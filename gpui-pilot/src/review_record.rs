//! A review's record in the harness, as Gannin keeps it for Agents ›
//! Metrics (`ReviewRecord`, `SessionStore.recordReview`): one JSON file per
//! pull request and reviewer, `.gannin/reviews/<owner>/<name>/<number>-
//! <reviewer>.json`, committed to the harness's default branch through
//! GitHub's API (no local git) as the signed-in person.
//!
//! It's written when a review is posted, and updated (each a commit of its
//! own, only when something changed) when the review's tab closes and when
//! Check for Changes finds the PR merged or closed. Each write re-reads the
//! PR's title, author, state and review threads, and marks a posted finding
//! resolved once a resolved thread of the reviewer's on its file starts
//! with its text. A branch that only takes pull requests gets one, merged
//! at once; one that can't merge is left open and said so.
//!
//! The format must stay as Gannin writes it: snake_case keys, sorted,
//! dates in UTC whole seconds, nil keys left out.

use crate::github;
use crate::review::{Finding, ReviewResult};
use chrono::{DateTime, Utc};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};

static RECORDING: AtomicBool = AtomicBool::new(true);
static LOADED: AtomicBool = AtomicBool::new(false);

fn pref_path() -> std::path::PathBuf {
    std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_default().join("Library/Application Support/GanninGPUIPilot/record-reviews")
}

/// Record reviews in the harness: on unless turned off, as Gannin's
/// `recordReviewsInHarness`. Off, nothing is recorded, updates included.
pub fn recording() -> bool {
    if !LOADED.swap(true, Ordering::Relaxed) {
        RECORDING.store(std::fs::read_to_string(pref_path()).map(|s| s.trim() != "0").unwrap_or(true), Ordering::Relaxed);
    }
    RECORDING.load(Ordering::Relaxed)
}

pub fn set_recording(on: bool) {
    LOADED.store(true, Ordering::Relaxed);
    RECORDING.store(on, Ordering::Relaxed);
    let _ = std::fs::write(pref_path(), if on { "1" } else { "0" });
}

/// What a write knows of the review.
pub struct Input {
    /// The harness, "owner/name".
    pub harness: String,
    pub repo: String,
    pub number: i64,
    /// The PR's node ID.
    pub pr_id: String,
    pub title: String,
    pub started_at: DateTime<Utc>,
    pub result: Option<ReviewResult>,
    pub dismissed: HashSet<String>,
    pub edits: HashMap<String, String>,
    /// Posting now: the event and when.
    pub posting: Option<(String, DateTime<Utc>)>,
}

fn iso(time: DateTime<Utc>) -> String {
    time.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn put(map: &mut Map<String, Value>, key: &str, value: Option<Value>) {
    match value.filter(|v| !v.is_null()) {
        Some(value) => {
            map.insert(key.into(), value);
        }
        None => {
            map.remove(key);
        }
    }
}

/// Keys sorted at every level, as `.sortedKeys` writes them.
fn sorted(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut entries: Vec<(String, Value)> = map.into_iter().collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            Value::Object(entries.into_iter().map(|(k, v)| (k, sorted(v))).collect())
        }
        Value::Array(items) => Value::Array(items.into_iter().map(sorted).collect()),
        other => other,
    }
}

