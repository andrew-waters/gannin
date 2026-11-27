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
use crate::planning_security::{self as security, Review};
use gpui::{div, prelude::*, px, relative, Animation, AnimationExt, ClickEvent, Transformation, Context, Entity, FontWeight, KeyDownEvent, SharedString, Subscription, Task, Window};
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
    questions: Vec<crate::work_panel::Question>,
    /// The options the room has picked, for each question.
    picked: Vec<Vec<usize>>,
    /// Where claude leaves the shape's images: the session's folder in the
    /// harness (the preview's own folder in the preview).
    folder: std::path::PathBuf,
    /// The screen the room has open: comments go to claude about it.
    screen: Option<String>,
    review: Option<Review>,
    reviewing: bool,
    /// The model the next security review runs on.
    review_model: &'static str,
    /// What claude's doing, as the session's hooks last wrote it:
    /// starting, working, needs-you, idle or exited.
    claude: Option<String>,
    /// A message just sent to claude, with the questions open then: until
    /// claude's seen working (or asks something new), the hooks' older
    /// "waiting for the room" and that question are stale, not shown again.
    awaiting: Option<(Vec<String>, std::time::Instant)>,
    /// Reopened after Gannin quit while claude was waiting on the room
    /// ("needs-you") or mid-turn ("working"): once claude's back, it's
    /// asked to pick up, since a resumed claude doesn't ask again itself.
    resumed_from: Option<String>,
    _poll: Task<()>,
    /// Redraws when a diagram's been drawn.
    _diagrams: Task<()>,
    /// A diagram opened large, in place of the stage and the spec.
    enlarged: Option<Enlarged>,
}

/// A diagram opened in the panel: what it's of, and its picture.
#[derive(Clone)]
struct Enlarged {
    title: String,
    path: std::path::PathBuf,
    /// Its natural size, in points.
    size: (f32, f32),
    /// Fitted to the panel's width, scrolling down; else at its natural
    /// size, scrolling both ways.
    fit: bool,
}

