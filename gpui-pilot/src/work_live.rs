//! What a live Work on This session shows, read where Gannin reads it:
//!
//! - The worktrees claude made in the session's folder (`.worktrees/
//!   <branch>/<repo>`), with what's changed in each since it left the
//!   default branch, what isn't committed, and what isn't pushed (git).
//! - What claude's doing, its model and how full its context is, from its
//!   transcript.
//! - What it's asking, from the tool it last asked to use (a hook saves it
//!   as `tool.json`) and the choices on its screen.
//! - The pull requests it opened (the PR hook saves their links), with
//!   their state, review, checks and the feedback on them, from GitHub.
//!
//! All of it is read only, and blocking: call it off the main thread.

use crate::work_panel::{Ask, ChangedFile, Feedback, PrState, Question, WorkPr, Worktree};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::Command;

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    // A session on a server: its worktrees are there.
    if let Some(server) = crate::servers::server_for(dir) {
        return crate::servers::git(&server, dir, args).ok().map(|o| String::from_utf8_lossy(&o).to_string());
    }
    let out = Command::new("git").arg("-C").arg(dir).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).to_string())
}

/// The worktrees in the session's folder: each folder in it that git
/// knows as a checkout.
pub fn worktrees(folder: &Path) -> Vec<Worktree> {
    if let Some(server) = crate::servers::server_for(folder) {
        let mut names = crate::servers::checkouts(&server, folder);
        names.sort();
        return names.iter().filter_map(|name| worktree(&folder.join(name))).collect();
    }
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(folder)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir() && p.join(".git").exists())
        .collect();
    dirs.sort();
    dirs.iter().filter_map(|dir| worktree(dir)).collect()
}

fn worktree(dir: &Path) -> Option<Worktree> {
    let name = dir.file_name()?.to_string_lossy().to_string();
    let base = git(dir, &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]).map(|s| s.trim().to_string()).unwrap_or_else(|| "origin/main".into());
    let merge_base = git(dir, &["merge-base", "HEAD", &base]).map(|s| s.trim().to_string());
    let unpushed = git(dir, &["rev-list", "--count", "@{u}..HEAD"]).and_then(|s| s.trim().parse::<usize>().ok());
    // Branch: everything since it left the default branch, committed or not.
    let files = match &merge_base {
        Some(mb) => numstat(dir, &["diff", "--numstat", "-M", mb], &["diff", "--name-status", "-M", mb]),
        None => Vec::new(),
    };
    // Uncommitted: what's staged and what isn't, and new files.
    let mut uncommitted = numstat(dir, &["diff", "--numstat", "--cached"], &["diff", "--name-status", "--cached"]);
    for f in &mut uncommitted {
        f.staged = true;
    }
    for f in numstat(dir, &["diff", "--numstat"], &["diff", "--name-status"]) {
        if !uncommitted.iter().any(|u| u.path == f.path) {
            uncommitted.push(f);
        }
    }
    if let Some(untracked) = git(dir, &["ls-files", "--others", "--exclude-standard"]) {
        for path in untracked.lines().filter(|l| !l.is_empty()) {
            if !uncommitted.iter().any(|u| u.path == path) {
                let lines = std::fs::read_to_string(dir.join(path)).map(|t| t.lines().count() as i64).unwrap_or(0);
                uncommitted.push(ChangedFile { status: 'A', path: path.into(), additions: lines, deletions: 0, staged: false, diff: Vec::new() });
            }
        }
    }
    Some(Worktree {
        name,
        path: dir.to_string_lossy().to_string(),
        unpushed,
        base: base.trim_start_matches("origin/").to_string(),
        files,
        uncommitted,
    })
}

fn numstat(dir: &Path, counts: &[&str], statuses: &[&str]) -> Vec<ChangedFile> {
    let status_of: Vec<(char, String)> = git(dir, statuses)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let mut parts = l.split('\t');
            let status = parts.next()?.chars().next()?;
            let path = parts.last()?.to_string();
            Some((if status == 'R' { 'M' } else { status }, path))
        })
        .collect();
    git(dir, counts)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let mut parts = l.split('\t');
            let add = parts.next()?.parse().unwrap_or(0);
            let del = parts.next()?.parse().unwrap_or(0);
            let raw = parts.next()?;
            // A rename reads "old => new" or "dir/{old => new}".
            let path = raw.rsplit(" => ").next().unwrap_or(raw).replace(['{', '}'], "");
            let status = status_of.iter().find(|(_, p)| *p == path).map(|(s, _)| *s).unwrap_or('M');
            Some(ChangedFile { status, path, additions: add, deletions: del, staged: false, diff: Vec::new() })
        })
        .collect()
}

