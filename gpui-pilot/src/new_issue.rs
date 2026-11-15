//! New Issue, after Gannin's `NewIssueSheet`: say what it's about and
//! Claude scouts the code and drafts it, following the template and the
//! harness skills picked; then the repository, template, type, title and
//! description, images, labels, assignees, a parent, and a board with its
//! single-select fields, to check and change. Templates, skills and images
//! are in `issue_parts.rs`.
//!
//! The draft is one headless `claude -p` turn, read only, in the harness
//! that covers the repository (its `projects/` clones are the code it
//! scouts), as `work_flow::ask_claude` runs the scout. It ends with a JSON
//! block the form fills itself from; Revise sends the next ask with what's
//! there now. Claude never writes to GitHub: Create on GitHub does.
//!
//! Everything it offers is read from GitHub as the form opens (the org's
//! repositories, boards and issue types) and as a repository or board is
//! picked (labels, assignable people, the board's fields), never from
//! Gannin's caches. Nothing is written until Review shows what will be
//! sent and Create on GitHub is pressed. Then it writes in Gannin's order:
//! the images (one commit to the harness), `createIssue`, `addSubIssue`,
//! `addProjectV2ItemById`, then each field. Images committed before a
//! refusal are linked, not committed again, on a retry to the same place.

use crate::charts::Theme;
use crate::github::{self, Error};
use crate::issues::IssueItem;
use gpui::{div, prelude::*, px, relative, ClickEvent, Context, Entity, EventEmitter, Focusable, FontWeight, KeyDownEvent, SharedString, Subscription, Window};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::{Arc, Mutex};

// MARK: - What GitHub offers

#[derive(Clone)]
pub struct Board {
    pub id: String,
    pub number: i64,
    pub title: String,
}

#[derive(Clone)]
pub struct Field {
    pub id: String,
    pub name: String,
    /// (option ID, name), in the board's order.
    pub options: Vec<(String, String)>,
}

#[derive(Clone)]
struct Label {
    id: String,
    name: String,
    color: String,
}

#[derive(Clone)]
struct Person {
    id: String,
    login: String,
    name: Option<String>,
}

#[derive(Clone, Default)]
struct OrgOptions {
    repos: Vec<String>,
    boards: Vec<Board>,
    /// (ID, name) of the org's issue types that are on.
    types: Vec<(String, String)>,
}

#[derive(Clone)]
struct RepoOptions {
    id: String,
    labels: Vec<Label>,
    people: Vec<Person>,
}

fn nodes(value: &Value) -> Vec<Value> {
    value["nodes"].as_array().cloned().unwrap_or_default()
}

/// The org's repositories that take issues, most recently pushed first
/// (up to 300), its open boards and its issue types. A personal account
/// has no issue types. Blocking.
fn fetch_org(token: &str, org: &str) -> Result<OrgOptions, Error> {
    const REPOS: &str = "query($login: String!, $cursor: String) { repositoryOwner(login: $login) { repositories(first: 100, after: $cursor, orderBy: { field: PUSHED_AT, direction: DESC }) { pageInfo { hasNextPage endCursor } nodes { nameWithOwner isArchived hasIssuesEnabled } } } }";
    const BOARDS: &str = "query($login: String!) { repositoryOwner(login: $login) { ... on ProjectV2Owner { projectsV2(first: 50, orderBy: { field: UPDATED_AT, direction: DESC }) { nodes { id number title closed } } } } }";
    const TYPES: &str = "query($login: String!) { organization(login: $login) { issueTypes(first: 25) { nodes { id name isEnabled } } } }";
    let mut options = OrgOptions::default();
    let mut cursor: Option<String> = None;
    for _ in 0..3 {
        let data = github::graphql(token, REPOS, json!({ "login": org, "cursor": cursor }))?;
        let repos = &data["repositoryOwner"]["repositories"];
        options.repos.extend(
            nodes(repos)
                .iter()
                .filter(|r| r["isArchived"] != true && r["hasIssuesEnabled"] != false)
                .filter_map(|r| r["nameWithOwner"].as_str().map(str::to_string)),
        );
        cursor = repos["pageInfo"]["endCursor"].as_str().map(str::to_string);
        if repos["pageInfo"]["hasNextPage"] != true || cursor.is_none() {
            break;
        }
    }
    // Boards need the project scope, and types an org: without either the
    // form still makes an issue.
    if let Ok(data) = github::graphql(token, BOARDS, json!({ "login": org })) {
        options.boards = nodes(&data["repositoryOwner"]["projectsV2"])
            .iter()
            .filter(|p| p["closed"] != true)
            .filter_map(|p| Some(Board { id: p["id"].as_str()?.into(), number: p["number"].as_i64()?, title: p["title"].as_str()?.into() }))
            .collect();
    }
    if let Ok(data) = github::graphql(token, TYPES, json!({ "login": org })) {
        options.types = nodes(&data["organization"]["issueTypes"])
            .iter()
            .filter(|t| t["isEnabled"] != false)
            .filter_map(|t| Some((t["id"].as_str()?.to_string(), t["name"].as_str()?.to_string())))
            .collect();
    }
    Ok(options)
}

/// A repository's labels and the people who can be assigned in it. Blocking.
fn fetch_repo(token: &str, repo: &str) -> Result<RepoOptions, Error> {
    const QUERY: &str = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id labels(first: 100, orderBy: { field: NAME, direction: ASC }) { nodes { id name color } } assignableUsers(first: 100) { nodes { id login name } } } }";
    let (owner, name) = repo.split_once('/').ok_or_else(|| Error::Other(format!("{repo} isn't owner/name")))?;
    let data = github::graphql(token, QUERY, json!({ "owner": owner, "name": name }))?;
    let repository = &data["repository"];
    let id = repository["id"].as_str().ok_or_else(|| Error::Other(format!("Couldn't find {repo}")))?.to_string();
    let labels = nodes(&repository["labels"])
        .iter()
        .filter_map(|l| Some(Label { id: l["id"].as_str()?.into(), name: l["name"].as_str()?.into(), color: l["color"].as_str().unwrap_or("ededed").into() }))
        .collect();
    let mut people: Vec<Person> = nodes(&repository["assignableUsers"])
        .iter()
        .filter_map(|p| {
            Some(Person { id: p["id"].as_str()?.into(), login: p["login"].as_str()?.into(), name: p["name"].as_str().filter(|n| !n.is_empty()).map(str::to_string) })
        })
        .collect();
    people.sort_by_key(|p| p.name.clone().unwrap_or_else(|| p.login.clone()).to_lowercase());
    Ok(RepoOptions { id, labels, people })
}

/// A board's single-select fields with their options. Blocking.
fn fetch_fields(token: &str, board: &str) -> Result<Vec<Field>, Error> {
    const QUERY: &str = "query($id: ID!) { node(id: $id) { ... on ProjectV2 { fields(first: 50) { nodes { ... on ProjectV2SingleSelectField { id name options { id name } } } } } } }";
    let data = github::graphql(token, QUERY, json!({ "id": board }))?;
    Ok(nodes(&data["node"]["fields"])
        .iter()
        .filter_map(|f| {
            Some(Field {
                id: f["id"].as_str()?.into(),
                name: f["name"].as_str()?.into(),
                options: f["options"].as_array()?.iter().filter_map(|o| Some((o["id"].as_str()?.to_string(), o["name"].as_str()?.to_string()))).collect(),
            })
        })
        .collect())
}

// MARK: - Creating

/// Everything Create on GitHub sends, settled at Review.
#[derive(Clone)]
struct Plan {
    repo: String,
    repo_id: String,
    title: String,
    body: String,
    issue_type: Option<(String, String)>,
    labels: Vec<Label>,
    assignees: Vec<Person>,
    parent: Option<IssueItem>,
    board: Option<Board>,
    /// (field, option ID, field name, option name).
    fields: Vec<(String, String, String, String)>,
    /// (ID, file name, bytes) of each image attached.
    images: Vec<(u64, String, Vec<u8>)>,
    /// Where images are committed: the harness covering the repository.
    harness: Option<String>,
    /// The folder they go in.
    folder: String,
    /// Links to those already committed for this harness and repo.
    committed: HashMap<u64, String>,
}

