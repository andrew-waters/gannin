//! Marra's state, one per app (a global entity): the Main conversation,
//! errands (workers in a harness), what needs the user, reminders, Focus
//! and notifications. The windows that show it (`marra_view.rs`) observe it.
//!
//! Gannin's own state (windows, sessions, Your Work) is read live each time,
//! never copied: a session is known by its window and id.

use crate::marra::{self, Engine, Entry, Event, Profile, Saved};
use crate::marra_mcp::{self, Call};
use crate::session::{SessionPage, State};
use crate::shell::Workspace;
use chrono::{DateTime, Local};
use gpui::{App, AppContext, Context, Entity, Global, Task, WindowHandle};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender};
use std::time::{Duration, Instant};

/// Which conversation: Marra's own, or an errand's worker.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Who {
    Main,
    Errand(String),
}

/// A conversation with a claude: its process and its chat as shown.
pub struct Convo {
    pub engine: Engine,
    pub chat: Vec<Entry>,
    /// Text streaming into the bubble being written.
    pub streaming: String,
    /// "compacting" while claude compacts.
    pub status: Option<String>,
    /// Context in use, in tokens.
    pub context: u64,
    /// Permission requests waiting on the user: request id to (tool, input).
    pub asks: HashMap<String, (String, Value)>,
    /// What it's doing, while busy: the last tool it used.
    pub doing: Option<String>,
    log: PathBuf,
}

impl Convo {
    fn new(profile: Profile, log: PathBuf) -> Self {
        let chat = marra::load_chat(&log);
        Self { engine: Engine::new(profile), chat, streaming: String::new(), status: None, context: 0, asks: HashMap::new(), doing: None, log }
    }

    pub fn busy(&self) -> bool {
        self.engine.busy
    }

    /// When it last said something worth reading.
    pub fn activity(&self) -> Option<DateTime<Local>> {
        self.chat.iter().rev().find_map(|e| e.at().and_then(|a| DateTime::parse_from_rfc3339(a).ok())).map(|d| d.with_timezone(&Local))
    }

    pub fn last_line(&self) -> String {
        if self.engine.busy {
            if let Some(doing) = &self.doing {
                return doing.clone();
            }
        }
        self.chat.iter().rev().find_map(|e| e.line()).unwrap_or_default()
    }

    fn save(&self) {
        marra::save_chat(&self.log, &self.chat);
    }

    fn say(&mut self, entry: Entry) {
        self.chat.push(entry);
        self.save();
    }

    pub fn event(&mut self, text: impl Into<String>) {
        self.say(Entry::Event { text: text.into(), at: marra::now() });
    }

    /// Sends a message as the user, recording it.
    pub fn send(&mut self, shown: &str, sent: &str) {
        self.chat.push(Entry::You { text: shown.to_string(), at: marra::now() });
        self.streaming.clear();
        if let Err(error) = self.engine.send(sent) {
            self.chat.push(Entry::Event { text: error, at: marra::now() });
        }
        self.save();
    }

    /// Applies what claude said; returns whether the turn ended.
    fn apply(&mut self, events: Vec<Event>, always: &[String]) -> bool {
        let mut ended = false;
        for event in events {
            match event {
                Event::Delta(text) => self.streaming.push_str(&text),
                Event::Text(text) => {
                    self.streaming.clear();
                    if !text.trim().is_empty() {
                        self.chat.push(Entry::Marra { text: text.trim().to_string(), at: marra::now() });
                    }
                }
                Event::Tool { id, name, input } => {
                    let summary = marra::summarize(&name, &input);
                    self.doing = Some(summary.clone());
                    self.chat.push(Entry::Tool { id, name, summary, failed: false });
                }
                Event::ToolDone { id, failed } => {
                    for entry in self.chat.iter_mut().rev() {
                        if let Entry::Tool { id: tool, failed: f, .. } = entry {
                            if *tool == id {
                                *f = failed;
                                break;
                            }
                        }
                    }
                }
                Event::Ask { request, tool, input } => {
                    if marra::read_only(&tool, &input) || always.contains(&marra::always_key(&tool, &input)) {
                        let _ = self.engine.answer(&request, true, &input);
                    } else {
                        let summary = marra::summarize(&tool, &input);
                        self.chat.push(Entry::Permission { request: request.clone(), tool: tool.clone(), summary, answer: None });
                        self.asks.insert(request, (tool, input));
                        self.save();
                    }
                }
                // Only compacting is worth saying; "requesting" is every call.
                Event::Status(status) => self.status = status.filter(|s| s == "compacting"),
                Event::Compacted { before, after } => self.chat.push(Entry::Event { text: format!("Compacted: {}k tokens down to {}k.", before / 1000, after / 1000), at: marra::now() }),
                Event::Context(tokens) => self.context = tokens,
                Event::Done { error } => {
                    self.streaming.clear();
                    self.doing = None;
                    self.status = None;
                    if let Some(error) = error {
                        self.chat.push(Entry::Event { text: error, at: marra::now() });
                    }
                    ended = true;
                    self.save();
                }
                Event::Exited(message) => {
                    self.streaming.clear();
                    self.doing = None;
                    self.status = None;
                    // Open requests died with the process.
                    for entry in &mut self.chat {
                        if let Entry::Permission { answer: answer @ None, .. } = entry {
                            *answer = Some("Not answered".into());
                        }
                    }
                    self.asks.clear();
                    self.chat.push(Entry::Event { text: format!("Claude stopped: {message} It starts again with the next message."), at: marra::now() });
                    ended = true;
                    self.save();
                }
            }
        }
        ended
    }

