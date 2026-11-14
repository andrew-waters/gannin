//! The longer histories Scorecards and Activity read, synced into the
//! pilot's own copies as Gannin syncs them:
//!
//! - People (`OrgSnapshotCache`): the org's members and teams, hourly.
//! - Metrics (`MetricsStore`): each merged PR's reviews, review requests,
//!   first commit and ready time, in the PR store's `metrics` slot. Weekly
//!   chunks back to the Scorecard's window, newest first, and a top-up from
//!   a day before the last sync. `Metrics/<org>.json` says how far back.
//! - Work log (`WorkLogStore`): each PR's commits, reviews and merger in its
//!   `workLog` slot, and issues with their comments in `WorkLog/<org>.json`.
//!   Weeks back to Activity's window, then what changed since the last fetch.
//!
//! Coverage only ever moves back. What Gannin had when the pilot first read
//! a file is where the pilot starts, so a first sync is a top-up, not a
//! refetch. Not ported: the opened-per-week counts and the back-fill of
//! changed files and head refs on old PRs, which the pilot doesn't read.

use crate::cache::{self, Kind};
use crate::github::{self, Error};
use crate::sync::{advance, begin, finish, held_is_newer, merge_core, nodes, put, read_store, search_stamp, Progress};
use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone, Utc};
use serde_json::{json, Map, Value};

/// How far back Scorecards look by default: 13 weeks and two days.
pub const METRICS_DAYS: i64 = 13 * 7 + 2;
/// How far back Activity looks: its twelve-week view.
pub const WORK_LOG_DAYS: i64 = 12 * 7;

const METRIC_FIELDS: &str = "... on PullRequest { id number title url createdAt mergedAt updatedAt additions deletions changedFiles headRefName repository { nameWithOwner } author { __typename login avatarUrl } commits(first: 1) { nodes { commit { authoredDate } } } timelineItems(itemTypes: [READY_FOR_REVIEW_EVENT, REVIEW_REQUESTED_EVENT, REVIEW_REQUEST_REMOVED_EVENT], first: 50) { nodes { __typename ... on ReadyForReviewEvent { createdAt } ... on ReviewRequestedEvent { createdAt requestedReviewer { ... on User { login } } } ... on ReviewRequestRemovedEvent { createdAt requestedReviewer { ... on User { login } } } } } reviews(first: 50) { nodes { state submittedAt author { __typename login avatarUrl } } } }";

const WORK_LOG_PR_FIELDS: &str = "... on PullRequest { id number title url createdAt updatedAt mergedAt closedAt isDraft additions deletions repository { nameWithOwner } closingIssuesReferences(first: 5) { nodes { id number title url state repository { nameWithOwner } } } author { __typename login avatarUrl } mergedBy { login } commits(last: 100) { nodes { commit { authoredDate additions deletions messageHeadline url author { user { login } } } } } reviews(last: 50) { nodes { submittedAt state author { login } } } }";

const WORK_LOG_ISSUE_FIELDS: &str = "... on Issue { id number title url createdAt repository { nameWithOwner } author { login } comments(last: 30) { nodes { createdAt url author { login } } } }";

const MEMBERS: &str = "query($login: String!, $cursor: String) { organization(login: $login) { membersWithRole(first: 100, after: $cursor) { totalCount pageInfo { hasNextPage endCursor } nodes { login name avatarUrl } } } }";
const TEAMS: &str = "query($login: String!, $cursor: String) { organization(login: $login) { teams(first: 100, after: $cursor) { totalCount pageInfo { hasNextPage endCursor } nodes { id slug name members(first: 100) { nodes { login } } } } } }";
const USER: &str = "query($login: String!) { user(login: $login) { login name avatarUrl } }";

// MARK: - Time, as Gannin formats it

