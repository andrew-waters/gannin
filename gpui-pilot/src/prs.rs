//! The Pull Requests page, made the way Issues was rather than copied from
//! `PullRequestsView`: one list of every PR in the org's cache
//! (`~/Library/Application Support/PullRequests/<org>.json`), a State menu
//! (Open, Merged, Closed) in place of the Open/Merged/All picker and its
//! two sections, filter menus with counts (Status, Author, Reviewer,
//! Checks, Repository; Me first where it fits), and columns each person
//! picks, orders and sizes. A row opens the PR in a drawer.
//!
//! The cache holds more than the Swift page lists: PRs closed without
//! merging (in the work log only) show under Closed. Open PRs carry their
//! review and checks (the workload slot); merged and closed ones carry
//! their commits and reviews (the work log). Labels and the base branch
//! aren't cached, so neither shows.

use crate::avatars::{avatar, stack};
use crate::charts::Theme;
use crate::format::thousands;
use crate::issues::{check_row, menu_action, menu_action_owned, menu_heading, mode_switch, pill, separator, summary, ColumnDrag, Tooltip};
use chrono::{DateTime, Utc};
use gpui::{
    anchored, deferred, div, prelude::*, px, uniform_list, ClickEvent, Context, EventEmitter, FocusHandle, FontWeight, Hsla,
    KeyDownEvent, MouseDownEvent, SharedString, Subscription, Window,
};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::ops::Range;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

