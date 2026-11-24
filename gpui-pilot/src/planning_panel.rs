//! A planning session's workspace beside its terminal, after Gannin's
//! `PlanningWorkspaceView`: the stages as a stepper (each approved, to
//! recheck, or open), then what claude keeps in `planning.json` (the
//! outcome, the requirement, the design and what it found in the code,
//! the breakdown and the decisions), and a footer where the room approves
//! the stage, sends claude back to an earlier one, or interjects ("From
//! the room, on <stage>: ..."). At Agree, the Agree view files the issues
//! and writes the plan (`planning_agree.rs`).
//!
//! Approvals are the room's, recorded here (`planning.rs`): claude moving
//! `phase` on approves nothing.

use crate::charts::Theme;
use crate::marra_view::button;
use crate::launch::Launch;
use crate::markdown::markdown;
use crate::planning::{self, Agreed, Approvals, Comment, Stage, State, Status};
use crate::planning_agree::{AgreeEvent, AgreeView};
use gpui::{div, prelude::*, px, relative, ClickEvent, Context, Entity, FontWeight, KeyDownEvent, SharedString, Subscription, Task, Window};
use std::time::Duration;
use terminal::Terminal;

pub struct PlanningPanel {
    launch: Launch,
    /// None in the preview, where messages to claude are only shown.
    terminal: Option<Entity<Terminal>>,
    /// Where approvals, the room's comments and Agree's record are kept.
    dir: std::path::PathBuf,
    /// The made-up plan (`planning_preview`): claude's part is played here.
    preview: bool,
    /// In the preview, the last message claude would have been sent.
    sent: Option<String>,
    state: Option<State>,
    approvals: Approvals,
    agreed: Agreed,
    comment: Entity<editor::Editor>,
    /// What the footer has to say: why a button did nothing.
    notice: Option<String>,
    agree: Option<(Entity<AgreeView>, Subscription)>,
    /// An earlier stage the room is looking back at, on the left.
    viewing: Option<Stage>,
    /// The question waiting for the room, when claude's asked one.
    question: Option<crate::work_panel::Question>,
    _poll: Task<()>,
}

impl PlanningPanel {
    pub fn new(launch: Launch, terminal: Entity<Terminal>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let path = launch.folder().join("planning.json");
        let dir = launch.dir();
        // Re-read every few seconds, off the main thread, with the question
        // claude's waiting on.
        let poll = cx.spawn(async move |this, cx| loop {
            let file = path.clone();
            let session = dir.clone();
            let (state, question) = cx
                .background_executor()
                .spawn(async move {
                    let waiting = std::fs::read_to_string(session.join("state")).is_ok_and(|s| s.trim() == "needs-you");
                    let question = match waiting.then(|| crate::work_live::ask(&session, "")) {
                        Some(crate::work_panel::Ask::Questions(qs)) => qs.into_iter().next(),
                        _ => None,
                    };
                    (State::read(&file), question)
                })
                .await;
            if this
                .update(cx, |this, cx| {
                    let changed_question = this.question.as_ref().map(|q| &q.question) != question.as_ref().map(|q| &q.question);
                    if changed_question {
                        this.question = question;
                    }
                    if state.is_some() && this.state != state {
                        this.state = state;
                        cx.notify();
                    } else if changed_question {
                        cx.notify();
                    }
                })
                .is_err()
            {
                return;
            }
            cx.background_executor().timer(Duration::from_secs(3)).await;
        });
        let comment = cx.new(|cx| {
            let mut editor = editor::Editor::single_line(window, cx);
            editor.set_placeholder_text("Say something from the room", window, cx);
            editor
        });
        let dir = launch.dir();
        Self { approvals: Approvals::load(&dir), agreed: Agreed::load(&dir), dir, preview: false, sent: None, launch, terminal: Some(terminal), state: None, comment, notice: None, agree: None, viewing: None, question: None, _poll: poll }
    }