/// Swift's `.iso8601`: UTC, whole seconds.
fn iso(time: DateTime<Utc>) -> String {
    time.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn date(value: &Value) -> Option<DateTime<Utc>> {
    value.as_str()?.parse().ok()
}

/// `.iso8601.year().month().day()`, which formats in UTC: a local midnight
/// east of UTC prints the day before, as Gannin's searches do.
fn day(time: DateTime<Utc>) -> String {
    time.format("%Y-%m-%d").to_string()
}

fn local_midnight(date: NaiveDate) -> DateTime<Utc> {
    Local.from_local_datetime(&date.and_hms_opt(0, 0, 0).unwrap_or_default()).earliest().map(|t| t.with_timezone(&Utc)).unwrap_or_default()
}

fn start_of_day(time: DateTime<Utc>) -> DateTime<Utc> {
    local_midnight(time.with_timezone(&Local).date_naive())
}

/// The local Monday on or before `time`, as `Calendar.metrics`.
fn monday(time: DateTime<Utc>) -> DateTime<Utc> {
    use chrono::Datelike;
    let local = time.with_timezone(&Local).date_naive();
    local_midnight(local - Duration::days(local.weekday().num_days_from_monday() as i64))
}

/// `weeklyChunks`: from the local start of `from`'s day, `[s, s + 6 days]`
/// a week at a time, the last cut at `to`.
fn weekly_chunks(from: DateTime<Utc>, to: DateTime<Utc>) -> Vec<(DateTime<Utc>, DateTime<Utc>)> {
    let mut chunks = Vec::new();
    let mut start = start_of_day(from);
    while start < to {
        chunks.push((start, (start + Duration::days(6)).min(to)));
        start += Duration::days(7);
    }
    chunks
}

/// `ParallelSearches.weeks`: seven-day `[a, b)` steps from `from`, the last
/// cut at `to`.
fn weeks(from: DateTime<Utc>, to: DateTime<Utc>) -> Vec<(DateTime<Utc>, DateTime<Utc>)> {
    let mut chunks = Vec::new();
    let mut start = from;
    while start < to {
        chunks.push((start, (start + Duration::days(7)).min(to)));
        start += Duration::days(7);
    }
    chunks
}

fn read(kind: Kind, org: &str) -> Option<Value> {
    std::fs::read(cache::path(kind, org)).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok())
}

fn save(kind: Kind, org: &str, value: &Value) -> Result<(), Error> {
    cache::write(kind, org, &serde_json::to_vec(value).unwrap_or_default()).map_err(|e| Error::Other(format!("Couldn't save {kind:?}: {e}")))
}

/// Whether the pilot has synced this file itself yet. Until it has, the
/// copy is Gannin's, whose PR store the pilot copied at another time, so
/// the first top-up reaches a week further back to close any gap.
fn first_by_pilot(file: &Value) -> bool {
    file.get("pilotSyncedAt").is_none()
}

/// Puts an incoming slot on a PR, unless the held one is newer; the core
/// merges as the workload sync merges it.
fn put_slot(entries: &mut Map<String, Value>, id: &str, core: Value, slot: &str, value: Value) {
    let entry = entries.entry(id.to_string()).or_insert_with(|| json!({}));
    let merged = merge_core(entry.get("core"), core);
    entry["core"] = merged;
    if entry.get(slot).is_none_or(|held| !held_is_newer(held, &value)) {
        entry[slot] = value;
    }
}

fn core_of(node: &Value, changed_files: bool) -> Value {
    let mut core = Map::new();
    for key in ["id", "number", "title", "url"] {
        core.insert(key.into(), node[key].clone());
    }
    core.insert("repo".into(), node["repository"]["nameWithOwner"].clone());
    if let Some(login) = node["author"]["login"].as_str() {
        let mut author = Map::new();
        author.insert("login".into(), json!(login));
        put(&mut author, "avatarUrl", &node["author"]["avatarUrl"]);
        core.insert("author".into(), Value::Object(author));
        core.insert("authorIsBot".into(), json!(node["author"]["__typename"] == "Bot"));
    }
    for key in ["createdAt", "mergedAt", "updatedAt", "additions", "deletions"] {
        put(&mut core, key, &node[key]);
    }
    if changed_files {
        put(&mut core, "changedFiles", &node["changedFiles"]);
    }
    Value::Object(core)
}

// MARK: - People

