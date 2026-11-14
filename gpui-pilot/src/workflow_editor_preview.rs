//! Workflows Preview: the editor for Work on This workflows (see
//! docs/workflows.md), from made-up ones, to shape before it's wired. A
//! workflow is five stages in order (Prepare, Session, Local review, On
//! the PR, Done), each a column of step cards; a step is set in the
//! inspector on the right. Beneath: routing rules and the most passes it
//! can make. Nothing is saved.

use crate::charts::Theme;
use gpui::{div, prelude::*, px, ClickEvent, Context, FontWeight, Hsla, SharedString, Window};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Stage {
    Prepare,
    Session,
    Local,
    Pr,
    Done,
}

impl Stage {
    const ALL: [Stage; 5] = [Stage::Prepare, Stage::Session, Stage::Local, Stage::Pr, Stage::Done];

    fn title(self) -> &'static str {
        match self {
            Stage::Prepare => "Prepare",
            Stage::Session => "Session",
            Stage::Local => "Local review",
            Stage::Pr => "On the PR",
            Stage::Done => "Done",
        }
    }

    fn caption(self) -> &'static str {
        match self {
            Stage::Prepare => "Once, before the session; what they write goes in its brief",
            Stage::Session => "The Claude Code session you talk to",
            Stage::Local => "Holds the push until it's clear; the session is told about it",
            Stage::Pr => "On the open pull request",
            Stage::Done => "PR open, checks passing, bot comments dealt with",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Provider {
    Claude,
    Junie,
    Command,
}

impl Provider {
    fn title(self) -> &'static str {
        match self {
            Provider::Claude => "Claude Code",
            Provider::Junie => "Junie",
            Provider::Command => "Command",
        }
    }
}

#[derive(Clone)]
struct Step {
    id: usize,
    stage: Stage,
    name: String,
    specialist: Option<String>,
    provider: Provider,
    model: String,
    focus: String,
    rounds: u32,
    /// A command step's command.
    command: String,
    /// For a local reviewer: what holds the gate.
    holds: &'static str,
}

#[derive(Clone)]
struct Workflow {
    name: String,
    whose: &'static str,
    steps: Vec<Step>,
}

fn workflows() -> Vec<Workflow> {
    let step = |id, stage, name: &str, specialist: Option<&str>, provider, rounds, command: &str| Step {
        id,
        stage,
        name: name.into(),
        specialist: specialist.map(str::to_string),
        provider,
        model: if provider == Provider::Claude { "Each person's".into() } else { String::new() },
        focus: String::new(),
        rounds,
        command: command.into(),
        holds: "Blockers and majors",
    };
    vec![
        Workflow { name: "Gannin's".into(), whose: "Gannin's", steps: vec![step(0, Stage::Session, "Session", None, Provider::Claude, 0, "")] },
        Workflow {
            name: "Careful".into(),
            whose: "Team",
            steps: vec![
                step(1, Stage::Prepare, "Scout", Some("scout"), Provider::Claude, 1, ""),
                step(2, Stage::Session, "Session", None, Provider::Claude, 0, ""),
                step(3, Stage::Local, "Correctness reviewer", Some("correctness"), Provider::Claude, 3, ""),
                step(4, Stage::Local, "Junie", None, Provider::Junie, 2, ""),
                step(5, Stage::Local, "cargo test", None, Provider::Command, 0, "cargo test"),
                step(6, Stage::Local, "cargo clippy", None, Provider::Command, 0, "cargo clippy -- -D warnings"),
                step(7, Stage::Pr, "Security reviewer", Some("security"), Provider::Claude, 1, ""),
                step(8, Stage::Pr, "Bot comments", None, Provider::Claude, 0, ""),
            ],
        },
        Workflow {
            name: "Quick fix".into(),
            whose: "Just me",
            steps: vec![
                step(9, Stage::Session, "Session", None, Provider::Claude, 0, ""),
                step(10, Stage::Local, "npm test", None, Provider::Command, 0, "npm test"),
                step(11, Stage::Pr, "Bot comments", None, Provider::Claude, 0, ""),
            ],
        },
    ]
}

pub struct WorkflowEditorPreview {
    workflows: Vec<Workflow>,
    current: usize,
    selected: Option<usize>,
    next_id: usize,
}

impl WorkflowEditorPreview {
    pub fn new(_: &mut Window, _: &mut Context<Self>) -> Self {
        Self { workflows: workflows(), current: 1, selected: Some(3), next_id: 100 }
    }

    fn button(id: impl Into<SharedString>, label: impl Into<SharedString>, on: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(gpui::ElementId::Name(id.into()))
            .flex_none()
            .px_2()
            .py_0p5()
            .rounded_md()
            .text_sm()
            .cursor_pointer()
            .border_1()
            .border_color(if on { theme.selected } else { theme.border })
            .when(on, |d| d.bg(theme.selected.opacity(0.15)).text_color(theme.selected))
            .hover(|s| s.bg(theme.row_selected))
            .child(label.into())
    }

