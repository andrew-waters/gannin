//! A piece of work in a tab of its own: Zed's terminal, running Claude Code
//! or a shell in a folder, beside the code change it's making in Zed's diff
//! view. In place of Gannin's session window and its Changes pane.
//!
//! Gannin knows a session's state from the files Claude Code's hooks write.
//! The pilot installs no hooks, so it reads the terminal instead: output
//! moving means working, a question on screen or a bell means it needs
//! you, and quiet means it's your turn.

use crate::changes::ChangesView;
use crate::charts::Theme;
use gpui::{div, prelude::*, px, App, ClickEvent, Context, Entity, FocusHandle, Focusable, SharedString, Task, WeakEntity, Window};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use terminal::{Terminal, TerminalBuilder};
use terminal_view::TerminalView;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Claude,
    Shell,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum State {
    Working,
    /// A permission prompt or a question on screen, or the bell rang.
    NeedsYou,
    /// Quiet: Claude has finished and waits for you.
    YourTurn,
    Ended,
}

impl State {
    pub fn label(self) -> &'static str {
        match self {
            State::Working => "Working",
            State::NeedsYou => "Needs you",
            State::YourTurn => "Your turn",
            State::Ended => "Ended",
        }
    }

    /// How soon it wants you: lower comes first.
    pub fn rank(self) -> u8 {
        match self {
            State::NeedsYou => 0,
            State::YourTurn => 1,
            State::Working => 2,
            State::Ended => 3,
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Show {
    Both,
    Terminal,
    Changes,
}

/// Output this recent means it's still working.
const QUIET: Duration = Duration::from_millis(1500);

pub struct SessionPage {
    pub id: u32,
    pub kind: Kind,
    /// Started the way Gannin starts a session (Work on This, a review, an
    /// Ask and so on): its state comes from the hooks' files, not the screen.
    pub launch: Option<crate::launch::Launch>,
    /// A plain Claude Code session's conversation ID, which it was started
    /// with, so the window can open it again and claude resume it.
    pub claude_id: Option<String>,
    folder: PathBuf,
    terminal: Entity<Terminal>,
    view: Entity<TerminalView>,
    changes: Entity<ChangesView>,
    /// A review session's findings, shown where Changes would be.
    review: Option<Entity<crate::review_panel::ReviewPanel>>,
    /// A Work on This session's panel: the terminal with the issue, its
    /// changes, PRs and activity beside it.
    work: Option<Entity<crate::work_panel::WorkPanel>>,
    /// A planning session's workspace, shown where Changes would be.
    planning: Option<Entity<crate::planning_panel::PlanningPanel>>,
    show: Show,
    pub state: State,
    /// When the state last changed, for "waiting since".
    pub since: chrono::DateTime<chrono::Local>,
    /// The server a plain session runs on, its folder being a path there:
    /// no Changes, as the folder isn't on this Mac.
    server: Option<crate::servers::Server>,
    /// While Move to Server runs: where it's going and the step it's on.
    /// The whole page is covered, so nothing in it can be used meanwhile.
    pub moving: Option<(String, String)>,
    last_output: Instant,
    _subscriptions: Vec<gpui::Subscription>,
    _tick: Task<()>,
}

/// Emitted when the title or state changes, so the tab and the work panel
/// redraw (not on every frame of output).
pub struct Changed;

impl gpui::EventEmitter<Changed> for SessionPage {}
impl gpui::EventEmitter<crate::review_panel::ExplainPr> for SessionPage {}
impl gpui::EventEmitter<crate::work_panel::WorkEvent> for SessionPage {}
impl gpui::EventEmitter<crate::harness::OpenDoc> for SessionPage {}

/// The command a plain Claude Code tab runs. `claude_id` is the tab's own
/// key: the conversation running in it can change (`/resume`, `/clear`), so
/// a SessionStart hook writes whichever one is running to
/// `~/.gannin/plain/<key>` on the machine it runs on, and the next start
/// resumes that one. It resumes only a conversation with a transcript (a
/// session never typed into has none, and `--resume` would refuse it), else
/// starts one under the key.
fn plain_claude(claude_id: Option<&str>) -> String {
    let Some(id) = claude_id else { return "claude".into() };
    let file = format!("\"$HOME/.gannin/plain/{id}\"");
    // Run with the hook's JSON on stdin; base64 keeps it clear of the
    // quoting in --settings and, on a server, ssh's.
    let hook = format!(
        "s=$(sed -n 's/.*\"session_id\" *: *\"\\([^\"]*\\)\".*/\\1/p' | head -n 1); [ -n \"$s\" ] && mkdir -p \"$HOME/.gannin/plain\" && printf %s \"$s\" > {file}; exit 0"
    );
    use base64::Engine;
    let encoded = base64::engine::general_purpose::STANDARD.encode(hook);
    let settings = format!("{{\"hooks\":{{\"SessionStart\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":\"sh -c \\\"$(echo {encoded} | base64 -d)\\\"\"}}]}}]}}");
    format!(
        "cur=$(cat {file} 2>/dev/null); case \"$cur\" in ''|*[!0-9a-f-]*) cur={id};; esac; \
         if [ -n \"$(find \"$HOME/.claude/projects\" -maxdepth 2 -name \"$cur.jsonl\" 2>/dev/null | head -n 1)\" ]; then exec claude --resume \"$cur\" --settings '{settings}'; \
         elif [ -n \"$(find \"$HOME/.claude/projects\" -maxdepth 2 -name '{id}.jsonl' 2>/dev/null | head -n 1)\" ]; then exec claude --resume {id} --settings '{settings}'; \
         else exec claude --session-id {id} --settings '{settings}'; fi"
    )
}

pub fn spawn_terminal(kind: Kind, folder: PathBuf, launch: Option<&crate::launch::Launch>, server: Option<&crate::servers::Server>, claude_id: Option<&str>, window: &Window, cx: &mut App) -> Task<anyhow::Result<TerminalBuilder>> {
    use settings::Settings;
    let settings = terminal::terminal_settings::TerminalSettings::get_global(cx).clone();
    // A resumed claude is starting until its SessionStart hook says it's
    // idle: a session cut off mid-turn (the app quit) left its state saying
    // it's working, and saying idle before claude's up would offer buttons
    // its terminal can't take yet.
    if let Some(launch) = launch {
        let dir = launch.dir();
        if dir.join("started").exists() {
            let _ = std::fs::write(dir.join("state"), "starting");
        }
    }
    // A launch runs its start script in a login shell from home, as
    // Gannin's terminal does.
    let (folder, shell) = match launch {
        Some(launch) => (
            std::env::var_os("HOME").map(PathBuf::from).unwrap_or(folder),
            Some(util::shell::Shell::WithArguments {
                program: crate::paths::shell(),
                args: vec![
                    "-l".into(),
                    "-i".into(),
                    "-c".into(),
                    match &launch.server {
                        // On a server: copied up and run there over ssh,
                        // its files mirrored back.
                        Some(server) => {
                            crate::servers::watch(launch);
                            crate::servers::start_command(server, launch)
                        }
                        None => format!("bash {}", crate::launch::quote(&launch.dir().join("start.sh").to_string_lossy())),
                    },
                ],
                title_override: None,
            }),
        ),
        // A plain session on a server: ssh there, into its folder, with
        // claude (or the shell) from a login shell so the profile's PATH is
        // set up.
        None => match server {
            Some(server) => {
                let run = match kind {
                    Kind::Claude => format!("exec \"${{SHELL:-/bin/bash}}\" -lic {}", crate::launch::quote(&plain_claude(claude_id))),
                    Kind::Shell => "exec \"${SHELL:-/bin/bash}\" -l".to_string(),
                };
                let remote = format!("cd {} && {run}", crate::launch::quote_path(&folder));
                (
                    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default(),
                    Some(util::shell::Shell::WithArguments {
                        program: crate::paths::shell(),
                        args: vec!["-l".into(), "-c".into(), format!("{} {}", server.ssh_command(true), crate::launch::quote(&remote))],
                        title_override: None,
                    }),
                )
            }
            None => (folder, None),
        },
    };
    let shell = if let Some(shell) = shell { shell } else { match kind {
        Kind::Shell => util::shell::Shell::System,
        // Through a login shell, so claude is on the PATH the user's
        // profile sets up.
        Kind::Claude => util::shell::Shell::WithArguments {
            program: crate::paths::shell(),
            args: vec!["-l".into(), "-i".into(), "-c".into(), plain_claude(claude_id)],
            title_override: None,
        },
    } };
    TerminalBuilder::new(
        Some(folder),
        terminal::TerminalMode::interactive(),
        shell,
        Default::default(),
        settings.cursor_shape,
        settings.alternate_scroll,
        settings.max_scroll_history_lines,
        settings.path_hyperlink_regexes,
        Duration::from_millis(settings.path_hyperlink_timeout_ms),
        false,
        window.window_handle().window_id().as_u64(),
        cx,
        Vec::new(),
        util::paths::PathStyle::local(),
    )
}

impl SessionPage {
    /// What the window saves to open this session again: its launch, or a
    /// plain Claude Code session as `plain:<its conversation ID>`. A plain
    /// terminal isn't saved.
    pub fn saved_key(&self) -> Option<String> {
        match (&self.launch, &self.claude_id) {
            (Some(launch), _) => Some(launch.id.clone()),
            (None, Some(id)) => Some(format!("plain:{id}")),
            _ => None,
        }
    }

    /// Where a plain session runs, to open it there again.
    pub fn location(&self) -> crate::folders::Location {
        crate::folders::Location { path: self.folder.clone(), server: self.server.clone() }
    }

    pub fn new(
        id: u32,
        kind: Kind,
        folder: PathBuf,
        launch: Option<crate::launch::Launch>,
        server: Option<crate::servers::Server>,
        builder: TerminalBuilder,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let session_folder = launch.as_ref().map(|l| l.folder());
        let terminal = cx.new(|cx| builder.subscribe(cx));
        // Zed's terminal view, with no Zed workspace or project around it:
        // the handles are empty, and what needs them (opening a path the
        // terminal shows in an editor tab) does nothing.
        let view = cx.new(|cx| TerminalView::new(terminal.clone(), WeakEntity::new_invalid(), None, WeakEntity::new_invalid(), window, cx));
        let start = folder.clone();
        let watched = terminal.downgrade();
        let changes = cx.new(|cx| {
            ChangesView::new(
                move |cx| watched.upgrade().and_then(|t| t.read(cx).working_directory()).or_else(|| Some(start.clone())),
                std::time::SystemTime::now(),
                session_folder,
                window,
                cx,
            )
        });
        let review = launch
            .as_ref()
            .filter(|l| l.flow == crate::launch::Flow::Review)
            .map(|l| {
                let (launch, terminal, terminal_view) = (l.clone(), terminal.clone(), gpui::AnyView::from(view.clone()));
                cx.new(|cx| crate::review_panel::ReviewPanel::new(launch, terminal, terminal_view, window, cx))
            });
        let work = launch.as_ref().filter(|l| l.flow == crate::launch::Flow::Work).map(|l| {
            let (launch, terminal, terminal_view) = (l.clone(), terminal.clone(), gpui::AnyView::from(view.clone()));
            cx.new(|cx| crate::work_panel::WorkPanel::live(launch, terminal, terminal_view, window, cx))
        });
        let planning = launch.as_ref().filter(|l| l.flow == crate::launch::Flow::Plan).map(|l| {
            let (launch, terminal) = (l.clone(), terminal.clone());
            cx.new(|cx| crate::planning_panel::PlanningPanel::new(launch, terminal, window, cx))
        });
        // Reviews and plans open on their panel; every other session on its
        // terminal, Changes a switch away.
        let show = if review.is_some() || planning.is_some() { Show::Changes } else { Show::Terminal };
        let mut subscriptions = Vec::new();
        if let Some(work) = &work {
            // Resume, Finish, Forget and Move to Server act on the tab, so the workspace hears of them.
            subscriptions.push(cx.subscribe(work, |_, _, event: &crate::work_panel::WorkEvent, cx| {
                cx.emit(match event {
                    crate::work_panel::WorkEvent::Resume => crate::work_panel::WorkEvent::Resume,
                    crate::work_panel::WorkEvent::Forget => crate::work_panel::WorkEvent::Forget,
                    crate::work_panel::WorkEvent::MoveToServer => crate::work_panel::WorkEvent::MoveToServer,
                })
            }));
            // A plan's row opens it in a drawer, which the workspace holds.
            subscriptions.push(cx.subscribe(work, |_, _, event: &crate::harness::OpenDoc, cx| cx.emit(crate::harness::OpenDoc(event.0.clone()))));
        }
        if let Some(review) = &review {
            // Explain starts a session of its own, so the workspace hears of it.
            subscriptions.push(cx.subscribe(review, |_, _, event: &crate::review_panel::ExplainPr, cx| cx.emit(crate::review_panel::ExplainPr(event.0.clone(), event.1.clone()))));
            subscriptions.push(cx.subscribe(review, |_, _, event: &crate::harness::OpenDoc, cx| cx.emit(crate::harness::OpenDoc(event.0.clone()))));
        }
        subscriptions.push(cx.subscribe(&terminal, |this, _, event: &terminal::Event, cx| match event {
            terminal::Event::Wakeup => {
                this.last_output = Instant::now();
                if this.launch.is_none() && this.state != State::Working && this.state != State::Ended {
                    this.set_state(State::Working, cx);
                }
            }
            terminal::Event::Bell => this.set_state(State::NeedsYou, cx),
            terminal::Event::TitleChanged | terminal::Event::BreadcrumbsChanged => cx.emit(Changed),
            terminal::Event::CloseTerminal => this.set_state(State::Ended, cx),
            _ => {}
        }));
        // Once a second: has the output gone quiet, and is it asking?
        let tick = cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(Duration::from_secs(1)).await;
            if this.update(cx, |this, cx| this.settle(cx)).is_err() {
                return;
            }
        });
        Self {
            id,
            kind,
            launch,
            claude_id: None,
            folder,
            terminal,
            view,
            changes,
            review,
            work,
            planning,
            // A review or a plan opens on its panel; the terminal is a
            // switch away, as in Gannin. Other sessions show both.
            show,
            state: State::Working,
            since: chrono::Local::now(),
            server,
            moving: None,
            last_output: Instant::now(),
            _subscriptions: subscriptions,
            _tick: tick,
        }
    }

    fn set_state(&mut self, state: State, cx: &mut Context<Self>) {
        if self.state != state {
            self.state = state;
            self.since = chrono::Local::now();
            cx.emit(Changed);
            cx.notify();
        }
    }

    fn settle(&mut self, cx: &mut Context<Self>) {
        // A launched session's hooks say where it is.
        if let Some(launch) = &self.launch {
            let state = match launch.state().as_deref() {
                Some("needs-you") => State::NeedsYou,
                Some("idle") => State::YourTurn,
                Some("exited") | Some("stopped") => State::Ended,
                _ => State::Working,
            };
            self.set_state(state, cx);
            return;
        }
        if self.state != State::Working || self.last_output.elapsed() < QUIET {
            return;
        }
        let asking = self.kind == Kind::Claude && asks_on_screen(&self.terminal.read(cx).get_content());
        self.set_state(if asking { State::NeedsYou } else { State::YourTurn }, cx);
    }

    /// The title Claude Code (or the shell) gives the terminal, else what
    /// it runs and where.
    pub fn title(&self, cx: &App) -> String {
        if let Some(launch) = &self.launch {
            return launch.title.clone();
        }
        let terminal = self.terminal.read(cx);
        let title = terminal.breadcrumb_text.trim();
        if !title.is_empty() {
            return title.to_string();
        }
        let folder = self.folder.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let on = self.server.as_ref().map(|s| format!(" on {}", s.name())).unwrap_or_default();
        match self.kind {
            Kind::Claude => format!("Claude Code in {folder}{on}"),
            Kind::Shell => format!("Terminal in {folder}{on}"),
        }
    }

    pub fn folder(&self, cx: &App) -> PathBuf {
        self.terminal.read(cx).working_directory().unwrap_or_else(|| self.folder.clone())
    }

    /// Types a message into claude's terminal, then Return.
    pub fn tell(&mut self, text: &str, cx: &mut Context<Self>) {
        let (terminal, text) = (self.terminal.clone(), text.to_string());
        cx.spawn(async move |_, cx| {
            terminal.update(cx, |t, _| t.paste(&text));
            cx.background_executor().timer(std::time::Duration::from_millis(150)).await;
            terminal.update(cx, |t, _| t.input(b"\r".to_vec()));
        })
        .detach();
    }

    /// Stops claude mid-turn, as Esc in its terminal does. Claude Code
    /// turns on the kitty keyboard protocol, so Esc goes as `CSI 27 u`.
    /// Claude Code's Stop hook doesn't run on an interrupt, so a launched
    /// session's state file is set to idle here, as that hook would; the
    /// next prompt's hook sets it working again.
    pub fn interrupt(&mut self, cx: &mut Context<Self>) {
        self.terminal.update(cx, |t, _| t.input(b"\x1b[27u".to_vec()));
        if let Some(launch) = &self.launch {
            let _ = std::fs::write(launch.dir().join("state"), "idle");
        }
    }

    /// The end of the terminal's screen, for Marra reading a plain session.
    pub fn screen_tail(&self, lines: usize, cx: &App) -> String {
        let content = self.terminal.read(cx).get_content();
        let all: Vec<&str> = content.lines().map(str::trim_end).collect();
        let end = all.iter().rposition(|l| !l.is_empty()).map_or(0, |i| i + 1);
        all[end.saturating_sub(lines)..end].join("\n")
    }

    /// The server it runs on, by name; None on this Mac.
    pub fn server_name(&self) -> Option<String> {
        self.server.as_ref().or(self.launch.as_ref().and_then(|l| l.server.as_ref())).map(|s| s.name())
    }

    /// A review whose result isn't posted yet: the findings kept and the verdict.
    pub fn review_ready(&self, cx: &App) -> Option<(usize, Option<String>)> {
        let review = self.review.as_ref()?.read(cx);
        let (result, posted, kept) = review.closing();
        (result && !posted).then(|| (kept, review.verdict()))
    }

    /// A Work on This session's panel.
    pub fn work(&self) -> Option<Entity<crate::work_panel::WorkPanel>> {
        self.work.clone()
    }

    /// A review session's panel.
    pub fn review(&self) -> Option<Entity<crate::review_panel::ReviewPanel>> {
        self.review.clone()
    }

    /// Called as its tab shows or hides: the diff is read only while seen.
    pub fn set_visible(&mut self, visible: bool, cx: &mut Context<Self>) {
        let show_changes = visible && self.show != Show::Terminal;
        self.changes.update(cx, |changes, _| changes.set_visible(show_changes));
    }

    fn switch(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let option = |id: &'static str, label: &'static str, value: Show, cx: &mut Context<Self>| {
            let on = self.show == value;
            div()
                .id(id)
                .px_2()
                .py_0p5()
                .rounded_md()
                .text_xs()
                .cursor_pointer()
                .text_color(if on { theme.fg } else { theme.secondary })
                .when(on, |d| d.bg(theme.row_selected))
                .hover(|s| s.bg(theme.row_selected))
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.show = value;
                    this.set_visible(true, cx);
                    cx.notify();
                }))
                .child(label)
        };
        div()
            .flex()
            .flex_row()
            .gap_0p5()
            .child(option("show-terminal", "Terminal", Show::Terminal, cx))
            .child(option("show-both", "Side by Side", Show::Both, cx))
            .child(option(
                "show-changes",
                if self.review.is_some() {
                    "Review"
                } else if self.planning.is_some() {
                    "Plan"
                } else {
                    "Changes"
                },
                Show::Changes,
                cx,
            ))
    }
}

