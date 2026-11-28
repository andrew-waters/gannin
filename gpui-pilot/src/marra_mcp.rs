//! Gannin as Marra's toolbox: an MCP server (streamable HTTP, JSON
//! replies only) on 127.0.0.1, behind a token made at launch and given to
//! Marra's claude in its `--mcp-config`. Nothing listens beyond this Mac.
//!
//! The server thread only parses; each tool call is handed to the app's
//! main thread (`Call`), which has the live windows and sessions, and the
//! reply comes back on a channel. A call that waits on the user (sending to
//! a session) waits here too, up to `PATIENCE`.

use serde_json::{json, Value};
use std::collections::HashSet;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::Duration;

/// How long a tool call may wait on the app (and the user).
const PATIENCE: Duration = Duration::from_secs(15 * 60);

/// A tool call for the main thread to run.
pub struct Call {
    pub tool: String,
    pub args: Value,
    pub reply: Sender<Result<String, String>>,
}

/// The tools, as `tools/list` gives them.
pub fn tools() -> Value {
    let id = json!({ "type": "string", "description": "The session's id, as list_sessions gives it" });
    json!([
        { "name": "list_sessions", "description": "Every Claude Code session open in Gannin, in every window: id, title, kind (work, review, ask, quick change, plan, terminal), state (working, needs you, your turn, ended), how long it has been in that state, its harness folder, the server it runs on, and its issue or PR. Call this before saying what's going on.", "inputSchema": { "type": "object", "properties": {} } },
        { "name": "waiting", "description": "What needs the user now, most urgent first: sessions blocked on them, reviews ready to post, sessions whose turn it is, review requests, and their PRs that need something (failing checks, changes requested, conflicts, ready to merge).", "inputSchema": { "type": "object", "properties": {} } },
        { "name": "read_session", "description": "What a session has been doing: the last messages of its conversation (or the end of its terminal screen for a plain terminal).", "inputSchema": { "type": "object", "properties": { "id": id, "messages": { "type": "integer", "description": "How many recent messages, default 12" }, "since": { "type": "string", "description": "An RFC 3339 time: every message after it instead (up to 150, each shortened), for summarising what happened since then" } }, "required": ["id"] } },
        { "name": "open_tab", "description": "Brings the Gannin window holding a session forward, on that session's tab, for the user to look at.", "inputSchema": { "type": "object", "properties": { "id": id }, "required": ["id"] } },
        { "name": "workload", "description": "The user's pull requests and review requests across their orgs, with each PR's state, and issues assigned to them.", "inputSchema": { "type": "object", "properties": {} } },
        { "name": "list_skills", "description": "The harnesses Gannin knows and the skills each offers (skills/*.md), for choosing where to answer a data question or run an investigation.", "inputSchema": { "type": "object", "properties": {} } },
        { "name": "send_to_session", "description": "Types a message into a session's Claude Code, as if the user had. Gannin shows the user a card first and only sends if they say so; the reply says whether it went.", "inputSchema": { "type": "object", "properties": { "id": id, "text": { "type": "string" } }, "required": ["id", "text"] } },
        { "name": "start_errand", "description": "Starts a question or an investigation in a harness: a separate read-only Claude Code worker with that harness's skills and access, shown to the user as a thread of its own. Use for data questions (ClickHouse, Mongo, analytics) and bug investigations, rather than answering them yourself.", "inputSchema": { "type": "object", "properties": { "kind": { "type": "string", "enum": ["question", "investigation"] }, "ask": { "type": "string", "description": "The question or what to investigate, in the user's words plus anything you know" }, "harness": { "type": "string", "description": "The harness, exactly as list_skills names it (server:/path for one on a server)" }, "skills": { "type": "array", "items": { "type": "string" } } }, "required": ["kind", "ask", "harness"] } },
        { "name": "notes", "description": "Reads your notes about the user (their preferences, standing instructions); with text, replaces them. Keep them short.", "inputSchema": { "type": "object", "properties": { "text": { "type": "string" } } } }
    ])
}