impl PlanningPanel {
    pub fn new(launch: Launch, terminal: Entity<Terminal>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let path = launch.local_folder().join("planning.json");
        let dir = launch.dir();
        // Re-read every few seconds, off the main thread, with the question
        // claude's waiting on.
        let poll = cx.spawn(async move |this, cx| loop {
            let file = path.clone();
            let session = dir.clone();
            let (state, question, claude) = cx
                .background_executor()
                .spawn(async move {
                    let claude = std::fs::read_to_string(session.join("state")).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
                    let waiting = claude.as_deref() == Some("needs-you");
                    let question = match waiting.then(|| crate::work_live::ask(&session, "")) {
                        Some(crate::work_panel::Ask::Questions(qs)) => qs,
                        _ => Vec::new(),
                    };
                    (State::read(&file), question, claude)
                })
                .await;
            if this
                .update(cx, |this, cx| {
                    let (mut claude, mut question) = (claude, question);
                    // Until a resumed claude is up, what the hooks last said
                    // (a server's copy may still say it's waiting) is stale.
                    if this.resumed_from.is_some() && claude.as_deref() != Some("idle") {
                        claude = Some("starting".into());
                        question = Vec::new();
                    }
                    if let Some((asked, at)) = &this.awaiting {
                        let asks_anew = !question.is_empty() && question.iter().map(|q| &q.question).ne(asked.iter());
                        if claude.as_deref() == Some("working") || asks_anew || at.elapsed() > Duration::from_secs(45) {
                            this.awaiting = None;
                        } else {
                            claude = Some("working".into());
                            question = Vec::new();
                        }
                    }
                    if this.claude != claude {
                        this.claude = claude;
                        cx.notify();
                    }
                    // Back after a restart: claude's idle again, so ask it to
                    // pick up where it was.
                    if this.claude.as_deref() == Some("idle") {
                        if let Some(before) = this.resumed_from.take() {
                            let message = if before == "needs-you" {
                                "Gannin was restarted while you were waiting on the room, so the question you'd asked was lost. Ask it again."
                            } else {
                                "Gannin was restarted while you were working, so that turn was cut off. Carry on from where you were."
                            };
                            this.send_now(message.to_string(), cx);
                        }
                    }
                    let changed_question = this.questions.iter().map(|q| &q.question).ne(question.iter().map(|q| &q.question));
                    if changed_question {
                        this.picked = vec![Vec::new(); question.len()];
                        this.questions = question;
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
        let folder = launch.local_folder();
        let resumed_from = {
            let file = dir.join("resumed-from");
            let before = std::fs::read_to_string(&file).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
            let _ = std::fs::remove_file(&file);
            before
        };
        Self {
            approvals: Approvals::load(&dir),
            agreed: Agreed::load(&dir),
            review: Review::load(&dir),
            dir,
            preview: false,
            sent: None,
            launch,
            terminal: Some(terminal),
            state: None,
            comment,
            notice: None,
            agree: None,
            viewing: None,
            questions: Vec::new(),
            picked: Vec::new(),
            folder,
            screen: None,
            reviewing: false,
            review_model: security::MODELS[0].0,
            claude: None,
            awaiting: None,
            resumed_from,
            _poll: poll,
            _diagrams: watch_diagrams(cx),
            enlarged: None,
        }
    }

    /// The made-up plan, from its first stage, with nothing kept from
    /// last time.
    pub fn preview(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let dir = crate::planning_preview::dir();
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::create_dir_all(&dir);
        let folder = crate::planning_preview::write_screens(&dir);
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
            questions: crate::planning_preview::question(Stage::Outcome).into_iter().collect(),
            picked: vec![Vec::new()],
            folder,
            screen: None,
            review: None,
            reviewing: false,
            review_model: security::MODELS[0].0,
            claude: None,
            awaiting: None,
            resumed_from: None,
            _poll: Task::ready(()),
            _diagrams: watch_diagrams(cx),
            enlarged: None,
        }
    }

    /// The preview's claude: the stage it's on, answered.
    fn answer(&mut self, cx: &mut Context<Self>) {
        let stage = self.stage();
        let mut state = crate::planning_preview::state(stage, true);
        // Claude answers the security review once it's run, and its
        // answers stay.
        state.security = self.state.as_ref().map(|s| s.security.clone()).unwrap_or_default();
        if stage == Stage::Design && self.review.as_ref().is_some_and(Review::done) {
            state.security = crate::planning_preview::security_answers();
        }
        self.state = Some(state);
        self.questions.clear();
        self.picked.clear();
        self.sent = Some(format!("(Claude asks the room about {} and fills it in.)", stage.title().to_lowercase()));
        cx.notify();
    }

    fn stage(&self) -> Stage {
        self.state.as_ref().map(State::stage).unwrap_or(Stage::Outcome)
    }

    /// Sends claude a message: Esc first when a question is waiting, as
    /// Gannin answers, then the text as one message.
    fn send(&mut self, message: String, _window: &mut Window, cx: &mut Context<Self>) {
        self.send_now(message, cx);
    }

    fn send_now(&mut self, message: String, cx: &mut Context<Self>) {
        let Some(terminal) = self.terminal.clone() else {
            self.sent = Some(message);
            return cx.notify();
        };
        let waiting = self.launch.state().as_deref() == Some("needs-you");
        // Straight to Claude at work: what was asked is answered.
        self.awaiting = Some((self.questions.iter().map(|q| q.question.clone()).collect(), std::time::Instant::now()));
        self.claude = Some("working".into());
        self.questions.clear();
        self.picked.clear();
        cx.notify();
        cx.spawn(async move |_, cx| {
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
        let on = self
            .screen
            .as_ref()
            .and_then(|id| self.state.as_ref()?.shape.screens.iter().find(|s| &s.id == id))
            .map(|s| format!("screen {} ({})", s.id, s.title))
            .unwrap_or(stage);
        let text = self.take_comment(window, cx);
        if text.is_empty() {
            return;
        }
        self.notice = None;
        self.send(format!("From the room, on {on}: {text}"), window, cx);
        cx.notify();
    }

    /// Why `stage` can't be approved yet: its criteria, and for the design,
    /// the security review and claude's answers to it.
    fn unmet(&self, state: &State, stage: Stage) -> Vec<String> {
        let mut out = state.unmet(stage);
        if stage == Stage::Design {
            out.extend(security::unmet(self.review.as_ref(), state));
        }
        out
    }

    /// The security review of the shape and the design, on the model
    /// picked, off the main thread; its findings go to claude.
    fn run_review(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(state) = self.state.clone() else { return };
        if self.reviewing {
            return;
        }
        self.reviewing = true;
        self.notice = None;
        cx.notify();
        let model = self.review_model.to_string();
        let prompt = security::prompt(&state);
        let (harness, server, preview) = (self.launch.harness_path.clone(), self.launch.server.clone(), self.preview);
        let fingerprint = security::fingerprint(&state);
        cx.spawn_in(window, async move |this, cx| {
            let result = if preview {
                cx.background_executor().timer(Duration::from_millis(1200)).await;
                Ok(crate::planning_preview::security_findings())
            } else {
                cx.background_executor().spawn(async move { security::run(&prompt, &model, &harness, server.as_ref()) }).await
            };
            let _ = this.update_in(cx, |this, window, cx| {
                this.reviewing = false;
                let mut review = Review { model: this.review_model.to_string(), fingerprint, ..Default::default() };
                match result {
                    Ok(findings) => {
                        review.at = Some(chrono::Utc::now());
                        review.findings = findings;
                    }
                    Err(e) => review.error = Some(e),
                }
                review.save(&this.dir);
                if review.done() {
                    this.send(security::message(&review), window, cx);
                }
                this.review = Some(review);
                cx.notify();
            });
        })
        .detach();
    }

    /// The room approves the stage it's on; with its criteria unmet only
    /// "anyway", saying why in the box.
    fn approve(&mut self, anyway: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(state) = self.state.clone() else { return };
        let stage = state.stage();
        let Some(next) = stage.next() else { return };
        let unmet = self.unmet(&state, stage);
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
            let mut moved = crate::planning_preview::state(next, next == Stage::Agree);
            moved.security = state.security.clone();
            self.state = Some(moved);
            self.questions = crate::planning_preview::question(next).into_iter().collect();
            self.picked = vec![Vec::new(); self.questions.len()];
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

impl PlanningPanel {
    /// The room picks an option. One question with one answer goes to
    /// claude straight away; otherwise picks are kept until Send Answers.
    fn pick(&mut self, question: usize, option: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(q) = self.questions.get(question) else { return };
        if self.picked.len() < self.questions.len() {
            self.picked.resize(self.questions.len(), Vec::new());
        }
        let picks = &mut self.picked[question];
        if q.multi {
            match picks.iter().position(|&p| p == option) {
                Some(at) => {
                    picks.remove(at);
                }
                None => picks.push(option),
            }
        } else {
            *picks = vec![option];
        }
        if self.questions.len() == 1 && !self.questions[0].multi {
            return self.send_answers(window, cx);
        }
        cx.notify();
    }

    /// The room's answers as one message, after Esc closes claude's own
    /// picker, as the Work panel answers.
    fn send_answers(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let lines: Vec<String> = self
            .questions
            .iter()
            .enumerate()
            .map(|(i, q)| {
                let picked: Vec<String> = self.picked.get(i).into_iter().flatten().filter_map(|&o| q.options.get(o).map(|(l, _, _)| l.clone())).collect();
                format!("- {}: {}", q.question, if picked.is_empty() { "your call".to_string() } else { picked.join(", ") })
            })
            .collect();
        let message = format!("The room's answers:\n{}", lines.join("\n"));
        // `send` clears the questions, once it's noted them as answered.
        self.send(message, window, cx);
        if self.preview {
            self.questions.clear();
            self.picked.clear();
            self.answer(cx);
        }
    }

    /// Claude's questions to the room, each option a button.
    fn question_box(&self, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        let single = self.questions.len() == 1 && !self.questions[0].multi;
        let blocks = self.questions.iter().enumerate().map(|(qi, q)| {
            let picks = self.picked.get(qi).cloned().unwrap_or_default();
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(div().text_xs().text_color(theme.secondary).child(if q.header.is_empty() { "Claude asks the room".to_string() } else { format!("Claude asks the room · {}", q.header) }))
                .child(div().text_base().font_weight(FontWeight::MEDIUM).child(q.question.clone()))
                .when(q.multi, |d| d.child(div().text_xs().text_color(theme.tertiary).child("Pick any that apply.")))
                .children(q.options.iter().enumerate().map(|(oi, (label, description, recommended))| {
                    let on = picks.contains(&oi);
                    div()
                        .id(SharedString::from(format!("plan-option-{qi}-{oi}")))
                        .flex()
                        .flex_row()
                        .gap_2()
                        .px_2()
                        .py_1p5()
                        .rounded_md()
                        .border_1()
                        .border_color(if on { theme.selected } else { theme.border })
                        .bg(if on { theme.selected.opacity(0.12) } else { gpui::transparent_black() })
                        .cursor_pointer()
                        .hover(|d| d.bg(theme.selected.opacity(0.08)))
                        .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.pick(qi, oi, window, cx)))
                        .child(div().w(px(18.)).flex_none().text_color(theme.selected).child(if q.multi { (if on { "☑" } else { "☐" }).to_string() } else { format!("{}", oi + 1) }))
                        .child(
                            div()
                                .flex_1().min_w_0()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .child(div().child(format!("{label}{}", if *recommended { " (Recommended)" } else { "" })))
                                .when(!description.is_empty(), |d| d.child(div().text_xs().text_color(theme.secondary).child(description.clone()))),
                        )
                }))
        });
        div()
            .flex()
            .flex_col()
            .gap_3()
            .p_3()
            .rounded_md()
            .border_1()
            .border_color(theme.selected.opacity(0.5))
            .bg(theme.selected.opacity(0.06))
            .children(blocks)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1().min_w_0().text_xs().text_color(theme.tertiary).child(if single {
                        "Pick one to answer, or say something else from the room below."
                    } else {
                        "Pick your answers, then send them. Or say something else from the room below."
                    }))
                    .when(!single, |d| d.child(button("plan-send-answers", "Send Answers", true, theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.send_answers(window, cx))))),
            )
            .into_any_element()
    }

    /// The room's just answered: Claude's taking it in.
    fn taking(&self, theme: &Theme) -> gpui::AnyElement {
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .p_3()
            .rounded_md()
            .border_1()
            .border_color(theme.selected.opacity(0.5))
            .bg(theme.selected.opacity(0.06))
            .child(spinner("plan-taking-spinner", px(14.), theme.selected))
            .child(div().text_sm().child("Claude is taking in what the room said"))
            .into_any_element()
    }

    /// What's happening now, beside the stages: a spinner while claude (or
    /// the security review) is at work, else whose turn it is.
    fn activity(&self, theme: &Theme) -> Option<gpui::AnyElement> {
        let stage = self.stage().title().to_lowercase();
        let (text, busy, tint): (String, bool, gpui::Hsla) = if self.reviewing {
            (format!("{} is reviewing the shape and the design for security", security::model_name(self.review_model)), true, theme.selected)
        } else if self.preview {
            return None;
        } else {
            match self.claude.as_deref() {
                None | Some("starting") => ("Claude is starting the session".into(), true, theme.selected),
                Some("working") => match self.state.as_ref().and_then(|s| s.scouting_now.as_ref()) {
                    Some(s) => (format!("Claude is reading the code: {}", s.why), true, theme.selected),
                    None if self.state.is_none() => ("Claude is reading the topic and what was shared".into(), true, theme.selected),
                    None => (format!("Claude is working on {stage}"), true, theme.selected),
                },
                Some("needs-you") => ("Claude is waiting for the room".into(), false, theme.orange()),
                Some("exited") => ("Claude Code has stopped: resume it in the terminal".into(), false, theme.critical()),
                Some(_) => ("The room's turn".into(), false, theme.secondary),
            }
        };
        Some(
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_1p5()
                .flex_none()
                .text_xs()
                .text_color(tint)
                .child(if busy {
                    spinner("plan-activity-spinner", px(12.), tint)
                } else {
                    div().size(px(7.)).rounded_full().bg(tint).flex_none().into_any_element()
                })
                .child(text)
                .into_any_element(),
        )
    }

    /// Shape: what the machine can run, the mock behind the screens, the
    /// flows, and the screens in flow order. A screen clicked opens large,
    /// and the room's comments go to claude about it.
    fn shape_view(&self, state: &State, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        let shape = &state.shape;
        let panel = cx.entity().downgrade();
        // Only what's missing, called out: with everything there, nothing.
        let missing: Vec<&str> = [(shape.tools.node == Some(false), "Node"), (shape.tools.browser == Some(false), "a headless browser")].into_iter().filter(|(m, _)| *m).map(|(_, n)| n).collect();
        let tools = (!missing.is_empty()).then(|| {
            div()
                .flex()
                .flex_col()
                .gap_0p5()
                .p_2()
                .rounded_md()
                .border_1()
                .border_color(theme.orange().opacity(0.6))
                .bg(theme.orange().opacity(0.08))
                .child(div().text_sm().text_color(theme.orange()).child(format!(
                    "The machine running this session has no {}, so the screens are wireframes Claude draws, not screenshots of a running mock.",
                    missing.join(" and no ")
                )))
                .when(!shape.tools.note.is_empty(), |d| d.child(div().text_xs().text_color(theme.secondary).child(shape.tools.note.clone())))
        });
        let mock = (shape.mock.kind.eq_ignore_ascii_case("running") && !shape.mock.branch.is_empty()).then(|| {
            let url = shape.mock.url.clone();
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .p_2()
                .rounded_md()
                .bg(theme.tile)
                .child(div().flex_1().min_w_0().text_xs().text_color(theme.secondary).child(format!(
                    "A running mock of {} on {}, a throwaway branch that's never pushed: delete it once the plan's agreed.",
                    if shape.mock.repo.is_empty() { "the app" } else { shape.mock.repo.as_str() },
                    shape.mock.branch
                )))
                .when(!url.is_empty(), |d| d.child(button("plan-open-mock", "Open the Mock", false, theme).on_click(move |_, _, cx| cx.open_url(&url))))
        });
        let chips = |ids: &[String]| div().flex().flex_row().flex_wrap().gap_1().children(ids.iter().map(|c| div().px_1p5().rounded_md().text_xs().bg(theme.tile).text_color(theme.selected).child(c.clone())));
        let flows = shape.flows.iter().enumerate().map(|(i, f)| {
            div()
                .flex()
                .flex_col()
                .gap_1()
                .py_1()
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(div().text_xs().text_color(theme.selected).child(f.id.clone()))
                        .child(div().flex_1().min_w_0().text_sm().font_weight(FontWeight::MEDIUM).child(f.title.clone()))
                        .when(!f.kind.is_empty(), |d| d.child(div().text_xs().text_color(theme.secondary).child(if f.kind.eq_ignore_ascii_case("process") { "System process" } else { "User journey" })))
                        .child(chips(&f.criteria)),
                )
                .when(!f.diagram.trim().is_empty(), |d| d.child(diagram(&format!("plan-flow-{i}"), &format!("{} {}", f.id, f.title), &f.diagram, theme, &panel)))
        });
        let open = self.screen.as_ref().and_then(|id| shape.screens.iter().find(|s| &s.id == id));
        let large = open.map(|s| {
            div()
                .flex()
                .flex_col()
                .gap_1()
                .p_2()
                .rounded_md()
                .border_1()
                .border_color(theme.selected)
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(div().text_xs().text_color(theme.selected).child(s.id.clone()))
                        .child(div().flex_1().min_w_0().text_sm().font_weight(FontWeight::MEDIUM).child(s.title.clone()))
                        .child(chips(&s.criteria))
                        .child(button("plan-screen-close", "Close", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                            this.screen = None;
                            cx.notify();
                        }))),
                )
                .child(match s.image_path() {
                    Some(path) => div().h(px(420.)).rounded_md().bg(gpui::white()).child(gpui::img(self.folder.join(path)).size_full().object_fit(gpui::ObjectFit::Contain)).into_any_element(),
                    None => markdown(&format!("plan-screen-large-{}", s.id), &s.wireframe, theme).into_any_element(),
                })
                .child(quiet(format!("What the room says now goes to Claude about {}.", s.id), theme))
        });
        let cards = shape.screens.iter().map(|s| {
            let id = s.id.clone();
            let picked = self.screen.as_deref() == Some(s.id.as_str());
            div()
                .id(SharedString::from(format!("plan-screen-{}", s.id)))
                .w(px(200.))
                .flex()
                .flex_col()
                .gap_1()
                .p_1p5()
                .rounded_md()
                .border_1()
                .border_color(if picked { theme.selected } else { theme.border })
                .cursor_pointer()
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.screen = if this.screen.as_deref() == Some(id.as_str()) { None } else { Some(id.clone()) };
                    cx.notify();
                }))
                .child(match s.image_path() {
                    Some(path) => div().h(px(130.)).rounded_sm().bg(gpui::white()).child(gpui::img(self.folder.join(path)).size_full().object_fit(gpui::ObjectFit::Contain)).into_any_element(),
                    None => div().h(px(130.)).overflow_hidden().p_1().rounded_sm().bg(theme.tile).text_xs().child(s.wireframe.clone()).into_any_element(),
                })
                .child(div().flex().flex_row().gap_1().child(div().text_xs().text_color(theme.selected).child(s.id.clone())).child(div().text_xs().truncate().child(s.title.clone())))
                .child(chips(&s.criteria))
        });
        let unshaped: Vec<String> = state.unshaped().iter().map(|c| c.id.clone()).collect();
        div()
            .flex()
            .flex_col()
            .gap_1()
            .children(tools)
            .children(mock)
            .when(!shape.flows.is_empty(), |d| d.child(heading("Flows", theme)).children(flows))
            .when(!shape.screens.is_empty(), |d| d.child(heading("Screens", theme)).children(large).child(div().flex().flex_row().flex_wrap().gap_2().children(cards)))
            .when(!unshaped.is_empty() && !shape.is_empty(), |d| d.child(div().text_xs().text_color(theme.orange()).child(format!("Not in any flow or screen yet: {}", unshaped.join(", ")))))
            .when(shape.is_empty(), |d| d.child(quiet("Nothing yet: Claude draws the flows, then the screens, as the room answers.".into(), theme)))
            .into_any_element()
    }

    /// The security review: the model to run it on, Run, and what it found
    /// with claude's answer to each.
    fn security_view(&self, state: &State, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        let models = div().flex().flex_row().gap_1().children(security::MODELS.iter().map(|(id, name)| {
            let id: &'static str = id;
            button(SharedString::from(format!("plan-review-model-{id}")), *name, self.review_model == id, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.review_model = id;
                cx.notify();
            }))
        }));
        let run_label = if self.reviewing {
            "Reviewing".to_string()
        } else if self.review.is_some() {
            "Run Again".to_string()
        } else {
            "Run Security Review".to_string()
        };
        let status = match &self.review {
            _ if self.reviewing => Some(format!("{} is reading the shape, the design and the code it touches.", security::model_name(self.review_model))),
            None => Some("Another model reviews the shape and the design before the room approves it.".to_string()),
            Some(r) if r.error.is_some() => Some(format!("The review didn't finish: {}", r.error.clone().unwrap_or_default())),
            Some(r) if r.fingerprint != security::fingerprint(state) => Some(format!("{} reviewed an earlier version: the shape or design has changed since.", security::model_name(&r.model))),
            Some(r) if r.findings.is_empty() => Some(format!("{} found nothing.", security::model_name(&r.model))),
            Some(r) => Some(format!("{} found {}.", security::model_name(&r.model), r.findings.len())),
        };
        let findings = self.review.iter().flat_map(|r| r.findings.iter()).map(|f| {
            let answer = state.security.iter().find(|a| a.id.eq_ignore_ascii_case(&f.id));
            let tint = match f.severity.to_lowercase().as_str() {
                "high" => theme.critical(),
                "medium" => theme.orange(),
                _ => theme.secondary,
            };
            div()
                .flex()
                .flex_col()
                .gap_0p5()
                .py_1()
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .gap_2()
                        .items_center()
                        .child(div().text_xs().text_color(tint).child(format!("{} {}", f.id, f.severity.to_uppercase())))
                        .child(div().flex_1().min_w_0().text_sm().font_weight(FontWeight::MEDIUM).child(f.title.clone())),
                )
                .when(!f.detail.is_empty(), |d| d.child(div().text_sm().child(f.detail.clone())))
                .when(!f.place.is_empty(), |d| d.child(quiet(format!("Where: {}", f.place), theme)))
                .when(!f.recommendation.is_empty(), |d| d.child(quiet(format!("Recommends: {}", f.recommendation), theme)))
                .child(match answer {
                    Some(a) => div().text_sm().text_color(theme.selected).child(format!("Claude: {}", a.response)),
                    None if f.blocking() => div().text_xs().text_color(theme.orange()).child("Waiting for Claude's answer."),
                    None => quiet("No answer needed before approving.".into(), theme),
                })
        });
        div()
            .flex()
            .flex_col()
            .gap_1()
            .child(heading("Security review", theme))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_wrap()
                    .items_center()
                    .gap_2()
                    .child(models)
                    .child(div().flex_1().min_w_0())
                    .child(if self.reviewing {
                        button("plan-review-run", run_label, false, theme).opacity(0.5).into_any_element()
                    } else {
                        button("plan-review-run", run_label, true, theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.run_review(window, cx))).into_any_element()
                    }),
            )
            .children(status.map(|s| quiet(s, theme)))
            .children(findings)
            .into_any_element()
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
                .child(div().flex_none().flex().flex_row().items_center().gap_2().px_3().py_2().border_b_1().border_color(theme.border).child(div().flex_1().min_w_0().child(stepper)).children(self.activity(&theme)))
                .child(div().flex_1().min_w_0().min_h_0().child(view.clone()))
                .into_any_element();
        }

        let body = if let Some(big) = self.enlarged.clone() {
            let url = format!("file://{}", big.path.display());
            div()
                .flex_1()
                .min_h_0()
                .flex()
                .flex_col()
                .child(
                    div()
                        .flex_none()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .px_4()
                        .py_2()
                        .border_b_1()
                        .border_color(theme.border)
                        .child(div().flex_1().min_w_0().font_weight(FontWeight::MEDIUM).truncate().child(big.title.clone()))
                        .child(button("plan-diagram-size", if big.fit { "Actual Size" } else { "Fit Width" }, false, &theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                            if let Some(big) = this.enlarged.as_mut() {
                                big.fit = !big.fit;
                            }
                            cx.notify();
                        })))
                        .child(button("plan-diagram-preview", "Open in Preview", false, &theme).on_click(move |_, _, cx| cx.open_url(&url)))
                        .child(button("plan-diagram-close", "Close", true, &theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                            this.enlarged = None;
                            cx.notify();
                        }))),
                )
                // Pinned inside the card, so it's fitted to the space rather
                // than drawn at its own size.
                .child(if big.fit {
                    // As wide as the panel, scrolling down a tall one.
                    let (w, h) = big.size;
                    div()
                        .id("plan-diagram-fit")
                        .flex_1()
                        .min_h_0()
                        .m_3()
                        .overflow_y_scroll()
                        .rounded_md()
                        .bg(if theme.dark { theme.tile } else { gpui::white() })
                        .child(
                            div().p_3().flex().flex_row().justify_center().child(
                                div()
                                    .relative()
                                    .w_full()
                                    .aspect_ratio(w / h.max(1.))
                                    .child(gpui::img(big.path.clone()).absolute().top_0().left_0().size_full().object_fit(gpui::ObjectFit::Contain)),
                            ),
                        )
                        .into_any_element()
                } else {
                    // At its own size, scrolling both ways.
                    div()
                        .id("plan-diagram-scroll")
                        .flex_1()
                        .min_h_0()
                        .m_3()
                        .overflow_scroll()
                        .rounded_md()
                        .bg(if theme.dark { theme.tile } else { gpui::white() })
                        .child(div().p_3().w(px(big.size.0 + 24.)).h(px(big.size.1 + 24.)).child(gpui::img(big.path.clone()).w(px(big.size.0)).h(px(big.size.1))))
                        .into_any_element()
                })
                .into_any_element()
        } else { match &self.state {
            // Before claude's written the plan: its first question still shows.
            None => div()
                .id("plan-stage")
                .flex_1().min_w_0()
                .min_h_0()
                .overflow_y_scroll()
                .p_4()
                .flex()
                .flex_col()
                .gap_2()
                .children(if !self.questions.is_empty() {
                    Some(self.question_box(&theme, cx))
                } else if self.awaiting.is_some() {
                    Some(self.taking(&theme))
                } else {
                    None
                })
                .child(quiet("The plan shows here as Claude writes it, from the room's answers.".into()))
                .into_any_element(),
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
                            .child(div().flex_1().min_w_0().text_xs().text_color(theme.secondary).child(format!("Looking back at {}. The room is on {}.", shown.title(), stage.title())))
                            .child(button("plan-view-current", format!("Back to {}", stage.title()), false, &theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                this.viewing = None;
                                cx.notify();
                            })))
                            .into_any_element(),
                    )
                } else {
                    if self.awaiting.is_some() && self.questions.is_empty() {
                        Some(self.taking(&theme))
                    } else if self.questions.is_empty() {
                        now_box(state, self.preview, &theme)
                    } else {
                        Some(self.question_box(&theme, cx))
                    }
                };
                let left = div()
                    .id("plan-stage")
                    .flex_1().min_w_0()
                    .min_w_0()
                    .h_full()
                    .overflow_y_scroll()
                    .p_4()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.selected).child(shown.title().to_uppercase()))
                    .children(now)
                    .child(match shown {
                        Stage::Shape => self.shape_view(state, &theme, cx),
                        Stage::Design => div().flex().flex_col().gap_1().child(stage_view(shown, state, &self.approvals, &theme, &cx.entity().downgrade())).child(self.security_view(state, &theme, cx)).into_any_element(),
                        _ => stage_view(shown, state, &self.approvals, &theme, &cx.entity().downgrade()),
                    })
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
                div().flex_1().min_w_0().min_h_0().flex().flex_row().child(left).child(right).into_any_element()
            }
        } };

        // The gate for the stage it's on, and the way back.
        let unmet = if self.state.is_some() { self.unmet(state, stage) } else { Vec::new() };
        let earlier: Vec<Stage> = Stage::ALL.iter().copied().filter(|s| s.index() < stage.index()).collect();
        let gate = if self.agreed.finished() {
            let url = crate::planning_docs::harness_url(&self.launch.harness_repo, &self.agreed.plan_path);
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .child(div().flex_1().min_w_0().text_xs().text_color(theme.secondary).child(format!("Agreed. The plan is {}.", self.agreed.plan_path)))
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
                .child(div().flex_1().min_w_0().text_xs().text_color(theme.secondary).child("The room's agreed the breakdown: check what gets filed, then write it all."))
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
                        .child(div().flex_1().min_w_0())
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
                        .flex_1().min_w_0()
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
            .child(div().flex_none().flex().flex_row().items_center().gap_2().px_3().py_2().border_b_1().border_color(theme.border).child(div().flex_1().min_w_0().child(stepper)).children(self.activity(&theme)))
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
                                    .flex_1().min_w_0()
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

/// Notifies the view each time a diagram finishes drawing.
fn watch_diagrams(cx: &mut Context<PlanningPanel>) -> Task<()> {
    cx.spawn(async move |this, cx| {
        let mut seen = crate::mermaid::generation();
        loop {
            cx.background_executor().timer(Duration::from_millis(800)).await;
            let now = crate::mermaid::generation();
            if now != seen {
                seen = now;
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    return;
                }
            }
        }
    })
}

