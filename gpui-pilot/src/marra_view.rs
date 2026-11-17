//! Marra's window (docs/marra.md): Needs you at the top, the threads under
//! it, a thread's conversation, and the input. The same view floats in a
//! window of its own or docks down the right of a Gannin window; both show
//! the one `Marra` model.

use crate::charts::Theme;
use crate::marra::Entry;
use crate::marra_model::{self, ago, waiting, Act, Lane, Marra, Need, Thread, ThreadKind, Who};
use crate::markdown::markdown;
use crate::shell::Workspace;
use gpui::{actions, div, prelude::*, px, AnyElement, App, ClickEvent, Context, Entity, FocusHandle, Focusable, FontWeight, Hsla, KeyDownEvent, Pixels, Point, SharedString, Subscription, Task, Window};
use std::collections::HashSet;
use std::time::{Duration, Instant};

actions!(marra, [ToggleMarra]);

/// Remind me's choices: label and minutes (None: when CI passes).
const REMIND: [(&str, Option<i64>); 7] = [("5m", Some(5)), ("10m", Some(10)), ("15m", Some(15)), ("30m", Some(30)), ("1h", Some(60)), ("Tomorrow", Some(-1)), ("When CI passes", None)];

/// The models offered in the menu; any other goes with /model.
const MODELS: [(&str, Option<&str>); 4] = [("Claude's default", None), ("Opus", Some("opus")), ("Sonnet", Some("sonnet")), ("Haiku", Some("haiku"))];

const COMMANDS: [(&str, &str); 13] = [
    ("/waiting", "What needs you now"),
    ("/catch-up", "Sum up the unread threads"),
    ("/ask", "A data question, answered by a worker in a harness"),
    ("/investigate", "Investigate a ticket or bug with the harness skills"),
    ("/review", "Review requests waiting on you"),
    ("/standup", "Yesterday and today, from your work"),
    ("/open", "Bring a session's tab forward"),
    ("/later", "Park the top item for 30 minutes"),
    ("/compact", "Compact Marra's conversation"),
    ("/new", "Start a new conversation"),
    ("/model", "Marra's model: /model sonnet, /model default"),
    ("/notes", "Edit Marra's notes about you"),
    ("/help", "What Marra can do"),
];

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
    row_menu: Option<(String, Point<Pixels>)>,
    menu_closed: Option<Instant>,
    suggest: usize,
    suggest_closed: Option<String>,
    long_open: HashSet<(String, usize)>,
    /// What @ inserted, and the exact id it stands for.
    mentions: Vec<(String, String)>,
    /// The skills the harnesses offer, for @.
    skills: Vec<String>,
    /// A session thread's conversation, read from its transcript.
    tail: Option<(String, Vec<(String, String)>)>,
    /// What the session did since it was last read, taken as it opened.
    since: Option<(String, Vec<(chrono::DateTime<chrono::Local>, String)>)>,
    _tail_task: Option<Task<()>>,
    theme: Theme,
    _subscriptions: Vec<Subscription>,
}

impl MarraView {
    pub fn new(docked: bool, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let marra = Marra::get(cx);
        let composer = cx.new(|cx| {
            let mut editor = editor::Editor::auto_height(2, 10, window, cx);
            editor.set_placeholder_text("Message Marra", window, cx);
            editor
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
                let thread = marra.read(cx).threads(cx).into_iter().find(|t| t.id == open);
                if thread.is_some_and(|t| marra.read(cx).is_unread(&t)) {
                    marra.update(cx, |m, _| m.mark_read(&open, true));
                }
            }
            cx.notify();
        });
        window.focus(&composer.focus_handle(cx), cx);
        if !docked {
            keep_up(window);
        }
        let skills = crate::marra_mcp::skills().lines().filter_map(|l| l.trim_start().strip_prefix("- ")).map(|l| l.split(':').next().unwrap_or(l).trim().to_string()).collect();
        Self {
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
            row_menu: None,
            menu_closed: None,
            suggest: 0,
            suggest_closed: None,
            long_open: HashSet::new(),
            mentions: Vec::new(),
            skills,
            tail: None,
            since: None,
            _tail_task: None,
            theme: Theme::for_window(window),
            _subscriptions: vec![edits, observe],
        }
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

