//! Starting Claude Code the way Gannin does (`SessionStore`, `SessionScript`,
//! `ClaudeCodeProvider`): in the org's harness, in a folder of its own
//! (`<harness>/.worktrees/<branch>/`), with a brief, hooks that write the
//! session's state into files, and a start script the terminal runs. The
//! script clones or updates the harness, puts the brief and hooks in the
//! folder, then starts claude, or resumes it once it has started before.
//!
//! The pilot keeps each session in a folder of its own in the harness's
//! git-ignored `.gannin-cache/sessions/<id>/` (in `~/.gannin/sessions/<id>/`
//! when the harness isn't cloned yet, as a clone needs an empty folder),
//! never Gannin's, and records nothing in the harness: Gannin's "Record the session" commit
//! is a write to GitHub the pilot doesn't make.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

const PR_HOOK: &str = include_str!("scripts/pr-hook.sh");
const PLANNING_INSTRUCTIONS: &str = include_str!("scripts/planning-instructions.txt");
const REVIEW_PROMPT: &str = include_str!("scripts/review-prompt.txt");

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub enum Flow {
    /// Work on This: an issue.
    Work,
    /// Review with Claude: a pull request, with edits disallowed.
    Review,
    Ask,
    QuickChange,
    Plan,
}

impl Flow {
    pub fn label(self) -> &'static str {
        match self {
            Flow::Work => "Work",
            Flow::Review => "Review",
            Flow::Ask => "Ask",
            Flow::QuickChange => "Quick change",
            Flow::Plan => "Plan",
        }
    }
}

/// What a session is about, for finding it again ("Open Session").
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Subject {
    /// The issue's or PR's node ID.
    pub id: String,
    pub repo: String,
    pub number: i64,
    pub title: String,
    pub url: String,
}

/// A session as the pilot keeps it on disk (`session.json`).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Launch {
    /// Upper case, as Gannin names session folders; claude gets it lower.
    pub id: String,
    pub flow: Flow,
    pub title: String,
    pub org: String,
    pub harness_repo: String,
    pub harness_path: PathBuf,
    pub branch: String,
    pub subject: Option<Subject>,
    pub created_at: DateTime<Utc>,
    /// Started by the schedule: runs in auto mode, can't merge, and keeps
    /// its pull requests the gap apart. Minutes of that gap.
    #[serde(default)]
    pub unattended: Option<u32>,
    /// The server it runs on (from the window's folder); None is this Mac.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server: Option<crate::servers::Server>,
}

