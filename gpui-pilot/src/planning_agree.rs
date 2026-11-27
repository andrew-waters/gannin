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
use gpui::{div, prelude::*, px, relative, ClickEvent, Context, Entity, EventEmitter, FontWeight, KeyDownEvent, SharedString, Window};
use serde_json::json;
use std::collections::HashMap;
use std::path::PathBuf;

pub enum AgreeEvent {
    Agreed(Agreed),
    Cancel,
}

pub struct AgreeView {
    launch: Launch,
    /// Where the session keeps what Agree has done.
    dir: PathBuf,
    state: State,
    approvals: Approvals,
    drafts: Vec<Draft>,
    titles: Vec<Entity<editor::Editor>>,
    /// Typing to find who was here, or to name someone not on GitHub.
    who: Entity<editor::Editor>,
    /// Who was here: GitHub logins, or names as typed.
    people: Vec<String>,
    /// The org's members, (login, name), to pick from.
    members: Vec<(String, String)>,
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

const ORG_MEMBERS: &str = "query($login: String!, $cursor: String) { organization(login: $login) { membersWithRole(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { login name } } } }";

const ORG_TYPES: &str = "query($login: String!) { organization(login: $login) { issueTypes(first: 25) { nodes { id name isEnabled } } } }";

impl AgreeView {
    pub fn new(launch: Launch, dir: PathBuf, state: State, approvals: Approvals, window: &mut Window, cx: &mut Context<Self>) -> Self {
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
            editor.set_placeholder_text("Find someone, or type a name and press Return", window, cx);
            editor
        });
        // Typing filters the members offered.
        cx.observe(&who, |_, _, cx| cx.notify()).detach();
        let people: Vec<String> = [viewer].into_iter().filter(|v| !v.is_empty()).collect();
        // The org's members, to pick who was here from.
        let org_login = launch.org.clone();
        cx.spawn(async move |this, cx| {
            let members = cx
                .background_executor()
                .spawn(async move {
                    let Some(token) = crate::auth::token() else { return Vec::new() };
                    let mut members: Vec<(String, String)> = Vec::new();
                    let mut cursor: Option<String> = None;
                    for _ in 0..10 {
                        let Ok(data) = github::graphql(&token, ORG_MEMBERS, json!({ "login": org_login, "cursor": cursor })) else { break };
                        let page = &data["organization"]["membersWithRole"];
                        members.extend(page["nodes"].as_array().into_iter().flatten().filter_map(|n| Some((n["login"].as_str()?.to_string(), n["name"].as_str().unwrap_or_default().to_string()))));
                        if page["pageInfo"]["hasNextPage"] != true {
                            break;
                        }
                        cursor = page["pageInfo"]["endCursor"].as_str().map(str::to_string);
                    }
                    members.sort_by_key(|(l, n)| if n.is_empty() { l.to_lowercase() } else { n.to_lowercase() });
                    members
                })
                .await;
            this.update(cx, |this, cx| {
                this.members = members;
                cx.notify();
            })
            .ok();
        })
        .detach();
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
        let agreed = Agreed::load(&dir);
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
            dir,
            state,
            approvals,
            drafts,
            titles,
            who,
            people,
            members: Vec::new(),
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

    /// Adds someone who was here: a member's login, or a name as typed.
    fn add_person(&mut self, who: String, window: &mut Window, cx: &mut Context<Self>) {
        let who = who.trim().trim_start_matches('@').to_string();
        if !who.is_empty() && !self.people.iter().any(|p| p.eq_ignore_ascii_case(&who)) {
            self.people.push(who);
        }
        self.who.update(cx, |e, cx| e.set_text("", window, cx));
        cx.notify();
    }

    /// The members whose login or name has what's typed in it, not yet
    /// picked: a few, for the list under the box.
    fn matches(&self, query: &str) -> Vec<(String, String)> {
        let q = query.trim().trim_start_matches('@').to_lowercase();
        if q.is_empty() {
            return Vec::new();
        }
        self.members
            .iter()
            .filter(|(l, n)| !self.people.iter().any(|p| p.eq_ignore_ascii_case(l)) && (l.to_lowercase().contains(&q) || n.to_lowercase().contains(&q)))
            .take(6)
            .cloned()
            .collect()
    }

