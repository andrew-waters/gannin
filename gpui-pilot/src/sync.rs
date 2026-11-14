//! Keeps the pilot's copies of an org's caches current from GitHub, as
//! Gannin's workload sync does (`OrgStore.refresh`, `GitHubAPI.snapshot`):
//! open pull requests and those merged in the lookback, and open issues.
//! Every 24 hours (or the first time) it searches them all; between those
//! it searches only what changed since the last sync, less five minutes.
//!
//! It writes the same JSON shapes Gannin does, slot by slot: a PR's `core`
//! and `workload`, an issue's `core` and `workload`. Other slots (metrics,
//! the work log, the issue history) are left as they were, so what Gannin
//! fetched for them stays. Merges follow Gannin's: the newer `updatedAt`
//! wins, and a person's name or avatar, or a label's colour, is kept from
//! the older copy when the newer one lacks it.

use crate::cache::{self, Kind};
use crate::github::{self, Error};
use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashSet};
use std::path::PathBuf;

const PR_FIELDS: &str = "... on PullRequest { id number title url isDraft state createdAt updatedAt mergedAt reviewDecision additions deletions changedFiles commits(last: 1) { nodes { commit { statusCheckRollup { state } committedDate } } } repository { nameWithOwner } author { login avatarUrl } assignees(first: 10) { nodes { login avatarUrl } } reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login avatarUrl } ... on Team { combinedSlug } } } } latestReviews(first: 10) { nodes { state submittedAt author { login avatarUrl } } } closingIssuesReferences(first: 10) { nodes { id number title url state repository { nameWithOwner } } } timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 20) { nodes { ... on ReviewRequestedEvent { createdAt requestedReviewer { ... on User { login } } } } } comments(last: 10) { nodes { createdAt author { login avatarUrl } } } }";

const ISSUE_FIELDS: &str = "... on Issue { id number title url state createdAt updatedAt closedAt repository { nameWithOwner } author { login avatarUrl } assignees(first: 10) { nodes { login avatarUrl } } labels(first: 10) { nodes { name color } } closedByPullRequestsReferences(first: 10, includeClosedPrs: true) { nodes { id number title url state repository { nameWithOwner } } } }";

/// When an org was last synced, kept beside the pilot's caches.
#[derive(Default, Clone, serde::Serialize, serde::Deserialize)]
#[serde(default)]
struct Synced {
    at: Option<DateTime<Utc>>,
    full_at: Option<DateTime<Utc>>,
    lookback_days: i64,
}

fn synced_path() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join("Library/Application Support/GanninGPUIPilot/Caches/synced.json")
}