    /// The made-up plan, from its first stage, with nothing kept from
    /// last time.
    pub fn preview(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let dir = crate::planning_preview::dir();
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::create_dir_all(&dir);
        let comment = cx.new(|cx| {
            let mut editor = editor::Editor::single_line(window, cx);
            editor.set_placeholder_text("Say something from the room", window, cx);
            editor
        });
        Self {
            launch: crate::planning_preview::launch(),
            terminal: None,
            approvals: Approvals::default(),
            agreed: Agreed::default(),
            dir,
            preview: true,
            sent: None,
            state: Some(crate::planning_preview::state(Stage::Outcome, false)),
            comment,
            notice: None,
            agree: None,
            viewing: None,
            question: crate::planning_preview::question(Stage::Outcome),
            _poll: Task::ready(()),
        }
    }

    /// The preview's claude: the stage it's on, answered.
    fn answer(&mut self, cx: &mut Context<Self>) {
        let stage = self.stage();
        self.state = Some(crate::planning_preview::state(stage, true));
        self.question = None;
        self.sent = Some(format!("(Claude asks the room about {} and fills it in.)", stage.title().to_lowercase()));
        cx.notify();
    }

    fn stage(&self) -> Stage {
        self.state.as_ref().map(State::stage).unwrap_or(Stage::Outcome)
    }

    /// Sends claude a message: Esc first when a question is waiting, as
    /// Gannin answers, then the text as one message.
    fn send(&mut self, message: String, window: &mut Window, cx: &mut Context<Self>) {
        let Some(terminal) = self.terminal.clone() else {
            self.sent = Some(message);
            return cx.notify();
        };
        let waiting = self.launch.state().as_deref() == Some("needs-you");
        cx.spawn_in(window, async move |_, cx| {
            if waiting {
                terminal.update(cx, |t, _| t.input(b"\x1b[27u".to_vec()));
                cx.background_executor().timer(Duration::from_millis(400)).await;
            }
            terminal.update(cx, |t, _| t.paste(&message));
            cx.background_executor().timer(Duration::from_millis(150)).await;
            terminal.update(cx, |t, _| t.input(b"\r".to_vec()));
        })
        .detach();
    }

    /// What's in the comment box, cleared; kept for the plan.
    fn take_comment(&mut self, window: &mut Window, cx: &mut Context<Self>) -> String {
        let text = self.comment.read(cx).text(cx).trim().to_string();
        if !text.is_empty() {
            self.comment.update(cx, |editor, cx| editor.set_text("", window, cx));
            planning::add_comment(&self.dir, Comment { stage: self.stage().title().to_lowercase(), text: text.clone(), at: chrono::Utc::now() });
        }
        text
    }

    fn send_comment(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let stage = self.stage().title().to_lowercase();
        let text = self.take_comment(window, cx);
        if text.is_empty() {
            return;
        }
        self.notice = None;
        self.send(format!("From the room, on {stage}: {text}"), window, cx);
        cx.notify();
    }

    /// The room approves the stage it's on; with its criteria unmet only
    /// "anyway", saying why in the box.
    fn approve(&mut self, anyway: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(state) = self.state.clone() else { return };
        let stage = state.stage();
        let Some(next) = stage.next() else { return };
        let unmet = state.unmet(stage);
        if !unmet.is_empty() && !anyway {
            return;
        }
        let reason = if anyway {
            let text = self.comment.read(cx).text(cx).trim().to_string();
            if text.is_empty() {
                self.notice = Some("Say in the box why it's right as it stands, then Approve Anyway.".into());
                return cx.notify();
            }
            Some(self.take_comment(window, cx))
        } else {
            None
        };
        self.approvals.approve(stage, &state, reason.clone(), chrono::Utc::now());
        self.approvals.save(&self.dir);
        self.notice = None;
        let message = match &reason {
            Some(why) => format!(
                "The room approved {} as it stands, though {}: {why}. Record that as a decision, then move on to {}.",
                stage.title().to_lowercase(),
                unmet.iter().map(|u| u.trim_end_matches('.').to_lowercase()).collect::<Vec<_>>().join("; "),
                next.title().to_lowercase()
            ),
            None if next == Stage::Agree => "The room approved the breakdown. Set `phase` to `ready` and `done` to true.".to_string(),
            None => format!("The room approved {}. Move on to {}: set `phase` to `{}`.", stage.title().to_lowercase(), next.title().to_lowercase(), next.key()),
        };
        self.send(message, window, cx);
        // The preview's claude moves on, and begins the next stage.
        if self.preview {
            self.state = Some(crate::planning_preview::state(next, next == Stage::Agree));
            self.question = crate::planning_preview::question(next);
        }
        cx.notify();
    }

