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

/// Starts the process in a pty; the page is made once it's running.
pub fn spawn_terminal(kind: Kind, folder: PathBuf, launch: Option<&crate::launch::Launch>, window: &Window, cx: &mut App) -> Task<anyhow::Result<TerminalBuilder>> {
    use settings::Settings;
    let settings = terminal::terminal_settings::TerminalSettings::get_global(cx).clone();
    // A launch runs its start script in a login shell from home, as
    // Gannin's terminal does.
    let (folder, shell) = match launch {
        Some(launch) => (
            std::env::var_os("HOME").map(PathBuf::from).unwrap_or(folder),
            Some(util::shell::Shell::WithArguments {
                program: std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into()),
                args: vec![
                    "-l".into(),
                    "-i".into(),
                    "-c".into(),
                    format!("bash {}", crate::launch::quote(&launch.dir().join("start.sh").to_string_lossy())),
                ],
                title_override: None,
            }),
        ),
        None => (folder, None),
    };
    let shell = if let Some(shell) = shell { shell } else { match kind {
        Kind::Shell => util::shell::Shell::System,
        // Through a login shell, so claude is on the PATH the user's
        // profile sets up.
        Kind::Claude => util::shell::Shell::WithArguments {
            program: std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into()),
            args: vec!["-l".into(), "-i".into(), "-c".into(), "claude".into()],
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
    pub fn new(
        id: u32,
        kind: Kind,
        folder: PathBuf,
        launch: Option<crate::launch::Launch>,
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
        let show = if review.is_some() || planning.is_some() { Show::Changes } else { Show::Both };
        let mut subscriptions = Vec::new();
        if let Some(work) = &work {
            // Resume, Finish and Forget act on the tab, so the workspace hears of them.
            subscriptions.push(cx.subscribe(work, |_, _, event: &crate::work_panel::WorkEvent, cx| {
                cx.emit(match event {
                    crate::work_panel::WorkEvent::Resume => crate::work_panel::WorkEvent::Resume,
                    crate::work_panel::WorkEvent::Forget => crate::work_panel::WorkEvent::Forget,
                })
            }));
        }
        if let Some(review) = &review {
            // Explain starts a session of its own, so the workspace hears of it.
            subscriptions.push(cx.subscribe(review, |_, _, event: &crate::review_panel::ExplainPr, cx| cx.emit(crate::review_panel::ExplainPr(event.0.clone(), event.1.clone()))));
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
        match self.kind {
            Kind::Claude => format!("Claude Code in {folder}"),
            Kind::Shell => format!("Terminal in {folder}"),
        }
    }

    pub fn folder(&self, cx: &App) -> PathBuf {
        self.terminal.read(cx).working_directory().unwrap_or_else(|| self.folder.clone())
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
            .when(self.review.is_none(), |d| d.child(self.switch(&theme, cx)));
        let terminal = div().flex_1().min_w_0().h_full().child(self.view.clone());
        let changes = div().flex_1().min_w_0().h_full().map(|d| match (&self.review, &self.planning) {
            (Some(review), _) => d.child(review.clone()),
            (_, Some(planning)) => d.child(planning.clone()),
            _ => d.child(self.changes.clone()),
        });
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
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
