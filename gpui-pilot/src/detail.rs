//! What an issue's drawer shows beyond the list's fields, as `IssueWindow`
//! has it: the description and comments, timing under the workflow, and the
//! timeline.
//!
//! Text is fetched from GitHub when a drawer opens (`sync::refresh_item`)
//! and kept in the pilot's own `Details.json` beside the org's caches, in
//! Gannin's shape: the description and the last 20 comments with their
//! dates. Until that answers, or when signed out, the drawer shows the
//! pilot's copy, else what Gannin has, read only and only if Gannin is
//! installed: its `Details.json`, then its issue text index
//! (`dev.andon.gannin/IssueText.sqlite`: "@login: text", without dates).
//!
//! Timing follows the org's issue workflow (`IssueWorkflow`), read with
//! its projects from Gannin's settings store (`projects.rs`).

use crate::issues::IssueItem;
use chrono::{DateTime, Local, NaiveDate, Utc};
use serde::Deserialize;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::OnceLock;

// MARK: - Text

pub struct Comment {
    pub author: String,
    pub body: String,
    pub at: Option<DateTime<Utc>>,
    pub url: Option<String>,
}

pub struct IssueText {
    pub body: String,
    /// All comments on the issue, when the cache knows; the list holds the
    /// most recent.
    pub comment_count: Option<usize>,
    pub comments: Vec<Comment>,
}

#[derive(Deserialize, serde::Serialize, Clone)]
struct Cached {
    detail: Detail,
}

#[derive(Deserialize, serde::Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Detail {
    body: String,
    comment_count: usize,
    #[serde(default)]
    recent_comments: Vec<CachedComment>,
}

#[derive(Deserialize, serde::Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct CachedComment {
    url: String,
    author: Option<CachedPerson>,
    body: String,
    created_at: DateTime<Utc>,
}

#[derive(Deserialize, serde::Serialize, Clone)]
struct CachedPerson {
    login: String,
}

fn support() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join("Library/Application Support")
}

/// `Details.json`'s issues, read once.
fn details() -> &'static HashMap<String, Detail> {
    static DETAILS: OnceLock<HashMap<String, Detail>> = OnceLock::new();
    DETAILS.get_or_init(|| {
        std::fs::read(support().join("Details.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<HashMap<String, Cached>>(&bytes).ok())
            .map(|all| all.into_iter().map(|(id, cached)| (id, cached.detail)).collect())
            .unwrap_or_default()
    })
}

fn own_path(org: &str) -> PathBuf {
    crate::cache::org_file(org, "Details.json", "Details.json")
}

/// The pilot's own `Details.json` for each org, beside its caches: read on
/// first use and written through as drawers fetch.
fn own() -> &'static std::sync::Mutex<HashMap<String, HashMap<String, Cached>>> {
    static OWN: OnceLock<std::sync::Mutex<HashMap<String, HashMap<String, Cached>>>> = OnceLock::new();
    OWN.get_or_init(Default::default)
}

fn own_for<'a>(all: &'a mut HashMap<String, HashMap<String, Cached>>, org: &str) -> &'a mut HashMap<String, Cached> {
    all.entry(org.to_string())
        .or_insert_with(|| std::fs::read(own_path(org)).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default())
}

fn text_of(detail: &Detail) -> IssueText {
    IssueText {
        body: detail.body.clone(),
        comment_count: Some(detail.comment_count),
        comments: detail
            .recent_comments
            .iter()
            .map(|c| Comment {
                author: c.author.as_ref().map_or("ghost".into(), |a| a.login.clone()),
                body: c.body.clone(),
                at: Some(c.created_at),
                url: Some(c.url.clone()),
            })
            .collect(),
    }
}

/// The issue's description and comments, from whichever cache has them:
/// the pilot's, then Gannin's. Runs off the main thread.
pub fn load_text(org: &str, id: &str) -> Option<IssueText> {
    if let Some(cached) = own().lock().ok().and_then(|mut all| own_for(&mut all, org).get(id).cloned()) {
        return Some(text_of(&cached.detail));
    }
    if let Some(detail) = details().get(id) {
        return Some(text_of(detail));
    }
    from_index(id)
}