// MARK: - The stored shape

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct File {
    #[serde(default)]
    pull_requests: HashMap<String, Stored>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stored {
    core: Core,
    workload: Option<Workload>,
    metrics: Option<Metrics>,
    work_log: Option<WorkLog>,
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
    #[serde(default)]
    author_is_bot: bool,
    created_at: DateTime<Utc>,
    updated_at: Option<DateTime<Utc>>,
    merged_at: Option<DateTime<Utc>>,
    additions: Option<i64>,
    deletions: Option<i64>,
    changed_files: Option<i64>,
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Person {
    login: String,
    name: Option<String>,
    avatar_url: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Workload {
    state: String,
    #[serde(default)]
    is_draft: bool,
    review_decision: Option<String>,
    checks: Option<String>,
    #[serde(default)]
    assignees: Vec<Person>,
    #[serde(default)]
    requested_reviewers: Vec<Person>,
    #[serde(default)]
    reviewers: Vec<Person>,
    #[serde(default)]
    review_states: HashMap<String, String>,
    #[serde(default)]
    linked_issues: Vec<LinkedIssue>,
    updated_at: Option<DateTime<Utc>>,
    last_commit_at: Option<DateTime<Utc>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Metrics {
    head_ref: Option<String>,
    first_commit_at: Option<DateTime<Utc>>,
    ready_at: Option<DateTime<Utc>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkLog {
    closed_at: Option<DateTime<Utc>>,
    merged_by: Option<String>,
    #[serde(default)]
    is_draft: bool,
    #[serde(default)]
    commits: Vec<Commit>,
    #[serde(default)]
    reviews: Vec<Review>,
    #[serde(default)]
    closing_issues: Vec<LinkedIssue>,
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Commit {
    pub author: Option<String>,
    pub authored_at: DateTime<Utc>,
    #[serde(default)]
    pub additions: i64,
    #[serde(default)]
    pub deletions: i64,
    pub url: Option<String>,
    #[serde(default)]
    pub message: String,
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Review {
    pub author: String,
    pub state: String,
    pub submitted_at: DateTime<Utc>,
}

#[derive(Deserialize, Clone)]
pub struct LinkedIssue {
    pub id: String,
    pub number: i64,
    pub title: String,
    pub url: String,
    pub repo: Option<String>,
    pub state: Option<String>,
}

// MARK: - Rows

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug, serde::Serialize, serde::Deserialize)]
pub enum PrState {
    Open,
    Merged,
    /// Closed without merging: the work log knows, the workload doesn't.
    Closed,
}

impl PrState {
    const ALL: [PrState; 3] = [PrState::Open, PrState::Merged, PrState::Closed];

    fn title(self) -> &'static str {
        match self {
            PrState::Open => "Open",
            PrState::Merged => "Merged",
            PrState::Closed => "Closed",
        }
    }
}

/// Where an open PR stands, as `statusText`; merged and closed ones have
/// their state instead.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub enum Standing {
    Draft,
    InReview,
    Commented,
    ChangesRequested,
    Approved,
}

impl Standing {
    const ALL: [Standing; 5] = [Standing::Draft, Standing::InReview, Standing::Commented, Standing::ChangesRequested, Standing::Approved];

    pub fn title(self) -> &'static str {
        match self {
            Standing::Draft => "Draft",
            Standing::InReview => "In review",
            Standing::Commented => "Commented",
            Standing::ChangesRequested => "Changes requested",
            Standing::Approved => "Approved",
        }
    }

    pub fn color(self, theme: &Theme) -> Hsla {
        match self {
            Standing::Draft => theme.secondary,
            Standing::InReview | Standing::Commented => theme.blue(),
            Standing::ChangesRequested => theme.orange(),
            Standing::Approved => theme.good(),
        }
    }

    fn from_title(title: &str) -> Option<Standing> {
        Standing::ALL.into_iter().find(|s| s.title() == title)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub enum Checks {
    Failing,
    Running,
    Passing,
}

impl Checks {
    pub fn title(self) -> &'static str {
        match self {
            Checks::Passing => "Passing",
            Checks::Failing => "Failing",
            Checks::Running => "Running",
        }
    }

    pub fn color(self, theme: &Theme) -> Hsla {
        match self {
            Checks::Passing => theme.good(),
            Checks::Failing => theme.critical(),
            Checks::Running => theme.orange(),
        }
    }
}

/// Someone asked to review, or who has.
#[derive(Clone)]
pub struct Reviewer {
    pub login: String,
    pub name: Option<String>,
    pub avatar: Option<String>,
    /// Their latest review's state, as GitHub names it; nil while they're
    /// only requested.
    pub state: Option<String>,
    pub requested: bool,
}

impl Reviewer {
    pub fn standing(&self) -> &'static str {
        match self.state.as_deref() {
            Some("APPROVED") => "Approved",
            Some("CHANGES_REQUESTED") => "Changes requested",
            Some("COMMENTED") if self.requested => "Commented, asked again",
            Some("COMMENTED") => "Commented",
            Some("DISMISSED") => "Dismissed",
            _ => "Requested",
        }
    }
}

/// A PR is stale when open and not updated for a week, as Swift's.
const STALE_DAYS: i64 = 7;

#[derive(Clone)]
pub struct PrItem {
    pub id: String,
    pub number: i64,
    pub title: String,
    pub url: String,
    pub repo: String,
    pub repo_name: String,
    pub author: Option<String>,
    pub author_name: Option<String>,
    pub author_avatar: Option<String>,
    pub author_is_bot: bool,
    pub state: PrState,
    pub draft: bool,
    /// Open PRs only: where review stands.
    pub standing: Option<Standing>,
    /// Open PRs with details only; nil there is no checks.
    pub checks: Option<Checks>,
    /// The cache has the open PR's review and checks.
    pub has_details: bool,
    pub reviewers: Vec<Reviewer>,
    pub assignees: Vec<(String, Option<String>)>,
    pub linked: Vec<LinkedIssue>,
    pub additions: Option<i64>,
    pub deletions: Option<i64>,
    pub files: Option<i64>,
    pub branch: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub merged_at: Option<DateTime<Utc>>,
    pub closed_at: Option<DateTime<Utc>>,
    pub merged_by: Option<String>,
    pub first_commit_at: Option<DateTime<Utc>>,
    pub ready_at: Option<DateTime<Utc>>,
    pub last_commit_at: Option<DateTime<Utc>>,
    pub commits: Vec<Commit>,
    pub reviews: Vec<Review>,
}

impl PrItem {
    pub fn is_stale(&self, now: DateTime<Utc>) -> bool {
        self.state == PrState::Open && (now - self.updated_at).num_days() >= STALE_DAYS
    }

    /// When it merged or closed, else when it last changed.
    pub fn ended_or_updated(&self) -> DateTime<Utc> {
        self.merged_at.or(self.closed_at).unwrap_or(self.updated_at)
    }

    pub fn status_title(&self) -> &'static str {
        match self.state {
            PrState::Merged => "Merged",
            PrState::Closed => "Closed",
            PrState::Open => self.standing.map_or("Open", Standing::title),
        }
    }

    fn reviewer_logins(&self) -> impl Iterator<Item = &str> {
        self.reviewers.iter().map(|r| r.login.as_str())
    }

    /// `None` when it isn't in the cache in a way the page can show: an
    /// open PR the workload has dropped (it closed since) is left out.
    fn from(stored: Stored) -> Option<Self> {
        let Stored { core, workload, metrics, work_log } = stored;
        let author = core.author.as_ref().map(|a| a.login.clone());
        let state = if core.merged_at.is_some() {
            PrState::Merged
        } else if work_log.as_ref().is_some_and(|w| w.closed_at.is_some()) {
            PrState::Closed
        } else if workload.as_ref().is_some_and(|w| w.state == "OPEN") {
            PrState::Open
        } else {
            return None;
        };
        let draft = state == PrState::Open && (workload.as_ref().is_some_and(|w| w.is_draft) || work_log.as_ref().is_some_and(|w| w.is_draft));

        // Reviewers: those asked, then those who reviewed (the author's own
        // comments aren't a review).
        let mut reviewers: Vec<Reviewer> = Vec::new();
        if let Some(w) = &workload {
            let people: HashMap<&str, &Person> = w.reviewers.iter().chain(&w.requested_reviewers).map(|p| (p.login.as_str(), p)).collect();
            for person in &w.requested_reviewers {
                reviewers.push(Reviewer {
                    login: person.login.clone(),
                    name: person.name.clone(),
                    avatar: person.avatar_url.clone(),
                    state: w.review_states.get(&person.login).cloned(),
                    requested: true,
                });
            }
            let mut reviewed: Vec<(&String, &String)> = w.review_states.iter().collect();
            reviewed.sort();
            for (login, review) in reviewed {
                if Some(login) == author.as_ref() || reviewers.iter().any(|r| &r.login == login) {
                    continue;
                }
                let person = people.get(login.as_str());
                reviewers.push(Reviewer {
                    login: login.clone(),
                    name: person.and_then(|p| p.name.clone()),
                    avatar: person.and_then(|p| p.avatar_url.clone()),
                    state: Some(review.clone()),
                    requested: false,
                });
            }
        } else if let Some(log) = &work_log {
            let mut latest: BTreeMap<&str, &Review> = BTreeMap::new();
            for review in &log.reviews {
                if Some(&review.author) == author.as_ref() {
                    continue;
                }
                let entry = latest.entry(review.author.as_str()).or_insert(review);
                if review.submitted_at > entry.submitted_at {
                    *entry = review;
                }
            }
            reviewers = latest
                .into_values()
                .map(|r| Reviewer { login: r.author.clone(), name: None, avatar: None, state: Some(r.state.clone()), requested: false })
                .collect();
        }

        let standing = (state == PrState::Open).then(|| {
            if draft {
                return Standing::Draft;
            }
            let decision = workload.as_ref().and_then(|w| w.review_decision.clone()).or_else(|| {
                let states: Vec<&str> = reviewers.iter().filter_map(|r| r.state.as_deref()).collect();
                if states.contains(&"CHANGES_REQUESTED") {
                    Some("CHANGES_REQUESTED".into())
                } else if states.contains(&"APPROVED") {
                    Some("APPROVED".into())
                } else {
                    None
                }
            });
            match decision.as_deref() {
                Some("APPROVED") => Standing::Approved,
                Some("CHANGES_REQUESTED") => Standing::ChangesRequested,
                _ if reviewers.iter().any(|r| r.state.is_some()) => Standing::Commented,
                _ => Standing::InReview,
            }
        });
        let checks = workload.as_ref().and_then(|w| match w.checks.as_deref() {
            Some("SUCCESS") => Some(Checks::Passing),
            Some("FAILURE" | "ERROR") => Some(Checks::Failing),
            Some("PENDING" | "EXPECTED") => Some(Checks::Running),
            _ => None,
        });
        let linked = match (&workload, &work_log) {
            (Some(w), _) if !w.linked_issues.is_empty() => w.linked_issues.clone(),
            (_, Some(log)) => log.closing_issues.clone(),
            _ => Vec::new(),
        };
        let updated_at = workload.as_ref().and_then(|w| w.updated_at).or(core.updated_at).unwrap_or(core.created_at);
        Some(Self {
            repo_name: core.repo.rsplit('/').next().unwrap_or(&core.repo).to_string(),
            author_name: core.author.as_ref().and_then(|a| a.name.clone()),
            author_avatar: core.author.as_ref().and_then(|a| a.avatar_url.clone()),
            author_is_bot: core.author_is_bot,
            author,
            state,
            draft,
            standing,
            checks,
            has_details: workload.is_some(),
            reviewers,
            assignees: workload.as_ref().map(|w| w.assignees.iter().map(|p| (p.login.clone(), p.avatar_url.clone())).collect()).unwrap_or_default(),
            linked,
            additions: core.additions,
            deletions: core.deletions,
            files: core.changed_files,
            branch: metrics.as_ref().and_then(|m| m.head_ref.clone()),
            first_commit_at: metrics.as_ref().and_then(|m| m.first_commit_at),
            ready_at: metrics.as_ref().and_then(|m| m.ready_at),
            last_commit_at: workload.as_ref().and_then(|w| w.last_commit_at),
            created_at: core.created_at,
            updated_at,
            merged_at: core.merged_at,
            closed_at: if state == PrState::Closed { work_log.as_ref().and_then(|w| w.closed_at) } else { None },
            merged_by: work_log.as_ref().and_then(|w| w.merged_by.clone()),
            commits: work_log.as_ref().map(|w| w.commits.clone()).unwrap_or_default(),
            reviews: work_log.as_ref().map(|w| w.reviews.clone()).unwrap_or_default(),
            id: core.id,
            number: core.number,
            title: core.title,
            url: core.url,
            repo: core.repo,
        })
    }
}

fn cache_path(org: &str) -> PathBuf {
    crate::cache::path(crate::cache::Kind::PullRequests, org)
}

pub(crate) fn load(org: &str) -> Result<Vec<PrItem>, String> {
    // Nothing synced yet (a fresh install) is an empty cache, not an error.
    let bytes = match std::fs::read(cache_path(org)) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.to_string()),
    };
    let file: File = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
    Ok(file.pull_requests.into_values().filter_map(PrItem::from).collect())
}

// MARK: - Filters

/// Special values: you, and a PR nobody's asked to review or has.
const ME: &str = "@me";
const NO_REVIEWER: &str = "";
const NO_CHECKS: &str = "";

/// Whether you're asked to review a PR, for the Requested column and
/// filter: asked and not yet reviewed since, reviewed it without a request
/// now, or neither. Only a request to you by name counts: a team's request
/// isn't cached with its members. None when signed out.
const ASKED: &str = "Requested";
const REVIEWED: &str = "Reviewed";
const NOT_ASKED: &str = "Not requested";

