//! Marra's engine: one headless claude kept running, spoken to in
//! stream-json on its stdin and heard on its stdout (docs/marra.md).
//!
//! - Gannin answers claude's permission requests itself (`--permission-prompt-tool
//!   stdio`: a `can_use_tool` control request, answered with a control
//!   response): read-only tools go straight through, the rest wait on a card.
//! - One conversation, resumed after a relaunch (`--resume`), its id and
//!   settings in `~/.gannin/marra/state.json`; the chat as shown is Gannin's
//!   own log beside it (`chat.jsonl`), so nothing depends on reading
//!   claude's transcript format.
//! - `/compact` goes as an ordinary message; New conversation starts a new
//!   session id.
//! - The process starts on the first message, not with the app, and starts
//!   again (resuming) if it has gone.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};

/// Marra's folder: claude's working directory (so `--resume` finds the
/// conversation) and Gannin's state and chat log.
pub fn dir() -> PathBuf {
    crate::paths::app_dir().join("marra")
}

/// What's kept between launches.
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Saved {
    /// The conversation, once one has started.
    #[serde(default)]
    pub session: Option<String>,
    /// claude's `--model`; None uses claude's own default.
    #[serde(default)]
    pub model: Option<String>,
    /// Tools allowed for good with Allow always: a tool name, or for Bash
    /// `Bash(<program>)`.
    #[serde(default)]
    pub always: Vec<String>,
    /// Whether Marra floats above other apps or docks into a Gannin window.
    #[serde(default)]
    pub docked: bool,
    /// Focus: everything but blocked items is held.
    #[serde(default)]
    pub focus: bool,
    /// Threads pinned, muted, and when each was last read (thread id to
    /// RFC 3339), for the thread list.
    #[serde(default)]
    pub pinned: Vec<String>,
    #[serde(default)]
    pub muted: Vec<String>,
    #[serde(default)]
    pub read: std::collections::HashMap<String, String>,
    /// Reminders set with Remind me: item key to when it comes back
    /// (RFC 3339), or "ci" for when CI passes.
    #[serde(default)]
    pub snoozed: std::collections::HashMap<String, String>,
}