/// Claude Code's permission prompts and questions end in a numbered choice
/// with the pointer on one, as Gannin's screen check looks for.
fn asks_on_screen(screen: &str) -> bool {
    let tail: Vec<&str> = screen.lines().rev().filter(|l| !l.trim().is_empty()).take(20).collect();
    tail.iter().any(|l| l.contains("Do you want to") || l.contains("Would you like to"))
        || tail.iter().any(|l| l.trim_start().starts_with("❯ 1."))
}

impl Focusable for SessionPage {
    /// The terminal's, but a review's own panel for a review: its terminal
    /// is often hidden, and focus on something not drawn would leave the
    /// window's shortcuts nowhere to go.
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        match &self.review {
            Some(review) => review.read(cx).focus.clone(),
            None => self.view.focus_handle(cx),
        }
    }
}

impl SessionPage {
    /// Covers the page while it moves to a server: a spinner, where it's
    /// going and the step it's on. It takes every click, so the terminal and
    /// the panel's buttons can't be used until it's done.
    fn moving_cover(title: String, step: String, theme: &Theme) -> impl IntoElement {
        use gpui::{Animation, AnimationExt, Transformation};
        div()
            .id("session-moving")
            .absolute()
            .inset_0()
            .occlude()
            .bg(theme.bg)
            .flex()
            .flex_col()
            .items_center()
            .justify_center()
            .gap_3()
            .child(
                gpui::svg()
                    .path("icons/arrow_circle.svg")
                    .size(px(28.))
                    .flex_none()
                    .text_color(theme.secondary)
                    .with_animation("session-moving-spinner", Animation::new(Duration::from_millis(1200)).repeat(), |svg, delta| svg.with_transformation(Transformation::rotate(gpui::percentage(delta)))),
            )
            .child(div().text_lg().font_weight(gpui::FontWeight::MEDIUM).child(title))
            .child(div().max_w(px(520.)).text_sm().text_color(theme.secondary).text_center().child(step))
            .child(div().text_xs().text_color(theme.tertiary).child("The session can't be used until it's moved."))
    }
}