fn your_request(pr: &PrItem, me: Option<&str>) -> Option<&'static str> {
    let me = me?;
    Some(match pr.reviewers.iter().find(|r| r.login.eq_ignore_ascii_case(me)) {
        Some(r) if r.requested => ASKED,
        Some(_) => REVIEWED,
        None => NOT_ASKED,
    })
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Key {
    Status,
    Author,
    Reviewer,
    Requested,
    Checks,
    Repository,
}

impl Key {
    const ALL: [Key; 6] = [Key::Status, Key::Author, Key::Reviewer, Key::Requested, Key::Checks, Key::Repository];

    fn title(self) -> &'static str {
        match self {
            Key::Status => "Status",
            Key::Author => "Author",
            Key::Reviewer => "Reviewer",
            Key::Requested => "Requested",
            Key::Checks => "Checks",
            Key::Repository => "Repository",
        }
    }
}

#[derive(Clone, PartialEq, Eq, Debug)]
enum Menu {
    State,
    Key(Key),
    Columns,
}

#[derive(Default, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Filters {
    search: String,
    statuses: BTreeSet<String>,
    authors: BTreeSet<String>,
    reviewers: BTreeSet<String>,
    /// Requested of you, Reviewed or Not requested.
    requested: BTreeSet<String>,
    checks: BTreeSet<String>,
    repositories: BTreeSet<String>,
    /// Menus whose picks leave PRs out rather than keep them, by title.
    excluding: BTreeSet<String>,
    /// The window's Filter box, matched as the search is: never saved.
    #[serde(skip)]
    outer: String,
}

impl Filters {
    fn excludes(&self, key: Key) -> bool {
        self.excluding.contains(key.title())
    }

    fn is_narrowed(&self) -> bool {
        !self.search.is_empty() || !self.outer.trim().is_empty() || Key::ALL.iter().any(|k| !self.values(*k).is_empty())
    }

    fn values(&self, key: Key) -> &BTreeSet<String> {
        match key {
            Key::Status => &self.statuses,
            Key::Author => &self.authors,
            Key::Reviewer => &self.reviewers,
            Key::Requested => &self.requested,
            Key::Checks => &self.checks,
            Key::Repository => &self.repositories,
        }
    }

    fn values_mut(&mut self, key: Key) -> &mut BTreeSet<String> {
        match key {
            Key::Status => &mut self.statuses,
            Key::Author => &mut self.authors,
            Key::Reviewer => &mut self.reviewers,
            Key::Requested => &mut self.requested,
            Key::Checks => &mut self.checks,
            Key::Repository => &mut self.repositories,
        }
    }
}

/// A PR's values for a filter, as the menu offers them.
fn values_of(pr: &PrItem, key: Key, me: Option<&str>) -> Vec<String> {
    let mine = |login: Option<&str>| me.is_some() && login == me;
    match key {
        Key::Status => pr.standing.map(|s| vec![s.title().to_string()]).unwrap_or_default(),
        Key::Author => {
            let mut v: Vec<String> = pr.author.iter().cloned().collect();
            if mine(pr.author.as_deref()) {
                v.push(ME.into());
            }
            v
        }
        Key::Reviewer => {
            let mut v: Vec<String> = pr.reviewer_logins().map(str::to_string).collect();
            if pr.reviewers.is_empty() {
                v.push(NO_REVIEWER.into());
            }
            if pr.reviewer_logins().any(|l| mine(Some(l))) {
                v.push(ME.into());
            }
            v
        }
        Key::Requested => your_request(pr, me).map(|v| vec![v.to_string()]).unwrap_or_default(),
        // Only open PRs with details have checks to speak of.
        Key::Checks if pr.state == PrState::Open && pr.has_details => {
            vec![pr.checks.map_or(NO_CHECKS.to_string(), |c| c.title().to_string())]
        }
        Key::Checks => Vec::new(),
        Key::Repository => vec![pr.repo.clone()],
    }
}

fn matches(filters: &Filters, pr: &PrItem, except: Option<Key>, me: Option<&str>) -> bool {
    for key in Key::ALL {
        let picked = filters.values(key);
        if Some(key) == except || picked.is_empty() {
            continue;
        }
        let have = values_of(pr, key, me);
        if picked.iter().any(|v| have.contains(v)) == filters.excludes(key) {
            return false;
        }
    }
    matches_search(&filters.search, pr) && matches_search(&filters.outer, pr)
}

/// Every word typed is in the title, the repo, `#123`, the branch or a
/// person's login or name.
pub(crate) fn matches_search(search: &str, pr: &PrItem) -> bool {
    let words: Vec<String> = search.split_whitespace().map(str::to_lowercase).collect();
    if words.is_empty() {
        return true;
    }
    let number = pr.number.to_string();
    let hash = format!("#{number}");
    let mut fields: Vec<&str> = vec![&pr.title, &pr.repo, &hash, &number];
    fields.extend(pr.author.as_deref());
    fields.extend(pr.author_name.as_deref());
    fields.extend(pr.branch.as_deref());
    fields.extend(pr.reviewers.iter().map(|r| r.login.as_str()));
    fields.extend(pr.reviewers.iter().filter_map(|r| r.name.as_deref()));
    fields.extend(pr.assignees.iter().map(|(l, _)| l.as_str()));
    let fields: Vec<String> = fields.iter().map(|f| f.to_lowercase()).collect();
    words.iter().all(|word| fields.iter().any(|f| f.contains(word.as_str())))
}

struct Choice {
    value: String,
    title: String,
    count: usize,
}

// MARK: - Columns

#[derive(Clone, PartialEq, Eq, Hash, Debug, serde::Serialize, serde::Deserialize)]
enum Column {
    State,
    Status,
    Title,
    Repository,
    Number,
    Author,
    Reviewers,
    /// Whether you're asked to review it.
    Requested,
    Assignees,
    Checks,
    /// The merge risk its latest review graded.
    Risk,
    Linked,
    Files,
    Size,
    Branch,
    Opened,
    Updated,
    Merged,
    Closed,
}

impl Column {
    fn defaults() -> Vec<Column> {
        use Column::*;
        vec![State, Status, Title, Repository, Number, Author, Reviewers, Requested, Checks, Risk, Size, Updated]
    }

    fn all() -> Vec<Column> {
        use Column::*;
        vec![State, Status, Title, Repository, Number, Author, Reviewers, Requested, Assignees, Checks, Risk, Linked, Files, Size, Branch, Opened, Updated, Merged, Closed]
    }

    fn title(&self) -> &'static str {
        match self {
            Column::State => "State",
            Column::Status => "Status",
            Column::Title => "Title",
            Column::Repository => "Repository",
            Column::Number => "Number",
            Column::Author => "Author",
            Column::Reviewers => "Reviewers",
            Column::Requested => "Requested",
            Column::Assignees => "Assignees",
            Column::Checks => "Checks",
            Column::Risk => "Risk",
            Column::Linked => "Linked",
            Column::Files => "Files",
            Column::Size => "Size",
            Column::Branch => "Branch",
            Column::Opened => "Opened",
            Column::Updated => "Updated",
            Column::Merged => "Merged",
            Column::Closed => "Closed",
        }
    }

    fn width(&self) -> Option<f32> {
        Some(match self {
            Column::Title => return None,
            Column::State => 76.,
            Column::Status => 140.,
            Column::Repository => 120.,
            Column::Number => 64.,
            Column::Author => 64.,
            Column::Reviewers | Column::Assignees => 100.,
            Column::Requested => 104.,
            Column::Checks => 56.,
            Column::Risk => 76.,
            Column::Linked | Column::Files => 56.,
            Column::Size => 110.,
            Column::Branch => 180.,
            Column::Opened | Column::Updated | Column::Merged | Column::Closed => 96.,
        })
    }

    fn sorts_descending(&self) -> bool {
        matches!(self, Column::Opened | Column::Updated | Column::Merged | Column::Closed | Column::Linked | Column::Files | Column::Size | Column::Risk)
    }

    fn id(&self) -> SharedString {
        SharedString::from(format!("pr-column-{}", self.title()))
    }
}