impl Launch {
    pub fn new(flow: Flow, title: String, org: &str, harness_repo: &str, branch: String, subject: Option<Subject>) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            flow,
            title,
            org: org.to_string(),
            harness_repo: harness_repo.to_string(),
            harness_path: harness_path(org, harness_repo),
            branch,
            subject,
            created_at: Utc::now(),
            unattended: None,
            // Set from the window's folder (`Workspace::place`): a session
            // runs where the window's harness is.
            server: None,
        }
    }

    pub fn claude_id(&self) -> String {
        self.id.to_lowercase()
    }

    /// The session's own folder. `~/.gannin/sessions/<id>` indexes them:
    /// a link to the folder in the harness, or the folder itself when the
    /// harness wasn't there to hold it. Never changes once it's made, as
    /// the start script and hooks are written with it.
    pub fn dir(&self) -> PathBuf {
        let entry = sessions_dir().join(&self.id);
        if let Ok(target) = std::fs::read_link(&entry) {
            return target;
        }
        if entry.exists() {
            return entry;
        }
        match self.harness_path.join(".git").exists() {
            true => self.harness_path.join(".gannin-cache/sessions").join(&self.id),
            false => entry,
        }
    }

    /// Takes the session's folder away, and its entry in the index.
    pub fn remove_dir(&self) {
        let _ = std::fs::remove_dir_all(self.dir());
        let _ = std::fs::remove_file(sessions_dir().join(&self.id));
    }

    /// The session's folder in the harness.
    pub fn folder(&self) -> PathBuf {
        self.harness_path.join(".worktrees").join(&self.branch)
    }

    /// The session's folder as this Mac can read it: the folder itself, or
    /// for a session on a server, the copy the mirror keeps of its plan,
    /// screens and architecture (`servers::watch`).
    pub fn local_folder(&self) -> PathBuf {
        match self.server {
            Some(_) => self.dir().join("folder"),
            None => self.folder(),
        }
    }

    /// The state the hooks last wrote: starting, working, needs-you, idle
    /// or exited.
    pub fn state(&self) -> Option<String> {
        std::fs::read_to_string(self.dir().join("state")).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
    }

    /// Pull requests claude opened, as the PR hook recorded them.
    pub fn pull_requests(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir().join("pr")).map(|s| s.lines().map(str::to_string).collect()).unwrap_or_default()
    }

    /// Writes the brief, the hooks and the start script, and the session's
    /// record; `extra` adds files the flow needs (Ask's context README).
    pub fn prepare(&self, brief: &str, prompt: &str, disallow_edits: bool, gate: bool) -> std::io::Result<()> {
        let dir = self.dir();
        let entry = sessions_dir().join(&self.id);
        if dir != entry {
            // Ignored by git before anything goes in it.
            crate::paths::harness_cache(&self.harness_path);
        }
        std::fs::create_dir_all(&dir)?;
        if dir != entry && !entry.is_symlink() {
            std::fs::create_dir_all(sessions_dir())?;
            std::os::unix::fs::symlink(&dir, &entry)?;
        }
        std::fs::write(dir.join("brief.md"), brief)?;
        let gap = self.unattended.map(|minutes| crate::schedule::gap_hook(&self.id, minutes));
        std::fs::write(dir.join("settings.json"), settings_json(&dir, gate, gap))?;
        std::fs::write(dir.join("start.sh"), self.start_script(prompt, disallow_edits))?;
        std::fs::write(dir.join("state"), "starting")?;
        std::fs::write(dir.join("session.json"), serde_json::to_vec_pretty(self).unwrap_or_default())?;
        Ok(())
    }

    /// `SessionScript.harnessStart`, as Gannin writes it.
    pub fn start_script(&self, prompt: &str, disallow_edits: bool) -> String {
        // Unattended: auto mode (never a laxer one), and it can't merge.
        let disallowed = match (disallow_edits, self.unattended.is_some()) {
            (true, false) => " --disallowedTools 'Edit,MultiEdit,Write,NotebookEdit'".to_string(),
            (true, true) => " --permission-mode auto --disallowedTools 'Edit,MultiEdit,Write,NotebookEdit,Bash(gh pr merge:*)'".to_string(),
            (false, true) => " --permission-mode auto --disallowedTools 'Bash(gh pr merge:*)'".to_string(),
            (false, false) => String::new(),
        };
        let about = match &self.subject {
            Some(s) => format!("{}#{}", s.repo, s.number),
            None => self.title.clone(),
        };
        let mut copies = String::new();
        if self.flow == Flow::Ask {
            copies.push_str("mkdir -p \"$folder/files\"\nrm -rf \"$folder/context\" && cp -R \"$session/context\" \"$folder/context\"\n");
        }
        if self.flow == Flow::QuickChange {
            copies.push_str("if [ -d \"$session/attachments\" ]; then mkdir -p \"$folder/.gannin/attachments\" && cp -R \"$session/attachments/.\" \"$folder/.gannin/attachments/\"; fi\n");
        }
        if self.flow == Flow::Plan {
            copies.push_str("mkdir -p \"$folder/docs\"\nif [ -d \"$session/docs\" ]; then cp -R \"$session/docs/.\" \"$folder/docs/\"; fi\n");
        }
        format!(
            r#"# Written by the Gannin pilot for {about}. Run in the session's terminal.
session={session}
harness={harness}
harness_repo={harness_repo}
id={id}
folder="$harness"/{branch}

# A session started from inside Claude Code would otherwise think it's
# nested in that one.
unset CLAUDECODE
for name in $(env | sed -n 's/^\(CLAUDE_CODE_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$name"; done

note() {{ printf '\033[90m%s\033[0m\n' "$1"; }}
warn() {{ printf '\033[33mGannin: %s\033[0m\n' "$1"; }}
fail() {{
  printf '\033[31mGannin: %s\033[0m\n' "$1"
  if [ -d "$harness" ]; then cd "$harness"; else cd; fi
  exec "${{SHELL:-bash}}" -l
}}

if [ ! -e "$harness/.git" ]; then
  note "Cloning the harness, $harness_repo, into $harness"
  mkdir -p "$(dirname "$harness")"
  if command -v gh >/dev/null 2>&1; then
    gh repo clone "$harness_repo" "$harness" || fail "Couldn't clone the harness, $harness_repo."
  else
    git clone "https://github.com/$harness_repo.git" "$harness" || fail "Couldn't clone the harness, $harness_repo."
  fi
else
  note "Updating the harness"
  git -C "$harness" pull --ff-only --quiet || warn "Couldn't fast-forward the harness, so it's as it was. Pull it when you can."
fi
exclude="$(git -C "$harness" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$exclude")"
for kept in projects .worktrees; do
  git -C "$harness" check-ignore -q "$kept/x" || echo "/$kept/" >> "$exclude"
done

mkdir -p "$folder/.gannin" || fail "Couldn't make $folder."
cp "$session/brief.md" "$folder/.gannin/"
{copies}cp "$session/settings.json" "$folder/.gannin/settings.json"
if [ -e "$session/preparing" ]; then
  note "Waiting for the workflow's prepare steps"
  while [ -e "$session/preparing" ]; do sleep 1; done
  cp "$session/brief.md" "$folder/.gannin/"
fi
cd "$harness" || fail "The harness isn't there."
command -v claude >/dev/null 2>&1 || fail "claude isn't on your PATH. Install Claude Code, then Resume the session."
if [ -e "$session/started" ]; then
  claude --resume "$id"{disallowed} --settings "$folder/.gannin/settings.json"
else
  claude --session-id "$id"{disallowed} --settings "$folder/.gannin/settings.json" {prompt}
fi
printf exited > "$session/state"
note "Claude Code has exited. This shell is in the harness; run claude --resume $id to go on."
exec "${{SHELL:-bash}}" -l
"#,
            session = quote_path(&self.dir()),
            harness = quote_path(&self.harness_path),
            harness_repo = quote(&self.harness_repo),
            id = quote(&self.claude_id()),
            branch = quote(&format!(".worktrees/{}", self.branch)),
            prompt = quote(prompt),
        )
    }
}