/// Refreshes the org's members and teams in the pilot's snapshot when an
/// hour has passed, or on a manual refresh. A personal account is its own
/// only member.
pub fn sync_people(token: &str, org: &str, personal: bool, force: bool, progress: &Progress) -> Result<Option<usize>, Error> {
    let now = Utc::now();
    let mut snapshot = read(Kind::Snapshots, org).unwrap_or_else(|| {
        json!({ "orgLogin": org, "fetchedAt": iso(now), "lookbackDays": 14, "members": [], "teams": [], "warnings": [],
                "storedOpenIDs": [], "storedMergedIDs": [], "storedIssueIDs": [] })
    });
    let due = force || first_by_pilot(&snapshot) || date(&snapshot["peopleFetchedAt"]).is_none_or(|at| now - at >= Duration::hours(1));
    if !due {
        return Ok(None);
    }
    let title = "People";
    begin(progress, &[title]);
    let member = |node: &Value| -> Option<Value> {
        let mut person = Map::new();
        person.insert("login".into(), json!(node["login"].as_str()?));
        put(&mut person, "name", &node["name"]);
        put(&mut person, "avatarUrl", &node["avatarUrl"]);
        Some(Value::Object(person))
    };
    let (members, teams, warnings) = if personal {
        let data = github::graphql(token, USER, json!({ "login": org }))?;
        (member(&data["user"]).into_iter().collect::<Vec<_>>(), Vec::new(), Vec::<Value>::new())
    } else {
        let page = |query: &str, key: &str, cap: usize| -> Result<Vec<Value>, Error> {
            let mut found = Vec::new();
            let mut cursor: Option<String> = None;
            loop {
                let data = github::graphql(token, query, json!({ "login": org, "cursor": cursor }))?;
                let connection = &data["organization"][key];
                found.extend(nodes(connection));
                let total = connection["totalCount"].as_u64().unwrap_or(0) as usize;
                advance(progress, title, found.len(), total.min(cap).max(found.len()));
                cursor = connection["pageInfo"]["endCursor"].as_str().map(str::to_string);
                if connection["pageInfo"]["hasNextPage"] != true || cursor.is_none() || found.len() >= cap {
                    return Ok(found);
                }
            }
        };
        let members = page(MEMBERS, "membersWithRole", 1000)?.iter().filter_map(member).collect();
        let (teams, warnings) = match page(TEAMS, "teams", 300) {
            Ok(teams) => (
                teams
                    .iter()
                    .map(|t| {
                        json!({ "id": t["id"], "slug": t["slug"], "name": t["name"],
                                "members": nodes(&t["members"]).iter().filter_map(|m| m["login"].as_str().map(|l| json!(l))).collect::<Vec<_>>() })
                    })
                    .collect(),
                Vec::new(),
            ),
            Err(error) => (Vec::new(), vec![json!(format!("Teams unavailable: {error}"))]),
        };
        (members, teams, warnings)
    };
    let count = members.len();
    snapshot["members"] = Value::Array(members);
    snapshot["teams"] = Value::Array(teams);
    snapshot["warnings"] = Value::Array(warnings);
    snapshot["peopleFetchedAt"] = json!(iso(now));
    snapshot["fetchedAt"] = json!(iso(now));
    snapshot["pilotSyncedAt"] = json!(iso(now));
    save(Kind::Snapshots, org, &snapshot)?;
    finish(progress, title, Some(count));
    Ok(Some(count))
}

// MARK: - Metrics

/// A merged PR's `metrics` slot and its core, from a metrics search node.
fn metrics_slot(node: &Value) -> Option<(String, Value, Value)> {
    let id = node["id"].as_str()?.to_string();
    let author = node["author"]["login"].as_str();
    let mut reviews: Vec<Value> = nodes(&node["reviews"])
        .into_iter()
        .filter(|r| r["author"]["login"].is_string() && r["author"]["__typename"] != "Bot" && r["author"]["login"].as_str() != author)
        .filter(|r| r["state"] != "PENDING" && r["submittedAt"].is_string())
        .map(|r| json!({ "login": r["author"]["login"], "state": r["state"], "submittedAt": r["submittedAt"] }))
        .collect();
    reviews.sort_by(|a, b| a["submittedAt"].as_str().cmp(&b["submittedAt"].as_str()));
    let mut events = nodes(&node["timelineItems"]);
    events.sort_by(|a, b| a["createdAt"].as_str().cmp(&b["createdAt"].as_str()));
    let mut ready_at = Value::Null;
    let mut requests: Vec<Value> = Vec::new();
    for event in events {
        match event["__typename"].as_str() {
            Some("ReadyForReviewEvent") => ready_at = event["createdAt"].clone(),
            Some("ReviewRequestedEvent") => {
                if let (Some(login), Some(at)) = (event["requestedReviewer"]["login"].as_str(), event["createdAt"].as_str()) {
                    requests.push(json!({ "login": login, "requestedAt": at }));
                }
            }
            Some("ReviewRequestRemovedEvent") => {
                if let (Some(login), Some(at)) = (event["requestedReviewer"]["login"].as_str(), event["createdAt"].as_str()) {
                    if let Some(open) = requests.iter_mut().rev().find(|r| r["login"] == login && r.get("removedAt").is_none()) {
                        open["removedAt"] = json!(at);
                    }
                }
            }
            _ => {}
        }
    }
    let mut slot = Map::new();
    put(&mut slot, "updatedAt", &node["updatedAt"]);
    put(&mut slot, "firstCommitAt", &nodes(&node["commits"]).first().map(|c| c["commit"]["authoredDate"].clone()).unwrap_or(Value::Null));
    put(&mut slot, "readyAt", &ready_at);
    slot.insert("reviews".into(), Value::Array(reviews));
    slot.insert("reviewRequests".into(), Value::Array(requests));
    put(&mut slot, "headRef", &node["headRefName"]);
    Some((id, core_of(node, true), Value::Object(slot)))
}

