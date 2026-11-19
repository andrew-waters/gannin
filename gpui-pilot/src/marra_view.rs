//! Marra's window (docs/marra.md): Needs you at the top, the threads under
//! it, a thread's conversation, and the input. The same view floats in a
//! window of its own or docks down the right of a Gannin window; both show
//! the one `Marra` model.

use crate::charts::Theme;
use crate::marra::Entry;
use crate::marra_model::{self, ago, waiting, Act, Lane, Marra, Need, Thread, ThreadKind, Who};
use crate::markdown::markdown;
use crate::shell::Workspace;
use gpui::{actions, div, prelude::*, px, relative, AnyElement, App, ClickEvent, Context, Entity, FocusHandle, Focusable, FontWeight, Hsla, KeyDownEvent, Pixels, Point, SharedString, Subscription, Task, Window};
use std::collections::HashSet;
use std::time::{Duration, Instant};

actions!(marra, [ToggleMarra]);

/// Remind me's choices: label and minutes (None: when CI passes).
const REMIND: [(&str, Option<i64>); 7] = [("5m", Some(5)), ("10m", Some(10)), ("15m", Some(15)), ("30m", Some(30)), ("1h", Some(60)), ("Tomorrow", Some(-1)), ("When CI passes", None)];

/// The models offered in the menu; any other goes with /model.
const MODELS: [(&str, Option<&str>); 4] = [("Claude's default", None), ("Opus", Some("opus")), ("Sonnet", Some("sonnet")), ("Haiku", Some("haiku"))];

const COMMANDS: [(&str, &str); 15] = [
    ("/waiting", "What needs you now"),
    ("/catch-up", "Sum up the unread threads"),
    ("/ask", "A data question, answered by a worker in a harness"),
    ("/investigate", "Investigate a ticket or bug with the harness skills"),
    ("/review", "Review requests waiting on you"),
    ("/standup", "Yesterday and today, from your work"),
    ("/open", "Bring a session's tab forward"),
    ("/later", "Park the top item for 30 minutes"),
    ("/todo", "Add a todo: /todo send the invoice"),
    ("/compact", "Compact Marra's conversation"),
    ("/new", "Start a new conversation"),
    ("/model", "Marra's model: /model sonnet, /model default"),
    ("/notes", "Edit Marra's notes about you"),
    ("/save", "Save your last message as a command: /save name"),
    ("/help", "What Marra can do"),
];

/// New Issue's picker: the harness, once picked (its label for the errand,
/// and its name as shown), then its skills, each ticked or not.
#[derive(Clone, Default)]
struct IssuePick {
    harness: Option<(String, String)>,
    skills: Vec<(String, String, bool)>,
}

/// Skills a new issue inherits unticking nothing: those about issues and
/// the planning around them, by their name or description.
fn issue_skill(name: &str, _about: &str) -> bool {
    name.to_lowercase().contains("issue")
}

/// A harness as the picker names it: its folder, and its server if any.
fn place_name(place: &crate::marra_mcp::HarnessPlace) -> String {
    let name = place.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| place.label());
    match &place.server {
        Some(server) => format!("{name} on {}", server.name()),
        None => name,
    }
}

pub struct MarraView {
    marra: Entity<Marra>,
    docked: bool,
    focus: FocusHandle,
    composer: Entity<editor::Editor>,
    /// The thread open: "main", "e:<id>" or "s:<window:id>".
    open: Option<String>,
    /// The org the window is narrowed to.
    scope: Option<String>,
    unread_only: bool,
    lane: Option<Lane>,
    /// Which item of Needs you is the top card.
    selected: usize,
    more_open: bool,
    later_menu: bool,
    scope_menu: bool,
    more_menu: bool,
    /// New Issue's picker in the thread list, while it's open.
    issue_pick: Option<IssuePick>,
    /// Narrows New Issue's skill list by name or description.
    skill_filter: Entity<editor::Editor>,
    /// New Issue's first message: what it's about, sent as the worker starts.
    issue_about: Entity<editor::Editor>,
    /// The open thread's conversation scroll, which follows new activity
    /// while it's at the bottom.
    chat_scroll: gpui::ScrollHandle,
    /// The thread it was last showing, to start a newly opened one at its end.
    chat_for: Option<String>,
    /// The checklist, as last read or changed (`todos.rs`).
    todos: Vec<crate::todos::Todo>,
    /// Whether the composer's placeholder says it adds a todo.
    todo_placeholder: bool,
    /// Why New Issue couldn't start, shown until the next try.
    issue_error: Option<String>,
    row_menu: Option<(String, Point<Pixels>)>,
    menu_closed: Option<Instant>,
    /// Phone access's address and paired devices, read as the menu opens
    /// (not on every frame).
    phone: (Option<String>, usize),
    suggest: usize,
    suggest_closed: Option<String>,
    long_open: HashSet<(String, usize)>,
    /// What @ inserted, and the exact id it stands for.
    mentions: Vec<(String, String)>,
    /// The skills the harnesses offer, for @.
    skills: Vec<String>,
    /// Saved prompts offered as / commands, the user's and the team's.
    saved_commands: Vec<crate::marra_mcp::SavedCommand>,
    /// A session thread's conversation, read from its transcript.
    tail: Option<(String, Vec<(String, String)>)>,
    /// What the session did since it was last read, taken as it opened.
    since: Option<(String, Vec<(chrono::DateTime<chrono::Local>, String)>, Option<chrono::DateTime<chrono::Local>>)>,
    /// The open session's digest since the last look, from its transcript
    /// (None inside when there's no transcript to read).
    digest: Option<(String, Option<crate::marra_mcp::Digest>)>,
    /// Haiku's summary of the open session since the last look, or why it
    /// couldn't; and the session being summarised now.
    summary: Option<(String, Result<String, String>)>,
    summarising: Option<String>,
    /// The open session's summary calls, from the audit trail: by session key.
    audit: Option<(String, Vec<crate::marra::SummaryCall>)>,
    /// Calls in the trail shown open, and those showing their prompt.
    audit_open: HashSet<(String, usize)>,
    audit_prompts: HashSet<(String, usize)>,
    _tail_task: Option<Task<()>>,
    theme: Theme,
    _subscriptions: Vec<Subscription>,
}

impl MarraView {
    pub fn new(docked: bool, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let marra = Marra::get(cx);
        let composer = cx.new(|cx| {
            // One line to start, growing as the text wraps or takes new
            // lines, up to ten, then scrolling.
            let mut editor = editor::Editor::auto_height(1, 10, window, cx);
            editor.set_soft_wrap_mode(language::language_settings::SoftWrap::EditorWidth, cx);
            editor.set_placeholder_text("Message Marra", window, cx);
            editor
        });
        let issue_about = cx.new(|cx| {
            let mut editor = editor::Editor::auto_height(2, 8, window, cx);
            editor.set_soft_wrap_mode(language::language_settings::SoftWrap::EditorWidth, cx);
            editor.set_placeholder_text("What's the issue about?", window, cx);
            editor
        });
        let about_edits = cx.subscribe(&issue_about, |_: &mut Self, _, event: &editor::EditorEvent, cx| {
            if matches!(event, editor::EditorEvent::BufferEdited) {
                cx.notify();
            }
        });
        let skill_filter = cx.new(|cx| {
            let mut editor = editor::Editor::single_line(window, cx);
            editor.set_placeholder_text("Filter skills", window, cx);
            editor
        });
        let filtering = cx.subscribe(&skill_filter, |_: &mut Self, _, event: &editor::EditorEvent, cx| {
            if matches!(event, editor::EditorEvent::BufferEdited) {
                cx.notify();
            }
        });
        let edits = cx.subscribe(&composer, |this: &mut Self, _, event: &editor::EditorEvent, cx| {
            if matches!(event, editor::EditorEvent::BufferEdited) {
                this.suggest = 0;
                cx.notify();
            }
        });
        // Marra's changes redraw it; an open thread stays read as it grows.
        let observe = cx.observe(&marra, |this: &mut Self, marra, cx| {
            if let Some(open) = this.open.clone() {
                let thread = marra.read(cx).threads().into_iter().find(|t| t.id == open);
                if thread.is_some_and(|t| marra.read(cx).is_unread(&t)) {
                    marra.update(cx, |m, _| m.mark_read(&open, true));
                }
            }
            cx.notify();
        });
        window.focus(&composer.focus_handle(cx), cx);
        if !docked && !marra.read(cx).saved.not_on_top {
            keep_up(window);
        }
        let skills: Vec<String> = crate::marra_mcp::skills().lines().filter_map(|l| l.trim_start().strip_prefix("- ")).map(|l| l.split(':').next().unwrap_or(l).trim().to_string()).collect();
        let mut this = Self {
            marra,
            docked,
            focus: cx.focus_handle(),
            composer,
            open: None,
            scope: None,
            unread_only: false,
            lane: None,
            selected: 0,
            more_open: false,
            later_menu: false,
            scope_menu: false,
            more_menu: false,
            issue_pick: None,
            skill_filter,
            issue_about,
            issue_error: None,
            chat_scroll: gpui::ScrollHandle::new(),
            chat_for: None,
            todos: crate::todos::load(),
            todo_placeholder: false,
            row_menu: None,
            menu_closed: None,
            phone: (None, 0),
            suggest: 0,
            suggest_closed: None,
            long_open: HashSet::new(),
            mentions: Vec::new(),
            skills,
            saved_commands: crate::marra_mcp::saved_commands(),
            tail: None,
            since: None,
            digest: None,
            summary: None,
            summarising: None,
            audit: None,
            audit_open: HashSet::new(),
            audit_prompts: HashSet::new(),
            _tail_task: None,
            theme: Theme::for_window(window),
            _subscriptions: vec![edits, observe, filtering, about_edits],
        };
        // In its own window the list and a thread show side by side, so
        // one's always open: the main conversation to start.
        if this.split() {
            this.open_thread("main".into(), cx);
        }
        this
    }

    /// Threads on the left and the open one on the right: in Marra's own
    /// window. Docked in a Gannin window it's one column, too narrow for two.
    fn split(&self) -> bool {
        !self.docked
    }

