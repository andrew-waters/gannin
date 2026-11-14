//! A Work on This session, laid out as Gannin's session tab: the terminal
//! (always showing) with a message bar under it, and a side panel on the
//! right switching between the issue, the changes, the pull requests and
//! the activity. Claude's permission prompts and questions float over the
//! bottom of the terminal as a card; Resume floats over it once claude has
//! exited.
//!
//! It draws from `WorkData`, which a live session fills from its worktrees,
//! its PRs and claude's transcript, and the Work Preview fills with made-up
//! data in each state. Nothing here writes anywhere yet: the preview's
//! buttons only change what shows.

use crate::charts::Theme;
use crate::markdown::markdown;
use gpui::{div, prelude::*, px, AnyView, ClickEvent, Context, Entity, FontWeight, Hsla, KeyDownEvent, SharedString, Window};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum WorkState {
    Starting,
    Working,
    NeedsYou,
    YourTurn,
    Exited,
    Stopped,
}

impl WorkState {
    pub fn label(self) -> &'static str {
        match self {
            WorkState::Starting => "Starting",
            WorkState::Working => "Working",
            WorkState::NeedsYou => "Needs you",
            WorkState::YourTurn => "Your turn",
            WorkState::Exited => "Claude exited",
            WorkState::Stopped => "Stopped",
        }
    }

    fn running(self) -> bool {
        !matches!(self, WorkState::Exited | WorkState::Stopped)
    }

    pub fn tint(self, theme: &Theme) -> Hsla {
        match self {
            WorkState::Starting | WorkState::Working => theme.blue(),
            WorkState::NeedsYou => gpui::rgb(0xFF9F0A).into(),
            WorkState::YourTurn => theme.good(),
            WorkState::Exited | WorkState::Stopped => theme.secondary.opacity(0.5),
        }
    }
}

