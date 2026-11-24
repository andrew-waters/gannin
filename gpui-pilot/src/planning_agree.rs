//! Agree, in a planning session's panel: the room checks what'll be filed
//! and who was there, then Gannin writes it all. The top issue (the one
//! being planned, or a new initiative, epic or issue), the epics under it
//! and the issues under those, each with its type and as sub-issues; then
//! the plan and the requirement, with the documents marked for it, in one
//! harness commit; then a comment on the issue being planned.
//!
//! Every step is written to `agreed.json` as it's done, so trying again
//! after a failure carries on and never files anything twice. Every write
//! is confirmed first, in one prompt that says what goes where.

use crate::charts::Theme;
use crate::marra_view::button;
use crate::github;
use crate::launch::Launch;
use crate::planning::{self, Agreed, Approvals, Draft, Made, State, Status};
use crate::planning_docs as docs;
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, EventEmitter, FontWeight, SharedString, Window};
use serde_json::json;
use std::collections::HashMap;
use std::path::PathBuf;

pub enum AgreeEvent {
    Agreed(Agreed),
    Cancel,
}

pub struct AgreeView {
    launch: Launch,
    state: State,
    approvals: Approvals,
    drafts: Vec<Draft>,
    titles: Vec<Entity<editor::Editor>>,
    who: Entity<editor::Editor>,
    parent_title: Entity<editor::Editor>,
    parent_repo: Option<String>,
    repos: Vec<String>,
    /// The org's issue types, (id, name).
    types: Vec<(String, String)>,
    parent_type: Option<String>,
    write_requirement: bool,
    agreed: Agreed,
    running: bool,
    error: Option<String>,
}

impl EventEmitter<AgreeEvent> for AgreeView {}

const ORG_TYPES: &str = "query($login: String!) { organization(login: $login) { issueTypes(first: 25) { nodes { id name isEnabled } } } }";