impl Saved {
    pub fn load() -> Self {
        std::fs::read(dir().join("state.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save(&self) {
        let _ = std::fs::create_dir_all(dir());
        if let Ok(bytes) = serde_json::to_vec_pretty(self) {
            let path = dir().join("state.json");
            let tmp = path.with_extension("json.tmp");
            if std::fs::write(&tmp, bytes).is_ok() {
                let _ = std::fs::rename(tmp, path);
            }
        }
    }
}

/// A line of Main's chat, as shown and as logged.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Entry {
    You { text: String, at: String },
    Marra { text: String, at: String },
    /// A tool Marra used: its name and what it was given, in a line.
    Tool { id: String, name: String, summary: String, #[serde(default)] failed: bool },
    /// A permission claude asked for; `answer` once decided.
    Permission { request: String, tool: String, summary: String, #[serde(default)] answer: Option<String> },
    /// Small centred text: compacted, a new conversation, an error.
    Event { text: String, at: String },
    /// A worker's reply under the contract: the point in a bubble, the
    /// body folded under it.
    Reply { point: String, body: String, at: String },
    /// Gannin answering from its own state (an instant command), no model call.
    Note { text: String, at: String },
}

impl Entry {
    /// The line a thread list shows for it, if it has one.
    pub fn line(&self) -> Option<String> {
        match self {
            Entry::You { text, .. } => Some(format!("You: {}", text.lines().next().unwrap_or_default())),
            Entry::Marra { text, .. } | Entry::Note { text, .. } => text.lines().find(|l| !l.trim().is_empty()).map(|l| l.trim_start_matches('#').trim().to_string()),
            Entry::Reply { point, .. } => Some(point.clone()),
            Entry::Permission { summary, answer: None, .. } => Some(format!("Wants to use {summary}")),
            _ => None,
        }
    }

    pub fn at(&self) -> Option<&str> {
        match self {
            Entry::You { at, .. } | Entry::Marra { at, .. } | Entry::Event { at, .. } | Entry::Reply { at, .. } | Entry::Note { at, .. } => Some(at),
            _ => None,
        }
    }
}

pub fn now() -> String {
    chrono::Local::now().to_rfc3339()
}

pub fn load_chat(path: &std::path::Path) -> Vec<Entry> {
    let Ok(text) = std::fs::read_to_string(path) else { return Vec::new() };
    let mut entries: Vec<Entry> = text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
    // A permission left open by a quit can't be answered now: its process went.
    for entry in &mut entries {
        if let Entry::Permission { answer, .. } = entry {
            if answer.is_none() {
                *answer = Some("Not answered".into());
            }
        }
    }
    let keep = entries.len().saturating_sub(400);
    entries.split_off(keep)
}

/// Rewrites the log: called after a turn ends, not per delta.
pub fn save_chat(path: &std::path::Path, entries: &[Entry]) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let body: String = entries.iter().filter_map(|e| serde_json::to_string(e).ok()).map(|l| l + "\n").collect();
    let path = path.to_path_buf();
    let tmp = path.with_extension("jsonl.tmp");
    if std::fs::write(&tmp, body).is_ok() {
        let _ = std::fs::rename(tmp, path);
    }
}

/// What the reader thread hands the window.
#[derive(Clone, Debug)]
pub enum Event {
    /// Text streaming into Marra's current bubble.
    Delta(String),
    /// A whole assistant text block (replaces the streamed text of that block).
    Text(String),
    Tool { id: String, name: String, input: Value },
    ToolDone { id: String, failed: bool },
    /// claude wants to use a tool that needs an answer.
    Ask { request: String, tool: String, input: Value },
    /// "compacting" while it compacts, None after.
    Status(Option<String>),
    Compacted { before: u64, after: u64 },
    /// Context in use: the latest call's input, cached or not.
    Context(u64),
    /// A turn ended.
    Done { error: Option<String> },
    /// The process went away.
    Exited(String),
}

/// The running claude and what it has said.
pub struct Engine {
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    events: Arc<Mutex<VecDeque<Event>>>,
    /// The process this reader belongs to, so a stale reader's events are dropped.
    generation: Arc<Mutex<u64>>,
    pub busy: bool,
    pub profile: Profile,
    /// The MCP server's address and token, given to each process started.
    pub mcp: Option<(u16, String)>,
}

/// How a claude is started: Marra's own, or an errand's worker.
#[derive(Clone, Default)]
pub struct Profile {
    pub cwd: PathBuf,
    pub system: String,
    /// The conversation; a new id is made when None.
    pub session: Option<String>,
    pub model: Option<String>,
    /// More arguments (an errand's disallowed tools).
    pub extra: Vec<String>,
}

impl Profile {
    /// Marra's own, from what's saved.
    pub fn marra(saved: &Saved) -> Self {
        Self { cwd: dir(), system: system_prompt(), session: saved.session.clone(), model: saved.model.clone(), extra: Vec::new() }
    }
}

impl Engine {
    pub fn new(profile: Profile) -> Self {
        Self { child: None, stdin: None, events: Arc::default(), generation: Arc::default(), busy: false, profile, mcp: None }
    }

    pub fn running(&mut self) -> bool {
        match self.child.as_mut().map(|c| c.try_wait()) {
            Some(Ok(None)) => true,
            _ => false,
        }
    }

    /// Takes what the reader has queued.
    pub fn drain(&mut self) -> Vec<Event> {
        let out: Vec<Event> = self.events.lock().map(|mut q| q.drain(..).collect()).unwrap_or_default();
        for event in &out {
            if matches!(event, Event::Done { .. } | Event::Exited(_)) {
                self.busy = false;
            }
        }
        if out.iter().any(|e| matches!(e, Event::Exited(_))) {
            self.stdin = None;
            self.child = None;
        }
        out
    }

    fn start(&mut self) -> Result<(), String> {
        let folder = self.profile.cwd.clone();
        std::fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
        let mut args: Vec<String> = vec![
            "-p".into(),
            "--input-format".into(),
            "stream-json".into(),
            "--output-format".into(),
            "stream-json".into(),
            "--include-partial-messages".into(),
            "--verbose".into(),
            "--permission-prompt-tool".into(),
            "stdio".into(),
            "--append-system-prompt".into(),
            self.profile.system.clone(),
        ];
        // A conversation that exists resumes; a new one takes the id it was given.
        match &self.profile.session {
            Some(id) if transcript_exists(id) => args.extend(["--resume".into(), id.clone()]),
            Some(id) => args.extend(["--session-id".into(), id.clone()]),
            None => {
                let id = uuid::Uuid::new_v4().to_string();
                self.profile.session = Some(id.clone());
                args.extend(["--session-id".into(), id]);
            }
        }
        if let Some(model) = self.profile.model.as_ref().filter(|m| !m.trim().is_empty()) {
            args.extend(["--model".into(), model.trim().into()]);
        }
        args.extend(self.profile.extra.iter().cloned());
        if let Some((port, token)) = &self.mcp {
            let config = json!({ "mcpServers": { "gannin": { "type": "http", "url": format!("http://127.0.0.1:{port}/mcp"), "headers": { "Authorization": format!("Bearer {token}") } } } });
            // Kept in Marra's folder (only this user can read ~/.gannin), not the harness.
            let path = dir().join(format!("mcp-{}.json", self.profile.session.as_deref().unwrap_or("marra")));
            let _ = std::fs::create_dir_all(dir());
            std::fs::write(&path, config.to_string()).map_err(|e| e.to_string())?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
            }
            args.extend(["--mcp-config".into(), path.display().to_string()]);
        }
        // An interactive login shell's PATH finds claude as a terminal would
        // (as explain.rs starts it); exec hands it the pipes.
        let quoted: Vec<String> = args.iter().map(|a| shell_quote(a)).collect();
        let line = format!("command -v claude >/dev/null 2>&1 || {{ echo 'Claude Code is not installed on this Mac.' >&2; exit 127; }}; exec claude {}", quoted.join(" "));
        let mut command = Command::new(crate::paths::shell());
        command.args(["-l", "-i", "-c", &line]).current_dir(&folder).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        for (key, _) in std::env::vars() {
            if key == "CLAUDECODE" || key.starts_with("CLAUDE_CODE_") {
                command.env_remove(key);
            }
        }
        let mut child = command.spawn().map_err(|e| format!("Couldn't start claude: {e}"))?;
        self.stdin = child.stdin.take();
        let generation = {
            let mut g = self.generation.lock().map_err(|_| "poisoned")?;
            *g += 1;
            *g
        };
        let stdout = child.stdout.take();
        let mut stderr = child.stderr.take();
        let events = self.events.clone();
        let current = self.generation.clone();
        std::thread::spawn(move || {
            let push = |event: Event| {
                if current.lock().map(|g| *g == generation).unwrap_or(false) {
                    if let Ok(mut q) = events.lock() {
                        q.push_back(event);
                    }
                }
            };
            if let Some(stdout) = stdout {
                for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                    let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
                    for event in parse(&value) {
                        push(event);
                    }
                }
            }
            let mut errors = String::new();
            if let Some(stderr) = stderr.as_mut() {
                let _ = stderr.read_to_string(&mut errors);
            }
            let lines: Vec<&str> = errors.lines().filter(|l| !l.trim().is_empty()).collect();
            let tail = lines[lines.len().saturating_sub(3)..].join("\n");
            push(Event::Exited(if tail.is_empty() { "claude stopped.".into() } else { tail }));
        });
        self.child = Some(child);
        Ok(())
    }