    /// Answers a permission card.
    pub fn decide(&mut self, request: &str, allow: bool, always: bool) -> Option<String> {
        let (tool, input) = self.asks.remove(request)?;
        let _ = self.engine.answer(request, allow, &input);
        let label = match (allow, always) {
            (true, true) => "Allowed always",
            (true, false) => "Allowed",
            _ => "Denied",
        };
        for entry in self.chat.iter_mut().rev() {
            if let Entry::Permission { request: r, answer, .. } = entry {
                if r == request {
                    *answer = Some(label.into());
                    break;
                }
            }
        }
        self.save();
        (allow && always).then(|| marra::always_key(&tool, &input))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrandKind {
    Question,
    Investigation,
}

/// An errand as saved, so it comes back after a relaunch.
#[derive(Clone, Serialize, Deserialize)]
pub struct ErrandSaved {
    pub id: String,
    pub kind: ErrandKind,
    pub title: String,
    pub harness: PathBuf,
    pub session: Option<String>,
    pub created: String,
    #[serde(default)]
    pub point: Option<String>,
    #[serde(default)]
    pub needs: Option<NeedsYou>,
    #[serde(default)]
    pub done: bool,
}

/// The reply contract's `needs_you`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NeedsYou {
    pub task: String,
    #[serde(default)]
    pub actions: Vec<String>,
}

pub struct Errand {
    pub saved: ErrandSaved,
    pub convo: Convo,
}

fn errands_file() -> PathBuf {
    marra::dir().join("errands.json")
}

fn errand_log(id: &str) -> PathBuf {
    marra::dir().join("errands").join(format!("{id}.jsonl"))
}

/// A worker's standing brief: read only, and the reply contract.
fn errand_brief(kind: ErrandKind) -> String {
    let job = match kind {
        ErrandKind::Question => "answer a data question using this harness's skills (ClickHouse, Mongo, analytics and so on). Pick the skill that fits, run read-only queries, and check the numbers make sense before answering.",
        ErrandKind::Investigation => "investigate a bug or ticket using this harness's skills: plan with the triage skill if there is one, then follow the evidence (logs, traces, databases, the code). Do not fix anything: report the cause, the evidence, your confidence and what is still unknown.",
    };
    format!(
        "You are a worker for Marra, the user's assistant in Gannin. Your job: {job}\n\n\
You are read only: never edit files, never write to databases, GitHub or any service. Summarise and count customer data; never quote raw documents or personal details in your reply.\n\n\
End every reply with the reply contract, a fenced json block and nothing after it:\n\
```json\n{{\"point\": \"one sentence you could say out loud: the answer or verdict\", \"body\": \"the whole of it in Markdown, any length: figures, evidence, the query and environment used, caveats\", \"needs_you\": null}}\n```\n\
Rules: lead with the answer, never with what you did; point is one sentence; set needs_you to {{\"task\": \"...\", \"actions\": [\"...\"]}} only for a real decision the user must make, never for \"let me know if\"; body is evidence, never needed to act. Text before the json block is not shown, so put everything in point and body."
    )
}

/// The reply contract at the end of a worker's text, if it's there.
pub fn contract(text: &str) -> Option<(String, String, Option<NeedsYou>)> {
    let start = text.rfind("```json")?;
    let rest = &text[start + 7..];
    let end = rest.find("```")?;
    let value: Value = serde_json::from_str(rest[..end].trim()).ok()?;
    let point = value["point"].as_str()?.trim().to_string();
    let body = value["body"].as_str().unwrap_or_default().trim().to_string();
    let needs = serde_json::from_value::<NeedsYou>(value["needs_you"].clone()).ok().filter(|n| !n.task.trim().is_empty());
    Some((point, body, needs))
}

/// A session open in a Gannin window, as Marra sees it.
#[derive(Clone)]
pub struct SessionInfo {
    pub key: String,
    pub window: WindowHandle<Workspace>,
    pub id: u32,
    pub page: Entity<SessionPage>,
    pub title: String,
    /// work, review, ask, quick change, plan, claude or terminal.
    pub kind: String,
    pub state: State,
    pub since: DateTime<Local>,
    pub org: Option<String>,
    pub folder: PathBuf,
    pub server: Option<String>,
    pub subject: Option<String>,
    pub claude_id: Option<String>,
    /// A review with a result not yet posted: findings kept and the verdict.
    pub review_ready: Option<(usize, Option<String>)>,
}

/// Every session open, in every window.
pub fn sessions(cx: &App) -> Vec<SessionInfo> {
    let mut out = Vec::new();
    for handle in cx.windows() {
        let Some(window) = handle.downcast::<Workspace>() else { continue };
        let Ok(workspace) = window.read(cx) else { continue };
        for page in workspace.session_pages() {
            let p = page.read(cx);
            let launch = p.launch.as_ref();
            let kind = match (launch.map(|l| l.flow), p.kind) {
                (Some(flow), _) => flow.label().to_lowercase(),
                (None, crate::session::Kind::Claude) => "claude".into(),
                (None, crate::session::Kind::Shell) => "terminal".into(),
            };
            out.push(SessionInfo {
                key: format!("{}:{}", handle.window_id().as_u64(), p.id),
                window,
                id: p.id,
                page: page.clone(),
                title: p.title(cx),
                kind,
                state: p.state,
                since: p.since,
                org: launch.map(|l| l.org.clone()),
                folder: p.folder(cx),
                server: p.server_name(),
                subject: launch.and_then(|l| l.subject.as_ref()).map(|s| format!("{}#{}", s.repo, s.number)),
                claude_id: launch.map(|l| l.claude_id()),
                review_ready: p.review_ready(cx),
            });
        }
    }
    out
}

/// Your Work, from the first window that has it.
pub fn work(cx: &App) -> crate::work::Work {
    cx.windows().into_iter().filter_map(|h| h.downcast::<Workspace>()).filter_map(|w| w.read(cx).ok().map(|w| w.work_lists().clone())).max_by_key(|w| w.reviews.len() + w.mine.len()).unwrap_or_default()
}

/// Which lane an item is in, for B, R and A.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Lane {
    Build,
    Review,
    Ask,
}