    /// Back to an earlier stage, saying why: it and every later one need
    /// approving again.
    fn back(&mut self, to: Stage, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.comment.read(cx).text(cx).trim().to_string();
        if text.is_empty() {
            self.notice = Some(format!("Say in the box why it's going back to {}, then press it again.", to.title()));
            return cx.notify();
        }
        let why = self.take_comment(window, cx);
        self.approvals.reopen(to);
        self.approvals.save(&self.dir);
        if self.preview {
            if let Some(state) = self.state.as_mut() {
                state.phase = to.key().to_string();
            }
        }
        self.notice = None;
        self.send(format!("Back to {}: {why}. Set `phase` to `{}`.", to.title().to_lowercase(), to.key()), window, cx);
        cx.notify();
    }

    fn open_agree(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(state) = self.state.clone() else { return };
        let view = cx.new(|cx| AgreeView::new(self.launch.clone(), self.dir.clone(), self.preview, state, self.approvals.clone(), window, cx));
        let subscription = cx.subscribe_in(&view, window, |this, _, event: &AgreeEvent, window, cx| {
            match event {
                AgreeEvent::Agreed(agreed) => {
                    this.agreed = agreed.clone();
                    let issues: Vec<String> = agreed.made.iter().map(|m| m.reference()).collect();
                    let message = format!(
                        "The room agreed. Gannin filed {} and wrote the plan to {}{}. There's nothing more to write.",
                        if issues.is_empty() { "nothing".to_string() } else { issues.join(", ") },
                        agreed.plan_path,
                        agreed.requirement_path.as_ref().map(|r| format!(" and the requirement to {r}")).unwrap_or_default()
                    );
                    this.send(message, window, cx);
                }
                AgreeEvent::Cancel => {}
            }
            this.agree = None;
            cx.notify();
        });
        self.agree = Some((view, subscription));
        cx.notify();
    }
}