#[derive(Clone, Debug)]
pub struct ChangedFile {
    /// A, M or D.
    pub status: char,
    pub path: String,
    pub additions: i64,
    pub deletions: i64,
    pub staged: bool,
    /// Its diff, as unified diff lines.
    pub diff: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct Worktree {
    pub name: String,
    /// Commits not pushed; None when it's never been pushed.
    pub unpushed: Option<usize>,
    pub base: String,
    pub files: Vec<ChangedFile>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PrState {
    Open,
    Draft,
    Merged,
    Closed,
}

#[derive(Clone, Debug)]
pub struct Feedback {
    pub author: String,
    pub location: Option<String>,
    pub verdict: Option<String>,
    pub body: String,
    pub sent: bool,
}

#[derive(Clone, Debug)]
pub struct WorkPr {
    pub repo: String,
    pub number: i64,
    pub title: String,
    pub state: PrState,
    /// APPROVED, CHANGES_REQUESTED or REVIEW_REQUIRED.
    pub review: Option<String>,
    pub conflicts: bool,
    pub failed: Vec<String>,
    pub pending: Vec<String>,
    pub passed: usize,
    pub failures_sent: bool,
    pub feedback: Vec<Feedback>,
}

/// What claude is asking, over the terminal.
#[derive(Clone, Debug)]
pub enum Ask {
    /// A permission prompt: the tool, what it'd do, and the terminal's
    /// middle choices.
    Permission { tool: String, text: String, choices: Vec<String> },
    /// Questions, each with its options (label, description, recommended).
    Questions(Vec<Question>),
}

#[derive(Clone, Debug)]
pub struct Question {
    pub header: String,
    pub question: String,
    pub multi: bool,
    pub options: Vec<(String, String, bool)>,
}

#[derive(Clone, Debug)]
pub struct WorkData {
    pub reference: String,
    pub title: String,
    pub issue_url: String,
    pub issue_body: String,
    pub state: WorkState,
    pub branch: String,
    pub folder: String,
    pub worktrees: Vec<Worktree>,
    pub prs: Vec<WorkPr>,
    pub ask: Option<Ask>,
    pub activity: Vec<(String, String)>,
    pub model: String,
    pub cost: f64,
    pub context: f32,
    pub last_check: Option<bool>,
    /// Days since anything happened, for Stale.
    pub idle_days: i64,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Pane {
    Issue,
    Changes,
    Prs,
    Activity,
}

pub struct WorkPanel {
    data: WorkData,
    terminal: Option<AnyView>,
    pane: Pane,
    panel_open: bool,
    /// Branch (everything since the default branch) or Uncommitted.
    uncommitted: bool,
    file: Option<String>,
    composer: Entity<editor::Editor>,
    /// The question card, put away to answer in the terminal.
    ask_away: bool,
    /// Options picked per question.
    picked: Vec<Vec<usize>>,
    /// Feedback ticked to send, by PR and index.
    ticked: Vec<(i64, usize)>,
    auto_feedback: bool,
}

impl WorkPanel {
    pub fn new(data: WorkData, terminal: Option<AnyView>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let composer = cx.new(|cx| {
            let mut editor = editor::Editor::auto_height(1, 5, window, cx);
            editor.set_placeholder_text("Tell claude something", window, cx);
            editor
        });
        let file = data.worktrees.iter().flat_map(|w| w.files.first()).next().map(|f| f.path.clone());
        let picked = match &data.ask {
            Some(Ask::Questions(qs)) => vec![Vec::new(); qs.len()],
            _ => Vec::new(),
        };
        Self { data, terminal, pane: Pane::Issue, panel_open: true, uncommitted: false, file, composer, ask_away: false, picked, ticked: Vec::new(), auto_feedback: true }
    }

    /// Shows a pane (the preview picks the one a state is about).
    pub fn show_pane(&mut self, pane: &str) {
        self.pane = match pane {
            "changes" => Pane::Changes,
            "prs" => Pane::Prs,
            "activity" => Pane::Activity,
            _ => Pane::Issue,
        };
    }

    fn button(id: impl Into<SharedString>, label: impl Into<SharedString>, prominent: bool, enabled: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(gpui::ElementId::Name(id.into()))
            .flex_none()
            .px_2()
            .py_0p5()
            .rounded_md()
            .text_sm()
            .map(|d| if prominent { d.bg(theme.selected).text_color(theme.on_selected) } else { d.border_1().border_color(theme.border) })
            .when(enabled, |d| d.cursor_pointer().hover(|s| s.opacity(0.85)))
            .when(!enabled, |d| d.opacity(0.4))
            .child(label.into())
    }

    fn dot(color: Hsla, size: f32) -> gpui::Div {
        div().flex_none().size(px(size)).rounded_full().bg(color)
    }

    fn section(title: &str, theme: &Theme) -> gpui::Div {
        div().flex().flex_col().gap_1p5().child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(title.to_uppercase()))
    }

    fn fact(label: &str, value: impl IntoElement, theme: &Theme) -> gpui::Div {
        div().flex().flex_row().gap_3().text_sm().child(div().w(px(90.)).flex_none().text_color(theme.secondary).child(label.to_string())).child(div().flex_1().min_w_0().child(value))
    }

    fn file_count(&self) -> usize {
        self.data.worktrees.iter().map(|w| w.files.len()).sum()
    }

    fn failed_count(&self) -> usize {
        self.data.prs.iter().filter(|p| p.state == PrState::Open).map(|p| p.failed.len()).sum()
    }

    // MARK: Terminal column

    fn terminal_column(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let state = self.data.state;
        let terminal = match &self.terminal {
            Some(view) => div().size_full().child(view.clone()).into_any_element(),
            None => div()
                .size_full()
                .p_3()
                .font_family("SF Mono")
                .text_xs()
                .text_color(theme.secondary)
                .flex()
                .flex_col()
                .gap_1()
                .children(self.mock_terminal_lines().into_iter().map(|l| div().child(l)))
                .into_any_element(),
        };
        div()
            .flex_1()
            .min_w(px(480.))
            .h_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .relative()
                    .flex_1()
                    .min_h_0()
                    .child(terminal)
                    .when(!state.running(), |d| {
                        d.child(div().absolute().top(px(12.)).right(px(12.)).child(Self::button("work-resume", "Resume", true, true, theme)))
                    })
                    .when_some(self.data.ask.clone().filter(|_| state == WorkState::NeedsYou), |d, ask| {
                        if self.ask_away {
                            d.child(
                                div().absolute().bottom(px(12.)).right(px(12.)).child(
                                    div()
                                        .id("ask-back")
                                        .px_3()
                                        .py_1()
                                        .rounded_md()
                                        .bg(gpui::rgb(0xFF9F0A))
                                        .text_color(gpui::white())
                                        .cursor_pointer()
                                        .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                            this.ask_away = false;
                                            cx.notify();
                                        }))
                                        .child("Claude is asking"),
                                ),
                            )
                        } else {
                            d.child(div().absolute().bottom(px(12.)).left(px(12.)).right(px(12.)).flex().justify_center().child(self.ask_card(&ask, theme, cx)))
                        }
                    }),
            )
            .child(self.composer_bar(theme, cx))
    }

    fn mock_terminal_lines(&self) -> Vec<String> {
        match self.data.state {
            WorkState::Starting => vec!["Cloning acme/api into projects/api".into(), "Making the worktree issue-412-retry-webhooks".into(), "Starting claude".into()],
            WorkState::Exited | WorkState::Stopped => vec!["> The PR is open and its checks pass.".into(), "".into(), "Claude Code has exited. This shell is in the harness; run claude --resume to go on.".into()],
            _ => vec![
                "> Work on acme/api#412: Retry failed webhooks with backoff".into(),
                "".into(),
                "⏺ Reading the issue and the webhook sender.".into(),
                "⏺ Read(src/webhooks/sender.rs)".into(),
                "⏺ Update(src/webhooks/sender.rs)".into(),
                "  ⎿  Added 38 lines, removed 6 lines".into(),
                "⏺ Bash(cargo test webhooks)".into(),
                "  ⎿  test result: ok. 14 passed".into(),
                "".into(),
                "(Claude's terminal shows here in a real session.)".into(),
            ],
        }
    }

    fn composer_bar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let state = self.data.state;
        let running = state.running();
        let gauge_tint = if self.data.context > 0.85 {
            theme.critical()
        } else if self.data.context > 0.7 {
            theme.orange()
        } else {
            theme.secondary
        };
        div()
            .flex_none()
            .flex()
            .flex_row()
            .items_end()
            .gap_2()
            .px(px(10.))
            .py(px(7.))
            .border_t_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .border_1()
                    .border_color(theme.border)
                    .bg(theme.bg)
                    .when(!running, |d| d.opacity(0.5))
                    .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                        if event.keystroke.key == "enter" && !event.keystroke.modifiers.shift {
                            cx.stop_propagation();
                            this.composer.update(cx, |e, cx| e.set_text("", window, cx));
                        }
                    }))
                    .child(self.composer.clone()),
            )
            .child(Self::button("work-send", "Send", false, running, theme))
            .child(Self::button("work-stop", "Stop", false, state == WorkState::Working, theme))
            .when_some(self.data.last_check, |d, passed| {
                d.child(div().flex_none().text_xs().text_color(if passed { theme.good() } else { theme.critical() }).child(if passed { "Passed" } else { "Failed" }))
            })
            .child(div().flex_none().text_xs().text_color(gauge_tint).child(format!("{}%", (self.data.context * 100.).round())))
            .child(Self::button("work-panel-toggle", if self.panel_open { "Hide Panel" } else { "Show Panel" }, false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.panel_open = !this.panel_open;
                cx.notify();
            })))
    }

    fn ask_card(&self, ask: &Ask, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let orange: Hsla = gpui::rgb(0xFF9F0A).into();
        let card = div()
            .w_full()
            .max_w(px(820.))
            .p_4()
            .flex()
            .flex_col()
            .gap_3()
            .rounded(px(12.))
            .bg(theme.popover)
            .border(px(1.5))
            .border_color(orange)
            .shadow_lg();
        let away = div()
            .id("ask-away")
            .px_1p5()
            .rounded_md()
            .cursor_pointer()
            .text_color(theme.secondary)
            .hover(|s| s.bg(theme.row_selected))
            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.ask_away = true;
                cx.notify();
            }))
            .child("Answer in Terminal");
        match ask {
            Ask::Permission { tool, text, choices } => {
                let title = match tool.as_str() {
                    "Bash" => "Claude wants to run a command".to_string(),
                    "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => "Claude wants to change a file".to_string(),
                    "WebFetch" | "WebSearch" => "Claude wants to go online".to_string(),
                    "ExitPlanMode" => "Claude wants to leave planning and start making changes".to_string(),
                    "" => "Claude needs your permission".to_string(),
                    other => format!("Claude wants to use {other}"),
                };
                card.child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(Self::dot(orange, 10.))
                        .child(div().flex_1().text_lg().font_weight(FontWeight::SEMIBOLD).child(title))
                        .child(away),
                )
                .child(div().p_2().rounded_md().bg(theme.bg).font_family("SF Mono").text_sm().child(text.clone()))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .justify_end()
                        .gap_2()
                        .child(Self::button("perm-unattended", "Allow and Stop Asking", false, true, theme))
                        .child(Self::button("perm-deny", "Deny", false, true, theme))
                        .children(choices.iter().enumerate().map(|(i, c)| Self::button(format!("perm-choice-{i}"), c.clone(), false, true, theme)))
                        .child(Self::button("perm-allow", "Allow", true, true, theme)),
                )
            }
            Ask::Questions(questions) => {
                let answered = self.picked.iter().filter(|p| !p.is_empty()).count();
                let title = if questions.len() == 1 { "Claude is asking".to_string() } else { format!("Claude has {} questions", questions.len()) };
                card.child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(Self::dot(orange, 10.))
                        .child(div().flex_1().text_lg().font_weight(FontWeight::SEMIBOLD).child(title))
                        .child(away),
                )
                .children(questions.iter().enumerate().map(|(qi, q)| {
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap_2()
                                .child(div().px_1p5().rounded_full().text_xs().bg(orange.opacity(0.2)).child(q.header.clone()))
                                .child(div().font_weight(FontWeight::SEMIBOLD).child(q.question.clone()))
                                .when(q.multi, |d| d.child(div().text_xs().text_color(theme.secondary).child("Pick any"))),
                        )
                        .child(div().flex().flex_row().flex_wrap().gap_2().children(q.options.iter().enumerate().map(|(oi, (label, desc, recommended))| {
                            let on = self.picked.get(qi).is_some_and(|p| p.contains(&oi));
                            let multi = q.multi;
                            div()
                                .id(SharedString::from(format!("opt-{qi}-{oi}")))
                                .w(px(240.))
                                .p_2()
                                .rounded_lg()
                                .cursor_pointer()
                                .bg(if on { theme.selected.opacity(0.15) } else { theme.tile })
                                .border_1()
                                .border_color(if on { theme.selected } else { theme.border })
                                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                    if let Some(p) = this.picked.get_mut(qi) {
                                        if multi {
                                            if let Some(at) = p.iter().position(|&o| o == oi) {
                                                p.remove(at);
                                            } else {
                                                p.push(oi);
                                            }
                                        } else {
                                            *p = vec![oi];
                                        }
                                    }
                                    cx.notify();
                                }))
                                .child(
                                    div()
                                        .flex()
                                        .flex_row()
                                        .items_center()
                                        .gap_1p5()
                                        .child(div().text_color(if on { theme.selected } else { theme.secondary }).child(if on { "◉" } else { "○" }))
                                        .child(div().font_weight(FontWeight::SEMIBOLD).child(label.clone()))
                                        .when(*recommended, |d| d.child(div().text_xs().text_color(theme.selected).child("Recommended"))),
                                )
                                .child(div().text_sm().text_color(theme.secondary).child(desc.clone()))
                        })))
                }))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(div().flex_1().text_sm().text_color(theme.secondary).child(if answered == questions.len() {
                            "Ready to send.".to_string()
                        } else {
                            format!("{answered} of {} answered. Any left go as \"your call\".", questions.len())
                        }))
                        .child(Self::button("q-dismiss", "Dismiss", false, true, theme))
                        .child(Self::button("q-send", "Send Answers", true, true, theme)),
                )
            }
        }
    }

    // MARK: Side panel

    fn side_panel(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let files = self.file_count();
        let prs = self.data.prs.len();
        let failed = self.failed_count();
        let tab = |id: &'static str, label: String, pane: Pane, cx: &mut Context<Self>| {
            let on = self.pane == pane;
            div()
                .id(id)
                .flex_1()
                .py_0p5()
                .flex()
                .justify_center()
                .rounded_md()
                .text_sm()
                .cursor_pointer()
                .text_color(if on { theme.fg } else { theme.secondary })
                .when(on, |d| d.bg(theme.bg))
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.pane = pane;
                    cx.notify();
                }))
                .child(label)
        };
        let body = match self.pane {
            Pane::Issue => self.issue_pane(theme).into_any_element(),
            Pane::Changes => self.changes_pane(theme, cx).into_any_element(),
            Pane::Prs => self.prs_pane(theme, cx).into_any_element(),
            Pane::Activity => self.activity_pane(theme).into_any_element(),
        };
        div()
            .w(px(440.))
            .flex_none()
            .h_full()
            .flex()
            .flex_col()
            .border_l_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .child(
                div()
                    .flex_none()
                    .p_2()
                    .child(
                        div()
                            .p_0p5()
                            .flex()
                            .flex_row()
                            .gap_0p5()
                            .rounded_md()
                            .bg(theme.grid)
                            .child(tab("pane-issue", "Issue".into(), Pane::Issue, cx))
                            .child(tab("pane-changes", if files > 0 { format!("Changes {files}") } else { "Changes".into() }, Pane::Changes, cx))
                            .child(tab(
                                "pane-prs",
                                match (prs, failed) {
                                    (0, _) => "PRs".into(),
                                    (n, 0) => format!("PRs {n}"),
                                    (n, f) => format!("PRs {n} ✕{f}"),
                                },
                                Pane::Prs,
                                cx,
                            ))
                            .child(tab("pane-activity", "Activity".into(), Pane::Activity, cx)),
                    ),
            )
            .child(div().id("work-pane").flex_1().min_h_0().overflow_y_scroll().child(body))
    }

    fn issue_pane(&self, theme: &Theme) -> impl IntoElement {
        let d = &self.data;
        let state = d.state;
        let all_merged = !d.prs.is_empty() && d.prs.iter().all(|p| p.state == PrState::Merged);
        let stale = !state.running() && d.idle_days > 3;
        div()
            .flex()
            .flex_col()
            .gap_5()
            .p_4()
            .when(all_merged || stale, |el| {
                el.child(
                    div()
                        .p_3()
                        .rounded_lg()
                        .bg(if all_merged { theme.good().opacity(0.1) } else { theme.tile })
                        .flex()
                        .flex_col()
                        .gap_2()
                        .child(div().font_weight(FontWeight::SEMIBOLD).child(if all_merged { "Done" } else { "Stale" }))
                        .child(div().text_sm().child(if all_merged {
                            "Every pull request from this session is merged, so its worktrees can go."
                        } else {
                            "Nothing's happened in this session for over three days. Finish it to remove its worktrees, or leave it be."
                        }))
                        .child(div().flex().flex_row().child(Self::button("work-finish", "Finish and Remove Worktrees", all_merged, true, theme))),
                )
            })
            .child(
                Self::section("Issue", theme)
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(d.title.clone()))
                    .child(div().text_sm().text_color(theme.selected).child(d.reference.clone()))
                    .child(markdown("work-issue-body", &d.issue_body, theme)),
            )
            .child(
                Self::section("Claude Code", theme)
                    .child(Self::fact("State", div().flex().flex_row().items_center().gap_1p5().child(Self::dot(state.tint(theme), 8.)).child(state.label()), theme))
                    .child(Self::fact("Branch", div().font_family("SF Mono").text_xs().truncate().child(d.branch.clone()), theme))
                    .child(Self::fact("Worktree", div().text_xs().truncate().child(d.folder.clone()), theme))
                    .when(!d.prs.is_empty(), |el| {
                        el.child(Self::fact(
                            "Pull request",
                            div().flex().flex_col().children(d.prs.iter().map(|p| div().text_color(theme.selected).child(format!("{}#{}", p.repo.rsplit('/').next().unwrap_or(&p.repo), p.number)))),
                            theme,
                        ))
                    })
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .gap_2()
                            .pt_1()
                            .child(Self::button("work-finder", "Show in Finder", false, true, theme))
                            .child(Self::button("work-stop-resume", if state.running() { "Stop Claude" } else { "Resume" }, false, true, theme))
                            .child(Self::button("work-forget", "Forget", false, true, theme)),
                    )
                    .child(div().text_xs().text_color(theme.secondary).child(if state.running() {
                        "Stop Claude ends it and keeps the worktree, to resume later. Forget ends claude and takes the session out of Gannin; its files stay."
                    } else {
                        "Resume starts claude again where the conversation left off. Forget takes the session out of Gannin; its files stay."
                    })),
            )
    }

    fn changes_pane(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let d = &self.data;
        if d.worktrees.is_empty() {
            return div()
                .p_6()
                .flex()
                .flex_col()
                .items_center()
                .gap_2()
                .child(div().font_weight(FontWeight::MEDIUM).child("No worktrees yet"))
                .child(div().text_sm().text_center().text_color(theme.secondary).child("Claude adds a worktree for each repo the issue touches, and what it changes shows here as it works."))
                .into_any_element();
        }
        let uncommitted = self.uncommitted;
        let mode = |id: &'static str, label: &'static str, value: bool, cx: &mut Context<Self>| {
            let on = uncommitted == value;
            div()
                .id(id)
                .px_2()
                .py_0p5()
                .rounded_md()
                .text_xs()
                .cursor_pointer()
                .text_color(if on { theme.fg } else { theme.secondary })
                .when(on, |d| d.bg(theme.bg))
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.uncommitted = value;
                    cx.notify();
                }))
                .child(label)
        };
        let selected = self.file.clone();
        let diff = d.worktrees.iter().flat_map(|w| w.files.iter()).find(|f| Some(&f.path) == selected.as_ref()).cloned();
        div()
            .flex()
            .flex_col()
            .child(
                div()
                    .px_3()
                    .pt_2()
                    .child(div().p_0p5().flex().flex_row().gap_0p5().rounded_md().bg(theme.grid).child(mode("mode-branch", "Branch", false, cx)).child(mode("mode-uncommitted", "Uncommitted", true, cx))),
            )
            .children(d.worktrees.iter().map(|w| {
                let files: Vec<&ChangedFile> = w.files.iter().filter(|f| !uncommitted || f.staged || f.status != ' ').collect();
                let pushed = match w.unpushed {
                    Some(0) => ("Pushed".to_string(), theme.secondary),
                    Some(n) => (format!("{n} not pushed"), theme.orange()),
                    None => ("Not pushed yet".to_string(), theme.orange()),
                };
                div()
                    .flex()
                    .flex_col()
                    .px_2()
                    .pt_3()
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .px_1()
                            .pb_1()
                            .child(div().flex_1().text_sm().font_weight(FontWeight::SEMIBOLD).child(w.name.clone()))
                            .child(div().text_xs().text_color(pushed.1).child(pushed.0))
                            .when(!uncommitted, |d| d.child(div().text_xs().text_color(theme.tertiary).child(format!("against {}", w.base))))
                            .when(uncommitted && w.files.iter().any(|f| f.staged), |d| d.child(Self::button(format!("commit-{}", w.name), "Commit", false, true, theme)))
                            .when(uncommitted && w.unpushed != Some(0), |d| d.child(Self::button(format!("push-{}", w.name), "Push", false, true, theme))),
                    )
                    .when(files.is_empty(), |d| d.child(div().px_1().text_sm().text_color(theme.secondary).child("No changes")))
                    .children(files.into_iter().map(|f| {
                        let on = selected.as_ref() == Some(&f.path);
                        let path = f.path.clone();
                        let (name, folder) = f.path.rsplit_once('/').map(|(a, b)| (b.to_string(), a.to_string())).unwrap_or((f.path.clone(), String::new()));
                        let tint = match f.status {
                            'A' => theme.good(),
                            'D' => theme.critical(),
                            _ => theme.orange(),
                        };
                        div()
                            .id(SharedString::from(format!("file-{}", f.path)))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .px_1()
                            .py_0p5()
                            .rounded_md()
                            .text_sm()
                            .cursor_pointer()
                            .when(on, |d| d.bg(theme.row_selected))
                            .hover(|s| s.bg(theme.row_selected.opacity(0.5)))
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.file = Some(path.clone());
                                cx.notify();
                            }))
                            .child(div().w(px(12.)).flex_none().font_family("SF Mono").text_xs().font_weight(FontWeight::SEMIBOLD).text_color(tint).child(f.status.to_string()))
                            .child(div().flex_none().child(name))
                            .child(div().flex_1().min_w_0().truncate().text_xs().text_color(theme.secondary).child(folder))
                            .when(uncommitted && f.staged, |d| d.child(div().text_xs().text_color(theme.good()).child("staged")))
                            .child(div().flex_none().text_xs().text_color(theme.good()).child(format!("+{}", f.additions)))
                            .child(div().flex_none().text_xs().text_color(theme.critical()).child(format!("-{}", f.deletions)))
                    }))
            }))
            .when_some(diff, |el, f| {
                el.child(
                    div()
                        .mt_3()
                        .border_t_1()
                        .border_color(theme.border)
                        .child(div().px_3().py_1p5().font_family("SF Mono").text_xs().border_b_1().border_color(theme.border).child(f.path.clone()))
                        .children(f.diff.iter().map(|line| {
                            let (bg, fg) = match line.chars().next() {
                                Some('+') => (theme.good().opacity(0.14), theme.fg),
                                Some('-') => (theme.critical().opacity(0.14), theme.fg),
                                Some('@') => (theme.tile, theme.secondary),
                                _ => (gpui::transparent_black(), theme.fg),
                            };
                            div().px_3().bg(bg).text_color(fg).font_family("SF Mono").text_xs().child(line.clone())
                        })),
                )
            })
            .into_any_element()
    }

    fn prs_pane(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let d = &self.data;
        if d.prs.is_empty() {
            return div()
                .p_6()
                .flex()
                .flex_col()
                .items_center()
                .gap_2()
                .child(div().font_weight(FontWeight::MEDIUM).child("No pull requests yet"))
                .child(div().text_sm().text_center().text_color(theme.secondary).child(format!(
                    "When claude opens one, or one is opened from {}, it shows here with its checks and review.",
                    d.branch
                )))
                .into_any_element();
        }
        let running = d.state.running();
        let auto = self.auto_feedback;
        div()
            .flex()
            .flex_col()
            .gap_4()
            .p_4()
            .child(
                div()
                    .id("auto-feedback")
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .text_sm()
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.auto_feedback = !auto;
                        cx.notify();
                    }))
                    .child(div().size(px(14.)).rounded(px(3.)).border_1().border_color(if auto { theme.selected } else { theme.secondary }).when(auto, |d| d.bg(theme.selected)).flex().items_center().justify_center().text_xs().text_color(theme.on_selected).child(if auto { "✓" } else { "" }))
                    .child("Send new feedback to Claude"),
            )
            .children(d.prs.iter().map(|pr| {
                let (state, tint) = match pr.state {
                    PrState::Open => ("Open", theme.good()),
                    PrState::Draft => ("Draft", theme.secondary),
                    PrState::Merged => ("Merged", gpui::rgb(0xA259FF).into()),
                    PrState::Closed => ("Closed", theme.secondary),
                };
                let review = match pr.review.as_deref() {
                    Some("APPROVED") => Some(("Approved", theme.secondary)),
                    Some("CHANGES_REQUESTED") => Some(("Changes requested", theme.orange())),
                    Some(_) => Some(("Review required", theme.secondary)),
                    None => None,
                };
                let checks = if pr.failed.is_empty() && pr.pending.is_empty() && pr.passed == 0 {
                    "None ran".to_string()
                } else {
                    let mut parts = Vec::new();
                    if !pr.failed.is_empty() {
                        parts.push(format!("{} failed", pr.failed.len()));
                    }
                    if !pr.pending.is_empty() {
                        parts.push(format!("{} running", pr.pending.len()));
                    }
                    if pr.passed > 0 {
                        parts.push(format!("{} passed", pr.passed));
                    }
                    parts.join(", ")
                };
                let open = pr.state == PrState::Open;
                let number = pr.number;
                let ticked: Vec<usize> = self.ticked.iter().filter(|(n, _)| *n == number).map(|(_, i)| *i).collect();
                Self::section(&format!("{}#{}", pr.repo, pr.number), theme)
                    .child(div().font_weight(FontWeight::SEMIBOLD).text_color(theme.selected).child(pr.title.clone()))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_3()
                            .text_sm()
                            .child(div().flex().flex_row().items_center().gap_1().child(Self::dot(tint, 7.)).child(state))
                            .when_some(review, |d, (label, tint)| d.child(div().text_color(tint).child(label)))
                            .when(open && pr.conflicts, |d| d.child(div().text_color(theme.critical()).child("Conflicts"))),
                    )
                    .child(Self::fact("Checks", checks, theme))
                    .children(pr.failed.iter().map(|c| div().text_sm().flex().flex_row().gap_1p5().child(div().text_color(theme.critical()).child("✕")).child(c.clone())))
                    .children(pr.pending.iter().take(5).map(|c| div().text_sm().flex().flex_row().gap_1p5().child(div().text_color(theme.orange()).child("◷")).child(c.clone())))
                    .when(open && !pr.failed.is_empty(), |d| {
                        d.child(
                            div()
                                .flex()
                                .flex_row()
                                .gap_2()
                                .items_center()
                                .when(pr.failures_sent, |d| d.child(div().text_xs().text_color(theme.secondary).child("Sent to Claude")))
                                .child(Self::button(format!("rerun-{number}"), "Re-run Failed Checks", false, true, theme))
                                .child(Self::button(format!("send-failures-{number}"), "Send Failures to Claude", false, running, theme)),
                        )
                    })
                    .when(open && !pr.feedback.is_empty(), |d| {
                        d.child(div().pt_1().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child("FEEDBACK"))
                            .children(pr.feedback.iter().enumerate().map(|(i, f)| {
                                let on = ticked.contains(&i);
                                div()
                                    .id(SharedString::from(format!("fb-{number}-{i}")))
                                    .flex()
                                    .flex_row()
                                    .gap_2()
                                    .p_2()
                                    .rounded_md()
                                    .bg(theme.tile)
                                    .cursor_pointer()
                                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                        if let Some(at) = this.ticked.iter().position(|t| *t == (number, i)) {
                                            this.ticked.remove(at);
                                        } else {
                                            this.ticked.push((number, i));
                                        }
                                        cx.notify();
                                    }))
                                    .child(div().size(px(14.)).flex_none().rounded(px(3.)).border_1().border_color(if on { theme.selected } else { theme.secondary }).when(on, |d| d.bg(theme.selected)).flex().items_center().justify_center().text_xs().text_color(theme.on_selected).child(if on { "✓" } else { "" }))
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w_0()
                                            .flex()
                                            .flex_col()
                                            .gap_0p5()
                                            .child(
                                                div()
                                                    .flex()
                                                    .flex_row()
                                                    .gap_2()
                                                    .text_sm()
                                                    .child(div().font_weight(FontWeight::MEDIUM).child(format!("@{}", f.author)))
                                                    .when_some(f.location.clone(), |d, l| d.child(div().font_family("SF Mono").text_xs().text_color(theme.secondary).child(l)))
                                                    .when_some(f.verdict.clone(), |d, v| d.child(div().text_xs().text_color(theme.orange()).child(v)))
                                                    .when(f.sent, |d| d.child(div().text_xs().text_color(theme.secondary).child("Sent"))),
                                            )
                                            .child(div().text_sm().text_color(if f.sent { theme.secondary } else { theme.fg }).child(f.body.clone())),
                                    )
                            }))
                            .child(div().flex().flex_row().child(Self::button(
                                format!("send-fb-{number}"),
                                if ticked.is_empty() { "Send to Claude".to_string() } else { format!("Send {} to Claude", ticked.len()) },
                                true,
                                running && !ticked.is_empty(),
                                theme,
                            )))
                    })
            }))
            .into_any_element()
    }

    fn activity_pane(&self, theme: &Theme) -> impl IntoElement {
        let d = &self.data;
        div()
            .flex()
            .flex_col()
            .gap_5()
            .p_4()
            .child(
                Self::section("Claude Code", theme)
                    .child(Self::fact("Model", d.model.clone(), theme))
                    .child(Self::fact("Cost", format!("${:.2}", d.cost), theme))
                    .child(Self::fact("Context", format!("{}%", (d.context * 100.).round()), theme))
                    .child(Self::fact("Last check", match d.last_check {
                        Some(true) => "Passed",
                        Some(false) => "Failed",
                        None => "None yet",
                    }, theme)),
            )
            .child(Self::section("Activity", theme).map(|el| {
                if d.activity.is_empty() {
                    el.child(div().text_sm().text_color(theme.secondary).child(if d.state.running() {
                        "Claude's activity shows here as it works."
                    } else {
                        "Start the session to see what claude has been doing."
                    }))
                } else {
                    el.children(d.activity.iter().map(|(at, what)| {
                        div().flex().flex_row().gap_3().text_sm().child(div().w(px(44.)).flex_none().text_color(theme.tertiary).child(at.clone())).child(div().flex_1().child(what.clone()))
                    }))
                }
            }))
    }
}

impl Render for WorkPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        div()
            .size_full()
            .flex()
            .flex_row()
            .bg(theme.bg)
            .child(self.terminal_column(&theme, cx))
            .when(self.panel_open, |d| d.child(self.side_panel(&theme, cx)))
    }
}