#[derive(Clone)]
struct DraggedColumn(Column);

fn sound_columns(columns: &[Column]) -> Vec<Column> {
    let mut seen = HashSet::new();
    let mut sound: Vec<Column> = columns.iter().filter(|c| seen.insert((*c).clone())).cloned().collect();
    if !sound.contains(&Column::Title) {
        sound.insert(0, Column::Title);
    }
    sound
}

#[derive(Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct PrsSaved {
    states: BTreeSet<PrState>,
    filters: Filters,
    sort: Column,
    descending: bool,
    columns: Vec<Column>,
    widths: BTreeMap<String, f32>,
}

impl PrsSaved {
    /// For a new tab: these columns and order, with nothing filtered.
    pub fn fresh(&self) -> Self {
        Self { sort: self.sort.clone(), descending: self.descending, columns: self.columns.clone(), widths: self.widths.clone(), ..Self::default() }
    }
}

impl Default for PrsSaved {
    fn default() -> Self {
        Self {
            states: BTreeSet::from([PrState::Open]),
            filters: Filters::default(),
            sort: Column::Updated,
            descending: true,
            columns: Column::defaults(),
            widths: BTreeMap::new(),
        }
    }
}

// MARK: - The page

/// A row was clicked; the workspace opens it in a drawer.
pub struct OpenPr(pub PrItem);

impl EventEmitter<OpenPr> for PrsPage {}

/// Review with Claude for each of these, picked together in the table.
pub struct ReviewPrs(pub Vec<PrItem>);

impl EventEmitter<ReviewPrs> for PrsPage {}

/// Show the review session open for this PR.
pub struct ShowReview(pub PrItem);

impl EventEmitter<ShowReview> for PrsPage {}

pub struct PrsPage {
    org: Option<String>,
    prs: Arc<Vec<PrItem>>,
    rows: Vec<usize>,
    pool_count: usize,
    focus: Option<HashSet<String>>,
    /// The signed-in login, for Me.
    me: Option<String>,
    states: BTreeSet<PrState>,
    filters: Filters,
    sort: (Column, bool),
    columns: Vec<Column>,
    widths: BTreeMap<String, f32>,
    resizing: Option<(Column, f32, f32)>,
    selected: Option<String>,
    /// Rows picked together with Command or Shift, by PR id, and the row a
    /// Shift-click range starts from.
    picked: Vec<String>,
    anchor: Option<usize>,
    open_menu: Option<Menu>,
    closed_menu: Option<(Menu, Instant)>,
    search_focus: FocusHandle,
    error: Option<String>,
    loading: bool,
    timings: String,
    generation: u64,
    /// PRs with a review session in a tab, by id: whether it's running.
    reviewing: HashMap<String, bool>,
    _subscriptions: Vec<Subscription>,
}

const ROW_HEIGHT: f32 = 30.0;

impl PrsPage {
    pub fn new(org: Option<String>, saved: &PrsSaved, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search_focus = cx.focus_handle();
        let subscriptions = vec![
            cx.observe_window_appearance(window, |_, _, cx| cx.notify()),
            cx.on_blur(&search_focus, window, |_, _, cx| cx.notify()),
        ];
        let mut page = Self {
            org,
            prs: Arc::new(Vec::new()),
            rows: Vec::new(),
            pool_count: 0,
            focus: None,
            me: None,
            states: saved.states.clone(),
            filters: Filters { search: String::new(), ..saved.filters.clone() },
            sort: (saved.sort.clone(), saved.descending),
            columns: sound_columns(&saved.columns),
            widths: saved.widths.clone(),
            resizing: None,
            selected: None,
            picked: Vec::new(),
            anchor: None,
            open_menu: None,
            closed_menu: None,
            search_focus,
            error: None,
            loading: false,
            timings: String::new(),
            generation: 0,
            reviewing: HashMap::new(),
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
            // Me carries over; another org's people and repos don't.
            let mine_only = |set: &BTreeSet<String>| set.iter().filter(|v| v.as_str() == ME).cloned().collect::<BTreeSet<_>>();
            self.filters = Filters {
                statuses: self.filters.statuses.clone(),
                checks: self.filters.checks.clone(),
                authors: mine_only(&self.filters.authors),
                reviewers: mine_only(&self.filters.reviewers),
                requested: self.filters.requested.clone(),
                ..Filters::default()
            };
            self.load(cx);
        }
    }

    /// The PRs with a review session open, from the window's tabs.
    pub fn set_reviewing(&mut self, reviewing: HashMap<String, bool>, cx: &mut Context<Self>) {
        if self.reviewing != reviewing {
            self.reviewing = reviewing;
            cx.notify();
        }
    }

    pub fn set_me(&mut self, me: Option<String>, cx: &mut Context<Self>) {
        if me != self.me {
            self.me = me;
            self.refilter();
            cx.notify();
        }
    }

