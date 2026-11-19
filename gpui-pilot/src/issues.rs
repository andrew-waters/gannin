//! The Issues page, one list with the filter bar from `IssueFilterBar`
//! (search, Assignee, Author, Repository, Label, Board, Field and Milestone, and the
//! state), read from the pilot's issue store, which its own sync fills
//! (`StoredIssues/<org>.json` in the org's harness `.gannin-cache/`, Gannin's shape). New
//! Issue at the end of the filter bar opens the form (`new_issue.rs`). Not on a board
//! is a Board filter here rather than a page of its own. Rows are a
//! virtualised `uniform_list`, so only those on screen are built.
//! Left out: Me (there's no signed-in viewer), sub-issue nesting, avatars,
//! hidden issues and team filtering.

use crate::avatars::{avatar, stack};
use crate::charts::Theme;
use crate::format::thousands;
use chrono::{DateTime, Utc};
use gpui::{
    anchored, deferred, div, prelude::*, px, uniform_list, ClickEvent, Context, EventEmitter, FocusHandle, FontWeight,
    KeyDownEvent, MouseDownEvent, SharedString, Subscription, Window,
};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::ops::Range;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

// MARK: - The stored shape

/// `SharedIssueStore.currentFormat`.
const CURRENT_FORMAT: i64 = 1;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct File {
    format_version: i64,
    issues: HashMap<String, Stored>,
}

#[derive(Deserialize)]
struct Stored {
    core: Core,
    history: Option<History>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Core {
    id: String,
    number: i64,
    title: String,
    url: String,
    repo: String,
    author: Option<Person>,
    created_at: DateTime<Utc>,
    closed_at: Option<DateTime<Utc>>,
    #[serde(default)]
    updated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    assignees: Vec<Person>,
    #[serde(default)]
    labels: Vec<Label>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Person {
    login: String,
    name: Option<String>,
    avatar_url: Option<String>,
}

impl Person {
    fn display(&self) -> String {
        self.name.clone().filter(|n| !n.is_empty()).unwrap_or_else(|| self.login.clone())
    }
}

#[derive(Deserialize)]
struct Label {
    name: String,
    /// GitHub's six-digit hex.
    color: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct History {
    issue_type: Option<String>,
    milestone: Option<String>,
    state_reason: Option<String>,
    #[serde(rename = "parentID")]
    parent_id: Option<String>,
    #[serde(default)]
    linked_pull_requests: Vec<LinkedPr>,
    #[serde(default)]
    mentioned_in_pull_requests: Option<Vec<LinkedPr>>,
    #[serde(default)]
    project_fields: Vec<ProjectFields>,
    #[serde(default)]
    status_changes: Vec<StatusChange>,
    #[serde(default)]
    assigned_at: Vec<DateTime<Utc>>,
    #[serde(default)]
    reopened_at: Vec<DateTime<Utc>>,
    #[serde(default)]
    sub_issues_added_at: Vec<DateTime<Utc>>,
}

/// A move on a board (`IssueStatusChange`).
#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct StatusChange {
    pub at: DateTime<Utc>,
    pub status: String,
    pub project_number: Option<i64>,
    pub project_title: Option<String>,
}

/// A pull request linked to or mentioning the issue (`IssueLinkedPullRequest`).
#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct LinkedPr {
    pub number: i64,
    pub url: String,
    pub created_at: DateTime<Utc>,
    pub merged_at: Option<DateTime<Utc>>,
    pub state: String,
    /// When it's in another repo than the issue.
    pub repo: Option<String>,
    /// Days with commits or reviews.
    #[serde(default)]
    pub activity_at: Vec<DateTime<Utc>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProjectFields {
    project_title: String,
    #[serde(default)]
    values: HashMap<String, serde_json::Value>,
}

/// A board field's value as `IssueFieldValue` encodes it: its text, and
/// for fields picked from options (single and multi select, iterations)
/// the choices with a key for the board's order.
fn field_value(value: &serde_json::Value) -> Option<(String, Vec<(String, i64)>)> {
    let (kind, inner) = value.as_object()?.iter().next()?;
    let payload = inner.get("_0");
    match kind.as_str() {
        "option" => {
            let name = inner.get("name")?.as_str()?.to_string();
            let position = inner.get("position").and_then(|p| p.as_i64()).unwrap_or(0);
            Some((name.clone(), vec![(name, position)]))
        }
        "iteration" => {
            let title = inner.get("title")?.as_str()?.to_string();
            let start = inner
                .get("start")
                .and_then(|s| s.as_str())
                .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                .map_or(0, |d| d.timestamp());
            Some((title.clone(), vec![(title, start)]))
        }
        "options" => {
            let names: Vec<String> = payload?.as_array()?.iter().filter_map(|n| n.as_str().map(str::to_string)).collect();
            let choices = names.iter().enumerate().map(|(i, n)| (n.clone(), i as i64)).collect();
            Some((names.join(", "), choices))
        }
        "text" => Some((payload?.as_str()?.to_string(), Vec::new())),
        "number" => {
            let number = payload?.as_f64()?;
            let text = if number.fract() == 0.0 && number.abs() < 1e15 { format!("{}", number as i64) } else { number.to_string() };
            Some((text, Vec::new()))
        }
        "date" => {
            let date = DateTime::parse_from_rfc3339(payload?.as_str()?).ok()?;
            Some((date.format("%-d %b %Y").to_string(), Vec::new()))
        }
        _ => None,
    }
}

// MARK: - Rows

/// A value an issue has for a board field picked from options.
#[derive(Clone)]
pub struct FieldChoice {
    pub field: String,
    pub value: String,
    /// The board's order: an option's position, an iteration's start.
    pub order: i64,
}

/// One issue, flattened for the table and the drawer.
#[derive(Clone)]
pub struct IssueItem {
    pub id: String,
    pub number: i64,
    pub title: String,
    pub url: String,
    pub repo: String,
    pub repo_name: String,
    pub author: Option<String>,
    pub author_login: Option<String>,
    pub assignees: Vec<String>,
    pub assignee_logins: Vec<String>,
    /// Each assignee's avatar URL, as the store has it.
    pub assignee_avatars: Vec<Option<String>>,
    pub author_avatar: Option<String>,
    pub labels: Vec<String>,
    /// Each label's colour, as GitHub's hex.
    pub label_colors: Vec<Option<String>>,
    pub status_changes: Vec<StatusChange>,
    pub linked_prs: Vec<LinkedPr>,
    pub mentioned_prs: Vec<LinkedPr>,
    pub assigned_at: Vec<DateTime<Utc>>,
    pub reopened_at: Vec<DateTime<Utc>>,
    pub sub_issues_added_at: Vec<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: Option<DateTime<Utc>>,
    pub closed_at: Option<DateTime<Utc>>,
    pub not_planned: bool,
    /// Its sub-issues closed, and in all, among those in the store.
    pub sub_issues_done: usize,
    pub sub_issues: usize,
    pub issue_type: Option<String>,
    pub milestone: Option<String>,
    pub linked: usize,
    /// The parent issue's node ID, when it's a sub-issue.
    pub parent_id: Option<String>,
    /// Each board it's on, with its field values by name.
    pub boards: Vec<(String, Vec<(String, String)>)>,
    pub field_choices: Vec<FieldChoice>,
    /// Its Status on each board it has one on, with the board's order for
    /// that value.
    pub statuses: Vec<(String, i64)>,
    /// The issue history has fetched it, so `boards` is known.
    pub has_history: bool,
    /// Its description and recent comments, lowercased, for the search:
    /// empty until the sync or its drawer has fetched them.
    pub text: String,
}

impl IssueItem {
    pub fn is_open(&self) -> bool {
        self.closed_at.is_none()
    }

    /// A board field's value on the first board that has it.
    fn field_text(&self, field: &str) -> Option<&str> {
        self.boards.iter().find_map(|(_, values)| values.iter().find(|(name, _)| name == field).map(|(_, value)| value.as_str()))
    }

    fn choices(&self, field: &str) -> Vec<&str> {
        self.field_choices.iter().filter(|c| c.field == field).map(|c| c.value.as_str()).collect()
    }

    fn from(stored: Stored) -> Self {
        let core = stored.core;
        let history = stored.history;
        let mut boards = Vec::new();
        let mut field_choices = Vec::new();
        let mut statuses = Vec::new();
        for board in history.iter().flat_map(|h| &h.project_fields) {
            let mut values = Vec::new();
            for (name, value) in &board.values {
                let Some((text, choices)) = field_value(value) else { continue };
                if name.eq_ignore_ascii_case("status") {
                    statuses.push((text.clone(), choices.first().map_or(i64::MAX, |c| c.1)));
                }
                values.push((name.clone(), text));
                field_choices.extend(choices.into_iter().map(|(value, order)| FieldChoice { field: name.clone(), value, order }));
            }
            values.sort();
            boards.push((board.project_title.clone(), values));
        }
        Self {
            repo_name: core.repo.rsplit('/').next().unwrap_or(&core.repo).to_string(),
            author: core.author.as_ref().map(Person::display),
            author_login: core.author.as_ref().map(|p| p.login.clone()),
            assignees: core.assignees.iter().map(Person::display).collect(),
            assignee_logins: core.assignees.iter().map(|p| p.login.clone()).collect(),
            assignee_avatars: core.assignees.iter().map(|p| p.avatar_url.clone()).collect(),
            author_avatar: core.author.as_ref().and_then(|p| p.avatar_url.clone()),
            label_colors: core.labels.iter().map(|l| l.color.clone()).collect(),
            labels: core.labels.into_iter().map(|l| l.name).collect(),
            status_changes: history.as_ref().map(|h| h.status_changes.clone()).unwrap_or_default(),
            linked_prs: history.as_ref().map(|h| h.linked_pull_requests.clone()).unwrap_or_default(),
            mentioned_prs: history.as_ref().and_then(|h| h.mentioned_in_pull_requests.clone()).unwrap_or_default(),
            assigned_at: history.as_ref().map(|h| h.assigned_at.clone()).unwrap_or_default(),
            reopened_at: history.as_ref().map(|h| h.reopened_at.clone()).unwrap_or_default(),
            sub_issues_added_at: history.as_ref().map(|h| h.sub_issues_added_at.clone()).unwrap_or_default(),
            not_planned: history.as_ref().and_then(|h| h.state_reason.as_deref()).is_some_and(|r| r.eq_ignore_ascii_case("not_planned")),
            issue_type: history.as_ref().and_then(|h| h.issue_type.clone()),
            milestone: history.as_ref().and_then(|h| h.milestone.clone()),
            linked: history.as_ref().map_or(0, |h| h.linked_pull_requests.len()),
            parent_id: history.as_ref().and_then(|h| h.parent_id.clone()),
            has_history: history.is_some(),
            boards,
            field_choices,
            statuses,
            id: core.id,
            number: core.number,
            title: core.title,
            url: core.url,
            repo: core.repo,
            created_at: core.created_at,
            updated_at: core.updated_at,
            closed_at: core.closed_at,
            sub_issues_done: 0,
            sub_issues: 0,
            text: String::new(),
        }
    }
}

fn cache_path(org: &str) -> PathBuf {
    crate::cache::path(crate::cache::Kind::Issues, org)
}

pub(crate) fn load(org: &str) -> Result<Vec<IssueItem>, String> {
    // Nothing synced yet (a fresh install) is an empty cache, not an error.
    let bytes = match std::fs::read(cache_path(org)) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.to_string()),
    };
    let file: File = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
    if file.format_version != CURRENT_FORMAT {
        return Err(format!("Store format {} isn't {CURRENT_FORMAT}", file.format_version));
    }
    Ok(file.issues.into_values().map(IssueItem::from).collect())
}