    /// Return in the box: the one member it matches, else the name typed.
    fn add_typed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let typed = self.who.read(cx).text(cx).trim().to_string();
        if typed.is_empty() {
            return;
        }
        let found = self.matches(&typed);
        let exact = self.members.iter().find(|(l, _)| l.eq_ignore_ascii_case(typed.trim_start_matches('@'))).map(|(l, _)| l.clone());
        let pick = exact.or_else(|| (found.len() == 1).then(|| found[0].0.clone())).unwrap_or(typed);
        self.add_person(pick, window, cx);
    }

    /// What Agree commits to the harness, a line each.
    fn committed(&self) -> Vec<String> {
        let slug = crate::launch::slug(if self.state.title.is_empty() { &self.launch.title } else { &self.state.title }, 40);
        let mut out = vec![format!("The plan, {}", if self.agreed.plan_path.is_empty() { format!("plans/<today>-{slug}.md") } else { self.agreed.plan_path.clone() })];
        if self.write_requirement {
            out.push(format!("The requirement, {}", docs::requirement_path(&slug)));
        }
        let screens = self.state.shape.screens.iter().filter(|s| s.image_path().is_some()).count();
        if screens > 0 {
            out.push(format!("{screens} screen{}, {}/screens/", if screens == 1 { "" } else { "s" }, docs::assets_dir(&slug)));
        }
        let flows = self.state.shape.flows.len();
        if flows > 0 {
            out.push(format!("{flows} flow{}, as diagrams in the plan", if flows == 1 { "" } else { "s" }));
        }
        for a in self.state.architecture.iter().filter(|a| a.valid()) {
            out.push(format!("{}{}, marked planned", a.path.trim(), if a.new { " (new)" } else { "" }));
        }
        for d in planning::docs(&self.dir).iter().filter(|d| d.commit) {
            out.push(format!("{}, {}/{}", d.name, docs::assets_dir(&slug), d.name));
        }
        out
    }

    /// Who was here: chips for those picked, a box to find a member or
    /// type any name, and the members it matches.
    fn who_picker(&self, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        let typed = self.who.read(cx).text(cx);
        let found = self.matches(&typed);
        let name_of = |login: &str| self.members.iter().find(|(l, _)| l.eq_ignore_ascii_case(login)).map(|(_, n)| n.clone()).filter(|n| !n.is_empty());
        div()
            .flex()
            .flex_col()
            .gap_1()
            .child(div().flex().flex_row().flex_wrap().gap_1().children(self.people.iter().enumerate().map(|(i, who)| {
                let label = match name_of(who) {
                    Some(name) => format!("{name} ({who})"),
                    None => who.clone(),
                };
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1()
                    .pl_2()
                    .pr_1()
                    .py_0p5()
                    .rounded_md()
                    .bg(theme.selected.opacity(0.16))
                    .text_sm()
                    .child(label)
                    .child(
                        div()
                            .id(SharedString::from(format!("agree-who-remove-{i}")))
                            .px_1()
                            .rounded_sm()
                            .text_color(theme.secondary)
                            .cursor_pointer()
                            .hover(|d| d.bg(theme.tile))
                            .child("×")
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                if i < this.people.len() {
                                    this.people.remove(i);
                                }
                                cx.notify();
                            })),
                    )
            })))
            .child(
                div()
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .border_1()
                    .border_color(theme.border)
                    .bg(theme.bg)
                    .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                        if event.keystroke.key == "enter" {
                            cx.stop_propagation();
                            this.add_typed(window, cx);
                        }
                    }))
                    .child(self.who.clone()),
            )
            .when(!typed.trim().is_empty(), |d| {
                let typed_name = typed.trim().to_string();
                let exact = self.members.iter().any(|(l, _)| l.eq_ignore_ascii_case(typed_name.trim_start_matches('@')));
                d.child(
                    div()
                        .flex()
                        .flex_col()
                        .rounded_md()
                        .border_1()
                        .border_color(theme.border)
                        .children(found.into_iter().enumerate().map(|(i, (login, name))| {
                            let pick = login.clone();
                            div()
                                .id(SharedString::from(format!("agree-who-member-{i}")))
                                .px_2()
                                .py_1()
                                .text_sm()
                                .cursor_pointer()
                                .hover(|d| d.bg(theme.tile))
                                .child(if name.is_empty() { login.clone() } else { format!("{name} ({login})") })
                                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.add_person(pick.clone(), window, cx)))
                        }))
                        .when(!exact, |d| {
                            let name = typed_name.clone();
                            d.child(
                                div()
                                    .id("agree-who-typed")
                                    .px_2()
                                    .py_1()
                                    .text_sm()
                                    .text_color(theme.secondary)
                                    .cursor_pointer()
                                    .hover(|d| d.bg(theme.tile))
                                    .child(format!("Add \"{typed_name}\", not on GitHub"))
                                    .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.add_person(name.clone(), window, cx))),
                            )
                        }),
                )
            })
            .into_any_element()
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
        let by: Vec<String> = self.people.clone();
        if by.is_empty() {
            self.error = Some("Say who was here: at least one person.".into());
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
        let architecture: Vec<String> = self.state.architecture.iter().filter(|a| a.valid()).map(|a| a.path.trim().to_string()).collect();
        {
            let folder = self.launch.local_folder();
            if let Some(missing) = architecture.iter().find(|p| !folder.join(p).is_file()) {
                self.error = Some(format!("{missing} isn't in the session's folder yet. Ask Claude to write it there, or to drop it from the design."));
                return cx.notify();
            }
            if let Some(missing) = self.state.shape.screens.iter().filter_map(|s| s.image_path()).find(|p| !folder.join(p).is_file()) {
                self.error = Some(format!("The screen {missing} isn't in the session's folder. Ask Claude to draw it again, or to drop its image."));
                return cx.notify();
            }
        }
        let shared = planning::docs(&self.dir);
        let mut committed: Vec<String> = shared.iter().filter(|d| d.commit).map(|d| d.name.clone()).collect();
        committed.extend(architecture.iter().cloned());
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
            dir: self.dir.clone(),
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
            folder: self.launch.local_folder(),
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
    /// The session's folder in the harness, where claude leaves the
    /// architecture documents the design changes.
    folder: PathBuf,
}