/// Starts the server; returns its port, token and the calls it receives.
pub fn serve() -> Option<(u16, String, Receiver<Call>)> {
    let listener = TcpListener::bind("127.0.0.1:0").ok()?;
    let port = listener.local_addr().ok()?.port();
    let token = format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple());
    let (tx, rx) = channel::<Call>();
    let expected = format!("Bearer {token}");
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let tx = tx.clone();
            let expected = expected.clone();
            std::thread::spawn(move || {
                let _ = handle(stream, &expected, &tx);
            });
        }
    });
    Some((port, token, rx))
}

/// An HTTP request, as much of it as Gannin's servers need.
pub struct Request {
    pub method: String,
    pub path: String,
    /// Header names in lower case.
    pub headers: std::collections::HashMap<String, String>,
    pub body: Vec<u8>,
}

/// Reads one request (Content-Length bodies only, up to 4 MB).
pub fn read_request(stream: &TcpStream) -> std::io::Result<Request> {
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    // Lines and headers are capped: this is read before anyone's checked.
    let too_long = || std::io::Error::new(std::io::ErrorKind::InvalidData, "request too large");
    let mut request_line = String::new();
    (&mut reader).take(8192).read_line(&mut request_line)?;
    let mut headers = std::collections::HashMap::new();
    for count in 0.. {
        if count > 100 {
            return Err(too_long());
        }
        let mut line = String::new();
        if (&mut reader).take(8192).read_line(&mut line)? == 0 {
            break;
        }
        if !line.ends_with('\n') {
            return Err(too_long());
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_string());
        }
    }
    let length: usize = headers.get("content-length").and_then(|l| l.parse().ok()).unwrap_or(0);
    let mut body = vec![0u8; length.min(4 << 20)];
    reader.read_exact(&mut body)?;
    let mut parts = request_line.split_whitespace();
    Ok(Request { method: parts.next().unwrap_or_default().to_string(), path: parts.next().unwrap_or_default().to_string(), headers, body })
}

fn handle(mut stream: TcpStream, expected: &str, calls: &Sender<Call>) -> std::io::Result<()> {
    let request = read_request(&stream)?;
    if request.headers.get("authorization").map(String::as_str) != Some(expected) {
        return respond(&mut stream, 401, "text/plain", "unauthorized");
    }
    if request.method != "POST" {
        // No server-to-client stream: everything is a reply to a POST.
        return respond(&mut stream, if request.method == "DELETE" { 200 } else { 405 }, "text/plain", "");
    }
    let Ok(message) = serde_json::from_slice::<Value>(&request.body) else {
        return respond(&mut stream, 400, "text/plain", "bad json");
    };
    // A notification (no id) is acknowledged without a body.
    if message.get("id").is_none() {
        return respond(&mut stream, 202, "text/plain", "");
    }
    let reply = rpc(&message, calls);
    respond(&mut stream, 200, "application/json", &reply.to_string())
}

fn rpc(message: &Value, calls: &Sender<Call>) -> Value {
    let id = message["id"].clone();
    let result = match message["method"].as_str() {
        Some("initialize") => json!({
            "protocolVersion": message["params"]["protocolVersion"].as_str().unwrap_or("2025-06-18"),
            "capabilities": { "tools": {} },
            "serverInfo": { "name": "gannin", "version": env!("CARGO_PKG_VERSION") }
        }),
        Some("ping") => json!({}),
        Some("tools/list") => json!({ "tools": tools() }),
        Some("tools/call") => {
            let (reply, answer) = channel();
            let tool = message["params"]["name"].as_str().unwrap_or_default().to_string();
            let args = message["params"]["arguments"].clone();
            let outcome = calls.send(Call { tool, args, reply }).map_err(|_| "Gannin isn't listening.".to_string()).and_then(|_| answer.recv_timeout(PATIENCE).map_err(|_| "Gannin didn't answer in time.".to_string())).and_then(|r| r);
            match outcome {
                Ok(text) => json!({ "content": [{ "type": "text", "text": text }] }),
                Err(error) => json!({ "content": [{ "type": "text", "text": error }], "isError": true }),
            }
        }
        _ => return json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": "Method not found" } }),
    };
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

pub fn respond(stream: &mut TcpStream, status: u16, kind: &str, body: &str) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        503 => "Service Unavailable",
        _ => "Method Not Allowed",
    };
    write!(stream, "HTTP/1.1 {status} {reason}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len())?;
    stream.flush()
}