/// One issue from the store, as the list would show it.
pub(crate) fn load_one(org: &str, id: &str) -> Option<IssueItem> {
    let bytes = std::fs::read(cache_path(org)).ok()?;
    let mut file: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    let entry = file["issues"].get_mut(id)?.take();
    serde_json::from_value::<Stored>(entry).ok().map(IssueItem::from)
}

// MARK: - Filters

/// Assignee values: a login, or these.
const UNASSIGNED: &str = "";
const ANYONE_ASSIGNED: &str = "*";
/// The milestone value for issues in none.
const NO_MILESTONE: &str = "";
/// The board value for issues the history has seen on none.
const NO_BOARD: &str = "";
/// The status value for issues with no Status on any board.
const NO_STATUS: &str = "";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Key {
    /// Board Status, on any board the issue is on.
    Status,
    Assignee,
    /// Who opened the issue.
    Author,
    Repository,
    Label,
    Board,
    Milestone,
}

impl Key {
    fn title(self) -> &'static str {
        match self {
            Key::Status => "Status",
            Key::Assignee => "Assignee",
            Key::Author => "Author",
            Key::Repository => "Repository",
            Key::Label => "Label",
            Key::Board => "Board",
            Key::Milestone => "Milestone",
        }
    }
}

#[derive(Clone, PartialEq, Eq, Debug)]
enum Menu {
    State,
    Key(Key),
    Field,
    Columns,
}

/// A state the list can show; several can be picked, and none picked
/// shows every issue.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug, serde::Serialize, serde::Deserialize)]
enum StateFilter {
    Open,
    /// Closed as completed: not planned has its own.
    Closed,
    NotPlanned,
}

impl StateFilter {
    const ALL: [StateFilter; 3] = [StateFilter::Open, StateFilter::Closed, StateFilter::NotPlanned];

    fn title(self) -> &'static str {
        match self {
            StateFilter::Open => "Open",
            StateFilter::Closed => "Closed",
            StateFilter::NotPlanned => "Not planned",
        }
    }

    fn holds(self, issue: &IssueItem) -> bool {
        match self {
            StateFilter::Open => issue.is_open(),
            StateFilter::Closed => !issue.is_open() && !issue.not_planned,
            StateFilter::NotPlanned => !issue.is_open() && issue.not_planned,
        }
    }
}

/// As `IssueFilters`: several values of each, any matching; across board
/// fields, every field matching.
#[derive(Default, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Filters {
    search: String,
    assignees: BTreeSet<String>,
    authors: BTreeSet<String>,
    repositories: BTreeSet<String>,
    labels: BTreeSet<String>,
    boards: BTreeSet<String>,
    statuses: BTreeSet<String>,
    milestones: BTreeSet<String>,
    /// (field, value); an empty value is an issue with none.
    fields: BTreeSet<(String, String)>,
    /// Menus whose picks leave issues out rather than keep them, by
    /// title ("Field" for board fields).
    excluding: BTreeSet<String>,
    /// The window's Filter box, matched as the search is: never saved.
    #[serde(skip)]
    outer: String,
}

impl Filters {
    fn excludes(&self, menu: &str) -> bool {
        self.excluding.contains(menu)
    }

    fn is_narrowed(&self) -> bool {
        !self.search.is_empty() || !self.outer.trim().is_empty() || Key::all().iter().any(|k| !self.values(*k).is_empty()) || !self.fields.is_empty()
    }

    fn values(&self, key: Key) -> &BTreeSet<String> {
        match key {
            Key::Assignee => &self.assignees,
            Key::Author => &self.authors,
            Key::Repository => &self.repositories,
            Key::Label => &self.labels,
            Key::Board => &self.boards,
            Key::Status => &self.statuses,
            Key::Milestone => &self.milestones,
        }
    }

    fn values_mut(&mut self, key: Key) -> &mut BTreeSet<String> {
        match key {
            Key::Assignee => &mut self.assignees,
            Key::Author => &mut self.authors,
            Key::Repository => &mut self.repositories,
            Key::Label => &mut self.labels,
            Key::Board => &mut self.boards,
            Key::Status => &mut self.statuses,
            Key::Milestone => &mut self.milestones,
        }
    }

    /// Everything but the state, less `except` or the field `except_field`,
    /// so a menu counts what picking among its own values would give.
    fn matches(&self, issue: &IssueItem, except: Option<Key>, except_field: Option<&str>) -> bool {
        for key in Key::all() {
            let picked = self.values(key);
            if Some(key) == except || picked.is_empty() {
                continue;
            }
            let hit = picked.iter().any(|value| match key {
                Key::Assignee => match value.as_str() {
                    UNASSIGNED => issue.assignee_logins.is_empty(),
                    ANYONE_ASSIGNED => !issue.assignee_logins.is_empty(),
                    login => issue.assignee_logins.iter().any(|l| l == login),
                },
                Key::Author => issue.author_login.as_deref() == Some(value.as_str()),
                Key::Repository => issue.repo == *value,
                Key::Label => issue.labels.contains(value),
                Key::Board if value == NO_BOARD => issue.has_history && issue.boards.is_empty(),
                Key::Board => issue.boards.iter().any(|(title, _)| title == value),
                Key::Status if value == NO_STATUS => issue.statuses.is_empty(),
                Key::Status => issue.statuses.iter().any(|(name, _)| name == value),
                Key::Milestone => issue.milestone.as_deref().unwrap_or(NO_MILESTONE) == value,
            });
            // Included, it must have one; excluded, none.
            if hit == self.excludes(key.title()) {
                return false;
            }
        }
        let mut by_field: HashMap<&str, Vec<&str>> = HashMap::new();
        for (field, value) in &self.fields {
            if Some(field.as_str()) != except_field {
                by_field.entry(field).or_default().push(value);
            }
        }
        let excluding_fields = self.excludes("Field");
        for (field, picks) in by_field {
            let have = issue.choices(field);
            let hit = picks.iter().any(|value| if value.is_empty() { have.is_empty() } else { have.contains(value) });
            if hit == excluding_fields {
                return false;
            }
        }
        self.matches_search(issue)
    }

    /// Every word typed, here or in the window's Filter box, is in the
    /// title, the repo, `#123`, a person's login or name, a label, or the
    /// description or a recent comment (`IssueSearch`, with the text).
    fn matches_search(&self, issue: &IssueItem) -> bool {
        let words: Vec<String> = self.search.split_whitespace().chain(self.outer.split_whitespace()).map(str::to_lowercase).collect();
        if words.is_empty() {
            return true;
        }
        let number = issue.number.to_string();
        let hash = format!("#{number}");
        let mut fields: Vec<&str> = vec![&issue.title, &issue.repo, &hash, &number];
        fields.extend(issue.assignees.iter().map(String::as_str));
        fields.extend(issue.assignee_logins.iter().map(String::as_str));
        fields.extend(issue.author.as_deref());
        fields.extend(issue.author_login.as_deref());
        fields.extend(issue.labels.iter().map(String::as_str));
        let fields: Vec<String> = fields.iter().map(|f| f.to_lowercase()).collect();
        words.iter().all(|word| fields.iter().any(|f| f.contains(word.as_str())) || issue.text.contains(word.as_str()))
    }
}

impl Key {
    fn all() -> [Key; 7] {
        [Key::Status, Key::Assignee, Key::Author, Key::Repository, Key::Label, Key::Board, Key::Milestone]
    }
}

/// A value a menu offers, with how many issues it would give.
struct Choice {
    value: String,
    title: String,
    count: usize,
}

/// "a, b", or "a, b and 3 more".
pub(crate) fn summary(titles: &[String], limit: usize) -> String {
    if titles.len() > limit {
        format!("{} and {} more", titles[..limit].join(", "), titles.len() - limit)
    } else {
        titles.join(", ")
    }
}

// MARK: - The page

/// A column the list can show. Which ones, and in what order, are the
/// person's choice (kept in their own state, not the org's); Title always
/// shows, since it holds the tree.
#[derive(Clone, PartialEq, Eq, Hash, Debug, serde::Serialize, serde::Deserialize)]
enum Column {
    State,
    Status,
    Title,
    Repository,
    Number,
    Author,
    Assignees,
    Labels,
    Type,
    Milestone,
    Boards,
    Linked,
    SubIssues,
    Opened,
    Updated,
    Closed,
    /// A board field by name: its value on the first board with one.
    Field(String),
}

impl Column {
    fn defaults() -> Vec<Column> {
        use Column::*;
        vec![State, Status, SubIssues, Title, Repository, Number, Author, Assignees, Linked, Opened, Closed]
    }

    /// Every built-in column, in the order the Columns menu offers them.
    fn built_in() -> Vec<Column> {
        use Column::*;
        vec![State, Status, Title, Repository, Number, Author, Assignees, Labels, Type, Milestone, Boards, Linked, SubIssues, Opened, Updated, Closed]
    }

    fn title(&self) -> String {
        match self {
            Column::State => "State",
            Column::Status => "Status",
            Column::Title => "Title",
            Column::Repository => "Repository",
            Column::Number => "Number",
            Column::Author => "Author",
            Column::Assignees => "Assignees",
            Column::Labels => "Labels",
            Column::Type => "Type",
            Column::Milestone => "Milestone",
            Column::Boards => "Boards",
            Column::Linked => "Linked",
            Column::SubIssues => "Sub-issues",
            Column::Opened => "Opened",
            Column::Updated => "Updated",
            Column::Closed => "Closed",
            Column::Field(name) => return name.clone(),
        }
        .to_string()
    }

    /// Nil for the flexible Title column.
    fn width(&self) -> Option<f32> {
        Some(match self {
            Column::Title => return None,
            Column::State => 92.,
            Column::Status => 130.,
            Column::Repository => 120.,
            Column::Number => 64.,
            Column::Author => 64.,
            Column::Assignees => 100.,
            Column::Labels | Column::Boards => 150.,
            Column::Type => 100.,
            Column::Milestone | Column::Field(_) => 120.,
            Column::Linked => 56.,
            Column::SubIssues => 90.,
            Column::Opened | Column::Updated | Column::Closed => 96.,
        })
    }

    /// Its first sort puts the most or newest first.
    fn sorts_descending(&self) -> bool {
        matches!(self, Column::Opened | Column::Updated | Column::Closed | Column::Linked | Column::SubIssues)
    }

    /// Its name in saved widths; board fields are kept apart from the
    /// built-in columns, so a field called Status has its own.
    fn key(&self) -> String {
        match self {
            Column::Field(name) => format!("field:{name}"),
            other => other.title(),
        }
    }

    fn id(&self) -> SharedString {
        SharedString::from(format!("column-{}", self.title()))
    }
}

/// A hover label, for avatars shown without names.
pub(crate) struct Tooltip(pub(crate) String);

impl Render for Tooltip {
    fn render(&mut self, window: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        div()
            .px_2()
            .py_1()
            .rounded_md()
            .bg(theme.popover)
            .border_1()
            .border_color(theme.border)
            .shadow_lg()
            .text_xs()
            .text_color(theme.fg)
            .font_family(".SystemUIFont")
            .child(self.0.clone())
    }
}