impl Lane {
    pub fn title(self) -> &'static str {
        match self {
            Lane::Build => "Build",
            Lane::Review => "Review",
            Lane::Ask => "Ask",
        }
    }
}

/// What a Needs you button does.
#[derive(Clone, Debug)]
pub enum Act {
    OpenSession(String),
    OpenThread(String),
    Url(String),
    Allow(Who, String, bool),
    Deny(Who, String),
    Confirm(u64, bool),
    /// Says the action to the errand, as the user.
    Reply(String, String),
    /// Review with Claude, in the front Gannin window.
    StartReview(crate::launch::Subject),
}

/// Something the user has to act on.
#[derive(Clone)]
pub struct Need {
    pub key: String,
    /// 0 blocked, 1 a decision, 2 a response; came-back reminders go first.
    pub rank: u8,
    pub subject: String,
    pub task: String,
    pub detail: String,
    pub since: DateTime<Local>,
    pub actions: Vec<(String, Act)>,
    pub open: Option<Act>,
    pub thread: Option<String>,
    pub lane: Lane,
    pub org: Option<String>,
    /// A PR, so "when CI passes" is offered.
    pub pr: Option<String>,
    pub returned: bool,
}

/// A send to a session waiting for the user's OK.
pub struct Confirm {
    pub id: u64,
    pub session: String,
    pub title: String,
    pub text: String,
    pub at: DateTime<Local>,
    reply: Sender<Result<String, String>>,
}

/// A thread in the list.
#[derive(Clone)]
pub struct Thread {
    pub id: String,
    pub kind: ThreadKind,
    pub title: String,
    pub last: String,
    pub activity: Option<DateTime<Local>>,
    pub working: bool,
    pub org: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ThreadKind {
    Main,
    Question,
    Investigation,
    Build,
    Review,
}

pub struct MarraGlobal(pub Entity<Marra>);
impl Global for MarraGlobal {}

pub struct Marra {
    pub saved: Saved,
    pub main: Convo,
    pub errands: Vec<Errand>,
    pub confirms: Vec<Confirm>,
    next_confirm: u64,
    calls: Option<Receiver<Call>>,
    /// Keys of needs seen, so only new ones notify.
    seen: HashSet<String>,
    /// Blocked items and how many reminders each has had.
    reminded: HashMap<String, u8>,
    /// Came back from Remind me, and not yet dealt with.
    pub returned: HashSet<String>,
    /// Notifications held by Focus or quiet hours.
    pub held: Vec<String>,
    /// What the views last drew from, so a tick only redraws on a change.
    signature: u64,
    last_check: Instant,
    /// When Marra started: what's already waiting then doesn't notify.
    started: Instant,
    /// The floating window, while open.
    pub floating: Option<gpui::AnyWindowHandle>,
    _poll: Task<()>,
}

impl Marra {
    pub fn get(cx: &mut App) -> Entity<Marra> {
        if let Some(global) = cx.try_global::<MarraGlobal>() {
            return global.0.clone();
        }
        let entity = cx.new(Marra::new);
        cx.set_global(MarraGlobal(entity.clone()));
        entity
    }

    fn new(cx: &mut Context<Self>) -> Self {
        let saved = Saved::load();
        let served = marra_mcp::serve();
        let mcp = served.as_ref().map(|(port, token, _)| (*port, token.clone()));
        let mut main = Convo::new(Profile::marra(&saved), marra::dir().join("chat.jsonl"));
        main.engine.mcp = mcp.clone();
        let saved_errands: Vec<ErrandSaved> = std::fs::read(errands_file()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let errands = saved_errands
            .into_iter()
            .map(|s| {
                let profile = Profile { cwd: s.harness.clone(), system: errand_brief(s.kind), session: s.session.clone(), model: saved.model.clone(), extra: errand_flags() };
                let convo = Convo::new(profile, errand_log(&s.id));
                Errand { saved: s, convo }
            })
            .collect();
        let poll = cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(Duration::from_millis(150)).await;
            if this.update(cx, |this, cx| this.tick(cx)).is_err() {
                return;
            }
        });
        Self {
            saved,
            main,
            errands,
            confirms: Vec::new(),
            next_confirm: 0,
            calls: served.map(|(_, _, rx)| rx),
            seen: HashSet::new(),
            reminded: HashMap::new(),
            returned: HashSet::new(),
            held: Vec::new(),
            signature: 0,
            last_check: Instant::now() - Duration::from_secs(60),
            started: Instant::now(),
            floating: None,
            _poll: poll,
        }
    }

    pub fn convo(&self, who: &Who) -> Option<&Convo> {
        match who {
            Who::Main => Some(&self.main),
            Who::Errand(id) => self.errands.iter().find(|e| &e.saved.id == id).map(|e| &e.convo),
        }
    }