/// A conversation's transcript file, in whichever project folder it is;
/// for a session on a server, the copy its mirror keeps in the session's
/// folder here (`servers::pull`), as claude's own is on the server.
fn transcript_file(claude_id: &str) -> Option<std::path::PathBuf> {
    let projects = std::env::var_os("HOME").map(std::path::PathBuf::from)?.join(".claude/projects");
    let local = std::fs::read_dir(projects).ok().and_then(|dirs| dirs.flatten().map(|d| d.path().join(format!("{claude_id}.jsonl"))).find(|p| p.exists()));
    local.or_else(|| {
        // A launch's folder is named by its ID, which claude's is the lower case of.
        [claude_id.to_uppercase(), claude_id.to_string()].into_iter().map(|id| crate::launch::sessions_dir().join(id).join("transcript.jsonl")).find(|p| p.exists())
    })
}

/// The conversation a session is having: its own ID, else (a plain tab
/// from before tabs had one) the newest transcript Claude Code keeps for
/// its folder on this Mac. None on a server, where the transcript isn't.
pub fn resolve_claude(claude_id: Option<String>, folder: &std::path::Path, on_server: bool) -> Option<String> {
    if claude_id.is_some() || on_server {
        return claude_id;
    }
    // Claude Code names a project's folder after its path, every character
    // but letters and digits made a hyphen.
    let name: String = folder.to_string_lossy().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    let dir = std::env::var_os("HOME").map(std::path::PathBuf::from)?.join(".claude/projects").join(name);
    std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "jsonl"))
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .max_by_key(|(at, _)| *at)
        .and_then(|(_, path)| path.file_stem().map(|s| s.to_string_lossy().into_owned()))
}

/// The transcript's entries that are the conversation itself (not Claude
/// Code's meta lines or subagents'), with when each was written.
fn entries(claude_id: &str) -> Option<Vec<(Option<chrono::DateTime<chrono::Utc>>, Value)>> {
    let text = std::fs::read_to_string(transcript_file(claude_id)?).ok()?;
    Some(
        text.lines()
            .filter_map(|raw| serde_json::from_str::<Value>(raw).ok())
            .filter(|v| v["isMeta"].as_bool() != Some(true) && v["isSidechain"].as_bool() != Some(true))
            .map(|v| (v["timestamp"].as_str().and_then(|t| t.parse().ok()), v))
            .collect(),
    )
}

/// The input of Claude's last AskUserQuestion still waiting for an answer
/// (no tool result for it yet), from its own transcript: subagents
/// working meanwhile don't hide it, as they can the hooks' files.
pub fn pending_question(claude_id: &str) -> Option<Value> {
    let mut pending: Option<(String, Value)> = None;
    for (_, value) in entries(claude_id)? {
        for block in value["message"]["content"].as_array().into_iter().flatten() {
            match block["type"].as_str() {
                Some("tool_use") if block["name"] == "AskUserQuestion" => {
                    pending = Some((block["id"].as_str().unwrap_or_default().to_string(), block["input"].clone()));
                }
                Some("tool_result") => {
                    if pending.as_ref().is_some_and(|(id, _)| block["tool_use_id"].as_str() == Some(id.as_str())) {
                        pending = None;
                    }
                }
                _ => {}
            }
        }
        // The room typed instead of answering: the question's gone.
        if value["type"] == "user" && value["message"]["content"].as_str().is_some_and(|t| !wrapper(t)) {
            pending = None;
        }
    }
    pending.map(|(_, input)| input)
}

/// Claude Code's own wrappers (command output, reminders) aren't the user's words.
fn wrapper(text: &str) -> bool {
    text.trim_start().starts_with('<') || text.trim().is_empty()
}