/// Keeps what GitHub sent for an issue or PR (its `body` and
/// `comments(last: 20) { totalCount nodes { url body createdAt author { login } } }`)
/// in the pilot's copy, and returns it as the drawer shows it.
pub fn remember(org: &str, id: &str, node: &serde_json::Value) -> Option<IssueText> {
    let body = node["body"].as_str()?.to_string();
    let comments = &node["comments"];
    let detail = Detail {
        body,
        comment_count: comments["totalCount"].as_u64().unwrap_or(0) as usize,
        recent_comments: comments["nodes"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|c| {
                Some(CachedComment {
                    url: c["url"].as_str()?.to_string(),
                    author: c["author"]["login"].as_str().map(|login| CachedPerson { login: login.to_string() }),
                    body: c["body"].as_str().unwrap_or("").to_string(),
                    created_at: c["createdAt"].as_str()?.parse().ok()?,
                })
            })
            .collect(),
    };
    let text = text_of(&detail);
    if let Ok(mut all) = own().lock() {
        let own = own_for(&mut all, org);
        own.insert(id.to_string(), Cached { detail });
        if let Ok(bytes) = serde_json::to_vec(&*own) {
            let path = own_path(org);
            if let Some(folder) = path.parent() {
                let _ = std::fs::create_dir_all(folder);
            }
            let partial = path.with_extension("json.part");
            if std::fs::write(&partial, bytes).is_ok() {
                let _ = std::fs::rename(&partial, &path);
            }
        }
    }
    Some(text)
}

fn from_index(id: &str) -> Option<IssueText> {
    use rusqlite::{Connection, OpenFlags};
    let path = support().join("dev.andon.gannin/IssueText.sqlite");
    let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX).ok()?;
    // The index's own columns: id, org, title, body, comments.
    let (body, comments): (String, String) = db
        .query_row("SELECT c3, c4 FROM fts_content WHERE c0 = ?1", [id], |row| Ok((row.get(0)?, row.get(1)?)))
        .ok()?;
    // Joined as "@login: text", a blank line apart.
    let comments: Vec<Comment> = if comments.trim().is_empty() {
        Vec::new()
    } else {
        comments
            .split("\n\n@")
            .map(|piece| {
                let piece = piece.strip_prefix('@').unwrap_or(piece);
                let (author, body) = piece.split_once(": ").unwrap_or(("someone", piece));
                Comment { author: author.to_string(), body: body.to_string(), at: None, url: None }
            })
            .collect()
    };
    Some(IssueText { body, comment_count: None, comments })
}

// MARK: - Timing

/// How an org's issues move through its board (`IssueWorkflow`).
#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct Workflow {
    /// Only this board's statuses count; none means any board.
    pub project_number: Option<i64>,
    /// Statuses that count as work in progress, compared without case.
    pub in_progress_statuses: Vec<String>,
    /// Without an in-progress status, the first linked PR starts the work.
    pub fall_back_to_pull_requests: bool,
}

impl Default for Workflow {
    fn default() -> Self {
        Self { project_number: None, in_progress_statuses: vec!["In Progress".into()], fall_back_to_pull_requests: true }
    }
}

impl Workflow {
    pub fn is_in_progress(&self, status: &str) -> bool {
        self.in_progress_statuses.iter().any(|s| s.eq_ignore_ascii_case(status))
    }

    /// A move on the board the workflow follows, or any board.
    pub fn counts(&self, change: &crate::issues::StatusChange) -> bool {
        self.project_number.is_none() || change.project_number == self.project_number
    }
}

/// `IssueTiming` under the org's workflow.
pub struct Timing {
    /// Time in progress, pauses left out.
    pub cycle: Option<f64>,
    pub in_progress: bool,
    pub lead: Option<f64>,
    /// Share of in-progress days with activity on a linked pull request.
    pub flow: Option<f64>,
    /// Share of sub-issues added after work started.
    pub scope_creep: Option<f64>,
}