/// One file's diff, as lines: since the default branch, or uncommitted.
pub fn diff(worktree: &Path, path: &str, uncommitted: bool) -> Vec<String> {
    let text = if uncommitted {
        let staged = git(worktree, &["diff", "--cached", "--", path]).unwrap_or_default();
        let unstaged = git(worktree, &["diff", "--", path]).unwrap_or_default();
        let both = format!("{staged}{unstaged}");
        if both.trim().is_empty() {
            // New and untracked: the whole file as added.
            std::fs::read_to_string(worktree.join(path)).map(|t| t.lines().map(|l| format!("+{l}")).collect::<Vec<_>>().join("\n")).unwrap_or_default()
        } else {
            both
        }
    } else {
        let base = git(worktree, &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]).map(|s| s.trim().to_string()).unwrap_or_else(|| "origin/main".into());
        let mb = git(worktree, &["merge-base", "HEAD", &base]).map(|s| s.trim().to_string()).unwrap_or(base);
        git(worktree, &["diff", "-M", &mb, "--", path]).unwrap_or_default()
    };
    // From the first hunk, past git's header lines; a new file read whole
    // has no hunks, so all of it.
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.iter().position(|l| l.starts_with("@@")).unwrap_or(0);
    lines[start..].iter().take(2000).map(|l| l.to_string()).collect()
}

/// From the transcript: what claude's done (time and tool), its model, and
/// how full its context is.
pub struct Transcript {
    pub activity: Vec<(String, String)>,
    pub model: String,
    pub context: f32,
}

pub fn transcript(claude_id: &str) -> Transcript {
    let mut out = Transcript { activity: Vec::new(), model: String::new(), context: 0. };
    let Some(path) = crate::review::transcript_path(claude_id) else { return out };
    let Ok(text) = std::fs::read_to_string(path) else { return out };
    for entry in text.lines().filter_map(|l| serde_json::from_str::<Value>(l).ok()) {
        if entry["type"] != "assistant" || entry["isSidechain"] == true {
            continue;
        }
        let message = &entry["message"];
        if let Some(model) = message["model"].as_str() {
            out.model = model.to_string();
        }
        let usage = &message["usage"];
        let used = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].iter().filter_map(|k| usage[*k].as_i64()).sum::<i64>();
        if used > 0 {
            let limit = if out.model.contains("[1m]") { 1_000_000. } else { 200_000. };
            out.context = (used as f32 / limit).min(1.);
        }
        let at = entry["timestamp"].as_str().and_then(|t| t.parse::<chrono::DateTime<chrono::Utc>>().ok()).map(|t| t.with_timezone(&chrono::Local).format("%H:%M").to_string()).unwrap_or_default();
        for block in message["content"].as_array().into_iter().flatten().filter(|b| b["type"] == "tool_use") {
            let input = &block["input"];
            let what = ["description", "file_path", "pattern", "command", "url", "query"].iter().find_map(|k| input[*k].as_str()).unwrap_or("");
            let what: String = what.lines().next().unwrap_or("").chars().take(100).collect();
            let name = block["name"].as_str().unwrap_or("Tool");
            out.activity.push((at.clone(), if what.is_empty() { name.to_string() } else { format!("{name}: {what}") }));
        }
    }
    let keep = out.activity.len().saturating_sub(200);
    out.activity.drain(..keep);
    out
}