const REPO: &str = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id labels(first: 100) { nodes { id name } } } }";
const CREATE: &str = "mutation($input: CreateIssueInput!) { createIssue(input: $input) { issue { id number url } } }";
const SUB: &str = "mutation($parent: ID!, $child: ID!) { addSubIssue(input: { issueId: $parent, subIssueId: $child }) { issue { id } } }";
const ISSUE: &str = "query($id: ID!) { node(id: $id) { ... on Issue { id number url body issueType { name } repository { nameWithOwner } } } }";
const UPDATE: &str = "mutation($id: ID!, $body: String!) { updateIssue(input: { id: $id, body: $body }) { issue { id } } }";
const COMMENT: &str = "mutation($id: ID!, $body: String!) { addComment(input: { subjectId: $id, body: $body }) { clientMutationId } }";

/// An issue as Agree reads it back: its type, body, URL and repository.
struct Existing {
    kind: Option<String>,
    body: String,
    url: String,
    repo: String,
}

/// Agree's writes, so the same steps run against GitHub or, in the
/// tests, against a stand-in that only records them.
trait Writer {
    /// Files an issue; its node ID, number and URL.
    fn create(&mut self, repo: &str, title: &str, body: &str, labels: &[String], type_id: Option<&String>) -> Result<(String, i64, String), String>;
    fn place(&mut self, parent: &str, child: &str, child_ref: &str) -> Result<(), String>;
    fn issue(&mut self, id: &str, reference: &str) -> Result<Existing, String>;
    fn update(&mut self, id: &str, reference: &str, body: &str) -> Result<(), String>;
    fn commit(&mut self, harness: &str, files: &[(String, Vec<u8>)], message: &str) -> Result<String, String>;
    fn comment(&mut self, id: &str, reference: &str, body: &str) -> Result<(), String>;
}