/// Syncs merged PRs' metrics back to `window_days` before now (to the
/// Monday on or before), every ten minutes or on a manual refresh.
pub fn sync_metrics(token: &str, org: &str, scope: &str, window_days: i64, force: bool, progress: &Progress) -> Result<Option<usize>, Error> {
    let now = Utc::now();
    let start = monday(now - Duration::days(window_days));
    let mut history = read(Kind::Metrics, org).filter(|h| h["formatVersion"] == 5).unwrap_or_else(|| {
        json!({ "formatVersion": 5, "orgLogin": org, "coveredFrom": iso(now), "syncedAt": "0001-01-01T00:00:00Z", "openedPerWeek": [], "storedCount": 0 })
    });
    let first = first_by_pilot(&history);
    let mut covered_from = date(&history["coveredFrom"]).unwrap_or(now);
    let synced_at = date(&history["syncedAt"]).filter(|at| at.timestamp() > 0);
    let due = force || first || synced_at.is_none_or(|at| now - at >= Duration::minutes(10)) || covered_from > start;
    if !due {
        return Ok(None);
    }
    // The top-up first, from a day before the last sync; then back-fill,
    // newest week first.
    let mut chunks: Vec<(String, Option<DateTime<Utc>>)> = Vec::new();
    if let Some(synced) = synced_at {
        let since = if first { synced.min(now - Duration::days(7)) } else { synced } - Duration::hours(24);
        for (i, (from, to)) in weekly_chunks(since, now).into_iter().enumerate() {
            let range = if i == 0 { format!("{}..{}T23:59:59+00:00", search_stamp(since), day(to)) } else { format!("{}..{}", day(from), day(to)) };
            chunks.push((range, None));
        }
    }
    if covered_from > start {
        for (from, to) in weekly_chunks(start, covered_from).into_iter().rev() {
            chunks.push((format!("{}..{}", day(from), day(to)), Some(from)));
        }
    }
    let title = "Merged pull requests for Scorecards";
    begin(progress, &[title]);
    let mut store = read_store(Kind::PullRequests, org, "pullRequests");
    let mut found = 0;
    let total = chunks.len();
    let save_all = |store: &Value, history: &mut Value, covered_from: DateTime<Utc>| -> Result<(), Error> {
        let stored = store["pullRequests"].as_object().map(|m| m.values().filter(|p| p.get("metrics").is_some() && p["core"]["mergedAt"].is_string()).count()).unwrap_or(0);
        history["coveredFrom"] = json!(iso(covered_from));
        history["storedCount"] = json!(stored);
        save(Kind::PullRequests, org, store)?;
        save(Kind::Metrics, org, history)
    };
    for (i, (range, backfill_from)) in chunks.into_iter().enumerate() {
        let query = format!("{scope} archived:false is:pr is:merged merged:{range}");
        let (prs, _) = github::search_reporting(token, &query, 25, METRIC_FIELDS, &|_, _| {})?;
        found += prs.len();
        let entries = store["pullRequests"].as_object_mut().expect("store map");
        for node in &prs {
            if let Some((id, core, slot)) = metrics_slot(node) {
                put_slot(entries, &id, core, "metrics", slot);
            }
        }
        if let Some(from) = backfill_from {
            covered_from = covered_from.min(from);
        }
        advance(progress, title, i + 1, total);
        if (i + 1) % 8 == 0 {
            save_all(&store, &mut history, covered_from)?;
        }
    }
    history["syncedAt"] = json!(iso(now));
    history["pilotSyncedAt"] = json!(iso(now));
    save_all(&store, &mut history, covered_from.min(start))?;
    finish(progress, title, Some(found));
    Ok(Some(found))
}

// MARK: - Work log

/// `GitTimestamp`: the instant, and the offset the commit was made at.
fn commit_time(text: &str) -> Option<(DateTime<Utc>, Option<i64>)> {
    let parsed = DateTime::parse_from_rfc3339(text).ok()?;
    let offset = if text.ends_with('Z') { Some(0) } else { Some(parsed.offset().local_minus_utc() as i64) };
    Some((parsed.with_timezone(&Utc), offset))
}