    pub fn convo_mut(&mut self, who: &Who) -> Option<&mut Convo> {
        match who {
            Who::Main => Some(&mut self.main),
            Who::Errand(id) => self.errands.iter_mut().find(|e| &e.saved.id == id).map(|e| &mut e.convo),
        }
    }

    fn tick(&mut self, cx: &mut Context<Self>) {
        let mut changed = false;
        let always = self.saved.always.clone();
        let events = self.main.engine.drain();
        if !events.is_empty() {
            changed = true;
            self.main.apply(events, &always);
        }
        let mut finished = Vec::new();
        for errand in &mut self.errands {
            let events = errand.convo.engine.drain();
            if events.is_empty() {
                continue;
            }
            changed = true;
            if errand.convo.apply(events, &always) && !errand.convo.engine.busy {
                finished.push(errand.saved.id.clone());
            }
        }
        for id in finished {
            self.finish_errand(&id);
        }
        // The session id a new conversation was given, kept for --resume.
        if self.main.engine.profile.session != self.saved.session {
            self.saved.session = self.main.engine.profile.session.clone();
            self.saved.save();
        }
        let calls: Vec<Call> = self.calls.as_ref().map(|rx| rx.try_iter().collect()).unwrap_or_default();
        for call in calls {
            changed = true;
            self.call(call, cx);
        }
        if self.last_check.elapsed() >= Duration::from_secs(1) {
            self.last_check = Instant::now();
            let signature = self.signature(cx);
            if signature != self.signature {
                self.signature = signature;
                changed = true;
            }
            self.check_needs(cx);
        }
        if changed || self.main.busy() || self.errands.iter().any(|e| e.convo.busy()) {
            cx.notify();
        }
    }

    /// What the views draw from Gannin's state, hashed.
    fn signature(&self, cx: &App) -> u64 {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        for s in sessions(cx) {
            (s.key, s.title, s.state.label(), s.since.timestamp(), s.review_ready.map(|r| r.0)).hash(&mut hasher);
        }
        let work = work(cx);
        for pr in work.reviews.iter().chain(&work.mine) {
            (&pr.url, pr.needs(), &pr.checks).hash(&mut hasher);
        }
        hasher.finish()
    }

    // MARK: Errands

    pub fn start_errand(&mut self, kind: ErrandKind, ask: &str, harness: PathBuf, skills: &[String]) -> Result<String, String> {
        if !harness.is_dir() {
            return Err(format!("{} isn't a folder on this Mac.", harness.display()));
        }
        let id = uuid::Uuid::new_v4().simple().to_string()[..8].to_string();
        let title = ask.lines().next().unwrap_or_default().chars().take(60).collect::<String>();
        let profile = Profile { cwd: harness.clone(), system: errand_brief(kind), session: None, model: self.saved.model.clone(), extra: errand_flags() };
        let mut convo = Convo::new(profile, errand_log(&id));
        let hint = if skills.is_empty() { String::new() } else { format!("\n\nSkills to start with: {}.", skills.join(", ")) };
        convo.send(ask, &format!("{ask}{hint}"));
        let saved = ErrandSaved { id: id.clone(), kind, title, harness, session: convo.engine.profile.session.clone(), created: marra::now(), point: None, needs: None, done: false };
        self.errands.push(Errand { saved, convo });
        self.save_errands();
        Ok(id)
    }

    fn save_errands(&self) {
        let list: Vec<&ErrandSaved> = self.errands.iter().map(|e| &e.saved).collect();
        if let Ok(bytes) = serde_json::to_vec_pretty(&list) {
            let _ = std::fs::create_dir_all(marra::dir());
            let _ = std::fs::write(errands_file(), bytes);
        }
    }

    /// A worker's turn ended: its reply under the contract becomes the point
    /// and folded body, and what it needs goes in Needs you.
    fn finish_errand(&mut self, id: &str) {
        let Some(errand) = self.errands.iter_mut().find(|e| e.saved.id == id) else { return };
        errand.saved.session = errand.convo.engine.profile.session.clone();
        let last = errand.convo.chat.iter().rposition(|e| matches!(e, Entry::Marra { .. }));
        if let Some(index) = last {
            if let Entry::Marra { text, at } = errand.convo.chat[index].clone() {
                if let Some((point, body, needs)) = contract(&text) {
                    errand.convo.chat[index] = Entry::Reply { point: point.clone(), body, at };
                    errand.saved.point = Some(point);
                    errand.saved.needs = needs;
                    errand.saved.done = true;
                    errand.convo.save();
                }
            }
        }
        self.save_errands();
    }

    pub fn remove_errand(&mut self, id: &str) {
        if let Some(index) = self.errands.iter().position(|e| e.saved.id == id) {
            let mut errand = self.errands.remove(index);
            errand.convo.engine.stop();
            let _ = std::fs::remove_file(errand_log(id));
        }
        self.save_errands();
    }

    // MARK: Tools