impl Plan {
    /// What will happen, a line a write, for Review.
    fn lines(&self) -> Vec<String> {
        let mut lines = Vec::new();
        let pending = self.images.iter().filter(|(id, ..)| !self.committed.contains_key(id)).count();
        if pending > 0 {
            let harness = self.harness.as_deref().unwrap_or("the harness");
            lines.push(format!("Commit {} to {harness}, in {}/", if pending == 1 { "1 image".to_string() } else { format!("{pending} images") }, self.folder));
        }
        lines.push(format!("Create “{}” in {}", self.title, self.repo));
        if let Some((_, name)) = &self.issue_type {
            lines.push(format!("as a {name}"));
        }
        if !self.labels.is_empty() {
            lines.push(format!("labelled {}", self.labels.iter().map(|l| l.name.as_str()).collect::<Vec<_>>().join(", ")));
        }
        if !self.assignees.is_empty() {
            lines.push(format!("assigned to {}", self.assignees.iter().map(|p| p.login.as_str()).collect::<Vec<_>>().join(", ")));
        }
        if let Some(parent) = &self.parent {
            lines.push(format!("Make it a sub-issue of {}#{} “{}”", parent.repo, parent.number, parent.title));
        }
        if let Some(board) = &self.board {
            lines.push(format!("Add it to the board {}", board.title));
            lines.extend(self.fields.iter().map(|(_, _, field, option)| format!("Set {field} to {option}")));
        }
        lines
    }
}

/// What was made.
#[derive(Clone)]
pub struct Created {
    pub id: String,
    pub number: i64,
    pub repo: String,
    pub url: String,
}

/// Sends the plan, telling `steps` as each write lands. Once the issue is
/// made, a later failure says so rather than leaving it unmentioned.
/// Also returns the links to the images committed, kept for a retry.
fn create(token: &str, plan: &Plan, steps: &Mutex<Vec<String>>) -> (Result<Created, (Option<Created>, String)>, HashMap<u64, String>) {
    let mut committed = plan.committed.clone();
    let result = create_committing(token, plan, steps, &mut committed);
    (result, committed)
}

fn create_committing(token: &str, plan: &Plan, steps: &Mutex<Vec<String>>, committed: &mut HashMap<u64, String>) -> Result<Created, (Option<Created>, String)> {
    let note = |line: String| {
        if let Ok(mut steps) = steps.lock() {
            steps.push(line);
        }
    };
    let pending: Vec<&(u64, String, Vec<u8>)> = plan.images.iter().filter(|(id, ..)| !committed.contains_key(id)).collect();
    if !pending.is_empty() {
        let harness = plan.harness.as_deref().ok_or((None, "Images go in the org's harness, and this org has none set up.".to_string()))?;
        let files: Vec<(String, Vec<u8>)> = pending.iter().map(|(_, name, data)| (format!("{}/{name}", plan.folder), data.clone())).collect();
        let message = format!("Gannin: {} for a new issue in {}", if pending.len() == 1 { "an image".to_string() } else { format!("{} images", pending.len()) }, plan.repo);
        let commit = crate::issue_parts::commit_files(token, harness, &files, &message).map_err(|e| (None, format!("GitHub didn't take the images: {e}")))?;
        for (id, name, _) in &pending {
            committed.insert(*id, crate::issue_parts::url(harness, &commit, &format!("{}/{name}", plan.folder)));
        }
        note(format!("Committed {} to {harness}", if pending.len() == 1 { "an image".to_string() } else { format!("{} images", pending.len()) }));
    }
    let links: Vec<(String, String)> = plan.images.iter().filter_map(|(id, name, _)| Some((name.clone(), committed.get(id)?.clone()))).collect();
    let body = crate::issue_parts::body(&plan.body, &links);
    let mut input = json!({ "repositoryId": plan.repo_id, "title": plan.title, "body": body });
    if !plan.labels.is_empty() {
        input["labelIds"] = json!(plan.labels.iter().map(|l| &l.id).collect::<Vec<_>>());
    }
    if !plan.assignees.is_empty() {
        input["assigneeIds"] = json!(plan.assignees.iter().map(|p| &p.id).collect::<Vec<_>>());
    }
    if let Some((id, _)) = &plan.issue_type {
        input["issueTypeId"] = json!(id);
    }
    let issue = github::mutate(token, "mutation($input: CreateIssueInput!) { createIssue(input: $input) { issue { id number url } } }", json!({ "input": input }), "createIssue")
        .map_err(|e| {
            let kept = if links.is_empty() { String::new() } else { " The images are committed, and trying again links them rather than committing them twice.".into() };
            (None, format!("GitHub didn't take the issue: {e}.{kept}"))
        })?;
    let created = Created {
        id: issue["issue"]["id"].as_str().unwrap_or_default().to_string(),
        number: issue["issue"]["number"].as_i64().unwrap_or_default(),
        repo: plan.repo.clone(),
        url: issue["issue"]["url"].as_str().unwrap_or_default().to_string(),
    };
    note(format!("Created {}#{}", created.repo, created.number));
    let rest = || -> Result<(), Error> {
        if let Some(parent) = &plan.parent {
            github::mutate(
                token,
                "mutation($parent: ID!, $child: ID!) { addSubIssue(input: { issueId: $parent, subIssueId: $child }) { issue { id } } }",
                json!({ "parent": parent.id, "child": created.id }),
                "addSubIssue",
            )?;
            note(format!("Made it a sub-issue of #{}", parent.number));
        }
        if let Some(board) = &plan.board {
            let added = github::mutate(
                token,
                "mutation($project: ID!, $content: ID!) { addProjectV2ItemById(input: { projectId: $project, contentId: $content }) { item { id } } }",
                json!({ "project": board.id, "content": created.id }),
                "addProjectV2ItemById",
            )?;
            note(format!("Added it to {}", board.title));
            let item = added["item"]["id"].as_str().unwrap_or_default().to_string();
            for (field, option, field_name, option_name) in &plan.fields {
                github::mutate(
                    token,
                    "mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) { updateProjectV2ItemFieldValue(input: { projectId: $project, itemId: $item, fieldId: $field, value: { singleSelectOptionId: $option } }) { clientMutationId } }",
                    json!({ "project": board.id, "item": item, "field": field, "option": option }),
                    "updateProjectV2ItemFieldValue",
                )?;
                note(format!("Set {field_name} to {option_name}"));
            }
        }
        Ok(())
    };
    match rest() {
        Ok(()) => Ok(created),
        Err(e) => {
            let message = format!("{}#{} is made, but GitHub didn't take the parent, board or fields: {e}", created.repo, created.number);
            Err((Some(created), message))
        }
    }
}

// MARK: - The form

pub enum NewIssueEvent {
    Created(Created),
    Cancel,
    /// Back to the page beneath, keeping the draft for New Issue to resume.
    Back,
}

impl EventEmitter<NewIssueEvent> for NewIssueForm {}

/// Where the form starts: the repository and parent it's for, the open
/// issues a parent can be picked from, and the board to offer first.
#[derive(Default)]
pub struct Start {
    pub repo: Option<String>,
    pub parent: Option<IssueItem>,
    pub open_issues: Vec<IssueItem>,
    pub board_number: Option<i64>,
    pub viewer: Option<String>,
    /// The org's projects, for the harness Claude scouts in.
    pub projects: Vec<crate::projects::Project>,
    /// The page Back returns to, for its button.
    pub back_title: String,
}

#[derive(PartialEq, Eq, Clone, Copy)]
enum Step {
    Edit,
    Review,
    Working,
}

