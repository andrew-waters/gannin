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
    /// When each open permission request arrived, for its reminders.
    pub asked_at: HashMap<String, DateTime<Local>>,
    log: PathBuf,
}

impl Convo {
    fn new(profile: Profile, log: PathBuf) -> Self {
        let chat = marra::load_chat(&log);
        Self { engine: Engine::new(profile), chat, streaming: String::new(), status: None, context: 0, asks: HashMap::new(), doing: None, asked_at: HashMap::new(), log }
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
                    if marra::read_only(&tool, &input) || marra::always_key(&tool, &input).is_some_and(|k| always.contains(&k)) {
                        let _ = self.engine.answer(&request, true, &input);
                    } else {
                        let summary = marra::summarize(&tool, &input);
                        self.chat.push(Entry::Permission { request: request.clone(), tool: tool.clone(), summary, answer: None });
                        self.asked_at.insert(request.clone(), Local::now());
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

    /// Ends claude's process, as when it's stuck: what was open goes with
    /// it, and the conversation resumes with the next message.
    pub fn restart(&mut self) {
        self.engine.stop();
        self.apply(vec![Event::Exited("restarted.".into())], &[]);
    }

    /// Answers a permission card.
    pub fn decide(&mut self, request: &str, allow: bool, always: bool) -> Option<String> {
        let (tool, input) = self.asks.remove(request)?;
        self.asked_at.remove(request);
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
        if allow && always { marra::always_key(&tool, &input) } else { None }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrandKind {
    Question,
    Investigation,
    /// A new issue, talked through, scouted and created with the harness's skills.
    Issue,
}

/// An errand as saved, so it comes back after a relaunch.
#[derive(Clone, Serialize, Deserialize)]
pub struct ErrandSaved {
    pub id: String,
    pub kind: ErrandKind,
    pub title: String,
    pub harness: PathBuf,
    /// The server the harness is on; None for this Mac.
    #[serde(default)]
    pub server: Option<crate::servers::Server>,
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
    if kind == ErrandKind::Issue {
        return issue_brief();
    }
    let job = match kind {
        ErrandKind::Question => "answer a data question using this harness's skills (ClickHouse, Mongo, analytics and so on). Pick the skill that fits, run read-only queries, and check the numbers make sense before answering.",
        ErrandKind::Investigation | ErrandKind::Issue => "investigate a bug or ticket using this harness's skills: plan with the triage skill if there is one, then follow the evidence (logs, traces, databases, the code). Do not fix anything: report the cause, the evidence, your confidence and what is still unknown.",
    };
    format!(
        "You are a worker for Marra, the user's assistant in Gannin. Your job: {job}\n\n\
You are read only: never edit files, never write to databases, GitHub or any service. Summarise and count customer data; never quote raw documents or personal details in your reply.\n\n\
End every reply with the reply contract, a fenced json block and nothing after it:\n\
```json\n{{\"point\": \"one sentence you could say out loud: the answer or verdict\", \"body\": \"the whole of it in Markdown, any length: figures, evidence, the query and environment used, caveats\", \"needs_you\": null}}\n```\n\
Rules: lead with the answer, never with what you did; point is one sentence; set needs_you to {{\"task\": \"...\", \"actions\": [\"...\"]}} only for a real decision the user must make, never for \"let me know if\"; body is evidence, never needed to act. Text before the json block is not shown, so put everything in point and body."
    )
}

/// An Issue errand's brief: a conversation, then a scout, then the issue
/// made as the harness's own skills say. Its one write is creating the
/// issue, which Gannin asks the user to approve as a card.
fn issue_brief() -> String {
    "You are a worker for Marra, the user's assistant in Gannin, in the team's harness. Your job: raise one GitHub issue with the user, by talking it through.\n\n\
The harness's own rules come first. Before you ask anything, read what this harness says about issues and planning: its CLAUDE.md, every skill (.claude/skills/, skills/ and wherever its CLAUDE.md points) that covers creating, scoping, triaging or planning issues, and its issue templates. Where they say something different from the steps below (the questions to ask, the order, the template, where it goes, labels, types, boards, fields, how to create it), do what they say: these steps are only the fallback. Tell the user in one line which skills you're following.\n\n\
How it goes, unless a skill says otherwise:\n\
1. Talk. The user's first message says what the issue is about; ask only what you still need: the problem or goal, who it's for, what done looks like. One or two short questions at a time, in plain words. Don't draft yet.\n\
2. Scout. Once you know what it is, read the code (the repos are shared clones under projects/, or this checkout when it's the code repo): where it lives, what it touches, how it behaves today. Change nothing. Say in a few lines what you found, and ask anything the code leaves open.\n\
3. Check the harness again. Before drafting, go back to the skills and templates you found, and any the scout turned up for the repo it belongs in (its own .github templates and docs). They decide the repo, the template, labels, type, board and fields.\n\
4. Draft. Show the whole issue: repo, title, body in Markdown (real files and behaviour, scope in and out, acceptance criteria someone can check), labels, type, board and fields. Don't invent details: say what's unknown. Ask whether to create it or change something.\n\
5. Create. Only after the user says to, create it the way the skill says (gh, or gh api for board fields). Gannin shows the user each write to approve first. Then give the link.\n\n\
Never edit files or write anything but the issue and its board fields. Write as a person would talk; no preamble, no summaries of what you did.\n\n\
When the issue is created (or the user calls it off), end that reply with a fenced json block and nothing after it: {\"point\": \"one sentence: the issue's link and title, or that it was called off\", \"body\": \"the issue as created, in Markdown\", \"needs_you\": null}. Don't add the block to any other reply.".to_string()
}

/// The opening a new Issue errand sends its worker: what the user said it's
/// about, so it starts there rather than by asking.
fn issue_opening(about: &str) -> String {
    format!("I want to raise a new issue from this harness. What it's about:\n\n{about}\n\nRead the harness's rules for issues first, then ask what you still need, or scout if you have enough.")
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
    /// That server, to reach it: a summary of its session is made and kept there.
    pub remote: Option<crate::servers::Server>,
    /// Its harness, on whichever machine it runs: where its summaries are kept.
    pub harness: Option<PathBuf>,
    pub subject: Option<String>,
    /// The issue or PR it's about, to open in Gannin or on GitHub.
    pub subject_link: Option<crate::launch::Subject>,
    pub claude_id: Option<String>,
    /// A review with a result not yet posted: findings kept and the verdict.
    pub review_ready: Option<(usize, Option<String>)>,
    /// A review's new commits on its PR since the review (0 when none).
    pub new_commits: usize,
    pub new_commits_since: DateTime<Local>,
}

/// Every session open, in every window, as Marra last read them. Read
/// from Marra's cache: a window being drawn or handling a click can't be
/// read (GPUI lends it out), so a docked view reading live would miss its
/// own window. Never call from inside Marra's own update.
pub fn sessions(cx: &App) -> Vec<SessionInfo> {
    cx.try_global::<MarraGlobal>().map(|g| g.0.read(cx).sessions.clone()).unwrap_or_default()
}

/// Your Work, as Marra last read it.
pub fn work(cx: &App) -> crate::work::Work {
    cx.try_global::<MarraGlobal>().map(|g| g.0.read(cx).work.clone()).unwrap_or_default()
}

/// Every session open, read from the windows: only from Marra's tick,
/// which runs outside any window's update.
fn live_sessions(cx: &App) -> Vec<SessionInfo> {
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
                // Its claude conversation where it has one, so pins, mutes and
                // reminders outlive a relaunch; else its window and tab.
                // A plain Claude Code tab by its own key, which a relaunch
                // keeps (it resumes by it); only a terminal by its window.
                key: launch.map(|l| l.claude_id()).or_else(|| p.claude_id.clone()).unwrap_or_else(|| format!("{}:{}", handle.window_id().as_u64(), p.id)),
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
                remote: p.server(),
                harness: launch.map(|l| l.harness_path.clone()).or_else(|| Some(p.folder(cx))),
                subject: launch.and_then(|l| l.subject.as_ref()).map(|s| format!("{}#{}", s.repo, s.number)),
                subject_link: launch.and_then(|l| l.subject.clone()),
                claude_id: launch.map(|l| l.claude_id()).or_else(|| p.claude_id.clone()),
                review_ready: p.review_ready(cx),
                new_commits: p.new_commits,
                new_commits_since: p.new_commits_since,
            });
        }
    }
    out
}

