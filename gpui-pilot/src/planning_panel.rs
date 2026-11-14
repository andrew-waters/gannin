//! A planning session's workspace beside its terminal, after Gannin's
//! `PlanningWorkspaceView`: the stages as a stepper, then what claude keeps
//! in `planning.json` (the requirement, the design, the tasks and the
//! decisions), and a box for the room to interject ("From the room, on
//! <stage>: ..."). The file is read leniently, so an unknown stage or a
//! missing field never loses the rest. Agree (filing the issues and writing
//! the plan) isn't here: it writes to GitHub and the harness.

use crate::charts::Theme;
use crate::launch::Launch;
use crate::markdown::markdown;
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, FontWeight, KeyDownEvent, Task, Window};
use serde_json::Value;
use std::time::Duration;
use terminal::Terminal;

const STAGES: [(&str, &str); 5] = [("context", "Context"), ("requirements", "Requirements"), ("design", "Design"), ("tasks", "Tasks"), ("ready", "Agree")];

pub struct PlanningPanel {
    launch: Launch,
    terminal: Entity<Terminal>,
    state: Option<Value>,
    comment: Entity<editor::Editor>,
    _poll: Task<()>,
}

impl PlanningPanel {
    pub fn new(launch: Launch, terminal: Entity<Terminal>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let path = launch.folder().join("planning.json");
        // Re-read every few seconds, off the main thread.
        let poll = cx.spawn(async move |this, cx| loop {
            let file = path.clone();
            let state = cx
                .background_executor()
                .spawn(async move { std::fs::read(&file).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) })
                .await;
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
        Self { launch, terminal, state: None, comment, _poll: poll }
    }

    /// The stage claude says it's on, read leniently.
    fn phase(&self) -> &str {
        self.state.as_ref().and_then(|s| s["phase"].as_str()).filter(|p| STAGES.iter().any(|(k, _)| k == p)).unwrap_or("requirements")
    }

    /// Sends the room's comment: Esc first when a question is waiting, as
    /// Gannin answers, then the text as one message.
    fn send_comment(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.comment.read(cx).text(cx).trim().to_string();
        if text.is_empty() {
            return;
        }
        let stage = STAGES.iter().find(|(k, _)| *k == self.phase()).map(|(_, t)| *t).unwrap_or("Requirements");
        let message = format!("From the room, on {}: {text}", stage.to_lowercase());
        let waiting = self.launch.state().as_deref() == Some("needs-you");
        let terminal = self.terminal.clone();
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
        self.comment.update(cx, |editor, cx| editor.set_text("", window, cx));
    }
}

fn strings(value: &Value) -> Vec<String> {
    value.as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default()
}

impl Render for PlanningPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let phase = self.phase().to_string();
        let current = STAGES.iter().position(|(k, _)| *k == phase).unwrap_or(1);
        let heading = |text: &str| div().pt_2().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(text.to_string());
        let quiet = |text: String| div().text_xs().text_color(theme.secondary).child(text);
        let stepper = div().flex().flex_row().items_center().gap_1().children(STAGES.iter().enumerate().map(|(i, (_, title))| {
            let (bg, fg) = if i == current {
                (theme.selected, theme.on_selected)
            } else if i < current {
                (theme.selected.opacity(0.18), theme.selected)
            } else {
                (theme.tile, theme.secondary)
            };
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_1()
                .when(i > 0, |d| d.child(div().text_color(theme.tertiary).child("›")))
                .child(div().px_2().py_0p5().rounded_full().text_xs().bg(bg).text_color(fg).child(*title))
        }));