/// A PR's `workLog` slot and its core, from a work log search node.
fn work_log_slot(node: &Value) -> Option<(String, Value, Value)> {
    let id = node["id"].as_str()?.to_string();
    let commits: Vec<Value> = nodes(&node["commits"])
        .iter()
        .filter_map(|c| {
            let commit = &c["commit"];
            let (at, offset) = commit_time(commit["authoredDate"].as_str()?)?;
            let mut out = Map::new();
            out.insert("authoredAt".into(), json!(iso(at)));
            put(&mut out, "author", &commit["author"]["user"]["login"]);
            out.insert("additions".into(), json!(commit["additions"].as_i64().unwrap_or(0)));
            out.insert("deletions".into(), json!(commit["deletions"].as_i64().unwrap_or(0)));
            if let Some(offset) = offset {
                out.insert("utcOffset".into(), json!(offset));
            }
            put(&mut out, "message", &commit["messageHeadline"]);
            put(&mut out, "url", &commit["url"]);
            Some(Value::Object(out))
        })
        .collect();
    let reviews: Vec<Value> = nodes(&node["reviews"])
        .iter()
        .filter(|r| r["submittedAt"].is_string() && r["author"]["login"].is_string() && r["state"] != "PENDING")
        .map(|r| json!({ "submittedAt": r["submittedAt"], "author": r["author"]["login"], "state": r["state"] }))
        .collect();
    let closing: Vec<Value> = nodes(&node["closingIssuesReferences"]).iter().filter_map(crate::sync::linked_item).collect();
    let mut slot = Map::new();
    put(&mut slot, "updatedAt", &node["updatedAt"]);
    put(&mut slot, "closedAt", &node["closedAt"]);
    put(&mut slot, "mergedBy", &node["mergedBy"]["login"]);
    slot.insert("commits".into(), Value::Array(commits));
    slot.insert("reviews".into(), Value::Array(reviews));
    put(&mut slot, "isDraft", &node["isDraft"]);
    slot.insert("closingIssues".into(), Value::Array(closing));
    Some((id, core_of(node, false), Value::Object(slot)))
}

fn work_log_issue(node: &Value) -> Option<(String, Value)> {
    let id = node["id"].as_str()?.to_string();
    let mut issue = Map::new();
    for key in ["id", "number", "title", "url", "createdAt"] {
        issue.insert(key.into(), node[key].clone());
    }
    issue.insert("repo".into(), node["repository"]["nameWithOwner"].clone());
    put(&mut issue, "author", &node["author"]["login"]);
    let comments: Vec<Value> = nodes(&node["comments"])
        .iter()
        .filter(|c| c["author"]["login"].is_string())
        .map(|c| {
            let mut comment = Map::new();
            comment.insert("createdAt".into(), c["createdAt"].clone());
            comment.insert("author".into(), c["author"]["login"].clone());
            put(&mut comment, "url", &c["url"]);
            Value::Object(comment)
        })
        .collect();
    issue.insert("comments".into(), Value::Array(comments));
    Some((id, Value::Object(issue)))
}

/// Syncs the work log back to `window_days` before today: weeks it hasn't
/// covered yet, then what changed since the last fetch, every ten minutes
/// or on a manual refresh.
pub fn sync_work_log(token: &str, org: &str, scope: &str, window_days: i64, force: bool, progress: &Progress) -> Result<Option<usize>, Error> {
    let now = Utc::now();
    let start = start_of_day(now) - Duration::days(window_days.max(28));
    let held = read(Kind::WorkLog, org).filter(|l| l["version"] == 5);
    let fresh = held.is_none();
    let mut log = held.unwrap_or_else(|| json!({ "version": 5, "orgLogin": org, "coveredFrom": iso(now), "fetchedAt": iso(now), "storedCount": 0, "issues": {} }));
    let first = first_by_pilot(&log);
    let covered_from = date(&log["coveredFrom"]).unwrap_or(now);
    let fetched_at = date(&log["fetchedAt"]).unwrap_or(now);
    let due = force || first || now - fetched_at >= Duration::minutes(10);
    // Each window: from, and to (None is open-ended).
    let mut windows: Vec<(DateTime<Utc>, Option<DateTime<Utc>>)> = Vec::new();
    if fresh {
        let all = weeks(start, now);
        let last = all.len().saturating_sub(1);
        windows.extend(all.into_iter().enumerate().map(|(i, (a, b))| (a, (i < last).then_some(b))));
    } else {
        if start < covered_from {
            windows.extend(weeks(start, covered_from).into_iter().map(|(a, b)| (a, Some(b))));
        }
        if due {
            let cursor = if first { fetched_at.min(now - Duration::days(7)) } else { fetched_at } - Duration::minutes(5);
            windows.push((cursor, None));
        }
    }
    if windows.is_empty() {
        return Ok(None);
    }
    let title = "Work log";
    begin(progress, &[title]);
    let range = |a: DateTime<Utc>, b: Option<DateTime<Utc>>| match b {
        Some(b) => format!("updated:{}..{}", search_stamp(a), search_stamp(b)),
        None => format!("updated:>={}", search_stamp(a)),
    };
    let mut prs: Vec<Value> = Vec::new();
    let mut issues: Vec<Value> = Vec::new();
    let total = windows.len();
    // Two windows at a time: four searches, as Gannin runs up to four.
    for (done, pair) in windows.chunks(2).enumerate() {
        let results = std::thread::scope(|threads| {
            let handles: Vec<_> = pair
                .iter()
                .map(|&(a, b)| {
                    let r = range(a, b);
                    let pr_query = format!("{scope} archived:false is:pr {r}");
                    let issue_query = format!("{scope} archived:false is:issue {r}");
                    (
                        threads.spawn(move || github::search_reporting(token, &pr_query, 20, WORK_LOG_PR_FIELDS, &|_, _| {})),
                        threads.spawn(move || github::search_reporting(token, &issue_query, 50, WORK_LOG_ISSUE_FIELDS, &|_, _| {})),
                    )
                })
                .collect();
            handles.into_iter().map(|(p, i)| (p.join().expect("search thread"), i.join().expect("search thread"))).collect::<Vec<_>>()
        });
        for (found_prs, found_issues) in results {
            prs.extend(found_prs?.0);
            issues.extend(found_issues?.0);
        }
        advance(progress, title, ((done + 1) * 2).min(total), total);
    }
    let mut store = read_store(Kind::PullRequests, org, "pullRequests");
    let entries = store["pullRequests"].as_object_mut().expect("store map");
    for node in &prs {
        if let Some((id, core, slot)) = work_log_slot(node) {
            put_slot(entries, &id, core, "workLog", slot);
        }
    }
    let stored = entries.values().filter(|p| p.get("workLog").is_some()).count();
    save(Kind::PullRequests, org, &store)?;
    let held_issues = log["issues"].as_object_mut().expect("issues map");
    for node in &issues {
        if let Some((id, issue)) = work_log_issue(node) {
            held_issues.insert(id, issue);
        }
    }
    log["coveredFrom"] = json!(iso(covered_from.min(start)));
    log["fetchedAt"] = json!(iso(now));
    log["storedCount"] = json!(stored);
    log["pilotSyncedAt"] = json!(iso(now));
    save(Kind::WorkLog, org, &log)?;
    let count = prs.len() + issues.len();
    finish(progress, title, Some(count));
    Ok(Some(count))
}