struct GitHub {
    token: String,
    /// Each repository's node ID and labels (lower-cased name to ID).
    repos: HashMap<String, (String, HashMap<String, String>)>,
}

impl GitHub {
    fn repo(&mut self, name: &str) -> Result<(String, HashMap<String, String>), String> {
        if let Some(found) = self.repos.get(name) {
            return Ok(found.clone());
        }
        let (owner, short) = name.split_once('/').ok_or(format!("{name} isn't owner/name."))?;
        let data = github::graphql(&self.token, REPO, json!({ "owner": owner, "name": short })).map_err(|e| format!("Couldn't find {name}: {e}"))?;
        let id = data["repository"]["id"].as_str().ok_or(format!("Couldn't find {name}."))?.to_string();
        let labels: HashMap<String, String> = data["repository"]["labels"]["nodes"]
            .as_array()
            .map(|a| a.iter().filter_map(|l| Some((l["name"].as_str()?.to_lowercase(), l["id"].as_str()?.to_string()))).collect())
            .unwrap_or_default();
        self.repos.insert(name.to_string(), (id.clone(), labels.clone()));
        Ok((id, labels))
    }
}

impl Writer for GitHub {
    fn create(&mut self, repo: &str, title: &str, body: &str, wanted: &[String], type_id: Option<&String>) -> Result<(String, i64, String), String> {
        let (repo_id, labels) = self.repo(repo)?;
        let mut input = json!({ "repositoryId": repo_id, "title": title, "body": body });
        let ids: Vec<&String> = wanted.iter().filter_map(|l| labels.get(&l.to_lowercase())).collect();
        if !ids.is_empty() {
            input["labelIds"] = json!(ids);
        }
        if let Some(id) = type_id {
            input["issueTypeId"] = json!(id);
        }
        let made = github::mutate(&self.token, CREATE, json!({ "input": input }), "createIssue").map_err(|e| format!("GitHub didn't take \"{title}\": {e}"))?;
        Ok((
            made["issue"]["id"].as_str().unwrap_or_default().to_string(),
            made["issue"]["number"].as_i64().unwrap_or_default(),
            made["issue"]["url"].as_str().unwrap_or_default().to_string(),
        ))
    }

    fn place(&mut self, parent: &str, child: &str, child_ref: &str) -> Result<(), String> {
        github::mutate(&self.token, SUB, json!({ "parent": parent, "child": child }), "addSubIssue").map(|_| ()).map_err(|e| format!("Couldn't put {child_ref} under its parent: {e}"))
    }

    fn issue(&mut self, id: &str, reference: &str) -> Result<Existing, String> {
        let data = github::graphql(&self.token, ISSUE, json!({ "id": id })).map_err(|e| format!("Couldn't read {reference}: {e}"))?;
        let node = &data["node"];
        Ok(Existing {
            kind: node["issueType"]["name"].as_str().map(str::to_string),
            body: node["body"].as_str().unwrap_or_default().to_string(),
            url: node["url"].as_str().unwrap_or_default().to_string(),
            repo: node["repository"]["nameWithOwner"].as_str().unwrap_or_default().to_string(),
        })
    }

    fn update(&mut self, id: &str, reference: &str, body: &str) -> Result<(), String> {
        github::mutate(&self.token, UPDATE, json!({ "id": id, "body": body }), "updateIssue").map(|_| ()).map_err(|e| format!("Couldn't add the plan to {reference}: {e}"))
    }

    fn commit(&mut self, harness: &str, files: &[(String, Vec<u8>)], message: &str) -> Result<String, String> {
        crate::issue_parts::commit_files(&self.token, harness, files, message).map_err(|e| format!("Couldn't commit the plan to {harness}: {e}"))
    }