/// The messages of a Claude Code conversation after `since` (all of them
/// when None), the last `count` of them, each clipped to `each`: who said
/// it ("User" or "Claude") and the text, a tool call as one line ("tool").
pub fn transcript_since(claude_id: &str, since: Option<chrono::DateTime<chrono::Utc>>, count: usize, each: usize) -> Option<Vec<(String, String)>> {
    let mut lines: Vec<(String, String)> = Vec::new();
    for (at, value) in entries(claude_id)? {
        if since.is_some_and(|since| at.is_none_or(|at| at <= since)) {
            continue;
        }
        let who = match value["type"].as_str() {
            Some("user") => "User",
            Some("assistant") => "Claude",
            _ => continue,
        };
        let content = &value["message"]["content"];
        if let Some(s) = content.as_str() {
            if !wrapper(s) {
                lines.push((who.into(), clip(s, each)));
            }
            continue;
        }
        for block in content.as_array().into_iter().flatten() {
            match block["type"].as_str() {
                Some("text") => {
                    let text = block["text"].as_str().unwrap_or_default();
                    if !wrapper(text) {
                        lines.push((who.into(), clip(text, each)));
                    }
                }
                Some("tool_use") => lines.push(("tool".into(), crate::marra::summarize(block["name"].as_str().unwrap_or_default(), &block["input"]))),
                _ => {}
            }
        }
    }
    let start = lines.len().saturating_sub(count);
    Some(lines.split_off(start))
}

/// The last `count` messages of a Claude Code conversation, from its
/// transcript.
pub fn transcript_messages(claude_id: &str, count: usize) -> Option<Vec<(String, String)>> {
    transcript_since(claude_id, None, count, 2000)
}

/// What a session did after `since`, read from its transcript with no
/// model call: for the top of its thread in Marra.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Digest {
    /// What the user typed, in order.
    pub prompts: Vec<String>,
    /// Claude's last words.
    pub last_reply: Option<String>,
    /// Files it edited or wrote, relative to where it runs.
    pub files: Vec<String>,
    pub commands: usize,
    pub tools: usize,
    /// Pull requests it opened (their links).
    pub prs: Vec<String>,
    /// A question or plan of Claude's not yet answered.
    pub waiting: Option<String>,
}

impl Digest {
    pub fn is_empty(&self) -> bool {
        self.prompts.is_empty() && self.last_reply.is_none() && self.tools == 0
    }
}