/// A column header being dragged to a new place.
#[derive(Clone)]
struct DraggedColumn(Column);

/// What follows the pointer while a header is dragged.
pub(crate) struct ColumnDrag(pub(crate) String);

impl Render for ColumnDrag {
    fn render(&mut self, window: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        div()
            .px_2()
            .py_0p5()
            .rounded_md()
            .bg(theme.popover)
            .border_1()
            .border_color(theme.selected)
            .text_xs()
            .text_color(theme.fg)
            .shadow_lg()
            .child(self.0.clone())
    }
}

/// The columns saved, made sound: Title present once, no repeats.
fn sound_columns(columns: &[Column]) -> Vec<Column> {
    let mut seen = HashSet::new();
    let mut sound: Vec<Column> = columns.iter().filter(|c| seen.insert((*c).clone())).cloned().collect();
    if !sound.contains(&Column::Title) {
        sound.insert(0, Column::Title);
    }
    sound
}

/// The page's controls, restored on the next launch. The search isn't
/// kept, as in the Swift app.
#[derive(Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct IssuesSaved {
    /// Saved before states could be combined it was `state`, which is
    /// left unread.
    states: BTreeSet<StateFilter>,
    filters: Filters,
    sort: Column,
    descending: bool,
    /// Parents opened in the tree, by node ID.
    expanded: BTreeSet<String>,
    /// The parent whose sub-issues the list is showing, by node ID.
    scope: Option<String>,
    /// The columns shown, in order.
    columns: Vec<Column>,
    /// Widths the person has dragged columns to, by `Column::key`.
    widths: BTreeMap<String, f32>,
    /// The Sub-issues column has been added to saved columns from before
    /// it opened the tree. Missing in those, so false there.
    #[serde(default)]
    tree_column: bool,
}

impl IssuesSaved {
    /// For a new tab: these columns and order, with nothing filtered.
    pub fn fresh(&self) -> Self {
        Self { sort: self.sort.clone(), descending: self.descending, columns: self.columns.clone(), widths: self.widths.clone(), ..Self::default() }
    }
}

impl Default for IssuesSaved {
    fn default() -> Self {
        Self {
            states: BTreeSet::from([StateFilter::Open]),
            filters: Filters::default(),
            sort: Column::Opened,
            descending: true,
            expanded: BTreeSet::new(),
            scope: None,
            columns: Column::defaults(),
            widths: BTreeMap::new(),
            tree_column: true,
        }
    }
}

/// A row in the list: an issue, how deep in the tree it sits, and what it
/// needs drawn beside its title.
struct Row {
    index: usize,
    depth: usize,
    /// It has sub-issues among those listed, so it can open.
    opens: bool,
    /// Its sub-issues done and in all, whatever the filters.
    /// Where it belongs when its parent isn't the row above it.
    context: Option<String>,
}

/// How deep the tree goes, in case the store ever holds a loop.
const MAX_DEPTH: usize = 12;

/// A row was clicked; the workspace opens it in a drawer.
pub struct OpenIssue(pub IssueItem);

impl EventEmitter<OpenIssue> for IssuesPage {}

/// Work on This for each of these, picked together in the table.
pub struct WorkOnIssues(pub Vec<IssueItem>);

impl EventEmitter<WorkOnIssues> for IssuesPage {}

/// New Issue from the filter bar.
pub struct NewIssue;

impl EventEmitter<NewIssue> for IssuesPage {}

/// Add these to the schedule, as a sequence in the order picked.
pub struct ScheduleIssues(pub Vec<IssueItem>);

impl EventEmitter<ScheduleIssues> for IssuesPage {}

pub struct IssuesPage {
    org: Option<String>,
    issues: Arc<Vec<IssueItem>>,
    /// Each issue's sub-issues, as indexes into `issues`.
    children: Arc<HashMap<String, Vec<usize>>>,
    /// Indexes into `issues` by node ID.
    by_id: Arc<HashMap<String, usize>>,
    /// The rows shown: the tree when nothing narrows the list, every match
    /// on its own when something does.
    rows: Vec<Row>,
    /// Issues in the state picked, before the other filters.
    pool_count: usize,
    /// Issues the filters leave, whether shown or tucked under a parent.
    match_count: usize,
    expanded: BTreeSet<String>,
    /// The parent the list is showing the sub-issues of, and every issue
    /// beneath it.
    scope: Option<String>,
    scope_set: Option<Arc<HashSet<usize>>>,
    /// The project's repos, when one is picked.
    focus: Option<HashSet<String>>,
    states: BTreeSet<StateFilter>,
    filters: Filters,
    sort: (Column, bool),
    columns: Vec<Column>,
    widths: BTreeMap<String, f32>,
    /// A column edge being dragged: the column, where the drag began and
    /// the width then.
    resizing: Option<(Column, f32, f32)>,
    selected: Option<String>,
    /// Rows picked together (checkbox, Command or Shift), by issue id, and
    /// the row a Shift-click range starts from.
    picked: Vec<String>,
    anchor: Option<usize>,
    open_menu: Option<Menu>,
    /// The menu a click outside just closed, so the same click on its own
    /// button doesn't open it again.
    closed_menu: Option<(Menu, Instant)>,
    /// The board field opened in the Field menu.
    expanded_field: Option<String>,
    search_focus: FocusHandle,
    error: Option<String>,
    loading: bool,
    timings: String,
    generation: u64,
    _subscriptions: Vec<Subscription>,
}

const ROW_HEIGHT: f32 = 30.0;

impl IssuesPage {
    pub fn new(org: Option<String>, saved: &IssuesSaved, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search_focus = cx.focus_handle();
        let subscriptions = vec![
            cx.observe_window_appearance(window, |_, _, cx| cx.notify()),
            // Redraws the search field without its caret.
            cx.on_blur(&search_focus, window, |_, _, cx| cx.notify()),
        ];
        let mut page = Self {
            org,
            issues: Arc::new(Vec::new()),
            children: Arc::new(HashMap::new()),
            by_id: Arc::new(HashMap::new()),
            rows: Vec::new(),
            pool_count: 0,
            match_count: 0,
            expanded: saved.expanded.clone(),
            scope: saved.scope.clone(),
            scope_set: None,
            focus: None,
            states: saved.states.clone(),
            filters: Filters { search: String::new(), ..saved.filters.clone() },
            sort: (saved.sort.clone(), saved.descending),
            columns: {
                let mut columns = sound_columns(&saved.columns);
                if !saved.tree_column && !columns.contains(&Column::SubIssues) {
                    let at = columns.iter().position(|c| *c == Column::Title).unwrap_or(0);
                    columns.insert(at, Column::SubIssues);
                }
                columns
            },
            widths: saved.widths.clone(),
            resizing: None,
            selected: None,
            picked: Vec::new(),
            anchor: None,
            open_menu: None,
            closed_menu: None,
            expanded_field: None,
            search_focus,
            error: None,
            loading: false,
            timings: String::new(),
            generation: 0,
            _subscriptions: subscriptions,
        };
        page.load(cx);
        page
    }

    /// The window's Filter box, narrowing the list with the page's own
    /// search.
    pub fn set_outer(&mut self, text: &str, cx: &mut Context<Self>) {
        if self.filters.outer != text {
            self.filters.outer = text.to_string();
            self.refilter();
            cx.notify();
        }
    }

    pub fn set_org(&mut self, org: Option<String>, cx: &mut Context<Self>) {
        if org != self.org {
            self.org = org;
            self.selected = None;
            // Another org's repos, people and boards differ.
            self.filters = Filters { outer: std::mem::take(&mut self.filters.outer), ..Filters::default() };
            self.load(cx);
        }
    }

    fn load(&mut self, cx: &mut Context<Self>) {
        self.load_quietly(false, cx);
    }

    /// Reads the cache again after a sync, keeping what's shown until the
    /// new copy is in.
    pub fn reload(&mut self, cx: &mut Context<Self>) {
        self.load_quietly(true, cx);
    }