    // MARK: Queries

    fn needs(&self, cx: &App) -> Vec<Need> {
        let mut needs = self.marra.read(cx).needs(self.scope.as_deref(), cx);
        if let Some(lane) = self.lane {
            needs.retain(|n| n.lane == lane);
        }
        needs
    }

    fn listed(&self, cx: &App) -> Vec<Thread> {
        let marra = self.marra.read(cx);
        let mut threads = marra.threads(cx);
        if let Some(scope) = &self.scope {
            threads.retain(|t| t.org.as_deref().is_none_or(|o| o == scope));
        }
        if self.unread_only {
            threads.retain(|t| marra.is_unread(t) || t.kind == ThreadKind::Main);
        }
        // Main first, then the newest; pinned ones lead.
        threads.sort_by(|a, b| (b.kind == ThreadKind::Main).cmp(&(a.kind == ThreadKind::Main)).then(b.activity.cmp(&a.activity)));
        threads
    }

    fn orgs(&self, cx: &App) -> Vec<String> {
        let mut orgs: Vec<String> = marra_model::sessions(cx).into_iter().filter_map(|s| s.org).collect();
        orgs.extend(marra_model::work(cx).reviews.iter().chain(&marra_model::work(cx).mine).filter_map(|p| p.repo.split('/').next().map(str::to_string)));
        orgs.sort();
        orgs.dedup();
        orgs
    }

    // MARK: Doing