pub struct NewIssueForm {
    org: String,
    viewer: Option<String>,
    step: Step,
    /// None while the org's options load.
    options: Option<OrgOptions>,
    repo: Option<String>,
    repo_search: Entity<editor::Editor>,
    picking_repo: bool,
    /// The picked repository's labels and people; None while they load.
    repo_options: Option<RepoOptions>,
    issue_type: Option<String>,
    title: Entity<editor::Editor>,
    body: Entity<editor::Editor>,
    labels: BTreeSet<String>,
    assignees: BTreeSet<String>,
    people_search: Entity<editor::Editor>,
    parent: Option<IssueItem>,
    parent_search: Entity<editor::Editor>,
    open_issues: Vec<IssueItem>,
    board: Option<Board>,
    board_number: Option<i64>,
    /// The board's fields; None while they load.
    fields: Option<Vec<Field>>,
    /// Field ID to option ID.
    field_values: BTreeMap<String, String>,
    plan: Option<Plan>,
    steps: Arc<Mutex<Vec<String>>>,
    error: Option<String>,
    /// Made, though something after it failed: Create isn't offered again.
    made: Option<Created>,
    back_title: String,
    projects: Vec<crate::projects::Project>,
    /// What to tell Claude.
    ask: Entity<editor::Editor>,
    /// Each ask and Claude's one-line answer.
    conversation: Vec<(String, String)>,
    /// When the draft under way started; counts up while Claude scouts.
    drafting: Option<std::time::Instant>,
    /// Bumped per draft, so a cancelled form or a later draft drops an
    /// earlier answer.
    draft_generation: usize,
    /// The repository's issue templates; None while they load.
    templates: Option<Vec<crate::issue_parts::Template>>,
    template: Option<String>,
    /// The harness's skills, and which harness they're from.
    skills: Vec<crate::issue_parts::Skill>,
    skills_from: Option<String>,
    picked_skills: BTreeSet<String>,
    images: Vec<Attached>,
    /// Links to images committed, and the (harness, repo) they were
    /// committed for: another commits them again there.
    committed: HashMap<u64, String>,
    committed_for: Option<(String, String)>,
    /// Names the images' folder, from when the form opened.
    started: chrono::DateTime<chrono::Utc>,
    folder_id: u64,
    next_image: u64,
    _subscriptions: Vec<Subscription>,
}

/// An image attached to the issue.
struct Attached {
    id: u64,
    name: String,
    data: Vec<u8>,
    image: Arc<gpui::Image>,
}

/// What Claude sent back.
#[derive(serde::Deserialize, Default)]
#[serde(default)]
struct Draft {
    repo: Option<String>,
    title: Option<String>,
    body: Option<String>,
    labels: Option<Vec<String>>,
    #[serde(rename = "type")]
    issue_type: Option<String>,
    fields: BTreeMap<String, String>,
    note: Option<String>,
}

/// The last fenced ```json block in a reply, else the reply itself as JSON.
fn parse_draft(reply: &str) -> Option<Draft> {
    let block = reply.rfind("```json").and_then(|start| {
        let start = start + "```json".len();
        let end = start + reply[start..].find("```")?;
        Some(reply[start..end].trim())
    });
    serde_json::from_str(block.unwrap_or(reply.trim())).ok()
}