    fn load_quietly(&mut self, quiet: bool, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        self.generation += 1;
        let generation = self.generation;
        if !quiet {
            self.loading = true;
            self.error = None;
            self.issues = Arc::new(Vec::new());
            self.rows.clear();
        }
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let started = Instant::now();
                    let texts = crate::detail::search_texts(&org);
                    load(&org).map(|mut issues| {
                        for issue in &mut issues {
                            if let Some(text) = texts.get(&issue.id) {
                                issue.text = text.clone();
                            }
                        }
                        (issues, started.elapsed())
                    })
                })
                .await;
            this.update(cx, |page, cx| {
                if page.generation != generation {
                    return;
                }
                page.loading = false;
                page.error = result.as_ref().err().cloned();
                match result {
                    Ok((issues, elapsed)) => {
                        page.timings = format!("read {} issues in {} ms", thousands(issues.len()), elapsed.as_millis());
                        let mut issues = issues;
                        let mut children: HashMap<String, Vec<usize>> = HashMap::new();
                        let mut by_id = HashMap::new();
                        for (index, issue) in issues.iter().enumerate() {
                            by_id.insert(issue.id.clone(), index);
                            if let Some(parent) = &issue.parent_id {
                                children.entry(parent.clone()).or_default().push(index);
                            }
                        }
                        for (parent, kids) in &children {
                            if let Some(&p) = by_id.get(parent) {
                                let done = kids.iter().filter(|&&k| !issues[k].is_open()).count();
                                issues[p].sub_issues_done = done;
                                issues[p].sub_issues = kids.len();
                            }
                        }
                        page.issues = Arc::new(issues);
                        page.children = Arc::new(children);
                        page.by_id = Arc::new(by_id);
                        page.rescope();
                        page.refilter();
                    }
                    Err(_) => {}
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    pub fn saved(&self) -> IssuesSaved {
        IssuesSaved {
            states: self.states.clone(),
            filters: Filters { search: String::new(), ..self.filters.clone() },
            sort: self.sort.0.clone(),
            descending: self.sort.1,
            expanded: self.expanded.clone(),
            scope: self.scope.clone(),
            columns: self.columns.clone(),
            widths: self.widths.clone(),
            tree_column: true,
        }
    }

    /// Shows a parent's sub-issues as the list, or every issue for none.
    pub fn set_scope(&mut self, scope: Option<String>, cx: &mut Context<Self>) {
        self.scope = scope;
        self.rescope();
        self.refilter();
        cx.notify();
    }

    /// Works out which issues sit beneath the scope, dropping a scope the
    /// store no longer has.
    fn rescope(&mut self) {
        self.scope_set = None;
        let Some(scope) = self.scope.clone() else { return };
        if self.issues.is_empty() {
            return;
        }
        if !self.by_id.contains_key(&scope) {
            self.scope = None;
            return;
        }
        let mut beneath = HashSet::new();
        let mut frontier = vec![(scope, 0)];
        while let Some((id, depth)) = frontier.pop() {
            for &child in self.children.get(&id).map(Vec::as_slice).unwrap_or(&[]) {
                if depth < MAX_DEPTH && beneath.insert(child) {
                    frontier.push((self.issues[child].id.clone(), depth + 1));
                }
            }
        }
        self.scope_set = Some(Arc::new(beneath));
    }

    fn in_focus(&self, issue: &IssueItem) -> bool {
        self.focus.as_ref().is_none_or(|repos| repos.contains(&issue.repo))
    }

    /// Keeps the list to a project's repos, or every repo for none.
    pub fn set_focus(&mut self, focus: Option<Vec<String>>, cx: &mut Context<Self>) {
        let focus = focus.map(|repos| repos.into_iter().collect::<HashSet<_>>());
        if focus != self.focus {
            self.focus = focus;
            self.refilter();
            cx.notify();
        }
    }

    fn in_scope(&self, index: usize) -> bool {
        self.scope_set.as_ref().is_none_or(|set| set.contains(&index))
    }

    /// The scope and its parents up to the top, top first.
    fn scope_path(&self) -> Vec<&IssueItem> {
        let mut path = Vec::new();
        let mut next = self.scope.as_ref().and_then(|id| self.by_id.get(id));
        while let Some(&index) = next {
            if path.len() > MAX_DEPTH {
                break;
            }
            let issue = &self.issues[index];
            path.push(issue);
            next = issue.parent_id.as_ref().and_then(|id| self.by_id.get(id));
        }
        path.reverse();
        path
    }

    fn breadcrumb(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let path = self.scope_path();
        let last = path.len().saturating_sub(1);
        let crumb = |id: &'static str, index: usize, label: String, target: Option<String>, current: bool, cx: &mut Context<Self>| {
            div()
                .id((id, index))
                .max_w(px(360.))
                .truncate()
                .when(current, |d| d.font_weight(FontWeight::SEMIBOLD))
                .when(!current, |d| {
                    d.text_color(theme.selected).cursor_pointer().on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                        page.set_scope(target.clone(), cx)
                    }))
                })
                .child(label)
        };
        div()
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .px_4()
            .pt_3()
            .child(crumb("crumb-all", 0, "All issues".into(), None, false, cx))
            .children(path.iter().enumerate().map(|(i, issue)| {
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(div().text_color(theme.tertiary).child("›"))
                    .child(crumb("crumb", i, format!("#{} {}", issue.number, issue.title), Some(issue.id.clone()), i == last, cx))
            }))
    }

    /// For the tab: how many are listed, and of how many while filtered.
    pub fn tab_count(&self) -> Option<String> {
        if self.loading || self.error.is_some() {
            return None;
        }
        let count = self.match_count;
        Some(if count == self.pool_count {
            thousands(count)
        } else {
            format!("{} of {}", thousands(count), thousands(self.pool_count))
        })
    }

    pub fn issue(&self, id: &str) -> Option<IssueItem> {
        self.issues.iter().find(|i| i.id == id).cloned()
    }

    /// An issue by its repo and number.
    pub fn issue_by_number(&self, repo: &str, number: i64) -> Option<IssueItem> {
        self.issues.iter().find(|i| i.number == number && i.repo == repo).cloned()
    }

    /// Open issues assigned to `login`, recently updated first.
    pub fn assigned_to(&self, login: &str) -> Vec<IssueItem> {
        let mut assigned: Vec<IssueItem> =
            self.issues.iter().filter(|i| i.is_open() && i.assignee_logins.iter().any(|l| l == login)).cloned().collect();
        assigned.sort_by_key(|i| std::cmp::Reverse(i.updated_at.unwrap_or(i.created_at)));
        assigned
    }

    /// Its sub-issues, open ones first, then by number.
    pub fn sub_issues(&self, id: &str) -> Vec<IssueItem> {
        let mut children: Vec<IssueItem> = self.issues.iter().filter(|i| i.parent_id.as_deref() == Some(id)).cloned().collect();
        children.sort_by_key(|i| (!i.is_open(), i.number));
        children
    }

    fn in_state(&self, issue: &IssueItem) -> bool {
        self.states.is_empty() || self.states.iter().any(|state| state.holds(issue))
    }

    /// The issues in the state picked and the scope, before the other
    /// filters.
    fn pool(&self) -> impl Iterator<Item = &IssueItem> {
        self.issues
            .iter()
            .enumerate()
            .filter(|(index, issue)| self.in_scope(*index) && self.in_focus(issue) && self.in_state(issue))
            .map(|(_, issue)| issue)
    }

    fn refilter(&mut self) {
        let issues = self.issues.clone();
        self.pool_count = self.pool().count();
        let mut matching: Vec<usize> =
            (0..issues.len())
                .filter(|&i| self.in_scope(i) && self.in_focus(&issues[i]) && self.in_state(&issues[i]) && self.filters.matches(&issues[i], None, None))
                .collect();
        self.match_count = matching.len();
        let sort = self.sort.clone();
        let order = |a: &usize, b: &usize| compare(&issues[*a], &issues[*b], &sort);

        // Narrowed, every match is its own row, so none hides under a
        // collapsed parent; each says where it belongs instead. One opened
        // shows all its sub-issues beneath it, filtered or not, so an epic
        // found by a search still opens.
        if self.filters.is_narrowed() {
            matching.sort_by(order);
            let mut rows = Vec::new();
            for index in matching {
                let children: Vec<usize> = {
                    let mut c: Vec<usize> = issues.iter().enumerate().filter(|(_, i)| i.parent_id.as_deref() == Some(issues[index].id.as_str())).map(|(i, _)| i).collect();
                    c.sort_by(order);
                    c
                };
                rows.push(Row { index, depth: 0, opens: !children.is_empty(), context: self.parent_label(&issues[index]) });
                if self.expanded.contains(&issues[index].id) {
                    rows.extend(children.into_iter().map(|c| Row { index: c, depth: 1, opens: false, context: None }));
                }
            }
            self.rows = rows;
            return;
        }

        // Otherwise sub-issues sit under their parent; one whose parent
        // isn't listed comes up to the top, saying where it belongs.
        let listed: std::collections::HashSet<usize> = matching.iter().copied().collect();
        let listed_children = |index: usize| -> Vec<usize> {
            let mut children: Vec<usize> =
                self.children.get(&issues[index].id).map(|c| c.iter().copied().filter(|c| listed.contains(c)).collect()).unwrap_or_default();
            children.sort_by(order);
            children
        };
        let mut roots: Vec<usize> = matching
            .iter()
            .copied()
            .filter(|&i| issues[i].parent_id.as_ref().and_then(|p| self.by_id.get(p)).is_none_or(|p| !listed.contains(p)))
            .collect();
        roots.sort_by(order);
        let mut rows = Vec::new();
        let mut stack: Vec<(usize, usize)> = roots.into_iter().rev().map(|i| (i, 0)).collect();
        while let Some((index, depth)) = stack.pop() {
            let children = listed_children(index);
            rows.push(Row {
                index,
                depth,
                opens: !children.is_empty(),
                context: if depth == 0 { self.parent_label(&issues[index]) } else { None },
            });
            if depth < MAX_DEPTH && self.expanded.contains(&issues[index].id) {
                stack.extend(children.into_iter().rev().map(|c| (c, depth + 1)));
            }
        }
        self.rows = rows;
    }

    /// "in #4120 Impersonation hardening", for a sub-issue shown away from
    /// its parent.
    fn parent_label(&self, issue: &IssueItem) -> Option<String> {
        let parent = issue.parent_id.as_ref()?;
        // The breadcrumb already says it.
        if self.scope.as_ref() == Some(parent) {
            return None;
        }
        Some(match self.by_id.get(parent) {
            Some(&p) => format!("in #{} {}", self.issues[p].number, self.issues[p].title),
            None => "in a parent issue Gannin hasn't fetched".into(),
        })
    }

    fn toggle_expanded(&mut self, id: String, cx: &mut Context<Self>) {
        if !self.expanded.remove(&id) {
            self.expanded.insert(id);
        }
        self.refilter();
        cx.notify();
    }

    /// Every parent with sub-issues listed, open; or all closed.
    fn expand_all(&mut self, open: bool, cx: &mut Context<Self>) {
        if open {
            let parents: Vec<String> = self.children.keys().cloned().collect();
            self.expanded.extend(parents);
        } else {
            self.expanded.clear();
        }
        self.refilter();
        cx.notify();
    }
}

/// Two issues in the order of the column sorted by.
fn compare(a: &IssueItem, b: &IssueItem, (column, descending): &(Column, bool)) -> std::cmp::Ordering {
    // Issues with a value first, then those without.
    fn present<T: Ord>(a: Option<T>, b: Option<T>) -> std::cmp::Ordering {
        match (a, b) {
            (Some(a), Some(b)) => a.cmp(&b),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => std::cmp::Ordering::Equal,
        }
    }
    let field_key = |issue: &IssueItem, name: &str| {
        let order = issue.field_choices.iter().find(|c| c.field == name).map_or(i64::MAX, |c| c.order);
        issue.field_text(name).map(|text| (order, text.to_lowercase()))
    };
    let order = match column {
        Column::Labels => present(a.labels.first(), b.labels.first()),
        Column::Type => present(a.issue_type.as_ref(), b.issue_type.as_ref()),
        Column::Milestone => present(a.milestone.as_ref(), b.milestone.as_ref()),
        Column::Boards => present(a.boards.first().map(|b| &b.0), b.boards.first().map(|b| &b.0)),
        Column::SubIssues => a.sub_issues.cmp(&b.sub_issues),
        Column::Updated => a.updated_at.cmp(&b.updated_at),
        Column::Field(name) => present(field_key(a, name), field_key(b, name)),
        // Open, then closed, then not planned.
        // In the board's order, then by name; issues with none last.
        Column::Status => {
            let key = |i: &IssueItem| i.statuses.first().map(|(name, order)| (0, *order, name.to_lowercase())).unwrap_or((1, 0, String::new()));
            key(a).cmp(&key(b)).then(a.number.cmp(&b.number))
        }
        Column::State => state_rank(a).cmp(&state_rank(b)).then(a.number.cmp(&b.number)),
        Column::Title => a.title.to_lowercase().cmp(&b.title.to_lowercase()),
        Column::Repository => a.repo_name.cmp(&b.repo_name).then(a.number.cmp(&b.number)),
        Column::Number => a.number.cmp(&b.number),
        Column::Author => a.author.cmp(&b.author),
        Column::Assignees => a.assignees.first().cmp(&b.assignees.first()),
        Column::Linked => a.linked.cmp(&b.linked),
        Column::Opened => a.created_at.cmp(&b.created_at),
        Column::Closed => a.closed_at.cmp(&b.closed_at),
    };
    let order = order.then(a.number.cmp(&b.number));
    if *descending { order.reverse() } else { order }
}

impl IssuesPage {
    // MARK: Menus

    /// A login's name, as the issues give it.
    fn person_name(&self, login: &str) -> String {
        self.issues
            .iter()
            .find_map(|i| i.assignee_logins.iter().position(|l| l == login).map(|p| i.assignees[p].clone()))
            .or_else(|| self.issues.iter().find(|i| i.author_login.as_deref() == Some(login)).and_then(|i| i.author.clone()))
            .unwrap_or_else(|| login.to_string())
    }

