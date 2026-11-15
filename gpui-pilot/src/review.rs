//! Review with Claude, as Gannin's `PullRequestReview`: the result claude
//! ends its reply with (read from its transcript), and posting it to GitHub
//! once the person has gone through it and confirmed.
//!
//! Posting keeps Gannin's rules: only Comment on your own PR; comments go
//! inline only on lines the diff shows, everything else in the body as
//! "- `path:line`: comment"; the PR's comments and reviews are fetched again
//! just before posting, and findings they already make are left out; an
//! identical review isn't posted twice.

use serde_json::{json, Value};
use std::collections::HashSet;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

#[derive(Clone, Debug, PartialEq)]
pub struct Finding {
    pub path: String,
    pub line: Option<i64>,
    pub comment: String,
    pub severity: Option<String>,
    pub category: Option<String>,
    pub suggestion: Option<String>,
}

impl Finding {
    /// Gannin's key for a finding: path, line and the comment's start.
    pub fn key(&self) -> String {
        format!("{}:{}:{}", self.path, self.line.unwrap_or(0), self.comment.chars().take(60).collect::<String>())
    }

    /// blocker 0, major 1, minor 2 (and unknown), nit 3.
    pub fn rank(&self) -> u8 {
        match self.severity.as_deref() {
            Some("blocker") => 0,
            Some("major") => 1,
            Some("nit") => 3,
            _ => 2,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ReviewResult {
    pub headline: Option<String>,
    pub summary: String,
    pub verdict: Option<String>,
    pub effort: Option<i64>,
    /// low, medium or high: what the change could break if it's wrong.
    pub risk: Option<String>,
    pub findings: Vec<Finding>,
    /// The change in areas, in the order to read them.
    pub walkthrough: Vec<Area>,
    /// What happens when the changed code runs, step by step.
    pub flow: Vec<String>,
    /// Review threads claude says are now dealt with.
    pub resolved: Vec<String>,
    /// The team's learnings that shaped this review.
    pub applied: Vec<Applied>,
    /// Explanations people gave in the PR that later reviews should know.
    pub learnings: Vec<Suggested>,
    /// When claude gave it, from the transcript.
    pub at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Area {
    pub title: String,
    pub summary: Option<String>,
    pub files: Vec<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Applied {
    pub learning: String,
    pub path: Option<String>,
    pub line: Option<i64>,
    pub note: String,
    pub concern: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Suggested {
    pub path: String,
    pub line: Option<i64>,
    pub end_line: Option<i64>,
    pub rule: String,
    pub reason: Option<String>,
    pub source: Option<String>,
    pub author: Option<String>,
}

impl ReviewResult {
    /// The area a file is in, by its index, else None.
    pub fn area_of(&self, path: &str) -> Option<usize> {
        self.walkthrough.iter().position(|a| a.files.iter().any(|f| f == path))
    }
}

/// Claude's transcript for a session, wherever its project folder is.
pub(crate) fn transcript_path(claude_id: &str) -> Option<PathBuf> {
    transcript(claude_id)
}

fn transcript(claude_id: &str) -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let projects = home.join(".claude/projects");
    std::fs::read_dir(projects).ok()?.flatten().map(|e| e.path().join(format!("{claude_id}.jsonl"))).find(|p| p.exists())
}

/// The review in claude's last reply: its last ```json block, read
/// leniently so one bad finding never loses the rest.
pub fn read_result(claude_id: &str) -> Option<ReviewResult> {
    let text = std::fs::read_to_string(transcript(claude_id)?).ok()?;
    let (last_reply, at) = text.lines().rev().filter_map(|line| serde_json::from_str::<Value>(line).ok()).find_map(|entry| {
        if entry["type"] != "assistant" || entry["isSidechain"] == true {
            return None;
        }
        let blocks = entry["message"]["content"].as_array()?;
        let text: Vec<&str> = blocks.iter().filter(|b| b["type"] == "text").filter_map(|b| b["text"].as_str()).collect();
        let text = text.join("\n");
        (!text.trim().is_empty()).then(|| (text, entry["timestamp"].as_str().and_then(|t| t.parse().ok())))
    })?;
    parse(&last_reply).map(|r| ReviewResult { at, ..r })
}

/// What claude is doing, from the end of its transcript: the tool it last
/// used and on what, or "Writing the review" once it's replying.
pub fn activity(claude_id: &str) -> Option<String> {
    let text = std::fs::read_to_string(transcript(claude_id)?).ok()?;
    let entry = text.lines().rev().filter_map(|line| serde_json::from_str::<Value>(line).ok()).find(|e| e["type"] == "assistant" && e["isSidechain"] != true)?;
    let block = entry["message"]["content"].as_array()?.last()?.clone();
    if block["type"] == "text" {
        return Some("Writing the review".into());
    }
    if block["type"] != "tool_use" {
        return None;
    }
    let input = &block["input"];
    let what = ["description", "file_path", "pattern", "path", "command", "url", "query"].iter().find_map(|k| input[*k].as_str()).unwrap_or("");
    let what: String = what.lines().next().unwrap_or("").chars().take(90).collect();
    let name = block["name"].as_str().unwrap_or("Working");
    Some(if what.is_empty() { name.to_string() } else { format!("{name}: {what}") })
}

pub fn parse(reply: &str) -> Option<ReviewResult> {
    let start = reply.rfind("```json")? + "```json".len();
    let end = start + reply[start..].find("```")?;
    let value: Value = serde_json::from_str(reply[start..end].trim()).ok()?;
    let summary = value["summary"].as_str()?.to_string();
    let text = |v: &Value| v.as_str().map(str::to_string).filter(|s| !s.is_empty());
    let findings = value["findings"]
        .as_array()?
        .iter()
        .filter_map(|f| {
            Some(Finding {
                path: f["path"].as_str()?.to_string(),
                line: f["line"].as_i64(),
                comment: f["comment"].as_str()?.to_string(),
                severity: text(&f["severity"]),
                category: text(&f["category"]),
                suggestion: text(&f["suggestion"]),
            })
        })
        .collect();
    let walkthrough = value["walkthrough"]
        .as_array()
        .map(|areas| {
            areas
                .iter()
                .filter_map(|a| {
                    Some(Area {
                        title: a["title"].as_str()?.to_string(),
                        summary: text(&a["summary"]),
                        files: a["files"].as_array().map(|f| f.iter().filter_map(|p| p.as_str().map(str::to_string)).collect()).unwrap_or_default(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Some(ReviewResult {
        headline: text(&value["headline"]),
        summary,
        verdict: text(&value["verdict"]),
        effort: value["effort"].as_i64().map(|e| e.clamp(1, 5)),
        risk: value["risk"].as_str().map(str::to_lowercase).filter(|r| matches!(r.as_str(), "low" | "medium" | "high")),
        findings,
        walkthrough,
        flow: value["flow"].as_array().map(|a| a.iter().filter_map(text).collect()).unwrap_or_default(),
        resolved: value["resolved"].as_array().map(|a| a.iter().filter_map(text).collect()).unwrap_or_default(),
        applied: value["applied"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|l| {
                        Some(Applied {
                            learning: l["learning"].as_str()?.to_string(),
                            path: text(&l["path"]),
                            line: l["line"].as_i64(),
                            note: l["note"].as_str().unwrap_or_default().to_string(),
                            concern: text(&l["concern"]),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default(),
        at: None,
        learnings: value["learnings"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|l| {
                        Some(Suggested {
                            path: l["path"].as_str()?.to_string(),
                            line: l["line"].as_i64(),
                            end_line: l["end_line"].as_i64(),
                            rule: l["rule"].as_str()?.to_string(),
                            reason: text(&l["reason"]),
                            source: text(&l["source"]),
                            author: text(&l["author"]),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default(),
    })
}

// MARK: - GitHub's REST API

fn rest(token: &str, method: &str, path: &str, body: Option<&Value>) -> Result<Value, String> {
    let mut config = format!(
        "header = \"Authorization: Bearer {token}\"\nheader = \"Accept: application/vnd.github+json\"\nheader = \"X-GitHub-Api-Version: 2022-11-28\"\nheader = \"User-Agent: gannin-gpui-pilot\"\n"
    );
    if let Some(body) = body {
        config.push_str("header = \"Content-Type: application/json\"\n");
        config.push_str(&format!("data = \"{}\"\n", body.to_string().replace('\\', "\\\\").replace('"', "\\\"")));
    }
    let mut child = Command::new("/usr/bin/curl")
        .args(["-sS", "--max-time", "60", "-X", method, "-w", "\n%{http_code}", "-K", "-"])
        .arg(format!("https://api.github.com/{path}"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    if let Some(mut pipe) = child.stdin.take() {
        pipe.write_all(config.as_bytes()).map_err(|e| e.to_string())?;
    }
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&output.stdout).into_owned();
    let (body, code) = text.rsplit_once('\n').unwrap_or((&text, "0"));
    let status: u16 = code.trim().parse().unwrap_or(0);
    let value: Value = serde_json::from_str(body).unwrap_or(Value::Null);
    if (200..300).contains(&status) {
        Ok(value)
    } else {
        Err(value["message"].as_str().map(str::to_string).unwrap_or_else(|| format!("GitHub answered {status}")))
    }
}

/// Every page of a list endpoint, up to 30.
fn rest_pages(token: &str, path: &str) -> Result<Vec<Value>, String> {
    let mut all = Vec::new();
    for page in 1..=30 {
        let separator = if path.contains('?') { '&' } else { '?' };
        let items = rest(token, "GET", &format!("{path}{separator}per_page=100&page={page}"), None)?;
        let items = items.as_array().cloned().unwrap_or_default();
        let done = items.len() < 100;
        all.extend(items);
        if done {
            break;
        }
    }
    Ok(all)
}

/// A comment already on the PR, for the duplicate check.
#[derive(Clone, Debug)]
struct Existing {
    path: String,
    line: Option<i64>,
    is_old: bool,
    outdated: bool,
    mine: bool,
    body: String,
}

/// What posting needs from GitHub: the head commit, who wrote the PR, which
/// lines each file's diff shows, and what's already been said.
pub struct Snapshot {
    pub head_sha: String,
    pub author: String,
    pub author_is_bot: bool,
    pub viewer: String,
    /// Lines added and removed, and files changed, when GitHub gave them.
    pub additions: Option<i64>,
    pub deletions: Option<i64>,
    pub changed_files: Option<i64>,
    /// path -> new-side line numbers the diff shows.
    lines: std::collections::HashMap<String, HashSet<i64>>,
    comments: Vec<Existing>,
    /// Earlier reviews' bodies.
    reviews: Vec<(String, String, String, String)>,
}

impl Snapshot {
    /// A made-up PR for the Review Preview: no GitHub call. `lines` are the
    /// new-side lines each file's diff shows.
    pub fn sample(own: bool, lines: &[(&str, std::ops::RangeInclusive<i64>)]) -> Self {
        Self {
            head_sha: "0000000".into(),
            author: if own { "you".into() } else { "someone".into() },
            author_is_bot: false,
            viewer: "you".into(),
            additions: Some(40),
            deletions: Some(12),
            changed_files: Some(lines.len() as i64),
            lines: lines.iter().map(|(path, range)| (path.to_string(), range.clone().collect())).collect(),
            comments: Vec::new(),
            reviews: Vec::new(),
        }
    }

    pub fn is_own(&self) -> bool {
        self.author.eq_ignore_ascii_case(&self.viewer)
    }
}

/// The new-side line numbers a unified diff shows.
fn shown_lines(patch: &str) -> HashSet<i64> {
    let mut lines = HashSet::new();
    let mut new = 0i64;
    for line in patch.lines() {
        if let Some(rest) = line.strip_prefix("@@") {
            new = rest.split_whitespace().find_map(|r| r.strip_prefix('+')).and_then(|r| r.split(',').next()).and_then(|n| n.parse().ok()).unwrap_or(0);
            continue;
        }
        match line.chars().next() {
            Some('-') => {}
            Some('\\') => {}
            _ => {
                lines.insert(new);
                new += 1;
            }
        }
    }
    lines
}

pub fn snapshot(token: &str, repo: &str, number: i64) -> Result<Snapshot, String> {
    let pr = rest(token, "GET", &format!("repos/{repo}/pulls/{number}"), None)?;
    let viewer = rest(token, "GET", "user", None)?["login"].as_str().unwrap_or_default().to_string();
    let files = rest_pages(token, &format!("repos/{repo}/pulls/{number}/files"))?;
    let lines = files
        .iter()
        .filter_map(|f| Some((f["filename"].as_str()?.to_string(), shown_lines(f["patch"].as_str().unwrap_or("")))))
        .collect();
    let comments = rest_pages(token, &format!("repos/{repo}/pulls/{number}/comments"))?
        .iter()
        .filter_map(|c| {
            Some(Existing {
                path: c["path"].as_str()?.to_string(),
                line: c["line"].as_i64().or(c["original_line"].as_i64()),
                is_old: c["side"].as_str().or(c["original_side"].as_str()) == Some("LEFT"),
                outdated: c["line"].is_null(),
                mine: c["user"]["login"].as_str().is_some_and(|l| l.eq_ignore_ascii_case(&viewer)),
                body: c["body"].as_str().unwrap_or_default().to_string(),
            })
        })
        .collect();
    let reviews = rest_pages(token, &format!("repos/{repo}/pulls/{number}/reviews"))?
        .iter()
        .filter(|r| !r["submitted_at"].is_null())
        .map(|r| {
            (
                r["user"]["login"].as_str().unwrap_or_default().to_string(),
                r["state"].as_str().unwrap_or_default().to_string(),
                r["commit_id"].as_str().unwrap_or_default().to_string(),
                r["body"].as_str().unwrap_or_default().to_string(),
            )
        })
        .collect();
    Ok(Snapshot {
        head_sha: pr["head"]["sha"].as_str().unwrap_or_default().to_string(),
        author: pr["user"]["login"].as_str().unwrap_or_default().to_string(),
        author_is_bot: pr["user"]["type"] == "Bot",
        viewer,
        additions: pr["additions"].as_i64(),
        deletions: pr["deletions"].as_i64(),
        changed_files: pr["changed_files"].as_i64(),
        lines,
        comments,
        reviews,
    })
}

/// Lower-case words, with suggestion blocks taken out.
fn words(text: &str) -> Vec<String> {
    let mut kept = String::new();
    let mut in_suggestion = false;
    for line in text.lines() {
        if line.trim_start().starts_with("```suggestion") {
            in_suggestion = true;
            continue;
        }
        if in_suggestion && line.trim_start().starts_with("```") {
            in_suggestion = false;
            continue;
        }
        if !in_suggestion {
            kept.push_str(line);
            kept.push(' ');
        }
    }
    kept.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(str::to_string).collect()
}

/// Gannin's "much the same": the finding's words inside the comment, or
/// four or more words each with 80% overlap.
fn similar(finding: &str, comment: &str) -> bool {
    let (a, b) = (words(finding), words(comment));
    let joined = a.join(" ");
    if joined.len() >= 20 && b.join(" ").contains(&joined) {
        return true;
    }
    if a.len() < 4 || b.len() < 4 {
        return false;
    }
    let (sa, sb): (HashSet<&String>, HashSet<&String>) = (a.iter().collect(), b.iter().collect());
    let shared = sa.intersection(&sb).count() as f64;
    let all = sa.union(&sb).count() as f64;
    all > 0.0 && shared / all >= 0.8
}

impl Snapshot {
    /// Whether a comment near the line, or an earlier review's body, already
    /// says it.
    fn said(&self, finding: &Finding, summary: &str) -> bool {
        let near = self.comments.iter().any(|c| {
            c.path == finding.path
                && !c.is_old
                && (!c.outdated || c.mine)
                && finding.line.is_none_or(|l| c.line.is_some_and(|cl| (cl - l).abs() <= 3))
                && similar(&finding.comment, &c.body)
        });
        let in_body = self.reviews.iter().filter(|(_, _, _, body)| !body.starts_with(summary.trim())).any(|(_, _, _, body)| {
            body.lines().any(|line| {
                let Some(rest) = line.strip_prefix("- `") else { return false };
                let Some((location, text)) = rest.split_once("`: ") else { return false };
                location.split(':').next() == Some(finding.path.as_str()) && similar(&finding.comment, text)
            })
        });
        near || in_body
    }
}

/// The review as it'd be posted: inline comments, the body, and findings
/// left out because they're already said.
pub struct Draft {
    pub body: String,
    pub comments: Vec<(String, i64, String)>,
    pub left_out: Vec<Finding>,
}

pub fn draft(result: &ReviewResult, dismissed: &HashSet<String>, snapshot: &Snapshot) -> Draft {
    let mut general = Vec::new();
    let mut comments = Vec::new();
    let mut left_out = Vec::new();
    for finding in result.findings.iter().filter(|f| !dismissed.contains(&f.key())) {
        if snapshot.said(finding, &result.summary) {
            left_out.push(finding.clone());
            continue;
        }
        let shown = finding.line.is_some_and(|l| snapshot.lines.get(&finding.path).is_some_and(|lines| lines.contains(&l)));
        match (shown, finding.line) {
            (true, Some(line)) => {
                let mut body = finding.comment.clone();
                if let Some(suggestion) = &finding.suggestion {
                    body.push_str(&format!("\n\n```suggestion\n{suggestion}\n```"));
                }
                comments.push((finding.path.clone(), line, body));
            }
            _ => general.push(match finding.line {
                Some(line) => format!("- `{}:{line}`: {}", finding.path, finding.comment),
                None => format!("- `{}`: {}", finding.path, finding.comment),
            }),
        }
    }
    let mut body = result.summary.trim().to_string();
    if !general.is_empty() {
        body.push_str("\n\n");
        body.push_str(&general.join("\n"));
    }
    Draft { body, comments, left_out }
}

/// The event the verdict suggests; Comment on your own PR.
pub fn default_event(result: &ReviewResult, own: bool) -> &'static str {
    if own {
        return "COMMENT";
    }
    match result.verdict.as_deref() {
        Some("approve") => "APPROVE",
        Some("request_changes") => "REQUEST_CHANGES",
        _ => "COMMENT",
    }
}

/// Posts the review. Called only from the confirmation the person clicks;
/// it refuses anything but Comment on their own PR, and a review they've
/// already posted.
pub fn post(token: &str, repo: &str, number: i64, event: &str, draft: &Draft, snapshot: &Snapshot) -> Result<String, String> {
    if snapshot.is_own() && event != "COMMENT" {
        return Err("It's your own pull request, so GitHub only takes a comment.".into());
    }
    let repeated = snapshot.reviews.iter().any(|(login, state, commit, body)| {
        login.eq_ignore_ascii_case(&snapshot.viewer)
            && commit == &snapshot.head_sha
            && body.trim() == draft.body.trim()
            && matches!((state.as_str(), event), ("APPROVED", "APPROVE") | ("CHANGES_REQUESTED", "REQUEST_CHANGES") | ("COMMENTED", "COMMENT"))
    });
    if repeated {
        return Err("You've already posted this review to GitHub, so it wasn't sent again.".into());
    }
    let comments: Vec<Value> = draft.comments.iter().map(|(path, line, body)| json!({ "path": path, "line": line, "side": "RIGHT", "body": body })).collect();
    let payload = json!({ "commit_id": snapshot.head_sha, "event": event, "body": draft.body, "comments": comments });
    let posted = rest(token, "POST", &format!("repos/{repo}/pulls/{number}/reviews"), Some(&payload)).map_err(|e| format!("GitHub didn't take it: {e}"))?;
    Ok(posted["html_url"].as_str().unwrap_or_default().to_string())
}

// MARK: - Changes since the review

/// What's happened on the PR since the review, as Check for Changes finds.
#[derive(Clone, Debug, PartialEq)]
pub struct Changes {
    /// OPEN, MERGED or CLOSED.
    pub state: String,
    pub new_commits: usize,
    /// Comments and reviews by others since the review.
    pub new_comments: usize,
    /// The viewer's own latest review since the review: its state, when and where.
    pub mine: Option<(String, chrono::DateTime<chrono::Utc>, String)>,
}

impl Changes {
    pub fn summary(&self) -> String {
        match self.state.as_str() {
            "MERGED" => return "Merged".into(),
            "CLOSED" => return "Closed".into(),
            _ => {}
        }
        let mut parts = Vec::new();
        if self.new_commits > 0 {
            parts.push(format!("{} new commit{}", self.new_commits, if self.new_commits == 1 { "" } else { "s" }));
        }
        if self.new_comments > 0 {
            parts.push(format!("{} new comment{}", self.new_comments, if self.new_comments == 1 { "" } else { "s" }));
        }
        if parts.is_empty() { "No changes".into() } else { parts.join(", ") }
    }
}

/// Reads the PR's state, commits, comments and reviews, and counts what's
/// newer than `since` (the review). Read only.
pub fn check(token: &str, repo: &str, number: i64, since: Option<chrono::DateTime<chrono::Utc>>) -> Result<Changes, String> {
    let (owner, name) = repo.split_once('/').ok_or("Not a repository")?;
    let query = "query($owner: String!, $name: String!, $number: Int!) { viewer { login } repository(owner: $owner, name: $name) { pullRequest(number: $number) { state commits(last: 100) { nodes { commit { committedDate } } } comments(last: 100) { nodes { createdAt author { login } } } reviews(last: 50) { nodes { state submittedAt url author { login } } } } } }";
    let data = crate::github::graphql(token, query, json!({ "owner": owner, "name": name, "number": number })).map_err(|e| e.to_string())?;
    let viewer = data["viewer"]["login"].as_str().unwrap_or("");
    let pr = &data["repository"]["pullRequest"];
    let after = |v: &Value| v.as_str().and_then(|t| t.parse::<chrono::DateTime<chrono::Utc>>().ok()).is_some_and(|t| since.is_none_or(|s| t > s));
    let nodes = |v: &Value| v["nodes"].as_array().cloned().unwrap_or_default();
    let new_commits = nodes(&pr["commits"]).iter().filter(|c| after(&c["commit"]["committedDate"])).count();
    let others = |n: &Value| n["author"]["login"].as_str().is_some_and(|l| l != viewer);
    let reviews = nodes(&pr["reviews"]);
    let new_comments = nodes(&pr["comments"]).iter().filter(|c| others(c) && after(&c["createdAt"])).count()
        + reviews.iter().filter(|r| others(r) && after(&r["submittedAt"])).count();
    let mine = reviews
        .iter()
        .filter(|r| r["author"]["login"].as_str() == Some(viewer) && after(&r["submittedAt"]))
        .filter_map(|r| Some((r["state"].as_str()?.to_string(), r["submittedAt"].as_str()?.parse().ok()?, r["url"].as_str().unwrap_or_default().to_string())))
        .max_by_key(|r| r.1);
    Ok(Changes { state: pr["state"].as_str().unwrap_or("OPEN").to_string(), new_commits, new_comments, mine })
}