    fn call(&mut self, call: Call, cx: &mut Context<Self>) {
        let reply = call.reply;
        let id = call.args["id"].as_str().unwrap_or_default().to_string();
        let outcome: Result<String, String> = match call.tool.as_str() {
            "list_sessions" => Ok(describe_sessions(&sessions(cx))),
            "waiting" => {
                let needs = self.needs(None, cx);
                Ok(if needs.is_empty() { "Nothing needs the user right now.".into() } else { needs.iter().map(|n| format!("- {}: {} ({}; {})", n.subject, n.task, n.detail, waiting(n.since))).collect::<Vec<_>>().join("\n") })
            }
            "read_session" => match sessions(cx).into_iter().find(|s| s.key == id) {
                None => Err(format!("No session {id}. Call list_sessions for the ids.")),
                Some(s) => {
                    let count = call.args["messages"].as_u64().unwrap_or(12) as usize;
                    let body = s.claude_id.as_deref().and_then(|c| marra_mcp::transcript_tail(c, count)).unwrap_or_else(|| s.page.read(cx).screen_tail(60, cx));
                    Ok(format!("{} ({}, {} since {}):\n\n{}", s.title, s.kind, s.state.label(), s.since.format("%H:%M"), body))
                }
            },
            "open_tab" => {
                if self.open_session(&id, cx) {
                    Ok("Brought it forward.".into())
                } else {
                    Err(format!("No session {id}."))
                }
            }
            "workload" => Ok(describe_work(&work(cx))),
            "list_skills" => Ok(marra_mcp::skills()),
            "notes" => {
                let path = marra::dir().join("marra-notes.md");
                match call.args["text"].as_str() {
                    Some(text) => std::fs::write(&path, text).map(|_| "Saved.".into()).map_err(|e| e.to_string()),
                    None => Ok(std::fs::read_to_string(&path).unwrap_or_else(|_| "(no notes yet)".into())),
                }
            }
            "start_errand" => {
                let kind = if call.args["kind"] == "investigation" { ErrandKind::Investigation } else { ErrandKind::Question };
                let skills: Vec<String> = call.args["skills"].as_array().map(|a| a.iter().filter_map(|s| s.as_str().map(str::to_string)).collect()).unwrap_or_default();
                let harness = PathBuf::from(call.args["harness"].as_str().unwrap_or_default());
                self.start_errand(kind, call.args["ask"].as_str().unwrap_or_default(), harness, &skills).map(|id| format!("Started errand {id}. It shows as a thread of its own and reports back there; you needn't wait for it."))
            }
            "send_to_session" => match sessions(cx).into_iter().find(|s| s.key == id) {
                None => Err(format!("No session {id}.")),
                Some(s) => {
                    // Waits for the user's OK on a card; the reply goes when they decide.
                    self.next_confirm += 1;
                    self.confirms.push(Confirm { id: self.next_confirm, session: s.key, title: s.title, text: call.args["text"].as_str().unwrap_or_default().to_string(), at: Local::now(), reply });
                    return;
                }
            },
            other => Err(format!("No tool {other}.")),
        };
        let _ = reply.send(outcome);
    }

    /// Answers a send-to-session card.
    pub fn confirm(&mut self, id: u64, send: bool, cx: &mut Context<Self>) {
        let Some(index) = self.confirms.iter().position(|c| c.id == id) else { return };
        let confirm = self.confirms.remove(index);
        let outcome = if !send {
            Err("The user said not to send it.".to_string())
        } else {
            match sessions(cx).into_iter().find(|s| s.key == confirm.session) {
                Some(s) => {
                    let text = confirm.text.clone();
                    s.page.update(cx, |page, cx| page.tell(&text, cx));
                    Ok("Sent.".to_string())
                }
                None => Err("The session has closed.".to_string()),
            }
        };
        self.main.event(if send { format!("Sent to {}.", confirm.title) } else { format!("Not sent to {}.", confirm.title) });
        let _ = confirm.reply.send(outcome);
        cx.notify();
    }

    /// Review with Claude in the front Gannin window (it asks for nothing
    /// on GitHub; posting confirms in the review as always).
    pub fn start_review(&mut self, subject: crate::launch::Subject, cx: &mut App) {
        let target = cx.active_window().and_then(|w| w.downcast::<Workspace>()).or_else(|| cx.windows().into_iter().find_map(|w| w.downcast::<Workspace>()));
        if let Some(window) = target {
            let _ = window.update(cx, |workspace, window, cx| {
                workspace.review_for_marra(subject, window, cx);
                window.activate_window();
            });
        }
    }

    /// Brings a session's window forward on its tab.
    pub fn open_session(&mut self, key: &str, cx: &mut App) -> bool {
        let Some(s) = sessions(cx).into_iter().find(|s| s.key == key) else { return false };
        let id = s.id;
        s.window
            .update(cx, |workspace, window, cx| {
                workspace.reveal_session(id, window, cx);
                window.activate_window();
            })
            .is_ok()
    }

    // MARK: Needs you