/// A Mermaid diagram, drawn (click to open it large in the panel), being
/// drawn, or its source with why it couldn't be.
fn diagram(id: &str, title: &str, source: &str, theme: &Theme, panel: &gpui::WeakEntity<PlanningPanel>) -> gpui::AnyElement {
    let code = |key: &str| markdown(&format!("{id}-{key}"), &format!("```mermaid\n{}\n```", source.trim()), theme);
    match crate::mermaid::diagram(source, theme.dark) {
        crate::mermaid::Diagram::Drawn(path, w, h) => {
            let (panel, open) = (panel.clone(), Enlarged { title: title.to_string(), path: path.clone(), size: (w, h), fit: true });
            div()
                .id(SharedString::from(format!("{id}-drawn")))
                .flex()
                .flex_row()
                .p_2()
                .rounded_md()
                .bg(if theme.dark { theme.tile } else { gpui::white() })
                .cursor_pointer()
                .on_click(move |_, _, cx| {
                    let _ = panel.update(cx, |this, cx| {
                        this.enlarged = Some(open.clone());
                        cx.notify();
                    });
                })
                .child(gpui::img(path).w(px(w)).h(px(h)).max_w_full().object_fit(gpui::ObjectFit::Contain))
                .into_any_element()
        }
        crate::mermaid::Diagram::Drawing => div()
            .flex()
            .flex_col()
            .gap_1()
            .child(div().flex().flex_row().items_center().gap_1p5().text_xs().text_color(theme.secondary).child(spinner_keyed(SharedString::from(format!("{id}-spin")), px(11.), theme.secondary)).child("Drawing the diagram (the first one takes a minute)"))
            .child(code("code"))
            .into_any_element(),
        crate::mermaid::Diagram::Failed(why) => {
            let source = source.to_string();
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(div().flex_1().min_w_0().text_xs().text_color(theme.orange()).child(format!("Couldn't draw it: {why}")))
                        .child(button(SharedString::from(format!("{id}-retry")), "Try Again", false, theme).on_click(move |_, _, _| crate::mermaid::retry(&source))),
                )
                .child(code("code"))
                .into_any_element()
        }
    }
}