    pub fn focus_input(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.composer.focus_handle(cx), cx);
    }

    fn just_closed(&self) -> bool {
        self.menu_closed.is_some_and(|at| at.elapsed() < Duration::from_millis(300))
    }

    fn close_menus(&mut self) {
        self.scope_menu = false;
        self.more_menu = false;
        self.row_menu = None;
        self.menu_closed = Some(Instant::now());
    }

    /// Starts New Issue with the harness and skills picked, and what it's
    /// about as the worker's first message; opens its thread.
    fn start_issue(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((label, _)) = self.issue_pick.as_ref().and_then(|p| p.harness.clone()) else { return };
        let about = self.issue_about.read(cx).text(cx).trim().to_string();
        if about.is_empty() {
            return;
        }
        let skills: Vec<String> = self.issue_pick.as_ref().map(|p| p.skills.iter().filter(|s| s.2).map(|s| s.0.clone()).collect()).unwrap_or_default();
        let started = self.marra.update(cx, |m, cx| {
            let started = m.start_issue(&label, &skills, &about);
            cx.notify();
            started
        });
        match started {
            Ok(id) => {
                self.issue_pick = None;
                self.issue_error = None;
                self.issue_about.update(cx, |editor, cx| editor.set_text("", window, cx));
                self.open_thread(format!("e:{id}"), cx);
                self.focus_input(window, cx);
            }
            Err(error) => self.issue_error = Some(error),
        }
        cx.notify();
    }

    // MARK: Queries

    fn needs(&self, cx: &App) -> Vec<Need> {
        let mut needs = self.marra.read(cx).needs(self.scope.as_deref());
        if let Some(lane) = self.lane {
            needs.retain(|n| n.lane == lane);
        }
        needs
    }

    fn listed(&self, cx: &App) -> Vec<Thread> {
        let marra = self.marra.read(cx);
        let mut threads = marra.threads();
        if let Some(scope) = &self.scope {
            threads.retain(|t| t.org.as_deref().is_none_or(|o| o == scope));
        }
        if self.unread_only {
            threads.retain(|t| marra.is_unread(t) || t.kind == ThreadKind::Main);
        }
        // Main first, then the newest; pinned ones lead.
        threads.sort_by(|a, b| (b.kind == ThreadKind::Main).cmp(&(a.kind == ThreadKind::Main)).then(b.activity.cmp(&a.activity)));
        // The checklist next, always: it isn't a conversation.
        let open: Vec<&crate::todos::Todo> = self.todos.iter().filter(|t| t.done.is_none()).collect();
        let last = match open.len() {
            0 => "Nothing to do".to_string(),
            1 => open[0].text.clone(),
            n => format!("{n} to do: {}", open[0].text),
        };
        let at = threads.iter().position(|t| t.kind != ThreadKind::Main).unwrap_or(threads.len());
        threads.insert(at, Thread { id: "todos".into(), kind: ThreadKind::Todos, title: "Todos".into(), last, activity: None, working: false, org: None });
        threads
    }

    /// The scopes: the orgs you have a harness in, not every org with a PR.
    fn orgs(&self, cx: &App) -> Vec<String> {
        self.marra.read(cx).harness_orgs.clone()
    }

    // MARK: Doing

    fn open_thread(&mut self, id: String, cx: &mut Context<Self>) {
        self.since = id.strip_prefix("s:").map(|key| {
            let m = self.marra.read(cx);
            (key.to_string(), m.since_read(key), m.read_at(key))
        });
        self.digest = None;
        self.audit = None;
        if self.summary.as_ref().is_some_and(|(k, _)| Some(k.as_str()) != id.strip_prefix("s:")) {
            self.summary = None;
        }
        self.marra.update(cx, |m, _| m.mark_read(&id, true));
        self.tail = None;
        self._tail_task = None;
        if let Some(key) = id.strip_prefix("s:").map(str::to_string) {
            self.watch_session(key, cx);
        }
        self.open = Some(id);
        self.later_menu = false;
        cx.notify();
    }

    fn back(&mut self, cx: &mut Context<Self>) {
        if let Some(open) = self.open.take() {
            self.marra.update(cx, |m, _| m.mark_read(&open, true));
        }
        self.tail = None;
        self._tail_task = None;
        cx.notify();
    }

    /// Reads a session's conversation now and every few seconds while its
    /// thread is open.
    fn watch_session(&mut self, key: String, cx: &mut Context<Self>) {
        let info = marra_model::sessions(cx).into_iter().find(|s| s.key == key);
        let (claude, folder, on_server, trail) = info.map(|s| (s.claude_id, s.folder, s.server.is_some(), crate::marra::Trail { server: s.remote, harness: s.harness })).unwrap_or((None, std::path::PathBuf::new(), true, crate::marra::Trail::default()));
        let read_at = self.since.as_ref().filter(|(k, _, _)| k == &key).and_then(|(_, _, at)| *at).map(|at| at.with_timezone(&chrono::Utc));
        let mut audited = false;
        self._tail_task = Some(cx.spawn(async move |this, cx| loop {
            let (claude, folder, trail) = (claude.clone(), folder.clone(), trail.clone());
            let first = !audited;
            audited = true;
            let (lines, digest, audit) = cx
                .background_executor()
                .spawn(async move {
                    // A plain tab from before tabs had a conversation ID: its
                    // folder's newest transcript.
                    match crate::marra_mcp::resolve_claude(claude, &folder, on_server) {
                        Some(id) => (
                            crate::marra_mcp::transcript_messages(&id, 30).unwrap_or_default(),
                            crate::marra_mcp::digest(&id, read_at),
                            // The trail once, when the thread opens; a new call adds itself.
                            first.then(|| crate::marra::summary_calls(&id, &trail)),
                        ),
                        None => (Vec::new(), None, first.then(Vec::new)),
                    }
                })
                .await;
            let key = key.clone();
            let gone = this
                .update(cx, |this, cx| {
                    if this.tail.as_ref().is_none_or(|(k, l)| k != &key || l != &lines) {
                        this.tail = Some((key.clone(), lines));
                        cx.notify();
                    }
                    if let Some(audit) = audit {
                        this.audit = Some((key.clone(), audit));
                        cx.notify();
                    }
                    if this.digest.as_ref().is_none_or(|(k, d)| k != &key || d != &digest) {
                        this.digest = Some((key, digest));
                        cx.notify();
                    }
                })
                .is_err();
            if gone {
                return;
            }
            cx.background_executor().timer(Duration::from_secs(3)).await;
        }));
    }

    /// Asks Haiku what a session did since the last look, from its
    /// transcript: one call, no tools, shown in its thread.
    fn summarise_session(&mut self, key: String, cx: &mut Context<Self>) {
        let Some(info) = marra_model::sessions(cx).into_iter().find(|s| s.key == key) else { return };
        if self.summarising.is_some() {
            return;
        }
        let read_at = self.since.as_ref().filter(|(k, _, _)| k == &key).and_then(|(_, _, at)| *at).map(|at| at.with_timezone(&chrono::Utc));
        let title = info.subject.clone().map(|s| format!("{s}: {}", info.title)).unwrap_or(info.title.clone());
        let (claude, folder, on_server) = (info.claude_id.clone(), info.folder.clone(), info.server.is_some());
        let trail = crate::marra::Trail { server: info.remote.clone(), harness: info.harness.clone() };
        let model = self.marra.read(cx).saved.summary_model.clone();
        self.summarising = Some(key.clone());
        self.summary = None;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let id = crate::marra_mcp::resolve_claude(claude, &folder, on_server).ok_or("Its conversation isn't on this Mac.")?;
                    let lines = crate::marra_mcp::transcript_since(&id, read_at, 150, 600).ok_or("Couldn't read its conversation.")?;
                    if lines.is_empty() {
                        return Err("Nothing has happened since you looked, so nothing was sent.".to_string());
                    }
                    let since = if read_at.is_some() { "since they last looked" } else { "so far" };
                    let prompt = format!(
                        "Summarise what happened in this Claude Code session {since}, for the person who owns it. They switch between several sessions, so lead with where it stands now and what, if anything, it needs from them; then what was done and what changed. At most six short bullets, plain words, no preamble.\n\nSession: {title}\n\nConversation:\n\n{}",
                        crate::marra_mcp::as_text(lines)
                    );
                    Ok(crate::marra::summarise(&prompt, model.as_deref(), &id, &title, read_at.map(|at| at.to_rfc3339()), &trail))
                })
                .await;
            this.update(cx, |this, cx| {
                this.summarising = None;
                let shown = match &result {
                    Ok(call) => match (&call.output, &call.error) {
                        (Some(text), _) => Ok(text.clone()),
                        (None, error) => Err(error.clone().unwrap_or_else(|| "It gave nothing back.".into())),
                    },
                    Err(error) => Err(error.clone()),
                };
                if let Ok(call) = result {
                    match this.audit.as_mut().filter(|(k, _)| k == &key) {
                        Some((_, calls)) => calls.push(call),
                        None => this.audit = Some((key.clone(), vec![call])),
                    }
                }
                this.summary = Some((key, shown));
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn act(&mut self, act: Act, window: &mut Window, cx: &mut Context<Self>) {
        match act {
            Act::OpenSession(key) => {
                self.marra.update(cx, |m, _| m.mark_read(&format!("s:{key}"), true));
                // After this window's update: a docked Marra's own window is
                // lent out until then, and it may be the one to show.
                let marra = self.marra.clone();
                cx.defer(move |cx| {
                    marra.update(cx, |m, cx| {
                        m.open_session(&key, cx);
                    });
                });
            }
            Act::OpenThread(id) => self.open_thread(id, cx),
            Act::Url(url) => cx.open_url(&url),
            Act::MarkRead(thread) => self.marra.update(cx, |m, cx| {
                m.mark_read(&thread, true);
                cx.notify();
            }),
            Act::OpenSubject(key) => {
                // After this window's update, as for a session.
                let marra = self.marra.clone();
                cx.defer(move |cx| marra.update(cx, |m, cx| m.open_subject(&key, cx)));
            }
            Act::Review(key, button) => {
                // After this window's update: the review's window may be
                // Marra's own when docked, lent out until then.
                let marra = self.marra.clone();
                cx.defer(move |cx| marra.update(cx, |m, cx| m.press_review(&key, button, cx)));
            }
            Act::StartReview(subject) => {
                let marra = self.marra.clone();
                cx.defer(move |cx| marra.update(cx, |m, cx| m.start_review(subject, cx)));
            }
            Act::Allow(who, request, always) => self.marra.update(cx, |m, cx| {
                if let Some(key) = m.convo_mut(&who).and_then(|c| c.decide(&request, true, always)) {
                    m.saved.always.push(key);
                    m.saved.save();
                }
                cx.notify();
            }),
            Act::Deny(who, request) => self.marra.update(cx, |m, cx| {
                if let Some(c) = m.convo_mut(&who) {
                    c.decide(&request, false, false);
                }
                cx.notify();
            }),
            Act::Confirm(id, send) => self.marra.update(cx, |m, cx| m.confirm(id, send, cx)),
            Act::Reply(errand, action) => {
                self.marra.update(cx, |m, cx| {
                    if let Some(e) = m.errands.iter_mut().find(|e| e.saved.id == errand) {
                        e.saved.needs = None;
                        e.convo.send(&action, &action);
                    }
                    cx.notify();
                });
                self.open_thread(format!("e:{errand}"), cx);
            }
        }
        self.selected = 0;
        self.later_menu = false;
        let _ = window;
        cx.notify();
    }

    /// Dismiss: the item's gone for good.
    fn dismiss(&mut self, key: String, cx: &mut Context<Self>) {
        self.marra.update(cx, |m, cx| {
            m.dismiss(&key);
            cx.notify();
        });
        self.later_menu = false;
        self.selected = 0;
        cx.notify();
    }

    fn remind(&mut self, key: String, minutes: Option<i64>, cx: &mut Context<Self>) {
        // Tomorrow is nine in the morning.
        let minutes = minutes.map(|m| {
            if m >= 0 {
                return m;
            }
            let now = chrono::Local::now();
            let nine = (now + chrono::Duration::days(1)).date_naive().and_hms_opt(9, 0, 0).unwrap_or_default();
            (nine - now.naive_local()).num_minutes().max(1)
        });
        self.marra.update(cx, |m, cx| {
            m.remind(&key, minutes);
            cx.notify();
        });
        self.later_menu = false;
        self.selected = 0;
        cx.notify();
    }

    fn send(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.composer.read(cx).text(cx).trim().to_string();
        if text.is_empty() {
            return;
        }
        // A todo, with the checklist open or /todo from anywhere: kept here,
        // never sent to Marra.
        let todo = match text.strip_prefix("/todo ").map(str::trim) {
            Some(todo) => Some(todo),
            None => (self.open.as_deref() == Some("todos")).then_some(text.as_str()),
        };
        if let Some(todo) = todo {
            crate::todos::add(&mut self.todos, todo);
            self.composer.update(cx, |editor, cx| editor.set_text("", window, cx));
            cx.notify();
            return;
        }
        self.composer.update(cx, |editor, cx| editor.set_text("", window, cx));
        let mentions = std::mem::take(&mut self.mentions);
        let used: Vec<String> = mentions.iter().filter(|(token, _)| text.contains(token.as_str())).map(|(token, id)| format!("{token} is {id}")).collect();
        let sent = if used.is_empty() { text.clone() } else { format!("{text}\n\n(Mentioned: {}.)", used.join("; ")) };
        match self.open.clone() {
            Some(id) if id.starts_with("s:") => {
                // Typed by the user into the session's Claude Code, as they would there.
                let key = id[2..].to_string();
                if let Some(s) = marra_model::sessions(cx).into_iter().find(|s| s.key == key) {
                    s.page.update(cx, |page, cx| page.tell(&text, cx));
                }
            }
            Some(id) if id.starts_with("e:") => {
                let errand = id[2..].to_string();
                self.marra.update(cx, |m, cx| {
                    if let Some(e) = m.errands.iter_mut().find(|e| e.saved.id == errand) {
                        e.saved.done = false;
                        e.convo.send(&text, &sent);
                    }
                    cx.notify();
                });
            }
            _ => {
                if !self.command(&text, window, cx) {
                    let scoped = match &self.scope {
                        Some(org) => format!("{sent}\n\n(The window is narrowed to the {org} org.)"),
                        None => sent,
                    };
                    self.marra.update(cx, |m, cx| {
                        m.main.send(&text, &scoped);
                        cx.notify();
                    });
                }
                if self.open.is_none() {
                    self.open_thread("main".into(), cx);
                }
            }
        }
        cx.notify();
    }

    /// A / command: Gannin answers the instant ones from its own state; the
    /// prompted ones go to Marra as a saved prompt. False when it isn't one.
    fn command(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let Some(rest) = text.strip_prefix('/') else { return false };
        let (name, arg) = rest.split_once(char::is_whitespace).map(|(n, a)| (n, a.trim())).unwrap_or((rest, ""));
        let note = |this: &mut Self, shown: &str, note: String, cx: &mut Context<Self>| {
            this.marra.update(cx, |m, cx| {
                m.main.chat.push(Entry::You { text: shown.to_string(), at: crate::marra::now() });
                m.main.chat.push(Entry::Note { text: note, at: crate::marra::now() });
                crate::marra::save_chat(&crate::marra::dir().join("chat.jsonl"), &m.main.chat);
                cx.notify();
            });
        };
        let prompt = |this: &mut Self, shown: &str, sent: String, cx: &mut Context<Self>| {
            this.marra.update(cx, |m, cx| {
                m.main.send(shown, &sent);
                cx.notify();
            });
        };
        match name {
            "waiting" => {
                let needs = self.needs(cx);
                let body = if needs.is_empty() { "Nothing needs you.".to_string() } else { needs.iter().map(|n| format!("- **{}**: {} ({})", n.subject, n.task, waiting(n.since))).collect::<Vec<_>>().join("\n") };
                note(self, text, body, cx);
            }
            "review" => {
                let work = marra_model::work(cx);
                let body = if work.reviews.is_empty() { "No review requests.".to_string() } else { work.reviews.iter().map(|p| format!("- [{}#{}]({}) {}{}", p.short_repo(), p.number, p.url, p.title, p.author.as_ref().map(|a| format!(", by {a}")).unwrap_or_default())).collect::<Vec<_>>().join("\n") };
                note(self, text, body, cx);
            }
            "open" => {
                let words = arg.to_lowercase();
                let found = marra_model::sessions(cx).into_iter().find(|s| !words.is_empty() && (s.title.to_lowercase().contains(&words) || s.subject.as_ref().is_some_and(|x| x.to_lowercase().contains(&words))));
                let body = match found {
                    Some(s) => {
                        let key = s.key.clone();
                        let marra = self.marra.clone();
                        cx.defer(move |cx| {
                            marra.update(cx, |m, cx| {
                                m.open_session(&key, cx);
                            });
                        });
                        format!("Opened {}.", s.title)
                    }
                    None => format!("No session matches \"{arg}\"."),
                };
                note(self, text, body, cx);
            }
            "later" => {
                let top = self.needs(cx).into_iter().next();
                let body = match top {
                    Some(n) => {
                        self.remind(n.key.clone(), Some(30), cx);
                        format!("{}: back in 30 minutes.", n.subject)
                    }
                    None => "Nothing to park.".into(),
                };
                note(self, text, body, cx);
            }
            "compact" => self.marra.update(cx, |m, cx| {
                if let Err(e) = m.main.engine.send("/compact") {
                    m.main.event(e);
                } else {
                    m.main.event("Compacting. Notes and threads are kept; a summary replaces older turns.");
                }
                cx.notify();
            }),
            "new" => self.marra.update(cx, |m, cx| {
                m.new_conversation();
                cx.notify();
            }),
            "model" => {
                let model = match arg {
                    "" | "default" => None,
                    other => Some(other.to_string()),
                };
                let body = format!("Marra now uses {}.", model.clone().unwrap_or_else(|| "Claude's default model".into()));
                self.marra.update(cx, |m, _| m.set_model(model));
                note(self, text, body, cx);
            }
            "notes" => edit_notes(cx),
            "save" => {
                let name: String = arg.trim_start_matches('/').chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').collect::<String>().to_lowercase();
                let last = self.marra.read(cx).main.chat.iter().rev().find_map(|e| match e {
                    Entry::You { text, .. } if !text.starts_with('/') => Some(text.clone()),
                    _ => None,
                });
                let body = match (name.is_empty(), last) {
                    (true, _) => "Name it: /save standup-notes".to_string(),
                    (_, None) => "There's no message of yours to save yet.".to_string(),
                    (false, Some(last)) => {
                        let folder = crate::marra::dir().join("commands");
                        let _ = std::fs::create_dir_all(&folder);
                        match std::fs::write(folder.join(format!("{name}.md")), format!("{last}\n")) {
                            Ok(()) => {
                                self.saved_commands = crate::marra_mcp::saved_commands();
                                format!("Saved as /{name}: your last message. It's in {}; edit it there.", folder.join(format!("{name}.md")).display())
                            }
                            Err(e) => format!("Couldn't save it: {e}"),
                        }
                    }
                };
                note(self, text, body, cx);
            }
            "help" => note(self, text, COMMANDS.iter().map(|(c, d)| format!("- `{c}`: {d}")).collect::<Vec<_>>().join("\n") + "\n\nAsk anything else in plain words: Marra reads Gannin's sessions and your work.", cx),
            "catch-up" => {
                let marra = self.marra.read(cx);
                let unread: Vec<String> = marra.threads().into_iter().filter(|t| marra.is_unread(t) && t.kind != ThreadKind::Main).map(|t| format!("- {} ({}): {}", t.title, t.id, t.last)).collect();
                let sent = if unread.is_empty() { "Catch me up: is anything waiting on me? Check with your tools.".to_string() } else { format!("Catch me up on these unread threads, most urgent first, one line each, reading the sessions with read_session where it helps:\n{}", unread.join("\n")) };
                prompt(self, text, sent, cx);
            }
            "standup" => prompt(self, text, "Write my standup: yesterday, today and blockers, a few bullets each, from my sessions (list_sessions, read_session) and my PRs and issues (workload). Only what you can see; say if something's missing.".into(), cx),
            "ask" | "investigate" if !arg.is_empty() => {
                let kind = if name == "ask" { "question" } else { "investigation" };
                prompt(self, text, format!("Start a {kind} errand for this with start_errand, choosing the harness and skills from list_skills (say which you chose): {arg}"), cx);
            }
            other => match self.saved_commands.iter().find(|c| c.name == other).cloned() {
                // A saved prompt goes to Marra, with anything typed after it.
                Some(saved) => prompt(self, text, if arg.is_empty() { saved.body } else { format!("{}\n\n{arg}", saved.body) }, cx),
                None => return false,
            },
        }
        let _ = window;
        true
    }

    /// The / or @ word being typed at the end, if any.
    fn typing_token(&self, cx: &App) -> Option<String> {
        let text = self.composer.read(cx).text(cx);
        if text.ends_with(char::is_whitespace) {
            return None;
        }
        let token = text.rsplit(char::is_whitespace).next()?.to_string();
        let first_word = !text.trim_start().contains(char::is_whitespace);
        ((token.starts_with('/') && first_word) || token.starts_with('@')).then_some(token).filter(|t| self.suggest_closed.as_ref() != Some(t))
    }

    /// What to offer for a / or @ word: (what goes in, what it is, the id it stands for).
    fn suggestions(&self, token: &str, cx: &App) -> Vec<(String, String, Option<String>)> {
        let needle = token[1..].to_lowercase();
        let options: Vec<(String, String, Option<String>)> = if token.starts_with('/') {
            if self.open.as_ref().is_some_and(|o| o != "main") {
                return Vec::new();
            }
            let mut list: Vec<(String, String, Option<String>)> = COMMANDS.iter().map(|(c, d)| (c.to_string(), d.to_string(), None)).collect();
            list.extend(self.saved_commands.iter().filter(|c| !COMMANDS.iter().any(|(n, _)| n[1..] == c.name)).map(|c| (format!("/{}", c.name), format!("{}{}", c.about, c.harness.as_ref().map(|h| format!(" · {h}")).unwrap_or_else(|| " · yours".into())), None)));
            list
        } else {
            let mut found: Vec<(String, String, Option<String>)> = marra_model::sessions(cx)
                .into_iter()
                .map(|s| {
                    let short = s.subject.clone().unwrap_or_else(|| s.title.split_whitespace().take(3).collect::<Vec<_>>().join("-"));
                    (format!("@{}", short.replace(' ', "-")), format!("{} · {} session", s.title, s.kind), Some(format!("session {} (\"{}\")", s.key, s.title)))
                })
                .collect();
            let work = marra_model::work(cx);
            found.extend(work.reviews.iter().chain(&work.mine).map(|p| (format!("@{}#{}", p.short_repo(), p.number), format!("{} · pull request", p.title), Some(format!("{}#{} ({})", p.repo, p.number, p.url)))));
            found.extend(self.marra.read(cx).errands.iter().map(|e| (format!("@{}", e.saved.title.split_whitespace().take(2).collect::<Vec<_>>().join("-")), format!("{} · errand", e.saved.title), Some(format!("errand {}", e.saved.id)))));
            found.extend(self.skills.iter().map(|s| (format!("@{s}"), "skill".to_string(), Some(format!("the {s} skill")))));
            found
        };
        options.into_iter().filter(|(insert, label, _)| insert.to_lowercase().contains(&needle) || label.to_lowercase().contains(&needle)).take(6).collect()
    }

    fn accept(&mut self, insert: String, id: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.composer.read(cx).text(cx);
        let token_len = text.rsplit(char::is_whitespace).next().map_or(0, str::len);
        let replaced = format!("{}{} ", &text[..text.len() - token_len], insert);
        self.composer.update(cx, |editor, cx| {
            editor.set_text(replaced, window, cx);
            editor.move_to_end(&editor::actions::MoveToEnd, window, cx);
        });
        if let Some(id) = id {
            self.mentions.push((insert, id));
        }
        self.suggest = 0;
        cx.notify();
    }
}

/// Opens Marra's notes in the default text editor, made if missing.
fn edit_notes(cx: &mut App) {
    let path = crate::marra::dir().join("marra-notes.md");
    if !path.exists() {
        let _ = std::fs::create_dir_all(crate::marra::dir());
        let _ = std::fs::write(&path, "# Notes for Marra\n\nPreferences and standing instructions, loaded into each new conversation.\n");
    }
    let _ = cx;
    let _ = std::process::Command::new("/usr/bin/open").arg("-t").arg(&path).spawn();
}

// MARK: Opening

/// ⌘J: brings Marra forward, in its window or docked in the front Gannin
/// window, with the input focused.
pub fn toggle(cx: &mut App) {
    let marra = Marra::get(cx);
    if marra.read(cx).saved.docked {
        let target = cx.active_window().and_then(|w| w.downcast::<Workspace>()).or_else(|| cx.windows().into_iter().find_map(|w| w.downcast::<Workspace>()));
        if let Some(window) = target {
            let _ = window.update(cx, |workspace, window, cx| {
                match workspace.marra_dock.clone() {
                    Some(view) if view.read(cx).composer.focus_handle(cx).is_focused(window) => workspace.marra_dock = None,
                    Some(view) => view.update(cx, |v, cx| v.focus_input(window, cx)),
                    None => workspace.marra_dock = Some(cx.new(|cx| MarraView::new(true, window, cx))),
                }
                cx.notify();
            });
        }
        return;
    }
    let existing = marra.read(cx).floating;
    if let Some(handle) = existing {
        let shown = handle
            .update(cx, |root, window, cx| {
                window.activate_window();
                if let Ok(view) = root.downcast::<MarraView>() {
                    view.update(cx, |v, cx| v.focus_input(window, cx));
                }
            })
            .is_ok();
        if shown {
            return;
        }
    }
    open_floating(cx);
}

/// A notification clicked: Gannin comes forward with Marra showing (never
/// toggled away), open on the notification's thread when it has one.
pub fn show_thread(thread: Option<String>, cx: &mut App) {
    cx.activate(true);
    let marra = Marra::get(cx);
    let open = move |view: &mut MarraView, window: &mut Window, cx: &mut Context<MarraView>| {
        if let Some(thread) = thread.clone() {
            view.open_thread(thread, cx);
        }
        view.focus_input(window, cx);
    };
    if marra.read(cx).saved.docked {
        let target = cx.active_window().and_then(|w| w.downcast::<Workspace>()).or_else(|| cx.windows().into_iter().find_map(|w| w.downcast::<Workspace>()));
        if let Some(window) = target {
            let _ = window.update(cx, |workspace, window, cx| {
                window.activate_window();
                let view = workspace.marra_dock.get_or_insert_with(|| cx.new(|cx| MarraView::new(true, window, cx))).clone();
                view.update(cx, |v, cx| open(v, window, cx));
                cx.notify();
            });
        }
        return;
    }
    if marra.read(cx).floating.is_none_or(|h| h.update(cx, |_, _, _| ()).is_err()) {
        open_floating(cx);
    }
    if let Some(handle) = marra.read(cx).floating {
        let _ = handle.update(cx, |root, window, cx| {
            window.activate_window();
            if let Ok(view) = root.downcast::<MarraView>() {
                view.update(cx, |v, cx| open(v, window, cx));
            }
        });
    }
}

/// Closes Marra's own window and opens it again, as Keep on Top changes.
fn reopen_floating(cx: &mut App) {
    let marra = Marra::get(cx);
    if let Some(handle) = marra.read(cx).floating {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
    marra.update(cx, |m, _| m.floating = None);
    open_floating(cx);
}

fn open_floating(cx: &mut App) {
    let on_top = !Marra::get(cx).read(cx).saved.not_on_top;
    let options = gpui::WindowOptions {
        // Wide enough for the thread list beside a thread.
        window_bounds: Some(gpui::WindowBounds::Windowed(gpui::Bounds::centered(None, gpui::size(px(980.), px(780.)), cx))),
        window_min_size: Some(gpui::size(px(760.), px(520.))),
        titlebar: Some(gpui::TitlebarOptions { title: Some("Marra".into()), appears_transparent: true, traffic_light_position: Some(gpui::point(px(14.), px(13.))) }),
        app_id: Some(crate::shell::APP_ID.into()),
        // Kept above other apps unless Keep on Top is off.
        kind: if on_top { gpui::WindowKind::Floating } else { gpui::WindowKind::Normal },
        ..Default::default()
    };
    if let Ok(handle) = cx.open_window(options, |window, cx| cx.new(|cx| MarraView::new(false, window, cx))) {
        let any: gpui::AnyWindowHandle = handle.into();
        Marra::get(cx).update(cx, |m, _| m.floating = Some(any));
        let _ = handle.update(cx, |_, window, _| window.activate_window());
    }
}

/// Docks Marra into the front Gannin window, or floats it again.
fn set_docked(docked: bool, cx: &mut App) {
    let marra = Marra::get(cx);
    marra.update(cx, |m, _| {
        m.saved.docked = docked;
        m.saved.save();
    });
    if docked {
        if let Some(handle) = marra.read(cx).floating {
            let _ = handle.update(cx, |_, window, _| window.remove_window());
        }
        marra.update(cx, |m, _| m.floating = None);
        toggle(cx);
    } else {
        for handle in cx.windows() {
            if let Some(w) = handle.downcast::<Workspace>() {
                let _ = w.update(cx, |workspace, _, cx| {
                    workspace.marra_dock = None;
                    cx.notify();
                });
            }
        }
        open_floating(cx);
    }
}

/// GPUI's floating window is a panel, which macOS hides while another app
/// is active, and which stays on one Space. Marra should follow you: shown
/// over other apps, on every Space.
fn keep_up(window: &Window) {
    #[cfg(target_os = "macos")]
    {
        use objc2::msg_send;
        use objc2::runtime::{AnyObject, Bool};
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        let Ok(handle) = HasWindowHandle::window_handle(window) else { return };
        if let RawWindowHandle::AppKit(appkit) = handle.as_raw() {
            let view = appkit.ns_view.as_ptr() as *mut AnyObject;
            unsafe {
                let ns_window: *mut AnyObject = msg_send![view, window];
                if !ns_window.is_null() {
                    let _: () = msg_send![ns_window, setHidesOnDeactivate: Bool::NO];
                    // NSWindowCollectionBehaviorCanJoinAllSpaces | FullScreenAuxiliary.
                    let _: () = msg_send![ns_window, setCollectionBehavior: (1usize << 0) | (1usize << 8)];
                }
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = window;
}

// MARK: Drawing

fn button(id: impl Into<SharedString>, label: impl Into<SharedString>, primary: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id.into())
        .px_2()
        .py_0p5()
        .rounded_md()
        .text_xs()
        .cursor_pointer()
        .border_1()
        .when(primary, |d| d.bg(theme.selected).border_color(theme.selected).text_color(theme.on_selected))
        .when(!primary, |d| d.border_color(theme.border).text_color(theme.fg).hover(|s| s.bg(theme.row_selected)))
        .child(label.into())
}

/// A square icon button with its words as a tooltip, for the session card
/// and the thread's bar, where labels took the room.
fn icon_button(id: impl Into<SharedString>, icon: &'static str, tip: impl Into<String>, primary: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
    let tip = tip.into();
    div()
        .id(id.into())
        .flex()
        .items_center()
        .justify_center()
        .size(px(26.))
        .rounded_md()
        .cursor_pointer()
        .border_1()
        .when(primary, |d| d.bg(theme.selected).border_color(theme.selected))
        .when(!primary, |d| d.border_color(theme.border).hover(|s| s.bg(theme.row_selected)))
        .child(gpui::svg().path(icon).size(px(14.)).text_color(if primary { theme.on_selected } else { theme.fg }))
        .tooltip(move |_, cx| cx.new(|_| crate::issues::Tooltip(tip.clone())).into())
}

/// A line led by an icon in place of a heading.
fn icon_line(icon: &'static str, theme: &Theme) -> gpui::Div {
    div().flex().flex_row().items_start().gap_2().child(div().flex_none().pt(px(3.)).child(gpui::svg().path(icon).size(px(12.)).text_color(theme.secondary)))
}

fn section(label: impl Into<SharedString>, theme: &Theme) -> gpui::Div {
    div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(label.into())
}

fn avatar(kind: ThreadKind, theme: &Theme) -> (&'static str, Hsla) {
    match kind {
        ThreadKind::Main => ("icons/sparkle.svg", theme.selected),
        ThreadKind::Question => ("icons/database_zap.svg", theme.slot(6)),
        ThreadKind::Investigation => ("icons/magnifying_glass.svg", theme.orange()),
        ThreadKind::Issue => ("icons/notepad.svg", theme.good()),
        ThreadKind::Todos => ("icons/list_todo.svg", theme.selected),
        ThreadKind::Build => ("icons/tool_hammer.svg", theme.good()),
        ThreadKind::Review => ("icons/pull_request.svg", theme.slot(4)),
    }
}

/// The kind's colour only while unread; grey once read.
fn avatar_view(kind: ThreadKind, unread: bool, size: f32, icon: f32, theme: &Theme) -> gpui::Div {
    let (path, tint) = avatar(kind, theme);
    div()
        .flex_none()
        .size(px(size))
        .rounded_full()
        .bg(if unread { tint } else { theme.border })
        .flex()
        .items_center()
        .justify_center()
        .child(gpui::svg().path(path).size(px(icon)).text_color(if unread { gpui::white() } else { theme.secondary }))
}

/// An open ring turning: working, without arrows.
fn spinner(id: impl Into<gpui::ElementId>, size: f32, theme: &Theme) -> impl IntoElement {
    use gpui::{Animation, AnimationExt, Transformation};
    gpui::svg()
        .path("icons/load_circle.svg")
        .size(px(size))
        .flex_none()
        .text_color(theme.blue())
        .with_animation(id, Animation::new(Duration::from_millis(900)).repeat(), |svg, delta| svg.with_transformation(Transformation::rotate(gpui::percentage(delta))))
}

/// Waiting gets harder to ignore as it ages, without ever turning red.
fn age_color(since: chrono::DateTime<chrono::Local>, theme: &Theme) -> Hsla {
    match (chrono::Local::now() - since).num_minutes() {
        m if m >= 30 => theme.orange(),
        m if m >= 10 => theme.fg,
        _ => theme.secondary,
    }
}

/// A worker's text while it streams: the reply contract's json isn't shown.
fn without_contract(text: &str) -> &str {
    text.find("```json").map_or(text, |i| &text[..i]).trim_end()
}

impl MarraView {
    fn title_bar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let marra = self.marra.read(cx);
        let focus = marra.saved.focus;
        let unread = marra.threads().iter().filter(|t| marra.is_unread(t)).count();
        div()
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .pl(px(if self.docked { 12. } else { 86. }))
            .pr_3()
            .h(px(40.))
            .border_b_1()
            // Focus turns the bar purple; the moon switches it.
            .map(|d| if focus { d.bg(theme.slot(6).opacity(0.45)).border_color(theme.slot(6)) } else { d.bg(theme.sidebar).border_color(theme.border) })
            .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child("Marra"))
            .child(div().flex_1())
            .child(
                div()
                    .id("focus-toggle")
                    .px_1()
                    .rounded_md()
                    .cursor_pointer()
                    .text_sm()
                    .text_color(if focus { gpui::white() } else { theme.secondary })
                    .hover(|s| s.bg(theme.row_selected))
                    .child("☾")
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.marra.update(cx, |m, cx| m.set_focus(!focus, cx)))),
            )
            .child(
                div()
                    .id("unread-toggle")
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1()
                    .px_1p5()
                    .py_0p5()
                    .rounded_md()
                    .cursor_pointer()
                    .when(self.unread_only, |d| d.bg(theme.selected))
                    .when(!self.unread_only, |d| d.hover(|s| s.bg(theme.row_selected)))
                    .child(gpui::svg().path("icons/filter.svg").size(px(14.)).text_color(if self.unread_only { theme.on_selected } else { theme.secondary }))
                    .child(div().text_xs().text_color(if self.unread_only { theme.on_selected } else { theme.secondary }).child(format!("{unread}")))
                    .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.unread_only = !this.unread_only;
                        cx.notify();
                    })),
            )
            .child(
                div()
                    .id("scope")
                    .px_2()
                    .py_0p5()
                    .rounded_md()
                    .bg(theme.tile)
                    .text_xs()
                    .text_color(theme.fg)
                    .cursor_pointer()
                    .child(format!("{} ▾", self.scope.clone().unwrap_or_else(|| "All".into())))
                    .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        if this.just_closed() {
                            return;
                        }
                        this.scope_menu = !this.scope_menu;
                        this.more_menu = false;
                        cx.notify();
                    })),
            )
            .child(
                div()
                    .id("more")
                    .px_1()
                    .rounded_md()
                    .text_sm()
                    .text_color(theme.secondary)
                    .cursor_pointer()
                    .hover(|s| s.bg(theme.row_selected))
                    .child("⋯")
                    .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        if this.just_closed() {
                            return;
                        }
                        this.more_menu = !this.more_menu;
                        this.scope_menu = false;
                        if this.more_menu {
                            this.phone = (crate::marra_api::address(), crate::marra_api::devices().len());
                        }
                        cx.notify();
                    })),
            )
            .when(self.docked, |d| {
                d.child(
                    div()
                        .id("hide-dock")
                        .px_1()
                        .rounded_md()
                        .cursor_pointer()
                        .hover(|s| s.bg(theme.row_selected))
                        .child(gpui::svg().path("icons/close.svg").size(px(12.)).text_color(theme.secondary))
                        .on_click(cx.listener(|_, _: &ClickEvent, window, cx| {
                            // The window's own Workspace drops its panel.
                            if let Some(handle) = window.window_handle().downcast::<Workspace>() {
                                cx.defer(move |cx| {
                                    let _ = handle.update(cx, |w, _, cx| {
                                        w.marra_dock = None;
                                        cx.notify();
                                    });
                                });
                            }
                        })),
                )
            })
    }

    fn menu_shell(&self, theme: &Theme, width: f32, cx: &mut Context<Self>) -> gpui::Div {
        div()
            .absolute()
            .top(px(38.))
            .right(px(10.))
            .w(px(width))
            .p_1()
            .bg(theme.popover)
            .border_1()
            .border_color(theme.border)
            .rounded_md()
            .shadow_lg()
            .occlude()
            .on_mouse_down_out(cx.listener(|this, _: &gpui::MouseDownEvent, _, cx| {
                this.close_menus();
                cx.notify();
            }))
    }

    fn menu_row(id: impl Into<SharedString>, label: impl Into<SharedString>, on: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(id.into())
            .flex()
            .flex_row()
            .px_2()
            .py_1()
            .rounded_md()
            .text_sm()
            .text_color(theme.fg)
            .cursor_pointer()
            .when(on, |d| d.bg(theme.row_selected))
            .hover(|s| s.bg(theme.row_selected))
            .child(label.into())
    }

    fn menus(&self, theme: &Theme, cx: &mut Context<Self>) -> Option<AnyElement> {
        if self.scope_menu {
            let mut scopes: Vec<Option<String>> = vec![None];
            scopes.extend(self.orgs(cx).into_iter().map(Some));
            let rows: Vec<AnyElement> = scopes
                .into_iter()
                .enumerate()
                .map(|(i, scope)| {
                    let count = self.marra.read(cx).needs(scope.as_deref()).len();
                    let on = scope == self.scope;
                    Self::menu_row(format!("scope-{i}"), scope.clone().unwrap_or_else(|| "All".into()), on, theme)
                        .child(div().flex_1())
                        .child(div().text_xs().text_color(theme.secondary).child(format!("{count} need you")))
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.scope = scope.clone();
                            this.scope_menu = false;
                            this.selected = 0;
                            cx.notify();
                        }))
                        .into_any_element()
                })
                .collect();
            return Some(self.menu_shell(theme, 240., cx).children(rows).into_any_element());
        }
        if !self.more_menu {
            return None;
        }
        let marra = self.marra.read(cx);
        let model = marra.saved.model.clone();
        let focus = marra.saved.focus;
        let context = marra.main.context;
        let busy = marra.main.busy();
        let mut rows: Vec<AnyElement> = Vec::new();
        let entries: Vec<(&str, String)> = vec![
            ("compact", "Compact now".into()),
            ("new", "New conversation".into()),
            ("stop", if busy { "Stop Marra".into() } else { String::new() }),
            ("restart", "Restart Marra".into()),
            ("notes", "Edit notes".into()),
            ("read", "Mark all read".into()),
            ("focus", if focus { "Focus off".into() } else { "Focus on".into() }),
            ("dock", if self.docked { "Float in its own window".into() } else { "Dock into Gannin".into() }),
        ];
        for (key, label) in entries.into_iter().filter(|(_, l)| !l.is_empty()) {
            rows.push(
                Self::menu_row(format!("more-{key}"), label, false, theme)
                    .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                        this.more_menu = false;
                        match key {
                            "compact" => {
                                this.command("/compact", window, cx);
                                this.open_thread("main".into(), cx);
                            }
                            "new" => {
                                this.command("/new", window, cx);
                                this.open_thread("main".into(), cx);
                            }
                            "stop" => this.marra.update(cx, |m, _| m.main.engine.interrupt()),
                            "restart" => this.marra.update(cx, |m, cx| {
                                m.main.restart();
                                cx.notify();
                            }),
                            "notes" => edit_notes(cx),
                            "read" => this.marra.update(cx, |m, cx| {
                                for t in m.threads() {
                                    m.saved.read.insert(t.id, chrono::Local::now().to_rfc3339());
                                }
                                m.saved.save();
                                cx.notify();
                            }),
                            "focus" => this.marra.update(cx, |m, cx| m.set_focus(!focus, cx)),
                            _ => {
                                // At the app level, once no window is lent out.
                                let docked = this.docked;
                                cx.defer(move |cx| set_docked(!docked, cx));
                            }
                        }
                        cx.notify();
                    }))
                    .into_any_element(),
            );
        }
        rows.push(div().mx_2().my_1().h(px(1.)).bg(theme.border).into_any_element());
        rows.push(div().px_2().pb_0p5().text_xs().text_color(theme.secondary).child("Model").into_any_element());
        for (i, (label, value)) in MODELS.iter().enumerate() {
            let value = value.map(str::to_string);
            let on = model == value || (value.is_none() && model.is_none());
            rows.push(
                Self::menu_row(format!("model-{i}"), format!("{}{label}", if on { "✓ " } else { "   " }), false, theme)
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        let value = value.clone();
                        this.marra.update(cx, |m, cx| {
                            m.set_model(value);
                            cx.notify();
                        });
                        this.more_menu = false;
                        cx.notify();
                    }))
                    .into_any_element(),
            );
        }
        if let Some(other) = model.filter(|m| !MODELS.iter().any(|(_, v)| *v == Some(m.as_str()))) {
            rows.push(div().px_2().py_1().text_sm().text_color(theme.fg).child(format!("✓ {other}")).into_any_element());
        }
        // Its own window kept above other apps, or an ordinary one.
        if !self.docked {
            let on_top = !self.marra.read(cx).saved.not_on_top;
            rows.push(div().mx_2().my_1().h(px(1.)).bg(theme.border).into_any_element());
            rows.push(
                Self::menu_row("keep-on-top", format!("{}Keep on Top", if on_top { "✓ " } else { "   " }), false, theme)
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.marra.update(cx, |m, _| {
                            m.saved.not_on_top = on_top;
                            m.saved.save();
                        });
                        this.more_menu = false;
                        // The window's kind is set as it opens: open it again.
                        cx.defer(reopen_floating);
                    }))
                    .into_any_element(),
            );
        }
        // Summaries of what a session did: off, or the model that writes them.
        let (summaries_off, summary_model) = {
            let saved = &self.marra.read(cx).saved;
            (saved.summaries_off, saved.summary_model.clone().unwrap_or_else(|| "haiku".into()))
        };
        rows.push(div().mx_2().my_1().h(px(1.)).bg(theme.border).into_any_element());
        rows.push(div().px_2().pb_0p5().text_xs().text_color(theme.secondary).child("Summaries").into_any_element());
        let choices: [(&str, Option<&str>); 4] = [("Off", None), ("Haiku", Some("haiku")), ("Sonnet", Some("sonnet")), ("Opus", Some("opus"))];
        for (i, (label, value)) in choices.into_iter().enumerate() {
            let on = match value {
                None => summaries_off,
                Some(v) => !summaries_off && summary_model == v,
            };
            rows.push(
                Self::menu_row(format!("summary-model-{i}"), format!("{}{label}", if on { "✓ " } else { "   " }), false, theme)
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.marra.update(cx, |m, cx| {
                            match value {
                                None => m.saved.summaries_off = true,
                                Some(v) => {
                                    m.saved.summaries_off = false;
                                    m.saved.summary_model = (v != "haiku").then(|| v.to_string());
                                }
                            }
                            m.saved.save();
                            cx.notify();
                        });
                        this.more_menu = false;
                        cx.notify();
                    }))
                    .into_any_element(),
            );
        }
        // Phone access: the API on the local network, with its pairing code.
        let (api_on, code, error) = {
            let m = self.marra.read(cx);
            (m.api.is_some(), m.api.as_ref().and_then(|a| a.code()), m.api_error.clone())
        };
        let devices = self.phone.1;
        rows.push(div().mx_2().my_1().h(px(1.)).bg(theme.border).into_any_element());
        rows.push(
            Self::menu_row("phone", if api_on { "✓ Phone access" } else { "   Phone access" }, false, theme)
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.marra.update(cx, |m, cx| {
                        m.set_api(!api_on);
                        cx.notify();
                    });
                    this.phone = (crate::marra_api::address(), crate::marra_api::devices().len());
                    cx.notify();
                }))
                .into_any_element(),
        );
        if let Some(error) = error {
            rows.push(div().px_2().pb_1().text_xs().text_color(theme.orange()).child(error).into_any_element());
        }
        if api_on {
            let address = self.phone.0.clone().unwrap_or_else(|| "no local network".into());
            rows.push(div().px_2().text_xs().text_color(theme.secondary).child(format!("On this network at {address}")).into_any_element());
            rows.push(
                div()
                    .px_2()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(div().text_xs().text_color(theme.secondary).child(match &code {
                        Some(code) => format!("Pairing code {code} (10 minutes, one device)"),
                        None => "No pairing code".into(),
                    }))
                    .child(div().id("new-code").text_xs().text_color(theme.selected).cursor_pointer().child("New code").on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.marra.update(cx, |m, cx| {
                            if let Some(api) = &m.api {
                                api.new_code();
                            }
                            cx.notify();
                        });
                        cx.notify();
                    })))
                    .into_any_element(),
            );
            rows.push(
                div()
                    .px_2()
                    .pb_1()
                    .flex()
                    .flex_row()
                    .gap_2()
                    .child(div().text_xs().text_color(theme.secondary).child(format!("{devices} device{} paired", if devices == 1 { "" } else { "s" })))
                    .when(devices > 0, |d| {
                        d.child(div().id("revoke").text_xs().text_color(theme.orange()).cursor_pointer().child("Revoke all").on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                            crate::marra_api::revoke_all();
                            this.phone.1 = 0;
                            cx.notify();
                        })))
                    })
                    .into_any_element(),
            );
        }
        // Claude Code compacts near its limit by itself; this says how close.
        let share = (context as f32 / 200_000.).clamp(0., 1.);
        rows.push(div().mt_1().mx_2().h(px(3.)).rounded_full().bg(theme.grid).child(div().h_full().w(px(250. * share)).rounded_full().bg(theme.blue())).into_any_element());
        rows.push(div().px_2().pt_0p5().pb_1().text_xs().text_color(theme.secondary).child(if context == 0 { "Context: not started yet".to_string() } else { format!("Context: {}k tokens", context / 1000) }).into_any_element());
        Some(self.menu_shell(theme, 270., cx).children(rows).into_any_element())
    }

    /// One thing at a time: the top item as a card, the rest behind "more".
    /// New Issue, at the top of the thread list: a button, then the harness
    /// to raise it from, then that harness's skills it inherits (those about
    /// issues and planning ticked), then Start opens its conversation.
    fn new_issue_view(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let Some(pick) = self.issue_pick.clone() else {
            return div()
                .flex_none()
                .px_3()
                .pt_2()
                .child(
                    div()
                        .id("new-issue")
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .px_2()
                        .py_1()
                        .rounded_md()
                        .cursor_pointer()
                        .text_sm()
                        .text_color(theme.selected)
                        .hover(|s| s.bg(theme.row_selected))
                        .child(gpui::svg().path("icons/square_plus.svg").size(px(14.)).text_color(theme.selected))
                        .child("New issue")
                        .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                            this.issue_pick = Some(IssuePick::default());
                            this.issue_error = None;
                            cx.notify();
                        })),
                )
                .into_any_element();
        };
        let cancel = div().id("issue-cancel").text_xs().text_color(theme.selected).cursor_pointer().child("Cancel").on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
            this.issue_pick = None;
            cx.notify();
        }));
        let mut panel = div().flex_none().flex().flex_col().gap_1().mx_3().mt_2().p_2().rounded(px(10.)).bg(theme.sidebar).border_1().border_color(theme.border);
        match &pick.harness {
            None => {
                panel = panel.child(div().flex().flex_row().items_center().child(div().flex_1().text_xs().text_color(theme.secondary).child("New issue in")).child(cancel));
                let places = crate::marra_mcp::harness_places();
                if places.is_empty() {
                    panel = panel.child(div().text_sm().text_color(theme.secondary).child("No harness yet: start a session in one first."));
                }
                for (i, place) in places.into_iter().enumerate() {
                    let shown = place_name(&place);
                    let label = place.label();
                    let mut skills: Vec<(String, String, bool)> = crate::marra_mcp::harness_skills(&place).into_iter().map(|(name, about)| {
                        let on = issue_skill(&name, &about);
                        (name, about, on)
                    }).collect();
                    // The issue skills first, ticked; the rest after.
                    skills.sort_by(|a, b| b.2.cmp(&a.2).then_with(|| a.0.cmp(&b.0)));
                    let name = shown.clone();
                    panel = panel.child(
                        div()
                            .id(SharedString::from(format!("issue-in-{i}")))
                            .px_2()
                            .py_1()
                            .rounded_md()
                            .text_sm()
                            .text_color(theme.fg)
                            .cursor_pointer()
                            .hover(|s| s.bg(theme.row_selected))
                            .child(shown)
                            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                                this.issue_pick = Some(IssuePick { harness: Some((label.clone(), name.clone())), skills: skills.clone() });
                                this.skill_filter.update(cx, |editor, cx| editor.set_text("", window, cx));
                                window.focus(&this.issue_about.focus_handle(cx), cx);
                                cx.notify();
                            })),
                    );
                }
            }
            Some((_, shown)) => {
                panel = panel.child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(div().id("issue-back").text_xs().text_color(theme.selected).cursor_pointer().child("‹").on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                            if let Some(pick) = this.issue_pick.as_mut() {
                                pick.harness = None;
                                pick.skills.clear();
                            }
                            cx.notify();
                        })))
                        .child(div().flex_1().min_w_0().truncate().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child(format!("New issue in {shown}")))
                        .child(cancel),
                );
                // What it's about: the worker's first message, so it starts
                // from there. Return starts it; Shift-Return is a new line.
                panel = panel.child(
                    div()
                        .px_2()
                        .py_1p5()
                        .rounded_md()
                        .border_1()
                        .border_color(theme.border)
                        .bg(theme.bg)
                        .text_sm()
                        .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                            let m = &event.keystroke.modifiers;
                            if event.keystroke.key == "enter" && !m.shift && !m.alt && !m.control {
                                cx.stop_propagation();
                                this.start_issue(window, cx);
                            }
                        }))
                        .child(self.issue_about.clone()),
                );
                panel = panel.child(div().text_xs().text_color(theme.secondary).child(if pick.skills.is_empty() { "No skills in this harness: its CLAUDE.md and templates still apply." } else { "Skills it inherits" }));
                let filter = self.skill_filter.read(cx).text(cx).trim().to_lowercase();
                if !pick.skills.is_empty() {
                    panel = panel.child(div().px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).text_xs().child(self.skill_filter.clone()));
                }
                let mut list = div().id("issue-skills").max_h(px(240.)).overflow_y_scroll().flex().flex_col();
                let mut shown_any = false;
                for (i, (name, about, on)) in pick.skills.iter().cloned().enumerate() {
                    if !filter.is_empty() && !name.to_lowercase().contains(&filter) && !about.to_lowercase().contains(&filter) {
                        continue;
                    }
                    shown_any = true;
                    let tip = if about.is_empty() { name.clone() } else { format!("{name}: {about}") };
                    list = list.child(
                        div()
                            .id(SharedString::from(format!("issue-skill-{i}")))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .px_1()
                            .py_0p5()
                            .rounded_md()
                            .cursor_pointer()
                            .hover(|s| s.bg(theme.row_selected))
                            .tooltip(move |_, cx| cx.new(|_| crate::issues::Tooltip(tip.clone())).into())
                            .child(
                                div()
                                    .flex_none()
                                    .size(px(13.))
                                    .rounded(px(3.))
                                    .border_1()
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .map(|d| if on { d.bg(theme.selected).border_color(theme.selected).text_color(theme.on_selected).text_xs().child("✓") } else { d.border_color(theme.secondary) }),
                            )
                            // One line: the name, then as much of what it's for as fits.
                            .child(div().flex_none().max_w(px(180.)).truncate().text_xs().text_color(theme.fg).child(name))
                            .child(div().flex_1().min_w_0().truncate().text_xs().text_color(theme.tertiary).child(about))
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                if let Some(skill) = this.issue_pick.as_mut().and_then(|p| p.skills.get_mut(i)) {
                                    skill.2 = !skill.2;
                                }
                                cx.notify();
                            })),
                    );
                }
                if !shown_any && !pick.skills.is_empty() {
                    list = list.child(div().px_1().py_1().text_xs().text_color(theme.secondary).child("No skill matches."));
                }
                panel = panel.child(list);
                let ready = !self.issue_about.read(cx).text(cx).trim().is_empty();
                panel = panel.child(
                    div().flex().flex_row().items_center().gap_2().pt_1().child(
                        button("issue-start", "Start", ready, theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.start_issue(window, cx))),
                    ).when(!ready, |d| d.child(div().text_xs().text_color(theme.tertiary).child("Say what it's about first"))),
                );
            }
        }
        panel
            .when_some(self.issue_error.clone(), |d, error| d.child(div().text_xs().text_color(theme.orange()).child(format!("Couldn't start it: {error}"))))
            .into_any_element()
    }

    fn needs_view(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let needs = self.needs(cx);
        let selected = self.selected.min(needs.len().saturating_sub(1));
        let top = needs.get(selected).cloned();
        let rest: Vec<(usize, Need)> = needs.iter().cloned().enumerate().filter(|(i, _)| *i != selected).collect();
        div()
            .flex_none()
            .flex()
            .flex_col()
            .gap_2()
            .px_4()
            .pt_3()
            .pb_3()
            .border_b_1()
            .border_color(theme.border)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(section(if needs.is_empty() { "Nothing needs you".to_string() } else { format!("Needs you · {}", needs.len()) }, theme))
                    .when_some(self.lane, |d, lane| {
                        d.child(button("lane", format!("{} ✕", lane.title()), true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                            this.lane = None;
                            cx.notify();
                        })))
                    }),
            )
            .when_some(top, |d, need| {
                let key = need.key.clone();
                let open = need.open.clone();
                let offers_ci = need.pr.is_some();
                d.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .p_3()
                        .rounded_lg()
                        .bg(theme.tile)
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap_2()
                                .child(div().flex_1().min_w_0().truncate().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child(need.subject.clone()))
                                .when(need.returned, |d| d.child(div().text_xs().text_color(theme.blue()).child("back")))
                                .child(div().flex_none().text_xs().text_color(age_color(need.since, theme)).child(waiting(need.since))),
                        )
                        .child(div().text_base().text_color(theme.fg).child(need.task.clone()))
                        .when(!need.detail.is_empty(), |d| d.child(div().text_xs().text_color(theme.secondary).child(need.detail.clone())))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .flex_wrap()
                                .gap_1()
                                .pt_1()
                                .children(need.actions.iter().enumerate().filter(|(_, (_, a))| !matches!(a, Act::Url(_)) || need.open.is_none()).map(|(n, (label, act))| {
                                    let act = act.clone();
                                    button(format!("act-{n}"), label.clone(), n == 0, theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.act(act.clone(), window, cx)))
                                }))
                                .child(div().flex_1())
                                .when_some(open, |d, open| d.child(button("open-top", "Open", need.actions.is_empty() || need.actions.iter().all(|(_, a)| matches!(a, Act::Url(_))), theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.act(open.clone(), window, cx)))))
                                .child(button("later-top", "Remind me", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                    this.later_menu = !this.later_menu;
                                    cx.notify();
                                })))
                                .child({
                                    let key = key.clone();
                                    button("dismiss-top", "Dismiss", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.dismiss(key.clone(), cx)))
                                }),
                        )
                        .when(self.later_menu, |d| {
                            d.child(div().flex().flex_row().flex_wrap().items_center().gap_1().child(div().text_xs().text_color(theme.secondary).pr_1().child("Remind me in")).children(REMIND.iter().enumerate().filter(|(_, (_, m))| m.is_some() || offers_ci).map(|(n, (label, minutes))| {
                                let key = key.clone();
                                let minutes = *minutes;
                                button(format!("when-{n}"), *label, false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.remind(key.clone(), minutes, cx)))
                            })))
                        }),
                )
            })
            .when(!rest.is_empty(), |d| {
                d.child(
                    div()
                        .id("more-needs")
                        .text_xs()
                        .text_color(theme.secondary)
                        .cursor_pointer()
                        .hover(|s| s.text_color(theme.fg))
                        .child(if self.more_open { "Hide the rest".to_string() } else { format!("{} more", rest.len()) })
                        .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                            this.more_open = !this.more_open;
                            cx.notify();
                        })),
                )
                .when(self.more_open, |d| {
                    d.child(div().id("rest").max_h(px(180.)).overflow_y_scroll().flex().flex_col().children(rest.into_iter().map(|(row, n)| {
                        div()
                            .id(SharedString::from(format!("need-{row}")))
                            .flex()
                            .flex_row()
                            .gap_2()
                            .py_0p5()
                            .cursor_pointer()
                            .hover(|s| s.bg(theme.row_selected))
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.selected = row;
                                this.later_menu = false;
                                cx.notify();
                            }))
                            .child(div().flex_none().max_w(px(140.)).truncate().text_sm().text_color(theme.fg).child(n.subject.clone()))
                            .child(div().flex_1().min_w_0().truncate().text_sm().text_color(theme.secondary).child(n.task.clone()))
                            .child(div().flex_none().text_xs().text_color(age_color(n.since, theme)).child(waiting(n.since)))
                    })))
                })
            })
    }

    /// The list as iOS Messages draws it: pinned first above one rule.
    fn threads_view(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let listed = self.listed(cx);
        let pinned = self.marra.read(cx).saved.pinned.clone();
        let (pins, rest): (Vec<Thread>, Vec<Thread>) = listed.into_iter().partition(|t| pinned.contains(&t.id));
        let rest_count = rest.len();
        let pin_count = pins.len();
        let rows_pins: Vec<AnyElement> = pins.into_iter().map(|t| self.row(t, theme, cx).into_any_element()).collect();
        let rows_rest: Vec<AnyElement> = rest.into_iter().map(|t| self.row(t, theme, cx).into_any_element()).collect();
        div()
            .id("threads")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .py_2()
            .children(rows_pins)
            .when(pin_count > 0 && rest_count > 0, |d| d.child(div().flex_none().w_full().px_4().my_2().child(div().w_full().h(px(1.)).bg(theme.secondary.opacity(0.4)))))
            .children(rows_rest)
    }

    fn row(&self, thread: Thread, theme: &Theme, cx: &mut Context<Self>) -> gpui::Stateful<gpui::Div> {
        let marra = self.marra.read(cx);
        let unread = marra.is_unread(&thread);
        let muted = marra.saved.muted.contains(&thread.id);
        let id = thread.id.clone();
        let menu_id = thread.id.clone();
        div()
            .id(SharedString::from(format!("thread-{}", thread.id)))
            .flex()
            .flex_row()
            .items_center()
            .pl_1()
            .cursor_pointer()
            .when(self.row_menu.as_ref().is_some_and(|(m, _)| *m == thread.id), |d| d.bg(theme.tile))
            .when(self.split() && self.open.as_deref() == Some(thread.id.as_str()), |d| d.bg(theme.selected.opacity(0.18)))
            .hover(|s| s.bg(theme.tile))
            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.open_thread(id.clone(), cx)))
            .on_mouse_down(
                gpui::MouseButton::Right,
                cx.listener(move |this, event: &gpui::MouseDownEvent, _, cx| {
                    cx.stop_propagation();
                    this.row_menu = Some((menu_id.clone(), event.position));
                    cx.notify();
                }),
            )
            .child(div().w(px(16.)).flex().justify_center().child(div().size(px(9.)).rounded_full().when(unread, |d| d.bg(theme.selected))))
            .child(avatar_view(thread.kind, unread, 34., 19., theme))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .ml_3()
                    .pr_3()
                    .py_2()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .child(div().flex_1().min_w_0().truncate().text_sm().font_weight(if unread { FontWeight::BOLD } else { FontWeight::MEDIUM }).text_color(theme.fg).child(thread.title.clone()))
                            .when(muted, |d| d.child(gpui::svg().path("icons/bell_off.svg").size(px(14.)).flex_none().text_color(theme.tertiary)))
                            .map(|d| {
                                if thread.working {
                                    d.child(spinner(SharedString::from(format!("row-spin-{}", thread.id)), 14., theme))
                                } else {
                                    d.child(div().flex_none().text_xs().text_color(theme.secondary).child(thread.activity.map(ago).unwrap_or_default()))
                                }
                            })
                            .when(!self.split(), |d| d.child(div().text_sm().text_color(theme.tertiary).child("›"))),
                    )
                    .child(div().truncate().text_xs().text_color(if muted { theme.tertiary } else { theme.secondary }).child(if thread.last.is_empty() { " ".to_string() } else { thread.last.clone() })),
            )
    }

    fn row_menu_view(&self, theme: &Theme, cx: &mut Context<Self>) -> Option<AnyElement> {
        let (id, at) = self.row_menu.clone()?;
        let marra = self.marra.read(cx);
        let thread = marra.threads().into_iter().find(|t| t.id == id)?;
        let unread = marra.is_unread(&thread);
        let pinned = marra.saved.pinned.contains(&id);
        let muted = marra.saved.muted.contains(&id);
        let errand = id.strip_prefix("e:").map(str::to_string);
        let mut entries: Vec<(&str, usize)> = vec![(if pinned { "Unpin" } else { "Pin" }, 0), (if muted { "Unmute" } else { "Mute" }, 1), (if unread { "Mark as Read" } else { "Mark as Unread" }, 2)];
        if errand.is_some() {
            entries.push(("Delete", 3));
        }
        Some(
            div()
                .absolute()
                .left(at.x)
                .top(at.y)
                .w(px(170.))
                .p_1()
                .bg(theme.popover)
                .border_1()
                .border_color(theme.border)
                .rounded_md()
                .shadow_lg()
                .occlude()
                .on_mouse_down_out(cx.listener(|this, _: &gpui::MouseDownEvent, _, cx| {
                    this.close_menus();
                    cx.notify();
                }))
                .children(entries.into_iter().map(|(label, which)| {
                    let id = id.clone();
                    let errand = errand.clone();
                    div()
                        .id(SharedString::from(format!("row-menu-{which}")))
                        .px_2()
                        .py_1()
                        .rounded(px(4.))
                        .text_sm()
                        .text_color(theme.fg)
                        .cursor_pointer()
                        .hover(|s| s.bg(theme.selected).text_color(theme.on_selected))
                        .child(label)
                        .on_mouse_down(
                            gpui::MouseButton::Left,
                            cx.listener(move |this, _: &gpui::MouseDownEvent, _, cx| {
                                cx.stop_propagation();
                                let id = id.clone();
                                let errand = errand.clone();
                                this.marra.update(cx, |m, cx| {
                                    match which {
                                        0 => Marra::toggle(&mut m.saved.pinned, &id),
                                        1 => Marra::toggle(&mut m.saved.muted, &id),
                                        2 => m.mark_read(&id, !unread),
                                        _ => {
                                            if let Some(e) = errand {
                                                m.remove_errand(&e);
                                            }
                                        }
                                    }
                                    m.saved.save();
                                    cx.notify();
                                });
                                this.row_menu = None;
                                cx.notify();
                            }),
                        )
                }))
                .into_any_element(),
        )
    }

    fn thread_view(&self, id: &str, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        if id == "todos" {
            return self.todos_view(theme, cx);
        }
        let marra = self.marra.read(cx);
        let Some(thread) = marra.threads().into_iter().find(|t| t.id == id) else {
            return div().flex_1().p_4().text_color(theme.secondary).child(div().id("gone").cursor_pointer().text_color(theme.selected).child("‹ Threads").on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.back(cx)))).child("This thread has closed.").into_any_element();
        };
        let pinned = marra.saved.pinned.iter().any(|p| p == id);
        let session = id.strip_prefix("s:").map(str::to_string);
        let nav = div()
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .px_2()
            .h(px(40.))
            .border_b_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .map(|d| {
                if self.split() {
                    d.child(div().flex_none().w(px(80.)))
                } else {
                    d.child(div().id("back").flex_none().w(px(80.)).text_sm().text_color(theme.selected).cursor_pointer().child("‹ Threads").on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.back(cx))))
                }
            })
            // The avatar and title on one line, the title cut short to fit.
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_center()
                    .gap_2()
                    .child(div().flex_none().child(avatar_view(thread.kind, false, 20., 12., theme)))
                    .child(div().min_w_0().truncate().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child(thread.title.clone())),
            )
            .child(
                div()
                    .flex_none()
                    .w(px(80.))
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap_2()
                    .child({
                        let id = id.to_string();
                        div()
                            .id("pin")
                            .px_1()
                            .cursor_pointer()
                            .child(gpui::svg().path(if pinned { "icons/unpin.svg" } else { "icons/pin.svg" }).size(px(14.)).text_color(theme.selected))
                            .tooltip(move |_, cx| cx.new(|_| crate::issues::Tooltip(if pinned { "Unpin".into() } else { "Pin".into() })).into())
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            let id = id.clone();
                            this.marra.update(cx, |m, cx| {
                                Marra::toggle(&mut m.saved.pinned, &id);
                                m.saved.save();
                                cx.notify();
                            });
                        }))
                    }),
            );
        let body = match &session {
            Some(key) => self.session_body(key, theme, cx),
            None => {
                let who = if id == "main" { Who::Main } else { Who::Errand(id[2..].to_string()) };
                self.convo_body(id, &who, theme, cx)
            }
        };
        let actions = session.as_deref().and_then(|key| self.session_actions(key, theme, cx));
        div().flex_1().min_h_0().flex().flex_col().child(nav).child(body).children(actions).into_any_element()
    }

    /// The checklist: to do first, oldest first, then what's done, newest
    /// first; each with when it was added and, once done, when and how long.
    fn todos_view(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let mut open: Vec<crate::todos::Todo> = self.todos.iter().filter(|t| t.done.is_none()).cloned().collect();
        open.sort_by_key(|t| t.added);
        let mut done: Vec<crate::todos::Todo> = self.todos.iter().filter(|t| t.done.is_some()).cloned().collect();
        done.sort_by(|a, b| b.done.cmp(&a.done));
        let has_done = !done.is_empty();
        let nav = div()
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .px_3()
            .h(px(40.))
            .border_b_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .when(!self.split(), |d| d.child(div().id("back").flex_none().w(px(80.)).text_sm().text_color(theme.selected).cursor_pointer().child("‹ Threads").on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.back(cx)))))
            .child(div().flex_1().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child(format!("Todos · {} to do", open.len())))
            .when(has_done, |d| {
                d.child(div().id("clear-done").text_xs().text_color(theme.selected).cursor_pointer().child("Clear done").on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                    crate::todos::clear_done(&mut this.todos);
                    cx.notify();
                })))
            });
        let row = |todo: crate::todos::Todo, cx: &mut Context<Self>| {
            let (toggle_id, remove_id) = (todo.id.clone(), todo.id.clone());
            let is_done = todo.done.is_some();
            let times = match (todo.done, crate::todos::took(&todo)) {
                (Some(at), Some(took)) => format!("Added {} · done {} · {took}", crate::todos::when(todo.added), crate::todos::when(at)),
                _ => format!("Added {}", crate::todos::when(todo.added)),
            };
            div()
                .id(SharedString::from(format!("todo-{}", todo.id)))
                .flex()
                .flex_row()
                .items_start()
                .gap_3()
                .px_4()
                .py_2()
                .hover(|s| s.bg(theme.tile))
                .child(
                    div()
                        .id(SharedString::from(format!("todo-check-{}", todo.id)))
                        .flex_none()
                        .mt(px(2.))
                        .size(px(16.))
                        .rounded(px(4.))
                        .border_1()
                        .cursor_pointer()
                        .flex()
                        .items_center()
                        .justify_center()
                        .map(|d| if is_done { d.bg(theme.selected).border_color(theme.selected).text_color(theme.on_selected).text_xs().child("✓") } else { d.border_color(theme.secondary) })
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            crate::todos::toggle(&mut this.todos, &toggle_id);
                            cx.notify();
                        })),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .child(div().text_sm().text_color(if is_done { theme.secondary } else { theme.fg }).when(is_done, |d| d.line_through()).child(todo.text.clone()))
                        .child(div().text_xs().text_color(theme.tertiary).child(times)),
                )
                .child(
                    div()
                        .id(SharedString::from(format!("todo-remove-{}", todo.id)))
                        .flex_none()
                        .px_1()
                        .text_sm()
                        .text_color(theme.tertiary)
                        .cursor_pointer()
                        .hover(|s| s.text_color(theme.fg))
                        .child("×")
                        .tooltip(|_, cx| cx.new(|_| crate::issues::Tooltip("Remove".into())).into())
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            crate::todos::remove(&mut this.todos, &remove_id);
                            cx.notify();
                        })),
                )
                .into_any_element()
        };
        let empty = open.is_empty() && done.is_empty();
        let open_rows: Vec<AnyElement> = open.into_iter().map(|t| row(t, cx)).collect();
        let done_rows: Vec<AnyElement> = done.into_iter().map(|t| row(t, cx)).collect();
        let list = div()
            .id("todos-list")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .py_2()
            .when(empty, |d| d.child(div().px_4().py_6().text_sm().text_color(theme.secondary).text_center().child("Nothing yet. Type below and press Return to add one; /todo adds one from any thread.")))
            .children(open_rows)
            .when(!done_rows.is_empty(), |d| d.child(div().px_4().pt_3().pb_1().text_xs().text_color(theme.secondary).child("Done")))
            .children(done_rows);
        div().flex_1().min_h_0().flex().flex_col().child(nav).child(list).into_any_element()
    }

    /// A session thread's actions, in a bar kept at the bottom above the
    /// composer, so they stay put while its conversation scrolls.
    fn session_actions(&self, key: &str, theme: &Theme, cx: &mut Context<Self>) -> Option<AnyElement> {
        let s = marra_model::sessions(cx).into_iter().find(|s| s.key == key)?;
        let digest = self.digest.clone().filter(|(k, _)| k == key).map(|(_, d)| d);
        let summarising = self.summarising.as_deref() == Some(key);
        let summaries_on = !self.marra.read(cx).saved.summaries_off;
        let mut links = div().flex_none().flex().flex_row().flex_wrap().gap_1p5().px_4().py_2().border_t_1().border_color(theme.border).bg(theme.sidebar);
                        // A review's own buttons, on when they are in its panel.
                        if let Some(review) = s.page.read(cx).review() {
                            let r = review.read(cx);
                            let (can_post, can_again, checking) = (r.can_post(), r.can_again(), r.is_checking());
                            for (n, label, which, on, primary) in [
                                (0, "Post Review", marra_model::ReviewButton::Post, can_post, true),
                                (1, "Review Again", marra_model::ReviewButton::Again, can_again, false),
                                (2, if checking { "Checking" } else { "Check for Changes" }, marra_model::ReviewButton::Check, !checking, false),
                            ] {
                                let key = key.to_string();
                                let b = button(format!("left-off-review-{n}"), label, primary && on, theme);
                                links = links.child(if on {
                                    b.on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.act(Act::Review(key.clone(), which), window, cx)))
                                } else {
                                    b.opacity(0.45).cursor_default()
                                });
                            }
                        }
                        let open_key = key.to_string();
                        links = links.child(icon_button("left-off-session", "icons/arrow_up_right.svg", "Open session", true, theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.act(Act::OpenSession(open_key.clone()), window, cx))));
                        // Only where there's a conversation to read, and something in it.
                        if summaries_on && digest.as_ref().and_then(|d| d.as_ref()).is_some_and(|d| !d.is_empty()) && !summarising {
                            let summary_key = key.to_string();
                            links = links.child(icon_button("left-off-summary", "icons/sparkle.svg", "Summarise with Haiku", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.summarise_session(summary_key.clone(), cx))));
                        }
                        for (n, url) in digest.as_ref().and_then(|d| d.as_ref()).map(|d| d.prs.clone()).unwrap_or_default().into_iter().enumerate() {
                            let label = url.rsplit('/').next().map(|n| format!("Open PR #{n}")).unwrap_or_else(|| "Open PR".into());
                            links = links.child(icon_button(format!("left-off-pr-{n}"), "icons/pull_request.svg", label, false, theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.act(Act::Url(url.clone()), window, cx))));
                        }
                        if let Some(subject) = &s.subject_link {
                            let (in_app, url) = (key.to_string(), subject.url.clone());
                            // A PR has no drawer to open by itself yet: the session
                            // is where its change shows.
                            if !subject.url.contains("/pull/") {
                                links = links.child(icon_button("left-off-app", "icons/file_text_outlined.svg", "Open issue in Gannin", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.act(Act::OpenSubject(in_app.clone()), window, cx))));
                            }
                            links = links
                                .child(icon_button("left-off-github", "icons/github.svg", "Open on GitHub", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.act(Act::Url(url.clone()), window, cx))));
                        }
        Some(links.into_any_element())
    }

    /// A session's thread: where you left off, from Gannin's own state, then
    /// its conversation from the transcript.
    fn session_body(&self, key: &str, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let info = marra_model::sessions(cx).into_iter().find(|s| s.key == key);
        let need = self.marra.read(cx).needs(None).into_iter().find(|n| n.thread.as_deref() == Some(&format!("s:{key}")));
        let lines = self.tail.as_ref().filter(|(k, _)| k == key).map(|(_, l)| l.clone()).unwrap_or_default();
        // What happened since the last look, from Gannin's log; frozen when
        // the thread opened, as opening marks it read.
        let (since, read_at) = self.since.clone().filter(|(k, _, _)| k == key).map(|(_, l, at)| (l, at)).unwrap_or_default();
        let digest = self.digest.clone().filter(|(k, _)| k == key).map(|(_, d)| d);
        let summary = self.summary.clone().filter(|(k, _)| k == key).map(|(_, r)| r);
        let summarising = self.summarising.as_deref() == Some(key);
        let audit = self.audit.clone().filter(|(k, _)| k == key).map(|(_, c)| c).unwrap_or_default();
        let mut body = div().id(SharedString::from(format!("session-body-{key}"))).flex_1().min_h_0().overflow_y_scroll().track_scroll(&self.chat_scroll).flex().flex_col().gap_2().px_3().py_3();
        if let Some(s) = &info {
            let what = format!("{} ({}){}", s.subject.clone().unwrap_or_else(|| s.title.clone()), s.kind, s.server.as_ref().map(|n| format!(", on {n}")).unwrap_or_default());
            let state = format!("{} since {}", s.state.label(), s.since.format("%H:%M"));
            body = body.child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .w_full()
                    .px_3()
                    .py_2()
                    .rounded(px(12.))
                    .bg(theme.sidebar)
                    // What it is and where it's up to, a line each, no headings.
                    .child(div().text_sm().text_color(theme.fg).child(what))
                    .child(icon_line("icons/clock.svg", theme).child(div().text_xs().text_color(theme.secondary).child(state)))
                    .child(
                        icon_line("icons/history_rerun.svg", theme)
                            .id("since-line")
                            .tooltip({
                                let tip = match read_at {
                                    Some(at) => format!("Since you looked at {}", at.format("%H:%M")),
                                    None => "Since it started".to_string(),
                                };
                                move |_, cx| cx.new(|_| crate::issues::Tooltip(tip.clone())).into()
                            })
                            .child(div().flex_1().min_w_0().flex().flex_col().children(since_lines(&since, digest.as_ref(), s.state.label() == "Working", theme))),
                    )
                    .when_some(digest.as_ref().and_then(|d| d.as_ref()).and_then(|d| d.waiting.clone()), |d, waiting| {
                        d.child(icon_line("icons/warning.svg", theme).child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.orange()).child(waiting)))
                    })
                    .when(summarising, |d| d.child(div().flex().flex_row().items_center().gap_2().pt_1().text_sm().text_color(theme.secondary).child(spinner(SharedString::from(format!("summary-{key}")), 12., theme)).child("Haiku is reading it")))
                    .when_some(summary, |d, summary| {
                        d.child(match summary {
                            Ok(text) => div()
                                .mt_1()
                                .p_2()
                                .rounded(px(10.))
                                .bg(theme.tile)
                                .flex()
                                .flex_col()
                                .gap_0p5()
                                .child(icon_line("icons/sparkle.svg", theme).child(div().text_xs().text_color(theme.secondary).child("Haiku")))
                                .child(div().text_sm().text_color(theme.fg).child(markdown(&format!("summary-{key}"), &text, theme)))
                                .into_any_element(),
                            Err(error) => div().text_sm().text_color(theme.orange()).child(error).into_any_element(),
                        })
                    })
                    .when_some(need, |d, n| d.child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.orange()).child(format!("Wants from you: {}", n.task))))
            );
        }
        if !audit.is_empty() {
            body = body.child(self.audit_view(key, &audit, theme, cx));
        }
        if lines.is_empty() {
            let text = match &info {
                Some(s) if s.kind == "terminal" => "A terminal: open it to see its screen.".to_string(),
                Some(s) if digest.as_ref().is_some_and(|d| d.is_none()) => match &s.server {
                    Some(server) => format!("Its conversation is on {server}: open it to see its terminal."),
                    None => "No conversation found for it: open it to see its terminal.".to_string(),
                },
                _ => "Reading its conversation.".to_string(),
            };
            body = body.child(div().w_full().px_6().text_xs().text_color(theme.secondary).text_center().child(text));
        }
        for (n, (who, text)) in lines.iter().enumerate() {
            body = body.child(match who.as_str() {
                "tool" => div().pl_3().flex().flex_row().gap_1().items_center().child(gpui::svg().path("icons/tool_hammer.svg").size(px(11.)).text_color(theme.tertiary)).child(div().min_w_0().truncate().text_xs().text_color(theme.tertiary).child(text.clone())).into_any_element(),
                "User" => div().w_full().flex().flex_col().items_end().child(div().max_w(relative(0.85)).px_3().py_1p5().rounded(px(18.)).text_sm().bg(theme.selected).text_color(theme.on_selected).children(text.lines().map(|l| div().child(l.to_string())))).into_any_element(),
                _ => self.folded(&format!("s:{key}"), n, text, theme, cx),
            });
        }
        body.into_any_element()
    }

    /// The summary calls made for this session: when, which model, how long,
    /// what it cost, and what came back; each opens to its output and,
    /// on request, the exact prompt sent.
    fn audit_view(&self, key: &str, calls: &[crate::marra::SummaryCall], theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let mut list = div()
            .flex()
            .flex_col()
            .gap_1()
            .w_full()
            .p_3()
            .rounded(px(14.))
            .bg(theme.sidebar)
            .child(div().text_xs().text_color(theme.secondary).child(format!("Summary calls ({})", calls.len())));
        for (n, call) in calls.iter().enumerate().rev() {
            let id = (key.to_string(), n);
            let open = self.audit_open.contains(&id);
            let prompt_open = self.audit_prompts.contains(&id);
            let at = chrono::DateTime::parse_from_rfc3339(&call.at).map(|d| d.with_timezone(&chrono::Local).format("%d %b %H:%M").to_string()).unwrap_or_else(|_| call.at.clone());
            let mut facts = vec![at, call.model.clone(), format!("{:.1}s", call.ms as f64 / 1000.)];
            if let Some(cost) = call.cost_usd {
                facts.push(format!("${cost:.4}"));
            }
            match (call.input_tokens, call.output_tokens) {
                (Some(i), Some(o)) => facts.push(format!("{i} in, {o} out tokens")),
                _ => facts.push(format!("{} characters sent", call.prompt.chars().count())),
            }
            if call.error.is_some() {
                facts.push("failed".into());
            }
            let toggle = id.clone();
            list = list.child(
                div()
                    .id(SharedString::from(format!("audit-{key}-{n}")))
                    .flex()
                    .flex_row()
                    .gap_1()
                    .cursor_pointer()
                    .text_sm()
                    .text_color(if call.error.is_some() { theme.orange() } else { theme.fg })
                    .child(if open { "▾" } else { "▸" })
                    .child(facts.join(" · "))
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        if !this.audit_open.remove(&toggle) {
                            this.audit_open.insert(toggle.clone());
                        }
                        cx.notify();
                    })),
            );
            if !open {
                continue;
            }
            let shown = call.output.clone().or(call.error.clone()).unwrap_or_default();
            let prompt_toggle = id.clone();
            list = list.child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .pl_4()
                    .when_some(call.since.as_ref(), |d, since| {
                        let since = chrono::DateTime::parse_from_rfc3339(since).map(|d| d.with_timezone(&chrono::Local).format("%H:%M").to_string()).unwrap_or_else(|_| since.clone());
                        d.child(div().text_xs().text_color(theme.secondary).child(format!("Read the conversation from {since} on")))
                    })
                    .child(div().p_2().rounded(px(10.)).bg(theme.tile).text_sm().text_color(theme.fg).child(markdown(&format!("audit-out-{key}-{n}"), &shown, theme)))
                    .child(
                        div()
                            .id(SharedString::from(format!("audit-prompt-toggle-{key}-{n}")))
                            .text_xs()
                            .text_color(theme.selected)
                            .cursor_pointer()
                            .child(if prompt_open { "Hide the prompt sent" } else { "Show the prompt sent" })
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                if !this.audit_prompts.remove(&prompt_toggle) {
                                    this.audit_prompts.insert(prompt_toggle.clone());
                                }
                                cx.notify();
                            })),
                    )
                    .when(prompt_open, |d| {
                        d.child(
                            div()
                                .id(SharedString::from(format!("audit-prompt-{key}-{n}")))
                                .max_h(px(320.))
                                .overflow_y_scroll()
                                .p_2()
                                .rounded(px(10.))
                                .bg(theme.bg)
                                .border_1()
                                .border_color(theme.border)
                                .text_xs()
                                .font_family("Menlo")
                                .text_color(theme.secondary)
                                .children(call.prompt.lines().map(|l| div().child(if l.is_empty() { " ".to_string() } else { l.to_string() }))),
                        )
                    }),
            );
        }
        list.into_any_element()
    }

    /// A long reply folds with a fade and Show all.
    fn folded(&self, thread: &str, n: usize, text: &str, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        // Up to 50 lines (or as many characters) shows whole; longer folds at
        // about that height, with Show all.
        let long = text.lines().count() > 50 || text.len() > 5000;
        let open = self.long_open.contains(&(thread.to_string(), n));
        let key = (thread.to_string(), n);
        div()
            .w_full()
            .flex()
            .flex_col()
            .items_start()
            .gap_0p5()
            .child(
                div()
                    .relative()
                    .max_w(relative(0.85))
                    .px_3()
                    .py_1p5()
                    .rounded(px(18.))
                    .bg(theme.tile)
                    .text_sm()
                    .text_color(theme.fg)
                    .when(long && !open, |d| d.h(px(1000.)).overflow_hidden())
                    .child(markdown(&format!("md-{thread}-{n}"), text, theme))
                    .when(long && !open, |d| d.child(div().absolute().bottom_0().left_0().right_0().h(px(40.)).bg(gpui::linear_gradient(180., gpui::linear_color_stop(theme.tile.opacity(0.), 0.), gpui::linear_color_stop(theme.tile, 1.))))),
            )
            .when(long, |d| {
                d.child(div().id(SharedString::from(format!("fold-{thread}-{n}"))).pl_3().text_xs().text_color(theme.selected).cursor_pointer().child(if open { "Show less" } else { "Show all" }).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    if !this.long_open.remove(&key) {
                        this.long_open.insert(key.clone());
                    }
                    cx.notify();
                })))
            })
            .into_any_element()
    }

    /// Main's or an errand's conversation.
    fn convo_body(&self, thread: &str, who: &Who, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let marra = self.marra.read(cx);
        let Some(convo) = marra.convo(who) else { return div().into_any_element() };
        let errand = matches!(who, Who::Errand(_));
        let chat = convo.chat.clone();
        let streaming = convo.streaming.clone();
        let busy = convo.busy();
        let status = convo.status.clone();
        let doing = convo.doing.clone();
        let asks: HashSet<String> = convo.asks.keys().cloned().collect();
        let confirms: Vec<(u64, String, String)> = if errand { Vec::new() } else { marra.confirms.iter().map(|c| (c.id, c.title.clone(), c.text.clone())).collect() };
        let mut body = div().id(SharedString::from(format!("convo-{thread}"))).flex_1().min_h_0().overflow_y_scroll().track_scroll(&self.chat_scroll).flex().flex_col().gap_2().px_3().py_3();
        if chat.is_empty() && !busy {
            body = body.child(div().w_full().px_6().pt_6().text_sm().text_color(theme.secondary).text_center().child(if errand { "Starting." } else { "Ask Marra anything: what's waiting, what a session is doing, a data question for a harness. / shows the commands." }));
        }
        let mut last_who = "";
        for (n, entry) in chat.iter().enumerate() {
            let speaker = match entry {
                Entry::You { .. } => "you",
                Entry::Marra { .. } | Entry::Reply { .. } => "marra",
                Entry::Note { .. } => "gannin",
                _ => "",
            };
            let named = !speaker.is_empty() && speaker != "you" && speaker != last_who;
            if !speaker.is_empty() {
                last_who = speaker;
            }
            let label = match speaker {
                "marra" if errand => "Worker",
                "marra" => "Marra",
                "gannin" => "Gannin",
                _ => "",
            };
            let element: AnyElement = match entry {
                Entry::You { text, .. } => div().w_full().flex().flex_col().items_end().child(div().max_w(relative(0.85)).px_3().py_1p5().rounded(px(18.)).text_sm().bg(theme.selected).text_color(theme.on_selected).children(text.lines().map(|l| div().child(l.to_string())))).into_any_element(),
                Entry::Marra { text, .. } => self.folded(thread, n, if errand { without_contract(text) } else { text }, theme, cx),
                Entry::Note { text, .. } => self.folded(thread, n, text, theme, cx),
                Entry::Reply { point, body: detail, .. } => {
                    let key = (thread.to_string(), n);
                    let open = self.long_open.contains(&key);
                    div()
                        .w_full()
                        .flex()
                        .flex_col()
                        .gap_1p5()
                        .child(div().max_w(relative(0.85)).px_3().py_1p5().rounded(px(18.)).bg(theme.tile).text_sm().font_weight(FontWeight::MEDIUM).text_color(theme.fg).child(point.clone()))
                        .when(!detail.is_empty(), |d| {
                            d.child(
                                div()
                                    .w_full()
                                    .relative()
                                    .px_3()
                                    .py_2()
                                    .rounded(px(12.))
                                    .border_1()
                                    .border_color(theme.border)
                                    .when(!open, |d| d.h(px(150.)).overflow_hidden())
                                    .text_sm()
                                    .text_color(theme.fg)
                                    .child(markdown(&format!("reply-{thread}-{n}"), detail, theme))
                                    .when(!open, |d| d.child(div().absolute().bottom_0().left_0().right_0().h(px(40.)).bg(gpui::linear_gradient(180., gpui::linear_color_stop(theme.bg.opacity(0.), 0.), gpui::linear_color_stop(theme.bg, 1.))))),
                            )
                            .child(div().id(SharedString::from(format!("reply-toggle-{thread}-{n}"))).pl_3().text_xs().text_color(theme.selected).cursor_pointer().child(if open { "Show less" } else { "Show all" }).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                if !this.long_open.remove(&key) {
                                    this.long_open.insert(key.clone());
                                }
                                cx.notify();
                            })))
                        })
                        .into_any_element()
                }
                Entry::Tool { summary, failed, .. } => div()
                    .pl_3()
                    .flex()
                    .flex_row()
                    .gap_1()
                    .items_center()
                    .child(gpui::svg().path("icons/tool_hammer.svg").size(px(11.)).text_color(theme.tertiary))
                    .child(div().min_w_0().truncate().text_xs().text_color(if *failed { theme.orange() } else { theme.tertiary }).child(if *failed { format!("{summary} (failed)") } else { summary.clone() }))
                    .into_any_element(),
                Entry::Permission { request, summary, answer, .. } => {
                    let live = answer.is_none() && asks.contains(request);
                    if !live {
                        div().w_full().px_6().text_xs().text_color(theme.secondary).text_center().child(format!("{}: {summary}", answer.clone().unwrap_or_else(|| "Not answered".into()))).into_any_element()
                    } else {
                        let (w1, w2, w3) = (who.clone(), who.clone(), who.clone());
                        let (r1, r2, r3) = (request.clone(), request.clone(), request.clone());
                        div()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .max_w(relative(0.85))
                            .p_3()
                            .rounded(px(14.))
                            .bg(theme.tile)
                            .border_1()
                            .border_color(theme.orange())
                            .child(div().text_xs().text_color(theme.secondary).child(if errand { "The worker wants to" } else { "Marra wants to" }))
                            .child(div().text_sm().font_family("Menlo").text_color(theme.fg).child(summary.clone()))
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .gap_1()
                                    .child(button(format!("allow-{n}"), "Allow", true, theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.act(Act::Allow(w1.clone(), r1.clone(), false), window, cx))))
                                    .child(button(format!("always-{n}"), "Allow always", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.act(Act::Allow(w2.clone(), r2.clone(), true), window, cx))))
                                    .child(button(format!("deny-{n}"), "Deny", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.act(Act::Deny(w3.clone(), r3.clone()), window, cx)))),
                            )
                            .into_any_element()
                    }
                }
                Entry::Event { text, .. } => div().w_full().px_6().text_xs().text_color(theme.secondary).text_center().child(text.clone()).into_any_element(),
            };
            body = body.child(div().w_full().flex().flex_col().gap_0p5().when(named && !label.is_empty(), |d| d.child(div().pl_3().text_xs().text_color(theme.secondary).child(label))).child(element));
        }
        // Send-to-session cards wait in Main.
        {
            for (id, title, text) in confirms {
                body = body.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .max_w(relative(0.85))
                        .p_3()
                        .rounded(px(14.))
                        .bg(theme.tile)
                        .border_1()
                        .border_color(theme.orange())
                        .child(div().text_xs().text_color(theme.secondary).child(format!("Send to {title}?")))
                        .child(div().text_sm().text_color(theme.fg).child(text))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .gap_1()
                                .child(button(format!("send-{id}"), "Send", true, theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.act(Act::Confirm(id, true), window, cx))))
                                .child(button(format!("nosend-{id}"), "Don't send", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.act(Act::Confirm(id, false), window, cx)))),
                        ),
                );
            }
        }
        if !streaming.trim().is_empty() {
            let shown = if errand { without_contract(&streaming).to_string() } else { streaming.clone() };
            body = body.child(div().max_w(relative(0.85)).px_3().py_1p5().rounded(px(18.)).bg(theme.tile).text_sm().text_color(theme.fg).child(markdown(&format!("stream-{thread}"), &shown, theme)));
        } else if busy {
            let line = status.map(|s| if s == "compacting" { "Compacting".to_string() } else { s }).or(doing).unwrap_or_else(|| "Thinking".into());
            // Stop asks claude to end the turn, as Esc does; Restart ends its
            // process, for when it doesn't.
            let (stop_who, restart_who) = (who.clone(), who.clone());
            let controls = div()
                .flex()
                .flex_row()
                .gap_1()
                .child(button(format!("stop-{thread}"), "Stop", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.marra.update(cx, |m, _| {
                        if let Some(c) = m.convo_mut(&stop_who) {
                            c.engine.interrupt();
                        }
                    });
                })))
                .child(button(format!("restart-{thread}"), "Restart", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.marra.update(cx, |m, cx| {
                        if let Some(c) = m.convo_mut(&restart_who) {
                            c.restart();
                        }
                        cx.notify();
                    });
                })));
            body = body.child(
                div()
                    .flex()
                    .flex_col()
                    .items_start()
                    .gap_1()
                    .child(div().flex().flex_row().items_center().gap_2().px_3().py_1p5().rounded(px(18.)).bg(theme.tile).text_sm().text_color(theme.secondary).child(spinner(SharedString::from(format!("doing-{thread}")), 14., theme)).child(div().max_w(px(300.)).truncate().child(line)))
                    .child(controls),
            );
        }
        body.into_any_element()
    }

    fn composer_view(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let busy = self.marra.read(cx).main.busy() && self.open.as_deref().is_none_or(|o| o == "main");
        let token = self.typing_token(cx);
        let options = token.as_deref().map(|t| self.suggestions(t, cx)).unwrap_or_default();
        let highlighted = self.suggest.min(options.len().saturating_sub(1));
        let keyed = options.clone();
        div()
            .flex_none()
            .flex()
            .flex_col()
            .gap_2()
            .px_4()
            .pt_3()
            .pb_4()
            .border_t_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .when(!options.is_empty(), |d| {
                d.child(
                    div()
                        .flex()
                        .flex_col()
                        .p_1()
                        .rounded(px(12.))
                        .bg(theme.popover)
                        .border_1()
                        .border_color(theme.border)
                        .shadow_lg()
                        .children(options.into_iter().enumerate().map(|(n, (insert, label, id))| {
                            let chosen = insert.clone();
                            div()
                                .id(SharedString::from(format!("suggest-{n}")))
                                .flex()
                                .flex_row()
                                .gap_2()
                                .px_2()
                                .py_1()
                                .rounded(px(8.))
                                .cursor_pointer()
                                .when(n == highlighted, |d| d.bg(theme.selected))
                                .when(n != highlighted, |d| d.hover(|s| s.bg(theme.row_selected)))
                                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.accept(chosen.clone(), id.clone(), window, cx)))
                                .child(div().flex_none().max_w(px(200.)).truncate().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(if n == highlighted { theme.on_selected } else { theme.fg }).child(insert))
                                .child(div().flex_1().min_w_0().truncate().text_sm().text_color(if n == highlighted { theme.on_selected } else { theme.secondary }).child(label))
                        })),
                )
            })
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_end()
                    .gap_2()
                    .px_3()
                    .py_2()
                    .rounded(px(18.))
                    .border_1()
                    .border_color(theme.border)
                    .bg(theme.bg)
                    .capture_key_down(cx.listener(move |this, event: &KeyDownEvent, window, cx| {
                        let key = event.keystroke.key.as_str();
                        if !keyed.is_empty() {
                            match key {
                                "down" => this.suggest = (this.suggest + 1).min(keyed.len() - 1),
                                "up" => this.suggest = this.suggest.saturating_sub(1),
                                "enter" | "tab" if !event.keystroke.modifiers.platform => {
                                    let (pick, _, id) = keyed[this.suggest.min(keyed.len() - 1)].clone();
                                    cx.stop_propagation();
                                    this.accept(pick, id, window, cx);
                                    return;
                                }
                                "escape" => this.suggest_closed = this.typing_token(cx),
                                _ => return,
                            }
                            cx.stop_propagation();
                            cx.notify();
                            return;
                        }
                        // Return sends; Shift-Return (or Option, Control) is a new line.
                        let m = &event.keystroke.modifiers;
                        if key == "enter" && !m.shift && !m.alt && !m.control {
                            cx.stop_propagation();
                            this.send(window, cx);
                        } else if key == "escape" && this.open.is_some() && this.composer.read(cx).text(cx).is_empty() {
                            cx.stop_propagation();
                            this.back(cx);
                        }
                    }))
                    .child(div().flex_1().min_w_0().py_0p5().child(self.composer.clone()))
                    .child(if busy {
                        div()
                            .id("stop")
                            .flex_none()
                            .size(px(28.))
                            .rounded_full()
                            .bg(theme.secondary)
                            .flex()
                            .items_center()
                            .justify_center()
                            .text_xs()
                            .text_color(theme.bg)
                            .cursor_pointer()
                            .child("■")
                            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.marra.update(cx, |m, _| m.main.engine.interrupt())))
                    } else {
                        div()
                            .id("send")
                            .flex_none()
                            .size(px(28.))
                            .rounded_full()
                            .bg(theme.selected)
                            .flex()
                            .items_center()
                            .justify_center()
                            .text_sm()
                            .text_color(theme.on_selected)
                            .cursor_pointer()
                            .child("↑")
                            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.send(window, cx)))
                    }),
            )
    }
}