    fn title_for(&self, key: Key, value: &str) -> String {
        match (key, value) {
            (Key::Assignee, UNASSIGNED) => "Unassigned".into(),
            (Key::Assignee, ANYONE_ASSIGNED) => "Anyone assigned".into(),
            (Key::Assignee, login) | (Key::Author, login) => self.person_name(login),
            (Key::Repository, repo) => repo.rsplit('/').next().unwrap_or(repo).to_string(),
            (Key::Board, NO_BOARD) => "Not on a board".into(),
            (Key::Status, NO_STATUS) => "No status".into(),
            (Key::Milestone, NO_MILESTONE) => "No milestone".into(),
            (_, value) => value.to_string(),
        }
    }

    /// A menu's special values first, then the rest, each with its count
    /// among the issues the other filters leave.
    fn choices(&self, key: Key) -> (Vec<Choice>, Vec<Choice>) {
        let mut counts: HashMap<String, usize> = HashMap::new();
        for issue in self.pool().filter(|i| self.filters.matches(i, Some(key), None)) {
            let values: Vec<String> = match key {
                Key::Assignee => {
                    let mut v: Vec<String> = issue.assignee_logins.clone();
                    v.push(if issue.assignee_logins.is_empty() { UNASSIGNED } else { ANYONE_ASSIGNED }.to_string());
                    v
                }
                Key::Author => issue.author_login.iter().cloned().collect(),
                Key::Repository => vec![issue.repo.clone()],
                Key::Label => issue.labels.clone(),
                Key::Board => {
                    let mut v: Vec<String> = issue.boards.iter().map(|(t, _)| t.clone()).collect();
                    if issue.has_history && issue.boards.is_empty() {
                        v.push(NO_BOARD.to_string());
                    }
                    v
                }
                Key::Milestone => vec![issue.milestone.clone().unwrap_or_default()],
                Key::Status => {
                    let mut v: Vec<String> = issue.statuses.iter().map(|(name, _)| name.clone()).collect();
                    if v.is_empty() {
                        v.push(NO_STATUS.to_string());
                    }
                    v
                }
            };
            for value in values.into_iter().collect::<BTreeSet<_>>() {
                *counts.entry(value).or_default() += 1;
            }
        }
        // Picked values stay listed even when nothing has them now.
        for value in self.filters.values(key) {
            counts.entry(value.clone()).or_default();
        }
        let special: &[&str] = match key {
            Key::Assignee => &[ANYONE_ASSIGNED, UNASSIGNED],
            Key::Board => &[NO_BOARD],
            Key::Status => &[NO_STATUS],
            Key::Milestone => &[NO_MILESTONE],
            _ => &[],
        };
        let choice = |value: &str, count: usize| Choice { value: value.to_string(), title: self.title_for(key, value), count };
        let leading: Vec<Choice> = special.iter().map(|v| choice(v, counts.get(*v).copied().unwrap_or(0))).collect();
        let mut rest: Vec<Choice> =
            counts.iter().filter(|(v, _)| !special.contains(&v.as_str())).map(|(v, c)| choice(v, *c)).collect();
        // Statuses in the board's order: Backlog, In Progress, Done.
        let mut board_order: HashMap<&str, i64> = HashMap::new();
        if key == Key::Status {
            for (name, order) in self.issues.iter().flat_map(|i| &i.statuses) {
                let entry = board_order.entry(name.as_str()).or_insert(*order);
                *entry = (*entry).min(*order);
            }
        }
        rest.sort_by(|a, b| {
            let by_order = |c: &Choice| board_order.get(c.value.as_str()).copied().unwrap_or(i64::MAX);
            let by_count = match key {
                Key::Assignee | Key::Author => b.count.cmp(&a.count),
                Key::Status => by_order(a).cmp(&by_order(b)),
                _ => std::cmp::Ordering::Equal,
            };
            by_count.then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
        });
        (leading, rest)
    }

    /// Board fields picked from options that the issues have, or that are
    /// picked, by name.
    fn field_names(&self) -> Vec<String> {
        let mut names: BTreeSet<String> = self.filters.fields.iter().map(|(f, _)| f.clone()).collect();
        // Status has its own menu, so it's left out unless already picked here.
        for issue in self.pool() {
            names.extend(issue.field_choices.iter().filter(|c| !c.field.eq_ignore_ascii_case("status")).map(|c| c.field.clone()));
        }
        let mut names: Vec<String> = names.into_iter().collect();
        names.sort_by_key(|n| n.to_lowercase());
        names
    }

    /// A field's values in the board's order, how many issues have each, and
    /// how many have none.
    fn field_tally(&self, field: &str) -> (Vec<(String, usize)>, usize) {
        let mut counts: HashMap<String, (usize, i64)> = HashMap::new();
        let mut none = 0;
        for issue in self.pool().filter(|i| self.filters.matches(i, None, Some(field))) {
            let have: BTreeSet<(&str, i64)> =
                issue.field_choices.iter().filter(|c| c.field == field).map(|c| (c.value.as_str(), c.order)).collect();
            if have.is_empty() {
                none += 1;
            }
            for (value, order) in have {
                let entry = counts.entry(value.to_string()).or_insert((0, order));
                entry.0 += 1;
            }
        }
        for (f, value) in &self.filters.fields {
            if f == field && !value.is_empty() {
                counts.entry(value.clone()).or_insert((0, i64::MAX));
            }
        }
        let mut values: Vec<(String, usize, i64)> = counts.into_iter().map(|(v, (c, o))| (v, c, o)).collect();
        values.sort_by(|a, b| a.2.cmp(&b.2).then_with(|| a.0.cmp(&b.0)));
        (values.into_iter().map(|(v, c, _)| (v, c)).collect(), none)
    }

    fn toggle_menu(&mut self, menu: Menu, cx: &mut Context<Self>) {
        let just_closed = self.closed_menu.take().is_some_and(|(m, at)| m == menu && at.elapsed() < Duration::from_millis(300));
        if self.open_menu.as_ref() == Some(&menu) || just_closed {
            self.open_menu = None;
        } else {
            self.open_menu = Some(menu);
            self.expanded_field = None;
        }
        cx.notify();
    }

    fn button_label(&self, menu: &Menu) -> (String, bool) {
        match menu {
            Menu::Columns => ("Columns".into(), false),
            // Open is where it starts, so only another state stands out.
            Menu::State => {
                let titles: Vec<String> = self.states.iter().map(|s| s.title().to_string()).collect();
                let label = if titles.is_empty() { "Any".to_string() } else { titles.join(", ") };
                (format!("State: {label}"), self.states != BTreeSet::from([StateFilter::Open]))
            }
            Menu::Key(key) => {
                let picked = self.filters.values(*key);
                if picked.is_empty() {
                    (key.title().to_string(), false)
                } else {
                    let mut titles: Vec<String> = picked.iter().map(|v| self.title_for(*key, v)).collect();
                    titles.sort_by_key(|t| t.to_lowercase());
                    let not = if self.filters.excludes(key.title()) { "not " } else { "" };
                    (format!("{}: {not}{}", key.title(), summary(&titles, 2)), true)
                }
            }
            Menu::Field => {
                if self.filters.fields.is_empty() {
                    return ("Field".into(), false);
                }
                let mut by_field: Vec<(String, Vec<String>)> = Vec::new();
                for (field, value) in &self.filters.fields {
                    let value = if value.is_empty() { "none".to_string() } else { value.clone() };
                    match by_field.iter_mut().find(|(f, _)| f == field) {
                        Some((_, values)) => values.push(value),
                        None => by_field.push((field.clone(), vec![value])),
                    }
                }
                let not = if self.filters.excludes("Field") { "not " } else { "" };
                let parts: Vec<String> = by_field.iter().map(|(f, v)| format!("{f}: {not}{}", summary(v, 2))).collect();
                (parts.join("; "), true)
            }
        }
    }