fn spinner_keyed(id: SharedString, size: gpui::Pixels, tint: gpui::Hsla) -> gpui::AnyElement {
    gpui::svg()
        .path("icons/arrow_circle.svg")
        .size(size)
        .flex_none()
        .text_color(tint)
        .with_animation(id, Animation::new(Duration::from_millis(1200)).repeat(), |svg, delta| svg.with_transformation(Transformation::rotate(gpui::percentage(delta))))
        .into_any_element()
}

fn spinner(id: &'static str, size: gpui::Pixels, tint: gpui::Hsla) -> gpui::AnyElement {
    gpui::svg()
        .path("icons/arrow_circle.svg")
        .size(size)
        .flex_none()
        .text_color(tint)
        .with_animation(id, Animation::new(Duration::from_millis(1200)).repeat(), |svg, delta| svg.with_transformation(Transformation::rotate(gpui::percentage(delta))))
        .into_any_element()
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
    div().flex().flex_row().gap_2().child(div().w(px(28.)).flex_none().text_color(tint).child(id.to_string())).child(div().flex_1().min_w_0().child(text.to_string()))
}

/// What's happening now: the question waiting for the room, what claude's
/// reading, or that it's the room's turn to say whether the stage is right.
fn now_box(state: &State, preview: bool, theme: &Theme) -> Option<gpui::AnyElement> {
    let boxed = || div().flex().flex_col().gap_1().p_3().rounded_md().border_1().border_color(theme.selected.opacity(0.5)).bg(theme.selected.opacity(0.06));
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
fn stage_view(stage: Stage, state: &State, _approvals: &Approvals, theme: &Theme, panel: &gpui::WeakEntity<PlanningPanel>) -> gpui::AnyElement {
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
            .when(!state.architecture.is_empty(), |d| d.child(heading("Architecture it changes", theme)).children(state.architecture.iter().enumerate().map(|(i, a)| architecture(i, a, theme, panel))))
            .when(state.approach.is_empty() && state.scouting.is_empty(), |d| d.child(nothing("the design")))
            .into_any_element(),
        // Drawn by the panel, which handles its clicks.
        Stage::Shape => col.into_any_element(),
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

/// An architecture document the design changes: which, what changes, and
/// the changed diagram's source (planned parts dashed once it's drawn).
fn architecture(i: usize, a: &planning::ArchChange, theme: &Theme, panel: &gpui::WeakEntity<PlanningPanel>) -> gpui::Div {
    div()
        .flex()
        .flex_col()
        .gap_1()
        .py_1()
        .child(
            div()
                .flex()
                .flex_row()
                .gap_2()
                .items_center()
                .child(div().text_xs().text_color(if a.valid() { theme.selected } else { theme.orange() }).child(a.path.clone()))
                .when(a.new, |d| d.child(div().px_1p5().rounded_md().text_xs().bg(theme.tile).child("New"))),
        )
        .when(!a.note.is_empty(), |d| d.child(div().text_sm().child(a.note.clone())))
        .when(!a.diagram.trim().is_empty(), |d| d.child(diagram(&format!("plan-architecture-{i}"), &a.path, &a.diagram, theme, panel)))
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
                .flex_1().min_w_0()
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
                    .child(div().flex_1().min_w_0().font_weight(FontWeight::MEDIUM).child(if task.title.is_empty() { "Untitled".to_string() } else { task.title.clone() })),
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
    if shows(Stage::Shape) && !state.shape.is_empty() {
        any = true;
        let screens = state.shape.screens.len();
        col = col
            .child(section(Stage::Shape))
            .children(state.shape.flows.iter().map(|f| ided(&f.id, &f.title, theme.selected).text_sm()))
            .when(screens > 0, |d| d.child(small(format!("{screens} screen{}", if screens == 1 { "" } else { "s" }))));
    }
    if shows(Stage::Design) && !state.approach.is_empty() {
        any = true;
        let first = state.approach.split("\n\n").next().unwrap_or_default().to_string();
        let risks = state.scouting.iter().filter(|f| f.kind.eq_ignore_ascii_case("risk")).count();
        col = col
            .child(section(Stage::Design))
            .child(small(first))
            .when(risks > 0, |d| d.child(div().text_xs().text_color(theme.orange()).child(format!("{risks} risk{} found in the code", if risks == 1 { "" } else { "s" }))))
            .when(!state.architecture.is_empty(), |d| d.child(small(format!("Changes {}", state.architecture.iter().map(|a| a.path.trim().trim_start_matches("architecture/").trim_end_matches(".md").to_string()).collect::<Vec<_>>().join(", ")))));
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