    fn comment(&mut self, id: &str, reference: &str, body: &str) -> Result<(), String> {
        github::mutate(&self.token, COMMENT, json!({ "id": id, "body": body }), "addComment").map(|_| ()).map_err(|e| format!("Couldn't comment on {reference}: {e}"))
    }
}

/// The tests' stand-in: numbers issues from 101 and keeps a record of
/// what GitHub would have been asked.
#[cfg(test)]
#[derive(Default)]
pub struct Rehearsal {
    next: i64,
    pub record: Vec<String>,
}

#[cfg(test)]
impl Writer for Rehearsal {
    fn create(&mut self, repo: &str, title: &str, body: &str, labels: &[String], type_id: Option<&String>) -> Result<(String, i64, String), String> {
        self.next = self.next.max(100) + 1;
        let n = self.next;
        let kind = type_id.map(|t| format!(" ({})", t.trim_start_matches("IT_"))).unwrap_or_default();
        let labels = if labels.is_empty() { String::new() } else { format!("\n\nLabels: {}", labels.join(", ")) };
        self.record.push(format!("### Files {repo}#{n}{kind}: {title}\n\n{body}{labels}"));
        Ok((format!("I_{n}"), n, format!("https://github.com/{repo}/issues/{n}")))
    }

    fn place(&mut self, parent: &str, _: &str, child_ref: &str) -> Result<(), String> {
        self.record.push(format!("Puts {child_ref} under {}.", parent.trim_start_matches("I_").parse::<i64>().map(|n| format!("#{n}")).unwrap_or_else(|_| parent.to_string())));
        Ok(())
    }

    fn issue(&mut self, _: &str, reference: &str) -> Result<Existing, String> {
        Ok(Existing { kind: None, body: String::new(), url: String::new(), repo: reference.split('#').next().unwrap_or_default().to_string() })
    }

    fn update(&mut self, _: &str, reference: &str, body: &str) -> Result<(), String> {
        self.record.push(format!("### Adds the plan to {reference}\n\n{body}"));
        Ok(())
    }

    fn commit(&mut self, harness: &str, files: &[(String, Vec<u8>)], message: &str) -> Result<String, String> {
        for (path, bytes) in files {
            let text = String::from_utf8(bytes.clone()).unwrap_or_else(|_| format!("({} bytes)", bytes.len()));
            let shown = if path.ends_with(".md") { format!("```markdown\n{text}\n```") } else { text };
            self.record.push(format!("### Commits {path} to {harness}, \"{message}\"\n\n{shown}"));
        }
        Ok("recorded".into())
    }

    fn comment(&mut self, _: &str, reference: &str, body: &str) -> Result<(), String> {
        self.record.push(format!("### Comments on {reference}\n\n{body}"));
        Ok(())
    }
}

impl Job {
    /// Writes it all.
    fn run(self) -> Result<Agreed, (Agreed, String)> {
        let mut agreed = Agreed::load(&self.dir);
        let Some(token) = crate::auth::token() else { return Err((agreed, "Not signed in to GitHub.".into())) };
        let mut writer = GitHub { token, repos: HashMap::new() };
        match self.steps(&mut agreed, &mut writer) {
            Ok(()) => Ok(agreed),
            Err(e) => Err((agreed, e)),
        }
    }

