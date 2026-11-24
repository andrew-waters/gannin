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
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, FontWeight, KeyDownEvent, SharedString, Subscription, Task, Window};
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
    _poll: Task<()>,
}

impl PlanningPanel {
    pub fn new(launch: Launch, terminal: Entity<Terminal>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let path = launch.folder().join("planning.json");
        // Re-read every few seconds, off the main thread.
        let poll = cx.spawn(async move |this, cx| loop {
            let file = path.clone();
            let state = cx.background_executor().spawn(async move { State::read(&file) }).await;
            if this
                .update(cx, |this, cx| {
                    if state.is_some() && this.state != state {
                        this.state = state;
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
        Self { approvals: Approvals::load(&dir), agreed: Agreed::load(&dir), dir, preview: false, sent: None, launch, terminal: Some(terminal), state: None, comment, notice: None, agree: None, _poll: poll }
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
            _poll: Task::ready(()),
        }
    }

    /// The preview's claude: the stage it's on, answered.
    fn answer(&mut self, cx: &mut Context<Self>) {
        let stage = self.stage();
        self.state = Some(crate::planning_preview::state(stage, true));
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
        let heading = |text: &str| div().pt_3().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(text.to_string());
        let quiet = |text: String| div().text_xs().text_color(theme.secondary).child(text);
        let empty = State::default();
        let state = self.state.as_ref().unwrap_or(&empty);

        let stepper = div().flex().flex_row().flex_wrap().items_center().gap_1().children(Stage::ALL.iter().enumerate().map(|(i, s)| {
            let status = if *s == Stage::Agree {
                if self.agreed.finished() { Status::Approved } else { Status::Open }
            } else {
                self.approvals.status(*s, state)
            };
            let (bg, fg) = if *s == stage {
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
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_1()
                .when(i > 0, |d| d.child(div().text_color(theme.tertiary).child("›")))
                .child(div().px_2().py_0p5().rounded_full().text_xs().bg(bg).text_color(fg).child(label))
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
            None => quiet("Claude keeps the plan in planning.json as the room answers; it shows here once it starts.".into()).into_any_element(),
            Some(state) => {
                let field = |label: &str, text: &str| (!text.is_empty()).then(|| div().flex().flex_col().child(heading(label)).child(text.to_string()));
                let list = |label: &str, items: &[String]| (!items.is_empty()).then(|| div().flex().flex_col().child(heading(label)).children(items.iter().map(|i| div().child(format!("• {i}")))));
                let ided = |id: String, text: String, tint| div().flex().flex_row().gap_2().child(div().w(px(28.)).flex_none().text_color(tint).child(id)).child(div().flex_1().child(text));
                let o = &state.outcome;
                let r = &state.requirement;
                let uncovered: Vec<String> = state.uncovered().iter().map(|c| c.id.clone()).collect();
                let task_card = |i: usize, task: &planning::Task, nested: bool| {
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
                        .when(!meta.is_empty(), |d| d.child(quiet(meta)))
                        .when(!task.body.is_empty(), |d| d.child(markdown(&format!("plan-task-{i}"), &task.body, &theme)))
                        .when(!task.test_plan.is_empty(), |d| d.child(quiet(format!("Checked by: {}", task.test_plan))))
                };
                // Epics with their issues under them, then issues under none.
                let mut cards: Vec<gpui::AnyElement> = Vec::new();
                for (i, epic) in state.tasks.iter().enumerate().filter(|(_, t)| t.is_epic()) {
                    cards.push(task_card(i, epic, false).into_any_element());
                    for (j, t) in state.tasks.iter().enumerate().filter(|(_, t)| !t.is_epic() && t.parent.trim().eq_ignore_ascii_case(epic.title.trim())) {
                        cards.push(task_card(j, t, true).into_any_element());
                    }
                }
                for (i, t) in state.tasks.iter().enumerate().filter(|(_, t)| !t.is_epic() && !state.epics().any(|e| e.title.trim().eq_ignore_ascii_case(t.parent.trim()))) {
                    cards.push(task_card(i, t, false).into_any_element());
                }
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .when(!state.title.is_empty(), |d| d.child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(state.title.clone())))
                    .when(!state.summary.is_empty(), |d| d.child(div().text_color(theme.secondary).child(state.summary.clone())))
                    // The outcome: what changes and how we'll know.
                    .children(field("What changes, for whom", &o.change))
                    .when(!o.measures.is_empty(), |d| {
                        d.child(heading("How we'll know")).children(o.measures.iter().map(|m| {
                            ided(m.id.clone(), if m.target.is_empty() { m.text.clone() } else { format!("{} (target: {})", m.text, m.target) }, theme.selected)
                        }))
                    })
                    .children(field("If we don't", &o.if_not))
                    .children(field("The smallest version that proves it", &o.smallest))
                    .children(list("If it fails, it'll be because", &o.premortem))
                    // The requirement.
                    .children(field("Problem", &r.problem))
                    .children(field("Goal", &r.goal))
                    .children(field("Who it's for", &r.users))
                    .children(list("Scope", &r.scope))
                    .children(list("Not doing", &r.non_goals))
                    .when(!r.acceptance.is_empty(), |d| {
                        d.child(heading("Acceptance criteria")).children(r.acceptance.iter().map(|c| {
                            let tint = if !state.tasks.is_empty() && uncovered.contains(&c.id) { theme.orange() } else { theme.selected };
                            ided(c.id.clone(), c.text.clone(), tint)
                        }))
                    })
                    .children(list("Open questions", &r.open_questions))
                    // The design, and what claude found in the code.
                    .when(!state.approach.is_empty(), |d| d.child(heading("Design")).child(markdown("plan-design", &state.approach, &theme)))
                    .when_some(state.scouting_now.as_ref(), |d, s| d.child(quiet(format!("Looking at the code: {}", s.why))))
                    .when(!state.scouting.is_empty(), |d| {
                        d.child(heading("In the code")).children(state.scouting.iter().enumerate().map(|(i, f)| {
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
                        }))
                    })
                    // The breakdown.
                    .when(!state.tasks.is_empty(), |d| {
                        let size = if state.size.is_empty() { String::new() } else { format!(" · {}{}", state.size[..1].to_uppercase(), &state.size[1..]) };
                        d.child(heading(&format!("Breakdown{size}")))
                            .when(!state.size_reason.is_empty(), |d| d.child(quiet(state.size_reason.clone())))
                            .children(cards)
                            .when(!uncovered.is_empty(), |d| d.child(div().text_xs().text_color(theme.orange()).child(format!("No issue satisfies {} yet.", uncovered.join(", ")))))
                    })
                    .when(!state.decisions.is_empty(), |d| {
                        d.child(heading("Decisions")).children(state.decisions.iter().map(|decision| {
                            div().flex().flex_col().child(div().text_color(theme.secondary).child(decision.question.clone())).child(decision.answer.clone())
                        }))
                    })
                    .into_any_element()
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
            .child(div().id("plan-body").flex_1().min_h_0().overflow_y_scroll().p_4().child(body))
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