impl Focusable for MarraView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for MarraView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        self.theme = theme;
        // The conversation follows what's new while you're at its end (within
        // a line), and a thread opens at its end; scrolled up, it stays put.
        let behind = self.chat_scroll.max_offset().y + self.chat_scroll.offset().y;
        if self.chat_for != self.open {
            self.chat_for = self.open.clone();
            self.chat_scroll.scroll_to_bottom();
        } else if behind <= px(24.) {
            self.chat_scroll.scroll_to_bottom();
        }
        // The composer says what Return does: add a todo, or message.
        let todos_open = self.open.as_deref() == Some("todos");
        if todos_open != self.todo_placeholder {
            self.todo_placeholder = todos_open;
            self.composer.update(cx, |editor, cx| editor.set_placeholder_text(if todos_open { "Add a todo" } else { "Message Marra" }, window, cx));
        }
        let menus = self.menus(&theme, cx);
        let row_menu = self.row_menu_view(&theme, cx);
        let panel = if self.split() {
            // The list on the left; the thread clicked, and the composer
            // that writes to it, on the right.
            let list = div().flex_none().w(px(340.)).h_full().min_h_0().flex().flex_col().border_r_1().border_color(theme.border).bg(theme.bg).child(self.new_issue_view(&theme, cx)).child(self.needs_view(&theme, cx)).child(self.threads_view(&theme, cx));
            let detail = div()
                .relative()
                .flex_1()
                .min_w_0()
                .h_full()
                .min_h_0()
                .flex()
                .flex_col()
                .bg(theme.bg)
                .map(|d| match self.open.clone() {
                    Some(id) => d.child(self.thread_view(&id, &theme, cx)),
                    None => d.child(div().flex_1().flex().items_center().justify_center().text_sm().text_color(theme.secondary).child("Choose a thread")),
                })
                .child(self.composer_view(&theme, cx));
            div().relative().flex_1().min_h_0().flex().flex_row().child(list).child(detail)
        } else {
            div()
                .relative()
                .flex_1()
                .min_h_0()
                .flex()
                .flex_col()
                .bg(theme.bg)
                .map(|d| match self.open.clone() {
                    Some(id) => d.child(self.thread_view(&id, &theme, cx)),
                    None => d.child(self.new_issue_view(&theme, cx)).child(self.needs_view(&theme, cx)).child(self.threads_view(&theme, cx)),
                })
                .child(self.composer_view(&theme, cx))
        };
        div()
            .id("marra")
            .track_focus(&self.focus)
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                let k = &event.keystroke;
                if k.modifiers.alt && !k.modifiers.platform {
                    let lane = match k.key.as_str() {
                        "b" => Some(Lane::Build),
                        "r" => Some(Lane::Review),
                        "a" => Some(Lane::Ask),
                        _ => return,
                    };
                    this.lane = if this.lane == lane { None } else { lane };
                    this.selected = 0;
                    cx.stop_propagation();
                    cx.notify();
                }
            }))
            .relative()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .text_color(theme.fg)
            .font_family(".SystemUIFont")
            .child(self.title_bar(&theme, cx))
            .child(panel)
            .when_some(menus, |d, m| d.child(m))
            .when_some(row_menu, |d, m| d.child(m))
    }
}