    fn write(&mut self, value: &Value) -> Result<(), String> {
        if !self.running() {
            self.start()?;
        }
        let stdin = self.stdin.as_mut().ok_or("claude isn't running")?;
        let mut line = value.to_string();
        line.push('\n');
        stdin.write_all(line.as_bytes()).and_then(|_| stdin.flush()).map_err(|e| format!("Couldn't reach claude: {e}"))
    }

    /// Sends a message (or `/compact`) as the user.
    pub fn send(&mut self, text: &str) -> Result<(), String> {
        let value = json!({ "type": "user", "message": { "role": "user", "content": text } });
        self.write(&value)?;
        self.busy = true;
        Ok(())
    }

    /// Answers a permission request: allowed (with the input unchanged) or not.
    pub fn answer(&mut self, request: &str, allow: bool, input: &Value) -> Result<(), String> {
        let response = if allow { json!({ "behavior": "allow", "updatedInput": input }) } else { json!({ "behavior": "deny", "message": "The user declined this. Ask them, or carry on without it." }) };
        self.write(&json!({ "type": "control_response", "response": { "subtype": "success", "request_id": request, "response": response } }))
    }

    /// Stops the turn in progress, as Esc does.
    pub fn interrupt(&mut self) {
        if self.running() {
            let id = uuid::Uuid::new_v4().to_string();
            let _ = self.write(&json!({ "type": "control_request", "request_id": id, "request": { "subtype": "interrupt" } }));
        }
    }

    /// Ends the process (it resumes on the next message).
    pub fn stop(&mut self) {
        if let Ok(mut g) = self.generation.lock() {
            *g += 1;
        }
        self.stdin = None;
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.busy = false;
    }