impl Render for SessionPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let title: SharedString = self.title(cx).into();
        let state = self.state;
        let tint = match state {
            State::NeedsYou => gpui::rgb(0xFF9F0A).into(),
            State::YourTurn => theme.selected,
            State::Working => gpui::green(),
            State::Ended => theme.tertiary,
        };
        let header = div()
            .h(px(34.))
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .gap_3()
            .px_3()
            .border_b_1()
            .border_color(theme.border)
            .child(div().size(px(8.)).rounded_full().bg(tint))
            .child(div().font_weight(gpui::FontWeight::MEDIUM).truncate().child(title))
            .child(div().text_xs().text_color(theme.secondary).child(state.label()))
            .when_some(self.launch.as_ref(), |d, launch| {
                // What kind of session it is, and any PRs it has opened.
                d.child(div().px_1p5().rounded_sm().text_xs().bg(theme.tile).text_color(theme.secondary).child(launch.flow.label()))
                    .children(launch.pull_requests().into_iter().enumerate().map(|(i, url)| {
                        let label = url.rsplit_once("/pull/").map(|(repo, n)| format!("{}#{n}", repo.rsplit('/').next().unwrap_or(""))).unwrap_or_else(|| url.clone());
                        div()
                            .id(("session-pr", i))
                            .text_xs()
                            .text_color(theme.selected)
                            .cursor_pointer()
                            .on_click(move |_, _, cx| cx.open_url(&url))
                            .child(label)
                    }))
            })
            .child(div().flex_1())
            // A review lays out its own conversation pane, so has no switch.
            .when(self.review.is_none() && self.server.is_none(), |d| d.child(self.switch(&theme, cx)));
        let terminal = div().flex_1().min_w_0().h_full().child(self.view.clone());
        let changes = div().flex_1().min_w_0().h_full().map(|d| match (&self.review, &self.planning) {
            (Some(review), _) => d.child(review.clone()),
            (_, Some(planning)) => d.child(planning.clone()),
            _ => d.child(self.changes.clone()),
        });
        div()
            .relative()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .when_some(self.moving.clone(), |d, (title, step)| d.child(Self::moving_cover(title, step, &theme)))
            // A review's own header says all this, in one row.
            .when(self.review.is_none() && self.work.is_none(), |d| d.child(header))
            .child(div().flex_1().min_h_0().flex().flex_row().map(|d| match self.show {
                _ if self.review.is_some() => d.child(changes),
                _ if self.work.is_some() => d.children(self.work.clone()),
                Show::Terminal => d.child(terminal),
                Show::Changes => d.child(changes),
                Show::Both => d.child(terminal).child(div().w(px(1.)).h_full().bg(theme.border)).child(changes),
            }))
    }
}