impl Render for PlanningPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let stage = self.stage();
        // Looking back at a stage only while it's an earlier one.
        let shown = self.viewing.filter(|v| v.index() < stage.index()).unwrap_or(stage);
        let quiet = |text: String| div().text_xs().text_color(theme.secondary).child(text);
        let empty = State::default();
        let state = self.state.as_ref().unwrap_or(&empty);

        // The stages; an earlier one opens on the left to look back at.
        let stepper = div().flex().flex_row().flex_wrap().items_center().gap_1().children(Stage::ALL.iter().enumerate().map(|(i, s)| {
            let s = *s;
            let status = if s == Stage::Agree {
                if self.agreed.finished() { Status::Approved } else { Status::Open }
            } else {
                self.approvals.status(s, state)
            };
            let (bg, fg) = if s == stage {
                (theme.selected, theme.on_selected)
            } else if status == Status::Approved {
                (theme.selected.opacity(0.18), theme.selected)
            } else if status == Status::Recheck {
                (theme.orange().opacity(0.18), theme.orange())
            } else {
                (theme.tile, theme.secondary)
            };
            let label = match status {
                Status::Approved => format!("✓ {}", s.title()),
                Status::Recheck => format!("{} · Recheck", s.title()),
                Status::Open => s.title().to_string(),
            };
            let earlier = s.index() < stage.index();
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_1()
                .when(i > 0, |d| d.child(div().text_color(theme.tertiary).child("›")))
                .child(
                    div()
                        .id(SharedString::from(format!("plan-step-{}", s.key())))
                        .px_2()
                        .py_0p5()
                        .rounded_full()
                        .text_xs()
                        .bg(bg)
                        .text_color(fg)
                        .border_1()
                        .border_color(if s == shown && shown != stage { theme.selected } else { gpui::transparent_black() })
                        .when(earlier || s == stage, |d| {
                            d.cursor_pointer().on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.viewing = (s.index() < this.stage().index()).then_some(s);
                                cx.notify();
                            }))
                        })
                        .child(label),
                )
        }));

        if let Some((view, _)) = &self.agree {
            return div()
                .size_full()
                .flex()
                .flex_col()
                .bg(theme.bg)
                .text_color(theme.fg)
                .child(div().flex_none().px_3().py_2().border_b_1().border_color(theme.border).child(stepper))
                .child(div().flex_1().min_h_0().child(view.clone()))
                .into_any_element();
        }

        let body = match &self.state {
            None => div().flex_1().p_4().child(quiet("Claude keeps the plan in planning.json as the room answers; it shows here once it starts.".into())).into_any_element(),
            Some(state) => {
                // Left: the stage in hand, in full, with what's happening now.
                let now: Option<gpui::AnyElement> = if shown != stage {
                    Some(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .p_2()
                            .rounded_md()
                            .bg(theme.tile)
                            .child(div().flex_1().text_xs().text_color(theme.secondary).child(format!("Looking back at {}. The room is on {}.", shown.title(), stage.title())))
                            .child(button("plan-view-current", format!("Back to {}", stage.title()), false, &theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                this.viewing = None;
                                cx.notify();
                            })))
                            .into_any_element(),
                    )
                } else {
                    now_box(self.question.as_ref(), state, self.preview, &theme)
                };
                let left = div()
                    .id("plan-stage")
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .overflow_y_scroll()
                    .p_4()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.selected).child(shown.title().to_uppercase()))
                    .children(now)
                    .child(stage_view(shown, state, &self.approvals, &theme))
                    .children(decisions(state, shown, &theme));
                // Right: what's been settled, compact, so the room keeps it in view.
                let right = div()
                    .id("plan-spec")
                    .w(relative(0.38))
                    .flex_none()
                    .h_full()
                    .overflow_y_scroll()
                    .p_4()
                    .border_l_1()
                    .border_color(theme.border)
                    .bg(theme.sidebar)
                    .child(spec_view(state, shown, &self.approvals, &theme));
                div().flex_1().min_h_0().flex().flex_row().child(left).child(right).into_any_element()
            }
        };

        // The gate for the stage it's on, and the way back.
        let unmet = if self.state.is_some() { state.unmet(stage) } else { Vec::new() };
        let earlier: Vec<Stage> = Stage::ALL.iter().copied().filter(|s| s.index() < stage.index()).collect();
        let gate = if self.agreed.finished() {
            let url = crate::planning_docs::harness_url(&self.launch.harness_repo, &self.agreed.plan_path);
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .child(div().flex_1().text_xs().text_color(theme.secondary).child(format!("Agreed. The plan is {}.", self.agreed.plan_path)))
                .child(button("plan-open-agreed", "Open the Plan", false, &theme).on_click(move |_, _, cx| cx.open_url(&url)))
                .into_any_element()
        } else if self.state.is_none() {
            div().into_any_element()
        } else if stage == Stage::Agree {
            div()
                .flex()
                .flex_row()
                .flex_wrap()
                .items_center()
                .gap_1()
                .child(div().flex_1().text_xs().text_color(theme.secondary).child("The room's agreed the breakdown: check what gets filed, then write it all."))
                .children(earlier.iter().map(|s| {
                    let s = *s;
                    button(SharedString::from(format!("plan-back-{}", s.key())), format!("Back to {}", s.title()), false, &theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.back(s, window, cx)))
                }))
                .child(button("plan-agree", "Agree", true, &theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.open_agree(window, cx))))
                .into_any_element()
        } else {
            let approved = self.approvals.status(stage, state) == Status::Approved;
            div()
                .flex()
                .flex_col()
                .gap_1()
                .children(unmet.iter().map(|u| div().text_xs().text_color(theme.orange()).child(u.clone())))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .flex_wrap()
                        .items_center()
                        .gap_1()
                        .children(earlier.iter().map(|s| {
                            let s = *s;
                            button(SharedString::from(format!("plan-back-{}", s.key())), format!("Back to {}", s.title()), false, &theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.back(s, window, cx)))
                        }))
                        .child(div().flex_1())
                        .when(approved, |d| d.child(div().text_xs().text_color(theme.secondary).child("Approved; waiting for Claude to move on.")))
                        .when(!approved && !unmet.is_empty(), |d| {
                            d.child(button("plan-approve-anyway", "Approve Anyway", false, &theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.approve(true, window, cx))))
                        })
                        .when(!approved, |d| {
                            let label = format!("{} Is Right", stage.title());
                            d.child(if unmet.is_empty() {
                                button("plan-approve", label, true, &theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.approve(false, window, cx))).into_any_element()
                            } else {
                                button("plan-approve", label, false, &theme).opacity(0.4).cursor_default().into_any_element()
                            })
                        }),
                )
                .into_any_element()
        };

        let strip = self.preview.then(|| {
            div()
                .flex_none()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .px_3()
                .py_1p5()
                .bg(theme.tile)
                .border_b_1()
                .border_color(theme.border)
                .child(
                    div()
                        .flex_1()
                        .flex()
                        .flex_col()
                        .text_xs()
                        .child(div().font_weight(FontWeight::SEMIBOLD).child("Preview: a made-up plan. Nothing runs, and nothing is filed or committed."))
                        .child(div().text_color(theme.secondary).child(match &self.sent {
                            Some(sent) => format!("Claude was sent: {sent}"),
                            None => "Press Claude Answers to have the stage filled in, as Claude would after asking the room.".to_string(),
                        })),
                )
                .when(stage != Stage::Agree && !self.agreed.finished(), |d| d.child(button("plan-preview-answer", "Claude Answers", false, &theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.answer(cx)))))
        });
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .text_color(theme.fg)
            .child(div().flex_none().px_3().py_2().border_b_1().border_color(theme.border).child(stepper))
            .children(strip)
            .child(body)
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .px_3()
                    .py_2()
                    .border_t_1()
                    .border_color(theme.border)
                    .child(gate)
                    .when_some(self.notice.clone(), |d, n| d.child(div().text_xs().text_color(theme.critical()).child(n)))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .child(
                                div()
                                    .flex_1()
                                    .px_2()
                                    .py_1()
                                    .rounded_md()
                                    .border_1()
                                    .border_color(theme.border)
                                    .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                                        if event.keystroke.key == "enter" {
                                            cx.stop_propagation();
                                            this.send_comment(window, cx);
                                        }
                                    }))
                                    .child(self.comment.clone()),
                            )
                            .child(button("plan-send", "Send", true, &theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.send_comment(window, cx)))),
                    ),
            )
            .into_any_element()
    }
}