    /// What needs the user, in order; `org` narrows it.
    pub fn needs(&self, org: Option<&str>, cx: &App) -> Vec<Need> {
        let mut out: Vec<Need> = Vec::new();
        let now = Local::now();
        // Marra's own and its workers' permission requests: blocked.
        let convos = std::iter::once((Who::Main, "Marra".to_string(), &self.main)).chain(self.errands.iter().map(|e| (Who::Errand(e.saved.id.clone()), e.saved.title.clone(), &e.convo)));
        for (who, title, convo) in convos {
            for entry in &convo.chat {
                if let Entry::Permission { request, summary, answer: None, .. } = entry {
                    if !convo.asks.contains_key(request) {
                        continue;
                    }
                    let thread = thread_id(&who);
                    out.push(Need {
                        key: format!("ask:{request}"),
                        rank: 0,
                        subject: title.clone(),
                        task: "Wants your OK".into(),
                        detail: summary.clone(),
                        since: now,
                        actions: vec![("Allow".into(), Act::Allow(who.clone(), request.clone(), false)), ("Allow always".into(), Act::Allow(who.clone(), request.clone(), true)), ("Deny".into(), Act::Deny(who.clone(), request.clone()))],
                        open: Some(Act::OpenThread(thread.clone())),
                        thread: Some(thread),
                        lane: Lane::Ask,
                        org: None,
                        pr: None,
                        returned: false,
                    });
                }
            }
        }
        for c in &self.confirms {
            out.push(Need {
                key: format!("confirm:{}", c.id),
                rank: 0,
                subject: c.title.clone(),
                task: "Marra wants to send this".into(),
                detail: c.text.clone(),
                since: c.at,
                actions: vec![("Send".into(), Act::Confirm(c.id, true)), ("Don't send".into(), Act::Confirm(c.id, false))],
                open: Some(Act::OpenSession(c.session.clone())),
                thread: Some(format!("s:{}", c.session)),
                lane: Lane::Build,
                org: None,
                pr: None,
                returned: false,
            });
        }
        for s in sessions(cx) {
            let lane = if s.kind == "review" { Lane::Review } else if s.kind == "ask" { Lane::Ask } else { Lane::Build };
            let thread = format!("s:{}", s.key);
            let base = |rank: u8, task: &str, detail: String| Need {
                key: format!("session:{}:{}", s.key, task),
                rank,
                subject: s.subject.clone().unwrap_or_else(|| s.title.clone()),
                task: task.into(),
                detail,
                since: s.since,
                actions: Vec::new(),
                open: Some(Act::OpenSession(s.key.clone())),
                thread: Some(thread.clone()),
                lane,
                org: s.org.clone(),
                pr: None,
                returned: false,
            };
            if let Some((kept, verdict)) = &s.review_ready {
                let verdict = verdict.clone().map(|v| format!("{v}, ")).unwrap_or_default();
                out.push(base(1, "Review ready to post", format!("{verdict}{kept} finding{} kept", if *kept == 1 { "" } else { "s" })));
                continue;
            }
            match s.state {
                State::NeedsYou => out.push(base(0, "Waiting for you", format!("{} has a question or a permission on screen", s.title))),
                State::YourTurn if s.kind != "terminal" => out.push(base(1, "Finished; your turn", s.title.clone())),
                _ => {}
            }
        }
        for e in &self.errands {
            if let (Some(needs), true) = (&e.saved.needs, e.saved.done) {
                let thread = format!("e:{}", e.saved.id);
                out.push(Need {
                    key: format!("errand:{}:{}", e.saved.id, needs.task),
                    rank: 1,
                    subject: e.saved.title.clone(),
                    task: needs.task.clone(),
                    detail: e.saved.point.clone().unwrap_or_default(),
                    since: e.convo.activity().unwrap_or(now),
                    actions: needs.actions.iter().map(|a| (a.clone(), Act::Reply(e.saved.id.clone(), a.clone()))).collect(),
                    open: Some(Act::OpenThread(thread.clone())),
                    thread: Some(thread),
                    lane: Lane::Ask,
                    org: None,
                    pr: None,
                    returned: false,
                });
            }
        }
        let work = work(cx);
        let org_of = |repo: &str| repo.split('/').next().map(str::to_string);
        let subjects: Vec<String> = sessions(cx).into_iter().filter_map(|s| s.subject).collect();
        for pr in &work.reviews {
            if subjects.contains(&format!("{}#{}", pr.repo, pr.number)) {
                continue;
            }
            out.push(Need {
                key: format!("review-request:{}", pr.url),
                rank: 2,
                subject: format!("{}#{}", pr.short_repo(), pr.number),
                task: "Review requested".into(),
                detail: format!("{}{}", pr.title, pr.author.as_ref().map(|a| format!(" by {a}")).unwrap_or_default()),
                since: pr.updated.with_timezone(&Local),
                actions: if pr.id.is_empty() {
                    vec![("Open on GitHub".into(), Act::Url(pr.url.clone()))]
                } else {
                    vec![("Start review".into(), Act::StartReview(crate::launch::Subject { id: pr.id.clone(), repo: pr.repo.clone(), number: pr.number, title: pr.title.clone(), url: pr.url.clone() })), ("Open on GitHub".into(), Act::Url(pr.url.clone()))]
                },
                open: Some(Act::Url(pr.url.clone())),
                thread: None,
                lane: Lane::Review,
                org: org_of(&pr.repo),
                pr: Some(pr.url.clone()),
                returned: false,
            });
        }
        for pr in &work.mine {
            if let Some(needs) = pr.needs() {
                out.push(Need {
                    key: format!("mine:{}:{needs}", pr.url),
                    rank: 2,
                    subject: format!("{}#{}", pr.short_repo(), pr.number),
                    task: needs.into(),
                    detail: pr.title.clone(),
                    since: pr.updated.with_timezone(&Local),
                    actions: vec![("Open on GitHub".into(), Act::Url(pr.url.clone()))],
                    open: Some(Act::Url(pr.url.clone())),
                    thread: None,
                    lane: Lane::Build,
                    org: org_of(&pr.repo),
                    pr: Some(pr.url.clone()),
                    returned: false,
                });
            }
        }
        // Remind me: hidden until due; back at the top once it is.
        out.retain(|n| !self.saved.snoozed.contains_key(&n.key));
        for n in &mut out {
            n.returned = self.returned.contains(&n.key);
        }
        if let Some(org) = org {
            out.retain(|n| n.org.as_deref().is_none_or(|o| o == org));
        }
        out.sort_by_key(|n| (!n.returned, n.rank, n.since));
        out
    }

