//! What an issue's drawer shows beyond the list's fields, as `IssueWindow`
//! has it: the description and comments, timing under the workflow, and the
//! timeline.
//!
//! Text is fetched from GitHub when a drawer opens (`sync::refresh_item`)
//! and kept in the pilot's own `Details.json` beside the org's caches, in
//! the shape Gannin's `DetailStore` reads: the description, the last 20
//! comments with their dates, a PR's branches and checks, the item's
//! `updatedAt` and when it was fetched. Until that answers, or when signed
//! out, the drawer shows the pilot's copy.
//!
//! Timing follows the org's issue workflow (`IssueWorkflow`), read with
//! its projects from the home harness's `workflow.json` (`projects.rs`).

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

/// The values `ItemDetail.CheckState` decodes. Gannin fails to read the
/// whole file on any other value.
const CHECK_STATES: [&str; 5] = ["SUCCESS", "FAILURE", "ERROR", "PENDING", "EXPECTED"];

/// Dates as Gannin's `.iso8601` coding strategy writes them: UTC, whole
/// seconds, `Z`. chrono's own serialisation adds fractional seconds
/// whenever they are nonzero. `ISO8601DateFormatter`, which backs that
/// strategy on older macOS releases, rejects them.
mod iso8601 {
    use chrono::{DateTime, SecondsFormat, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(at: &DateTime<Utc>, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&at.to_rfc3339_opts(SecondsFormat::Secs, true))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<DateTime<Utc>, D::Error> {
        DateTime::<Utc>::deserialize(deserializer)
    }

    pub mod option {
        use chrono::{DateTime, Utc};
        use serde::{Deserialize, Deserializer, Serializer};

        pub fn serialize<S: Serializer>(at: &Option<DateTime<Utc>>, serializer: S) -> Result<S::Ok, S::Error> {
            match at {
                Some(at) => super::serialize(at, serializer),
                None => serializer.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<DateTime<Utc>>, D::Error> {
            Option::<DateTime<Utc>>::deserialize(deserializer)
        }
    }
}

/// One entry of `Details.json`, as Gannin's `DetailStore.Cached`.
#[derive(Deserialize, serde::Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Cached {
    detail: Detail,
    /// An entry without one reads as the Unix epoch, so Gannin treats it as
    /// stale and fetches it again.
    #[serde(default, with = "iso8601")]
    fetched_at: DateTime<Utc>,
}

/// Gannin's `ItemDetail`. The optional fields are left out when empty, as
/// Swift's encoder does, and default when absent so older entries still
/// read.
#[derive(Deserialize, serde::Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Detail {
    body: String,
    comment_count: usize,
    #[serde(default)]
    recent_comments: Vec<CachedComment>,
    /// A PR's branch names. Issues have none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    head_ref: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    base_ref: Option<String>,
    /// The last commit's check rollup, one of `CHECK_STATES`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    checks: Option<String>,
    /// The item's `updatedAt` when this was fetched.
    #[serde(default, skip_serializing_if = "Option::is_none", with = "iso8601::option")]
    updated_at: Option<DateTime<Utc>>,
}

#[derive(Deserialize, serde::Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct CachedComment {
    url: String,
    author: Option<CachedPerson>,
    body: String,
    #[serde(with = "iso8601")]
    created_at: DateTime<Utc>,
}

/// Gannin's `Person`.
#[derive(Deserialize, serde::Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct CachedPerson {
    login: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    avatar_url: Option<String>,
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

/// The issue's description and comments, from the pilot's copy. Runs off
/// the main thread.
pub fn load_text(org: &str, id: &str) -> Option<IssueText> {
    let cached = own().lock().ok().and_then(|mut all| own_for(&mut all, org).get(id).cloned())?;
    Some(text_of(&cached.detail))
}

/// Keeps what GitHub sent for an issue or PR in the pilot's copy, and
/// returns it as the drawer shows it. The node has its `body`, `updatedAt`
/// and `comments(last: 20) { totalCount nodes { url body createdAt author { login avatarUrl ... on User { name } } } }`;
/// a PR's also has `headRefName`, `baseRefName` and
/// `commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }`.
pub fn remember(org: &str, id: &str, node: &serde_json::Value) -> Option<IssueText> {
    let detail = detail_of(node)?;
    let text = text_of(&detail);
    store(org, vec![(id.to_string(), detail)]);
    Some(text)
}

/// Keeps the text of every node the sync fetched (each with its `id`),
/// writing the file once.
pub fn remember_all(org: &str, nodes: &[serde_json::Value]) {
    let found: Vec<(String, Detail)> = nodes.iter().filter_map(|n| Some((n["id"].as_str()?.to_string(), detail_of(n)?))).collect();
    if !found.is_empty() {
        store(org, found);
    }
}