fn read_synced() -> BTreeMap<String, Synced> {
    std::fs::read(synced_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn write_synced(all: &BTreeMap<String, Synced>) {
    if let Ok(json) = serde_json::to_vec_pretty(all) {
        let _ = std::fs::write(synced_path(), json);
    }
}

/// When the org was last synced by the pilot.
pub fn last_synced(org: &str) -> Option<DateTime<Utc>> {
    read_synced().get(org).and_then(|s| s.at)
}

/// Gannin's lookback for merged PRs (Settings), else its default 14 days.
pub fn gannin_lookback_days() -> i64 {
    std::process::Command::new("/usr/bin/defaults")
        .args(["read", "dev.andon.gannin", "lookbackDays"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok())
        .filter(|d: &i64| *d > 0)
        .unwrap_or(14)
}

/// GitHub's ISO time with an explicit offset, as Gannin's searches use.
pub(crate) fn search_stamp(time: DateTime<Utc>) -> String {
    time.format("%Y-%m-%dT%H:%M:%S+00:00").to_string()
}

/// A step of a sync, for the sync popover: what it fetches, how many it
/// found, and whether it's done.
#[derive(Clone, Debug)]
pub struct Step {
    pub title: String,
    pub count: Option<usize>,
    pub done: bool,
    /// Results fetched so far, and how many there are, while it runs.
    pub fetched: usize,
    pub total: Option<usize>,
}

impl Step {
    /// How far through it is, 0 to 1.
    pub fn fraction(&self) -> f32 {
        if self.done {
            return 1.;
        }
        match self.total {
            Some(0) => 1.,
            Some(total) => self.fetched as f32 / total as f32,
            None => 0.,
        }
    }
}

/// Records a page fetched for a step.
pub(crate) fn advance(progress: &Progress, title: &str, fetched: usize, total: usize) {
    if let Ok(mut steps) = progress.lock() {
        if let Some(step) = steps.iter_mut().rev().find(|s| s.title == title && !s.done) {
            step.fetched = fetched;
            step.total = Some(total);
        }
    }
}

/// The steps of the sync under way, shared with the window as it runs.
pub type Progress = std::sync::Arc<std::sync::Mutex<Vec<Step>>>;

pub(crate) fn begin(progress: &Progress, titles: &[&str]) {
    if let Ok(mut steps) = progress.lock() {
        steps.extend(titles.iter().map(|t| Step { title: t.to_string(), count: None, done: false, fetched: 0, total: None }));
    }
}

pub(crate) fn finish(progress: &Progress, title: &str, count: Option<usize>) {
    if let Ok(mut steps) = progress.lock() {
        if let Some(step) = steps.iter_mut().rev().find(|s| s.title == title && !s.done) {
            step.done = true;
            step.count = count;
        }
    }
}

#[derive(Default, Debug)]
pub struct Report {
    pub full: bool,
    pub pull_requests: usize,
    pub issues: usize,
}

/// Syncs one org's PRs and issues into the pilot's caches. `viewer` is the
/// signed-in login, for a personal account's `user:` searches. Blocking:
/// run it off the main thread.
/// How a sync runs, from the settings.
#[derive(Clone, Copy)]
pub struct Options {
    pub lookback_days: i64,
    pub full_every: Duration,
}

impl Default for Options {
    fn default() -> Self {
        Self { lookback_days: gannin_lookback_days(), full_every: Duration::hours(24) }
    }
}

pub fn sync_org(token: &str, org: &str, viewer: Option<&str>, force_full: bool, options: Options, progress: &Progress) -> Result<Report, Error> {
    let now = Utc::now();
    let lookback = options.lookback_days;
    let mut all = read_synced();
    let previous = all.get(org).cloned().unwrap_or_default();
    let scope = format!("{}:{org} archived:false", if viewer == Some(org) { "user" } else { "org" });
    let since = previous.at.map(|at| at - Duration::minutes(5));
    let full_due = force_full || previous.full_at.is_none_or(|at| now - at > options.full_every) || previous.lookback_days != lookback;
    let merged_since = (now - Duration::days(lookback)).date_naive();

    let mut report = Report::default();
    // Changes since the last sync, unless a full search is due or more
    // changed than a search can return.
    let mut changes: Option<(Vec<Value>, Vec<Value>)> = None;
    if let (Some(since), false) = (since, full_due) {
        let stamp = search_stamp(since);
        begin(progress, &["Changed pull requests", "Changed issues"]);
        let (prs, issues) = std::thread::scope(|scope_| {
            let prs = scope_.spawn(|| {
                let found = github::search_reporting(token, &format!("{scope} is:pr updated:>={stamp}"), 50, PR_FIELDS, &|f, t| advance(progress, "Changed pull requests", f, t));
                finish(progress, "Changed pull requests", found.as_ref().ok().map(|f| f.0.len()));
                found
            });
            let issues = scope_.spawn(|| {
                let found = github::search_reporting(token, &format!("{scope} is:issue updated:>={stamp}"), 100, ISSUE_FIELDS, &|f, t| advance(progress, "Changed issues", f, t));
                finish(progress, "Changed issues", found.as_ref().ok().map(|f| f.0.len()));
                found
            });
            (prs.join().expect("search thread"), issues.join().expect("search thread"))
        });
        let (prs, prs_cut) = prs?;
        let (issues, issues_cut) = issues?;
        if !prs_cut && !issues_cut {
            changes = Some((prs, issues));
        }
    }
    let (prs, issues) = match changes {
        Some(found) => found,
        None => {
            report.full = true;
            // The three searches at once, as Gannin runs them.
            let merged_query = format!("{scope} is:pr is:merged merged:>={} sort:updated-desc", merged_since.format("%Y-%m-%d"));
            let merged_title = format!("Pull requests merged in {lookback} days");
            begin(progress, &["Open pull requests", &merged_title, "Open issues"]);
            let search = |title: &str, query: &str, size: usize, fields: &str| {
                let found = github::search_reporting(token, query, size, fields, &|f, t| advance(progress, title, f, t));
                finish(progress, title, found.as_ref().ok().map(|f| f.0.len()));
                found
            };
            let search = &search;
            let (open_query, issues_query) = (format!("{scope} is:pr is:open sort:updated-desc"), format!("{scope} is:issue is:open sort:updated-desc"));
            let (open, merged, issues) = std::thread::scope(|scope_| {
                let open = scope_.spawn(|| search("Open pull requests", &open_query, 50, PR_FIELDS));
                let merged = scope_.spawn(|| search(&merged_title, &merged_query, 50, PR_FIELDS));
                let issues = scope_.spawn(|| search("Open issues", &issues_query, 100, ISSUE_FIELDS));
                (open.join().expect("search thread"), merged.join().expect("search thread"), issues.join().expect("search thread"))
            });
            let mut prs = open?.0;
            prs.extend(merged?.0);
            (prs, issues?.0)
        }
    };
    report.pull_requests = prs.len();
    report.issues = issues.len();

    let cutoff = merged_since.and_hms_opt(0, 0, 0).map(|t| t.and_utc());
    begin(progress, &["Saving the pilot's copy"]);
    merge_pull_requests(org, &prs, report.full, cutoff).map_err(|e| Error::Other(format!("Couldn't save pull requests: {e}")))?;
    merge_issues(org, &issues, report.full).map_err(|e| Error::Other(format!("Couldn't save issues: {e}")))?;

    all.insert(
        org.to_string(),
        Synced { at: Some(now), full_at: if report.full { Some(now) } else { previous.full_at }, lookback_days: lookback },
    );
    write_synced(&all);
    finish(progress, "Saving the pilot's copy", None);

    // The longer histories Scorecards and Activity read, each when it's due.
    let base = format!("{}:{org}", if viewer == Some(org) { "user" } else { "org" });
    crate::history::sync_people(token, org, viewer == Some(org), force_full, progress)?;
    crate::history::sync_metrics(token, org, &base, crate::history::METRICS_DAYS, force_full, progress)?;
    crate::history::sync_issue_history(token, org, &base, crate::history::METRICS_DAYS, force_full, progress)?;
    crate::history::sync_work_log(token, org, &base, crate::history::WORK_LOG_DAYS, force_full, progress)?;
    Ok(report)
}

// MARK: - Pull requests

pub(crate) fn person(node: &Value) -> Option<Value> {
    let login = node["login"].as_str()?;
    let mut person = Map::new();
    person.insert("login".into(), json!(login));
    if let Some(avatar) = node["avatarUrl"].as_str() {
        person.insert("avatarUrl".into(), json!(avatar));
    }
    Some(Value::Object(person))
}

pub(crate) fn nodes(value: &Value) -> Vec<Value> {
    value["nodes"].as_array().cloned().unwrap_or_default()
}

pub(crate) fn linked_item(node: &Value) -> Option<Value> {
    Some(json!({
        "id": node["id"].as_str()?,
        "number": node["number"].as_i64()?,
        "title": node["title"].as_str()?,
        "url": node["url"].as_str()?,
        "repo": node["repository"]["nameWithOwner"].as_str()?,
        "state": node["state"].as_str()?,
    }))
}

/// Puts `key` in `map` only when it has a value, as Swift's Codable leaves
/// out nil optionals.
pub(crate) fn put(map: &mut Map<String, Value>, key: &str, value: &Value) {
    if !value.is_null() {
        map.insert(key.into(), value.clone());
    }
}

/// A search node as `StoredPullRequest(workload:)` stores it: its `core`
/// and `workload` slots.
fn pull_request_slots(node: &Value) -> Option<(String, Value, Value)> {
    let id = node["id"].as_str()?.to_string();
    let author_login = node["author"]["login"].as_str();

    let mut core = Map::new();
    for key in ["id", "number", "title", "url"] {
        core.insert(key.into(), node[key].clone());
    }
    core.insert("repo".into(), node["repository"]["nameWithOwner"].clone());
    if let Some(author) = person(&node["author"]) {
        core.insert("author".into(), author);
    }
    for key in ["createdAt", "updatedAt", "mergedAt", "additions", "deletions", "changedFiles"] {
        put(&mut core, key, &node[key]);
    }

    let commit = nodes(&node["commits"]).last().map(|c| c["commit"].clone()).unwrap_or(Value::Null);
    let reviews = nodes(&node["latestReviews"]);
    let mut requested_at: Map<String, Value> = Map::new();
    for event in nodes(&node["timelineItems"]) {
        let (Some(login), Some(at)) = (event["requestedReviewer"]["login"].as_str(), event["createdAt"].as_str()) else { continue };
        if requested_at.get(login).and_then(Value::as_str).is_none_or(|held| held < at) {
            requested_at.insert(login.into(), json!(at));
        }
    }
    let mut review_states = Map::new();
    let mut reviewed_at = Map::new();
    for review in &reviews {
        let Some(login) = review["author"]["login"].as_str() else { continue };
        if let Some(state) = review["state"].as_str() {
            review_states.entry(login.to_string()).or_insert(json!(state));
        }
        if let Some(at) = review["submittedAt"].as_str() {
            reviewed_at.entry(login.to_string()).or_insert(json!(at));
        }
    }
    let author_replied = reviews
        .iter()
        .filter(|r| r["author"]["login"].as_str() == author_login && author_login.is_some())
        .filter_map(|r| r["submittedAt"].as_str())
        .chain(
            nodes(&node["comments"])
                .iter()
                .filter(|c| c["author"]["login"].as_str() == author_login && author_login.is_some())
                .filter_map(|c| c["createdAt"].as_str())
                .collect::<Vec<_>>(),
        )
        .max()
        .map(str::to_string);
    let requests = nodes(&node["reviewRequests"]);

    let mut workload = Map::new();
    workload.insert("updatedAt".into(), node["updatedAt"].clone());
    workload.insert("state".into(), node["state"].clone());
    workload.insert("isDraft".into(), json!(node["isDraft"].as_bool().unwrap_or(false)));
    if let Some(decision) = node["reviewDecision"].as_str().filter(|d| ["APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"].contains(d)) {
        workload.insert("reviewDecision".into(), json!(decision));
    }
    workload.insert("assignees".into(), Value::Array(nodes(&node["assignees"]).iter().filter_map(person).collect()));
    workload.insert(
        "requestedReviewers".into(),
        Value::Array(requests.iter().filter_map(|r| person(&r["requestedReviewer"])).collect()),
    );
    workload.insert(
        "requestedTeams".into(),
        Value::Array(requests.iter().filter_map(|r| r["requestedReviewer"]["combinedSlug"].as_str().map(|s| json!(s))).collect()),
    );
    workload.insert("reviewRequestedAt".into(), Value::Object(requested_at));
    workload.insert("reviewers".into(), Value::Array(reviews.iter().filter_map(|r| person(&r["author"])).collect()));
    workload.insert("reviewStates".into(), Value::Object(review_states));
    workload.insert("reviewedAt".into(), Value::Object(reviewed_at));
    workload.insert(
        "linkedIssues".into(),
        Value::Array(nodes(&node["closingIssuesReferences"]).iter().filter_map(linked_item).collect()),
    );
    if let Some(checks) = commit["statusCheckRollup"]["state"].as_str().filter(|s| ["SUCCESS", "FAILURE", "ERROR", "PENDING", "EXPECTED"].contains(s)) {
        workload.insert("checks".into(), json!(checks));
    }
    put(&mut workload, "lastCommitAt", &commit["committedDate"]);
    if let Some(at) = author_replied {
        workload.insert("authorRepliedAt".into(), json!(at));
    }
    Some((id, Value::Object(core), Value::Object(workload)))
}

fn updated_at(slot: &Value) -> Option<&str> {
    slot.get("updatedAt").and_then(Value::as_str)
}

/// Gannin's stale rule: the held copy is newer if it has an `updatedAt` and
/// the incoming one is older or has none.
pub(crate) fn held_is_newer(held: &Value, incoming: &Value) -> bool {
    match (updated_at(held), updated_at(incoming)) {
        (Some(h), Some(i)) => h > i,
        (Some(_), None) => true,
        _ => false,
    }
}

/// A person from the newer side, keeping the older side's name and avatar
/// when the newer one lacks them and it's the same login.
fn merge_person(newer: &Value, older: Option<&Value>) -> Value {
    let mut merged = newer.clone();
    if let (Some(map), Some(older)) = (merged.as_object_mut(), older) {
        if older["login"] == map["login"] {
            for key in ["name", "avatarUrl"] {
                if !map.contains_key(key) {
                    if let Some(value) = older.get(key).filter(|v| !v.is_null()) {
                        map.insert(key.into(), value.clone());
                    }
                }
            }
        }
    }
    merged
}

/// Merges an incoming `core` into the held one: the newer side's fields,
/// the other's where the newer has none; people and labels keep what the
/// older copy knew of them.
pub(crate) fn merge_core(held: Option<&Value>, incoming: Value) -> Value {
    let Some(held) = held else { return incoming };
    let (newer, older) = if held_is_newer(held, &incoming) { (held.clone(), incoming) } else { (incoming, held.clone()) };
    let mut merged = older.as_object().cloned().unwrap_or_default();
    for (key, value) in newer.as_object().cloned().unwrap_or_default() {
        let value = match key.as_str() {
            "author" => merge_person(&value, older.get("author")),
            "assignees" => Value::Array(
                value
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                    .iter()
                    .map(|p| merge_person(p, older["assignees"].as_array().and_then(|a| a.iter().find(|o| o["login"] == p["login"]))))
                    .collect(),
            ),
            "labels" => Value::Array(
                value
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .map(|mut label| {
                        if label.get("color").is_none_or(Value::is_null) {
                            if let Some(color) = older["labels"]
                                .as_array()
                                .and_then(|a| a.iter().find(|o| o["name"] == label["name"]))
                                .and_then(|o| o.get("color"))
                                .filter(|c| !c.is_null())
                            {
                                label["color"] = color.clone();
                            }
                        }
                        label
                    })
                    .collect(),
            ),
            _ => value,
        };
        merged.insert(key, value);
    }
    Value::Object(merged)
}

pub(crate) fn read_store(kind: Kind, org: &str, items_key: &str) -> Value {
    std::fs::read(cache::path(kind, org))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .filter(|v| v["formatVersion"] == 1)
        .unwrap_or_else(|| json!({ "formatVersion": 1, items_key: {} }))
}

/// Removes the `workload` slot, and the whole entry when it was the last.
fn drop_workload(entries: &mut Map<String, Value>, id: &str, others: &[&str]) {
    let empty = match entries.get_mut(id).and_then(Value::as_object_mut) {
        Some(entry) => {
            entry.remove("workload");
            !others.iter().any(|slot| entry.get(*slot).is_some_and(|v| !v.is_null()))
        }
        None => false,
    };
    if empty {
        entries.remove(id);
    }
}

fn merge_pull_requests(org: &str, nodes: &[Value], full: bool, merged_cutoff: Option<DateTime<Utc>>) -> std::io::Result<()> {
    let mut store = read_store(Kind::PullRequests, org, "pullRequests");
    let entries = store["pullRequests"].as_object_mut().expect("store map");
    let mut kept: HashSet<String> = HashSet::new();
    let others = ["metrics", "workLog"];
    for node in nodes {
        let Some((id, core, workload)) = pull_request_slots(node) else { continue };
        let state = workload["state"].as_str().unwrap_or("").to_string();
        let entry = entries.entry(id.clone()).or_insert_with(|| json!({}));
        let merged_core = merge_core(entry.get("core"), core);
        entry["core"] = merged_core;
        // Open and recently merged PRs carry a workload; closed ones lose it.
        let merged_at = entry["core"]["mergedAt"].as_str().and_then(|s| s.parse::<DateTime<Utc>>().ok());
        let in_workload = state == "OPEN" || (state == "MERGED" && merged_at.zip(merged_cutoff).is_some_and(|(at, cut)| at >= cut));
        if in_workload {
            let held = entry.get("workload").cloned();
            if held.as_ref().is_none_or(|h| !held_is_newer(h, &workload)) {
                entry["workload"] = workload;
            }
            kept.insert(id);
        } else {
            drop_workload(entries, &id, &others);
        }
    }
    // A full search saw every open and recently merged PR, so any other
    // PR's workload is out of date. Between those, only merged PRs that
    // have aged out of the lookback leave.
    let ids: Vec<String> = entries.keys().cloned().collect();
    for id in ids {
        let Some(entry) = entries.get(&id) else { continue };
        let Some(workload) = entry.get("workload") else { continue };
        let aged_out = workload["state"] == "MERGED"
            && entry["core"]["mergedAt"]
                .as_str()
                .and_then(|s| s.parse::<DateTime<Utc>>().ok())
                .zip(merged_cutoff)
                .is_some_and(|(at, cut)| at < cut);
        if (full && !kept.contains(&id)) || aged_out {
            drop_workload(entries, &id, &others);
        }
    }
    cache::write(Kind::PullRequests, org, &serde_json::to_vec(&store).unwrap_or_default())
}

// MARK: - Issues

fn issue_slots(node: &Value) -> Option<(String, Value, Value, bool)> {
    let id = node["id"].as_str()?.to_string();
    let mut core = Map::new();
    for key in ["id", "number", "title", "url"] {
        core.insert(key.into(), node[key].clone());
    }
    core.insert("repo".into(), node["repository"]["nameWithOwner"].clone());
    if let Some(author) = person(&node["author"]) {
        core.insert("author".into(), author);
    }
    for key in ["createdAt", "closedAt", "updatedAt"] {
        put(&mut core, key, &node[key]);
    }
    core.insert("assignees".into(), Value::Array(nodes(&node["assignees"]).iter().filter_map(person).collect()));
    core.insert(
        "labels".into(),
        Value::Array(
            nodes(&node["labels"])
                .iter()
                .filter_map(|l| Some(json!({ "name": l["name"].as_str()?, "color": l["color"].as_str().unwrap_or("ededed") })))
                .collect(),
        ),
    );
    let workload = json!({
        "updatedAt": node["updatedAt"],
        "linkedPullRequests": nodes(&node["closedByPullRequestsReferences"]).iter().filter_map(linked_item).collect::<Vec<_>>(),
    });
    let open = node["state"] == "OPEN";
    Some((id, Value::Object(core), workload, open))
}

fn merge_issues(org: &str, nodes: &[Value], full: bool) -> std::io::Result<()> {
    let mut store = read_store(Kind::Issues, org, "issues");
    let entries = store["issues"].as_object_mut().expect("store map");
    let mut kept: HashSet<String> = HashSet::new();
    let others = ["history"];
    for node in nodes {
        let Some((id, core, workload, open)) = issue_slots(node) else { continue };
        let entry = entries.entry(id.clone()).or_insert_with(|| json!({}));
        let merged = merge_core(entry.get("core"), core);
        entry["core"] = merged;
        if open {
            let held = entry.get("workload").cloned();
            if held.as_ref().is_none_or(|h| !held_is_newer(h, &workload)) {
                entry["workload"] = workload;
            }
            kept.insert(id);
        } else {
            drop_workload(entries, &id, &others);
        }
    }
    if full {
        let stale: Vec<String> = entries.iter().filter(|(id, e)| e.get("workload").is_some() && !kept.contains(*id)).map(|(id, _)| id.clone()).collect();
        for id in stale {
            drop_workload(entries, &id, &others);
        }
    }
    cache::write(Kind::Issues, org, &serde_json::to_vec(&store).unwrap_or_default())
}