    /// Parks an item: back after `minutes`, or (None) when its PR's CI passes.
    pub fn remind(&mut self, key: &str, minutes: Option<i64>) {
        let when = match minutes {
            Some(m) => (Local::now() + chrono::Duration::minutes(m)).to_rfc3339(),
            None => "ci".into(),
        };
        self.saved.snoozed.insert(key.to_string(), when);
        self.returned.remove(key);
        self.saved.save();
    }

    /// Reminders due come back; new items notify; blocked ones are
    /// mentioned again at 15 minutes and an hour.
    fn check_needs(&mut self, cx: &mut Context<Self>) {
        let now = Local::now();
        let work = work(cx);
        let due: Vec<String> = self
            .saved
            .snoozed
            .iter()
            .filter(|(key, when)| match when.as_str() {
                "ci" => work.mine.iter().any(|pr| key.contains(&pr.url) && pr.checks.as_deref() == Some("SUCCESS")),
                when => DateTime::parse_from_rfc3339(when).is_ok_and(|w| w <= now),
            })
            .map(|(k, _)| k.clone())
            .collect();
        for key in &due {
            self.saved.snoozed.remove(key);
            self.returned.insert(key.clone());
        }
        if !due.is_empty() {
            self.saved.save();
        }
        let needs = self.needs(None, cx);
        let keys: HashSet<String> = needs.iter().map(|n| n.key.clone()).collect();
        self.returned.retain(|k| keys.contains(k) || self.saved.snoozed.contains_key(k));
        let first_look = self.started.elapsed() < Duration::from_secs(5);
        for need in &needs {
            let thread_muted = need.thread.as_ref().is_some_and(|t| self.saved.muted.contains(t)) && need.rank > 0;
            if self.seen.insert(need.key.clone()) {
                // Already there when Gannin started: no flood of notifications.
                if !first_look && !thread_muted {
                    self.tell(need, need.rank == 0);
                }
            } else if due.contains(&need.key) {
                self.tell(&Need { task: format!("{} (back)", need.task), ..need.clone() }, false);
            } else if need.rank == 0 {
                let waited = (now - need.since).num_minutes();
                let count = self.reminded.entry(need.key.clone()).or_insert(0);
                if (waited >= 15 && *count == 0) || (waited >= 60 && *count == 1) {
                    *count += 1;
                    self.tell(&Need { task: format!("{} ({})", need.task, waiting(need.since)), ..need.clone() }, true);
                }
            }
        }
        self.seen.retain(|k| keys.contains(k));
        self.reminded.retain(|k, _| keys.contains(k));
        // The morning digest: what quiet hours held, once they end.
        if !quiet_hours() && !self.saved.focus && !self.held.is_empty() {
            let held = std::mem::take(&mut self.held);
            notify(&format!("{} while you were away", if held.len() == 1 { "1 thing".to_string() } else { format!("{} things", held.len()) }), &held.join("\n"));
        }
    }

    /// A notification that says what to do; held by Focus and quiet hours
    /// (blocked items get through Focus, not quiet hours).
    fn tell(&mut self, need: &Need, blocked: bool) {
        let line = format!("{}: {}", need.subject, need.task);
        if quiet_hours() || (self.saved.focus && !blocked) {
            self.held.push(line);
            return;
        }
        notify(&need.subject, &format!("{}. {}", need.task, need.detail));
    }

    pub fn set_focus(&mut self, on: bool, cx: &mut Context<Self>) {
        self.saved.focus = on;
        self.saved.save();
        if !on && !self.held.is_empty() {
            let held = std::mem::take(&mut self.held);
            let title = match held.len() {
                1 => "1 thing while you were busy".to_string(),
                n => format!("{n} things while you were busy"),
            };
            notify(&title, &held.join("\n"));
        }
        cx.notify();
    }

    // MARK: Threads

    pub fn threads(&self, cx: &App) -> Vec<Thread> {
        let mut out = vec![Thread { id: "main".into(), kind: ThreadKind::Main, title: "Marra".into(), last: self.main.last_line(), activity: self.main.activity(), working: self.main.busy(), org: None }];
        for e in &self.errands {
            out.push(Thread {
                id: format!("e:{}", e.saved.id),
                kind: if e.saved.kind == ErrandKind::Investigation { ThreadKind::Investigation } else { ThreadKind::Question },
                title: e.saved.title.clone(),
                last: e.saved.point.clone().filter(|_| !e.convo.busy()).unwrap_or_else(|| e.convo.last_line()),
                activity: e.convo.activity(),
                working: e.convo.busy(),
                org: None,
            });
        }
        for s in sessions(cx) {
            let last = match (&s.review_ready, s.state) {
                (Some(_), _) => "Review ready to post".to_string(),
                (_, State::Working) => "Working".into(),
                (_, State::NeedsYou) => "Waiting for you".into(),
                (_, State::YourTurn) => "Your turn".into(),
                (_, State::Ended) => "Ended".into(),
            };
            out.push(Thread {
                id: format!("s:{}", s.key),
                kind: if s.kind == "review" { ThreadKind::Review } else if s.kind == "ask" { ThreadKind::Question } else { ThreadKind::Build },
                title: s.title.clone(),
                last: format!("{last}{}", s.server.as_ref().map(|n| format!(" · on {n}")).unwrap_or_default()),
                activity: Some(s.since),
                working: s.state == State::Working,
                org: s.org.clone(),
            });
        }
        out
    }