/// `~/.gannin/sessions`: every session, by id (see `Launch::dir`).
pub fn sessions_dir() -> PathBuf {
    crate::paths::app_dir().join("sessions")
}

/// Every session the pilot has started, newest first.
/// Whether `url` ("https://github.com/owner/repo/pull/12") is PR `number`
/// of `repo`.
pub fn is_pull_url(url: &str, repo: &str, number: i64) -> bool {
    url.trim()
        .split("github.com/")
        .nth(1)
        .and_then(|rest| rest.split_once("/pull/"))
        .is_some_and(|(r, n)| r.eq_ignore_ascii_case(repo) && n.split(|c: char| !c.is_ascii_digit()).next() == Some(number.to_string().as_str()))
}

/// The work session (Work on This or a quick change) that opened PR
/// `number` of `repo`, newest first, from the sessions kept on disk.
pub fn opened_pull(repo: &str, number: i64) -> Option<Launch> {
    saved().into_iter().find(|l| matches!(l.flow, Flow::Work | Flow::QuickChange) && l.pull_requests().iter().any(|u| is_pull_url(u, repo, number)))
}

pub fn saved() -> Vec<Launch> {
    let mut all: Vec<Launch> = std::fs::read_dir(sessions_dir())
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| std::fs::read(entry.path().join("session.json")).ok())
        .filter_map(|bytes| serde_json::from_slice(&bytes).ok())
        .collect();
    all.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    all
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

/// A shell word in single quotes.
pub fn quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// A path for the script, under `$HOME` where it is, as Gannin writes it.
pub fn quote_path(path: &Path) -> String {
    let home = home();
    match path.strip_prefix(&home) {
        Ok(rest) if !home.as_os_str().is_empty() => format!("\"$HOME\"/{}", quote(&rest.to_string_lossy())),
        _ => quote(&path.to_string_lossy()),
    }
}