fn heading(text: &str, theme: &Theme) -> gpui::Div {
    div().pt_3().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(text.to_string())
}

fn quiet(text: String, theme: &Theme) -> gpui::Div {
    div().text_xs().text_color(theme.secondary).child(text)
}

fn field(label: &str, text: &str, theme: &Theme) -> Option<gpui::Div> {
    (!text.is_empty()).then(|| div().flex().flex_col().child(heading(label, theme)).child(text.to_string()))
}

fn list(label: &str, items: &[String], theme: &Theme) -> Option<gpui::Div> {
    (!items.is_empty()).then(|| div().flex().flex_col().child(heading(label, theme)).children(items.iter().map(|i| div().child(format!("• {i}")))))
}

fn ided(id: &str, text: &str, tint: gpui::Hsla) -> gpui::Div {
    div().flex().flex_row().gap_2().child(div().w(px(28.)).flex_none().text_color(tint).child(id.to_string())).child(div().flex_1().child(text.to_string()))
}

/// What's happening now: the question waiting for the room, what claude's
/// reading, or that it's the room's turn to say whether the stage is right.
fn now_box(question: Option<&crate::work_panel::Question>, state: &State, preview: bool, theme: &Theme) -> Option<gpui::AnyElement> {
    let boxed = || div().flex().flex_col().gap_1().p_3().rounded_md().border_1().border_color(theme.selected.opacity(0.5)).bg(theme.selected.opacity(0.06));
    if let Some(q) = question {
        return Some(
            boxed()
                .child(div().text_xs().text_color(theme.secondary).child(if q.header.is_empty() { "Claude asks the room".to_string() } else { format!("Claude asks the room · {}", q.header) }))
                .child(div().text_base().font_weight(FontWeight::MEDIUM).child(q.question.clone()))
                .children(q.options.iter().enumerate().map(|(i, (label, description, recommended))| {
                    div()
                        .flex()
                        .flex_row()
                        .gap_2()
                        .child(div().w(px(18.)).flex_none().text_color(theme.selected).child(format!("{}", i + 1)))
                        .child(
                            div()
                                .flex_1()
                                .flex()
                                .flex_col()
                                .child(div().child(format!("{label}{}", if *recommended { " (Recommended)" } else { "" })))
                                .when(!description.is_empty(), |d| d.child(div().text_xs().text_color(theme.secondary).child(description.clone()))),
                        )
                }))
                .child(div().text_xs().text_color(theme.tertiary).child("Answer in the terminal, or say something from the room below."))
                .into_any_element(),
        );
    }
    if let Some(s) = &state.scouting_now {
        return Some(boxed().child(div().text_xs().text_color(theme.secondary).child("Claude is reading the code")).child(s.why.clone()).into_any_element());
    }
    if preview {
        return None;
    }
    let stage = state.stage();
    (stage != Stage::Agree && state.unmet(stage).is_empty())
        .then(|| boxed().child(div().text_sm().child(format!("Is {} right? Say so below, or tell Claude what to change.", stage.title().to_lowercase()))).into_any_element())
}