    pub fn is_unread(&self, thread: &Thread) -> bool {
        if self.saved.muted.contains(&thread.id) || thread.working {
            return false;
        }
        let Some(activity) = thread.activity else { return false };
        match self.saved.read.get(&thread.id).and_then(|r| DateTime::parse_from_rfc3339(r).ok()) {
            Some(read) => activity > read,
            None => true,
        }
    }

    pub fn mark_read(&mut self, thread: &str, read: bool) {
        if read {
            self.saved.read.insert(thread.to_string(), Local::now().to_rfc3339());
        } else {
            self.saved.read.remove(thread);
        }
        self.saved.save();
    }

    pub fn toggle(list: &mut Vec<String>, id: &str) {
        if let Some(i) = list.iter().position(|x| x == id) {
            list.remove(i);
        } else {
            list.push(id.to_string());
        }
    }

    pub fn set_model(&mut self, model: Option<String>) {
        self.saved.model = model.clone();
        self.saved.save();
        self.main.engine.profile.model = model;
        // The next message starts claude again with it, resuming.
        self.main.engine.stop();
    }

    pub fn new_conversation(&mut self) {
        self.main.engine.new_conversation();
        self.main.engine.profile.system = marra::system_prompt();
        self.saved.session = self.main.engine.profile.session.clone();
        self.saved.save();
        self.main.asks.clear();
        self.main.event("New conversation. Your notes are loaded; the earlier one stays above.");
    }
}

/// An errand's worker can't change anything.
fn errand_flags() -> Vec<String> {
    vec!["--disallowedTools".into(), "Edit".into(), "Write".into(), "NotebookEdit".into()]
}

pub fn thread_id(who: &Who) -> String {
    match who {
        Who::Main => "main".into(),
        Who::Errand(id) => format!("e:{id}"),
    }
}

/// How long something has waited: "just now", "waiting 40m".
pub fn waiting(since: DateTime<Local>) -> String {
    match (Local::now() - since).num_minutes() {
        m if m < 1 => "just now".into(),
        m if m < 60 => format!("waiting {m}m"),
        m if m < 60 * 24 => format!("waiting {}h", m / 60),
        m => format!("waiting {}d", m / 60 / 24),
    }
}

/// "now", "2m ago", "1h ago", "3d ago".
pub fn ago(at: DateTime<Local>) -> String {
    match (Local::now() - at).num_minutes() {
        m if m < 1 => "now".into(),
        m if m < 60 => format!("{m}m ago"),
        m if m < 60 * 24 => format!("{}h ago", m / 60),
        m => format!("{}d ago", m / 60 / 24),
    }
}

/// 22:00 to 07:00: nothing notifies; it's summed up after.
fn quiet_hours() -> bool {
    use chrono::Timelike;
    let hour = Local::now().hour();
    !(7..22).contains(&hour)
}

/// A macOS notification.
pub fn notify(title: &str, body: &str) {
    if !cfg!(target_os = "macos") {
        return;
    }
    let (title, body) = (title.to_string(), body.to_string());
    std::thread::spawn(move || {
        let _ = std::process::Command::new("/usr/bin/osascript")
            .args(["-e", "on run argv", "-e", "display notification (item 2 of argv) with title \"Marra\" subtitle (item 1 of argv)", "-e", "end run", &title, &body])
            .output();
    });
}

fn describe_sessions(list: &[SessionInfo]) -> String {
    if list.is_empty() {
        return "No sessions are open in Gannin.".into();
    }
    list.iter()
        .map(|s| {
            let place = s.server.as_ref().map(|n| format!(", on server {n}")).unwrap_or_default();
            let subject = s.subject.as_ref().map(|x| format!(", about {x}")).unwrap_or_default();
            let review = s.review_ready.as_ref().map(|(kept, v)| format!(", review ready to post ({}{kept} findings)", v.clone().map(|v| format!("{v}, ")).unwrap_or_default())).unwrap_or_default();
            format!("- id {}: \"{}\" ({}), {} since {}{subject}{review}{place}, folder {}", s.key, s.title, s.kind, s.state.label().to_lowercase(), s.since.format("%H:%M"), s.folder.display())
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn describe_work(work: &crate::work::Work) -> String {
    let pr = |p: &crate::work::Pr| format!("- {}#{} \"{}\": {}{} ({})", p.repo, p.number, p.title, p.standing(), p.author.as_ref().map(|a| format!(", by {a}")).unwrap_or_default(), p.url);
    let mut out = vec![format!("Review requests ({}):", work.reviews.len())];
    out.extend(work.reviews.iter().map(pr));
    out.push(format!("\nTheir PRs ({}):", work.mine.len()));
    out.extend(work.mine.iter().map(pr));
    if let Some(issues) = &work.issues {
        out.push(format!("\nIssues assigned ({}):", issues.len()));
        out.extend(issues.iter().map(|i| format!("- {}#{} \"{}\" ({})", i.repo, i.number, i.title, i.url)));
    }
    if !work.live {
        out.push("\n(From Gannin's cache, not a live query.)".into());
    }
    out.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_contract() {
        let text = "Done.\n```json\n{\"point\": \"1,284 permits\", \"body\": \"## Detail\", \"needs_you\": {\"task\": \"Post it\", \"actions\": [\"Post\"]}}\n```";
        let (point, body, needs) = contract(text).unwrap();
        assert_eq!(point, "1,284 permits");
        assert_eq!(body, "## Detail");
        assert_eq!(needs.unwrap().actions, vec!["Post".to_string()]);
        let none = contract("```json\n{\"point\": \"x\", \"body\": \"y\", \"needs_you\": null}\n```").unwrap();
        assert!(none.2.is_none());
    }
}