    fn provider_tint(provider: Provider, theme: &Theme) -> Hsla {
        match provider {
            Provider::Claude => theme.blue(),
            Provider::Junie => gpui::rgb(0xA259FF).into(),
            Provider::Command => theme.secondary,
        }
    }

    fn toolbar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let wf = &self.workflows[self.current];
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
            .bg(theme.sidebar)
            .child(div().text_sm().text_color(theme.secondary).child("Work on This"))
            .children(self.workflows.iter().enumerate().map(|(i, w)| {
                Self::button(format!("wf-{i}"), w.name.clone(), i == self.current, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.current = i;
                    this.selected = None;
                    cx.notify();
                }))
            }))
            .child(div().px_1p5().rounded_full().text_xs().bg(theme.grid).child(wf.whose))
            .child(div().flex_1())
            .child(Self::button("wf-new", "New", false, theme))
            .child(Self::button("wf-duplicate", "Duplicate", false, theme))
            .child(Self::button("wf-default", "Make My Default", false, theme))
    }

    fn canvas(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let wf = &self.workflows[self.current];
        let fixed = wf.whose == "Gannin's";
        div()
            .id("wf-canvas")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p_4()
            .flex()
            .flex_row()
            .gap_3()
            .children(Stage::ALL.into_iter().enumerate().map(|(si, stage)| {
                let steps: Vec<&Step> = wf.steps.iter().filter(|s| s.stage == stage).collect();
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .child(div().flex().flex_row().items_center().gap_1p5().child(div().text_xs().text_color(theme.tertiary).child(format!("{}", si + 1))).child(div().font_weight(FontWeight::SEMIBOLD).child(stage.title())))
                            .child(div().text_xs().text_color(theme.secondary).child(stage.caption())),
                    )
                    .children(steps.into_iter().map(|step| {
                        let on = self.selected == Some(step.id);
                        let id = step.id;
                        let tint = Self::provider_tint(step.provider, theme);
                        div()
                            .id(SharedString::from(format!("step-{}", step.id)))
                            .flex()
                            .flex_col()
                            .gap_1()
                            .p(px(10.))
                            .rounded_lg()
                            .cursor_pointer()
                            .bg(theme.bg)
                            .border_1()
                            .border_color(if on { theme.selected } else { theme.border })
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.selected = Some(id);
                                cx.notify();
                            }))
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap_1p5()
                                    .child(div().size(px(7.)).rounded_full().bg(tint))
                                    .child(div().flex_1().truncate().font_weight(FontWeight::MEDIUM).child(step.name.clone()))
                                    .when(stage == Stage::Session, |d| d.child(div().px_1p5().rounded_full().text_xs().bg(theme.selected.opacity(0.18)).text_color(theme.selected).child("Session"))),
                            )
                            .child(div().text_xs().text_color(theme.secondary).child(match step.provider {
                                Provider::Command => step.command.clone(),
                                _ => format!(
                                    "{}{}{}",
                                    step.provider.title(),
                                    step.specialist.as_ref().map(|s| format!(" · {s}")).unwrap_or_default(),
                                    if step.rounds > 1 { format!(" · up to {} rounds", step.rounds) } else { String::new() }
                                ),
                            }))
                    }))
                    .when(!fixed && !matches!(stage, Stage::Session | Stage::Done), |d| {
                        d.child(
                            div()
                                .id(SharedString::from(format!("add-{si}")))
                                .py_1()
                                .rounded_lg()
                                .border_1()
                                .border_dashed()
                                .border_color(theme.border)
                                .flex()
                                .justify_center()
                                .text_sm()
                                .text_color(theme.secondary)
                                .cursor_pointer()
                                .hover(|s| s.bg(theme.row_selected))
                                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                    let id = this.next_id;
                                    this.next_id += 1;
                                    let current = this.current;
                                    this.workflows[current].steps.push(Step {
                                        id,
                                        stage,
                                        name: if stage == Stage::Local { "New reviewer".into() } else { "New step".into() },
                                        specialist: None,
                                        provider: Provider::Claude,
                                        model: "Each person's".into(),
                                        focus: String::new(),
                                        rounds: 1,
                                        command: String::new(),
                                        holds: "Blockers and majors",
                                    });
                                    this.selected = Some(id);
                                    cx.notify();
                                }))
                                .child("+ Step"),
                        )
                    })
            }))
    }

    fn footer(&self, theme: &Theme) -> impl IntoElement {
        let wf = &self.workflows[self.current];
        let passes: u32 = wf.steps.iter().filter(|s| s.provider != Provider::Command).map(|s| s.rounds.max(1)).sum();
        let commands = wf.steps.iter().filter(|s| s.provider == Provider::Command).count();
        div()
            .flex_none()
            .flex()
            .flex_col()
            .gap_2()
            .px_4()
            .py_3()
            .border_t_1()
            .border_color(theme.border)
            .child(div().text_sm().text_color(theme.secondary).child(format!(
                "At most {passes} agent passes{}, besides the session's own turns.",
                if commands > 0 { format!(" and {commands} command{} each round", if commands == 1 { "" } else { "s" }) } else { String::new() }
            )))
            .child(div().font_weight(FontWeight::SEMIBOLD).text_sm().child("Routing"))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .text_sm()
                    .child(div().flex().flex_row().gap_2().child(div().w(px(80.)).text_color(theme.secondary).child("Mine")).child("Repos: api, billing → Careful"))
                    .child(div().flex().flex_row().gap_2().child(div().w(px(80.)).text_color(theme.secondary).child("The team's")).child("Labels: hotfix → Quick fix")),
            )
    }

    fn inspector(&self, theme: &Theme, cx: &mut Context<Self>) -> Option<impl IntoElement> {
        let wf = &self.workflows[self.current];
        let step = wf.steps.iter().find(|s| Some(s.id) == self.selected)?.clone();
        let fixed = wf.whose == "Gannin's";
        let field = |label: &str, value: String| {
            div().flex().flex_col().gap_0p5().child(div().text_xs().text_color(theme.secondary).child(label.to_string())).child(div().px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).text_sm().child(value))
        };
        let id = step.id;
        let providers = div().flex().flex_row().gap_1().children([Provider::Claude, Provider::Junie, Provider::Command].map(|p| {
            Self::button(format!("prov-{}", p.title()), p.title(), step.provider == p, theme).when(!fixed && step.stage != Stage::Session, |b| {
                b.on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    let current = this.current;
                    if let Some(s) = this.workflows[current].steps.iter_mut().find(|s| s.id == id) {
                        s.provider = p;
                        if p == Provider::Command && s.command.is_empty() {
                            s.command = "npm test".into();
                            s.name = "npm test".into();
                        }
                    }
                    cx.notify();
                }))
            })
        }));
        Some(
            div()
                .flex()
                .flex_col()
                .gap_3()
                .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(step.name.clone()))
                .child(div().text_xs().text_color(theme.secondary).child(format!("{} stage", step.stage.title())))
                .child(div().flex().flex_col().gap_0p5().child(div().text_xs().text_color(theme.secondary).child("Provider")).child(providers))
                .map(|d| match step.provider {
                    Provider::Command => d
                        .child(field("Command", step.command.clone()))
                        .child(div().text_xs().text_color(theme.secondary).child("Must pass before the push. The session's brief lists it, exactly as it runs, so it runs it as it works.")),
                    _ => d
                        .child(field("Specialist", step.specialist.clone().unwrap_or_else(|| "None (Gannin's own prompt)".into())))
                        .when(step.provider == Provider::Claude, |d| d.child(field("Model", step.model.clone())))
                        .child(field("Focus", if step.focus.is_empty() { "None".into() } else { step.focus.clone() }))
                        .when(step.stage != Stage::Session, |d| d.child(field("Rounds", format!("Up to {}", step.rounds.max(1))))),
                })
                .when(step.stage == Stage::Local && step.provider != Provider::Command, |d| {
                    d.child(field("Holds the push on", step.holds.to_string()))
                        .child(div().text_xs().text_color(theme.secondary).child("Minors and nits go to the session once, as suggestions, without another round."))
                })
                .when(!fixed && step.stage != Stage::Session, |d| {
                    d.child(Self::button("remove-step", "Remove Step", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        let current = this.current;
                        this.workflows[current].steps.retain(|s| s.id != id);
                        this.selected = None;
                        cx.notify();
                    })))
                })
                .when(fixed, |d| d.child(div().text_xs().text_color(theme.secondary).child("Gannin's workflow can't be changed: Duplicate it to make your own."))),
        )
    }
}

impl Render for WorkflowEditorPreview {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let inspector = self.inspector(&theme, cx);
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .child(self.toolbar(&theme, cx))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_row()
                    .child(div().flex_1().min_w_0().flex().flex_col().child(self.canvas(&theme, cx)).child(self.footer(&theme)))
                    .when_some(inspector, |d, inspector| {
                        d.child(div().id("wf-inspector").w(px(300.)).flex_none().h_full().overflow_y_scroll().p_4().border_l_1().border_color(theme.border).bg(theme.sidebar).child(inspector))
                    }),
            )
    }
}