/// Your Work, from the window that has the most of it.
fn live_work(cx: &App) -> crate::work::Work {
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
    /// A session's issue or PR in Gannin (its drawer), else on GitHub.
    OpenSubject(String),
    /// Seen: a thread marked read, which clears its "your turn".
    MarkRead(String),
    Allow(Who, String, bool),
    Deny(Who, String),
    Confirm(u64, bool),
    /// Says the action to the errand, as the user.
    Reply(String, String),
    /// Review with Claude, in the front Gannin window.
    StartReview(crate::launch::Subject),
    /// A review session's own button, pressed in its panel.
    Review(String, ReviewButton),
}

/// The review panel's buttons Marra offers, which do there what they do in
/// the panel: Post Review opens its sheet, so posting is still confirmed there.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ReviewButton {
    Post,
    Again,
    Check,
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
    /// One of your PRs, so "when CI passes" is offered.
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
    Issue,
    /// The plain checklist: no AI, kept on this Mac (`todos.rs`).
    Todos,
    /// Your notes: no AI, kept on this Mac unless shared (`notes.rs`).
    Notes,
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
    /// Gannin's own log of each session's changes (by session key), for
    /// "since you looked"; no model call. Kept while Gannin runs.
    pub log: HashMap<String, Vec<(DateTime<Local>, String)>>,
    /// Each session's state as last seen, to notice changes.
    states: HashMap<String, String>,
    /// Sessions and Your Work as last read from the windows (in `tick`).
    pub sessions: Vec<SessionInfo>,
    pub work: crate::work::Work,
    /// The orgs you have a harness in (and those sessions run in): the
    /// scopes offered, and the only orgs whose needs show. A PR in an org
    /// you've no harness for isn't Marra's to chase.
    pub harness_orgs: Vec<String>,
    harness_checked: Option<Instant>,
    /// The phone API, while it's on.
    pub api: Option<crate::marra_api::Api>,
    pub api_error: Option<String>,
    _poll: Task<()>,
}