/// A stage in full, as the room works on it.
fn stage_view(stage: Stage, state: &State, _approvals: &Approvals, theme: &Theme) -> gpui::AnyElement {
    let o = &state.outcome;
    let r = &state.requirement;
    let uncovered: Vec<String> = state.uncovered().iter().map(|c| c.id.clone()).collect();
    let col = div().flex().flex_col().gap_1();
    let nothing = |what: &str| quiet(format!("Nothing yet: Claude fills in {what} as the room answers."), theme);
    match stage {
        Stage::Outcome => col
            .when(!state.title.is_empty(), |d| d.child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(state.title.clone())))
            .when(!state.summary.is_empty(), |d| d.child(div().text_color(theme.secondary).child(state.summary.clone())))
            .children(field("What changes, for whom", &o.change, theme))
            .when(!o.measures.is_empty(), |d| {
                d.child(heading("How we'll know", theme)).children(o.measures.iter().map(|m| {
                    ided(&m.id, &if m.target.is_empty() { m.text.clone() } else { format!("{} (target: {})", m.text, m.target) }, theme.selected)
                }))
            })
            .children(field("If we don't", &o.if_not, theme))
            .children(field("The smallest version that proves it", &o.smallest, theme))
            .children(list("If it fails, it'll be because", &o.premortem, theme))
            .when(o.change.is_empty() && o.measures.is_empty(), |d| d.child(nothing("the outcome")))
            .into_any_element(),
        Stage::Requirements => col
            .children(field("Problem", &r.problem, theme))
            .children(field("Goal", &r.goal, theme))
            .children(field("Who it's for", &r.users, theme))
            .children(list("In scope", &r.scope, theme))
            .children(list("Not doing", &r.non_goals, theme))
            .when(!r.acceptance.is_empty(), |d| d.child(heading("Acceptance criteria", theme)).children(r.acceptance.iter().map(|c| ided(&c.id, &c.text, theme.selected))))
            .children(list("Open questions", &r.open_questions, theme))
            .when(r.problem.is_empty() && r.acceptance.is_empty(), |d| d.child(nothing("the requirement")))
            .into_any_element(),
        Stage::Design => col
            .when(!state.approach.is_empty(), |d| d.child(markdown("plan-design", &state.approach, theme)))
            .when(!state.scouting.is_empty(), |d| d.child(heading("In the code", theme)).children(state.scouting.iter().enumerate().map(|(i, f)| finding(i, f, theme))))
            .when(state.approach.is_empty() && state.scouting.is_empty(), |d| d.child(nothing("the design")))
            .into_any_element(),
        Stage::Breakdown | Stage::Agree => {
            let cards = breakdown_cards(state, theme);
            col.when(!state.size.is_empty(), |d| {
                let size = format!("{}{}", state.size[..1].to_uppercase(), &state.size[1..]);
                d.child(div().flex().flex_row().items_center().gap_2().child(div().px_2().py_0p5().rounded_md().text_xs().bg(theme.tile).child(size)).child(quiet(state.size_reason.clone(), theme)))
            })
            .children(cards)
            .when(!uncovered.is_empty() && !state.tasks.is_empty(), |d| d.child(div().text_xs().text_color(theme.orange()).child(format!("No issue satisfies {} yet.", uncovered.join(", ")))))
            .when(state.tasks.is_empty(), |d| d.child(nothing("the breakdown")))
            .into_any_element()
        }
    }
}