    fn steps(&self, agreed: &mut Agreed, w: &mut dyn Writer) -> Result<(), String> {
        // The paths are fixed the first time, so a retry another day writes the same plan.
        if agreed.plan_path.is_empty() {
            agreed.plan_path = docs::plan_path(&chrono::Local::now().format("%Y-%m-%d").to_string(), &self.slug);
        }
        agreed.requirement_path = self.write_requirement.then(|| docs::requirement_path(&self.slug));
        agreed.by = self.by.clone();
        agreed.save(&self.dir);
        let plan_url = docs::harness_url(&self.harness, &agreed.plan_path);
        let screens_url = docs::harness_url(&self.harness, &format!("{}/screens", docs::assets_dir(&self.slug)));
        let title = if self.state.title.is_empty() { "the plan".to_string() } else { self.state.title.clone() };

        // 1. The top issue: the one being planned, or a new one.
        let (parent_type, parent_body) = match (&self.subject, &self.new_parent) {
            (Some(subject), _) => {
                let reference = format!("{}#{}", subject.repo, subject.number);
                let found = w.issue(&subject.id, &reference)?;
                if agreed.parent.is_none() {
                    agreed.parent = Some(Made {
                        key: "parent".into(),
                        id: subject.id.clone(),
                        repo: Some(found.repo).filter(|r| !r.is_empty()).unwrap_or_else(|| subject.repo.clone()),
                        number: subject.number,
                        url: Some(found.url).filter(|u| !u.is_empty()).unwrap_or_else(|| subject.url.clone()),
                    });
                    agreed.save(&self.dir);
                }
                (found.kind, found.body)
            }
            (None, Some(new)) => {
                let body = top_body(&self.state, &title, &plan_url);
                if agreed.parent.is_none() {
                    let (id, number, url) = w.create(&new.repo, &new.title, &body, &[], new.type_id.as_ref())?;
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
                let work = docs::issue_body(&draft.task, &self.state, &[], (&title, &plan_url), &screens_url);
                w.update(&parent.id, &parent.reference(), &docs::merge_into(&parent_body, &agreed.plan_path, &work))?;
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
                        let body = docs::issue_body(task, &self.state, &depends, (&title, &plan_url), &screens_url);
                        let type_id = if task.is_epic() { epic_type.as_ref() } else { None };
                        let (id, number, url) = w.create(&task.repo, &task.title, &body, &task.labels, type_id)?;
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
                    w.place(&under, &made.id, &made.reference())?;
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
            let review = crate::planning_security::Review::load(&self.dir);
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
                security: review.as_ref(),
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
            // The screens, beside the plan's other assets.
            for screen in &self.state.shape.screens {
                let (Some(from), Some(to)) = (screen.image_path(), docs::screen_path(&self.slug, screen)) else { continue };
                let bytes = match std::fs::read(self.folder.join(from)) {
                    Ok(bytes) => bytes,
                    Err(e) => return Err(format!("Couldn't read the screen {from} from the session's folder: {e}")),
                };
                files.push((to, bytes));
            }
            // The architecture the design changes, its planned parts traced
            // to the plan.
            for change in self.state.architecture.iter().filter(|a| a.valid()) {
                let path = change.path.trim();
                let text = match std::fs::read_to_string(self.folder.join(path)) {
                    Ok(text) => text,
                    Err(e) => return Err(format!("Couldn't read {path} from the session's folder: {e}")),
                };
                files.push((path.to_string(), docs::mark_planned(&text, &agreed.plan_path).into_bytes()));
            }
            agreed.commit = Some(w.commit(&self.harness, &files, &format!("Plan: {title}"))?);
            agreed.save(&self.dir);
        }

        // 4. A link on the issue being planned.
        if let (Some(subject), false) = (&self.subject, agreed.commented) {
            let list: Vec<String> = agreed.made.iter().filter(|m| m.number != parent.number || m.repo != parent.repo).map(|m| format!("- {}", m.reference())).collect();
            let body = format!("Planned in [{}]({plan_url}).{}", agreed.plan_path, if list.is_empty() { String::new() } else { format!("\n\n{}", list.join("\n")) });
            w.comment(&subject.id, &format!("{}#{}", subject.repo, subject.number), &body)?;
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
        let field = |editor: &Entity<editor::Editor>| div().flex_1().min_w_0().px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).child(editor.clone());

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

        let who = self.who_picker(&theme, cx);

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
            .child(who)
            .child(heading("Top of the tree"))
            .child(top)
            .child(heading(&format!("In the harness, {}", self.launch.harness_repo)))
            .children(self.committed().into_iter().map(|line| div().text_sm().child(line)))
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
        // The choices on the left; what gets filed, the long part, on the right.
        let tickets = div()
            .id("agree-tickets")
            .flex_1()
            .min_w_0()
            .h_full()
            .overflow_y_scroll()
            .p_4()
            .flex()
            .flex_col()
            .gap_2()
            .child(heading("What gets filed"))
            .children(rows)
            .child(quiet("Change a repository or a body by asking Claude in the session: it updates the plan, and this list follows.".into()));
        div()
            .size_full()
            .flex()
            .flex_row()
            .text_color(theme.fg)
            .child(div().id("agree").w(relative(0.4)).flex_none().h_full().overflow_y_scroll().p_4().border_r_1().border_color(theme.border).child(body))
            .child(tickets)
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::planning::Stage;

    fn job(dir: PathBuf) -> Job {
        let state = crate::planning_fixtures::state(Stage::Agree, true);
        Job {
            harness: "acme/harness".into(),
            branch: "plan-x".into(),
            dir,
            slug: "failed-job-alerts".into(),
            drafts: planning::drafts(&state),
            state,
            subject: None,
            new_parent: Some(NewParent { title: "Failed job alerts".into(), repo: "acme/notify".into(), type_id: Some("IT_initiative".into()), type_name: Some("Initiative".into()) }),
            types: crate::planning_fixtures::types(),
            write_requirement: true,
            by: vec!["aw".into()],
            owner: "aw".into(),
            shared: Vec::new(),
            folder: folder(),
        }
    }

    /// The session's folder as claude would leave it: the screens and the
    /// architecture document the design changes.
    fn folder() -> PathBuf {
        let folder = std::env::temp_dir().join(format!("gannin-agree-test-folder-{}", std::process::id()));
        std::fs::create_dir_all(folder.join("shape")).unwrap();
        std::fs::create_dir_all(folder.join("architecture")).unwrap();
        for s in ["S1", "S2", "S3"] {
            std::fs::write(folder.join(format!("shape/{s}.svg")), "<svg/>").unwrap();
        }
        std::fs::write(folder.join("architecture/job-runs.md"), "---\ntype: architecture\nsummary: Job runs\n---\n\n# Job runs\n").unwrap();
        folder
    }

    #[test]
    fn agree_files_the_tree_once_and_writes_the_plan() {
        let dir = std::env::temp_dir().join(format!("gannin-agree-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut agreed = Agreed::load(&dir);
        let mut w = Rehearsal::default();
        job(dir.clone()).steps(&mut agreed, &mut w).unwrap();
        // The top issue, the epic and its three issues, each placed.
        assert_eq!(agreed.parent.as_ref().map(|p| p.number), Some(101));
        assert_eq!(agreed.made.len(), 4);
        assert_eq!(agreed.placed.len(), 4);
        assert!(agreed.finished() && agreed.commit.is_some());
        let record = w.record.join("\n\n");
        // What it needs first was filed first, and named.
        assert!(record.contains("Files acme/scheduler#104: Rerun a job from its alert") && record.contains("Depends on: acme/notify#103"));
        assert!(record.contains("Puts acme/scheduler#104 under #102."));
        assert!(record.contains("Commits plans/") && record.contains("Commits requirements/failed-job-alerts.md"));
        assert!(record.contains("Commits architecture/job-runs.md") && record.contains("planned_by:\n  - plans/"));
        // The screens go with the plan, and each issue links its own.
        assert!(record.contains("Commits plans/assets/failed-job-alerts/screens/S2.svg") && record.contains("## Shape") && record.contains("![S1 The alert in Slack](assets/failed-job-alerts/screens/S1.svg)"));
        assert!(record.contains("[S2 After Rerun](https://github.com/acme/harness/blob/HEAD/plans/assets/failed-job-alerts/screens/S2.svg)"));
        // Trying again files nothing twice.
        let mut again = Agreed::load(&dir);
        again.at = None;
        again.commit = None;
        let mut w = Rehearsal::default();
        job(dir.clone()).steps(&mut again, &mut w).unwrap();
        assert!(!w.record.iter().any(|r| r.starts_with("### Files")));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