// MARK: - Issue history

const ISSUE_HISTORY_FIELDS: &str = "... on Issue { id number title url createdAt updatedAt closedAt stateReason repository { nameWithOwner } author { login } assignees(first: 10) { nodes { login } } labels(first: 20) { nodes { name } } issueType { name } milestone { title } parent { id } timelineItems(itemTypes: [PROJECT_V2_ITEM_STATUS_CHANGED_EVENT, ASSIGNED_EVENT, REOPENED_EVENT, SUB_ISSUE_ADDED_EVENT], first: 100) { nodes { __typename ... on ProjectV2ItemStatusChangedEvent { createdAt status project { number title } } ... on AssignedEvent { createdAt } ... on ReopenedEvent { createdAt } ... on SubIssueAddedEvent { createdAt } } } projectItems(first: 5) { nodes { project { number title } fieldValues(first: 30) { nodes { ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name dataType } } } ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { name dataType } } } ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name dataType } } } ... on ProjectV2ItemFieldSingleSelectValue { name optionId field { ... on ProjectV2FieldCommon { name dataType } ... on ProjectV2SingleSelectField { options { id } } } } ... on ProjectV2ItemFieldIterationValue { title startDate field { ... on ProjectV2FieldCommon { name dataType } } } ... on ProjectV2ItemFieldMultiSelectValue { options { name } field { ... on ProjectV2FieldCommon { name dataType } } } } } } } closedByPullRequestsReferences(first: 5, includeClosedPrs: true) { nodes { number url createdAt mergedAt state repository { nameWithOwner } commits(last: 50) { nodes { commit { authoredDate } } } reviews(last: 20) { nodes { submittedAt } } } } mentionedInPullRequests: timelineItems(itemTypes: [CROSS_REFERENCED_EVENT], last: 20) { nodes { ... on CrossReferencedEvent { source { ... on PullRequest { number url createdAt mergedAt state repository { nameWithOwner } } } } } } }";

/// A `YYYY-MM-DD` as Swift stores it: UTC midnight.
fn day_value(text: &str) -> Option<String> {
    NaiveDate::parse_from_str(text, "%Y-%m-%d").ok().map(|d| format!("{}T00:00:00Z", d.format("%Y-%m-%d")))
}