impl AgreeView {
    pub fn new(launch: Launch, state: State, approvals: Approvals, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let drafts = planning::drafts(&state);
        let titles = drafts
            .iter()
            .map(|d| {
                let title = d.task.title.clone();
                cx.new(|cx| {
                    let mut editor = editor::Editor::single_line(window, cx);
                    editor.set_text(title, window, cx);
                    editor
                })
            })
            .collect();
        let viewer = crate::auth::saved_viewer().map(|v| v.login).unwrap_or_default();
        let who = cx.new(|cx| {
            let mut editor = editor::Editor::single_line(window, cx);
            editor.set_placeholder_text("Logins, separated by commas", window, cx);
            editor.set_text(viewer, window, cx);
            editor
        });
        let parent_title = cx.new(|cx| {
            let mut editor = editor::Editor::single_line(window, cx);
            editor.set_placeholder_text("The initiative, epic or issue it all sits under", window, cx);
            editor.set_text(state.title.clone(), window, cx);
            editor
        });
        let mut repos: Vec<String> = state.tasks.iter().map(|t| t.repo.clone()).filter(|r| !r.is_empty()).collect();
        repos.dedup();
        let mut seen = std::collections::HashSet::new();
        repos.retain(|r| seen.insert(r.clone()));
        let parent_repo = repos.first().cloned();
        let agreed = Agreed::load(&launch.dir());
        // The org's issue types, for the top issue's and the epics'.
        let org = launch.org.clone();
        cx.spawn(async move |this, cx| {
            let types = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token()?;
                    let data = github::graphql(&token, ORG_TYPES, json!({ "login": org })).ok()?;
                    Some(
                        data["organization"]["issueTypes"]["nodes"]
                            .as_array()?
                            .iter()
                            .filter(|t| t["isEnabled"] != false)
                            .filter_map(|t| Some((t["id"].as_str()?.to_string(), t["name"].as_str()?.to_string())))
                            .collect::<Vec<_>>(),
                    )
                })
                .await
                .unwrap_or_default();
            this.update(cx, |this, cx| {
                // The plan's size picks the top issue's type, when the org has it.
                let wanted = match this.state.size.as_str() {
                    "initiative" => "initiative",
                    "issue" => "",
                    _ => "epic",
                };
                this.parent_type = types.iter().find(|(_, n)| n.eq_ignore_ascii_case(wanted)).map(|(_, n)| n.clone());
                this.types = types;
                cx.notify();
            })
            .ok();
        })
        .detach();
        Self {
            launch,
            state,
            approvals,
            drafts,
            titles,
            who,
            parent_title,
            parent_repo,
            repos,
            types: Vec::new(),
            parent_type: None,
            write_requirement: true,
            agreed,
            running: false,
            error: None,
        }
    }

    /// The drafts with the titles as edited, and the epics' new titles
    /// carried into the issues under them.
    fn edited(&self, cx: &Context<Self>) -> Vec<Draft> {
        let mut drafts = self.drafts.clone();
        let mut renamed: HashMap<String, String> = HashMap::new();
        for (draft, editor) in drafts.iter_mut().zip(&self.titles) {
            let title = editor.read(cx).text(cx).trim().to_string();
            if !title.is_empty() && title != draft.task.title {
                renamed.insert(draft.task.title.trim().to_lowercase(), title.clone());
                draft.task.title = title;
            }
        }
        for draft in drafts.iter_mut() {
            if let Some(title) = renamed.get(&draft.task.parent.trim().to_lowercase()) {
                draft.task.parent = title.clone();
            }
            for dep in draft.task.depends_on.iter_mut() {
                if let Some(title) = renamed.get(&dep.trim().to_lowercase()) {
                    *dep = title.clone();
                }
            }
        }
        drafts
    }

    fn agree(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let by: Vec<String> = self.who.read(cx).text(cx).split([',', ' ']).map(|s| s.trim().trim_start_matches('@').to_string()).filter(|s| !s.is_empty()).collect();
        if by.is_empty() {
            self.error = Some("Say who was here: at least one login.".into());
            return cx.notify();
        }
        let drafts = self.edited(cx);
        if !drafts.iter().any(|d| d.include && !d.task.is_epic()) {
            self.error = Some("Include at least one issue.".into());
            return cx.notify();
        }
        let subject = self.launch.subject.clone();
        let new_parent = match &subject {
            Some(_) => None,
            None => {
                let title = self.parent_title.read(cx).text(cx).trim().to_string();
                let Some(repo) = self.parent_repo.clone() else {
                    self.error = Some("Pick the repository for the top issue.".into());
                    return cx.notify();
                };
                if title.is_empty() {
                    self.error = Some("Give the top issue a title.".into());
                    return cx.notify();
                }
                let type_id = self.parent_type.as_ref().and_then(|n| self.types.iter().find(|(_, t)| t == n)).map(|(id, _)| id.clone());
                Some(NewParent { title, repo, type_id, type_name: self.parent_type.clone() })
            }
        };
        self.error = None;
        let included: Vec<&Draft> = drafts.iter().filter(|d| d.include).collect();
        let mut repos: Vec<String> = included.iter().map(|d| d.task.repo.clone()).collect();
        repos.sort();
        repos.dedup();
        let shared = planning::docs(&self.launch.dir());
        let committed: Vec<String> = shared.iter().filter(|d| d.commit).map(|d| d.name.clone()).collect();
        let top = match (&subject, &new_parent) {
            (Some(s), _) => format!("under {}#{}", s.repo, s.number),
            (None, Some(p)) => format!("under a new {} in {}, \"{}\"", p.type_name.as_deref().unwrap_or("issue").to_lowercase(), p.repo, p.title),
            _ => String::new(),
        };
        let epics = included.iter().filter(|d| d.task.is_epic()).count();
        let issues = included.len() - epics;
        let mut detail = vec![format!(
            "Files {}{} {top}, in {}.",
            if epics > 0 { format!("{epics} epic{} and ", if epics == 1 { "" } else { "s" }) } else { String::new() },
            format!("{issues} issue{}", if issues == 1 { "" } else { "s" }),
            repos.join(", ")
        )];
        detail.push(format!(
            "Commits the plan{}{} to {}, where everyone who can read it sees them and git keeps them.",
            if self.write_requirement { " and the requirement" } else { "" },
            if committed.is_empty() { String::new() } else { format!(", with {}", committed.join(", ")) },
            self.launch.harness_repo
        ));
        if let Some(s) = &subject {
            detail.push(format!("Comments a link to the plan on {}#{}.", s.repo, s.number));
        }
        if !self.agreed.made.is_empty() || self.agreed.parent.is_some() {
            detail.push("What was filed last time is kept, not filed again.".into());
        }
        let answer = window.prompt(gpui::PromptLevel::Info, "Agree and write it all?", Some(&detail.join("\n\n")), &["Agree and Write", "Cancel"], cx);
        let job = Job {
            harness: self.launch.harness_repo.clone(),
            branch: self.launch.branch.clone(),
            dir: self.launch.dir(),
            slug: crate::launch::slug(if self.state.title.is_empty() { &self.launch.title } else { &self.state.title }, 40),
            state: self.state.clone(),
            drafts,
            subject,
            new_parent,
            types: self.types.clone(),
            write_requirement: self.write_requirement,
            by,
            owner: crate::auth::saved_viewer().map(|v| v.login).unwrap_or_default(),
            shared,
        };
        cx.spawn_in(window, async move |this, cx| {
            if answer.await != Ok(0) {
                return;
            }
            if this.update(cx, |this, cx| {
                this.running = true;
                cx.notify();
            })
            .is_err()
            {
                return;
            }
            let result = cx.background_executor().spawn(async move { job.run() }).await;
            this.update(cx, |this, cx| {
                this.running = false;
                match result {
                    Ok(agreed) => {
                        this.agreed = agreed.clone();
                        cx.emit(AgreeEvent::Agreed(agreed));
                    }
                    Err((agreed, error)) => {
                        this.agreed = agreed;
                        this.error = Some(error);
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }
}

struct NewParent {
    title: String,
    repo: String,
    type_id: Option<String>,
    type_name: Option<String>,
}

/// Everything Agree needs, off the main thread.
struct Job {
    harness: String,
    branch: String,
    dir: PathBuf,
    slug: String,
    state: State,
    drafts: Vec<Draft>,
    subject: Option<crate::launch::Subject>,
    new_parent: Option<NewParent>,
    types: Vec<(String, String)>,
    write_requirement: bool,
    by: Vec<String>,
    owner: String,
    shared: Vec<planning::Doc>,
}

const REPO: &str = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id labels(first: 100) { nodes { id name } } } }";
const CREATE: &str = "mutation($input: CreateIssueInput!) { createIssue(input: $input) { issue { id number url } } }";
const SUB: &str = "mutation($parent: ID!, $child: ID!) { addSubIssue(input: { issueId: $parent, subIssueId: $child }) { issue { id } } }";
const ISSUE: &str = "query($id: ID!) { node(id: $id) { ... on Issue { id number url body issueType { name } repository { nameWithOwner } } } }";
const UPDATE: &str = "mutation($id: ID!, $body: String!) { updateIssue(input: { id: $id, body: $body }) { issue { id } } }";
const COMMENT: &str = "mutation($id: ID!, $body: String!) { addComment(input: { subjectId: $id, body: $body }) { clientMutationId } }";

impl Job {
    fn run(self) -> Result<Agreed, (Agreed, String)> {
        let mut agreed = Agreed::load(&self.dir);
        match self.steps(&mut agreed) {
            Ok(()) => Ok(agreed),
            Err(e) => Err((agreed, e)),
        }
    }

    fn steps(&self, agreed: &mut Agreed) -> Result<(), String> {
        let token = crate::auth::token().ok_or("Not signed in to GitHub.")?;
        let token = token.as_str();
        let err = |what: String| move |e: github::Error| format!("{what}: {e}");
        // The paths are fixed the first time, so a retry another day writes the same plan.
        if agreed.plan_path.is_empty() {
            agreed.plan_path = docs::plan_path(&chrono::Local::now().format("%Y-%m-%d").to_string(), &self.slug);
        }
        agreed.requirement_path = self.write_requirement.then(|| docs::requirement_path(&self.slug));
        agreed.by = self.by.clone();
        agreed.save(&self.dir);
        let plan_url = docs::harness_url(&self.harness, &agreed.plan_path);
        let title = if self.state.title.is_empty() { "the plan".to_string() } else { self.state.title.clone() };

        let mut repos: HashMap<String, (String, HashMap<String, String>)> = HashMap::new();
        let mut repo = |name: &str| -> Result<(String, HashMap<String, String>), String> {
            if let Some(found) = repos.get(name) {
                return Ok(found.clone());
            }
            let (owner, short) = name.split_once('/').ok_or(format!("{name} isn't owner/name."))?;
            let data = github::graphql(token, REPO, json!({ "owner": owner, "name": short })).map_err(err(format!("Couldn't find {name}")))?;
            let id = data["repository"]["id"].as_str().ok_or(format!("Couldn't find {name}."))?.to_string();
            let labels: HashMap<String, String> = data["repository"]["labels"]["nodes"]
                .as_array()
                .map(|a| a.iter().filter_map(|l| Some((l["name"].as_str()?.to_lowercase(), l["id"].as_str()?.to_string()))).collect())
                .unwrap_or_default();
            repos.insert(name.to_string(), (id.clone(), labels.clone()));
            Ok((id, labels))
        };
        let create = |repo_id: &str, labels: &HashMap<String, String>, title: &str, body: &str, wanted: &[String], type_id: Option<&String>| -> Result<(String, i64, String), String> {
            let mut input = json!({ "repositoryId": repo_id, "title": title, "body": body });
            let ids: Vec<&String> = wanted.iter().filter_map(|l| labels.get(&l.to_lowercase())).collect();
            if !ids.is_empty() {
                input["labelIds"] = json!(ids);
            }
            if let Some(id) = type_id {
                input["issueTypeId"] = json!(id);
            }
            let made = github::mutate(token, CREATE, json!({ "input": input }), "createIssue").map_err(err(format!("GitHub didn't take \"{title}\"")))?;
            Ok((
                made["issue"]["id"].as_str().unwrap_or_default().to_string(),
                made["issue"]["number"].as_i64().unwrap_or_default(),
                made["issue"]["url"].as_str().unwrap_or_default().to_string(),
            ))
        };

        // 1. The top issue: the one being planned, or a new one.
        let (parent_type, parent_body) = match (&self.subject, &self.new_parent) {
            (Some(subject), _) => {
                let data = github::graphql(token, ISSUE, json!({ "id": subject.id })).map_err(err(format!("Couldn't read {}#{}", subject.repo, subject.number)))?;
                let node = &data["node"];
                if agreed.parent.is_none() {
                    agreed.parent = Some(Made {
                        key: "parent".into(),
                        id: subject.id.clone(),
                        repo: node["repository"]["nameWithOwner"].as_str().unwrap_or(&subject.repo).to_string(),
                        number: subject.number,
                        url: node["url"].as_str().unwrap_or(&subject.url).to_string(),
                    });
                    agreed.save(&self.dir);
                }
                (node["issueType"]["name"].as_str().map(str::to_string), node["body"].as_str().unwrap_or_default().to_string())
            }
            (None, Some(new)) => {
                let body = top_body(&self.state, &title, &plan_url);
                if agreed.parent.is_none() {
                    let (repo_id, labels) = repo(&new.repo)?;
                    let (id, number, url) = create(&repo_id, &labels, &new.title, &body, &[], new.type_id.as_ref())?;
                    agreed.parent = Some(Made { key: "parent".into(), id, repo: new.repo.clone(), number, url });
                    agreed.save(&self.dir);
                }
                (new.type_name.clone(), body)
            }
            (None, None) => return Err("There's nothing to file under.".into()),
        };
        let parent = agreed.parent.clone().ok_or("No top issue.")?;

        // 2. The epics and issues under it, or the one issue's work in it.
        let order = planning::creation_order(&self.drafts);
        let included: Vec<&Draft> = order.iter().map(|i| &self.drafts[*i]).collect();
        let big = parent_type.as_deref().is_some_and(|t| t.eq_ignore_ascii_case("epic") || t.eq_ignore_ascii_case("initiative"));
        let one = included.iter().filter(|d| !d.task.is_epic()).count() == 1 && !included.iter().any(|d| d.task.is_epic());
        if one && !big {
            let draft = included.iter().find(|d| !d.task.is_epic()).ok_or("No issue.")?;
            if agreed.made(&draft.key).is_none() {
                let work = docs::issue_body(&draft.task, &self.state, &[], (&title, &plan_url));
                github::mutate(token, UPDATE, json!({ "id": parent.id, "body": docs::merge_into(&parent_body, &agreed.plan_path, &work) }), "updateIssue")
                    .map_err(err(format!("Couldn't add the plan to {}", parent.reference())))?;
                agreed.merged_into_parent = true;
                agreed.made.push(Made { key: draft.key.clone(), ..parent.clone() });
                agreed.save(&self.dir);
            }
        } else {
            let epic_type = self.types.iter().find(|(_, n)| n.eq_ignore_ascii_case("epic")).map(|(id, _)| id.clone());
            for draft in &included {
                let task = &draft.task;
                let made = match agreed.made(&draft.key) {
                    Some(made) => made.clone(),
                    None => {
                        let depends: Vec<String> = task
                            .depends_on
                            .iter()
                            .filter_map(|dep| included.iter().find(|d| d.task.title.eq_ignore_ascii_case(dep.trim())))
                            .filter_map(|d| agreed.made(&d.key).map(|m| m.reference()))
                            .collect();
                        let body = docs::issue_body(task, &self.state, &depends, (&title, &plan_url));
                        let (repo_id, labels) = repo(&task.repo)?;
                        let type_id = if task.is_epic() { epic_type.as_ref() } else { None };
                        let (id, number, url) = create(&repo_id, &labels, &task.title, &body, &task.labels, type_id)?;
                        let made = Made { key: draft.key.clone(), id, repo: task.repo.clone(), number, url };
                        agreed.made.push(made.clone());
                        agreed.save(&self.dir);
                        made
                    }
                };
                if !agreed.placed.contains(&draft.key) {
                    // Under its epic, else the top issue.
                    let under = included
                        .iter()
                        .find(|d| d.task.is_epic() && !task.is_epic() && d.task.title.trim().eq_ignore_ascii_case(task.parent.trim()))
                        .and_then(|d| agreed.made(&d.key))
                        .map(|m| m.id.clone())
                        .unwrap_or_else(|| parent.id.clone());
                    github::mutate(token, SUB, json!({ "parent": under, "child": made.id }), "addSubIssue").map_err(err(format!("Couldn't put {} under its parent", made.reference())))?;
                    agreed.placed.push(draft.key.clone());
                    agreed.save(&self.dir);
                }
            }
        }

        // 3. The plan, the requirement and the documents, in one commit.
        if agreed.commit.is_none() {
            let edited = State { tasks: included.iter().map(|d| d.task.clone()).collect(), ..self.state.clone() };
            let issues: Vec<(String, Made)> = included.iter().filter_map(|d| agreed.made(&d.key).map(|m| (d.task.title.clone(), m.clone()))).collect();
            let assets: Vec<String> = self.shared.iter().filter(|d| d.commit).map(|d| d.name.clone()).collect();
            let comments = planning::comments(&self.dir);
            let started = self.subject.as_ref().map(|s| format!("{}#{}", s.repo, s.number));
            let at = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
            let ctx = docs::Context {
                slug: &self.slug,
                branch: &self.branch,
                owner: &self.owner,
                agreed_by: &self.by,
                agreed_at: &at,
                started_from: started.as_deref(),
                parent: Some(&parent),
                issues: &issues,
                requirement_path: agreed.requirement_path.as_deref(),
                assets: &assets,
                comments: &comments,
            };
            let mut files = vec![(agreed.plan_path.clone(), docs::plan(&edited, &ctx).into_bytes())];
            if let Some(path) = &agreed.requirement_path {
                let refs: Vec<String> = std::iter::once(parent.reference()).chain(issues.iter().map(|(_, m)| m.reference())).collect();
                files.push((path.clone(), docs::requirement(&edited, &agreed.plan_path, &refs).into_bytes()));
            }
            for name in &assets {
                let bytes = std::fs::read(self.dir.join("docs").join(name)).map_err(|e| format!("Couldn't read {name}: {e}"))?;
                files.push((format!("{}/{name}", docs::assets_dir(&self.slug)), bytes));
            }
            let commit = crate::issue_parts::commit_files(token, &self.harness, &files, &format!("Plan: {title}")).map_err(err(format!("Couldn't commit the plan to {}", self.harness)))?;
            agreed.commit = Some(commit);
            agreed.save(&self.dir);
        }

        // 4. A link on the issue being planned.
        if let (Some(subject), false) = (&self.subject, agreed.commented) {
            let list: Vec<String> = agreed.made.iter().filter(|m| m.number != parent.number || m.repo != parent.repo).map(|m| format!("- {}", m.reference())).collect();
            let body = format!("Planned in [{}]({plan_url}).{}", agreed.plan_path, if list.is_empty() { String::new() } else { format!("\n\n{}", list.join("\n")) });
            github::mutate(token, COMMENT, json!({ "id": subject.id, "body": body }), "addComment").map_err(err(format!("Couldn't comment on {}#{}", subject.repo, subject.number)))?;
            agreed.commented = true;
            agreed.save(&self.dir);
        }

        agreed.at = Some(chrono::Utc::now());
        agreed.save(&self.dir);
        Ok(())
    }
}

/// A new top issue's body: what it's for and how we'll know, then the plan.
fn top_body(state: &State, title: &str, plan_url: &str) -> String {
    let mut out = Vec::new();
    if !state.summary.is_empty() {
        out.push(state.summary.clone());
    }
    if !state.outcome.change.is_empty() {
        out.push(format!("**Outcome:** {}", state.outcome.change));
    }
    if !state.outcome.measures.is_empty() {
        out.push(format!(
            "**How we'll know**\n\n{}",
            state.outcome.measures.iter().map(|m| format!("- {}: {}{}", m.id, m.text, if m.target.is_empty() { String::new() } else { format!(" (target: {})", m.target) })).collect::<Vec<_>>().join("\n")
        ));
    }
    out.push(format!("From the plan [{title}]({plan_url})."));
    out.join("\n\n")
}

impl Render for AgreeView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let heading = |text: &str| div().pt_2().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(text.to_string());
        let quiet = |text: String| div().text_xs().text_color(theme.secondary).child(text);
        let field = |editor: &Entity<editor::Editor>| div().flex_1().px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).child(editor.clone());

        // Before you agree: what isn't settled. Never a block.
        let mut warnings: Vec<String> = self
            .approvals
            .outstanding(&self.state)
            .into_iter()
            .map(|(stage, status)| match status {
                Status::Recheck => format!("{} changed after the room approved it.", stage.title()),
                _ => format!("The room hasn't approved {}.", stage.title()),
            })
            .collect();
        let uncovered: Vec<String> = self.state.uncovered().iter().map(|c| c.id.clone()).collect();
        if !uncovered.is_empty() {
            warnings.push(format!("No issue satisfies {}.", uncovered.join(", ")));
        }

        let top: gpui::AnyElement = match &self.launch.subject {
            Some(s) => quiet(format!("Everything goes under {}#{}, the issue being planned.", s.repo, s.number)).into_any_element(),
            None => div()
                .flex()
                .flex_col()
                .gap_1()
                .child(div().flex().flex_row().child(field(&self.parent_title)))
                .child(div().flex().flex_row().flex_wrap().gap_1().children(self.repos.iter().enumerate().map(|(i, repo)| {
                    let on = self.parent_repo.as_deref() == Some(repo.as_str());
                    let repo = repo.clone();
                    button(SharedString::from(format!("agree-parent-repo-{i}")), repo.clone(), on, &theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.parent_repo = Some(repo.clone());
                        cx.notify();
                    }))
                })))
                .when(!self.types.is_empty(), |d| {
                    d.child(div().flex().flex_row().flex_wrap().gap_1().children(self.types.iter().enumerate().map(|(i, (_, name))| {
                        let on = self.parent_type.as_deref() == Some(name.as_str());
                        let name = name.clone();
                        button(SharedString::from(format!("agree-parent-type-{i}")), name.clone(), on, &theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.parent_type = if this.parent_type.as_deref() == Some(name.as_str()) { None } else { Some(name.clone()) };
                            cx.notify();
                        }))
                    })))
                })
                .into_any_element(),
        };

        // The breakdown as it'll be filed: epics, and the issues under them.
        let rows = self.drafts.iter().enumerate().map(|(i, draft)| {
            let task = &draft.task;
            let under_epic = !task.is_epic() && self.state.epics().any(|e| e.title.trim().eq_ignore_ascii_case(task.parent.trim()));
            let made = self.agreed.made(&draft.key).cloned();
            let meta = [
                Some(task.repo.clone()).filter(|r| !r.is_empty()),
                (!task.satisfies.is_empty()).then(|| format!("Satisfies {}", task.satisfies.join(", "))),
                (!task.estimate.is_empty()).then(|| format!("Size {}", task.estimate)),
                (!task.depends_on.is_empty()).then(|| format!("After {}", task.depends_on.join(", "))),
                made.as_ref().map(|m| format!("Filed as {}", m.reference())),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" · ");
            div()
                .flex()
                .flex_col()
                .gap_0p5()
                .when(under_epic, |d| d.pl(px(20.)))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(
                            div()
                                .id(SharedString::from(format!("agree-include-{i}")))
                                .size(px(14.))
                                .flex_none()
                                .rounded(px(3.))
                                .border_1()
                                .flex()
                                .items_center()
                                .justify_center()
                                .cursor_pointer()
                                .map(|d| if draft.include { d.bg(theme.selected).border_color(theme.selected).text_color(theme.on_selected).text_xs().child("✓") } else { d.border_color(theme.secondary) })
                                .when(made.is_none(), |d| {
                                    d.on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                        if let Some(d) = this.drafts.get_mut(i) {
                                            d.include = !d.include;
                                        }
                                        cx.notify();
                                    }))
                                }),
                        )
                        .when(task.is_epic(), |d| d.child(div().text_xs().px_1().rounded_sm().bg(theme.tile).text_color(theme.secondary).child("Epic")))
                        .child(field(&self.titles[i])),
                )
                .child(div().pl(px(22.)).child(quiet(meta)))
        });

        let body = div()
            .flex()
            .flex_col()
            .gap_2()
            .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child("Agree"))
            .when(!warnings.is_empty(), |d| {
                d.child(heading("Before you agree"))
                    .children(warnings.into_iter().map(|w| div().text_sm().text_color(theme.orange()).child(w)))
                    .child(quiet("You can agree anyway: it's the room's call.".into()))
            })
            .child(heading("Who was here"))
            .child(div().flex().flex_row().child(field(&self.who)))
            .child(heading("Top of the tree"))
            .child(top)
            .child(heading("What gets filed"))
            .children(rows)
            .child(quiet("Change a repository or a body by asking Claude in the session: it updates the plan, and this list follows.".into()))
            .child(heading("In the harness"))
            .child(quiet(format!(
                "{} in {}",
                if self.agreed.plan_path.is_empty() { "plans/<today>-<slug>.md".to_string() } else { self.agreed.plan_path.clone() },
                self.launch.harness_repo
            )))
            .child(
                div()
                    .id("agree-requirement")
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1p5()
                    .text_sm()
                    .cursor_pointer()
                    .child(div().size(px(14.)).rounded(px(3.)).border_1().flex().items_center().justify_center().map(|d| if self.write_requirement { d.bg(theme.selected).border_color(theme.selected).text_color(theme.on_selected).text_xs().child("✓") } else { d.border_color(theme.secondary) }))
                    .child("Also write the requirement")
                    .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.write_requirement = !this.write_requirement;
                        cx.notify();
                    })),
            )
            .when_some(self.error.clone(), |d, e| d.child(div().text_sm().text_color(theme.critical()).child(e)))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap_2()
                    .pt_2()
                    .child(button("agree-cancel", "Back to the Plan", false, &theme).on_click(cx.listener(|_, _: &ClickEvent, _, cx| cx.emit(AgreeEvent::Cancel))))
                    .child(if self.running {
                        div().text_xs().text_color(theme.secondary).child("Filing the issues and writing the plan").into_any_element()
                    } else {
                        let label = if self.error.is_some() { "Try Again" } else { "Agree and Write" };
                        button("agree-write", label, true, &theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.agree(window, cx))).into_any_element()
                    }),
            );
        div().id("agree").size_full().overflow_y_scroll().p_4().child(body)
    }
}