/// The lines under "Since you looked": how long it worked, from Gannin's
/// log, then what its transcript says it did; the log alone when there's
/// no transcript.
fn since_lines(log: &[(chrono::DateTime<chrono::Local>, String)], digest: Option<&Option<crate::marra_mcp::Digest>>, working: bool, theme: &Theme) -> Vec<AnyElement> {
    let line = |text: String| div().text_sm().text_color(theme.fg).child(text).into_any_element();
    let mut out = Vec::new();
    // Each Working entry lasts until the next entry, or until now.
    let mut minutes = 0i64;
    let mut turns = 0usize;
    for (i, (at, what)) in log.iter().enumerate() {
        if what == "Working" {
            turns += 1;
            let end = log.get(i + 1).map(|(next, _)| *next).unwrap_or_else(|| if working { chrono::Local::now() } else { *at });
            minutes += (end - *at).num_seconds().max(0);
        }
    }
    let minutes = (minutes + 30) / 60;
    let worked = match (turns, minutes) {
        (0, _) => None,
        (1, m) if m < 1 => Some("Worked once, briefly".to_string()),
        (1, m) => Some(format!("Worked once, about {m} min")),
        (n, m) if m < 1 => Some(format!("Worked {n} times, briefly")),
        (n, m) => Some(format!("Worked {n} times, about {m} min in all")),
    };
    match digest.and_then(|d| d.as_ref()) {
        Some(d) if d.is_empty() && worked.is_none() => out.push(line("Nothing new".into())),
        Some(d) => {
            let mut doing: Vec<String> = worked.into_iter().collect();
            if d.commands > 0 {
                doing.push(format!("ran {} command{}", d.commands, if d.commands == 1 { "" } else { "s" }));
            }
            if d.tools > d.commands {
                doing.push(format!("{} other step{}", d.tools - d.commands, if d.tools - d.commands == 1 { "" } else { "s" }));
            }
            if !doing.is_empty() {
                let mut text = doing.join(", ");
                if let Some(first) = text.get_mut(0..1) {
                    first.make_ascii_uppercase();
                }
                out.push(line(text));
            }
            if let Some(last) = d.prompts.last() {
                let more = d.prompts.len() - 1;
                let first_line = last.lines().find(|l| !l.trim().is_empty()).unwrap_or_default();
                out.push(line(format!("You asked: {}{}", clip_line(first_line, 140), if more > 0 { format!(" (and {more} more)") } else { String::new() })));
            }
            if !d.files.is_empty() {
                let shown: Vec<&str> = d.files.iter().take(4).map(String::as_str).collect();
                let rest = d.files.len().saturating_sub(4);
                out.push(line(format!(
                    "Changed {} file{}: {}{}",
                    d.files.len(),
                    if d.files.len() == 1 { "" } else { "s" },
                    shown.join(", "),
                    if rest > 0 { format!(" and {rest} more") } else { String::new() }
                )));
            }
            if let Some(reply) = &d.last_reply {
                let first = reply.split("\n\n").next().unwrap_or(reply);
                out.push(div().text_sm().text_color(theme.secondary).child(format!("Ended with: {}", clip_line(&first.replace('\n', " "), 280))).into_any_element());
            }
        }
        // No transcript: Gannin's log, condensed.
        _ => out.push(line(worked.unwrap_or_else(|| "Nothing new".into()))),
    }
    out
}

fn clip_line(text: &str, max: usize) -> String {
    let text = text.trim();
    if text.chars().count() <= max {
        text.to_string()
    } else {
        // Cut at a word, so a clipped quote doesn't end mid-word.
        let cut: String = text.chars().take(max).collect();
        cut.rsplit_once(' ').map(|(head, _)| head.to_string()).unwrap_or(cut)
    }
}