/// One project item's field values, keyed by field name, in the shapes
/// Swift's synthesized `IssueFieldValue` Codable writes.
fn project_values(values: &[Value]) -> Map<String, Value> {
    let mut out = Map::new();
    for value in values {
        let field = &value["field"];
        let Some(name) = field["name"].as_str() else { continue };
        let encoded = match field["dataType"].as_str() {
            Some("TEXT") => value["text"].as_str().filter(|t| !t.is_empty()).map(|t| json!({ "text": { "_0": t } })),
            Some("NUMBER") => value["number"].as_f64().map(|n| json!({ "number": { "_0": n } })),
            Some("DATE") => value["date"].as_str().and_then(day_value).map(|d| json!({ "date": { "_0": d } })),
            Some("SINGLE_SELECT") => value["name"].as_str().filter(|n| !n.is_empty()).map(|n| {
                let position = field["options"].as_array().and_then(|o| o.iter().position(|o| o["id"] == value["optionId"])).map(|p| p as i64).unwrap_or(i64::MAX);
                json!({ "option": { "name": n, "position": position } })
            }),
            Some("ITERATION") => value["title"].as_str().filter(|t| !t.is_empty()).map(|t| {
                let mut iteration = Map::new();
                iteration.insert("title".into(), json!(t));
                if let Some(start) = value["startDate"].as_str().and_then(day_value) {
                    iteration.insert("start".into(), json!(start));
                }
                json!({ "iteration": iteration })
            }),
            Some("MULTI_SELECT") => {
                let names: Vec<Value> = value["options"].as_array().map(|o| o.iter().filter_map(|o| o["name"].as_str().map(|n| json!(n))).collect()).unwrap_or_default();
                (!names.is_empty()).then(|| json!({ "options": { "_0": names } }))
            }
            _ => None,
        };
        if let Some(encoded) = encoded {
            out.insert(name.to_string(), encoded);
        }
    }
    out
}

/// An issue's `history` slot and its core, from a history search node.
fn issue_history(node: &Value) -> Option<(String, Value, Value)> {
    let id = node["id"].as_str()?.to_string();
    let repo = node["repository"]["nameWithOwner"].as_str().unwrap_or("");
    let mut core = Map::new();
    for key in ["id", "number", "title", "url"] {
        core.insert(key.into(), node[key].clone());
    }
    core.insert("repo".into(), json!(repo));
    if let Some(login) = node["author"]["login"].as_str() {
        core.insert("author".into(), json!({ "login": login }));
    }
    for key in ["createdAt", "closedAt", "updatedAt"] {
        put(&mut core, key, &node[key]);
    }
    core.insert("assignees".into(), Value::Array(nodes(&node["assignees"]).iter().filter_map(|p| p["login"].as_str().map(|l| json!({ "login": l }))).collect()));
    core.insert("labels".into(), Value::Array(nodes(&node["labels"]).iter().filter_map(|l| l["name"].as_str().map(|n| json!({ "name": n }))).collect()));

    let events = nodes(&node["timelineItems"]);
    let times = |kind: &str| -> Vec<Value> {
        let mut at: Vec<&str> = events.iter().filter(|e| e["__typename"] == kind).filter_map(|e| e["createdAt"].as_str()).collect();
        at.sort();
        at.into_iter().map(|a| json!(a)).collect()
    };
    let mut changes: Vec<Value> = events
        .iter()
        .filter(|e| e["__typename"] == "ProjectV2ItemStatusChangedEvent")
        .filter_map(|e| {
            let status = e["status"].as_str().filter(|s| !s.is_empty())?;
            let mut change = Map::new();
            change.insert("at".into(), json!(e["createdAt"].as_str()?));
            change.insert("status".into(), json!(status));
            put(&mut change, "projectNumber", &e["project"]["number"]);
            put(&mut change, "projectTitle", &e["project"]["title"]);
            Some(Value::Object(change))
        })
        .collect();
    changes.sort_by(|a, b| a["at"].as_str().cmp(&b["at"].as_str()));
    let linked_pr = |pr: &Value, activity: Vec<Value>| -> Option<Value> {
        let mut out = Map::new();
        out.insert("number".into(), json!(pr["number"].as_i64()?));
        out.insert("url".into(), json!(pr["url"].as_str()?));
        out.insert("createdAt".into(), json!(pr["createdAt"].as_str()?));
        put(&mut out, "mergedAt", &pr["mergedAt"]);
        out.insert("state".into(), json!(pr["state"].as_str()?));
        if let Some(other) = pr["repository"]["nameWithOwner"].as_str().filter(|r| *r != repo) {
            out.insert("repo".into(), json!(other));
        }
        out.insert("activityAt".into(), Value::Array(activity));
        Some(Value::Object(out))
    };
    let linked: Vec<Value> = nodes(&node["closedByPullRequestsReferences"])
        .iter()
        .filter_map(|pr| {
            let mut activity: Vec<String> = nodes(&pr["commits"]).iter().filter_map(|c| c["commit"]["authoredDate"].as_str().map(str::to_string)).collect();
            activity.extend(nodes(&pr["reviews"]).iter().filter_map(|r| r["submittedAt"].as_str().map(str::to_string)));
            activity.sort();
            linked_pr(pr, activity.into_iter().map(|a| json!(a)).collect())
        })
        .collect();
    let mut seen: Vec<String> = linked.iter().filter_map(|p| p["url"].as_str().map(str::to_string)).collect();
    let mentioned: Vec<Value> = nodes(&node["mentionedInPullRequests"])
        .iter()
        .filter_map(|e| {
            let pr = &e["source"];
            let url = pr["url"].as_str()?.to_string();
            if seen.contains(&url) {
                return None;
            }
            seen.push(url);
            linked_pr(pr, Vec::new())
        })
        .collect();
    let fields: Vec<Value> = nodes(&node["projectItems"])
        .iter()
        .filter_map(|item| {
            Some(json!({
                "projectNumber": item["project"]["number"].as_i64()?,
                "projectTitle": item["project"]["title"].as_str()?,
                "values": project_values(&nodes(&item["fieldValues"])),
            }))
        })
        .collect();
    let mut history = Map::new();
    put(&mut history, "updatedAt", &node["updatedAt"]);
    put(&mut history, "issueType", &node["issueType"]["name"]);
    put(&mut history, "milestone", &node["milestone"]["title"]);
    put(&mut history, "parentID", &node["parent"]["id"]);
    put(&mut history, "stateReason", &node["stateReason"]);
    history.insert("statusChanges".into(), Value::Array(changes));
    history.insert("assignedAt".into(), Value::Array(times("AssignedEvent")));
    history.insert("reopenedAt".into(), Value::Array(times("ReopenedEvent")));
    history.insert("subIssuesAddedAt".into(), Value::Array(times("SubIssueAddedEvent")));
    history.insert("linkedPullRequests".into(), Value::Array(linked));
    history.insert("mentionedInPullRequests".into(), Value::Array(mentioned));
    history.insert("projectFields".into(), Value::Array(fields));
    Some((id, Value::Object(core), Value::Object(history)))
}