    /// A new conversation: the process ends and the next message starts afresh.
    pub fn new_conversation(&mut self) {
        self.stop();
        self.profile.session = Some(uuid::Uuid::new_v4().to_string());
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.stop();
    }
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Whether claude has a transcript for the conversation, so `--resume` works.
fn transcript_exists(id: &str) -> bool {
    let projects = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default().join(".claude/projects");
    std::fs::read_dir(projects).map(|dirs| dirs.flatten().any(|d| d.path().join(format!("{id}.jsonl")).exists())).unwrap_or(false)
}

/// claude's stream-json line, as the events the window wants.
pub fn parse(value: &Value) -> Vec<Event> {
    let mut out = Vec::new();
    match value["type"].as_str() {
        Some("stream_event") => {
            let event = &value["event"];
            if event["type"] == "content_block_delta" && event["delta"]["type"] == "text_delta" && value["parent_tool_use_id"].is_null() {
                if let Some(text) = event["delta"]["text"].as_str() {
                    out.push(Event::Delta(text.to_string()));
                }
            }
        }
        Some("assistant") if value["parent_tool_use_id"].is_null() => {
            let usage = &value["message"]["usage"];
            let context = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].iter().filter_map(|k| usage[*k].as_u64()).sum::<u64>();
            if context > 0 {
                out.push(Event::Context(context));
            }
            for block in value["message"]["content"].as_array().into_iter().flatten() {
                match block["type"].as_str() {
                    Some("text") => out.push(Event::Text(block["text"].as_str().unwrap_or_default().to_string())),
                    Some("tool_use") => out.push(Event::Tool { id: block["id"].as_str().unwrap_or_default().into(), name: block["name"].as_str().unwrap_or_default().into(), input: block["input"].clone() }),
                    _ => {}
                }
            }
        }
        Some("user") => {
            for block in value["message"]["content"].as_array().into_iter().flatten() {
                if block["type"] == "tool_result" {
                    out.push(Event::ToolDone { id: block["tool_use_id"].as_str().unwrap_or_default().into(), failed: block["is_error"].as_bool().unwrap_or(false) });
                }
            }
        }
        Some("control_request") if value["request"]["subtype"] == "can_use_tool" => {
            out.push(Event::Ask {
                request: value["request_id"].as_str().unwrap_or_default().into(),
                tool: value["request"]["tool_name"].as_str().unwrap_or_default().into(),
                input: value["request"]["input"].clone(),
            });
        }
        Some("system") => match value["subtype"].as_str() {
            Some("status") => out.push(Event::Status(value["status"].as_str().map(str::to_string))),
            Some("compact_boundary") => {
                let m = &value["compact_metadata"];
                out.push(Event::Compacted { before: m["pre_tokens"].as_u64().unwrap_or(0), after: m["post_tokens"].as_u64().unwrap_or(0) });
                if let Some(after) = m["post_tokens"].as_u64() {
                    out.push(Event::Context(after));
                }
            }
            _ => {}
        },
        Some("result") => {
            let failed = value["is_error"].as_bool().unwrap_or(false) || value["subtype"].as_str().is_some_and(|s| s != "success");
            let error = failed.then(|| value["result"].as_str().or(value["subtype"].as_str()).unwrap_or("The turn failed.").to_string());
            out.push(Event::Done { error });
        }
        _ => {}
    }
    out
}

/// A tool call in a line: the tool and what it was given.
pub fn summarize(tool: &str, input: &Value) -> String {
    let field = |k: &str| input[k].as_str().map(str::to_string);
    let short = |s: String| if s.chars().count() > 140 { format!("{}...", s.chars().take(140).collect::<String>()) } else { s };
    let detail = match tool {
        "Bash" => field("command"),
        "Read" | "Write" | "Edit" | "NotebookEdit" => field("file_path"),
        "Grep" | "Glob" => field("pattern"),
        "WebFetch" => field("url"),
        "WebSearch" => field("query"),
        "Task" | "Agent" => field("description"),
        _ => None,
    };
    let name = tool.strip_prefix("mcp__gannin__").map(|n| n.replace('_', " ")).unwrap_or_else(|| tool.to_string());
    match detail {
        Some(d) => format!("{name}: {}", short(d.lines().next().unwrap_or_default().to_string())),
        None => {
            let args = input.as_object().map(|o| o.iter().map(|(k, v)| format!("{k} {}", v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string()))).collect::<Vec<_>>().join(", ")).unwrap_or_default();
            if args.is_empty() { name } else { format!("{name}: {}", short(args)) }
        }
    }
}