        let body = match &self.state {
            None => quiet("Claude keeps the plan in planning.json as the room answers; it shows here once it starts.".into()).into_any_element(),
            Some(state) => {
                let requirement = &state["requirement"];
                let field = |label: &str, value: &Value| {
                    value.as_str().filter(|s| !s.is_empty()).map(|text| div().flex().flex_col().child(heading(label)).child(text.to_string()))
                };
                let list = |label: &str, value: &Value| {
                    let items = strings(value);
                    (!items.is_empty()).then(|| div().flex().flex_col().child(heading(label)).children(items.into_iter().map(|i| div().child(format!("• {i}")))))
                };
                let acceptance: Vec<(String, String)> = requirement["acceptance"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|c| Some((c["id"].as_str()?.to_string(), c["text"].as_str()?.to_string()))).collect())
                    .unwrap_or_default();
                let tasks: Vec<&Value> = state["tasks"].as_array().map(|t| t.iter().collect()).unwrap_or_default();
                let decisions: Vec<&Value> = state["decisions"].as_array().map(|t| t.iter().collect()).unwrap_or_default();
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .when_some(state["title"].as_str(), |d, t| d.child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(t.to_string())))
                    .when_some(state["summary"].as_str(), |d, s| d.child(div().text_color(theme.secondary).child(s.to_string())))
                    .children(field("Problem", &requirement["problem"]))
                    .children(field("Goal", &requirement["goal"]))
                    .children(field("Users", &requirement["users"]))
                    .children(list("Scope", &requirement["scope"]))
                    .children(list("Not doing", &requirement["non_goals"]))
                    .when(!acceptance.is_empty(), |d| {
                        d.child(heading("Acceptance criteria")).children(acceptance.into_iter().map(|(id, text)| {
                            div().flex().flex_row().gap_2().child(div().w(px(28.)).flex_none().text_color(theme.selected).child(id)).child(div().flex_1().child(text))
                        }))
                    })
                    .children(list("Open questions", &requirement["open_questions"]))
                    .when_some(state["design"]["approach"].as_str().filter(|s| !s.is_empty()), |d, approach| {
                        d.child(heading("Design")).child(markdown("plan-design", approach, &theme))
                    })
                    .when_some(state["scouting_now"]["why"].as_str(), |d, why| d.child(quiet(format!("Looking at the code: {why}"))))
                    .when(!tasks.is_empty(), |d| {
                        d.child(heading(&format!("Tasks · {}", tasks.len()))).children(tasks.into_iter().enumerate().map(|(i, task)| {
                            let satisfies = strings(&task["satisfies"]).join(", ");
                            div()
                                .flex()
                                .flex_col()
                                .gap_0p5()
                                .p_2()
                                .rounded_md()
                                .border_1()
                                .border_color(theme.border)
                                .child(div().font_weight(FontWeight::MEDIUM).child(task["title"].as_str().unwrap_or("Task").to_string()))
                                .child(quiet(format!(
                                    "{}{}",
                                    task["repo"].as_str().unwrap_or(""),
                                    if satisfies.is_empty() { String::new() } else { format!(" · Satisfies {satisfies}") }
                                )))
                                .when_some(task["body"].as_str(), |d, b| d.child(markdown(&format!("plan-task-{i}"), b, &theme)))
                        }))
                    })
                    .when(!decisions.is_empty(), |d| {
                        d.child(heading("Decisions")).children(decisions.into_iter().map(|decision| {
                            div()
                                .flex()
                                .flex_col()
                                .child(div().text_color(theme.secondary).child(decision["question"].as_str().unwrap_or("").to_string()))
                                .child(decision["answer"].as_str().unwrap_or("").to_string())
                        }))
                    })
                    .into_any_element()
            }
        };

        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .child(div().flex_none().px_3().py_2().border_b_1().border_color(theme.border).child(stepper))
            .child(div().id("plan-body").flex_1().min_h_0().overflow_y_scroll().p_4().child(body))
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .px_3()
                    .py_2()
                    .border_t_1()
                    .border_color(theme.border)
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
                    .child(
                        div()
                            .id("plan-send")
                            .px_2()
                            .py_0p5()
                            .rounded_md()
                            .bg(theme.selected)
                            .text_color(theme.on_selected)
                            .cursor_pointer()
                            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.send_comment(window, cx)))
                            .child("Send"),
                    ),
            )
    }
}