pub fn digest(claude_id: &str, since: Option<chrono::DateTime<chrono::Utc>>) -> Option<Digest> {
    let mut d = Digest::default();
    // Tool calls whose results matter: a PR being made, a question asked.
    let mut pr_calls: HashSet<String> = HashSet::new();
    let mut open_question: Option<(String, String)> = None;
    for (at, value) in entries(claude_id)? {
        if since.is_some_and(|since| at.is_none_or(|at| at <= since)) {
            continue;
        }
        let cwd = value["cwd"].as_str().unwrap_or_default().to_string();
        let content = &value["message"]["content"];
        match value["type"].as_str() {
            Some("user") => {
                if let Some(text) = content.as_str() {
                    if !wrapper(text) {
                        d.prompts.push(clip(text, 300));
                    }
                }
                for block in content.as_array().into_iter().flatten() {
                    match block["type"].as_str() {
                        Some("text") => {
                            let text = block["text"].as_str().unwrap_or_default();
                            if !wrapper(text) {
                                d.prompts.push(clip(text, 300));
                            }
                        }
                        Some("tool_result") => {
                            let id = block["tool_use_id"].as_str().unwrap_or_default();
                            if open_question.as_ref().is_some_and(|(q, _)| q == id) {
                                open_question = None;
                            }
                            if pr_calls.remove(id) {
                                let result = block["content"].to_string();
                                if let Some(url) = pr_link(&result) {
                                    if !d.prs.contains(&url) {
                                        d.prs.push(url);
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
            Some("assistant") => {
                for block in content.as_array().into_iter().flatten() {
                    match block["type"].as_str() {
                        Some("text") => {
                            let text = block["text"].as_str().unwrap_or_default();
                            if !wrapper(text) {
                                d.last_reply = Some(text.trim().to_string());
                            }
                        }
                        Some("tool_use") => {
                            d.tools += 1;
                            let id = block["id"].as_str().unwrap_or_default().to_string();
                            let input = &block["input"];
                            match block["name"].as_str().unwrap_or_default() {
                                "Edit" | "Write" | "MultiEdit" | "NotebookEdit" => {
                                    if let Some(path) = input["file_path"].as_str().or(input["notebook_path"].as_str()) {
                                        let shown = path.strip_prefix(&format!("{cwd}/")).unwrap_or(path).to_string();
                                        if !d.files.contains(&shown) {
                                            d.files.push(shown);
                                        }
                                    }
                                }
                                "Bash" => {
                                    d.commands += 1;
                                    let command = input["command"].as_str().unwrap_or_default();
                                    if command.contains("gh pr create") || (command.contains("gh api") && command.contains("/pulls")) {
                                        pr_calls.insert(id);
                                    }
                                }
                                "AskUserQuestion" => {
                                    let question = input["questions"][0]["question"].as_str().unwrap_or("A question").to_string();
                                    open_question = Some((id, question));
                                }
                                "ExitPlanMode" => open_question = Some((id, "A plan to approve".into())),
                                name if name.ends_with("create_pull_request") => {
                                    pr_calls.insert(id);
                                }
                                _ => {}
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    d.waiting = open_question.map(|(_, q)| q);
    Some(d)
}

/// The first pull request link in a tool's result.
fn pr_link(text: &str) -> Option<String> {
    let start = text.find("https://github.com/")?;
    let rest = &text[start..];
    let end = rest.find(|c: char| c.is_whitespace() || c == '"' || c == '\\' || c == ')').unwrap_or(rest.len());
    let url = &rest[..end];
    let tail = url.split("/pull/").nth(1)?;
    let number: String = tail.chars().take_while(|c| c.is_ascii_digit()).collect();
    (!number.is_empty()).then(|| format!("{}/pull/{number}", url.split("/pull/").next().unwrap_or_default()))
}

/// Messages as text for a model to read.
pub fn as_text(lines: Vec<(String, String)>) -> String {
    lines.into_iter().map(|(who, text)| if who == "tool" { format!("Claude used {text}") } else { format!("{who}: {text}") }).collect::<Vec<_>>().join("\n\n")
}

fn clip(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.trim().to_string()
    } else {
        format!("{}...", s.chars().take(max).collect::<String>().trim())
    }
}

/// The harnesses Gannin knows (from its sessions) and their skills.
/// A harness's skills, from this Mac's checkout of the same repo: each
/// one's name and the description its front matter gives (may be empty).
pub fn harness_skills(place: &HarnessPlace) -> Vec<(String, String)> {
    let harness = place.local.clone().unwrap_or_else(|| place.path.clone());
    let mut skills: Vec<(String, String)> = Vec::new();
    for folder in ["skills", ".claude/skills"] {
        for entry in std::fs::read_dir(harness.join(folder)).into_iter().flatten().flatten() {
            let path = entry.path();
            let name = path.file_stem().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            let file = if path.is_dir() { path.join("SKILL.md") } else { path.clone() };
            let about = std::fs::read_to_string(&file).ok().map(|t| description(&t)).unwrap_or_default();
            if !name.starts_with('.') && !skills.iter().any(|(n, _)| *n == name) {
                skills.push((name, about));
            }
        }
    }
    skills.sort();
    skills
}

/// A skill's `description:` from its front matter, as one line: a folded
/// or literal block (`>`, `>-`, `|`) read from the indented lines after it.
fn description(text: &str) -> String {
    let mut lines = text.lines().skip_while(|l| !l.trim_start().starts_with("description:"));
    let Some(first) = lines.next() else { return String::new() };
    let value = first.trim_start().trim_start_matches("description:").trim();
    let value = if value.is_empty() || value.starts_with(['>', '|']) {
        lines.take_while(|l| l.starts_with([' ', '\t']) || l.trim().is_empty()).map(str::trim).filter(|l| !l.is_empty()).collect::<Vec<_>>().join(" ")
    } else {
        value.to_string()
    };
    value.trim_matches(['"', '\'']).to_string()
}

pub fn skills() -> String {
    let mut out = Vec::new();
    for place in harness_places() {
        let names: Vec<String> = harness_skills(&place).into_iter().map(|(name, about)| if about.is_empty() { format!("  - {name}") } else { format!("  - {name}: {}", clip(&about, 160)) }).collect();
        out.push(format!("{}\n{}", place.label(), if names.is_empty() { "  (no skills)".to_string() } else { names.join("\n") }));
    }
    if out.is_empty() {
        "No harnesses yet: Gannin knows a harness once a session has run in it.".into()
    } else {
        out.join("\n\n")
    }
}

/// A harness Gannin has run sessions in, and where: on a server when one
/// has run there (where sessions are meant to run), else on this Mac.
#[derive(Clone, Debug)]
pub struct HarnessPlace {
    pub path: std::path::PathBuf,
    pub server: Option<crate::servers::Server>,
    /// A checkout here of the same repo, to read its skills and prompts.
    pub local: Option<std::path::PathBuf>,
}

impl HarnessPlace {
    /// As Marra names it: `server:/path` on a server, else the path.
    pub fn label(&self) -> String {
        match &self.server {
            Some(server) => format!("{}:{}", server.name(), self.path.display()),
            None => self.path.display().to_string(),
        }
    }
}

/// Each harness repo once, where its errands should run.
pub fn harness_places() -> Vec<HarnessPlace> {
    let launches = crate::launch::saved();
    let mut repos: Vec<String> = launches.iter().map(|l| l.harness_repo.to_lowercase()).filter(|r| !r.is_empty()).collect();
    repos.sort();
    repos.dedup();
    repos
        .into_iter()
        .filter_map(|repo| {
            let of_repo = || launches.iter().filter(|l| l.harness_repo.eq_ignore_ascii_case(&repo));
            let local = of_repo().filter(|l| l.server.is_none()).map(|l| l.harness_path.clone()).find(|h| h.exists());
            // Newest first, as `saved` lists them.
            match of_repo().find(|l| l.server.is_some()) {
                Some(l) => Some(HarnessPlace { path: l.harness_path.clone(), server: l.server.clone(), local }),
                None => local.clone().map(|path| HarnessPlace { path, server: None, local }),
            }
        })
        .collect()
}

/// The harness folders Gannin knows on this Mac (from its sessions).
pub fn harnesses() -> Vec<std::path::PathBuf> {
    let mut list: Vec<std::path::PathBuf> = crate::launch::saved().into_iter().filter(|l| l.server.is_none()).map(|l| l.harness_path).filter(|h| h.exists()).collect();
    list.sort();
    list.dedup();
    list
}

/// A saved prompt Marra offers as a / command.
#[derive(Clone)]
pub struct SavedCommand {
    pub name: String,
    pub about: String,
    pub body: String,
    /// The harness it's from; None for one of the user's own.
    pub harness: Option<String>,
}

/// The user's own (`~/.gannin/marra/commands/*.md`) and the team's
/// (`prompts/*.md` in a harness with `use: marra` in their front matter).
pub fn saved_commands() -> Vec<SavedCommand> {
    let mut out = Vec::new();
    let mut read = |folder: std::path::PathBuf, harness: Option<String>, need_use: bool| {
        for entry in std::fs::read_dir(&folder).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("md") {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&path) else { continue };
            let (front, body) = match text.strip_prefix("---\n").and_then(|rest| rest.split_once("\n---")) {
                Some((front, body)) => (front.to_string(), body.trim_start_matches('-').trim().to_string()),
                None => (String::new(), text.trim().to_string()),
            };
            let field = |key: &str| front.lines().find_map(|l| l.trim().strip_prefix(&format!("{key}:")).map(|v| v.trim().trim_matches('"').to_string()));
            if need_use && !field("use").is_some_and(|u| u.split(|c: char| c == ',' || c.is_whitespace() || c == '[' || c == ']').any(|w| w == "marra")) {
                continue;
            }
            let name = path.file_stem().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            if body.is_empty() || name.is_empty() {
                continue;
            }
            let about = field("description").unwrap_or_else(|| clip(body.lines().next().unwrap_or_default(), 70));
            out.push(SavedCommand { name, about, body, harness: harness.clone() });
        }
    };
    read(crate::marra::dir().join("commands"), None, false);
    for harness in harnesses() {
        let label = harness.file_name().map(|n| n.to_string_lossy().into_owned());
        read(harness.join("prompts"), label, true);
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out.dedup_by(|a, b| a.name == b.name);
    out
}