/// Claude Code's settings with Gannin's hooks: each writes the session's
/// state, or records a change or an opened pull request, into its folder.
fn settings_json(dir: &Path, gate: bool, gap: Option<String>) -> String {
    let file = |name: &str| format!("{}/{name}", quote_path(dir));
    let state = |value: &str| serde_json::json!({ "type": "command", "command": format!("printf {value} > {} 2>/dev/null; exit 0", file("state")) });
    let pr_hook = PR_HOOK.replace("__PR__", &file("pr"));
    let settings = serde_json::json!({
        "hooks": {
            "Notification": [{ "matcher": "permission_prompt|elicitation_dialog", "hooks": [state("needs-you")] }],
            "PostToolUse": [
                { "matcher": "*", "hooks": [state("working")] },
                { "matcher": "*", "hooks": [{ "type": "command", "command": pr_hook }] },
                { "matcher": "Edit|MultiEdit|Write|NotebookEdit|Bash", "hooks": [{ "type": "command", "command": format!("printf %s \"$(date +%s)-$$\" > {} 2>/dev/null; exit 0", file("changed")) }] },
            ],
            "PreToolUse": [
                { "matcher": "*", "hooks": [state("working")] },
                // The tool it's about to use, and on what, for the question
                // or permission card.
                { "matcher": "*", "hooks": [{ "type": "command", "command": format!("cat > {} 2>/dev/null; exit 0", file("tool.json")) }] },
                { "matcher": "AskUserQuestion", "hooks": [state("needs-you")] },
            ],
            "SessionEnd": [{ "hooks": [state("exited")] }],
            "SessionStart": [{ "hooks": [state("idle")] }],
            "Stop": [{ "hooks": [state("idle")] }],
            "UserPromptSubmit": [{ "hooks": [
                { "type": "command", "command": format!("touch {}", file("started")) },
                state("working"),
            ] }],
        },
    });
    let mut settings = settings;
    // A workflow's local review holds pushes until it's clear, and an
    // unattended session's pull requests keep the gap apart.
    if let Some(pre) = settings["hooks"]["PreToolUse"].as_array_mut() {
        if gate {
            pre.push(serde_json::json!({ "matcher": "Bash", "hooks": [{ "type": "command", "command": crate::work_flow::gate_hook(dir) }] }));
        }
        if let Some(gap) = gap {
            pre.push(serde_json::json!({ "matcher": "Bash", "hooks": [{ "type": "command", "command": gap }] }));
        }
    }
    serde_json::to_string_pretty(&settings).unwrap_or_default()
}

/// The harness checkout off its default branch: where it is instead
/// ("on stack-dns", "at 3cf2f36d, not on a branch"), its default branch,
/// and whether it has no changes to tracked files (so it can be switched).
pub struct HarnessOff {
    pub on: String,
    pub default: String,
    pub clean: bool,
}