    pub fn set_focus(&mut self, focus: Option<Vec<String>>, cx: &mut Context<Self>) {
        let focus = focus.map(|repos| repos.into_iter().collect::<HashSet<_>>());
        if focus != self.focus {
            self.focus = focus;
            self.refilter();
            cx.notify();
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
            self.prs = Arc::new(Vec::new());
            self.rows.clear();
        }
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let started = Instant::now();
                    load(&org).map(|prs| (prs, started.elapsed()))
                })
                .await;
            this.update(cx, |page, cx| {
                if page.generation != generation {
                    return;
                }
                page.loading = false;
                page.error = result.as_ref().err().cloned();
                match result {
                    Ok((prs, elapsed)) => {
                        page.timings = format!("read {} in {} ms", thousands(prs.len()), elapsed.as_millis());
                        page.prs = Arc::new(prs);
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

    pub fn saved(&self) -> PrsSaved {
        PrsSaved {
            states: self.states.clone(),
            filters: Filters { search: String::new(), ..self.filters.clone() },
            sort: self.sort.0.clone(),
            descending: self.sort.1,
            columns: self.columns.clone(),
            widths: self.widths.clone(),
        }
    }

    pub fn is_resizing(&self) -> bool {
        self.resizing.is_some()
    }

    pub fn tab_count(&self) -> Option<String> {
        if self.loading || self.error.is_some() {
            return None;
        }
        let count = self.rows.len();
        Some(if count == self.pool_count { thousands(count) } else { format!("{} of {}", thousands(count), thousands(self.pool_count)) })
    }

    fn in_focus(&self, pr: &PrItem) -> bool {
        self.focus.as_ref().is_none_or(|repos| repos.contains(&pr.repo))
    }

    fn in_state(&self, pr: &PrItem) -> bool {
        self.states.is_empty() || self.states.contains(&pr.state)
    }

    fn pool(&self) -> impl Iterator<Item = &PrItem> {
        self.prs.iter().filter(|p| self.in_focus(p) && self.in_state(p))
    }

    fn refilter(&mut self) {
        let prs = self.prs.clone();
        let me = self.me.as_deref();
        self.pool_count = self.pool().count();
        let mut rows: Vec<usize> = (0..prs.len())
            .filter(|&i| self.in_focus(&prs[i]) && self.in_state(&prs[i]) && matches(&self.filters, &prs[i], None, me))
            .collect();
        let sort = self.sort.clone();
        rows.sort_by(|a, b| compare(&prs[*a], &prs[*b], &sort, me));
        self.rows = rows;
    }

    // MARK: Menus

    fn title_for(&self, key: Key, value: &str) -> String {
        match (key, value) {
            (Key::Author | Key::Reviewer, ME) => "Me".into(),
            (Key::Reviewer, NO_REVIEWER) => "No reviewer".into(),
            (Key::Checks, NO_CHECKS) => "No checks".into(),
            (Key::Repository, repo) => repo.rsplit('/').next().unwrap_or(repo).to_string(),
            (Key::Author | Key::Reviewer, login) => self.person_name(login),
            (_, value) => value.to_string(),
        }
    }

    fn person_name(&self, login: &str) -> String {
        self.prs
            .iter()
            .find_map(|p| {
                if p.author.as_deref() == Some(login) {
                    p.author_name.clone()
                } else {
                    p.reviewers.iter().find(|r| r.login == login).and_then(|r| r.name.clone())
                }
            })
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| login.to_string())
    }

    fn choices(&self, key: Key) -> (Vec<Choice>, Vec<Choice>) {
        let me = self.me.as_deref();
        let mut counts: HashMap<String, usize> = HashMap::new();
        for pr in self.pool().filter(|p| matches(&self.filters, p, Some(key), me)) {
            for value in values_of(pr, key, me).into_iter().collect::<BTreeSet<_>>() {
                *counts.entry(value).or_default() += 1;
            }
        }
        for value in self.filters.values(key) {
            counts.entry(value.clone()).or_default();
        }
        let special: Vec<&str> = match key {
            Key::Author if me.is_some() => vec![ME],
            Key::Reviewer if me.is_some() => vec![ME, NO_REVIEWER],
            Key::Reviewer => vec![NO_REVIEWER],
            Key::Requested => vec![ASKED, REVIEWED, NOT_ASKED],
            Key::Checks => vec![NO_CHECKS],
            _ => Vec::new(),
        };
        let choice = |value: &str, count: usize| Choice { value: value.to_string(), title: self.title_for(key, value), count };
        let leading: Vec<Choice> = special.iter().map(|v| choice(v, counts.get(*v).copied().unwrap_or(0))).collect();
        let mut rest: Vec<Choice> =
            counts.iter().filter(|(v, _)| !special.contains(&v.as_str())).map(|(v, c)| choice(v, *c)).collect();
        rest.sort_by(|a, b| {
            let first = match key {
                // In the order a PR moves through review.
                Key::Status => Standing::from_title(&a.value).cmp(&Standing::from_title(&b.value)),
                Key::Checks => a.value.cmp(&b.value),
                Key::Author | Key::Reviewer => b.count.cmp(&a.count),
                Key::Requested | Key::Repository => std::cmp::Ordering::Equal,
            };
            first.then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
        });
        (leading, rest)
    }

    fn set_excluding(&mut self, key: Key, exclude: bool, cx: &mut Context<Self>) {
        if exclude {
            self.filters.excluding.insert(key.title().to_string());
        } else {
            self.filters.excluding.remove(key.title());
        }
        self.refilter();
        cx.notify();
    }

    fn toggle_menu(&mut self, menu: Menu, cx: &mut Context<Self>) {
        let just_closed = self.closed_menu.take().is_some_and(|(m, at)| m == menu && at.elapsed() < Duration::from_millis(300));
        self.open_menu = if self.open_menu.as_ref() == Some(&menu) || just_closed { None } else { Some(menu) };
        cx.notify();
    }

    fn button_label(&self, menu: &Menu) -> (String, bool) {
        match menu {
            Menu::Columns => ("Columns".into(), false),
            Menu::State => {
                let titles: Vec<&str> = self.states.iter().map(|s| s.title()).collect();
                let label = if titles.is_empty() { "Any".to_string() } else { titles.join(", ") };
                (format!("State: {label}"), self.states != BTreeSet::from([PrState::Open]))
            }
            Menu::Key(key) => {
                let picked = self.filters.values(*key);
                if picked.is_empty() {
                    (key.title().to_string(), false)
                } else {
                    let mut titles: Vec<String> = picked.iter().map(|v| self.title_for(*key, v)).collect();
                    titles.sort_by_key(|t| t.to_lowercase());
                    let not = if self.filters.excludes(*key) { "not " } else { "" };
                    (format!("{}: {not}{}", key.title(), summary(&titles, 2)), true)
                }
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
                    .id(SharedString::from(format!("pr-filter-{menu:?}")))
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
            .when(open, |d| d.child(deferred(anchored().snap_to_window_with_margin(px(8.)).child(self.menu_panel(&menu, theme, cx))).with_priority(1)))
    }

    fn menu_panel(&self, menu: &Menu, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let closing = menu.clone();
        let panel = div()
            .id("pr-filter-menu")
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
            .occlude()
            .on_mouse_down_out(cx.listener(move |page, _: &MouseDownEvent, _, cx| {
                if page.open_menu.take().is_some() {
                    page.closed_menu = Some((closing.clone(), Instant::now()));
                    cx.notify();
                }
            }));
        match menu {
            Menu::Columns => panel.children(self.columns_panel(theme, cx)).into_any_element(),
            Menu::State => {
                let me = self.me.as_deref();
                panel
                    .children(PrState::ALL.into_iter().map(|state| {
                        let count = self.prs.iter().filter(|p| self.in_focus(p) && p.state == state && matches(&self.filters, p, None, me)).count();
                        check_row(SharedString::from(format!("pr-state-{}", state.title())), self.states.contains(&state), state.title().into(), count, 0., theme)
                            .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                                if !page.states.remove(&state) {
                                    page.states.insert(state);
                                }
                                page.refilter();
                                cx.notify();
                            }))
                    }))
                    .when(!self.states.is_empty(), |d| {
                        d.child(separator(theme)).child(menu_action("pr-any-state", "Any State", theme).on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                            page.states.clear();
                            page.refilter();
                            cx.notify();
                        })))
                    })
                    .into_any_element()
            }
            Menu::Key(key) => {
                let key = *key;
                let (leading, rest) = self.choices(key);
                let picked = self.filters.values(key).clone();
                let has_leading = !leading.is_empty();
                let include = cx.listener(move |page: &mut Self, _: &ClickEvent, _, cx| page.set_excluding(key, false, cx));
                let exclude = cx.listener(move |page: &mut Self, _: &ClickEvent, _, cx| page.set_excluding(key, true, cx));
                let modes = mode_switch(key.title(), self.filters.excludes(key), theme, include, exclude);
                let row = |choice: Choice, cx: &mut Context<Self>| {
                    let checked = picked.contains(&choice.value);
                    let value = choice.value.clone();
                    check_row(SharedString::from(format!("pr-{key:?}-{}", choice.value)), checked, choice.title, choice.count, 0., theme).on_click(
                        cx.listener(move |page, _: &ClickEvent, _, cx| {
                            let values = page.filters.values_mut(key);
                            if !values.remove(&value) {
                                values.insert(value.clone());
                            }
                            page.refilter();
                            cx.notify();
                        }),
                    )
                };
                let leading: Vec<_> = leading.into_iter().map(|c| row(c, cx)).collect();
                let rest: Vec<_> = rest.into_iter().map(|c| row(c, cx)).collect();
                let has_rest = !rest.is_empty();
                panel
                    .child(modes)
                    .children(leading)
                    .when(has_leading && has_rest, |d| d.child(separator(theme)))
                    .children(rest)
                    .when(!picked.is_empty(), |d| {
                        d.child(separator(theme)).child(menu_action("pr-clear", "Clear", theme).on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                            page.filters.values_mut(key).clear();
                            page.filters.excluding.remove(key.title());
                            page.refilter();
                            cx.notify();
                        })))
                    })
                    .into_any_element()
            }
        }
    }

    // MARK: Search

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
            .id("pr-search")
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
            .child(div().flex_1().min_w_0().truncate().map(|d| {
                if text.is_empty() {
                    d.text_color(theme.tertiary).child(if focused { "|".to_string() } else { "Title, number, person or branch".to_string() })
                } else {
                    d.child(if focused { format!("{text}|") } else { text.clone() })
                }
            }))
            .when(!text.is_empty(), |d| {
                d.child(
                    div()
                        .id("pr-clear-search")
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
        // Status and Checks only mean something for open PRs.
        let any_open = self.pool().any(|p| p.state == PrState::Open);
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
            .when(any_open || !self.filters.statuses.is_empty(), |d| d.child(self.menu_button(Menu::Key(Key::Status), theme, cx)))
            .child(self.menu_button(Menu::Key(Key::Author), theme, cx))
            .child(self.menu_button(Menu::Key(Key::Reviewer), theme, cx))
            .when(self.me.is_some(), |d| d.child(self.menu_button(Menu::Key(Key::Requested), theme, cx)))
            .when(any_open || !self.filters.checks.is_empty(), |d| d.child(self.menu_button(Menu::Key(Key::Checks), theme, cx)))
            .child(self.menu_button(Menu::Key(Key::Repository), theme, cx))
            .when(self.filters.is_narrowed(), |d| {
                d.child(
                    div()
                        .id("pr-clear-all")
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
            .child(div().flex_1())
            .child(self.menu_button(Menu::Columns, theme, cx))
    }

    // MARK: Rows

    fn row(&self, index: usize, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let pr = &self.prs[self.rows[index]];
        let selected = self.selected.as_deref() == Some(pr.id.as_str());
        let picked = self.picked.contains(&pr.id);
        let opened = pr.clone();
        div()
            .id(("pr", index))
            .when(picked, |d| d.bg(theme.selected.opacity(0.16)))
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
                    // Command toggles a row; the one showing joins the first pick.
                    if page.picked.is_empty() {
                        if let Some(current) = page.selected.clone().filter(|c| *c != opened.id) {
                            page.picked.push(current);
                        }
                    }
                    if let Some(at) = page.picked.iter().position(|id| *id == opened.id) {
                        page.picked.remove(at);
                    } else {
                        page.picked.push(opened.id.clone());
                    }
                    page.anchor = Some(index);
                } else if modifiers.shift {
                    // Shift picks the rows from the last one clicked to this.
                    let from = page.anchor.or_else(|| page.selected.as_ref().and_then(|id| page.rows.iter().position(|&r| page.prs[r].id == *id))).unwrap_or(index);
                    let (a, b) = (from.min(index), from.max(index));
                    for row in a..=b {
                        let id = page.prs[page.rows[row]].id.clone();
                        if !page.picked.contains(&id) {
                            page.picked.push(id);
                        }
                    }
                } else {
                    // A plain click opens the drawer; what's ticked stays.
                    page.anchor = Some(index);
                    page.selected = Some(opened.id.clone());
                    cx.emit(OpenPr(opened.clone()));
                }
                cx.notify();
            }))
            .child(
                div()
                    .id(("pick", index))
                    .flex_none()
                    .p_1()
                    .on_click(cx.listener({
                        let id = pr.id.clone();
                        move |page, _: &ClickEvent, _, cx| {
                            cx.stop_propagation();
                            page.toggle_pick(&id, index);
                            cx.notify();
                        }
                    }))
                    .child(Self::checkbox(Some(picked), theme)),
            )
            .children(self.columns.iter().map(|column| self.cell(column, index, theme, cx)))
    }

    fn cell(&self, column: &Column, index: usize, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        let pr = &self.prs[self.rows[index]];
        let now = Utc::now();
        let width = self.column_width(column).unwrap_or(0.);
        let text = |value: String| div().w(px(width)).flex_none().truncate().child(value);
        let quiet = |value: String| text(value).text_color(theme.secondary);
        let when = |date: Option<DateTime<Utc>>| quiet(date.map(crate::format::table_date).unwrap_or_default());
        let count = |n: usize| quiet(if n > 0 { n.to_string() } else { String::new() });
        match column {
            Column::Title => div()
                .flex_1()
                .min_w(px(220.))
                .overflow_hidden()
                .flex()
                .flex_row()
                .items_center()
                .gap_1p5()
                .child(div().flex_shrink(1.).min_w(px(60.)).truncate().child(pr.title.clone()))
                .when(pr.author_is_bot, |d| d.child(div().flex_none().text_xs().text_color(theme.tertiary).child("bot")))
                // Its merge risk, here when the Risk column isn't shown.
                .when_some(crate::risk::level_for(&pr.id).filter(|_| !self.columns.contains(&Column::Risk)), |d, level| d.child(risk_pill(level, theme)))
                // A review session open for it, to click through to.
                .when_some(self.reviewing.get(&pr.id).copied(), |d, running| {
                    let item = pr.clone();
                    let tint = if running { theme.good() } else { theme.secondary };
                    d.child(
                        div()
                            .id(gpui::ElementId::Name(format!("reviewing-{}", pr.id).into()))
                            .flex_none()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_1()
                            .px_1p5()
                            .rounded_md()
                            .border_1()
                            .border_color(tint.opacity(0.5))
                            .text_xs()
                            .text_color(tint)
                            .cursor_pointer()
                            .hover(|s| s.bg(tint.opacity(0.15)))
                            .child(div().size(px(6.)).rounded_full().bg(tint))
                            .child(if running { "Reviewing" } else { "Review stopped" })
                            .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| {
                                cx.stop_propagation();
                                cx.emit(ShowReview(item.clone()));
                            })),
                    )
                })
                .into_any_element(),
            Column::State => div().w(px(width)).flex_none().flex().overflow_hidden().child(state_pill(pr, theme)).into_any_element(),
            Column::Status => div()
                .w(px(width))
                .flex_none()
                .flex()
                .flex_row()
                .items_center()
                .gap_1p5()
                .overflow_hidden()
                .when_some(pr.standing, |d, standing| {
                    d.child(div().size(px(7.)).flex_none().rounded_full().bg(standing.color(theme)))
                        .child(div().flex_shrink(1.).min_w_0().truncate().child(standing.title()))
                })
                .when(pr.is_stale(now), |d| d.child(div().flex_none().text_xs().text_color(theme.tertiary).child("stale")))
                .into_any_element(),
            Column::Repository => quiet(pr.repo_name.clone()).into_any_element(),
            Column::Number => quiet(format!("#{}", pr.number)).into_any_element(),
            Column::Author => {
                let name = pr.author_name.clone().or(pr.author.clone()).unwrap_or_default();
                div()
                    .id(("pr-author", index))
                    .w(px(width))
                    .flex_none()
                    .flex()
                    .items_center()
                    .overflow_hidden()
                    .when_some(pr.author.clone(), |d, login| d.child(avatar(&login, pr.author_avatar.as_deref(), 20., theme, cx)))
                    .when(!name.is_empty(), |d| d.tooltip(move |_, cx| cx.new(|_| Tooltip(name.clone())).into()))
                    .into_any_element()
            }
            Column::Reviewers => {
                let people: Vec<(String, Option<String>)> = pr.reviewers.iter().map(|r| (r.login.clone(), r.avatar.clone())).collect();
                let names = pr.reviewers.iter().map(|r| format!("{} ({})", r.name.clone().unwrap_or(r.login.clone()), r.standing())).collect::<Vec<_>>().join("\n");
                div()
                    .id(("pr-reviewers", index))
                    .w(px(width))
                    .flex_none()
                    .flex()
                    .items_center()
                    .overflow_hidden()
                    .when(!people.is_empty(), |d| d.child(stack(&people, 20., theme, cx)).tooltip(move |_, cx| cx.new(|_| Tooltip(names.clone())).into()))
                    .into_any_element()
            }
            // Requested with an orange dot (it's waiting on you), Reviewed
            // quieter, nothing when you're not involved.
            Column::Requested => {
                let (label, waiting) = match your_request(pr, self.me.as_deref()) {
                    Some(ASKED) => (ASKED, true),
                    Some(REVIEWED) => (REVIEWED, false),
                    _ => ("", false),
                };
                div()
                    .w(px(width))
                    .flex_none()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1p5()
                    .overflow_hidden()
                    .text_color(if waiting { theme.fg } else { theme.secondary })
                    .when(waiting, |d| d.child(div().size(px(7.)).flex_none().rounded_full().bg(theme.orange())))
                    .child(div().min_w_0().truncate().child(label))
                    .into_any_element()
            }
            Column::Assignees => {
                let people = pr.assignees.clone();
                let names = people.iter().map(|(l, _)| l.clone()).collect::<Vec<_>>().join(", ");
                div()
                    .id(("pr-assignees", index))
                    .w(px(width))
                    .flex_none()
                    .flex()
                    .items_center()
                    .overflow_hidden()
                    .when(!people.is_empty(), |d| d.child(stack(&people, 20., theme, cx)).tooltip(move |_, cx| cx.new(|_| Tooltip(names.clone())).into()))
                    .into_any_element()
            }
            // A coloured badge, its name on hover.
            Column::Checks => div()
                .id(("pr-checks", index))
                .w(px(width))
                .flex_none()
                .flex()
                .items_center()
                .when_some(pr.checks, |d, checks| {
                    d.child(checks_badge(checks, theme)).tooltip(move |_, cx| cx.new(|_| Tooltip(checks.title().to_string())).into())
                })
                .into_any_element(),
            Column::Risk => div()
                .w(px(width))
                .flex_none()
                .flex()
                .items_center()
                .when_some(crate::risk::level_for(&pr.id), |d, level| d.child(risk_pill(level, theme)))
                .into_any_element(),
            Column::Linked => count(pr.linked.len()).into_any_element(),
            Column::Files => quiet(pr.files.map(|f| f.to_string()).unwrap_or_default()).into_any_element(),
            Column::Size => div()
                .w(px(width))
                .flex_none()
                .flex()
                .flex_row()
                .gap_1p5()
                .overflow_hidden()
                .text_xs()
                .when_some(pr.additions, |d, a| d.child(div().text_color(theme.good()).child(format!("+{}", thousands(a as usize)))))
                .when_some(pr.deletions, |d, r| d.child(div().text_color(theme.critical()).child(format!("−{}", thousands(r as usize)))))
                .into_any_element(),
            Column::Branch => quiet(pr.branch.clone().unwrap_or_default()).into_any_element(),
            Column::Opened => when(Some(pr.created_at)).into_any_element(),
            Column::Updated => when(Some(pr.updated_at)).into_any_element(),
            Column::Merged => when(pr.merged_at).into_any_element(),
            Column::Closed => when(pr.closed_at).into_any_element(),
        }
    }

    // MARK: Columns

    fn column_width(&self, column: &Column) -> Option<f32> {
        let default = column.width()?;
        Some(self.widths.get(column.title()).copied().unwrap_or(default))
    }

    fn resize(&mut self, event: &gpui::MouseMoveEvent, _: &mut Window, cx: &mut Context<Self>) {
        let Some((column, start, width)) = self.resizing.clone() else { return };
        if event.pressed_button != Some(gpui::MouseButton::Left) {
            self.resizing = None;
            cx.notify();
            return;
        }
        let width = (width + f32::from(event.position.x) - start).clamp(40.0, 600.0);
        self.widths.insert(column.title().to_string(), width);
        cx.notify();
    }

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

    fn columns_panel(&self, theme: &Theme, cx: &mut Context<Self>) -> Vec<gpui::AnyElement> {
        let mut rows: Vec<gpui::AnyElement> = vec![menu_heading("Shown", theme).into_any_element()];
        let last = self.columns.len().saturating_sub(1);
        for (position, column) in self.columns.iter().enumerate() {
            let fixed = *column == Column::Title;
            let (hidden, up, down) = (column.clone(), column.clone(), column.clone());
            let arrow = |id: &str, label: &'static str, enabled: bool| {
                div()
                    .id(SharedString::from(format!("pr-{id}-{}", column.title())))
                    .px_1()
                    .rounded_sm()
                    .text_color(if enabled { theme.secondary } else { theme.border })
                    .when(enabled, |d| d.cursor_pointer().hover(|s| s.bg(theme.row_selected)))
                    .child(label)
            };
            let shift = |by: isize, column: Column| {
                cx.listener(move |page: &mut Self, _: &ClickEvent, _, cx| {
                    let Some(from) = page.columns.iter().position(|c| *c == column) else { return };
                    let to = (from as isize + by).clamp(0, page.columns.len() as isize - 1) as usize;
                    let moved = page.columns.remove(from);
                    page.columns.insert(to, moved);
                    cx.notify();
                })
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
                            .id(SharedString::from(format!("pr-shown-{}", column.title())))
                            .flex_1()
                            .flex()
                            .flex_row()
                            .gap_2()
                            .when(!fixed, |d| {
                                d.cursor_pointer().on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                                    page.columns.retain(|c| *c != hidden);
                                    cx.notify();
                                }))
                            })
                            .child(div().w(px(12.)).text_color(if fixed { theme.tertiary } else { theme.selected }).child("✓"))
                            .child(div().flex_1().truncate().when(fixed, |d| d.text_color(theme.secondary)).child(column.title())),
                    )
                    .child(arrow("up", "↑", position > 0).when(position > 0, |d| d.on_click(shift(-1, up))))
                    .child(arrow("down", "↓", position < last).when(position < last, |d| d.on_click(shift(1, down))))
                    .into_any_element(),
            );
        }
        let more: Vec<Column> = Column::all().into_iter().filter(|c| !self.columns.contains(c)).collect();
        if !more.is_empty() {
            rows.push(separator(theme).into_any_element());
            rows.push(menu_heading("More", theme).into_any_element());
            for column in more {
                let added = column.clone();
                rows.push(
                    menu_action_owned(SharedString::from(format!("pr-add-{}", column.title())), format!("    {}", column.title()), theme)
                        .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                            if !page.columns.contains(&added) {
                                page.columns.push(added.clone());
                            }
                            cx.notify();
                        }))
                        .into_any_element(),
                );
            }
        }
        rows.push(separator(theme).into_any_element());
        rows.push(
            menu_action("pr-reset-columns", "Reset to Default", theme)
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

fn compare(a: &PrItem, b: &PrItem, (column, descending): &(Column, bool), me: Option<&str>) -> std::cmp::Ordering {
    fn present<T: Ord>(a: Option<T>, b: Option<T>) -> std::cmp::Ordering {
        match (a, b) {
            (Some(a), Some(b)) => a.cmp(&b),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => std::cmp::Ordering::Equal,
        }
    }
    let size = |p: &PrItem| p.additions.zip(p.deletions).map(|(a, d)| a + d);
    // Waiting reviewers count most, then everyone involved.
    let reviewers = |p: &PrItem| p.reviewers.iter().filter(|r| r.requested && r.state.is_none()).count() * 100 + p.reviewers.len();
    let order = match column {
        Column::State => a.state.cmp(&b.state),
        Column::Status => present(a.standing, b.standing),
        Column::Title => a.title.to_lowercase().cmp(&b.title.to_lowercase()),
        Column::Repository => a.repo_name.cmp(&b.repo_name),
        Column::Number => a.number.cmp(&b.number),
        Column::Author => a.author.cmp(&b.author),
        Column::Reviewers => reviewers(a).cmp(&reviewers(b)),
        Column::Requested => {
            let rank = |p: &PrItem| match your_request(p, me) {
                Some(ASKED) => 0,
                Some(REVIEWED) => 1,
                _ => 2,
            };
            rank(a).cmp(&rank(b))
        }
        Column::Assignees => a.assignees.first().map(|x| &x.0).cmp(&b.assignees.first().map(|x| &x.0)),
        Column::Checks => present(a.checks, b.checks),
        Column::Risk => present(crate::risk::level_for(&a.id), crate::risk::level_for(&b.id)),
        Column::Linked => a.linked.len().cmp(&b.linked.len()),
        Column::Files => a.files.cmp(&b.files),
        Column::Size => size(a).cmp(&size(b)),
        Column::Branch => present(a.branch.as_ref(), b.branch.as_ref()),
        Column::Opened => a.created_at.cmp(&b.created_at),
        Column::Updated => a.ended_or_updated().cmp(&b.ended_or_updated()),
        Column::Merged => a.merged_at.cmp(&b.merged_at),
        Column::Closed => a.closed_at.cmp(&b.closed_at),
    };
    let order = order.then(a.number.cmp(&b.number));
    if *descending { order.reverse() } else { order }
}

/// Checks as an icon from Zed's set (Lucide), as `ChecksBadge`: a tick in
/// a green circle, a cross in a red one, and an orange arc that turns while
/// they run.
pub fn checks_badge(checks: Checks, theme: &Theme) -> gpui::AnyElement {
    let color = checks.color(theme);
    match checks {
        Checks::Passing => div()
            .size(px(16.))
            .flex_none()
            .rounded_full()
            .bg(color)
            .flex()
            .items_center()
            .justify_center()
            .child(gpui::svg().path("icons/check.svg").size(px(13.)).text_color(gpui::white()))
            .into_any_element(),
        Checks::Failing => gpui::svg().path("icons/x_circle_filled.svg").size(px(17.)).flex_none().text_color(color).into_any_element(),
        Checks::Running => gpui::svg()
            .path("icons/load_circle.svg")
            .size(px(16.))
            .flex_none()
            .text_color(color)
            .with_timed_transformation(gpui::TimedTransformation::rotation(Duration::from_secs(2), gpui::Transformation::default()))
            .into_any_element(),
    }
}

/// Open in green (a draft in grey), Merged in purple, Closed in red.
pub fn state_pill(pr: &PrItem, theme: &Theme) -> impl IntoElement {
    match pr.state {
        PrState::Open if pr.draft => pill("Draft", theme.secondary),
        PrState::Open => pill("Open", theme.good()),
        PrState::Merged => pill("Merged", theme.slot(6)),
        PrState::Closed => pill("Closed", theme.critical()),
    }
}

impl PrsPage {
    /// A checkbox: ticked, part-ticked (some of the rows) or empty.
    pub(crate) fn checkbox(state: Option<bool>, theme: &Theme) -> gpui::Div {
        let on = state != Some(false);
        div()
            .size(px(14.))
            .flex_none()
            .rounded(px(3.))
            .flex()
            .items_center()
            .justify_center()
            .text_xs()
            .border_1()
            .border_color(if on { theme.selected } else { theme.secondary.opacity(0.6) })
            .when(on, |d| d.bg(theme.selected).text_color(theme.on_selected))
            .child(match state {
                Some(true) => "✓",
                None => "–",
                Some(false) => "",
            })
    }

    fn toggle_pick(&mut self, id: &str, index: usize) {
        if let Some(at) = self.picked.iter().position(|p| p == id) {
            self.picked.remove(at);
        } else {
            self.picked.push(id.to_string());
        }
        self.anchor = Some(index);
    }

    /// The PRs picked together that are still in the list.
    fn picked_prs(&self) -> Vec<PrItem> {
        self.picked.iter().filter_map(|id| self.prs.iter().find(|p| &p.id == id).cloned()).collect()
    }

    /// Along the foot while rows are picked: how many, and Review with
    /// Claude for the open ones.
    fn picked_bar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let picked = self.picked_prs();
        let open: Vec<PrItem> = picked.iter().filter(|p| p.state == PrState::Open).cloned().collect();
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
                d.child(div().text_xs().text_color(theme.secondary).child("Only open pull requests can be reviewed."))
            }))
            .child(button("picked-clear", "Clear".into(), false).on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                page.picked.clear();
                cx.notify();
            })))
            .when(!open.is_empty(), |d| {
                let count = open.len();
                d.child(
                    button("picked-review", if count == 1 { "Review with Claude".into() } else { format!("Review {count} with Claude") }, true).on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                        cx.emit(ReviewPrs(open.clone()));
                        page.picked.clear();
                        cx.notify();
                    })),
                )
            })
    }
}