/// Each issue's description and comments as one lowercased string, by
/// node ID, for the Issues search. Runs off the main thread.
pub fn search_texts(org: &str) -> HashMap<String, String> {
    let Ok(mut all) = own().lock() else { return HashMap::new() };
    own_for(&mut all, org)
        .iter()
        .map(|(id, cached)| {
            let d = &cached.detail;
            let mut text = d.body.to_lowercase();
            for c in &d.recent_comments {
                text.push('\n');
                text.push_str(&c.body.to_lowercase());
            }
            (id.clone(), text)
        })
        .collect()
}

fn store(org: &str, found: Vec<(String, Detail)>) {
    if let Ok(mut all) = own().lock() {
        let own = own_for(&mut all, org);
        let fetched_at = Utc::now();
        own.extend(found.into_iter().map(|(id, detail)| (id, Cached { detail, fetched_at })));
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
}

fn detail_of(node: &serde_json::Value) -> Option<Detail> {
    let body = node["body"].as_str()?.to_string();
    let comments = &node["comments"];
    Some(Detail {
        body,
        comment_count: comments["totalCount"].as_u64().unwrap_or(0) as usize,
        recent_comments: comments["nodes"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|c| {
                let author = &c["author"];
                Some(CachedComment {
                    url: c["url"].as_str()?.to_string(),
                    author: author["login"].as_str().map(|login| CachedPerson {
                        login: login.to_string(),
                        name: author["name"].as_str().map(str::to_string),
                        avatar_url: author["avatarUrl"].as_str().map(str::to_string),
                    }),
                    body: c["body"].as_str().unwrap_or("").to_string(),
                    created_at: c["createdAt"].as_str()?.parse().ok()?,
                })
            })
            .collect(),
        head_ref: node["headRefName"].as_str().map(str::to_string),
        base_ref: node["baseRefName"].as_str().map(str::to_string),
        checks: node["commits"]["nodes"]
            .as_array()
            .and_then(|n| n.last())
            .and_then(|c| c["commit"]["statusCheckRollup"]["state"].as_str())
            .filter(|s| CHECK_STATES.contains(s))
            .map(str::to_string),
        updated_at: node["updatedAt"].as_str().and_then(|s| s.parse().ok()),
    })
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    // Gannin's `DetailStore.Cached`, `ItemDetail`, `Comment` and `Person`.
    // Swift's required fields are plain here and its optional ones `Option`,
    // so a missing required field fails to decode as it would in Gannin.
    // Dates stay strings so the tests can check their exact form.

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct SwiftCached {
        detail: SwiftDetail,
        fetched_at: String,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct SwiftDetail {
        body: String,
        comment_count: i64,
        recent_comments: Vec<SwiftComment>,
        head_ref: Option<String>,
        base_ref: Option<String>,
        checks: Option<String>,
        updated_at: Option<String>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct SwiftComment {
        url: String,
        author: Option<SwiftPerson>,
        body: String,
        created_at: String,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct SwiftPerson {
        login: String,
        name: Option<String>,
        avatar_url: Option<String>,
    }

    /// `YYYY-MM-DDTHH:MM:SSZ`, the form Swift's `.iso8601` strategy writes.
    fn is_swift_date(s: &str) -> bool {
        s.len() == 20
            && s.bytes().enumerate().all(|(i, c)| match i {
                4 | 7 => c == b'-',
                10 => c == b'T',
                13 | 16 => c == b':',
                19 => c == b'Z',
                _ => c.is_ascii_digit(),
            })
            && s.parse::<DateTime<Utc>>().is_ok()
    }

    fn pr_node(state: &str) -> Value {
        json!({
            "__typename": "PullRequest",
            "body": "Adds the thing.",
            "updatedAt": "2026-11-18T09:15:00Z",
            "headRefName": "feature/thing",
            "baseRefName": "main",
            "commits": { "nodes": [{ "commit": { "statusCheckRollup": { "state": state } } }] },
            "comments": {
                "totalCount": 3,
                "nodes": [
                    {
                        "url": "https://github.com/o/r/pull/1#issuecomment-1",
                        "body": "Looks good.",
                        "createdAt": "2026-11-18T08:00:00Z",
                        "author": { "login": "octocat", "name": "The Octocat", "avatarUrl": "https://avatars.githubusercontent.com/u/1" }
                    },
                    {
                        "url": "https://github.com/o/r/pull/1#issuecomment-2",
                        "body": "Deployed.",
                        "createdAt": "2026-11-18T08:30:00Z",
                        "author": { "login": "deploy-bot", "avatarUrl": "https://avatars.githubusercontent.com/u/2" }
                    }
                ]
            }
        })
    }

    fn issue_node() -> Value {
        json!({
            "__typename": "Issue",
            "body": "It breaks.",
            "updatedAt": "2026-11-17T12:00:00Z",
            "comments": { "totalCount": 0, "nodes": [] }
        })
    }

    #[test]
    fn detail_of_reads_a_pull_requests_branches_checks_and_update() {
        let detail = detail_of(&pr_node("SUCCESS")).expect("detail");
        assert_eq!(detail.head_ref.as_deref(), Some("feature/thing"));
        assert_eq!(detail.base_ref.as_deref(), Some("main"));
        assert_eq!(detail.checks.as_deref(), Some("SUCCESS"));
        assert_eq!(detail.updated_at, Some("2026-11-18T09:15:00Z".parse().unwrap()));
        assert_eq!(detail.comment_count, 3);
        let octocat = detail.recent_comments[0].author.as_ref().expect("author");
        assert_eq!(octocat.name.as_deref(), Some("The Octocat"));
        assert_eq!(octocat.avatar_url.as_deref(), Some("https://avatars.githubusercontent.com/u/1"));
        let bot = detail.recent_comments[1].author.as_ref().expect("author");
        assert_eq!(bot.name, None);
    }

    #[test]
    fn detail_of_drops_check_states_gannin_cannot_decode() {
        assert_eq!(detail_of(&pr_node("NEUTRAL")).expect("detail").checks, None);
    }

    #[test]
    fn detail_of_gives_an_issue_no_branches_or_checks() {
        let detail = detail_of(&issue_node()).expect("detail");
        assert_eq!((detail.head_ref, detail.base_ref, detail.checks), (None, None, None));
        assert_eq!(detail.updated_at, Some("2026-11-17T12:00:00Z".parse().unwrap()));
    }

    #[test]
    fn details_json_decodes_as_gannin_reads_it() {
        // Fractional seconds, as `Utc::now()` has, must not reach the file.
        let fetched_at: DateTime<Utc> = "2026-11-19T10:20:30.123456789Z".parse().unwrap();
        let file: HashMap<String, Cached> = HashMap::from([
            ("PR_1".to_string(), Cached { detail: detail_of(&pr_node("PENDING")).unwrap(), fetched_at }),
            ("I_1".to_string(), Cached { detail: detail_of(&issue_node()).unwrap(), fetched_at }),
        ]);
        let bytes = serde_json::to_vec(&file).unwrap();

        let decoded: HashMap<String, SwiftCached> = serde_json::from_slice(&bytes).expect("decodes as Gannin's Cached");
        let pr = &decoded["PR_1"];
        assert_eq!(pr.fetched_at, "2026-11-19T10:20:30Z");
        assert!(is_swift_date(&pr.fetched_at));
        assert_eq!(pr.detail.body, "Adds the thing.");
        assert_eq!(pr.detail.comment_count, 3);
        assert_eq!(pr.detail.head_ref.as_deref(), Some("feature/thing"));
        assert_eq!(pr.detail.base_ref.as_deref(), Some("main"));
        assert!(pr.detail.checks.as_deref().is_some_and(|c| CHECK_STATES.contains(&c)));
        assert!(pr.detail.updated_at.as_deref().is_some_and(is_swift_date));
        let comment = &pr.detail.recent_comments[0];
        assert!(comment.url.starts_with("https://"));
        assert_eq!(comment.body, "Looks good.");
        assert!(is_swift_date(&comment.created_at));
        let author = comment.author.as_ref().expect("author");
        assert_eq!(author.login, "octocat");
        assert_eq!(author.name.as_deref(), Some("The Octocat"));
        assert_eq!(author.avatar_url.as_deref(), Some("https://avatars.githubusercontent.com/u/1"));

        // An issue's missing branches and checks are left out, not null.
        let raw: Value = serde_json::from_slice(&bytes).unwrap();
        let issue = raw["I_1"]["detail"].as_object().unwrap();
        for key in ["headRef", "baseRef", "checks"] {
            assert!(!issue.contains_key(key), "{key} written for an issue");
        }
        assert!(decoded["I_1"].detail.recent_comments.is_empty());

        // The pilot reads its own file back.
        let back: HashMap<String, Cached> = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(back["PR_1"].fetched_at, "2026-11-19T10:20:30Z".parse::<DateTime<Utc>>().unwrap());
        assert_eq!(back["PR_1"].detail.checks.as_deref(), Some("PENDING"));
    }

    #[test]
    fn entries_without_the_newer_fields_still_read() {
        let older = r#"{"I_1":{"detail":{"body":"b","commentCount":1,"recentComments":[{"url":"https://github.com/o/r/issues/1#issuecomment-1","author":{"login":"a"},"body":"c","createdAt":"2026-01-02T03:04:05Z"}]}}}"#;
        let file: HashMap<String, Cached> = serde_json::from_str(older).expect("reads");
        let cached = &file["I_1"];
        assert_eq!(cached.fetched_at.timestamp(), 0);
        assert!(cached.detail.head_ref.is_none() && cached.detail.checks.is_none() && cached.detail.updated_at.is_none());
        assert!(cached.detail.recent_comments[0].author.as_ref().is_some_and(|a| a.name.is_none() && a.avatar_url.is_none()));
    }
}