/// Syncs issue histories back to the Scorecard's window: issues closed in
/// each week not yet covered, the open ones on a first sync, and what
/// changed since the last, every ten minutes or on a manual refresh.
/// Gannin's pruning of open issues no search returned isn't ported.
pub fn sync_issue_history(token: &str, org: &str, scope: &str, window_days: i64, force: bool, progress: &Progress) -> Result<Option<usize>, Error> {
    let now = Utc::now();
    let start = monday(now - Duration::days(window_days));
    let held = read(Kind::IssueHistory, org).filter(|h| h["version"] == 1);
    let fresh = held.is_none();
    let mut history = held.unwrap_or_else(|| json!({ "version": 1, "orgLogin": org, "coveredFrom": iso(now), "syncedAt": iso(now), "openFetchedAt": iso(now), "storedIDs": [] }));
    let first = first_by_pilot(&history);
    let covered_from = if fresh { now } else { date(&history["coveredFrom"]).unwrap_or(now) };
    let synced_at = date(&history["syncedAt"]).unwrap_or(now);
    let due = force || first || now - synced_at >= Duration::minutes(10);
    let mut queries: Vec<String> = Vec::new();
    if start < covered_from {
        queries.extend(weeks(start, covered_from).into_iter().map(|(a, b)| format!("closed:{}..{}", search_stamp(a), search_stamp(b))));
    }
    if fresh {
        queries.push("is:open".into());
    } else if due {
        let cursor = if first { synced_at.min(now - Duration::days(7)) } else { synced_at } - Duration::minutes(5);
        queries.push(format!("updated:>={}", search_stamp(cursor)));
    }
    if queries.is_empty() {
        return Ok(None);
    }
    let title = "Issue history";
    begin(progress, &[title]);
    let total = queries.len();
    let mut found: Vec<Value> = Vec::new();
    for (done, batch) in queries.chunks(4).enumerate() {
        let results = std::thread::scope(|threads| {
            let handles: Vec<_> = batch
                .iter()
                .map(|q| {
                    let query = format!("{scope} archived:false is:issue {q}");
                    threads.spawn(move || github::search_reporting(token, &query, 15, ISSUE_HISTORY_FIELDS, &|_, _| {}))
                })
                .collect();
            handles.into_iter().map(|h| h.join().expect("search thread")).collect::<Vec<_>>()
        });
        for result in results {
            found.extend(result?.0);
        }
        advance(progress, title, ((done + 1) * 4).min(total), total);
    }
    let mut store = read_store(Kind::Issues, org, "issues");
    let entries = store["issues"].as_object_mut().expect("store map");
    let mut ids: std::collections::BTreeSet<String> = history["storedIDs"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default();
    for node in &found {
        if let Some((id, core, slot)) = issue_history(node) {
            put_slot(entries, &id, core, "history", slot);
            ids.insert(id);
        }
    }
    save(Kind::Issues, org, &store)?;
    history["storedIDs"] = json!(ids.into_iter().collect::<Vec<_>>());
    history["coveredFrom"] = json!(iso(covered_from.min(start)));
    history["syncedAt"] = json!(iso(now));
    if fresh {
        history["openFetchedAt"] = json!(iso(now));
    }
    history["pilotSyncedAt"] = json!(iso(now));
    save(Kind::IssueHistory, org, &history)?;
    finish(progress, title, Some(found.len()));
    Ok(Some(found.len()))
}