impl Render for PrsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let (sort, descending) = self.sort.clone();
        let count = self.rows.len();
        let noun = match self.states.iter().collect::<Vec<_>>().as_slice() {
            [PrState::Open] => "open pull requests",
            [PrState::Merged] => "merged pull requests",
            [PrState::Closed] => "pull requests closed without merging",
            _ => "pull requests",
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
                let visible: Vec<String> = self.rows.iter().map(|&r| self.prs[r].id.clone()).collect();
                let ticked = visible.iter().filter(|id| self.picked.contains(id)).count();
                let state = if ticked == 0 { Some(false) } else if ticked == visible.len() { Some(true) } else { None };
                div()
                    .id("pick-all")
                    .flex_none()
                    .p_1()
                    .cursor_pointer()
                    .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                        // Ticks every row showing, or clears them when all are.
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
                    .child(Self::checkbox(state, &theme))
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
                        page.sort = if page.sort.0 == sorted { (sorted.clone(), !page.sort.1) } else { (sorted.clone(), sorted.sorts_descending()) };
                        page.refilter();
                        cx.notify();
                    }))
                    .on_drag(DraggedColumn(column.clone()), |dragged, _, _, cx| cx.new(|_| ColumnDrag(dragged.0.title().to_string())))
                    .drag_over::<DraggedColumn>(move |style, _, _, _| style.bg(landing))
                    .on_drop(cx.listener(move |page, dragged: &DraggedColumn, _, cx| page.move_column(&dragged.0, &onto, cx)))
                    .child(div().truncate().child(format!("{title}{marker}")))
                    .when_some(width, |d, w| {
                        d.child(
                            div()
                                .id(SharedString::from(format!("pr-resize-{}", resized.title())))
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
            div().p_4().text_color(theme.secondary).child(format!("Couldn't read the pull request cache: {error}")).into_any_element()
        } else if self.loading {
            div().p_4().text_color(theme.secondary).child("Loading").into_any_element()
        } else if count == 0 {
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
                "pr-rows",
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
            .child(self.filter_bar(&theme, window, cx))
            .child(column_header)
            .child(div().flex_1().min_h_0().flex().flex_col().child(body))
            .when(!self.picked.is_empty(), |d| d.child(self.picked_bar(&theme, cx)))
            .when(self.open_menu.is_some(), |d| {
                d.child(
                    div()
                        .id("pr-menu-backdrop")
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

/// A merge risk grade as a small coloured pill: a dot and the word.
fn risk_pill(level: crate::risk::Level, theme: &Theme) -> gpui::Div {
    let tint = crate::review_panel::risk_tint(level, theme);
    div()
        .flex_none()
        .flex()
        .flex_row()
        .items_center()
        .gap_1()
        .px_1p5()
        .rounded_md()
        .bg(tint.opacity(0.12))
        .text_xs()
        .text_color(tint)
        .child(div().size(px(6.)).rounded_full().bg(tint))
        .child(level.title())
}
