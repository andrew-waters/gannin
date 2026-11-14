//! Running a Work on This session through its workflow (docs/workflows.md).
//!
//! - **Prepare**: each step runs once, headless (`claude -p`, read only),
//!   in the harness before the session's claude starts; the start script
//!   waits while `preparing` is in the session's folder. Their notes go
//!   into the brief.
//! - **Local review**: a PreToolUse hook holds `git push`, `gh pr create`
//!   and `gh pr ready` until the gate is clear for the commit being pushed
//!   (`gate/clear` lists cleared commits). A held push asks for a round
//!   (`gate/request`: the worktree and commit); the app runs the local
//!   steps on it (reviewers headless and read only, commands in the
//!   worktree), and sends what they found to the session. Clear when no
//!   blocker or major is open and every command passes, or once a
//!   reviewer's rounds run out (its findings still go to the session).
//! - Its progress is kept in `workflow-run.json`, for the panel's strip.
//!
//! All of it is blocking: call it off the main thread.

use crate::workflows::{Specialist, Step, When, Workflow};
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const READ_ONLY: &str = "Read,Grep,Glob,Bash(git diff:*),Bash(git diff *),Bash(git log:*),Bash(git log *),Bash(git show:*),Bash(git show *),Bash(git status:*),Bash(git status),Bash(git merge-base:*),Bash(git merge-base *),Bash(gh issue view:*),Bash(gh issue view *),Bash(gh pr view:*),Bash(gh pr view *),Bash(ls:*),Bash(ls *)";

/// One headless claude turn: its final reply, or why not.
pub(crate) fn ask_claude(dir: &Path, prompt: &str, model: Option<&str>, timeout: Duration) -> Result<String, String> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let mut args = vec!["-p".to_string(), "--output-format".into(), "json".into(), "--allowedTools".into(), READ_ONLY.into(), "--disallowedTools".into(), "Edit,MultiEdit,Write,NotebookEdit".into()];
    if let Some(model) = model.filter(|m| !m.is_empty() && *m != "Each person's") {
        args.push("--model".into());
        args.push(model.into());
    }
    let quoted: Vec<String> = args.iter().map(|a| format!("'{}'", a.replace('\'', "'\\''"))).collect();
    let mut command = Command::new(shell);
    command.args(["-l", "-c", &format!("claude {}", quoted.join(" "))]).current_dir(dir).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    for (key, _) in std::env::vars() {
        if key == "CLAUDECODE" || key.starts_with("CLAUDE_CODE_") {
            command.env_remove(key);
        }
    }
    let mut child = command.spawn().map_err(|e| format!("Couldn't start claude: {e}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        use std::io::Write;
        let _ = stdin.write_all(prompt.as_bytes());
    }
    let started = Instant::now();
    loop {
        if child.try_wait().map_err(|e| e.to_string())?.is_some() {
            break;
        }
        if started.elapsed() > timeout {
            let _ = child.kill();
            return Err("Took too long, so it was stopped.".into());
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    let mut out = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        let _ = stdout.read_to_string(&mut out);
    }
    let value: serde_json::Value = serde_json::from_str(out.trim()).map_err(|_| "Claude didn't answer.".to_string())?;
    if value["is_error"] == true {
        return Err(value["result"].as_str().unwrap_or("Claude failed.").to_string());
    }
    Ok(value["result"].as_str().unwrap_or("").trim().to_string())
}

fn specialist<'a>(step: &Step, specialists: &'a [Specialist]) -> Option<&'a Specialist> {
    step.specialist.as_deref().and_then(|n| specialists.iter().find(|s| s.name.eq_ignore_ascii_case(n)))
}

/// Who the step is, ahead of its task: the specialist's soul and the focus.
fn persona(step: &Step, specialists: &[Specialist]) -> String {
    let mut out = String::new();
    if let Some(s) = specialist(step, specialists) {
        out.push_str(&s.soul);
        out.push_str("\n\n");
    }
    if let Some(focus) = step.focus.as_deref().or(specialist(step, specialists).and_then(|s| s.focus.as_deref())).filter(|f| !f.is_empty()) {
        out.push_str(&format!("Focus on: {focus}\n\n"));
    }
    out
}