pub fn timing(issue: &IssueItem, workflow: &Workflow, now: DateTime<Utc>) -> Timing {
    let end = issue.closed_at.unwrap_or(now);
    let mut intervals: Vec<(DateTime<Utc>, DateTime<Utc>)> = Vec::new();
    let mut opened: Option<DateTime<Utc>> = None;
    for change in issue.status_changes.iter().filter(|c| workflow.counts(c)) {
        if workflow.is_in_progress(&change.status) {
            opened.get_or_insert(change.at);
        } else if let Some(started) = opened.take() {
            intervals.push((started, change.at.max(started)));
        }
    }
    if let Some(started) = opened {
        if started < end {
            intervals.push((started, end));
        }
    }
    let mut in_progress = issue.is_open() && opened.is_some();
    if intervals.is_empty() && workflow.fall_back_to_pull_requests {
        if let Some(first) = issue.linked_prs.iter().map(|pr| pr.created_at).min().filter(|first| *first < end) {
            // Open issues only count as in progress while a linked PR is open.
            if issue.is_open() {
                in_progress = issue.linked_prs.iter().any(|pr| pr.state == "OPEN");
                if in_progress {
                    intervals.push((first, end));
                }
            } else {
                intervals.push((first, end));
            }
        }
    }
    let seconds = |(a, b): &(DateTime<Utc>, DateTime<Utc>)| (*b - *a).num_seconds() as f64;
    let cycle = (!intervals.is_empty()).then(|| intervals.iter().map(seconds).sum());
    let lead = issue.closed_at.map(|closed| (closed - issue.created_at).num_seconds() as f64);

    let day = |t: DateTime<Utc>| t.with_timezone(&Local).date_naive();
    let flow = (!intervals.is_empty() && !issue.linked_prs.is_empty())
        .then(|| {
            let mut spanned: HashSet<NaiveDate> = HashSet::new();
            for (start, end) in &intervals {
                let mut d = day(*start);
                while d <= day(*end) {
                    spanned.insert(d);
                    d = d.succ_opt()?;
                }
            }
            let active: HashSet<NaiveDate> = issue.linked_prs.iter().flat_map(|pr| pr.activity_at.iter().map(|t| day(*t))).collect();
            (!spanned.is_empty()).then(|| spanned.intersection(&active).count() as f64 / spanned.len() as f64)
        })
        .flatten();
    let scope_creep = intervals.first().filter(|_| !issue.sub_issues_added_at.is_empty()).map(|(start, _)| {
        issue.sub_issues_added_at.iter().filter(|t| *t > start).count() as f64 / issue.sub_issues_added_at.len() as f64
    });
    Timing { cycle, in_progress, lead, flow, scope_creep }
}

// MARK: - Timeline

/// One thing that happened, as the Standup's timeline shows it.
pub struct Moment {
    pub at: DateTime<Utc>,
    pub who: String,
    pub what: String,
    /// Opens on GitHub when clicked.
    pub url: Option<String>,
}

/// Opened, assigned, each board move, sub-issues added, reopened, closed,
/// comments and linked PRs opened and merged, by local day, oldest first.
/// GitHub doesn't say who assigned or moved it, so those are the
/// assignee's, as on the Standup.
pub fn timeline(issue: &IssueItem, text: Option<&IssueText>) -> Vec<(NaiveDate, Vec<Moment>)> {
    let author = issue.author_login.clone().unwrap_or_else(|| "someone".into());
    let owner = issue.assignee_logins.first().cloned().unwrap_or_else(|| author.clone());
    let mut moments = vec![Moment { at: issue.created_at, who: author.clone(), what: "opened the issue".into(), url: None }];
    let mut add = |at: DateTime<Utc>, who: &str, what: String, url: Option<String>| moments.push(Moment { at, who: who.to_string(), what, url });
    for at in &issue.assigned_at {
        add(*at, &owner, "was assigned".into(), None);
    }
    for change in &issue.status_changes {
        let board = change.project_title.as_ref().map(|t| format!(" on {t}")).unwrap_or_default();
        add(change.at, &owner, format!("moved it to {}{board}", change.status), None);
    }
    for at in &issue.sub_issues_added_at {
        add(*at, &owner, "added a sub-issue".into(), None);
    }
    for at in &issue.reopened_at {
        add(*at, &owner, "reopened it".into(), None);
    }
    if let Some(closed) = issue.closed_at {
        add(closed, &owner, if issue.not_planned { "closed it as not planned".into() } else { "closed it".into() }, None);
    }
    for comment in text.map(|t| t.comments.as_slice()).unwrap_or_default() {
        let Some(at) = comment.at else { continue };
        let line = comment.body.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
        add(at, &comment.author, format!("commented: {line}"), comment.url.clone());
    }
    for pr in &issue.linked_prs {
        let name = pr.repo.as_ref().map_or(format!("#{}", pr.number), |r| format!("{r}#{}", pr.number));
        add(pr.created_at, &owner, format!("opened pull request {name}"), Some(pr.url.clone()));
        if let Some(merged) = pr.merged_at {
            add(merged, &owner, format!("merged pull request {name}"), Some(pr.url.clone()));
        }
    }
    moments.sort_by_key(|m| m.at);
    let mut days: BTreeMap<NaiveDate, Vec<Moment>> = BTreeMap::new();
    for moment in moments {
        days.entry(moment.at.with_timezone(&Local).date_naive()).or_default().push(moment);
    }
    days.into_iter().collect()
}