impl Marra {
    pub fn get(cx: &mut App) -> Entity<Marra> {
        if let Some(global) = cx.try_global::<MarraGlobal>() {
            return global.0.clone();
        }
        let entity = cx.new(Marra::new);
        cx.set_global(MarraGlobal(entity.clone()));
        // A click on one of Marra's notifications brings Marra forward, on
        // its thread when it has one.
        cx.on_system_notification_response(|response, cx| {
            let thread = response.tag.strip_prefix("thread:").map(str::to_string);
            crate::marra_view::show_thread(thread, cx);
        });
        entity
    }

    fn new(cx: &mut Context<Self>) -> Self {
        let mut saved = Saved::load();
        // A session without a claude id is known by its window, whose id is
        // new each launch: what was kept for one means nothing now.
        let stale = |k: &str| k.strip_prefix("s:").or_else(|| k.strip_prefix("session:")).is_some_and(|rest| rest.split(':').next().is_some_and(|w| w.chars().all(|c| c.is_ascii_digit())) && rest.contains(':'));
        saved.read.retain(|k, _| !stale(k));
        saved.pinned.retain(|k| !stale(k));
        saved.muted.retain(|k| !stale(k));
        saved.snoozed.retain(|k, _| !stale(k));
        saved.dismissed.retain(|k| !stale(k));
        // Each claude gets its config (with this launch's token) as it
        // starts; earlier launches' are stale.
        for entry in std::fs::read_dir(marra::dir()).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with("mcp-") && name.ends_with(".json") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
        let served = marra_mcp::serve();
        let mcp = served.as_ref().map(|(port, token, _)| (*port, token.clone()));
        let mut main = Convo::new(Profile::marra(&saved), marra::dir().join("chat.jsonl"));
        main.engine.mcp = mcp.clone();
        let saved_errands: Vec<ErrandSaved> = std::fs::read(errands_file()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let errands = saved_errands
            .into_iter()
            .map(|s| {
                let profile = Profile { cwd: s.harness.clone(), system: errand_brief(s.kind), session: s.session.clone(), model: saved.model.clone(), extra: errand_flags(), server: s.server.clone() };
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
        // A test copy leaves the phone API to the copy in use.
        let (api, api_error) = if saved.api && !crate::state::beside() {
            match crate::marra_api::Api::start() {
                Ok(api) => (Some(api), None),
                Err(e) => (None, Some(e)),
            }
        } else {
            (None, None)
        };
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
            log: HashMap::new(),
            states: HashMap::new(),
            api,
            api_error,
            sessions: Vec::new(),
            work: Default::default(),
            harness_orgs: Vec::new(),
            harness_checked: None,
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
        post_notifications(cx);
        let mut changed = false;
        // Read here, outside any window's update, for everything else to use.
        self.sessions = live_sessions(cx);
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
            // The user's Allow always holds for workers too, but never for
            // gh or git: a worker's writes to GitHub always ask.
            let worker_always: Vec<String> = always.iter().filter(|k| !k.starts_with("Bash(gh") && !k.starts_with("Bash(git") && !k.starts_with("Bash(rtk gh") && !k.starts_with("Bash(rtk git")).cloned().collect();
            if errand.convo.apply(events, &worker_always) && !errand.convo.engine.busy {
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
            self.work = live_work(cx);
            if self.harness_checked.is_none_or(|at| at.elapsed() >= Duration::from_secs(30)) {
                self.harness_checked = Some(Instant::now());
                let mut orgs: Vec<String> = crate::projects::orgs_with_settings().into_iter().filter(|org| !crate::projects::harness_repos(org).is_empty()).collect();
                orgs.extend(self.sessions.iter().filter_map(|s| s.org.clone()));
                orgs.sort_by_key(|o| o.to_lowercase());
                orgs.dedup_by(|a, b| a.eq_ignore_ascii_case(b));
                if orgs != self.harness_orgs {
                    self.harness_orgs = orgs;
                    changed = true;
                }
            }
            // A send card whose tool call has given up waiting goes too.
            self.confirms.retain(|c| (Local::now() - c.at).num_minutes() < 15);
            self.note_changes();
            let signature = self.signature();
            if signature != self.signature {
                self.signature = signature;
                changed = true;
            }
            self.check_needs();
        }
        let api_calls: Vec<crate::marra_api::ApiCall> = self.api.as_ref().map(|a| a.calls.try_iter().collect()).unwrap_or_default();
        for call in api_calls {
            changed = true;
            // A session's transcript can be large: read it off the main thread.
            let parts: Vec<String> = call.path.trim_matches('/').split('/').map(urldecode).collect();
            if call.method == "GET" && parts.len() == 2 && parts[0] == "sessions" {
                match self.sessions.iter().find(|s| s.key == parts[1]) {
                    Some(s) => {
                        let (key, title, state, claude) = (s.key.clone(), s.title.clone(), s.state.label(), s.claude_id.clone());
                        let since: Vec<Value> = self.since_read(&key).iter().map(|(at, what)| serde_json::json!({ "at": at.to_rfc3339(), "what": what })).collect();
                        let reply = call.reply;
                        std::thread::spawn(move || {
                            let messages = claude.as_deref().and_then(|c| marra_mcp::transcript_messages(c, 30)).unwrap_or_default();
                            let _ = reply.send((200, serde_json::json!({ "id": key, "title": title, "state": state, "since_read": since, "messages": messages.iter().map(|(who, text)| serde_json::json!({ "who": who, "text": text })).collect::<Vec<_>>() })));
                        });
                    }
                    None => {
                        let _ = call.reply.send((404, serde_json::json!({ "error": "No such session." })));
                    }
                }
                continue;
            }
            let (status, body) = self.api_call(&call.method, &call.path, &call.body, cx);
            let _ = call.reply.send((status, body));
        }
        // Only on a change: a busy turn's events are changes, and the
        // spinner turns by itself.
        if changed {
            if let Some(api) = &self.api {
                api.changed();
            }
            cx.notify();
        }
    }

    /// What the views draw from Gannin's state, hashed.
    fn signature(&self) -> u64 {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        for s in self.sessions.clone() {
            (s.key, s.title, s.state.label(), s.since.timestamp(), s.review_ready.map(|r| r.0), s.new_commits).hash(&mut hasher);
        }
        let work = self.work.clone();
        for pr in work.reviews.iter().chain(&work.mine) {
            (&pr.url, pr.needs(), &pr.checks).hash(&mut hasher);
        }
        hasher.finish()
    }

    /// Logs what changed in each session since the last look: its state,
    /// and a review becoming ready.
    fn note_changes(&mut self) {
        let now = Local::now();
        let mut seen = HashSet::new();
        for s in self.sessions.clone() {
            seen.insert(s.key.clone());
            let state = match &s.review_ready {
                Some((kept, verdict)) => format!("Review ready ({}{kept} kept)", verdict.clone().map(|v| format!("{v}, ")).unwrap_or_default()),
                None => s.state.label().to_string(),
            };
            match self.states.insert(s.key.clone(), state.clone()) {
                Some(before) if before != state => {
                    let entries = self.log.entry(s.key.clone()).or_default();
                    entries.push((now, state));
                    let keep = entries.len().saturating_sub(40);
                    entries.drain(..keep);
                }
                // First seen: started now, unless Gannin itself just started.
                None if self.started.elapsed() > Duration::from_secs(5) => self.log.entry(s.key.clone()).or_default().push((now, "Started".into())),
                _ => {}
            }
        }
        self.states.retain(|k, _| seen.contains(k));
        self.log.retain(|k, _| seen.contains(k));
    }

    /// When the user last read a session's thread.
    pub fn read_at(&self, key: &str) -> Option<DateTime<Local>> {
        self.saved.read.get(&format!("s:{key}")).and_then(|r| DateTime::parse_from_rfc3339(r).ok()).map(|d| d.with_timezone(&Local))
    }

    /// What a session did after the user last read its thread.
    pub fn since_read(&self, key: &str) -> Vec<(DateTime<Local>, String)> {
        let read = self.saved.read.get(&format!("s:{key}")).and_then(|r| DateTime::parse_from_rfc3339(r).ok()).map(|d| d.with_timezone(&Local));
        self.log.get(key).map(|l| l.iter().filter(|(at, _)| read.is_none_or(|r| *at > r)).cloned().collect()).unwrap_or_default()
    }

    // MARK: Phone

    /// Phone access on or off; on makes a pairing code.
    pub fn set_api(&mut self, on: bool) {
        self.saved.api = on;
        self.saved.save();
        self.api = None;
        self.api_error = None;
        if on {
            match crate::marra_api::Api::start() {
                Ok(api) => {
                    api.new_code();
                    self.api = Some(api);
                }
                Err(e) => self.api_error = Some(e),
            }
        }
    }

    /// One API request, on the main thread: (status, JSON body).
    fn api_call(&mut self, method: &str, path: &str, body: &Value, cx: &mut Context<Self>) -> (u16, Value) {
        use serde_json::json;
        let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
        let text = body["text"].as_str().unwrap_or_default().trim().to_string();
        let convo_json = |c: &Convo| json!({ "messages": c.chat, "busy": c.busy(), "streaming": c.streaming, "context": c.context, "pending": c.asks.keys().collect::<Vec<_>>() });
        match (method, parts.as_slice()) {
            ("GET", ["assistant", "messages"]) => (200, convo_json(&self.main)),
            ("POST", ["assistant", "messages"]) if !text.is_empty() => {
                self.main.send(&text, &text);
                (202, json!({}))
            }
            ("POST", ["assistant", "stop"]) => {
                self.main.engine.interrupt();
                (202, json!({}))
            }
            ("POST", ["assistant", "compact"]) => match self.main.engine.send("/compact") {
                Ok(()) => (202, json!({})),
                Err(e) => (409, json!({ "error": e })),
            },
            ("POST", ["assistant", "new"]) => {
                self.new_conversation();
                (202, json!({}))
            }
            ("GET", ["needs"]) => (200, json!({ "needs": self.needs(None).iter().map(need_json).collect::<Vec<_>>() })),
            ("POST", ["needs", key, "remind"]) => {
                let key = urldecode(key);
                self.remind(&key, body["minutes"].as_i64());
                (202, json!({}))
            }
            ("GET", ["threads"]) => {
                let threads = self.threads();
                (200, json!({ "threads": threads.iter().map(|t| json!({ "id": t.id, "kind": format!("{:?}", t.kind).to_lowercase(), "title": t.title, "last": t.last, "activity": t.activity.map(|a| a.to_rfc3339()), "working": t.working, "unread": self.is_unread(t), "pinned": self.saved.pinned.contains(&t.id), "muted": self.saved.muted.contains(&t.id) })).collect::<Vec<_>>() }))
            }
            ("POST", ["threads", id, "read"]) => {
                self.mark_read(&urldecode(id), body["read"].as_bool().unwrap_or(true));
                (202, json!({}))
            }
            ("GET", ["approvals"]) => {
                let mut list = Vec::new();
                for (who, convo) in std::iter::once((Who::Main, &self.main)).chain(self.errands.iter().map(|e| (Who::Errand(e.saved.id.clone()), &e.convo))) {
                    for (request, (tool, input)) in &convo.asks {
                        list.push(json!({ "id": request, "kind": "permission", "thread": thread_id(&who), "summary": crate::marra::summarize(tool, input) }));
                    }
                }
                for c in &self.confirms {
                    list.push(json!({ "id": format!("send-{}", c.id), "kind": "send", "thread": format!("s:{}", c.session), "summary": format!("Send to {}: {}", c.title, c.text) }));
                }
                (200, json!({ "approvals": list }))
            }
            ("POST", ["approvals", id]) => {
                let allow = body["allow"].as_bool().unwrap_or(false);
                if let Some(n) = id.strip_prefix("send-").and_then(|n| n.parse::<u64>().ok()) {
                    // On the phone, the confirmation is the tap.
                    self.confirm(n, allow, cx);
                    return (202, json!({}));
                }
                let always = body["always"].as_bool().unwrap_or(false);
                let who = std::iter::once(Who::Main).chain(self.errands.iter().map(|e| Who::Errand(e.saved.id.clone()))).find(|w| self.convo(w).is_some_and(|c| c.asks.contains_key(*id)));
                match who {
                    Some(who) => {
                        if let Some(key) = self.convo_mut(&who).and_then(|c| c.decide(id, allow, always)) {
                            self.saved.always.push(key);
                            self.saved.save();
                        }
                        (202, json!({}))
                    }
                    None => (404, json!({ "error": "No such request; it may have been answered." })),
                }
            }
            ("GET", ["sessions"]) => (200, json!({ "sessions": self.sessions.clone().iter().map(|s| json!({ "id": s.key, "title": s.title, "kind": s.kind, "state": s.state.label(), "since": s.since.to_rfc3339(), "subject": s.subject, "server": s.server, "review_ready": s.review_ready.as_ref().map(|(kept, verdict)| json!({ "kept": kept, "verdict": verdict })), "new_commits": s.new_commits })).collect::<Vec<_>>() })),
            ("POST", ["sessions", key, "message"]) if !text.is_empty() => {
                let key = urldecode(key);
                match self.sessions.clone().into_iter().find(|s| s.key == key) {
                    Some(s) => {
                        s.page.update(cx, |page, cx| page.tell(&text, cx));
                        (202, json!({}))
                    }
                    None => (404, json!({ "error": "No such session." })),
                }
            }
            ("GET", ["workload"]) => {
                let work = self.work.clone();
                let pr = |p: &crate::work::Pr| json!({ "repo": p.repo, "number": p.number, "title": p.title, "url": p.url, "author": p.author, "standing": p.standing(), "needs": p.needs() });
                (200, json!({ "reviews": work.reviews.iter().map(pr).collect::<Vec<_>>(), "mine": work.mine.iter().map(pr).collect::<Vec<_>>(), "live": work.live }))
            }
            ("GET", ["errands", id]) => match self.errands.iter().find(|e| e.saved.id == *id) {
                Some(e) => (200, json!({ "id": e.saved.id, "title": e.saved.title, "point": e.saved.point, "needs_you": e.saved.needs, "conversation": convo_json(&e.convo) })),
                None => (404, json!({ "error": "No such errand." })),
            },
            ("POST", ["errands", id, "messages"]) if !text.is_empty() => match self.errands.iter_mut().find(|e| e.saved.id == *id) {
                Some(e) => {
                    e.saved.done = false;
                    e.convo.send(&text, &text);
                    (202, json!({}))
                }
                None => (404, json!({ "error": "No such errand." })),
            },
            _ => (404, json!({ "error": format!("No {method} /v1{path}") })),
        }
    }

    // MARK: Errands

    /// `harness` as list_skills names it. An errand runs where the harness's
    /// sessions run: on its server when one has run there, even when it's
    /// named by its folder on this Mac.
    pub fn start_errand(&mut self, kind: ErrandKind, ask: &str, harness: &str, skills: &[String]) -> Result<String, String> {
        let places = marra_mcp::harness_places();
        let place = places
            .iter()
            .find(|p| p.label() == harness)
            .or_else(|| places.iter().find(|p| p.local.as_deref() == Some(std::path::Path::new(harness)) || p.path == std::path::Path::new(harness)))
            .cloned();
        let (harness, server) = match place {
            Some(p) => (p.path, p.server),
            None if std::path::Path::new(harness).is_dir() => (PathBuf::from(harness), None),
            None => return Err(format!("{harness} isn't a harness Gannin knows: use one list_skills names.")),
        };
        let id = uuid::Uuid::new_v4().simple().to_string()[..8].to_string();
        let title = ask.lines().next().unwrap_or_default().chars().take(60).collect::<String>();
        let profile = Profile { cwd: harness.clone(), system: errand_brief(kind), session: None, model: self.saved.model.clone(), extra: errand_flags(), server: server.clone() };
        let mut convo = Convo::new(profile, errand_log(&id));
        let hint = if skills.is_empty() { String::new() } else { format!("\n\nSkills to start with: {}.", skills.join(", ")) };
        convo.send(ask, &format!("{ask}{hint}"));
        let saved = ErrandSaved { id: id.clone(), kind, title, harness, server, session: convo.engine.profile.session.clone(), created: marra::now(), point: None, needs: None, done: false };
        self.errands.push(Errand { saved, convo });
        self.save_errands();
        Ok(id)
    }

    /// New Issue: an Issue errand in the harness picked (as `harness_places`
    /// labels it), its worker asking what the issue is about.
    pub fn start_issue(&mut self, harness: &str, skills: &[String], about: &str) -> Result<String, String> {
        let about = about.trim();
        if about.is_empty() {
            return Err("Say what the issue is about first.".into());
        }
        let id = self.start_errand(ErrandKind::Issue, &issue_opening(about), harness, skills)?;
        if let Some(errand) = self.errands.iter_mut().find(|e| e.saved.id == id) {
            // Its thread is named by what it's about, so two at once are told apart.
            let first: String = about.lines().next().unwrap_or_default().chars().take(50).collect();
            errand.saved.title = format!("New issue: {first}");
        }
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
            "list_sessions" => Ok(describe_sessions(&self.sessions.clone())),
            "waiting" => {
                let needs = self.needs(None);
                Ok(if needs.is_empty() { "Nothing needs the user right now.".into() } else { needs.iter().map(|n| format!("- {}: {} ({}; {})", n.subject, n.task, n.detail, waiting(n.since))).collect::<Vec<_>>().join("\n") })
            }
            "read_session" => match self.sessions.clone().into_iter().find(|s| s.key == id) {
                None => Err(format!("No session {id}. Call list_sessions for the ids.")),
                Some(s) => {
                    let count = call.args["messages"].as_u64().unwrap_or(12) as usize;
                    let since: Option<chrono::DateTime<chrono::Utc>> = call.args["since"].as_str().and_then(|t| t.parse().ok());
                    let head = format!("{} ({}, {} since {}):\n\n", s.title, s.kind, s.state.label(), s.since.format("%H:%M"));
                    if s.kind == "terminal" {
                        Ok(format!("{head}{}", s.page.read(cx).screen_tail(60, cx)))
                    } else {
                        // A transcript can be large: read it off the main thread.
                        let screen = s.page.read(cx).screen_tail(60, cx);
                        let (claude, folder, on_server) = (s.claude_id.clone(), s.folder.clone(), s.server.is_some());
                        std::thread::spawn(move || {
                            let lines = marra_mcp::resolve_claude(claude, &folder, on_server).and_then(|id| match since {
                                Some(_) => marra_mcp::transcript_since(&id, since, 150, 600),
                                None => marra_mcp::transcript_since(&id, None, count, 2000),
                            });
                            let body = match lines {
                                Some(lines) if lines.is_empty() => "(nothing since then)".to_string(),
                                Some(lines) => marra_mcp::as_text(lines),
                                None => screen,
                            };
                            let _ = reply.send(Ok(format!("{head}{body}")));
                        });
                        return;
                    }
                }
            },
            "open_tab" => {
                if self.open_session(&id, cx) {
                    Ok("Brought it forward.".into())
                } else {
                    Err(format!("No session {id}."))
                }
            }
            "workload" => Ok(describe_work(&self.work.clone())),
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
                let harness = call.args["harness"].as_str().unwrap_or_default().to_string();
                self.start_errand(kind, call.args["ask"].as_str().unwrap_or_default(), &harness, &skills).map(|id| format!("Started errand {id}. It shows as a thread of its own and reports back there; you needn't wait for it."))
            }
            "send_to_session" => match self.sessions.clone().into_iter().find(|s| s.key == id) {
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
            match self.sessions.clone().into_iter().find(|s| s.key == confirm.session) {
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
        // The window whose org and harness suit the PR, one on a server
        // first: Marra's own window is usually the active one, and the first
        // window may be a local folder, which would run it on this Mac.
        let fits = Workspace::review_window_for(&subject.repo, cx);
        let target = fits.or_else(|| cx.active_window().and_then(|w| w.downcast::<Workspace>())).or_else(|| cx.windows().into_iter().find_map(|w| w.downcast::<Workspace>()));
        if let Some(window) = target {
            let _ = window.update(cx, |workspace, window, cx| {
                workspace.review_for_marra(subject, window, cx);
                window.activate_window();
            });
        }
    }

    /// Brings a session's window forward on its tab.
    pub fn open_session(&mut self, key: &str, cx: &mut App) -> bool {
        let Some(s) = self.sessions.clone().into_iter().find(|s| s.key == key) else { return false };
        let id = s.id;
        s.window
            .update(cx, |workspace, window, cx| {
                workspace.reveal_session(id, window, cx);
                window.activate_window();
            })
            .is_ok()
    }

    /// Presses a review session's button in its panel; for Post Review, with
    /// its tab brought forward, where the sheet to confirm it opens.
    pub fn press_review(&mut self, key: &str, button: ReviewButton, cx: &mut App) {
        let Some(s) = self.sessions.clone().into_iter().find(|s| s.key == key) else { return };
        let (id, page) = (s.id, s.page.clone());
        let _ = s.window.update(cx, |workspace, window, cx| {
            let Some(review) = page.read(cx).review() else { return };
            if button == ReviewButton::Post {
                workspace.reveal_session(id, window, cx);
                window.activate_window();
            }
            review.update(cx, |review, cx| match button {
                ReviewButton::Post => review.start_post(window, cx),
                ReviewButton::Again => review.review_again(window, cx),
                ReviewButton::Check => review.check_for_changes(cx),
            });
        });
    }

    /// A session's issue in a drawer in the session's window; a PR, or an
    /// issue that window doesn't have, on GitHub.
    pub fn open_subject(&mut self, key: &str, cx: &mut App) {
        let Some(s) = self.sessions.clone().into_iter().find(|s| s.key == key) else { return };
        let Some(subject) = s.subject_link else { return };
        let shown = s
            .window
            .update(cx, |workspace, window, cx| {
                let shown = workspace.open_subject_for_marra(&subject, window, cx);
                if shown {
                    window.activate_window();
                }
                shown
            })
            .unwrap_or(false);
        if !shown {
            cx.open_url(&subject.url);
        }
    }

    // MARK: Needs you

    /// What needs the user, in order; `org` narrows it.
    pub fn needs(&self, org: Option<&str>) -> Vec<Need> {
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
                        since: convo.asked_at.get(request).copied().unwrap_or(now),
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
        for s in self.sessions.clone() {
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
            // New commits on a review's PR since the review: until Review
            // Again catches up. The count is in the task (and so the key),
            // so another push tells again.
            if s.new_commits > 0 {
                let n = s.new_commits;
                let task = format!("{n} new commit{} since the review", if n == 1 { "" } else { "s" });
                out.push(Need { since: s.new_commits_since, ..base(1, &task, "Review Again to catch up".into()) });
            }
            if let Some((kept, verdict)) = &s.review_ready {
                let verdict = verdict.clone().map(|v| format!("{v}, ")).unwrap_or_default();
                out.push(base(1, "Review ready to post", format!("{verdict}{kept} finding{} kept", if *kept == 1 { "" } else { "s" })));
                continue;
            }
            match s.state {
                State::NeedsYou => out.push(base(0, "Waiting for you", format!("{} has a question or a permission on screen", s.title))),
                // Only until you've looked: opening it, its thread, or Done.
                State::YourTurn if s.kind != "terminal" && !self.looked_since(&thread, s.since) => {
                    out.push(Need { actions: vec![("Done".into(), Act::MarkRead(thread.clone()))], ..base(1, "Finished; your turn", s.title.clone()) })
                }
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
        let work = self.work.clone();
        let org_of = |repo: &str| repo.split('/').next().map(str::to_string);
        let subjects: Vec<String> = self.sessions.clone().into_iter().filter_map(|s| s.subject).collect();
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
                pr: None,
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
        out.retain(|n| !self.saved.snoozed.contains_key(&n.key) && !self.saved.dismissed.contains(&n.key));
        for n in &mut out {
            n.returned = self.returned.contains(&n.key);
        }
        // Only orgs with a harness (once known, so nothing's hidden before).
        if !self.harness_orgs.is_empty() {
            out.retain(|n| n.org.as_deref().is_none_or(|o| self.harness_orgs.iter().any(|h| h.eq_ignore_ascii_case(o))));
        }
        if let Some(org) = org {
            out.retain(|n| n.org.as_deref().is_none_or(|o| o == org));
        }
        out.sort_by_key(|n| (!n.returned, n.rank, n.since));
        out
    }

    /// Parks an item: back after `minutes`, or (None) when its PR's CI passes.
    pub fn remind(&mut self, key: &str, minutes: Option<i64>) {
        let pr = self.needs(None).into_iter().find(|n| n.key == key).and_then(|n| n.pr);
        let when = match (minutes, pr) {
            (Some(m), _) => (Local::now() + chrono::Duration::minutes(m)).to_rfc3339(),
            (None, Some(url)) => format!("ci:{url}"),
            (None, None) => (Local::now() + chrono::Duration::minutes(60)).to_rfc3339(),
        };
        self.saved.snoozed.insert(key.to_string(), when);
        self.returned.remove(key);
        self.saved.save();
    }

    /// Hides an item for good: no reminder brings it back.
    pub fn dismiss(&mut self, key: &str) {
        self.saved.snoozed.remove(key);
        self.returned.remove(key);
        if !self.saved.dismissed.iter().any(|k| k == key) {
            self.saved.dismissed.push(key.to_string());
        }
        self.saved.save();
    }

    /// Reminders due come back; new items notify; blocked ones are
    /// mentioned again at 15 minutes and an hour.
    fn check_needs(&mut self) {
        let now = Local::now();
        let work = self.work.clone();
        let due: Vec<String> = self
            .saved
            .snoozed
            .iter()
            .filter(|(_, when)| match when.as_str() {
                when => match when.strip_prefix("ci:") {
                    // Back when its checks pass, or when the PR has gone.
                    Some(url) => work.mine.iter().find(|pr| pr.url == url).is_none_or(|pr| pr.checks.as_deref() == Some("SUCCESS")),
                    None => DateTime::parse_from_rfc3339(when).is_ok_and(|w| w <= now),
                },
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
        let needs = self.needs(None);
        let keys: HashSet<String> = needs.iter().map(|n| n.key.clone()).collect();
        // A PR parked until CI passed whose item has gone (its checks were
        // what it needed): say so once.
        for key in due.iter().filter(|k| !keys.contains(*k) && k.starts_with("mine:")) {
            let url = key.trim_start_matches("mine:").rsplit_once(':').map_or(key.as_str(), |(u, _)| u).to_string();
            if let Some(pr) = work.mine.iter().find(|p| p.url == url) {
                notify(&format!("{}#{}", pr.short_repo(), pr.number), "Back: its checks passed.");
            }
        }
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
        // A parked item's key stays seen, so it comes back as "back", not new.
        self.seen.retain(|k| keys.contains(k) || self.saved.snoozed.contains_key(k));
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
        notify_thread(need.thread.clone(), &need.subject, &format!("{}. {}", need.task, need.detail));
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

    pub fn threads(&self) -> Vec<Thread> {
        let mut out = vec![Thread { id: "main".into(), kind: ThreadKind::Main, title: "Marra".into(), last: self.main.last_line(), activity: self.main.activity(), working: self.main.busy(), org: None }];
        for e in &self.errands {
            out.push(Thread {
                id: format!("e:{}", e.saved.id),
                kind: match e.saved.kind {
                    ErrandKind::Investigation => ThreadKind::Investigation,
                    ErrandKind::Issue => ThreadKind::Issue,
                    ErrandKind::Question => ThreadKind::Question,
                },
                title: e.saved.title.clone(),
                last: e.saved.point.clone().filter(|_| !e.convo.busy()).unwrap_or_else(|| e.convo.last_line()),
                activity: e.convo.activity(),
                working: e.convo.busy(),
                org: None,
            });
        }
        for s in self.sessions.clone() {
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

    /// Whether the user has opened or dismissed this thread since `at`.
    fn looked_since(&self, thread: &str, at: DateTime<Local>) -> bool {
        self.saved.read.get(thread).and_then(|r| DateTime::parse_from_rfc3339(r).ok()).is_some_and(|read| read >= at)
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

/// Notifications waiting for the tick to post them: (thread, title, body).
static PENDING: std::sync::Mutex<Vec<(Option<String>, String, String)>> = std::sync::Mutex::new(Vec::new());

/// A notification, posted on the next tick as Gannin's own (its name and
/// icon; osascript's came from Script Editor). Clicking it opens Marra.
pub fn notify(title: &str, body: &str) {
    notify_thread(None, title, body);
}

/// The same, opening `thread` in Marra when clicked.
pub fn notify_thread(thread: Option<String>, title: &str, body: &str) {
    if let Ok(mut pending) = PENDING.lock() {
        pending.push((thread, title.to_string(), body.to_string()));
    }
}

/// Posts what's waiting. The tag is the thread (a newer notification for a
/// thread replaces its older one), and it comes back on a click.
fn post_notifications(cx: &mut App) {
    let pending: Vec<_> = PENDING.lock().map(|mut p| std::mem::take(&mut *p)).unwrap_or_default();
    for (thread, title, body) in pending {
        let tag = match thread {
            Some(thread) => format!("thread:{thread}"),
            None => format!("marra:{}", uuid::Uuid::new_v4()),
        };
        cx.show_system_notification(gpui::SystemNotification { tag: tag.into(), title: title.into(), body: body.into(), actions: Vec::new() });
    }
}

fn need_json(n: &Need) -> serde_json::Value {
    serde_json::json!({
        "key": n.key,
        "subject": n.subject,
        "task": n.task,
        "detail": n.detail,
        "since": n.since.to_rfc3339(),
        "waiting": waiting(n.since),
        "blocked": n.rank == 0,
        "back": n.returned,
        "thread": n.thread,
        "lane": n.lane.title(),
        "actions": n.actions.iter().map(|(label, _)| label).collect::<Vec<_>>(),
    })
}

/// A path segment's %-escapes undone (a session id's colon may arrive as %3A).
fn urldecode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            // Bytes, not a str slice: a % before a multibyte character mustn't panic.
            if let Some(b) = std::str::from_utf8(&bytes[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
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
    fn decodes_paths() {
        assert_eq!(urldecode("12%3A3"), "12:3");
        assert_eq!(urldecode("plain"), "plain");
        assert_eq!(urldecode("bad%2"), "bad%2");
        assert_eq!(urldecode("%aé"), "%aé");
    }

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