fn model(step: &Step, specialists: &[Specialist]) -> Option<String> {
    step.model.clone().or_else(|| specialist(step, specialists).and_then(|s| s.model.clone()))
}

// MARK: - Prepare

/// Runs the prepare steps on the brief, in the harness, and returns their
/// notes as a brief section (empty when there are none).
pub fn prepare(harness: &Path, brief: &str, workflow: &Workflow, specialists: &[Specialist]) -> String {
    let steps: Vec<Step> = workflow.steps_when(When::Prepare).into_iter().filter(|s| s.command.is_none()).cloned().collect();
    if steps.is_empty() {
        return String::new();
    }
    let handles: Vec<_> = steps
        .into_iter()
        .map(|step| {
            let (harness, brief, specialists) = (harness.to_path_buf(), brief.to_string(), specialists.to_vec());
            std::thread::spawn(move || {
                let prompt = format!(
                    "{}You're preparing the way for a Claude Code session that will work on the issue below, in this harness. Don't change anything. Read the issue and the code it touches (the code repos are under projects/), and write notes for the session: where the relevant code is, how it fits together, what to watch out for, and anything the issue leaves open. Plain Markdown, no preamble.\n\nThe session's brief:\n\n{brief}",
                    persona(&step, &specialists)
                );
                let label = step.label(&specialists);
                match ask_claude(&harness, &prompt, model(&step, &specialists).as_deref(), Duration::from_secs(15 * 60)) {
                    Ok(notes) => format!("### {label}\n\n{notes}"),
                    Err(error) => format!("### {label}\n\nIt couldn't prepare: {error}"),
                }
            })
        })
        .collect();
    let notes: Vec<String> = handles.into_iter().filter_map(|h| h.join().ok()).collect();
    format!("\n## Notes from the workflow's preparation\n\nWritten for you before the session started, by its prepare steps.\n\n{}\n", notes.join("\n\n"))
}

/// What the brief says about the local review, so the session works to it.
pub fn brief_section(workflow: &Workflow, specialists: &[Specialist]) -> String {
    let local = workflow.steps_when(When::Local);
    if local.is_empty() {
        return String::new();
    }
    let commands: Vec<String> = local.iter().filter_map(|s| s.command.clone()).map(|c| format!("- `{c}`")).collect();
    let reviewers: Vec<String> = local.iter().filter(|s| s.command.is_none()).map(|s| format!("- {}", s.label(specialists))).collect();
    let mut out = String::from("\n## Before you push\n\nGannin checks each commit on this Mac before it's pushed or a pull request is opened: `git push`, `gh pr create` and `gh pr ready` are held until it's clear. When one is held, wait: the check's findings come to you here. Fix blockers and majors (or say why not), commit, then push again. Minors and nits are suggestions.\n");
    if !commands.is_empty() {
        out.push_str(&format!("\nThese must pass, run in the worktree exactly as written; run them yourself as you work:\n\n{}\n", commands.join("\n")));
    }
    if !reviewers.is_empty() {
        out.push_str(&format!("\nThese review the change first:\n\n{}\n", reviewers.join("\n")));
    }
    out
}

// MARK: - The gate