    fn menu_button(&self, menu: Menu, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let (label, active) = self.button_label(&menu);
        let open = self.open_menu.as_ref() == Some(&menu);
        let toggled = menu.clone();
        div()
            .flex()
            .flex_col()
            .child(
                div()
                    .id(SharedString::from(format!("filter-{menu:?}")))
                    .max_w(px(280.))
                    .truncate()
                    .px_2()
                    .py_0p5()
                    .rounded_md()
                    .border_1()
                    .border_color(if active { theme.selected } else { theme.border })
                    .text_color(if active { theme.selected } else { theme.fg })
                    .when(open, |d| d.bg(theme.row_selected))
                    .cursor_pointer()
                    .hover(|s| s.bg(theme.row_selected))
                    .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| page.toggle_menu(toggled.clone(), cx)))
                    .child(format!("{label} ▾")),
            )
            .when(open, |d| {
                d.child(deferred(anchored().snap_to_window_with_margin(px(8.)).child(self.menu_panel(&menu, theme, cx))).with_priority(1))
            })
    }

    fn menu_panel(&self, menu: &Menu, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let closing = menu.clone();
        let panel = div()
            .id("filter-menu")
            .mt_1()
            .w(px(300.))
            .max_h(px(420.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .py_1()
            .bg(theme.popover)
            .border_1()
            .border_color(theme.border)
            .rounded_lg()
            .shadow_lg()
            // Clicks in the menu stop here, not on the row beneath.
            .occlude()
            .on_mouse_down_out(cx.listener(move |page, _: &MouseDownEvent, _, cx| {
                if page.open_menu.take().is_some() {
                    page.closed_menu = Some((closing.clone(), Instant::now()));
                    cx.notify();
                }
            }));
        match menu {
            Menu::Columns => panel.children(self.columns_panel(theme, cx)).into_any_element(),
            // Any of the states ticked, each with how many the other filters
            // leave; none ticked is every issue.
            Menu::State => panel
                .children(StateFilter::ALL.into_iter().map(|state| {
                    let count = self
                        .issues
                        .iter()
                        .enumerate()
                        .filter(|(i, issue)| self.in_scope(*i) && self.in_focus(issue) && state.holds(issue) && self.filters.matches(issue, None, None))
                        .count();
                    check_row(SharedString::from(format!("state-{}", state.title())), self.states.contains(&state), state.title().into(), count, 0., theme)
                        .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                            if !page.states.remove(&state) {
                                page.states.insert(state);
                            }
                            page.refilter();
                            cx.notify();
                        }))
                }))
                .when(!self.states.is_empty(), |d| {
                    d.child(separator(theme)).child(menu_action("any-state", "Any State", theme).on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                        page.states.clear();
                        page.refilter();
                        cx.notify();
                    })))
                })
                .into_any_element(),
            Menu::Key(key) => {
                let key = *key;
                let (leading, rest) = self.choices(key);
                let picked = self.filters.values(key);
                let has_leading = !leading.is_empty();
                panel
                    .child(self.mode_switch(key.title(), theme, cx))
                    .children(leading.into_iter().map(|c| self.check_row(key, c, picked, theme, cx)))
                    .when(has_leading && !rest.is_empty(), |d| d.child(separator(theme)))
                    .children(rest.into_iter().map(|c| self.check_row(key, c, picked, theme, cx)))
                    .when(!picked.is_empty(), |d| {
                        d.child(separator(theme)).child(menu_action("clear", "Clear", theme).on_click(cx.listener(
                            move |page, _: &ClickEvent, _, cx| {
                                page.filters.values_mut(key).clear();
                                page.filters.excluding.remove(key.title());
                                page.refilter();
                                cx.notify();
                            },
                        )))
                    })
                    .into_any_element()
            }
            Menu::Field => {
                let mut rows: Vec<gpui::AnyElement> = Vec::new();
                for name in self.field_names() {
                    let expanded = self.expanded_field.as_deref() == Some(name.as_str());
                    let picked = self.filters.fields.iter().filter(|(f, _)| *f == name).count();
                    let opened = name.clone();
                    rows.push(
                        menu_action_owned(
                            SharedString::from(format!("field-{name}")),
                            format!("{} {name}{}", if expanded { "▾" } else { "▸" }, if picked > 0 { format!(" ({picked} picked)") } else { String::new() }),
                            theme,
                        )
                        .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                            page.expanded_field = if page.expanded_field.as_deref() == Some(opened.as_str()) { None } else { Some(opened.clone()) };
                            cx.notify();
                        }))
                        .into_any_element(),
                    );
                    if expanded {
                        let (values, none) = self.field_tally(&name);
                        rows.push(self.field_row(&name, "", format!("No {name}"), none, theme, cx).into_any_element());
                        for (value, count) in values {
                            rows.push(self.field_row(&name, &value, value.clone(), count, theme, cx).into_any_element());
                        }
                    }
                }
                let any_picked = !self.filters.fields.is_empty();
                panel
                    .child(self.mode_switch("Field", theme, cx))
                    .children(rows)
                    .when(any_picked, |d| {
                        d.child(separator(theme)).child(menu_action("clear-fields", "Clear", theme).on_click(cx.listener(
                            |page, _: &ClickEvent, _, cx| {
                                page.filters.fields.clear();
                                page.filters.excluding.remove("Field");
                                page.refilter();
                                cx.notify();
                            },
                        )))
                    })
                    .into_any_element()
            }
        }
    }

    /// Include or Exclude, at the top of a menu: whether its picks keep
    /// issues or leave them out.
    fn mode_switch(&self, menu: &'static str, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        let include = cx.listener(move |page: &mut Self, _: &ClickEvent, _, cx| page.set_excluding(menu, false, cx));
        let exclude = cx.listener(move |page: &mut Self, _: &ClickEvent, _, cx| page.set_excluding(menu, true, cx));
        mode_switch(menu, self.filters.excludes(menu), theme, include, exclude)
    }

    fn set_excluding(&mut self, menu: &str, exclude: bool, cx: &mut Context<Self>) {
        if exclude {
            self.filters.excluding.insert(menu.to_string());
        } else {
            self.filters.excluding.remove(menu);
        }
        self.refilter();
        cx.notify();
    }

    fn check_row(&self, key: Key, choice: Choice, picked: &BTreeSet<String>, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let checked = picked.contains(&choice.value);
        let value = choice.value.clone();
        check_row(SharedString::from(format!("{key:?}-{}", choice.value)), checked, choice.title, choice.count, 0., theme)
            .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                let values = page.filters.values_mut(key);
                if !values.remove(&value) {
                    values.insert(value.clone());
                }
                page.refilter();
                cx.notify();
            }))
    }

    fn field_row(&self, field: &str, value: &str, title: String, count: usize, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let pick = (field.to_string(), value.to_string());
        let checked = self.filters.fields.contains(&pick);
        check_row(SharedString::from(format!("field-{field}-{value}")), checked, title, count, 16., theme).on_click(cx.listener(
            move |page, _: &ClickEvent, _, cx| {
                if !page.filters.fields.remove(&pick) {
                    page.filters.fields.insert(pick.clone());
                }
                page.refilter();
                cx.notify();
            },
        ))
    }

    // MARK: Search

    /// A search field by hand, as GPUI has no text input: printable keys,
    /// Backspace (Option or Command for a word), Command-V and Escape.
    fn search_key(&mut self, event: &KeyDownEvent, _: &mut Window, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;
        let modifiers = &keystroke.modifiers;
        let search = &mut self.filters.search;
        match keystroke.key.as_str() {
            "escape" if !search.is_empty() => search.clear(),
            "backspace" if modifiers.alt || modifiers.platform => {
                let trimmed = search.trim_end().len();
                search.truncate(trimmed);
                let cut = if modifiers.platform { 0 } else { search.rfind(' ').map_or(0, |i| i + 1) };
                search.truncate(cut);
            }
            "backspace" => {
                search.pop();
            }
            "v" if modifiers.platform => match cx.read_from_clipboard().and_then(|c| c.text()) {
                Some(text) => search.push_str(&text.replace(['\n', '\r'], " ")),
                None => return,
            },
            _ => {
                if modifiers.platform || modifiers.control {
                    return;
                }
                match &keystroke.key_char {
                    Some(text) if !text.chars().any(char::is_control) => search.push_str(text),
                    _ => return,
                }
            }
        }
        self.refilter();
        cx.stop_propagation();
        cx.notify();
    }

    fn search_field(&self, theme: &Theme, window: &Window, cx: &mut Context<Self>) -> impl IntoElement {
        let focused = self.search_focus.is_focused(window);
        let text = self.filters.search.clone();
        div()
            .id("issue-search")
            .track_focus(&self.search_focus)
            .on_key_down(cx.listener(Self::search_key))
            .on_click(cx.listener(|page, _: &ClickEvent, window, cx| {
                window.focus(&page.search_focus, cx);
                cx.notify();
            }))
            .w(px(240.))
            .flex()
            .flex_row()
            .items_center()
            .gap_1()
            .px_2()
            .py_0p5()
            .rounded_full()
            .bg(theme.tile)
            .border_1()
            .border_color(if focused { theme.selected } else { theme.border })
            .cursor_text()
            .child(
                div().flex_1().min_w_0().truncate().map(|d| {
                    if text.is_empty() {
                        d.text_color(theme.tertiary).child(if focused { "|".to_string() } else { "Title, number, person, label or text".to_string() })
                    } else {
                        d.child(if focused { format!("{text}|") } else { text.clone() })
                    }
                }),
            )
            .when(!text.is_empty(), |d| {
                d.child(
                    div()
                        .id("clear-search")
                        .px_1()
                        .text_color(theme.tertiary)
                        .cursor_pointer()
                        .on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                            page.filters.search.clear();
                            page.refilter();
                            cx.stop_propagation();
                            cx.notify();
                        }))
                        .child("×"),
                )
            })
    }

    fn filter_bar(&self, theme: &Theme, window: &Window, cx: &mut Context<Self>) -> impl IntoElement {
        let has_milestones = !self.filters.milestones.is_empty() || self.pool().any(|i| i.milestone.is_some());
        let has_boards = !self.filters.boards.is_empty() || self.pool().any(|i| i.has_history);
        let has_fields = !self.field_names().is_empty();
        div()
            .flex_none()
            .flex()
            .flex_row()
            .flex_wrap()
            .items_center()
            .gap_2()
            .px_4()
            .py_3()
            .child(self.search_field(theme, window, cx))
            .child(self.menu_button(Menu::State, theme, cx))
            .when(!self.filters.statuses.is_empty() || self.pool().any(|i| !i.statuses.is_empty()), |d| {
                d.child(self.menu_button(Menu::Key(Key::Status), theme, cx))
            })
            .child(self.menu_button(Menu::Key(Key::Assignee), theme, cx))
            .child(self.menu_button(Menu::Key(Key::Author), theme, cx))
            .child(self.menu_button(Menu::Key(Key::Repository), theme, cx))
            .child(self.menu_button(Menu::Key(Key::Label), theme, cx))
            .when(has_boards, |d| d.child(self.menu_button(Menu::Key(Key::Board), theme, cx)))
            .when(has_fields, |d| d.child(self.menu_button(Menu::Field, theme, cx)))
            .when(has_milestones, |d| d.child(self.menu_button(Menu::Key(Key::Milestone), theme, cx)))
            .when(self.filters.is_narrowed(), |d| {
                d.child(
                    div()
                        .id("clear-all")
                        .cursor_pointer()
                        .text_color(theme.selected)
                        .on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                            page.filters = Filters::default();
                            page.refilter();
                            cx.notify();
                        }))
                        .child("Clear All"),
                )
            })
            // Display only from here.
            .child(div().flex_1())
            .when(!self.filters.is_narrowed() && self.rows.iter().any(|r| r.opens), |d| {
                let any_open = !self.expanded.is_empty();
                d.child(
                    div()
                        .id("expand-all")
                        .cursor_pointer()
                        .text_color(theme.selected)
                        .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| page.expand_all(!any_open, cx)))
                        .child(if any_open { "Collapse All" } else { "Expand All" }),
                )
            })
            .child(self.menu_button(Menu::Columns, theme, cx))
            .child(
                div()
                    .id("new-issue")
                    .px_2()
                    .py_0p5()
                    .rounded_md()
                    .cursor_pointer()
                    .border_1()
                    .border_color(theme.border)
                    .hover(|s| s.bg(theme.row_selected))
                    .on_click(cx.listener(|_, _: &ClickEvent, _, cx| cx.emit(NewIssue)))
                    .child("New Issue"),
            )
    }

    /// Where New Issue starts from this list: the repository when the
    /// filter has exactly one, and the open issues a parent can be.
    pub fn new_issue_start(&self) -> (Option<String>, Vec<IssueItem>) {
        let repo = (self.filters.repositories.len() == 1 && !self.filters.excludes(Key::Repository.title()))
            .then(|| self.filters.repositories.iter().next().cloned())
            .flatten();
        let mut open: Vec<IssueItem> = self.issues.iter().filter(|i| i.is_open()).cloned().collect();
        open.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        (repo, open)
    }

    // MARK: Rows

    fn row(&self, index: usize, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let row = &self.rows[index];
        let issue = &self.issues[row.index];
        let selected = self.selected.as_deref() == Some(issue.id.as_str());
        let picked = self.picked.contains(&issue.id);
        let opened = issue.clone();
        let id = issue.id.clone();
        div()
            .id(("issue", index))
            .when(picked, |d| d.bg(theme.selected.opacity(0.16)))
            // Each row is laid out on its own and would otherwise shrink to
            // its content, pushing the columns out of line with the header.
            .w_full()
            .h(px(ROW_HEIGHT))
            .px_4()
            .flex()
            .flex_row()
            .items_center()
            .gap_3()
            .border_b_1()
            .border_color(theme.grid)
            .cursor_pointer()
            .when(selected, |d| d.bg(theme.row_selected))
            .when(!selected, |d| d.hover(|s| s.bg(theme.tile)))
            .on_click(cx.listener(move |page, event: &ClickEvent, _, cx| {
                let modifiers = event.modifiers();
                if modifiers.platform {
                    if page.picked.is_empty() {
                        if let Some(current) = page.selected.clone().filter(|c| *c != opened.id) {
                            page.picked.push(current);
                        }
                    }
                    page.toggle_pick(&opened.id, index);
                } else if modifiers.shift {
                    let from = page.anchor.unwrap_or(index);
                    for row in from.min(index)..=from.max(index) {
                        let id = page.issues[page.rows[row].index].id.clone();
                        if !page.picked.contains(&id) {
                            page.picked.push(id);
                        }
                    }
                } else {
                    // A plain click opens the drawer; what's ticked stays.
                    page.anchor = Some(index);
                    page.selected = Some(opened.id.clone());
                    cx.emit(OpenIssue(opened.clone()));
                }
                cx.notify();
            }))
            .child(
                div()
                    .id(("pick-issue", index))
                    .flex_none()
                    .p_1()
                    .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                        cx.stop_propagation();
                        page.toggle_pick(&id, index);
                        cx.notify();
                    }))
                    .child(crate::prs::PrsPage::checkbox(Some(picked), theme)),
            )
            .children(self.columns.iter().map(|column| self.cell(column, index, theme, cx)))
    }

    fn toggle_pick(&mut self, id: &str, index: usize) {
        if let Some(at) = self.picked.iter().position(|p| p == id) {
            self.picked.remove(at);
        } else {
            self.picked.push(id.to_string());
        }
        self.anchor = Some(index);
    }

    /// Along the foot while rows are picked: how many, and Work on This for
    /// the open ones.
    fn picked_bar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let picked: Vec<IssueItem> = self.picked.iter().filter_map(|id| self.issues.iter().find(|i| &i.id == id).cloned()).collect();
        let open: Vec<IssueItem> = picked.iter().filter(|i| i.closed_at.is_none()).cloned().collect();
        let button = |id: &'static str, label: String, prominent: bool| {
            div()
                .id(id)
                .px_2()
                .py_0p5()
                .rounded_md()
                .cursor_pointer()
                .map(|d| if prominent { d.bg(theme.selected).text_color(theme.on_selected) } else { d.border_1().border_color(theme.border) })
                .hover(|s| s.opacity(0.85))
                .child(label)
        };
        div()
            .flex_none()
            .h(px(40.))
            .px_4()
            .flex()
            .flex_row()
            .items_center()
            .gap_3()
            .border_t_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .child(div().flex_1().min_w_0().text_sm().child(format!("{} selected", picked.len())).when(open.len() < picked.len(), |d| {
                d.child(div().text_xs().text_color(theme.secondary).child("Only open issues can be worked on."))
            }))
            .child(button("picked-clear", "Clear".into(), false).on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                page.picked.clear();
                cx.notify();
            })))
            .when(!open.is_empty(), |d| {
                let scheduled = open.clone();
                d.child(button("picked-schedule", "Add to Schedule".into(), false).on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                    cx.emit(ScheduleIssues(scheduled.clone()));
                    page.picked.clear();
                    cx.notify();
                })))
            })
            .when(!open.is_empty(), |d| {
                let count = open.len();
                d.child(
                    button("picked-work", if count == 1 { "Work on This".into() } else { format!("Work on {count} with Claude") }, true).on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                        cx.emit(WorkOnIssues(open.clone()));
                        page.picked.clear();
                        cx.notify();
                    })),
                )
            })
    }
}