fn finding(i: usize, f: &planning::Finding, theme: &Theme) -> gpui::Div {
    let url = f.url();
    let kind = match f.kind.to_lowercase().as_str() {
        "risk" => "Risk",
        "pattern" => "Pattern",
        _ => "Area",
    };
    div()
        .flex()
        .flex_row()
        .gap_2()
        .py_0p5()
        .child(div().w(px(52.)).flex_none().text_xs().text_color(if kind == "Risk" { theme.orange() } else { theme.secondary }).child(kind))
        .child(
            div()
                .flex_1()
                .flex()
                .flex_col()
                .when(!f.path.is_empty(), |d| {
                    d.child(
                        div()
                            .id(SharedString::from(format!("plan-finding-{i}")))
                            .text_xs()
                            .text_color(theme.selected)
                            .cursor_pointer()
                            .child(format!("{}:{}", f.repo.rsplit('/').next().unwrap_or(&f.repo), f.path))
                            .when_some(url, |d, url| d.on_click(move |_, _, cx| cx.open_url(&url))),
                    )
                })
                .child(f.note.clone()),
        )
}

/// Epics with their issues under them, then issues under none.
fn breakdown_cards(state: &State, theme: &Theme) -> Vec<gpui::AnyElement> {
    let card = |i: usize, task: &planning::Task, nested: bool| {
        let meta = [
            Some(task.repo.clone()).filter(|r| !r.is_empty()),
            (!task.satisfies.is_empty()).then(|| format!("Satisfies {}", task.satisfies.join(", "))),
            (!task.estimate.is_empty()).then(|| format!("Size {}", task.estimate)),
            (!task.depends_on.is_empty()).then(|| format!("After {}", task.depends_on.join(", "))),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" · ");
        div()
            .flex()
            .flex_col()
            .gap_0p5()
            .p_2()
            .rounded_md()
            .border_1()
            .border_color(theme.border)
            .when(nested, |d| d.ml(px(20.)))
            .when(task.is_epic(), |d| d.bg(theme.tile))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1p5()
                    .when(task.is_epic(), |d| d.child(div().text_xs().px_1().rounded_sm().border_1().border_color(theme.border).text_color(theme.secondary).child("Epic")))
                    .child(div().font_weight(FontWeight::MEDIUM).child(if task.title.is_empty() { "Untitled".to_string() } else { task.title.clone() })),
            )
            .when(!meta.is_empty(), |d| d.child(quiet(meta, theme)))
            .when(!task.body.is_empty(), |d| d.child(markdown(&format!("plan-task-{i}"), &task.body, theme)))
            .when(!task.test_plan.is_empty(), |d| d.child(quiet(format!("Checked by: {}", task.test_plan), theme)))
            .into_any_element()
    };
    let mut cards = Vec::new();
    for (i, epic) in state.tasks.iter().enumerate().filter(|(_, t)| t.is_epic()) {
        cards.push(card(i, epic, false));
        for (j, t) in state.tasks.iter().enumerate().filter(|(_, t)| !t.is_epic() && t.parent.trim().eq_ignore_ascii_case(epic.title.trim())) {
            cards.push(card(j, t, true));
        }
    }
    for (i, t) in state.tasks.iter().enumerate().filter(|(_, t)| !t.is_epic() && !state.epics().any(|e| e.title.trim().eq_ignore_ascii_case(t.parent.trim()))) {
        cards.push(card(i, t, false));
    }
    cards
}