impl NewIssueForm {
    pub fn new(org: String, start: Start, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let line = |placeholder: &'static str, window: &mut Window, cx: &mut Context<Self>| {
            cx.new(|cx| {
                let mut editor = editor::Editor::single_line(window, cx);
                editor.set_placeholder_text(placeholder, window, cx);
                editor
            })
        };
        let repo_search = line("Search repositories", window, cx);
        let people_search = line("Search people", window, cx);
        let parent_search = line("Search open issues by title or number", window, cx);
        let title = line("Title", window, cx);
        let ask = cx.new(|cx| {
            let mut editor = editor::Editor::auto_height(2, 8, window, cx);
            editor.set_placeholder_text("What's it about? A rough line is enough: Claude looks through the code and writes it up.", window, cx);
            editor
        });
        let body = cx.new(|cx| {
            let mut editor = editor::Editor::auto_height(5, 14, window, cx);
            editor.set_placeholder_text("Description, in Markdown", window, cx);
            editor
        });
        let subscriptions = [&repo_search, &people_search, &parent_search]
            .into_iter()
            .map(|editor| {
                cx.subscribe(editor, |_, _, event: &editor::EditorEvent, cx| {
                    if matches!(event, editor::EditorEvent::BufferEdited) {
                        cx.notify();
                    }
                })
            })
            .collect();
        let repo = start.repo.or_else(|| start.parent.as_ref().map(|p| p.repo.clone()));
        let focus = ask.focus_handle(cx);
        window.focus(&focus, cx);
        let mut form = Self {
            org: org.clone(),
            viewer: start.viewer,
            step: Step::Edit,
            options: None,
            repo: None,
            repo_search,
            picking_repo: repo.is_none(),
            repo_options: None,
            issue_type: None,
            title,
            body,
            labels: BTreeSet::new(),
            assignees: BTreeSet::new(),
            people_search,
            parent: start.parent,
            parent_search,
            open_issues: start.open_issues,
            board: None,
            board_number: start.board_number,
            fields: None,
            field_values: BTreeMap::new(),
            plan: None,
            steps: Default::default(),
            error: None,
            made: None,
            back_title: start.back_title,
            projects: start.projects,
            ask,
            conversation: Vec::new(),
            drafting: None,
            draft_generation: 0,
            templates: None,
            template: None,
            skills: Vec::new(),
            skills_from: None,
            picked_skills: BTreeSet::new(),
            images: Vec::new(),
            committed: HashMap::new(),
            committed_for: None,
            started: chrono::Utc::now(),
            folder_id: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(0) ^ std::process::id() as u64,
            next_image: 0,
            _subscriptions: subscriptions,
        };
        if let Some(repo) = repo {
            form.pick_repo(repo, cx);
        } else {
            form.load_skills(cx);
        }
        cx.spawn(async move |this, cx| {
            let fetched = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or(Error::Unauthorised)?;
                    fetch_org(&token, &org)
                })
                .await;
            this.update(cx, |form, cx| {
                match fetched {
                    Ok(options) => {
                        // The org's workflow board, else none, to start.
                        let board = form.board_number.and_then(|n| options.boards.iter().find(|b| b.number == n).cloned());
                        form.options = Some(options);
                        if let Some(board) = board {
                            form.pick_board(Some(board), cx);
                        }
                    }
                    Err(e) => {
                        form.options = Some(OrgOptions::default());
                        form.error = Some(format!("Couldn't read the org's repositories: {e}"));
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
        form
    }

    /// New Sub-issue while a draft is kept: the draft carries on, under
    /// this parent now.
    pub fn set_parent(&mut self, parent: IssueItem, cx: &mut Context<Self>) {
        if self.repo.is_none() {
            self.pick_repo(parent.repo.clone(), cx);
        }
        self.parent = Some(parent);
        cx.notify();
    }

    pub fn set_back_title(&mut self, title: String) {
        self.back_title = title;
    }

    pub fn focus(&self, window: &mut Window, cx: &mut Context<Self>) {
        let focus = self.ask.focus_handle(cx);
        window.focus(&focus, cx);
    }

    fn pick_repo(&mut self, repo: String, cx: &mut Context<Self>) {
        if self.repo.as_deref() == Some(repo.as_str()) && self.repo_options.is_some() {
            self.picking_repo = false;
            return cx.notify();
        }
        self.repo = Some(repo.clone());
        self.picking_repo = false;
        self.repo_options = None;
        self.templates = None;
        self.template = None;
        self.load_skills(cx);
        // Labels are the repository's own: those the new one lacks go once
        // it's read. People may carry over.
        cx.notify();
        cx.spawn(async move |this, cx| {
            let wanted = repo.clone();
            let fetched = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or(Error::Unauthorised)?;
                    // A repo without templates, or one GitHub won't show
                    // them for, has none.
                    let templates = crate::issue_parts::fetch_templates(&token, &wanted).unwrap_or_default();
                    fetch_repo(&token, &wanted).map(|options| (options, templates))
                })
                .await;
            this.update(cx, |form, cx| {
                if form.repo.as_deref() != Some(repo.as_str()) {
                    return;
                }
                let fetched = fetched.map(|(options, templates)| {
                    form.templates = Some(templates);
                    options
                });
                match fetched {
                    Ok(options) => {
                        form.assignees.retain(|login| options.people.iter().any(|p| &p.login == login));
                        form.labels.retain(|name| options.labels.iter().any(|l| &l.name == name));
                        form.repo_options = Some(options);
                    }
                    Err(e) => form.error = Some(format!("Couldn't read {repo}: {e}")),
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// The harness covering the repository, else the org's first.
    fn harness(&self) -> Option<String> {
        self.repo
            .as_ref()
            .and_then(|repo| self.projects.iter().find(|p| p.repos.contains(repo)))
            .or(self.projects.first())
            .map(|p| p.id.clone())
    }

    /// Reads the skills of the harness covering the repository, when it's
    /// another than they're from; those about issues start ticked.
    fn load_skills(&mut self, cx: &mut Context<Self>) {
        let Some(harness) = self.harness() else { return };
        if self.skills_from.as_deref() == Some(harness.as_str()) {
            return;
        }
        self.skills_from = Some(harness.clone());
        let org = self.org.clone();
        cx.spawn(async move |this, cx| {
            let wanted = harness.clone();
            let skills = cx.background_executor().spawn(async move { crate::issue_parts::skills(&crate::launch::harness_path(&org, &wanted)) }).await;
            this.update(cx, |form, cx| {
                if form.skills_from.as_deref() != Some(harness.as_str()) {
                    return;
                }
                form.picked_skills = skills.iter().filter(|s| s.about_issues()).map(|s| s.path.clone()).collect();
                form.skills = skills;
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// Fills in from a template: its title when there's none yet, its body,
    /// its labels the repository has, and its assignees.
    fn apply_template(&mut self, file: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        self.template = file.clone();
        let Some(template) = file.and_then(|f| self.templates.as_ref()?.iter().find(|t| t.file == f).cloned()) else { return cx.notify() };
        if self.title.read(cx).text(cx).trim().is_empty() && !template.title.is_empty() {
            self.title.update(cx, |e, cx| e.set_text(template.title.clone(), window, cx));
        }
        // Images keep their places at the end.
        let placeholders: Vec<String> = self.images.iter().map(|i| crate::issue_parts::placeholder(&i.name)).collect();
        let mut body = template.body.clone();
        for tag in placeholders {
            body = format!("{}\n\n{tag}", body.trim_end());
        }
        self.body.update(cx, |e, cx| e.set_text(body, window, cx));
        let known = |name: &String| self.repo_options.as_ref().is_none_or(|o| o.labels.iter().any(|l| &l.name == name));
        let labels: Vec<String> = template.labels.iter().filter(|l| known(l)).cloned().collect();
        self.labels.extend(labels);
        self.assignees.extend(template.assignees.iter().cloned());
        cx.notify();
    }

    /// Attaches an image: prepared off the main thread, then shown, with its
    /// placeholder at the end of the description.
    fn add_image(&mut self, name: String, bytes: Vec<u8>, window: &mut Window, cx: &mut Context<Self>) {
        if self.harness().is_none() {
            self.error = Some("Images are committed to the org's harness, and this org has none set up.".into());
            return cx.notify();
        }
        cx.spawn_in(window, async move |this, cx| {
            let prepared = cx.background_executor().spawn(async move { crate::issue_parts::prepare(&name, bytes) }).await;
            this.update_in(cx, |form, window, cx| {
                match prepared {
                    Ok((name, data)) => {
                        // A name unique among them.
                        let (stem, ext) = name.rsplit_once('.').map(|(s, e)| (s.to_string(), e.to_string())).unwrap_or((name.clone(), "png".into()));
                        let mut unique = name.clone();
                        let mut n = 2;
                        while form.images.iter().any(|i| i.name == unique) {
                            unique = format!("{stem}-{n}.{ext}");
                            n += 1;
                        }
                        form.next_image += 1;
                        let image = Arc::new(gpui::Image::from_bytes(crate::issue_parts::gpui_format(&unique), data.clone()));
                        let body = crate::issue_parts::appending_placeholder(&form.body.read(cx).text(cx), &unique);
                        form.body.update(cx, |e, cx| e.set_text(body, window, cx));
                        form.images.push(Attached { id: form.next_image, name: unique, data, image });
                    }
                    Err(e) => form.error = Some(e),
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn remove_image(&mut self, id: u64, window: &mut Window, cx: &mut Context<Self>) {
        let Some(at) = self.images.iter().position(|i| i.id == id) else { return };
        let image = self.images.remove(at);
        let body = crate::issue_parts::removing_placeholder(&self.body.read(cx).text(cx), &image.name);
        self.body.update(cx, |e, cx| e.set_text(body, window, cx));
        cx.notify();
    }

    fn add_paths(&mut self, paths: &[std::path::PathBuf], window: &mut Window, cx: &mut Context<Self>) {
        for path in paths {
            let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "image.png".into());
            match std::fs::read(path) {
                Ok(bytes) => self.add_image(name, bytes, window, cx),
                Err(e) => self.error = Some(format!("Couldn't read {name}: {e}")),
            }
        }
    }

    /// ⌘V with pictures or image files on the clipboard attaches them;
    /// false leaves the keystroke to the field (text pastes as usual).
    fn paste_images(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let Some(item) = cx.read_from_clipboard() else { return false };
        let mut pictures = Vec::new();
        let mut paths = Vec::new();
        for entry in item.entries() {
            match entry {
                gpui::ClipboardEntry::Image(image) => pictures.push((image.format, image.bytes.clone())),
                gpui::ClipboardEntry::ExternalPaths(external) => paths.extend(external.paths().iter().cloned()),
                gpui::ClipboardEntry::String(_) => {}
            }
        }
        if pictures.is_empty() && paths.is_empty() {
            return false;
        }
        for (format, bytes) in pictures {
            let name = format!("pasted.{}", crate::issue_parts::extension(format));
            self.add_image(name, bytes, window, cx);
        }
        self.add_paths(&paths, window, cx);
        true
    }

    fn pick_images(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(gpui::PathPromptOptions { files: true, directories: false, multiple: true, prompt: Some("Attach".into()) });
        cx.spawn_in(window, async move |this, cx| {
            let Ok(Ok(Some(paths))) = paths.await else { return };
            this.update_in(cx, |form, window, cx| form.add_paths(&paths, window, cx)).ok();
        })
        .detach();
    }

    fn pick_board(&mut self, board: Option<Board>, cx: &mut Context<Self>) {
        self.field_values.clear();
        self.fields = None;
        self.board = board.clone();
        cx.notify();
        let Some(board) = board else { return };
        cx.spawn(async move |this, cx| {
            let id = board.id.clone();
            let fetched = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or(Error::Unauthorised)?;
                    fetch_fields(&token, &id)
                })
                .await;
            this.update(cx, |form, cx| {
                if form.board.as_ref().map(|b| &b.id) != Some(&board.id) {
                    return;
                }
                match fetched {
                    Ok(fields) => form.fields = Some(fields),
                    Err(e) => {
                        form.fields = Some(Vec::new());
                        form.error = Some(format!("Couldn't read {}'s fields: {e}", board.title));
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// The prompt for a draft: the ask, what's written so far, and what
    /// the form can take (repositories, labels, types, the board's fields).
    fn draft_prompt(&self, request: &str, cx: &Context<Self>) -> String {
        let title = self.title.read(cx).text(cx);
        let body = self.body.read(cx).text(cx);
        let mut parts = vec![format!("Draft a GitHub issue with me, for {}. What I want: {request}", self.org)];
        if !self.conversation.is_empty() || !title.trim().is_empty() || !body.trim().is_empty() {
            parts.push(format!("What's written so far, to improve on rather than start over (keep what I wrote unless I ask otherwise):\n\nTitle: {title}\n\n{body}"));
        }
        parts.push("Scout before you write. Don't change anything. The code repos are shared clones under projects/ (or this checkout, when it's the code repo and has no projects/): find where this lives in the code, what it touches and how it behaves today, so the description names the real files, types and behaviour, says what's in and out of scope, and gives acceptance criteria someone can check. Keep it as long as it needs to be and no longer.".into());
        match &self.repo {
            Some(repo) => parts.push(format!("The repo is {repo}; say if the code shows it belongs in another, and name it in \"repo\".")),
            None => {
                let repos = self.options.as_ref().map(|o| o.repos.iter().take(40).cloned().collect::<Vec<_>>().join(", ")).unwrap_or_default();
                parts.push(format!("The repo isn't picked yet: pick the one the code says it belongs in{}.", if repos.is_empty() { String::new() } else { format!(", from: {repos}") }));
            }
        }
        if let Some(options) = &self.repo_options {
            if !options.labels.is_empty() {
                parts.push(format!("Labels the repo has (use only these): {}.", options.labels.iter().map(|l| l.name.as_str()).collect::<Vec<_>>().join(", ")));
            }
        }
        if let Some(types) = self.options.as_ref().map(|o| &o.types).filter(|t| !t.is_empty()) {
            parts.push(format!("Issue types (pick one, or none): {}.", types.iter().map(|(_, n)| n.as_str()).collect::<Vec<_>>().join(", ")));
        }
        if let (Some(board), Some(fields)) = (&self.board, self.fields.as_ref().filter(|f| !f.is_empty())) {
            let lines: Vec<String> = fields.iter().map(|f| format!("- {}: {}", f.name, f.options.iter().map(|(_, n)| n.as_str()).collect::<Vec<_>>().join(", "))).collect();
            parts.push(format!("It goes on the board {}. Suggest values only where you can tell, from these:\n{}", board.title, lines.join("\n")));
        }
        if let Some(parent) = &self.parent {
            parts.push(format!("It's a sub-issue of {}#{}: {}.", parent.repo, parent.number, parent.title));
        }
        if let Some(template) = self.template.as_ref().and_then(|f| self.templates.as_ref()?.iter().find(|t| &t.file == f)) {
            parts.push(format!("Follow the repo's {} template: keep its headings.\n\n{}", template.name, template.body));
        }
        if !self.images.is_empty() {
            parts.push(format!(
                "The description has images as placeholders, lines like `{}`. Keep every one exactly as it is, each where it fits best.",
                crate::issue_parts::placeholder(&self.images[0].name)
            ));
        }
        let skills: Vec<&str> = self.skills.iter().filter(|s| self.picked_skills.contains(&s.path)).map(|s| s.path.as_str()).collect();
        if !skills.is_empty() {
            parts.push(format!("Follow these skills from the team's harness, at these paths here: {}. Read them first.", skills.iter().map(|p| format!("`{p}`")).collect::<Vec<_>>().join(", ")));
        }
        parts.push("Don't invent details: say in the description what's unknown. End your reply with one fenced ```json block: {\"repo\": \"owner/name\", \"title\": \"...\", \"body\": \"<Markdown>\", \"labels\": [\"...\"], \"type\": \"<issue type or null>\", \"fields\": {\"Field\": \"option\"}, \"note\": \"one line to me: what you found, or what you need to know\"}".into());
        parts.join("\n\n")
    }

    /// Draft with Claude, or Revise: one read-only turn in the harness.
    fn draft(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let request = self.ask.read(cx).text(cx).trim().to_string();
        if request.is_empty() || self.drafting.is_some() {
            return;
        }
        let prompt = self.draft_prompt(&request, cx);
        self.error = None;
        self.drafting = Some(std::time::Instant::now());
        self.draft_generation += 1;
        let generation = self.draft_generation;
        // The harness covering the repository, else the org's first.
        let harness = self
            .repo
            .as_ref()
            .and_then(|repo| self.projects.iter().find(|p| p.repos.contains(repo)))
            .or(self.projects.first())
            .map(|p| p.id.clone());
        let org = self.org.clone();
        // The clock ticks while Claude works.
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(std::time::Duration::from_secs(1)).await;
            let Ok(going) = this.update(cx, |form, cx| {
                cx.notify();
                form.drafting.is_some() && form.draft_generation == generation
            }) else {
                return;
            };
            if !going {
                return;
            }
        })
        .detach();
        cx.spawn_in(window, async move |this, cx| {
            let reply = cx
                .background_executor()
                .spawn(async move {
                    let dir = harness.map(|h| crate::launch::harness_path(&org, &h)).filter(|d| d.is_dir()).unwrap_or_else(std::env::temp_dir);
                    crate::work_flow::ask_claude(&dir, &prompt, None, std::time::Duration::from_secs(10 * 60))
                })
                .await;
            this.update_in(cx, |form, window, cx| {
                if form.draft_generation != generation {
                    return;
                }
                form.drafting = None;
                match reply.and_then(|r| parse_draft(&r).ok_or_else(|| "That reply wasn't a draft. Say a little more and try again.".to_string())) {
                    Ok(draft) => {
                        let note = form.apply(draft, window, cx);
                        form.conversation.push((request, note));
                        form.ask.update(cx, |e, cx| e.set_text("", window, cx));
                    }
                    Err(e) => form.conversation.push((request, e)),
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
        cx.notify();
    }

    /// Fills the form from a draft; returns Claude's note.
    fn apply(&mut self, draft: Draft, window: &mut Window, cx: &mut Context<Self>) -> String {
        if let Some(repo) = draft.repo.filter(|r| self.repo.as_ref() != Some(r)) {
            let known = self.options.as_ref().is_none_or(|o| o.repos.is_empty() || o.repos.iter().any(|x| x.eq_ignore_ascii_case(&repo)));
            if known && repo.contains('/') {
                self.pick_repo(repo, cx);
            }
        }
        if let Some(title) = draft.title.filter(|t| !t.trim().is_empty()) {
            self.title.update(cx, |e, cx| e.set_text(title, window, cx));
        }
        if let Some(body) = draft.body.filter(|b| !b.trim().is_empty()) {
            self.body.update(cx, |e, cx| e.set_text(body, window, cx));
        }
        if let Some(labels) = draft.labels {
            // Only the repo's own; if its labels are still loading they're
            // kept and filtered when the plan is made.
            self.labels = labels
                .into_iter()
                .filter(|name| self.repo_options.as_ref().is_none_or(|o| o.labels.iter().any(|l| &l.name == name)))
                .collect();
        }
        if let Some(wanted) = draft.issue_type.filter(|t| !t.is_empty()) {
            if let Some((id, _)) = self.options.as_ref().and_then(|o| o.types.iter().find(|(_, n)| n.eq_ignore_ascii_case(&wanted))) {
                self.issue_type = Some(id.clone());
            }
        }
        for (name, value) in draft.fields {
            let Some(field) = self.fields.as_ref().and_then(|f| f.iter().find(|f| f.name.eq_ignore_ascii_case(&name))) else { continue };
            if let Some((option, _)) = field.options.iter().find(|(_, n)| n.eq_ignore_ascii_case(&value)) {
                self.field_values.insert(field.id.clone(), option.clone());
            }
        }
        draft.note.filter(|n| !n.trim().is_empty()).unwrap_or_else(|| "Drafted. Check it over.".into())
    }

    /// Settles what will be sent and shows it, or says what's missing.
    fn review(&mut self, cx: &mut Context<Self>) {
        self.error = None;
        if self.drafting.is_some() {
            self.error = Some("Claude is still drafting.".into());
            return cx.notify();
        }
        let title = self.title.read(cx).text(cx).trim().to_string();
        let (Some(repo), Some(options)) = (self.repo.clone(), self.repo_options.clone()) else {
            self.error = Some(if self.repo.is_none() { "Pick the repository it goes in.".into() } else { "Still reading the repository.".into() });
            return cx.notify();
        };
        if title.is_empty() {
            self.error = Some("Give it a title.".into());
            return cx.notify();
        }
        if self.board.is_some() && self.fields.is_none() {
            self.error = Some("Still reading the board's fields.".into());
            return cx.notify();
        }
        let types = self.options.as_ref().map(|o| o.types.clone()).unwrap_or_default();
        let fields = self.fields.clone().unwrap_or_default();
        self.plan = Some(Plan {
            repo,
            repo_id: options.id.clone(),
            title,
            body: self.body.read(cx).text(cx).trim_end().to_string(),
            issue_type: self.issue_type.as_ref().and_then(|id| types.into_iter().find(|(t, _)| t == id)),
            labels: options.labels.iter().filter(|l| self.labels.contains(&l.name)).cloned().collect(),
            assignees: options.people.iter().filter(|p| self.assignees.contains(&p.login)).cloned().collect(),
            parent: self.parent.clone(),
            board: self.board.clone(),
            fields: fields
                .iter()
                .filter_map(|f| {
                    let option = self.field_values.get(&f.id)?;
                    let name = f.options.iter().find(|(id, _)| id == option)?.1.clone();
                    Some((f.id.clone(), option.clone(), f.name.clone(), name))
                })
                .collect(),
            images: self.images.iter().map(|i| (i.id, i.name.clone(), i.data.clone())).collect(),
            harness: self.harness(),
            folder: crate::issue_parts::folder(self.repo.as_deref().unwrap_or(""), self.started, self.folder_id),
            committed: if self.committed_for == self.harness().zip(self.repo.clone()) { self.committed.clone() } else { HashMap::new() },
        });
        self.step = Step::Review;
        cx.notify();
    }

    fn send(&mut self, cx: &mut Context<Self>) {
        let Some(plan) = self.plan.clone() else { return };
        if self.made.is_some() {
            return;
        }
        self.step = Step::Working;
        self.error = None;
        self.steps = Default::default();
        let steps = self.steps.clone();
        cx.notify();
        // The steps tick off as they land.
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(std::time::Duration::from_millis(200)).await;
            let Ok(working) = this.update(cx, |form, cx| {
                cx.notify();
                form.step == Step::Working
            }) else {
                return;
            };
            if !working {
                return;
            }
        })
        .detach();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let committed_for = plan.harness.clone().zip(Some(plan.repo.clone()));
                    let Some(token) = crate::auth::token() else { return (Err((None, "Sign in to GitHub first.".to_string())), plan.committed.clone(), committed_for) };
                    let (result, committed) = create(&token, &plan, &steps);
                    (result, committed, committed_for)
                })
                .await;
            this.update(cx, |form, cx| {
                let (result, committed, committed_for) = result;
                if !committed.is_empty() {
                    form.committed = committed;
                    form.committed_for = committed_for;
                }
                match result {
                    Ok(created) => cx.emit(NewIssueEvent::Created(created)),
                    Err((made, message)) => {
                        form.step = Step::Review;
                        form.made = made;
                        form.error = Some(message);
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn cancel(&mut self, cx: &mut Context<Self>) {
        self.draft_generation += 1;
        match (&self.made, self.step) {
            // Made, though not all of it: close on what was made.
            (Some(made), _) => cx.emit(NewIssueEvent::Created(made.clone())),
            (None, Step::Working) => {}
            _ => cx.emit(NewIssueEvent::Cancel),
        }
    }
}

fn label_color(hex: &str) -> gpui::Hsla {
    u32::from_str_radix(hex.trim_start_matches('#'), 16).map(|v| gpui::rgb(v).into()).unwrap_or(gpui::rgb(0xededed).into())
}

impl Render for NewIssueForm {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let label = |text: &str| div().text_xs().text_color(theme.secondary).child(text.to_string());
        let note = |text: &str| div().text_xs().text_color(theme.tertiary).child(text.to_string());
        let field = |editor: &Entity<editor::Editor>| div().px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).child(editor.clone());
        let chip = |id: SharedString, text: String, on: bool| {
            div()
                .id(id)
                .px_2()
                .py_0p5()
                .rounded_md()
                .text_xs()
                .cursor_pointer()
                .border_1()
                .border_color(if on { theme.selected } else { theme.border })
                .text_color(if on { theme.selected } else { theme.fg })
                .when(on, |d| d.bg(theme.selected.opacity(0.12)))
                .hover(|s| s.bg(theme.row_selected))
                .child(text)
        };
        let button = |id: &'static str, text: String, primary: bool| {
            div()
                .id(id)
                .px_3()
                .py_1()
                .rounded_md()
                .cursor_pointer()
                .when(primary, |d| d.bg(theme.selected).text_color(theme.on_selected))
                .when(!primary, |d| d.border_1().border_color(theme.border))
                .child(text)
        };
        let row = || div().flex().flex_row().flex_wrap().gap_1();
        let mut claude_column = None;
        let mut claude = div().id("new-issue-claude").flex_1().min_h_0().overflow_y_scroll().flex().flex_col().gap_2();
        let mut body = div().id("new-issue-body").flex().flex_col().gap_3();
        match self.step {
            Step::Edit => {
                // Claude: describe it, and it scouts the code and drafts.
                if self.conversation.is_empty() && self.drafting.is_none() {
                    claude = claude.child(note("Say what it's about, roughly. Claude reads the code read only (the harness's projects/ clones), works out where it lives and what it touches, and writes the issue up on the right: title, description with acceptance criteria, labels, type and board fields. Revise as often as you like; nothing goes to GitHub until you Review and Create."));
                }
                claude = claude.children(self.conversation.iter().map(|(ask, reply)| {
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(div().self_end().max_w(relative(0.9)).p_2().rounded_lg().bg(theme.selected.opacity(0.14)).text_sm().child(ask.clone()))
                        .child(div().max_w(relative(0.9)).p_2().rounded_lg().bg(theme.tile).text_sm().text_color(theme.secondary).child(reply.clone()))
                }));
                let drafting = self.drafting.map(|at| at.elapsed().as_secs());
                if let Some(seconds) = drafting {
                    claude = claude.child(note(&format!("Claude is reading the code and writing it up, {}:{:02}", seconds / 60, seconds % 60)));
                }
                let composer = div().flex_none().flex().flex_col().gap_2().child(field(&self.ask)).child(
                    row().items_center().gap_2().child(match drafting {
                        Some(_) => button("new-issue-draft", "Scouting…".into(), false).text_color(theme.secondary),
                        None => button("new-issue-draft", if self.conversation.is_empty() { "Draft with Claude  ⌥↩".into() } else { "Revise  ⌥↩".into() }, true)
                            .on_click(cx.listener(|form, _: &ClickEvent, window, cx| form.draft(window, cx))),
                    }),
                );
                let skills = (!self.skills.is_empty()).then(|| {
                    div()
                        .id("new-issue-skills")
                        .flex_none()
                        .max_h(px(180.))
                        .overflow_y_scroll()
                        .flex()
                        .flex_col()
                        .gap_0p5()
                        .child(label("Skills Claude follows"))
                        .children(self.skills.iter().enumerate().map(|(i, skill)| {
                            let on = self.picked_skills.contains(&skill.path);
                            let path = skill.path.clone();
                            div()
                                .id(("skill", i))
                                .flex()
                                .flex_row()
                                .gap_2()
                                .px_1()
                                .py_0p5()
                                .rounded_md()
                                .cursor_pointer()
                                .hover(|s| s.bg(theme.row_selected))
                                .on_click(cx.listener(move |form, _: &ClickEvent, _, cx| {
                                    if !form.picked_skills.remove(&path) {
                                        form.picked_skills.insert(path.clone());
                                    }
                                    cx.notify();
                                }))
                                .child(div().flex_none().text_color(if on { theme.selected } else { theme.tertiary }).child(if on { "☑" } else { "☐" }))
                                .child(
                                    div()
                                        .min_w_0()
                                        .flex()
                                        .flex_col()
                                        .child(div().text_sm().child(skill.name.clone()))
                                        .when_some(skill.summary.clone(), |d, summary| d.child(div().text_xs().text_color(theme.secondary).truncate().child(summary))),
                                )
                        }))
                });
                claude_column = Some(
                    div()
                        .w(relative(0.38))
                        .min_w(px(320.))
                        .max_w(px(520.))
                        .h_full()
                        .flex()
                        .flex_col()
                        .gap_3()
                        .p_4()
                        .border_r_1()
                        .border_color(theme.border)
                        .bg(theme.sidebar)
                        .child(label("Claude"))
                        .child(claude)
                        .children(skills)
                        .child(composer),
                );
                // Repository.
                let repo_query = self.repo_search.read(cx).text(cx).to_lowercase();
                body = body.child(label("Repository"));
                match (&self.options, self.picking_repo) {
                    (None, _) if self.repo.is_none() => body = body.child(note("Reading the org's repositories…")),
                    (_, false) => {
                        let repo = self.repo.clone().unwrap_or_default();
                        body = body.child(
                            row().items_center().child(chip("repo-picked".into(), repo, true)).child(
                                div()
                                    .id("repo-change")
                                    .text_xs()
                                    .cursor_pointer()
                                    .text_color(theme.selected)
                                    .on_click(cx.listener(|form, _: &ClickEvent, window, cx| {
                                        form.picking_repo = true;
                                        let focus = form.repo_search.focus_handle(cx);
                                        window.focus(&focus, cx);
                                        cx.notify();
                                    }))
                                    .child("Change"),
                            ),
                        );
                    }
                    (_, true) => {
                        let repos = self.options.as_ref().map(|o| o.repos.clone()).unwrap_or_default();
                        let matches: Vec<String> = repos.into_iter().filter(|r| repo_query.is_empty() || r.to_lowercase().contains(&repo_query)).take(18).collect();
                        body = body.child(field(&self.repo_search)).child(row().children(matches.into_iter().enumerate().map(|(i, repo)| {
                            let on = self.repo.as_deref() == Some(repo.as_str());
                            let short = repo.rsplit('/').next().unwrap_or(&repo).to_string();
                            chip(SharedString::from(format!("repo-{i}")), short, on).on_click(cx.listener(move |form, _: &ClickEvent, _, cx| form.pick_repo(repo.clone(), cx)))
                        })));
                    }
                }

                // Template.
                match &self.templates {
                    None if self.repo.is_some() => {}
                    Some(templates) if !templates.is_empty() => {
                        body = body.child(label("Template")).child(
                            row()
                                .child(chip("template-none".into(), "None".into(), self.template.is_none()).on_click(cx.listener(|form, _: &ClickEvent, window, cx| form.apply_template(None, window, cx))))
                                .children(templates.iter().enumerate().map(|(i, t)| {
                                    let on = self.template.as_deref() == Some(t.file.as_str());
                                    let file = t.file.clone();
                                    let about = t.about.clone().unwrap_or_default();
                                    chip(SharedString::from(format!("template-{i}")), t.name.clone(), on)
                                        .when(!about.is_empty(), |d| d.tooltip(move |_, cx| cx.new(|_| crate::issues::Tooltip(about.clone())).into()))
                                        .on_click(cx.listener(move |form, _: &ClickEvent, window, cx| form.apply_template(Some(file.clone()), window, cx)))
                                })),
                        );
                    }
                    _ => {}
                }

                // Type.
                let types = self.options.as_ref().map(|o| o.types.clone()).unwrap_or_default();
                if !types.is_empty() {
                    body = body.child(label("Type")).child(
                        row()
                            .child(chip("type-none".into(), "None".into(), self.issue_type.is_none()).on_click(cx.listener(|form, _: &ClickEvent, _, cx| {
                                form.issue_type = None;
                                cx.notify();
                            })))
                            .children(types.into_iter().enumerate().map(|(i, (id, name))| {
                                let on = self.issue_type.as_deref() == Some(id.as_str());
                                chip(SharedString::from(format!("type-{i}")), name, on).on_click(cx.listener(move |form, _: &ClickEvent, _, cx| {
                                    form.issue_type = Some(id.clone());
                                    cx.notify();
                                }))
                            })),
                    );
                }

                body = body.child(label("Title")).child(field(&self.title)).child(label("Description")).child(field(&self.body));

                // Images: dropped anywhere on the page, pasted, or added.
                let harness = self.harness();
                body = body.child(label("Images"));
                match &harness {
                    None => body = body.child(note("Images are committed to the org's harness, and this org has none set up.")),
                    Some(harness) => {
                        if !self.images.is_empty() {
                            body = body.child(row().gap_2().children(self.images.iter().map(|image| {
                                let id = image.id;
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap_0p5()
                                    .w(px(120.))
                                    .child(
                                        div()
                                            .relative()
                                            .size(px(120.))
                                            .rounded_md()
                                            .overflow_hidden()
                                            .border_1()
                                            .border_color(theme.border)
                                            .bg(theme.tile)
                                            .child(gpui::img(image.image.clone()).size_full().object_fit(gpui::ObjectFit::Contain))
                                            .child(
                                                div()
                                                    .id(("remove-image", id))
                                                    .absolute()
                                                    .top_1()
                                                    .right_1()
                                                    .px_1()
                                                    .rounded_sm()
                                                    .bg(theme.popover)
                                                    .cursor_pointer()
                                                    .text_xs()
                                                    .on_click(cx.listener(move |form, _: &ClickEvent, window, cx| form.remove_image(id, window, cx)))
                                                    .child("×"),
                                            ),
                                    )
                                    .child(div().text_xs().text_color(theme.secondary).truncate().child(image.name.clone()))
                            })));
                        }
                        body = body
                            .child(
                                div()
                                    .id("image-drop")
                                    .h(px(52.))
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .justify_center()
                                    .gap_3()
                                    .rounded_md()
                                    .border_1()
                                    .border_dashed()
                                    .border_color(theme.border)
                                    .drag_over::<gpui::ExternalPaths>({ let over = theme.row_selected; move |s, _, _, _| s.bg(over) })
                                    .child(div().text_sm().text_color(theme.secondary).child("Drop images here, or paste them (⌘V)"))
                                    .child(button("add-images", "Add Images".into(), false).on_click(cx.listener(|form, _: &ClickEvent, window, cx| form.pick_images(window, cx)))),
                            )
                            .child(note(&crate::issue_parts::audience(harness, self.repo.as_deref().unwrap_or(harness))));
                    }
                }

                // Labels and assignees, once the repository is read.
                match &self.repo_options {
                    None if self.repo.is_some() => body = body.child(note("Reading the repository's labels and people…")),
                    None => {}
                    Some(options) => {
                        if !options.labels.is_empty() {
                            body = body.child(label("Labels")).child(row().children(options.labels.iter().enumerate().map(|(i, l)| {
                                let on = self.labels.contains(&l.name);
                                let name = l.name.clone();
                                chip(SharedString::from(format!("label-{i}")), l.name.clone(), on)
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap_1()
                                    .child(div().size(px(8.)).rounded_full().bg(label_color(&l.color)))
                                    .on_click(cx.listener(move |form, _: &ClickEvent, _, cx| {
                                        if !form.labels.remove(&name) {
                                            form.labels.insert(name.clone());
                                        }
                                        cx.notify();
                                    }))
                            })));
                        }
                        let query = self.people_search.read(cx).text(cx).to_lowercase();
                        // Who's picked, you, then those matching the search.
                        let mut shown: Vec<&Person> = options.people.iter().filter(|p| self.assignees.contains(&p.login)).collect();
                        if let Some(me) = options.people.iter().find(|p| Some(&p.login) == self.viewer.as_ref()) {
                            if !shown.iter().any(|p| p.login == me.login) {
                                shown.push(me);
                            }
                        }
                        let picked: BTreeSet<String> = shown.iter().map(|p| p.login.clone()).collect();
                        let matching = options.people.iter().filter(|p| {
                            !picked.contains(&p.login)
                                && (query.is_empty() || p.login.to_lowercase().contains(&query) || p.name.as_deref().is_some_and(|n| n.to_lowercase().contains(&query)))
                        });
                        let shown: Vec<Person> = shown.into_iter().cloned().chain(matching.take(12).cloned()).collect();
                        body = body.child(label("Assignees")).child(field(&self.people_search)).child(row().children(shown.into_iter().enumerate().map(|(i, p)| {
                            let on = self.assignees.contains(&p.login);
                            let me = Some(&p.login) == self.viewer.as_ref();
                            let text = match (&p.name, me) {
                                (_, true) => format!("Me ({})", p.login),
                                (Some(name), _) => format!("{name} ({})", p.login),
                                (None, _) => p.login.clone(),
                            };
                            let login = p.login.clone();
                            chip(SharedString::from(format!("person-{i}")), text, on).on_click(cx.listener(move |form, _: &ClickEvent, _, cx| {
                                if !form.assignees.remove(&login) {
                                    form.assignees.insert(login.clone());
                                }
                                cx.notify();
                            }))
                        })));
                    }
                }

                // Parent.
                body = body.child(label("Parent"));
                if let Some(parent) = &self.parent {
                    body = body.child(
                        row()
                            .items_center()
                            .child(chip("parent-picked".into(), format!("#{} {}", parent.number, parent.title), true))
                            .child(
                                div()
                                    .id("parent-clear")
                                    .text_xs()
                                    .cursor_pointer()
                                    .text_color(theme.selected)
                                    .on_click(cx.listener(|form, _: &ClickEvent, _, cx| {
                                        form.parent = None;
                                        cx.notify();
                                    }))
                                    .child("Remove"),
                            ),
                    );
                } else {
                    let query = self.parent_search.read(cx).text(cx).to_lowercase();
                    let query = query.trim().trim_start_matches('#').to_string();
                    body = body.child(field(&self.parent_search));
                    if !query.is_empty() {
                        let matches: Vec<IssueItem> = self
                            .open_issues
                            .iter()
                            .filter(|i| i.number.to_string().starts_with(&query) || i.title.to_lowercase().contains(&query))
                            .take(6)
                            .cloned()
                            .collect();
                        body = body.child(div().flex().flex_col().children(matches.into_iter().enumerate().map(|(i, issue)| {
                            let text = format!("{} #{}  {}", issue.repo_name, issue.number, issue.title);
                            div()
                                .id(("parent", i))
                                .px_2()
                                .py_0p5()
                                .rounded_md()
                                .text_sm()
                                .cursor_pointer()
                                .hover(|s| s.bg(theme.row_selected))
                                .child(text)
                                .on_click(cx.listener(move |form, _: &ClickEvent, _, cx| {
                                    form.parent = Some(issue.clone());
                                    cx.notify();
                                }))
                        })));
                    }
                }

                // Board and its fields.
                let boards = self.options.as_ref().map(|o| o.boards.clone()).unwrap_or_default();
                if !boards.is_empty() {
                    body = body.child(label("Board")).child(
                        row()
                            .child(chip("board-none".into(), "None".into(), self.board.is_none()).on_click(cx.listener(|form, _: &ClickEvent, _, cx| form.pick_board(None, cx))))
                            .children(boards.into_iter().enumerate().map(|(i, board)| {
                                let on = self.board.as_ref().is_some_and(|b| b.id == board.id);
                                chip(SharedString::from(format!("board-{i}")), board.title.clone(), on)
                                    .on_click(cx.listener(move |form, _: &ClickEvent, _, cx| form.pick_board(Some(board.clone()), cx)))
                            })),
                    );
                    match (&self.board, &self.fields) {
                        (Some(_), None) => body = body.child(note("Reading the board's fields…")),
                        (Some(_), Some(fields)) => {
                            for (f, field_) in fields.iter().enumerate() {
                                let picked = self.field_values.get(&field_.id).cloned();
                                let field_id = field_.id.clone();
                                body = body.child(label(&field_.name)).child(
                                    row()
                                        .child(chip(SharedString::from(format!("field-{f}-none")), "None".into(), picked.is_none()).on_click(cx.listener({
                                            let field_id = field_id.clone();
                                            move |form, _: &ClickEvent, _, cx| {
                                                form.field_values.remove(&field_id);
                                                cx.notify();
                                            }
                                        })))
                                        .children(field_.options.iter().enumerate().map(|(o, (option, name))| {
                                            let on = picked.as_deref() == Some(option.as_str());
                                            let (field_id, option) = (field_id.clone(), option.clone());
                                            chip(SharedString::from(format!("field-{f}-{o}")), name.clone(), on).on_click(cx.listener(move |form, _: &ClickEvent, _, cx| {
                                                form.field_values.insert(field_id.clone(), option.clone());
                                                cx.notify();
                                            }))
                                        })),
                                );
                            }
                        }
                        _ => {}
                    }
                }
            }
            Step::Review | Step::Working => {
                let done = self.steps.lock().map(|s| s.clone()).unwrap_or_default();
                if let Some(plan) = &self.plan {
                    body = body.child(label(if self.step == Step::Working { "Sending to GitHub" } else { "This will be sent to GitHub, as you" }));
                    body = body.child(div().flex().flex_col().gap_1().children(plan.lines().into_iter().map(|line| div().text_sm().child(format!("•  {line}")))));
                    if let (false, Some(harness)) = (plan.images.is_empty(), &plan.harness) {
                        body = body.child(note(&crate::issue_parts::audience(harness, &plan.repo)));
                    }
                    if !plan.body.is_empty() {
                        body = body.child(label("Description")).child(
                            div().p_3().rounded_md().border_1().border_color(theme.border).child(crate::markdown::markdown("new-issue-preview", &plan.body, &theme)),
                        );
                    }
                }
                if !done.is_empty() {
                    body = body.child(label("Done")).child(div().flex().flex_col().children(done.into_iter().map(|line| div().text_sm().child(format!("✓  {line}")))));
                }
            }
        }

        let pending_images = self.plan.as_ref().map_or(0, |p| p.images.iter().filter(|(id, ..)| !p.committed.contains_key(id)).count());
        let create_label = match pending_images {
            0 => "Create on GitHub  ⌘↩".to_string(),
            1 => "Commit 1 Image and Create on GitHub  ⌘↩".to_string(),
            n => format!("Commit {n} Images and Create on GitHub  ⌘↩"),
        };
        let actions = match self.step {
            Step::Edit => div()
                .flex()
                .flex_row()
                .gap_2()
                .child(button("new-issue-cancel", "Discard".into(), false).on_click(cx.listener(|form, _: &ClickEvent, _, cx| form.cancel(cx))))
                .child(button("new-issue-review", "Review  ⌘↩".into(), true).on_click(cx.listener(|form, _: &ClickEvent, _, cx| form.review(cx)))),
            Step::Review => div()
                .flex()
                .flex_row()
                .gap_2()
                .when(self.made.is_none(), |d| {
                    d.child(button("new-issue-edit", "Edit".into(), false).on_click(cx.listener(|form, _: &ClickEvent, _, cx| {
                        form.step = Step::Edit;
                        form.error = None;
                        cx.notify();
                    })))
                    .child(button("new-issue-create", create_label, true).on_click(cx.listener(|form, _: &ClickEvent, _, cx| form.send(cx))))
                })
                .when(self.made.is_some(), |d| d.child(button("new-issue-done", "Close".into(), true).on_click(cx.listener(|form, _: &ClickEvent, _, cx| form.cancel(cx))))),
            Step::Working => div().child(note("Creating…")),
        };
        let back = format!("‹ {}", self.back_title);
        let header = div()
            .h(px(44.))
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .gap_3()
            .px_4()
            .border_b_1()
            .border_color(theme.border)
            .child(
                div()
                    .id("new-issue-back")
                    .px_2()
                    .py_0p5()
                    .rounded_md()
                    .cursor_pointer()
                    .text_color(theme.selected)
                    .hover(|s| s.bg(theme.row_selected))
                    .on_click(cx.listener(|_, _: &ClickEvent, _, cx| cx.emit(NewIssueEvent::Back)))
                    .child(back),
            )
            .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(if self.step == Step::Edit { "New Issue" } else { "Review New Issue" }))
            .child(div().text_xs().text_color(theme.secondary).child(self.org.clone()))
            .child(div().flex_1())
            .child(note("Nothing's sent to GitHub until you press Create on GitHub."))
            .child(actions);
        let issue_column = div()
            .id("new-issue-fields")
            .flex_1()
            .min_w_0()
            .h_full()
            .overflow_y_scroll()
            .child(
                div()
                    .max_w(px(820.))
                    .mx_auto()
                    .p_5()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .when_some(self.error.clone(), |d, e| d.child(div().text_sm().text_color(theme.critical()).child(e)))
                    .child(body),
            );

        div()
            .id("new-issue")
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            // Pictures and image files on the clipboard attach before the
            // field under the cursor sees ⌘V; text pastes as usual.
            .capture_key_down(cx.listener(|form, event: &KeyDownEvent, window, cx| {
                if form.step == Step::Edit && event.keystroke.key == "v" && event.keystroke.modifiers.platform && form.paste_images(window, cx) {
                    cx.stop_propagation();
                }
            }))
            .on_drop(cx.listener(|form, paths: &gpui::ExternalPaths, window, cx| {
                if form.step == Step::Edit {
                    form.add_paths(paths.paths(), window, cx);
                }
            }))
            .on_key_down(cx.listener(|form, event: &KeyDownEvent, window, cx| {
                if event.keystroke.key == "escape" {
                    cx.stop_propagation();
                    if form.step == Step::Review && form.made.is_none() {
                        form.step = Step::Edit;
                        cx.notify();
                    } else if form.step == Step::Edit {
                        cx.emit(NewIssueEvent::Back);
                    } else {
                        form.cancel(cx);
                    }
                } else if event.keystroke.key == "enter" && event.keystroke.modifiers.alt && form.step == Step::Edit {
                    cx.stop_propagation();
                    form.draft(window, cx);
                } else if event.keystroke.key == "enter" && event.keystroke.modifiers.platform {
                    cx.stop_propagation();
                    match form.step {
                        Step::Edit => form.review(cx),
                        Step::Review => form.send(cx),
                        Step::Working => {}
                    }
                }
            }))
            .child(header)
            .child(div().flex_1().min_h_0().flex().flex_row().children(claude_column).child(issue_column))
    }
}