/// The PreToolUse hook that holds a push until the local review is clear
/// for the commit (see the module's notes). Self-contained: sed and git.
pub fn gate_hook(session_dir: &Path) -> String {
    let gate = session_dir.join("gate");
    let gate = gate.to_string_lossy().replace('\'', "'\\''");
    format!(
        r#"input=$(cat); gate='{gate}'
printf %s "$input" | grep -Eq '"tool_name": ?"Bash"' || exit 0
printf %s "$input" | grep -Eq '"command": ?"[^"]*(git( -C [^ ]+)? push|gh pr create|gh pr ready)' || exit 0
cwd=$(printf %s "$input" | sed -n 's/.*"cwd": *"\([^"]*\)".*/\1/p')
dir=$(printf %s "$input" | sed -n 's/.*"command": *"[^"]*git -C \([^ "]*\) push.*/\1/p')
[ -z "$dir" ] && dir=$(printf %s "$input" | sed -n 's/.*"command": *"cd \([^"&;]*[^ "&;]\) *&&.*/\1/p')
if [ -n "$dir" ]; then case "$dir" in /*) cwd="$dir";; *) cwd="$cwd/$dir";; esac; fi
sha=$(git -C "$cwd" rev-parse HEAD 2>/dev/null)
mkdir -p "$gate"
[ -n "$sha" ] && grep -qx "$sha" "$gate/clear" 2>/dev/null && exit 0
printf '%s\n%s\n' "$cwd" "$sha" > "$gate/request.tmp" && mv "$gate/request.tmp" "$gate/request"
printf '{{"hookSpecificOutput":{{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Gannin checks each commit on this Mac before it is pushed or a pull request opened, and has started on %s. Its findings will be sent to you here: wait for them without pushing, deal with them, then push again."}}}}' "$(printf %s "$sha" | cut -c1-7)"
exit 0"#
    )
}

pub fn gate_dir(session_dir: &Path) -> PathBuf {
    session_dir.join("gate")
}

/// A round asked for: the worktree and the commit, if one's waiting.
pub fn pending_request(session_dir: &Path) -> Option<(PathBuf, String, std::time::SystemTime)> {
    let path = gate_dir(session_dir).join("request");
    let text = std::fs::read_to_string(&path).ok()?;
    let at = std::fs::metadata(&path).and_then(|m| m.modified()).ok()?;
    let mut lines = text.lines();
    Some((PathBuf::from(lines.next()?), lines.next().unwrap_or("").to_string(), at))
}

/// Lets a commit through the gate (a clear round, or Push Anyway).
pub fn clear(session_dir: &Path, sha: &str) {
    let dir = gate_dir(session_dir);
    let _ = std::fs::create_dir_all(&dir);
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("clear")) {
        let _ = writeln!(f, "{sha}");
    }
    let _ = std::fs::remove_file(dir.join("request"));
}

// MARK: - A local round

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Finding {
    pub severity: String,
    pub path: String,
    #[serde(default)]
    pub line: Option<i64>,
    pub comment: String,
    #[serde(default)]
    pub reviewer: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct StepResult {
    pub label: String,
    pub provider: String,
    /// done, failed, holding
    pub status: String,
    pub summary: String,
    pub findings: Vec<Finding>,
    /// Every finding of this reviewer's holds the push, not only blockers
    /// and majors.
    #[serde(default)]
    pub holds_all: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct LocalRun {
    pub round: u32,
    /// waiting, running, holding, clear
    pub status: String,
    pub sha: String,
    pub steps: Vec<StepResult>,
    /// Commits let through by Push Anyway.
    #[serde(default)]
    pub overridden: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Run {
    pub workflow: String,
    /// done, running, skipped
    pub prepare: String,
    pub local: LocalRun,
}

pub fn read_run(session_dir: &Path) -> Option<Run> {
    std::fs::read(session_dir.join("workflow-run.json")).ok().and_then(|b| serde_json::from_slice(&b).ok())
}

pub fn write_run(session_dir: &Path, run: &Run) {
    let _ = std::fs::write(session_dir.join("workflow-run.json"), serde_json::to_vec_pretty(run).unwrap_or_default());
}

pub fn read_workflow(session_dir: &Path) -> Option<Workflow> {
    std::fs::read(session_dir.join("workflow.json")).ok().and_then(|b| serde_json::from_slice(&b).ok())
}

/// The fenced JSON list a reviewer ends with; None when there's no list.
fn findings_in(reply: &str, reviewer: &str) -> Option<Vec<Finding>> {
    let start = reply.rfind("```json")? + "```json".len();
    let end = start + reply[start..].find("```")?;
    let list: Vec<serde_json::Value> = serde_json::from_str(reply[start..end].trim()).ok()?;
    Some(
        list.into_iter()
            .filter_map(|f| {
                Some(Finding {
                    severity: f["severity"].as_str().unwrap_or("minor").to_lowercase(),
                    path: f["path"].as_str().unwrap_or("").to_string(),
                    line: f["line"].as_i64(),
                    comment: f["comment"].as_str()?.to_string(),
                    reviewer: reviewer.to_string(),
                })
            })
            .collect(),
    )
}

fn run_command(dir: &Path, command: &str) -> (bool, String, Duration) {
    let started = Instant::now();
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let out = Command::new(shell).args(["-l", "-c", &format!("{command} 2>&1")]).current_dir(dir).output();
    let took = started.elapsed();
    match out {
        Ok(out) => {
            let text = String::from_utf8_lossy(&out.stdout);
            let lines: Vec<&str> = text.lines().collect();
            (out.status.success(), lines[lines.len().saturating_sub(25)..].join("\n"), took)
        }
        Err(e) => (false, e.to_string(), took),
    }
}

/// Runs the local steps on the worktree: reviewers (in parallel, told
/// what earlier rounds found) and commands. Their results, and whether the
/// gate is clear.
pub fn local_round(worktree: &Path, workflow: &Workflow, specialists: &[Specialist], round: u32, earlier: &[Finding]) -> (Vec<StepResult>, bool) {
    let steps: Vec<Step> = workflow.steps_when(When::Local).into_iter().cloned().collect();
    let base = Command::new("git").args(["-C"]).arg(worktree).args(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).filter(|s| !s.is_empty()).unwrap_or_else(|| "origin/main".into());
    let earlier_text = if earlier.is_empty() {
        String::new()
    } else {
        format!(
            "\n\nEarlier rounds found these; check whether each is now dealt with (fixed, or answered in the commits) and leave those out:\n{}",
            earlier.iter().map(|f| format!("- [{}] {}:{} {}", f.severity, f.path, f.line.unwrap_or(0), f.comment)).collect::<Vec<_>>().join("\n")
        )
    };
    let handles: Vec<_> = steps
        .into_iter()
        .map(|step| {
            let (worktree, specialists, base, earlier_text) = (worktree.to_path_buf(), specialists.to_vec(), base.clone(), earlier_text.clone());
            std::thread::spawn(move || {
                let label = step.label(&specialists);
                let holds_all = step.holds.as_deref() == Some("all");
                if let Some(command) = &step.command {
                    let (ok, tail, took) = run_command(&worktree, command);
                    return StepResult {
                        label,
                        provider: "Command".into(),
                        status: if ok { "done".into() } else { "failed".into() },
                        summary: if ok { format!("Passed in {}s.", took.as_secs()) } else { format!("Failed after {}s:\n{tail}", took.as_secs()) },
                        findings: Vec::new(),
                        holds_all: false,
                    };
                }
                // A step's provider, else its specialist's.
                if step.provider.as_deref().or(specialist(&step, &specialists).and_then(|s| s.provider.as_deref())) == Some("junie") {
                    return StepResult { label, provider: "Junie".into(), status: "done".into(), summary: "Junie doesn't run here yet.".into(), findings: Vec::new(), holds_all: false };
                }
                if round > step.round_count() {
                    return StepResult { label, provider: "Claude Code".into(), status: "done".into(), summary: format!("Its {} rounds are done.", step.round_count()), findings: Vec::new(), holds_all: false };
                }
                let prompt = format!(
                    "{}Review the change in this git worktree before it's pushed: everything since it left {base} (`git diff $(git merge-base HEAD {base})`), committed or not. Don't change anything. Look for bugs, missed cases, security problems and code that doesn't fit the repo; comment only on what the change touches.{earlier_text}\n\nEnd your reply with one fenced ```json block: a list of findings, most important first, each {{\"path\": \"<file>\", \"line\": <line in the new file>, \"severity\": \"blocker\" | \"major\" | \"minor\" | \"nit\", \"comment\": \"<what's wrong and what to do>\"}}. Give [] when there's nothing.",
                    persona(&step, &specialists)
                );
                match ask_claude(&worktree, &prompt, model(&step, &specialists).as_deref(), Duration::from_secs(15 * 60)) {
                    Ok(reply) => match findings_in(&reply, &label) {
                        Some(findings) => StepResult {
                            label,
                            provider: "Claude Code".into(),
                            status: "done".into(),
                            summary: if findings.is_empty() { "Found nothing.".into() } else { format!("{} finding{}.", findings.len(), if findings.len() == 1 { "" } else { "s" }) },
                            findings,
                            holds_all,
                        },
                        None => StepResult { label, provider: "Claude Code".into(), status: "failed".into(), summary: "Gave no list of findings.".into(), findings: Vec::new(), holds_all },
                    },
                    Err(error) => StepResult { label, provider: "Claude Code".into(), status: "failed".into(), summary: error, findings: Vec::new(), holds_all },
                }
            })
        })
        .collect();
    let mut results: Vec<StepResult> = handles.into_iter().filter_map(|h| h.join().ok()).collect();
    let blocking = |f: &Finding| matches!(f.severity.as_str(), "blocker" | "major");
    let commands_pass = results.iter().filter(|r| r.provider == "Command").all(|r| r.status == "done");
    let open_blocking = results.iter().any(|r| r.findings.iter().any(|f| r.holds_all || blocking(f)));
    // Out of rounds: a reviewer's findings no longer hold the push.
    let rounds_left = workflow.steps_when(When::Local).iter().any(|s| s.command.is_none() && s.provider.as_deref() != Some("junie") && round < s.round_count());
    let clear = commands_pass && (!open_blocking || !rounds_left);
    for r in &mut results {
        if r.provider != "Command" && r.findings.iter().any(|f| r.holds_all || blocking(f)) && !clear {
            r.status = "holding".into();
        }
    }
    (results, clear)
}

/// What the session is told after a round.
pub fn round_message(round: u32, sha: &str, results: &[StepResult], clear: bool) -> String {
    let short = &sha[..sha.len().min(7)];
    let all: Vec<&Finding> = results.iter().flat_map(|r| r.findings.iter()).collect();
    let line = |f: &&Finding| format!("- [{}] {}{}: {} ({})", f.severity, f.path, f.line.map(|l| format!(":{l}")).unwrap_or_default(), f.comment, f.reviewer);
    let blocking: Vec<String> = all.iter().filter(|f| matches!(f.severity.as_str(), "blocker" | "major")).map(line).collect();
    let suggestions: Vec<String> = all.iter().filter(|f| !matches!(f.severity.as_str(), "blocker" | "major")).map(line).collect();
    let failed: Vec<String> = results.iter().filter(|r| r.provider == "Command" && r.status == "failed").map(|r| format!("- `{}`: {}", r.label, r.summary)).collect();
    let mut out = if clear {
        format!("Gannin's local review is clear for {short} (round {round}): push when you're ready.")
    } else {
        format!("Gannin's local review, round {round}, on {short}, holds the push.")
    };
    if !failed.is_empty() {
        out.push_str(&format!("\n\nCommands that failed (make them pass):\n{}", failed.join("\n")));
    }
    if !blocking.is_empty() {
        out.push_str(&format!(
            "\n\n{}:\n{}",
            if clear { "Blockers and majors from its last round (its rounds are done, so these no longer hold the push; still deal with them)" } else { "Blockers and majors (fix them or say why not, commit, then push again)" },
            blocking.join("\n")
        ));
    }
    if !suggestions.is_empty() {
        out.push_str(&format!("\n\nSuggestions (minors and nits; take them or leave them, no need for another round):\n{}", suggestions.join("\n")));
    }
    out
}