/// The key Allow always records for a tool call.
pub fn always_key(tool: &str, input: &Value) -> String {
    match tool {
        "Bash" => format!("Bash({})", input["command"].as_str().and_then(|c| c.split_whitespace().next()).unwrap_or_default()),
        _ => tool.to_string(),
    }
}

/// Tools that only read, which never need a card. Gannin's own read tools
/// count; sending to a session never does.
pub fn read_only(tool: &str, input: &Value) -> bool {
    match tool {
        "Read" | "Grep" | "Glob" | "LS" | "TodoWrite" | "WebSearch" => true,
        "mcp__gannin__list_sessions" | "mcp__gannin__read_session" | "mcp__gannin__workload" | "mcp__gannin__list_skills" | "mcp__gannin__waiting" | "mcp__gannin__notes" | "mcp__gannin__open_tab" | "mcp__gannin__show" => {
            // Writing notes is Marra's own file; still read-only for the world.
            true
        }
        "Bash" => input["command"].as_str().is_some_and(read_only_command),
        _ => false,
    }
}

/// A shell command that can only read: one program from a short list, with
/// nothing that chains, redirects or substitutes.
fn read_only_command(command: &str) -> bool {
    if command.contains([';', '&', '|', '>', '<', '`', '$', '\n']) {
        return false;
    }
    let words: Vec<&str> = command.split_whitespace().collect();
    match words.as_slice() {
        [] => false,
        ["ls" | "cat" | "head" | "tail" | "wc" | "rg" | "grep" | "find" | "pwd" | "date" | "which" | "echo", rest @ ..] => !rest.iter().any(|w| *w == "-delete" || w.starts_with("-exec")),
        ["git", sub, ..] => matches!(*sub, "status" | "log" | "diff" | "show" | "branch" | "rev-parse" | "ls-files" | "blame"),
        ["gh", "pr" | "issue" | "run" | "repo" | "release", sub, ..] => matches!(*sub, "view" | "list" | "diff" | "checks" | "status"),
        ["gh", "search", ..] => true,
        _ => false,
    }
}

/// Marra's standing instructions, appended to claude's own.
pub fn system_prompt() -> String {
    let notes = std::fs::read_to_string(dir().join("marra-notes.md")).unwrap_or_default();
    let notes = if notes.trim().is_empty() { String::new() } else { format!("\n\nThe user's notes for you (marra-notes.md; keep them up to date with the notes tool when they tell you a preference):\n\n{}", notes.trim()) };
    format!(
        "You are Marra, the user's assistant inside Gannin, a Mac app for their engineering work: Claude Code sessions (building and reviewing), pull requests, issues and harnesses across their GitHub orgs. Your job is attention: they run several streams at once and lose track of what needs them. Keep that list for them, say what needs doing, and answer ad hoc questions.\n\n\
How to reply:\n\
- Lead with the answer or the verdict, never with what you did. The first sentence should stand on its own, as something you could say out loud.\n\
- Be short. Put detail after the first line, in Markdown, only when it helps.\n\
- Never end with \"let me know if\". Ask only when there is a real decision for them.\n\n\
Gannin's tools (the gannin MCP server) are the truth about sessions and work: always call them rather than relying on what you remember from earlier in the conversation, which may have been compacted. Use list_sessions or waiting before saying what needs them; read_session before saying what a session is doing; open_tab to bring something forward when they ask to see it. Sending anything to a session asks them first.\n\n\
Never write to GitHub (comments, reviews, merges, labels) unless they ask for that exact thing; Gannin confirms every write with them.{notes}"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_only_commands() {
        assert!(read_only_command("git log --oneline -5"));
        assert!(read_only_command("gh pr view 12 --repo a/b"));
        assert!(!read_only_command("git push"));
        assert!(!read_only_command("ls; rm -rf x"));
        assert!(!read_only_command("find . -delete"));
        assert!(!read_only_command("cat x > y"));
    }

    #[test]
    fn parses_permission_requests() {
        let line: Value = serde_json::from_str(r#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/a"}}}"#).unwrap();
        match parse(&line).as_slice() {
            [Event::Ask { request, tool, .. }] => assert_eq!((request.as_str(), tool.as_str()), ("r1", "Write")),
            other => panic!("{other:?}"),
        }
    }
}