/// The decisions settled in a stage.
fn decisions(state: &State, stage: Stage, theme: &Theme) -> Option<gpui::Div> {
    let here: Vec<&planning::Decision> = state.decisions.iter().filter(|d| Stage::parse(&d.stage) == Some(stage)).collect();
    (!here.is_empty()).then(|| {
        div().flex().flex_col().gap_1().child(heading("Decided", theme)).children(here.into_iter().map(|d| {
            div().flex().flex_col().child(div().text_xs().text_color(theme.secondary).child(d.question.clone())).child(d.answer.clone())
        }))
    })
}

/// The spec so far, compact: each stage before the one in hand, with
/// whether the room's approved it. It stays put while the left changes.
fn spec_view(state: &State, shown: Stage, approvals: &Approvals, theme: &Theme) -> gpui::AnyElement {
    let o = &state.outcome;
    let r = &state.requirement;
    let section = |s: Stage| {
        let mark = match approvals.status(s, state) {
            Status::Approved => ("✓ Approved", theme.selected),
            Status::Recheck => ("Recheck", theme.orange()),
            Status::Open => ("Not approved", theme.tertiary),
        };
        div()
            .pt_3()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(s.title().to_uppercase()))
            .child(div().text_xs().text_color(mark.1).child(mark.0))
    };
    let small = |text: String| div().text_sm().child(text);
    let breakdown_started = !state.tasks.is_empty();
    let shows = |s: Stage| s != shown && (s.index() < state.stage().index() || s.index() < shown.index());
    let mut col = div()
        .flex()
        .flex_col()
        .gap_1()
        .child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.tertiary).child("THE SPEC SO FAR"))
        .when(!state.title.is_empty(), |d| d.child(div().pt_1().text_base().font_weight(FontWeight::SEMIBOLD).child(state.title.clone())));
    let mut any = false;
    if shows(Stage::Outcome) && (!o.change.is_empty() || !o.measures.is_empty()) {
        any = true;
        col = col
            .child(section(Stage::Outcome))
            .when(!o.change.is_empty(), |d| d.child(small(o.change.clone())))
            .children(o.measures.iter().map(|m| ided(&m.id, &if m.target.is_empty() { m.text.clone() } else { format!("{} ({})", m.text, m.target) }, theme.selected).text_sm()));
    }
    if shows(Stage::Requirements) && (!r.problem.is_empty() || !r.acceptance.is_empty()) {
        any = true;
        let uncovered: Vec<String> = state.uncovered().iter().map(|c| c.id.clone()).collect();
        col = col
            .child(section(Stage::Requirements))
            .when(!r.goal.is_empty(), |d| d.child(small(r.goal.clone())))
            .children(r.acceptance.iter().map(|c| {
                let tint = if breakdown_started && uncovered.contains(&c.id) { theme.orange() } else { theme.selected };
                ided(&c.id, &c.text, tint).text_sm()
            }))
            .when(breakdown_started && !uncovered.is_empty(), |d| d.child(div().text_xs().text_color(theme.orange()).child(format!("Not yet satisfied: {}", uncovered.join(", ")))));
    }
    if shows(Stage::Design) && !state.approach.is_empty() {
        any = true;
        let first = state.approach.split("\n\n").next().unwrap_or_default().to_string();
        let risks = state.scouting.iter().filter(|f| f.kind.eq_ignore_ascii_case("risk")).count();
        col = col
            .child(section(Stage::Design))
            .child(small(first))
            .when(risks > 0, |d| d.child(div().text_xs().text_color(theme.orange()).child(format!("{risks} risk{} found in the code", if risks == 1 { "" } else { "s" }))));
    }
    if shows(Stage::Breakdown) && breakdown_started {
        any = true;
        col = col.child(section(Stage::Breakdown)).children(state.tasks.iter().map(|t| {
            div().text_sm().when(!t.is_epic() && !t.parent.is_empty(), |d| d.pl(px(14.))).child(format!("{}{}", if t.is_epic() { "Epic: " } else { "" }, t.title))
        }));
    }
    if !any {
        col = col.child(quiet("What the room settles shows here, so it stays in view while the next stage is worked out.".into(), theme));
    }
    col.into_any_element()
}