impl IssuesPage {
    fn cell(&self, column: &Column, index: usize, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        let row = &self.rows[index];
        let issue = &self.issues[row.index];
        let width = self.column_width(column).unwrap_or(0.);
        let text = |value: String| div().w(px(width)).flex_none().truncate().child(value);
        let quiet = |value: String| text(value).text_color(theme.secondary);
        let when = |date: Option<DateTime<Utc>>| quiet(date.map(crate::format::table_date).unwrap_or_default());
        match column {
            Column::Title => self.title_cell(index, theme).into_any_element(),
            Column::State => div().w(px(width)).flex_none().flex().overflow_hidden().child(state_pill(issue, theme)).into_any_element(),
            Column::Status => div()
                .w(px(width))
                .flex_none()
                .flex()
                .flex_row()
                .items_center()
                .gap_1()
                .overflow_hidden()
                .when_some(issue.statuses.first(), |d, (status, _)| {
                    d.child(div().flex_shrink(1.).min_w_0().truncate().px_1p5().rounded_sm().bg(theme.tile).child(status.clone()))
                })
                .when(issue.statuses.len() > 1, |d| {
                    d.child(div().flex_none().text_xs().text_color(theme.secondary).child(format!("+{}", issue.statuses.len() - 1)))
                })
                .into_any_element(),
            Column::Repository => quiet(issue.repo_name.clone()).into_any_element(),
            Column::Number => quiet(format!("#{}", issue.number)).into_any_element(),
            // Avatars only; the names show on hover.
            Column::Author => div()
                .id(("author", index))
                .w(px(width))
                .flex_none()
                .flex()
                .items_center()
                .overflow_hidden()
                .when_some(issue.author_login.clone(), |d, login| d.child(avatar(&login, issue.author_avatar.as_deref(), 20., theme, cx)))
                .when_some(issue.author.clone(), |d, name| d.tooltip(move |_, cx| cx.new(|_| Tooltip(name.clone())).into()))
                .into_any_element(),
            Column::Assignees => {
                let people: Vec<(String, Option<String>)> =
                    issue.assignee_logins.iter().cloned().zip(issue.assignee_avatars.iter().cloned()).collect();
                let names = issue.assignees.join(", ");
                div()
                    .id(("assignees", index))
                    .w(px(width))
                    .flex_none()
                    .flex()
                    .items_center()
                    .overflow_hidden()
                    .when(!people.is_empty(), |d| {
                        d.child(stack(&people, 20., theme, cx)).tooltip(move |_, cx| cx.new(|_| Tooltip(names.clone())).into())
                    })
                    .into_any_element()
            }
            Column::Labels => quiet(issue.labels.join(", ")).into_any_element(),
            Column::Type => text(issue.issue_type.clone().unwrap_or_default()).into_any_element(),
            Column::Milestone => text(issue.milestone.clone().unwrap_or_default()).into_any_element(),
            Column::Boards => quiet(issue.boards.iter().map(|(b, _)| b.as_str()).collect::<Vec<_>>().join(", ")).into_any_element(),
            Column::Linked => quiet(if issue.linked > 0 { issue.linked.to_string() } else { String::new() }).into_any_element(),
            // Opens and closes the row's sub-issues beneath it in the tree;
            // in a filtered list, where every match is its own row, it only
            // counts them.
            Column::SubIssues => {
                let expanded = self.expanded.contains(&issue.id);
                let toggled = issue.id.clone();
                div()
                    .w(px(width))
                    .flex_none()
                    .flex()
                    .items_center()
                    .when(issue.sub_issues > 0, |d| {
                        let label = format!("{} of {}", issue.sub_issues_done, issue.sub_issues);
                        d.child(
                            div()
                                .id(("sub-issues", index))
                                .px_1p5()
                                .py_0p5()
                                .rounded_md()
                                .bg(theme.tile)
                                .text_xs()
                                .map(|d| {
                                    if row.opens {
                                        d.text_color(theme.fg)
                                            .cursor_pointer()
                                            .hover(|s| s.bg(theme.row_selected))
                                            .when(expanded, |d| d.bg(theme.selected.opacity(0.22)).text_color(theme.selected))
                                            .child(label)
                                            .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                                                cx.stop_propagation();
                                                page.toggle_expanded(toggled.clone(), cx);
                                            }))
                                    } else {
                                        d.text_color(theme.secondary).child(label)
                                    }
                                }),
                        )
                    })
                    .into_any_element()
            }
            Column::Opened => when(Some(issue.created_at)).into_any_element(),
            Column::Updated => when(issue.updated_at).into_any_element(),
            Column::Closed => when(issue.closed_at).into_any_element(),
            Column::Field(name) => text(issue.field_text(name).unwrap_or_default().to_string()).into_any_element(),
        }
    }

    /// The title, with the tree's indent and triangle, the sub-issue chip
    /// and where it belongs.
    fn title_cell(&self, index: usize, theme: &Theme) -> impl IntoElement {
        let row = &self.rows[index];
        let issue = &self.issues[row.index];
        div()
            .flex_1()
            .min_w(px(220.))
            .overflow_hidden()
            .flex()
            .flex_row()
            .items_center()
            .gap_1p5()
            .pl(px(row.depth as f32 * 18.))
            .child(div().flex_shrink(1.).min_w(px(60.)).truncate().child(issue.title.clone()))
            .when_some(row.context.clone(), |d, context| {
                d.child(div().flex_1().min_w_0().truncate().text_xs().text_color(theme.tertiary).child(context))
            })
    }

    // MARK: Columns

    /// Its width: as dragged, else its default; nil for the flexible Title.
    fn column_width(&self, column: &Column) -> Option<f32> {
        let default = column.width()?;
        Some(self.widths.get(&column.key()).copied().unwrap_or(default))
    }

    /// A column edge is being dragged, so saving waits for the drag to end.
    pub fn is_resizing(&self) -> bool {
        self.resizing.is_some()
    }

    fn resize(&mut self, event: &gpui::MouseMoveEvent, _: &mut Window, cx: &mut Context<Self>) {
        let Some((column, start, width)) = self.resizing.clone() else { return };
        if event.pressed_button != Some(gpui::MouseButton::Left) {
            self.resizing = None;
            cx.notify();
            return;
        }
        let width = (width + f32::from(event.position.x) - start).clamp(40.0, 600.0);
        self.widths.insert(column.key(), width);
        cx.notify();
    }

    fn show_column(&mut self, column: Column, cx: &mut Context<Self>) {
        if !self.columns.contains(&column) {
            self.columns.push(column);
            cx.notify();
        }
    }

    fn hide_column(&mut self, column: &Column, cx: &mut Context<Self>) {
        if *column != Column::Title {
            self.columns.retain(|c| c != column);
            cx.notify();
        }
    }

    /// Moves a column by `by` places, staying in bounds.
    fn shift_column(&mut self, column: &Column, by: isize, cx: &mut Context<Self>) {
        let Some(from) = self.columns.iter().position(|c| c == column) else { return };
        let to = (from as isize + by).clamp(0, self.columns.len() as isize - 1) as usize;
        let moved = self.columns.remove(from);
        self.columns.insert(to, moved);
        cx.notify();
    }

    /// Drops a dragged header onto another's place.
    fn move_column(&mut self, dragged: &Column, onto: &Column, cx: &mut Context<Self>) {
        let (Some(from), Some(to)) = (self.columns.iter().position(|c| c == dragged), self.columns.iter().position(|c| c == onto)) else {
            return;
        };
        if from != to {
            let moved = self.columns.remove(from);
            self.columns.insert(to, moved);
            cx.notify();
        }
    }

    /// The Columns menu: those shown, in order, to hide or move; then those
    /// that can be added, board fields included; then Reset.
    fn columns_panel(&self, theme: &Theme, cx: &mut Context<Self>) -> Vec<gpui::AnyElement> {
        let mut rows: Vec<gpui::AnyElement> = Vec::new();
        rows.push(menu_heading("Shown", theme).into_any_element());
        let last = self.columns.len().saturating_sub(1);
        for (position, column) in self.columns.iter().enumerate() {
            let fixed = *column == Column::Title;
            let (hidden, up, down) = (column.clone(), column.clone(), column.clone());
            let arrow = |id: &str, label: &'static str, enabled: bool| {
                div()
                    .id(SharedString::from(format!("{id}-{}", column.title())))
                    .px_1()
                    .rounded_sm()
                    .text_color(if enabled { theme.secondary } else { theme.border })
                    .when(enabled, |d| d.cursor_pointer().hover(|s| s.bg(theme.row_selected)))
                    .child(label)
            };
            rows.push(
                div()
                    .mx_1()
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .id(SharedString::from(format!("shown-{}", column.title())))
                            .flex_1()
                            .flex()
                            .flex_row()
                            .gap_2()
                            .when(!fixed, |d| {
                                d.cursor_pointer().on_click(cx.listener(move |page, _: &ClickEvent, _, cx| page.hide_column(&hidden, cx)))
                            })
                            .child(div().w(px(12.)).text_color(if fixed { theme.tertiary } else { theme.selected }).child("✓"))
                            .child(div().flex_1().truncate().when(fixed, |d| d.text_color(theme.secondary)).child(column.title())),
                    )
                    .child(arrow("up", "↑", position > 0).when(position > 0, |d| {
                        d.on_click(cx.listener(move |page, _: &ClickEvent, _, cx| page.shift_column(&up, -1, cx)))
                    }))
                    .child(arrow("down", "↓", position < last).when(position < last, |d| {
                        d.on_click(cx.listener(move |page, _: &ClickEvent, _, cx| page.shift_column(&down, 1, cx)))
                    }))
                    .into_any_element(),
            );
        }

        let mut more: Vec<Column> = Column::built_in().into_iter().filter(|c| !self.columns.contains(c)).collect();
        more.extend(
            self.field_names()
                .into_iter()
                .filter(|name| !name.eq_ignore_ascii_case("status"))
                .map(Column::Field)
                .filter(|c| !self.columns.contains(c)),
        );
        if !more.is_empty() {
            rows.push(separator(theme).into_any_element());
            rows.push(menu_heading("More", theme).into_any_element());
            for column in more {
                let label = match &column {
                    Column::Field(name) => format!("{name} (board field)"),
                    other => other.title(),
                };
                let added = column.clone();
                rows.push(
                    menu_action_owned(SharedString::from(format!("add-{}", column.title())), format!("    {label}"), theme)
                        .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| page.show_column(added.clone(), cx)))
                        .into_any_element(),
                );
            }
        }
        rows.push(separator(theme).into_any_element());
        rows.push(
            menu_action("reset-columns", "Reset to Default", theme)
                .on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                    page.columns = Column::defaults();
                    page.widths.clear();
                    cx.notify();
                }))
                .into_any_element(),
        );
        rows
    }
}

