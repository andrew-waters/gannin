//! Gannin as Marra's toolbox: an MCP server (streamable HTTP, JSON
//! replies only) on 127.0.0.1, behind a token made at launch and given to
//! Marra's claude in its `--mcp-config`. Nothing listens beyond this Mac.
//!
//! The server thread only parses; each tool call is handed to the app's
//! main thread (`Call`), which has the live windows and sessions, and the
//! reply comes back on a channel. A call that waits on the user (sending to
//! a session) waits here too, up to `PATIENCE`.

use serde_json::{json, Value};
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
        { "name": "read_session", "description": "What a session has been doing: the last messages of its conversation (or the end of its terminal screen for a plain terminal).", "inputSchema": { "type": "object", "properties": { "id": id, "messages": { "type": "integer", "description": "How many recent messages, default 12" } }, "required": ["id"] } },
        { "name": "open_tab", "description": "Brings the Gannin window holding a session forward, on that session's tab, for the user to look at.", "inputSchema": { "type": "object", "properties": { "id": id }, "required": ["id"] } },
        { "name": "workload", "description": "The user's pull requests and review requests across their orgs, with each PR's state, and issues assigned to them.", "inputSchema": { "type": "object", "properties": {} } },
        { "name": "list_skills", "description": "The harnesses Gannin knows and the skills each offers (skills/*.md), for choosing where to answer a data question or run an investigation.", "inputSchema": { "type": "object", "properties": {} } },
        { "name": "send_to_session", "description": "Types a message into a session's Claude Code, as if the user had. Gannin shows the user a card first and only sends if they say so; the reply says whether it went.", "inputSchema": { "type": "object", "properties": { "id": id, "text": { "type": "string" } }, "required": ["id", "text"] } },
        { "name": "start_errand", "description": "Starts a question or an investigation in a harness: a separate read-only Claude Code worker with that harness's skills and access, shown to the user as a thread of its own. Use for data questions (ClickHouse, Mongo, analytics) and bug investigations, rather than answering them yourself.", "inputSchema": { "type": "object", "properties": { "kind": { "type": "string", "enum": ["question", "investigation"] }, "ask": { "type": "string", "description": "The question or what to investigate, in the user's words plus anything you know" }, "harness": { "type": "string", "description": "The harness folder, from list_skills" }, "skills": { "type": "array", "items": { "type": "string" } } }, "required": ["kind", "ask", "harness"] } },
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

fn handle(mut stream: TcpStream, expected: &str, calls: &Sender<Call>) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut request_line = String::new();
    reader.read_line(&mut request_line)?;
    let mut length = 0usize;
    let mut authorized = false;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            break;
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            let (name, value) = (name.trim().to_ascii_lowercase(), value.trim());
            if name == "content-length" {
                length = value.parse().unwrap_or(0);
            } else if name == "authorization" {
                authorized = value == expected;
            }
        }
    }
    let method = request_line.split_whitespace().next().unwrap_or_default().to_string();
    if !authorized {
        return respond(&mut stream, 401, "text/plain", "unauthorized");
    }
    if method != "POST" {
        // No server-to-client stream: everything is a reply to a POST.
        return respond(&mut stream, if method == "DELETE" { 200 } else { 405 }, "text/plain", "");
    }
    let mut body = vec![0u8; length.min(4 << 20)];
    reader.read_exact(&mut body)?;
    let Ok(message) = serde_json::from_slice::<Value>(&body) else {
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

fn respond(stream: &mut TcpStream, status: u16, kind: &str, body: &str) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        _ => "Method Not Allowed",
    };
    write!(stream, "HTTP/1.1 {status} {reason}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len())?;
    stream.flush()
}

/// The last `count` messages of a Claude Code conversation, from its
/// transcript: who said it ("User" or "Claude") and the text, a tool call
/// as one line ("tool").
pub fn transcript_messages(claude_id: &str, count: usize) -> Option<Vec<(String, String)>> {
    let projects = std::env::var_os("HOME").map(std::path::PathBuf::from)?.join(".claude/projects");
    let path = std::fs::read_dir(projects).ok()?.flatten().map(|d| d.path().join(format!("{claude_id}.jsonl"))).find(|p| p.exists())?;
    let text = std::fs::read_to_string(path).ok()?;
    let mut lines: Vec<(String, String)> = Vec::new();
    for raw in text.lines() {
        let Ok(value) = serde_json::from_str::<Value>(raw) else { continue };
        if value["isMeta"].as_bool() == Some(true) || value["isSidechain"].as_bool() == Some(true) {
            continue;
        }
        let who = match value["type"].as_str() {
            Some("user") => "User",
            Some("assistant") => "Claude",
            _ => continue,
        };
        let content = &value["message"]["content"];
        if let Some(s) = content.as_str() {
            // Claude Code's own wrappers (command output, reminders) aren't the user's words.
            if !s.trim_start().starts_with('<') {
                lines.push((who.into(), clip(s, 2000)));
            }
            continue;
        }
        for block in content.as_array().into_iter().flatten() {
            match block["type"].as_str() {
                Some("text") => {
                    let text = block["text"].as_str().unwrap_or_default();
                    if !text.trim_start().starts_with('<') && !text.trim().is_empty() {
                        lines.push((who.into(), clip(text, 2000)));
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

/// The same, as text for Marra.
pub fn transcript_tail(claude_id: &str, count: usize) -> Option<String> {
    let lines = transcript_messages(claude_id, count)?;
    Some(lines.into_iter().map(|(who, text)| if who == "tool" { format!("Claude used {text}") } else { format!("{who}: {text}") }).collect::<Vec<_>>().join("\n\n"))
}

fn clip(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.trim().to_string()
    } else {
        format!("{}...", s.chars().take(max).collect::<String>().trim())
    }
}

/// The harnesses Gannin knows (from its sessions) and their skills.
pub fn skills() -> String {
    let mut harnesses: Vec<std::path::PathBuf> = crate::launch::saved().into_iter().filter(|l| l.server.is_none()).map(|l| l.harness_path).collect();
    harnesses.sort();
    harnesses.dedup();
    let mut out = Vec::new();
    for harness in harnesses.into_iter().filter(|h| h.exists()) {
        let mut names: Vec<String> = Vec::new();
        for folder in ["skills", ".claude/skills"] {
            for entry in std::fs::read_dir(harness.join(folder)).into_iter().flatten().flatten() {
                let path = entry.path();
                let name = path.file_stem().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                let file = if path.is_dir() { path.join("SKILL.md") } else { path.clone() };
                let about = std::fs::read_to_string(&file).ok().and_then(|t| t.lines().find(|l| l.trim_start().starts_with("description:")).map(|l| l.trim_start().trim_start_matches("description:").trim().trim_matches('"').to_string())).unwrap_or_default();
                if !name.starts_with('.') {
                    names.push(if about.is_empty() { format!("  - {name}") } else { format!("  - {name}: {}", clip(&about, 160)) });
                }
            }
        }
        names.sort();
        out.push(format!("{}\n{}", harness.display(), if names.is_empty() { "  (no skills)".to_string() } else { names.join("\n") }));
    }
    if out.is_empty() {
        "No harnesses yet: Gannin knows a harness once a session has run in it.".into()
    } else {
        out.join("\n\n")
    }
}