fn git_in(dir: &Path, args: &[&str]) -> Option<String> {
    let out = std::process::Command::new("git").arg("-C").arg(dir).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Whether the harness is off its default branch (None when it's on it, or
/// that can't be told).
pub fn harness_branch(harness: &Path) -> Option<HarnessOff> {
    let default = git_in(harness, &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])?.trim_start_matches("origin/").to_string();
    let on = match git_in(harness, &["symbolic-ref", "--short", "-q", "HEAD"]) {
        Some(branch) if branch == default => return None,
        Some(branch) => format!("on {branch}"),
        None => format!("at {}, not on a branch", git_in(harness, &["rev-parse", "--short", "HEAD"]).unwrap_or_default()),
    };
    let clean = git_in(harness, &["status", "--porcelain", "--untracked-files=no"]).is_some_and(|s| s.is_empty());
    Some(HarnessOff { on, default, clean })
}

/// Puts the harness back on its default branch and pulls it.
pub fn switch_harness(harness: &Path, default: &str) -> Result<(), String> {
    let run = |args: &[&str]| -> Result<(), String> {
        let out = std::process::Command::new("git").arg("-C").arg(harness).args(args).output().map_err(|e| e.to_string())?;
        if out.status.success() {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
        }
    };
    run(&["checkout", default])?;
    run(&["pull", "--ff-only", "--quiet"])
}

/// Where the org's harness is checked out here, as
/// `SessionStore.localHarnessPath` finds it: where a folder opened here has
/// it, else an existing checkout of it in the usual places, else
/// `~/Gannin/<org>-<name>`.
pub fn harness_path(org: &str, repo: &str) -> PathBuf {
    // Where a folder opened here (Open Recent) has it.
    if let Some(path) = crate::folders::known_path(repo) {
        return path;
    }
    let (owner, name) = repo.split_once('/').unwrap_or(("", repo));
    let home = home();
    let mut candidates = Vec::new();
    for root in ["Code", "Developer", "Projects", "src", "code", "dev"] {
        candidates.push(home.join(root).join(owner).join(name));
        candidates.push(home.join(root).join(name));
    }
    candidates.push(home.join(owner).join(name));
    candidates.push(home.join(name));
    candidates.push(home.join("Gannin").join(owner).join(name));
    for candidate in candidates {
        if origin_is(&candidate, repo) {
            return candidate;
        }
    }
    let folder = if name == "harness" { format!("{org}-harness") } else { format!("{org}-{name}") };
    home.join("Gannin").join(folder)
}

/// Whether the folder is a checkout of `repo`, by its origin.
fn origin_is(folder: &Path, repo: &str) -> bool {
    if !folder.join(".git").exists() {
        return false;
    }
    std::process::Command::new("git")
        .arg("-C")
        .arg(folder)
        .args(["remote", "get-url", "origin"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().trim_end_matches(".git").to_lowercase())
        .is_some_and(|url| url.ends_with(&format!("/{}", repo.to_lowercase())) || url.ends_with(&format!(":{}", repo.to_lowercase())))
}

/// `Slug.make`: lower case, words of letters and digits joined by `-`,
/// as many as fit in `limit`.
pub fn slug(text: &str, limit: usize) -> String {
    let cleaned: String = text.to_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { ' ' }).collect();
    let mut slug = String::new();
    for word in cleaned.split_whitespace() {
        let next = if slug.is_empty() { word.to_string() } else { format!("{slug}-{word}") };
        if next.len() > limit {
            break;
        }
        slug = next;
    }
    slug
}

/// `SessionStore.branchName`: `<number>-<slug>`, else `issue-<number>`.
pub fn issue_branch(number: i64, title: &str) -> String {
    let slug = slug(title, 40);
    if slug.is_empty() { format!("issue-{number}") } else { format!("{number}-{slug}") }
}

// MARK: - Prompts, as Gannin's

/// `SessionScript.openingPrompt`, for Work on This.
pub fn opening_prompt(reference: &str, title: &str, branch: &str) -> String {
    format!(
        "You're picking up {reference}, \"{title}\", in the team's harness. Read .worktrees/{branch}/.gannin/brief.md first: it has the issue, its discussion, where it sits on the board and any plans for it. Work out which repos it touches (those under projects/, or the harness itself when it's the code repo and has no projects/) and look through their code, then propose a plan before changing anything. Make the changes in a worktree per repo under .worktrees/{branch}/, as the brief says, never in projects/ or the harness checkout itself. If you have questions for me, ask them with the AskUserQuestion tool rather than as plain text."
    )
}

/// `pullRequestReviewPrompt`, with no team learnings or review config. The
/// team's default review prompts are named, not inlined: claude reads them
/// in the harness after the start script pulls it, here or on a server.
pub fn review_prompt(repo: &str, number: i64, title: &str, url: &str, branch: &str, sensitive: &[crate::risk::Sensitive]) -> String {
    let (owner, name) = repo.split_once('/').unwrap_or((repo, repo));
    // The team's `{{placeholders}}` stay as written: hide them from ours.
    REVIEW_PROMPT
        .replace("{{", "\u{1}")
        .replace("}}", "\u{2}")
        .replace("{sensitive}", &crate::risk::prompt_part(sensitive))
        .replace("{repo}", repo)
        .replace("{owner}", owner)
        .replace("{name}", name)
        .replace("{number}", &number.to_string())
        .replace("{title}", title)
        .replace("{url}", url)
        .replace("{branch}", branch)
        .replace('\u{1}', "{{")
        .replace('\u{2}', "}}")
}

/// The Review Again prompt.
pub const REVIEW_AGAIN: &str = "The PR may have changed. Fetch it again, review it afresh, and end the same way with the JSON block, listing in `resolved` the threads now dealt with.";

/// `askPrompt`.
pub fn ask_prompt(message: &str, branch: &str) -> String {
    format!(
        "{}\n\n(From Gannin: this is an open-ended conversation in the team's harness, about whatever I've asked. Save any file you make for me, such as an export, a CSV or a chart, in `.worktrees/{branch}/files/`, where I can grab it. Gannin's view of the org (workload, issues, delivery, the harness's documents, time off) is in `.worktrees/{branch}/context/`, README.md first, if the question needs it. More in `.worktrees/{branch}/.gannin/brief.md`.)",
        message.trim()
    )
}

/// `askBrief`.
pub fn ask_brief(title: &str, harness_repo: &str, harness_path: &Path, branch: &str) -> String {
    format!(
        "# Ask: {title}\n\nAn open-ended conversation started from Gannin. It isn't about an issue, a pull request or a plan: it's about whatever was asked, which may have nothing to do with the code or the harness (how many users logged in today, say, which may need the code to find out where that's kept).\n\n## Working here\n\n- You're in the team's harness, {harness_repo}, checked out at `{}`. Its CLAUDE.md, skills and MCP servers apply. The code repos are shared clones under `projects/<name>`, to read; don't change them.\n- Save every file you make for the person you're talking to in `.worktrees/{branch}/files/`, so they can open it, drag it out or save it elsewhere from Gannin. Don't leave files anywhere else unless asked to.\n- `.worktrees/{branch}/context/` is Gannin's view of the org as JSON, written when the session started or resumed: workload, issues, delivery, the harness's documents and time off. README.md says what's in each. Use it if a question needs it; it isn't the subject.\n- Never commit, push or copy into the harness anything from this folder. Files may hold customer or other sensitive data. If one should be shared, the person commits it themselves from Gannin.\n- `.worktrees/{branch}/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` is kept out of the harness's git.\n",
        harness_path.display()
    )
}

/// `askTitle`: the first line, cut at a word near 60 characters.
pub fn short_title(text: &str) -> String {
    let line = text.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    if line.chars().count() <= 60 {
        return line.to_string();
    }
    let cut: String = line.chars().take(60).collect();
    match cut.rfind(' ') {
        Some(at) if at > 30 => cut[..at].to_string(),
        _ => cut,
    }
}

/// `quickChangePrompt`, with no issue filed (filing one is a write).
pub fn quick_change_prompt(repo: &str, title: &str, branch: &str, screenshots: bool) -> String {
    format!(
        "You're making a quick change in {repo}, \"{title}\", in the team's harness. Read .worktrees/{branch}/.gannin/brief.md first: it has the note{}. It's meant to be small, so there's no plan document: look through the code, say in a line or two what you'll change. Then make the change in a worktree of the repo under .worktrees/{branch}/, as the brief says, never in projects/ or the harness checkout itself. If it turns out not to be small, stop and say so before going further.",
        if screenshots { " and the screenshots to look at" } else { "" }
    )
}

/// The planning session's prompt: the default guidance, then the state
/// file's instructions, as `planningPrompt` puts them together.
/// `size` is what the room expects it to be (initiative, epic or issue),
/// when it said; `docs` the documents shared at the start, and whether
/// each may be committed.
pub fn planning_prompt(topic: &str, branch: &str, issue: Option<(&str, i64, &str)>, size: Option<&str>, docs: &[crate::planning::Doc]) -> String {
    let today = Utc::now().format("%Y-%m-%d");
    let slug = slug(topic, 40);
    let mut starting = match issue {
        Some((reference, number, repo)) => format!(" We're planning {reference}: read it first with `gh issue view {number} --repo {repo} --comments`."),
        None => String::new(),
    };
    if let Some(size) = size {
        starting.push_str(&format!(" The room expects this to be {} {size}; say so if the outcome turns out bigger or smaller.", if size.starts_with(['a', 'e', 'i', 'o', 'u']) { "an" } else { "a" }));
    }
    if !docs.is_empty() {
        let list: Vec<String> = docs.iter().map(|d| format!("{} ({})", d.name, if d.commit { "may be committed" } else { "don't commit" })).collect();
        starting.push_str(&format!(" The room has shared {}, in .worktrees/{branch}/docs/.", list.join(", ")));
    }
    let guidance = format!(
        "Let's plan \"{topic}\" together, here in the team's harness. Read STANDARDS.md and plans/_template.md first.{starting}\n\nI may share documents (specs, notes, emails, exports). They'll be in .worktrees/{branch}/docs/, and I'll tell you each time, with which ones may be committed. Only those may go into the harness, in plans/assets/{slug}/, linked from the plan. Never commit, copy into the harness, or quote at length a document I haven't marked for committing: it may hold sensitive details. Summarise what you need from it in your own words.\n\nAsk what you need to know, one question at a time. When we agree, Gannin writes the plan as plans/{today}-{slug}.md, following the standard, from what you've kept. Commit only the assets marked for committing, and only when I say so."
    );
    let repo_rule = "where its issue is filed, so it must be a repository with issues turned on that isn't archived (check with `gh repo view owner/name --json hasIssuesEnabled,isArchived`). When the work is in a repository that can't take issues, give the task the closest repository that accepts them and name the other in its `body`.";
    let instructions = PLANNING_INSTRUCTIONS.replace("__PATH__", &format!(".worktrees/{branch}/planning.json")).replace("__REPO_RULE__", repo_rule);
    format!("{guidance}\n\n{instructions}")
}

/// The planning prompt's suggested facilitator guidance.
pub fn suggested_planning_guidance(title: &str) -> String {
    format!(
        "Run this like a good refinement session for {title}.\n\n- Start from the outcome, not the solution: who it's for, what changes for them, and how we'll know it worked.\n- Start from the problem as people have it today: how often, and what it costs them.\n- Push on scope: suggest the smallest version worth shipping, and name what's deliberately left out.\n- Before deciding how it's built, show what it looks like: the flows people go through and a screen for each step they see, checked against the acceptance criteria.\n- Before proposing an approach, look at how similar things are already done in the code, and follow those patterns.\n- Call out risks, dependencies, and anything that needs someone who isn't in the room.\n- Group the work into a few larger issues, by repository where it makes sense, each with its steps as a checklist and a line on how it'll be checked."
    )
}

/// The "Working here" section of a work brief (`SessionBrief.make`).
pub fn working_here(harness_repo: &str, harness_path: &Path, branch: &str, reference: Option<&str>, issue_repo: &str, quick: bool) -> String {
    let harness_name = harness_repo.rsplit('/').next().unwrap_or(harness_repo);
    let thing = if quick { "change" } else { "issue" };
    let mut lines = vec![
        format!("- You're in the team's harness, {harness_repo}, checked out at `{}`. Its CLAUDE.md lists the projects and how work goes here.", harness_path.display()),
        format!(
            "- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This {thing}'s folder is `.worktrees/{branch}/`: give each repo it touches a worktree there, on the branch `{branch}`, from the harness root:\n\n  ```bash\n  git -C projects/<name> fetch origin\n  git -C projects/<name> worktree add \"$PWD/.worktrees/{branch}/<name>\" -b {branch} origin/HEAD\n  ```\n\n  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`."
        ),
        format!(
            "- If the harness has no `projects/` folder, it's the code repo too: the code is {harness_repo} itself. Don't work in its checkout; give it one worktree in the {thing}'s folder the same way, with `git -C . fetch origin` and `git -C . worktree add \"$PWD/.worktrees/{branch}/{harness_name}\" -b {branch} origin/HEAD`, and do everything there, the plan included."
        ),
    ];
    if quick {
        lines.push(format!("- The change is in {issue_repo}."));
    } else if issue_repo != harness_repo {
        lines.push(format!("- The issue lives in {issue_repo}."));
    }
    match (reference, quick) {
        (Some(reference), _) => lines.push(format!(
            "- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting \"Closes {reference}\" in its body so it links to the issue. When one of them needs another merged first (an API before the page that calls it, config before the code that reads it), put a line \"Depends on: owner/repo#number\" in the body of the one that waits, and keep it right as PRs are added, so the order shows in Gannin."
        )),
        (None, _) => lines.push(format!(
            "- Commit in the worktree, and open a pull request with `gh pr create`. There's no issue, so don't make one or invent a reference: put \"Quick change, no issue.\" in its body where `Closes` would go, and keep the branch's name, `{branch}`."
        )),
    }
    if quick {
        lines.push("- A quick change needs no plan document. If it grows to need one, stop and say so instead.".into());
    } else if let Some(reference) = reference {
        lines.push(format!(
            "- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [{reference}]` and a summary in its front matter as `{}/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.",
            harness_path.display()
        ));
    }
    lines.push(format!("- `.worktrees/{branch}/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git."));
    format!("## Working here\n\n{}\n", lines.join("\n"))
}

/// Map the System: claude writes the harness's architecture documents from
/// the code, for planning to start from and keep up to date.
pub fn map_brief(org: &str, harness_repo: &str, harness_path: &Path, branch: &str) -> String {
    let today = Utc::now().format("%Y-%m-%d");
    format!(
        r#"# Map the System

Write the team's architecture documents: how {org}'s systems fit together, drawn from the code. Planning sessions start their design from these and update them as plans are agreed, so they need to be right and grounded in the code, not a guess at it.

## Working here

- You're in the team's harness, {harness_repo}, checked out at `{harness}`. The code repos are shared clones under `projects/<name>`, to read. Bring each up to date with `git -C projects/<name> pull --ff-only` before reading it, and never change, commit or push in one. For repos that aren't cloned there, `gh repo list {org} --no-archived` lists them: say which you couldn't read rather than cloning them.
- Read what's in the harness's `architecture/` first. Update a document that exists rather than writing a second one about the same thing.
- Write every document in `.worktrees/{branch}/architecture/`, under the name it has (or will have) in the harness. Don't write anywhere else.
- `.worktrees/{branch}/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` is kept out of the harness's git.

## What to write

- `overview.md`: every system, and how they connect, in one context diagram: people, external services and each system as a box, each connection labelled with what crosses it. A line on each system linking to its own document.
- One document per system or area (a service, an app, a pipeline), named for it in kebab case: `job-runs.md`, `billing.md`.

Each document:

```markdown
---
type: architecture
title: The system's name
summary: A sentence on what it does and for whom.
status: current
covers: [owner/repo, owner/repo:path/inside]
verified_at:
  owner/repo: <the commit you read, from git -C projects/<name> rev-parse HEAD>
updated: {today}
---

# The system's name

What it is and what it's for, in a paragraph.

## Context
A Mermaid flowchart: who and what it talks to, outside itself.

## Parts
A Mermaid flowchart: its services, stores, queues and jobs, each connection labelled with what passes along it.

## Key flows
One to three Mermaid sequence diagrams for what matters most (a request, a job, a payment).

## Trust boundaries
Where data comes in from outside, who can trigger what, how it's authenticated, and where personal or sensitive data is kept.

## Where to look
Links to the code for each part: [owner/repo:path](https://github.com/owner/repo/blob/HEAD/path).
```

- Ground every box and every connection in code you read, and link it under Where to look. When something is inferred (from config, naming or a README) rather than read, say so in the text.
- Keep each diagram readable: around fifteen nodes at most. Split a system that needs more into documents of its own and link them.
- Planned work is marked in diagrams by planning sessions (`:::planned`, `:::retiring`, and `planned_by` in front matter). You're mapping what's built: leave those marks as they are in a document you update, and don't add any.

## When you're done

Say what you wrote, what you couldn't map and why, and anything that looked wrong or risky in passing. Then ask before writing anything to GitHub. With the person's go-ahead, put the documents on a branch of the harness named `{branch}` (a worktree at `.worktrees/{branch}/harness`, from the default branch, with the documents copied into its `architecture/`), commit them, push the branch and open a pull request for the team to review. Never push to the default branch.
"#,
        harness = harness_path.display()
    )
}

pub fn map_prompt(branch: &str) -> String {
    format!("You're mapping how the team's systems fit together, to write the harness's architecture documents. Read .worktrees/{branch}/.gannin/brief.md first: it says where the code is, what to write and where. Start by listing the repos you'll read and the systems you expect to find, and ask me if that's the right scope before you go deep.")
}