pub(crate) fn menu_heading(label: &'static str, theme: &Theme) -> impl IntoElement {
    div().px_3().pt_1().pb_0p5().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.tertiary).child(label)
}

pub(crate) fn separator(theme: &Theme) -> impl IntoElement {
    div().my_1().h(px(1.)).bg(theme.border)
}

pub(crate) fn menu_action(id: &'static str, label: &'static str, theme: &Theme) -> gpui::Stateful<gpui::Div> {
    menu_action_owned(id.into(), label.to_string(), theme)
}

pub(crate) fn menu_action_owned(id: SharedString, label: String, theme: &Theme) -> gpui::Stateful<gpui::Div> {
    div().id(id).mx_1().px_2().py_1().rounded_md().cursor_pointer().hover(|s| s.bg(theme.row_selected)).child(label)
}

/// Include and Exclude side by side, the one in use highlighted; `on`
/// makes each one's click handler (true for Exclude).
pub(crate) fn mode_switch(
    menu: &str,
    excluding: bool,
    theme: &Theme,
    include: impl Fn(&ClickEvent, &mut Window, &mut gpui::App) + 'static,
    exclude: impl Fn(&ClickEvent, &mut Window, &mut gpui::App) + 'static,
) -> gpui::AnyElement {
    let mode = |exclude: bool| {
        let current = exclude == excluding;
        div()
            .id(SharedString::from(format!("{menu}-{}", if exclude { "exclude" } else { "include" })))
            .flex_1()
            .py_0p5()
            .flex()
            .justify_center()
            .rounded_md()
            .cursor_pointer()
            .text_color(if current { theme.fg } else { theme.secondary })
            .when(current, |d| d.bg(theme.row_selected))
            .hover(|s| s.bg(theme.row_selected))
            .child(if exclude { "Exclude" } else { "Include" })
    };
    div()
        .mx_2()
        .mb_1()
        .p_0p5()
        .flex()
        .flex_row()
        .gap_0p5()
        .rounded_md()
        .bg(theme.tile)
        .text_xs()
        .child(mode(false).on_click(include))
        .child(mode(true).on_click(exclude))
        .into_any_element()
}

/// A menu row to tick: a check, the title and its count.
pub(crate) fn check_row(id: SharedString, checked: bool, title: String, count: usize, indent: f32, theme: &Theme) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .mx_1()
        .pl(px(8. + indent))
        .pr_2()
        .py_1()
        .rounded_md()
        .flex()
        .flex_row()
        .items_center()
        .gap_2()
        .cursor_pointer()
        .hover(|s| s.bg(theme.row_selected))
        .child(div().w(px(12.)).text_color(theme.selected).child(if checked { "✓" } else { "" }))
        .child(div().flex_1().min_w_0().truncate().child(title))
        .child(div().text_color(theme.secondary).child(thousands(count)))
}

fn state_rank(issue: &IssueItem) -> u8 {
    match (issue.is_open(), issue.not_planned) {
        (true, _) => 0,
        (false, false) => 1,
        (false, true) => 2,
    }
}

/// Open in green, Closed in purple, Not planned in grey.
pub fn state_pill(issue: &IssueItem, theme: &Theme) -> impl IntoElement {
    match (issue.is_open(), issue.not_planned) {
        (true, _) => pill("Open", theme.good()),
        (false, false) => pill("Closed", theme.slot(6)),
        (false, true) => pill("Not planned", theme.secondary),
    }
}

pub fn pill(label: &'static str, color: gpui::Hsla) -> impl IntoElement {
    div().flex_none().px_1p5().rounded_sm().text_xs().border_1().border_color(color).text_color(color).child(label)
}

impl Render for IssuesPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let (sort, descending) = self.sort.clone();
        let count = self.rows.len();
        let matched = self.match_count;
        let only = |state: StateFilter| self.states.len() == 1 && self.states.contains(&state);
        let noun = if only(StateFilter::Open) {
            "open issues"
        } else if only(StateFilter::Closed) {
            "closed issues"
        } else if only(StateFilter::NotPlanned) {
            "issues not planned"
        } else {
            "issues"
        };

        let column_header = div()
            .flex_none()
            .h(px(28.))
            .px_4()
            .flex()
            .flex_row()
            .items_center()
            .gap_3()
            .border_b_1()
            .border_color(theme.border)
            .text_xs()
            .font_weight(FontWeight::MEDIUM)
            .text_color(theme.secondary)
            .child({
                let visible: Vec<String> = self.rows.iter().map(|r| self.issues[r.index].id.clone()).collect();
                let ticked = visible.iter().filter(|id| self.picked.contains(id)).count();
                let state = if ticked == 0 { Some(false) } else if ticked == visible.len() { Some(true) } else { None };
                div()
                    .id("pick-all-issues")
                    .flex_none()
                    .p_1()
                    .cursor_pointer()
                    .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                        if state == Some(true) {
                            page.picked.retain(|id| !visible.contains(id));
                        } else {
                            for id in &visible {
                                if !page.picked.contains(id) {
                                    page.picked.push(id.clone());
                                }
                            }
                        }
                        cx.notify();
                    }))
                    .child(crate::prs::PrsPage::checkbox(state, &theme))
            })
            .children(self.columns.clone().into_iter().map(|column| {
                let marker = if column == sort { if descending { " ↓" } else { " ↑" } } else { "" };
                let (sorted, onto, title) = (column.clone(), column.clone(), column.title());
                let landing = theme.row_selected;
                let width = self.column_width(&column);
                let (resized, edge) = (column.clone(), theme.selected);
                div()
                    .id(column.id())
                    .relative()
                    .when_some(width, |d, w| d.w(px(w)).flex_none())
                    .when(width.is_none(), |d| d.flex_1().min_w(px(220.)))
                    .rounded_sm()
                    .cursor_pointer()
                    .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                        page.sort = if page.sort.0 == sorted {
                            (sorted.clone(), !page.sort.1)
                        } else {
                            (sorted.clone(), sorted.sorts_descending())
                        };
                        page.refilter();
                        cx.notify();
                    }))
                    // Drag a header onto another to move it there.
                    .on_drag(DraggedColumn(column.clone()), |dragged, _, _, cx| cx.new(|_| ColumnDrag(dragged.0.title())))
                    .drag_over::<DraggedColumn>(move |style, _, _, _| style.bg(landing))
                    .on_drop(cx.listener(move |page, dragged: &DraggedColumn, _, cx| page.move_column(&dragged.0, &onto, cx)))
                    .child(div().truncate().child(format!("{title}{marker}")))
                    // Its right edge drags to resize; Title takes what's left.
                    .when_some(width, |d, w| {
                        d.child(
                            div()
                                .id(SharedString::from(format!("resize-{}", resized.key())))
                                .absolute()
                                .top_0()
                                .bottom_0()
                                .right(px(-8.))
                                .w(px(10.))
                                .cursor_col_resize()
                                .hover(move |s| s.border_r_2().border_color(edge))
                                .on_mouse_down(
                                    gpui::MouseButton::Left,
                                    cx.listener(move |page, event: &MouseDownEvent, _, cx| {
                                        page.resizing = Some((resized.clone(), f32::from(event.position.x), w));
                                        cx.stop_propagation();
                                        cx.notify();
                                    }),
                                ),
                        )
                    })
            }));

        let body = if let Some(error) = &self.error {
            div().p_4().text_color(theme.secondary).child(format!("Couldn't read the issue store: {error}")).into_any_element()
        } else if self.loading {
            div().p_4().text_color(theme.secondary).child("Loading").into_any_element()
        } else if matched == 0 {
            let never_synced = self.org.as_deref().is_some_and(|org| crate::sync::last_synced(org).is_none());
            let text = if self.pool_count == 0 && never_synced {
                "Not synced yet. Sync this org to see its work here.".to_string()
            } else if self.pool_count == 0 {
                format!("No {noun}")
            } else {
                format!("No {noun} match")
            };
            div().p_4().text_color(theme.secondary).child(text).into_any_element()
        } else {
            uniform_list(
                "issue-rows",
                count,
                cx.processor(|page, range: Range<usize>, window, cx| {
                    let theme = Theme::for_window(window);
                    range.map(|i| page.row(i, &theme, cx)).collect::<Vec<_>>()
                }),
            )
            .flex_1()
            .into_any_element()
        };

        div()
            .relative()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .on_mouse_move(cx.listener(Self::resize))
            .on_mouse_up(
                gpui::MouseButton::Left,
                cx.listener(|page, _: &gpui::MouseUpEvent, _, cx| {
                    if page.resizing.take().is_some() {
                        cx.notify();
                    }
                }),
            )
            .when(self.scope_set.is_some(), |d| d.child(self.breadcrumb(&theme, cx)))
            .child(self.filter_bar(&theme, window, cx))
            .child(column_header)
            .child(div().flex_1().min_h_0().flex().flex_col().child(body))
            .when(!self.picked.is_empty(), |d| d.child(self.picked_bar(&theme, cx)))
            // While a menu is open, a click elsewhere on the page only closes
            // it, as a macOS menu does; the menu is drawn above this.
            .when(self.open_menu.is_some(), |d| {
                d.child(
                    div()
                        .id("menu-backdrop")
                        .absolute()
                        .top_0()
                        .left_0()
                        .right_0()
                        .bottom_0()
                        .occlude()
                        .on_mouse_down(
                            gpui::MouseButton::Left,
                            cx.listener(|page, _: &MouseDownEvent, _, cx| {
                                page.open_menu = None;
                                cx.notify();
                            }),
                        ),
                )
            })
    }
}