/// What claude's asking: the tool it last asked to use (saved by the
/// PreToolUse hook) and the numbered choices on its screen.
pub fn ask(session_dir: &Path, screen: &str) -> Ask {
    let tool: Value = std::fs::read(session_dir.join("tool.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(Value::Null);
    let name = tool["tool_name"].as_str().unwrap_or("").to_string();
    let input = &tool["tool_input"];
    if name == "AskUserQuestion" {
        let questions = questions_in(input);
        if !questions.is_empty() {
            return Ask::Questions(questions);
        }
    }
    let text = ["command", "file_path", "url", "query", "plan"].iter().find_map(|k| input[*k].as_str()).map(str::to_string).unwrap_or_else(|| "Look at the terminal for what it wants to do.".into());
    Ask::Permission { tool: name, text, choices: screen_choices(screen) }
}

/// An AskUserQuestion's questions, from its input.
pub fn questions_in(input: &Value) -> Vec<Question> {
    input["questions"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|q| Question {
                header: q["header"].as_str().unwrap_or("").to_string(),
                question: q["question"].as_str().unwrap_or("").to_string(),
                multi: q["multiSelect"].as_bool().unwrap_or(false),
                options: q["options"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|o| {
                        let label = o["label"].as_str().unwrap_or("").to_string();
                        let recommended = label.contains("(Recommended)");
                        (label.replace(" (Recommended)", ""), o["description"].as_str().unwrap_or("").to_string(), recommended)
                    })
                    .collect(),
            })
            .collect()
}

/// The numbered choices at the end of the screen, as "1. Yes" and so on,
/// with the digit that picks each.
pub fn screen_choices(screen: &str) -> Vec<String> {
    let tail: Vec<&str> = screen.lines().rev().filter(|l| !l.trim().is_empty()).take(20).collect();
    let mut choices: Vec<String> = tail
        .iter()
        .rev()
        .filter_map(|l| {
            let t = l.trim().trim_start_matches('❯').trim();
            let (n, rest) = t.split_once(". ")?;
            (n.len() == 1 && n.chars().all(|c| c.is_ascii_digit())).then(|| format!("{n}. {}", rest.trim()))
        })
        .collect();
    choices.dedup();
    choices
}

/// The PRs from their links, read from GitHub: state, review, conflicts,
/// checks, and the feedback others left (reviews with words, and the first
/// comment of each unresolved thread).
pub fn pull_requests(token: &str, urls: &[String], viewer: &str) -> Vec<WorkPr> {
    let query = "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { title body baseRefName headRefName state isDraft reviewDecision mergeable commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 60) { nodes { __typename ... on CheckRun { name status conclusion } ... on StatusContext { context state } } } } } } } reviews(last: 30) { nodes { author { login } state body } } reviewThreads(last: 50) { nodes { isResolved path line comments(first: 1) { nodes { author { login } body } } } } } } }";
    let mut out = Vec::new();
    for url in urls {
        let Some((repo, number)) = parse_pr(url) else { continue };
        let Some((owner, name)) = repo.split_once('/') else { continue };
        let Ok(data) = crate::github::graphql(token, query, json!({ "owner": owner, "name": name, "number": number })) else { continue };
        let pr = &data["repository"]["pullRequest"];
        let mut failed = Vec::new();
        let mut pending = Vec::new();
        let mut passed = 0;
        for c in pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["nodes"].as_array().into_iter().flatten() {
            let name = c["name"].as_str().or(c["context"].as_str()).unwrap_or("check").to_string();
            let outcome = c["conclusion"].as_str().or(c["state"].as_str()).unwrap_or("");
            match outcome {
                "SUCCESS" | "NEUTRAL" | "SKIPPED" => passed += 1,
                "FAILURE" | "ERROR" | "TIMED_OUT" | "CANCELLED" | "ACTION_REQUIRED" | "STARTUP_FAILURE" => failed.push(name),
                _ => pending.push(name),
            }
        }
        let others = |n: &Value| n["author"]["login"].as_str().is_some_and(|l| !l.eq_ignore_ascii_case(viewer));
        let mut feedback: Vec<Feedback> = pr["reviews"]["nodes"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|r| others(r) && r["body"].as_str().is_some_and(|b| !b.trim().is_empty()))
            .map(|r| Feedback {
                author: r["author"]["login"].as_str().unwrap_or("").into(),
                location: None,
                verdict: (r["state"] == "CHANGES_REQUESTED").then(|| "Changes requested".into()),
                body: r["body"].as_str().unwrap_or("").trim().into(),
                sent: false,
            })
            .collect();
        for t in pr["reviewThreads"]["nodes"].as_array().into_iter().flatten().filter(|t| t["isResolved"] == false) {
            let first = &t["comments"]["nodes"][0];
            if !others(first) {
                continue;
            }
            feedback.push(Feedback {
                author: first["author"]["login"].as_str().unwrap_or("").into(),
                location: t["path"].as_str().map(|p| match t["line"].as_i64() {
                    Some(l) => format!("{p}:{l}"),
                    None => p.to_string(),
                }),
                verdict: None,
                body: first["body"].as_str().unwrap_or("").trim().into(),
                sent: false,
            });
        }
        out.push(WorkPr {
            repo: repo.clone(),
            number,
            title: pr["title"].as_str().unwrap_or("").into(),
            state: match (pr["state"].as_str(), pr["isDraft"].as_bool()) {
                (Some("MERGED"), _) => PrState::Merged,
                (Some("CLOSED"), _) => PrState::Closed,
                (_, Some(true)) => PrState::Draft,
                _ => PrState::Open,
            },
            review: pr["reviewDecision"].as_str().map(str::to_string),
            conflicts: pr["mergeable"] == "CONFLICTING",
            failed,
            pending,
            passed,
            failures_sent: false,
            feedback,
            needs: crate::pr_deps::needs(pr["body"].as_str().unwrap_or(""), &repo),
            base: pr["baseRefName"].as_str().unwrap_or("").into(),
            head: pr["headRefName"].as_str().unwrap_or("").into(),
        });
    }
    out
}

/// "owner/name" and the number from a PR's link.
pub fn parse_pr(url: &str) -> Option<(String, i64)> {
    let rest = url.trim().split("github.com/").nth(1)?;
    let mut parts = rest.split('/');
    let (owner, name, kind, number) = (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
    (kind == "pull").then_some(())?;
    Some((format!("{owner}/{name}"), number.trim_end_matches(|c: char| !c.is_ascii_digit()).parse().ok()?))
}