    fn open_thread(&mut self, id: String, cx: &mut Context<Self>) {
        self.since = id.strip_prefix("s:").map(|key| (key.to_string(), self.marra.read(cx).since_read(key)));
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
        let claude = marra_model::sessions(cx).into_iter().find(|s| s.key == key).and_then(|s| s.claude_id);
        self._tail_task = Some(cx.spawn(async move |this, cx| loop {
            let lines = match claude.clone() {
                Some(id) => cx.background_executor().spawn(async move { crate::marra_mcp::transcript_messages(&id, 30).unwrap_or_default() }).await,
                None => Vec::new(),
            };
            let key = key.clone();
            let gone = this
                .update(cx, |this, cx| {
                    if this.tail.as_ref().is_none_or(|(k, l)| k != &key || l != &lines) {
                        this.tail = Some((key, lines));
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

    fn act(&mut self, act: Act, window: &mut Window, cx: &mut Context<Self>) {
        match act {
            Act::OpenSession(key) => {
                self.marra.update(cx, |m, cx| {
                    m.mark_read(&format!("s:{key}"), true);
                    m.open_session(&key, cx);
                });
            }
            Act::OpenThread(id) => self.open_thread(id, cx),
            Act::Url(url) => cx.open_url(&url),
            Act::StartReview(subject) => self.marra.update(cx, |m, cx| m.start_review(subject, cx)),
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
                        self.marra.update(cx, |m, cx| {
                            m.open_session(&key, cx);
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
            "help" => note(self, text, COMMANDS.iter().map(|(c, d)| format!("- `{c}`: {d}")).collect::<Vec<_>>().join("\n") + "\n\nAsk anything else in plain words: Marra reads Gannin's sessions and your work.", cx),
            "catch-up" => {
                let marra = self.marra.read(cx);
                let unread: Vec<String> = marra.threads(cx).into_iter().filter(|t| marra.is_unread(t) && t.kind != ThreadKind::Main).map(|t| format!("- {} ({}): {}", t.title, t.id, t.last)).collect();
                let sent = if unread.is_empty() { "Catch me up: is anything waiting on me? Check with your tools.".to_string() } else { format!("Catch me up on these unread threads, most urgent first, one line each, reading the sessions with read_session where it helps:\n{}", unread.join("\n")) };
                prompt(self, text, sent, cx);
            }
            "standup" => prompt(self, text, "Write my standup: yesterday, today and blockers, a few bullets each, from my sessions (list_sessions, read_session) and my PRs and issues (workload). Only what you can see; say if something's missing.".into(), cx),
            "ask" | "investigate" if !arg.is_empty() => {
                let kind = if name == "ask" { "question" } else { "investigation" };
                prompt(self, text, format!("Start a {kind} errand for this with start_errand, choosing the harness and skills from list_skills (say which you chose): {arg}"), cx);
            }
            _ => return false,
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
            COMMANDS.iter().map(|(c, d)| (c.to_string(), d.to_string(), None)).collect()
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

fn open_floating(cx: &mut App) {
    let options = gpui::WindowOptions {
        window_bounds: Some(gpui::WindowBounds::Windowed(gpui::Bounds::centered(None, gpui::size(px(460.), px(800.)), cx))),
        titlebar: Some(gpui::TitlebarOptions { title: Some("Marra".into()), appears_transparent: true, traffic_light_position: Some(gpui::point(px(14.), px(13.))) }),
        kind: gpui::WindowKind::Floating,
        ..Default::default()
    };
    if let Ok(handle) = cx.open_window(options, |window, cx| cx.new(|cx| MarraView::new(false, window, cx))) {
        let any: gpui::AnyWindowHandle = handle.into();
        Marra::get(cx).update(cx, |m, _| m.floating = Some(any));
        let _ = handle.update(cx, |_, window, _| window.activate_window());
    }
}

/// Docks Marra into the front Gannin window, or floats it again.
fn set_docked(docked: bool, window: &mut Window, cx: &mut App) {
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
    let _ = window;
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

fn section(label: impl Into<SharedString>, theme: &Theme) -> gpui::Div {
    div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(label.into())
}

fn avatar(kind: ThreadKind, theme: &Theme) -> (&'static str, Hsla) {
    match kind {
        ThreadKind::Main => ("icons/sparkle.svg", theme.selected),
        ThreadKind::Question => ("icons/database_zap.svg", theme.slot(6)),
        ThreadKind::Investigation => ("icons/magnifying_glass.svg", theme.orange()),
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
        let unread = marra.threads(cx).iter().filter(|t| marra.is_unread(t)).count();
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
                    let count = self.marra.read(cx).needs(scope.as_deref(), cx).len();
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
                            "notes" => edit_notes(cx),
                            "read" => this.marra.update(cx, |m, cx| {
                                for t in m.threads(cx) {
                                    m.saved.read.insert(t.id, chrono::Local::now().to_rfc3339());
                                }
                                m.saved.save();
                                cx.notify();
                            }),
                            "focus" => this.marra.update(cx, |m, cx| m.set_focus(!focus, cx)),
                            _ => {
                                let docked = this.docked;
                                cx.defer_in(window, move |_, window, cx| set_docked(!docked, window, cx));
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
        // Phone access: the API on the local network, with its pairing code.
        let (api_on, code, error) = {
            let m = self.marra.read(cx);
            (m.api.is_some(), m.api.as_ref().and_then(|a| a.code()), m.api_error.clone())
        };
        let devices = crate::marra_api::devices().len();
        rows.push(div().mx_2().my_1().h(px(1.)).bg(theme.border).into_any_element());
        rows.push(
            Self::menu_row("phone", if api_on { "✓ Phone access" } else { "   Phone access" }, false, theme)
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.marra.update(cx, |m, cx| {
                        m.set_api(!api_on);
                        cx.notify();
                    });
                    cx.notify();
                }))
                .into_any_element(),
        );
        if let Some(error) = error {
            rows.push(div().px_2().pb_1().text_xs().text_color(theme.orange()).child(error).into_any_element());
        }
        if api_on {
            let address = crate::marra_api::address().unwrap_or_else(|| "no local network".into());
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
                        d.child(div().id("revoke").text_xs().text_color(theme.orange()).cursor_pointer().child("Revoke all").on_click(cx.listener(|_, _: &ClickEvent, _, cx| {
                            crate::marra_api::revoke_all();
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
                                }))),
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
                            .child(div().text_sm().text_color(theme.tertiary).child("›")),
                    )
                    .child(div().truncate().text_xs().text_color(if muted { theme.tertiary } else { theme.secondary }).child(if thread.last.is_empty() { " ".to_string() } else { thread.last.clone() })),
            )
    }

    fn row_menu_view(&self, theme: &Theme, cx: &mut Context<Self>) -> Option<AnyElement> {
        let (id, at) = self.row_menu.clone()?;
        let marra = self.marra.read(cx);
        let thread = marra.threads(cx).into_iter().find(|t| t.id == id)?;
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
        let marra = self.marra.read(cx);
        let Some(thread) = marra.threads(cx).into_iter().find(|t| t.id == id) else {
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
            .h(px(52.))
            .border_b_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .child(div().id("back").flex_none().w(px(80.)).text_sm().text_color(theme.selected).cursor_pointer().child("‹ Threads").on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.back(cx))))
            .child(div().flex_1().min_w_0().flex().flex_col().items_center().child(avatar_view(thread.kind, false, 26., 15., theme)).child(div().max_w(px(260.)).truncate().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child(thread.title.clone())))
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
                        div().id("pin").cursor_pointer().text_xs().text_color(theme.selected).child(if pinned { "Unpin" } else { "Pin" }).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            let id = id.clone();
                            this.marra.update(cx, |m, cx| {
                                Marra::toggle(&mut m.saved.pinned, &id);
                                m.saved.save();
                                cx.notify();
                            });
                        }))
                    })
                    .when_some(session.clone(), |d, key| {
                        d.child(div().id("thread-expand").px_1().cursor_pointer().child(gpui::svg().path("icons/maximize.svg").size(px(14.)).text_color(theme.selected)).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.act(Act::OpenSession(key.clone()), window, cx))))
                    }),
            );
        let body = match &session {
            Some(key) => self.session_body(key, theme, cx),
            None => {
                let who = if id == "main" { Who::Main } else { Who::Errand(id[2..].to_string()) };
                self.convo_body(id, &who, theme, cx)
            }
        };
        div().flex_1().min_h_0().flex().flex_col().child(nav).child(body).into_any_element()
    }

    /// A session's thread: where you left off, from Gannin's own state, then
    /// its conversation from the transcript.
    fn session_body(&self, key: &str, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let info = marra_model::sessions(cx).into_iter().find(|s| s.key == key);
        let need = self.marra.read(cx).needs(None, cx).into_iter().find(|n| n.thread.as_deref() == Some(&format!("s:{key}")));
        let lines = self.tail.as_ref().filter(|(k, _)| k == key).map(|(_, l)| l.clone()).unwrap_or_default();
        // What happened since the last look, from Gannin's log; frozen when
        // the thread opened, as opening marks it read.
        let since = self.since.clone().filter(|(k, _)| k == key).map(|(_, l)| l).unwrap_or_default();
        let mut body = div().id(SharedString::from(format!("session-body-{key}"))).flex_1().min_h_0().overflow_y_scroll().flex().flex_col().gap_2().px_3().py_3();
        if let Some(s) = &info {
            let what = format!("{} ({}){}", s.subject.clone().unwrap_or_else(|| s.title.clone()), s.kind, s.server.as_ref().map(|n| format!(", on {n}")).unwrap_or_default());
            let state = format!("{} since {}", s.state.label(), s.since.format("%H:%M"));
            body = body.child(
                div()
                    .flex()
                    .flex_col()
                    .gap_0p5()
                    .w_full()
                    .p_3()
                    .rounded(px(14.))
                    .bg(theme.sidebar)
                    .child(div().text_xs().text_color(theme.secondary).child("Where you left off"))
                    .child(div().text_sm().text_color(theme.fg).child(format!("What it is: {what}")))
                    .child(div().text_sm().text_color(theme.fg).child(format!("Now: {state}")))
                    .child(div().text_sm().text_color(theme.fg).child(if since.is_empty() { "Since you looked: nothing new".to_string() } else { format!("Since you looked: {}", since.iter().map(|(at, what)| format!("{what} at {}", at.format("%H:%M"))).collect::<Vec<_>>().join(", ")) }))
                    .when_some(need, |d, n| d.child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.orange()).child(format!("Wants from you: {}", n.task)))),
            );
        }
        if lines.is_empty() {
            body = body.child(div().w_full().px_6().text_xs().text_color(theme.secondary).text_center().child(if info.as_ref().is_some_and(|s| s.claude_id.is_some()) { "Reading its conversation." } else { "A plain session: open it to see its terminal." }));
        }
        for (n, (who, text)) in lines.iter().enumerate() {
            body = body.child(match who.as_str() {
                "tool" => div().pl_3().flex().flex_row().gap_1().items_center().child(gpui::svg().path("icons/tool_hammer.svg").size(px(11.)).text_color(theme.tertiary)).child(div().min_w_0().truncate().text_xs().text_color(theme.tertiary).child(text.clone())).into_any_element(),
                "User" => div().w_full().flex().flex_col().items_end().child(div().max_w(px(320.)).px_3().py_1p5().rounded(px(18.)).text_sm().bg(theme.selected).text_color(theme.on_selected).children(text.lines().map(|l| div().child(l.to_string())))).into_any_element(),
                _ => self.folded(&format!("s:{key}"), n, text, theme, cx),
            });
        }
        body.into_any_element()
    }

    /// A long reply folds with a fade and Show all.
    fn folded(&self, thread: &str, n: usize, text: &str, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let long = text.lines().count() > 12 || text.len() > 900;
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
                    .max_w(px(380.))
                    .px_3()
                    .py_1p5()
                    .rounded(px(18.))
                    .bg(theme.tile)
                    .text_sm()
                    .text_color(theme.fg)
                    .when(long && !open, |d| d.h(px(200.)).overflow_hidden())
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
        let mut body = div().id(SharedString::from(format!("convo-{thread}"))).flex_1().min_h_0().overflow_y_scroll().flex().flex_col().gap_2().px_3().py_3();
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
                Entry::You { text, .. } => div().w_full().flex().flex_col().items_end().child(div().max_w(px(320.)).px_3().py_1p5().rounded(px(18.)).text_sm().bg(theme.selected).text_color(theme.on_selected).children(text.lines().map(|l| div().child(l.to_string())))).into_any_element(),
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
                        .child(div().max_w(px(340.)).px_3().py_1p5().rounded(px(18.)).bg(theme.tile).text_sm().font_weight(FontWeight::MEDIUM).text_color(theme.fg).child(point.clone()))
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
                            .max_w(px(380.))
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
                        .max_w(px(380.))
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
            body = body.child(div().max_w(px(380.)).px_3().py_1p5().rounded(px(18.)).bg(theme.tile).text_sm().text_color(theme.fg).child(markdown(&format!("stream-{thread}"), &shown, theme)));
        } else if busy {
            let line = status.map(|s| if s == "compacting" { "Compacting".to_string() } else { s }).or(doing).unwrap_or_else(|| "Thinking".into());
            body = body.child(div().flex().flex_col().items_start().child(div().flex().flex_row().items_center().gap_2().px_3().py_1p5().rounded(px(18.)).bg(theme.tile).text_sm().text_color(theme.secondary).child(spinner(SharedString::from(format!("doing-{thread}")), 14., theme)).child(div().max_w(px(300.)).truncate().child(line))));
        }
        body.into_any_element()
    }

    fn composer_view(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let target = match self.open.as_deref() {
            Some(id) if id.starts_with("s:") => Some("Goes to this session's Claude Code, as if typed there"),
            Some(id) if id.starts_with("e:") => Some("Goes to this errand's worker"),
            _ => None,
        };
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
            .when_some(target, |d, target| d.child(div().text_xs().text_color(theme.tertiary).child(target)))
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
                        if key == "enter" && event.keystroke.modifiers.platform {
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
            .child(div().truncate().text_xs().text_color(theme.tertiary).child("⌘↩ send · / commands · @ mention · ⌥B ⌥R ⌥A lanes"))
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
        let menus = self.menus(&theme, cx);
        let row_menu = self.row_menu_view(&theme, cx);
        let panel = div()
            .relative()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .map(|d| match self.open.clone() {
                Some(id) => d.child(self.thread_view(&id, &theme, cx)),
                None => d.child(self.needs_view(&theme, cx)).child(self.threads_view(&theme, cx)),
            })
            .child(self.composer_view(&theme, cx));
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