/// Apple's pretty print: two spaces, `"key" : value`.
struct AppleFormatter(serde_json::ser::PrettyFormatter<'static>);

impl serde_json::ser::Formatter for AppleFormatter {
    fn begin_array<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> {
        self.0.begin_array(w)
    }
    fn end_array<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> {
        self.0.end_array(w)
    }
    fn begin_array_value<W: ?Sized + std::io::Write>(&mut self, w: &mut W, first: bool) -> std::io::Result<()> {
        self.0.begin_array_value(w, first)
    }
    fn end_array_value<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> {
        self.0.end_array_value(w)
    }
    fn begin_object<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> {
        self.0.begin_object(w)
    }
    fn end_object<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> {
        self.0.end_object(w)
    }
    fn begin_object_key<W: ?Sized + std::io::Write>(&mut self, w: &mut W, first: bool) -> std::io::Result<()> {
        self.0.begin_object_key(w, first)
    }
    fn begin_object_value<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> {
        w.write_all(b" : ")
    }
    fn end_object_value<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> {
        self.0.end_object_value(w)
    }
}

fn encode(record: &Value) -> String {
    let mut out = Vec::new();
    let mut serializer = serde_json::Serializer::with_formatter(&mut out, AppleFormatter(serde_json::ser::PrettyFormatter::with_indent(b"  ")));
    let _ = serde::Serialize::serialize(&sorted(record.clone()), &mut serializer);
    let mut text = String::from_utf8(out).unwrap_or_default();
    text.push('\n');
    text
}

fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(TABLE[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

const CATEGORIES: [&str; 6] = ["correctness", "data", "stability", "security", "performance", "maintainability"];

/// The record from the one at the branch head (if any), as
/// `ReviewRecord.updated` merges: findings matched by key, a posted one
/// left as it was posted, new ones added, vanished ones kept.
fn build(existing: Option<&Value>, input: &Input, reviewer: &str, outcome: Option<&Value>, now: DateTime<Utc>) -> Value {
    let mut record: Map<String, Value> = existing.and_then(|e| e.as_object().cloned()).unwrap_or_default();
    record.insert("repo".into(), json!(input.repo));
    record.insert("number".into(), json!(input.number));
    record.insert("reviewer".into(), record.get("reviewer").cloned().unwrap_or(json!(reviewer)));
    let title = outcome.and_then(|o| o["title"].as_str()).unwrap_or(&input.title);
    record.insert("title".into(), json!(title));
    if let Some(author) = outcome.and_then(|o| o["author"]["login"].as_str()) {
        record.insert("author".into(), json!(author));
    }
    if !record.contains_key("started_at") {
        record.insert("started_at".into(), json!(iso(input.started_at)));
    }
    if let Some(result) = &input.result {
        put(&mut record, "verdict", result.verdict.clone().map(Value::from));
        put(&mut record, "effort", result.effort.map(Value::from));
    }
    if let Some(outcome) = outcome {
        put(&mut record, "state", outcome["state"].as_str().map(Value::from));
        put(&mut record, "merged_at", outcome["mergedAt"].as_str().and_then(|t| t.parse::<DateTime<Utc>>().ok()).map(|t| Value::from(iso(t))));
    }
    // Findings.
    let mut findings: Vec<Value> = record.get("findings").and_then(Value::as_array).cloned().unwrap_or_default();
    let posting = input.posting.clone();
    if let Some(result) = &input.result {
        for finding in &result.findings {
            let key = finding.key();
            let dismissed = input.dismissed.contains(&key);
            let edited = input.edits.get(&key);
            let entry = recorded(finding, dismissed, edited);
            match findings.iter_mut().find(|f| f["key"] == key.as_str()) {
                Some(held) if held.get("posted_at").is_some() => {}
                Some(held) => {
                    let resolved = held.get("resolved_at").cloned();
                    *held = entry;
                    if let Some(resolved) = resolved {
                        held["resolved_at"] = resolved;
                    }
                }
                None => findings.push(entry),
            }
        }
    }
    if let Some((event, at)) = &posting {
        for finding in findings.iter_mut().filter(|f| f["decision"] != "dismissed" && f.get("posted_at").is_none()) {
            finding["posted_at"] = json!(iso(*at));
        }
        record.insert("posted_at".into(), json!(iso(*at)));
        record.insert("event".into(), json!(event));
    }
    // Threads resolved: the reviewer's, on the finding's file, starting
    // with its text.
    if let Some(threads) = outcome.and_then(|o| o["reviewThreads"]["nodes"].as_array()) {
        for finding in findings.iter_mut().filter(|f| f.get("posted_at").is_some() && f.get("resolved_at").is_none()) {
            let start: String = finding["excerpt"].as_str().unwrap_or("").trim().chars().take(40).collect();
            let matched = threads.iter().any(|t| {
                let first = &t["comments"]["nodes"][0];
                t["isResolved"] == true
                    && t["path"] == finding["path"]
                    && first["author"]["login"].as_str().is_some_and(|l| l.eq_ignore_ascii_case(reviewer))
                    && !start.is_empty()
                    && first["body"].as_str().is_some_and(|b| b.trim().starts_with(&start))
            });
            if matched {
                finding["resolved_at"] = json!(iso(now));
            }
        }
    }
    record.insert("findings".into(), Value::Array(findings));
    // An approval not posted, while the PR's still open.
    let event = record.get("event").and_then(Value::as_str).unwrap_or("");
    let state = record.get("state").and_then(Value::as_str).unwrap_or("OPEN");
    let held = record.get("verdict").and_then(Value::as_str) == Some("approve") && event != "APPROVE" && state != "MERGED" && state != "CLOSED";
    put(&mut record, "approval_held", held.then_some(json!(true)));
    record.insert("updated_at".into(), json!(iso(now)));
    Value::Object(record)
}

fn recorded(finding: &Finding, dismissed: bool, edited: Option<&String>) -> Value {
    let mut entry = Map::new();
    entry.insert("key".into(), json!(finding.key()));
    entry.insert("path".into(), json!(finding.path));
    put(&mut entry, "line", finding.line.map(Value::from));
    put(&mut entry, "severity", finding.severity.as_ref().map(|s| Value::from(s.to_lowercase())));
    put(&mut entry, "category", finding.category.as_ref().filter(|c| CATEGORIES.contains(&c.as_str())).map(|c| Value::from(c.as_str())));
    let (decision, text) = match (dismissed, edited) {
        (true, _) => ("dismissed", finding.comment.as_str()),
        (false, Some(text)) => ("edited", text.as_str()),
        (false, None) => ("kept", finding.comment.as_str()),
    };
    entry.insert("decision".into(), json!(decision));
    entry.insert("excerpt".into(), json!(text.chars().take(80).collect::<String>()));
    Value::Object(entry)
}

/// The same record but for when it was written.
fn same(a: &Value, b: &Value) -> bool {
    let strip = |v: &Value| {
        let mut v = sorted(v.clone());
        if let Some(map) = v.as_object_mut() {
            map.remove("updated_at");
        }
        v
    };
    strip(a) == strip(b)
}

fn gql(token: &str, query: &str, variables: Value) -> Result<Value, String> {
    github::graphql(token, query, variables).map_err(|e| e.to_string())
}

/// Writes (or updates) the review's record. Blocking; returns a note for
/// the person when a pull request it opened is left open.
pub fn record(token: &str, input: &Input) -> Result<Option<String>, String> {
    if !recording() || input.harness.is_empty() {
        return Ok(None);
    }
    if input.result.is_none() && input.posting.is_none() {
        return Ok(None);
    }
    let reviewer = crate::auth::saved_viewer().map(|v| v.login).ok_or("Not signed in")?;
    let (owner, name) = input.repo.split_once('/').ok_or("Not a repository")?;
    let path = format!(".gannin/reviews/{owner}/{name}/{}-{}.json", input.number, reviewer.to_lowercase());
    let outcome = gql(
        token,
        "query($id: ID!) { node(id: $id) { ... on PullRequest { title author { login } state mergedAt reviewThreads(first: 100) { nodes { isResolved path comments(first: 1) { nodes { author { login } body } } } } } } }",
        json!({ "id": input.pr_id }),
    )
    .ok()
    .map(|d| d["node"].clone());
    let (h_owner, h_name) = input.harness.split_once('/').ok_or("Not a harness repository")?;
    for attempt in 0..2 {
        let head = gql(
            token,
            "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id defaultBranchRef { name target { oid } } } }",
            json!({ "owner": h_owner, "name": h_name }),
        )?;
        let repo_id = head["repository"]["id"].as_str().unwrap_or_default().to_string();
        let branch = head["repository"]["defaultBranchRef"]["name"].as_str().ok_or("The harness has no default branch")?.to_string();
        let oid = head["repository"]["defaultBranchRef"]["target"]["oid"].as_str().ok_or("The harness has no head")?.to_string();
        let file = gql(
            token,
            "query($owner: String!, $name: String!, $expr: String!) { repository(owner: $owner, name: $name) { object(expression: $expr) { ... on Blob { text } } } }",
            json!({ "owner": h_owner, "name": h_name, "expr": format!("{oid}:{path}") }),
        )?;
        let existing: Option<Value> = file["repository"]["object"]["text"].as_str().and_then(|t| serde_json::from_str(t).ok());
        let now = Utc::now();
        let built = build(existing.as_ref(), input, &reviewer, outcome.as_ref(), now);
        if existing.as_ref().is_some_and(|e| same(e, &built)) {
            return Ok(None);
        }
        let what = if input.posting.is_some() {
            "posted"
        } else {
            match built["state"].as_str() {
                Some("MERGED") => "merged",
                Some("CLOSED") => "closed",
                _ => "updated",
            }
        };
        let headline = format!("Gannin: review of {}#{} by {reviewer}, {what}", input.repo, input.number);
        let contents = base64(encode(&built).as_bytes());
        match commit(token, &input.harness, &branch, &oid, &headline, &path, &contents) {
            Ok(()) => return Ok(None),
            Err(error) if attempt == 0 && (error.contains("expected") || error.contains("Expected")) => continue,
            Err(error) if error.to_lowercase().contains("pull request") || error.to_lowercase().contains("rule violation") => {
                return via_pull_request(token, &input.harness, &repo_id, &branch, &oid, &headline, &path, &contents);
            }
            Err(error) => return Err(error),
        }
    }
    Err("The harness kept moving while recording the review.".into())
}

/// Commits one file to the harness's default branch through GitHub's API:
/// `build` makes its new text from the text at the head (None skips the
/// commit, nothing having changed). Rebuilt on the new head and retried
/// once if the branch moved; a branch that needs a pull request gets one,
/// merged at once, or left open and said so.
pub fn commit_file(token: &str, harness: &str, path: &str, headline: &str, build: &dyn Fn(Option<&str>) -> Option<String>) -> Result<Option<String>, String> {
    let (owner, name) = harness.split_once('/').ok_or("Not a harness repository")?;
    for attempt in 0..2 {
        let head = gql(
            token,
            "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id defaultBranchRef { name target { oid } } } }",
            json!({ "owner": owner, "name": name }),
        )?;
        let repo_id = head["repository"]["id"].as_str().unwrap_or_default().to_string();
        let branch = head["repository"]["defaultBranchRef"]["name"].as_str().ok_or("The harness has no default branch")?.to_string();
        let oid = head["repository"]["defaultBranchRef"]["target"]["oid"].as_str().ok_or("The harness has no head")?.to_string();
        let file = gql(
            token,
            "query($owner: String!, $name: String!, $expr: String!) { repository(owner: $owner, name: $name) { object(expression: $expr) { ... on Blob { text } } } }",
            json!({ "owner": owner, "name": name, "expr": format!("{oid}:{path}") }),
        )?;
        let Some(text) = build(file["repository"]["object"]["text"].as_str()) else { return Ok(None) };
        let contents = base64(text.as_bytes());
        match commit(token, harness, &branch, &oid, headline, path, &contents) {
            Ok(()) => return Ok(None),
            Err(error) if attempt == 0 && (error.contains("expected") || error.contains("Expected")) => continue,
            Err(error) if error.to_lowercase().contains("pull request") || error.to_lowercase().contains("rule violation") => {
                return via_pull_request(token, harness, &repo_id, &branch, &oid, headline, path, &contents);
            }
            Err(error) => return Err(error),
        }
    }
    Err("The harness kept moving while committing.".into())
}

fn commit(token: &str, repo: &str, branch: &str, oid: &str, headline: &str, path: &str, contents: &str) -> Result<(), String> {
    gql(
        token,
        "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
        json!({ "input": {
            "branch": { "repositoryNameWithOwner": repo, "branchName": branch },
            "message": { "headline": headline },
            "expectedHeadOid": oid,
            "fileChanges": { "additions": [{ "path": path, "contents": contents }] },
        }}),
    )
    .map(|_| ())
}

/// A branch that only takes pull requests: commit on a branch of its own,
/// open one, and merge it at once; if it won't merge, leave it open.
#[allow(clippy::too_many_arguments)]
fn via_pull_request(token: &str, repo: &str, repo_id: &str, base: &str, oid: &str, headline: &str, path: &str, contents: &str) -> Result<Option<String>, String> {
    let slug: String = crate::launch::slug(headline, 32);
    let hex: String = uuid::Uuid::new_v4().simple().to_string()[..8].to_string();
    let branch = format!("gannin-{slug}-{hex}");
    let made = gql(
        token,
        "mutation($repo: ID!, $name: String!, $oid: GitObjectID!) { createRef(input: { repositoryId: $repo, name: $name, oid: $oid }) { ref { id } } }",
        json!({ "repo": repo_id, "name": format!("refs/heads/{branch}"), "oid": oid }),
    )?;
    let ref_id = made["createRef"]["ref"]["id"].as_str().unwrap_or_default().to_string();
    commit(token, repo, &branch, oid, headline, path, contents)?;
    let opened = gql(
        token,
        "mutation($repo: ID!, $base: String!, $head: String!, $title: String!) { createPullRequest(input: { repositoryId: $repo, baseRefName: $base, headRefName: $head, title: $title }) { pullRequest { id url } } }",
        json!({ "repo": repo_id, "base": base, "head": branch, "title": headline }),
    )?;
    let pr_id = opened["createPullRequest"]["pullRequest"]["id"].as_str().unwrap_or_default().to_string();
    let url = opened["createPullRequest"]["pullRequest"]["url"].as_str().unwrap_or_default().to_string();
    match gql(token, "mutation($id: ID!) { mergePullRequest(input: { pullRequestId: $id }) { pullRequest { merged } } }", json!({ "id": pr_id })) {
        Ok(_) => {
            let _ = gql(token, "mutation($id: ID!) { deleteRef(input: { refId: $id }) { clientMutationId } }", json!({ "id": ref_id }));
            Ok(None)
        }
        Err(error) => Ok(Some(format!("The review's record is in a pull request on the harness that couldn't merge ({error}): {url}"))),
    }
}
