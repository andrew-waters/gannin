//! Workflows: the editor for Work on This workflows (docs/workflows.md), on
//! the project's harness. Gannin's own can't be changed; yours ("Just
//! me") save on this Mac as you edit; the team's wait as changes until
//! Commit to Harness, which asks first and commits through GitHub's API,
//! merged onto the harness's copy by workflow id. A workflow is laid out
//! as its five stages, each a column of steps; a step is set in the
//! inspector, and with none picked the inspector holds the workflow's own
//! settings.

use crate::charts::Theme;
use crate::workflows::{self, Offered, Specialist, Stage, Step, When, Whose, Workflow};
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, FontWeight, Hsla, SharedString, Subscription, Window};
use std::path::PathBuf;

const ACTIVITY: &str = "work";
const COLUMNS: [(When, &str, &str); 4] = [
    (When::Prepare, "Prepare", "Once, before the session; what they write goes in its brief"),
    (When::Session, "Session", "The Claude Code session you talk to"),
    (When::Local, "Local review", "Holds the push until it's clear; the session is told about it"),
    (When::Pr, "On the PR", "On the open pull request"),
];
const MODELS: [(&str, Option<&str>); 4] = [("Each person's", None), ("Opus", Some("opus")), ("Sonnet", Some("sonnet")), ("Haiku", Some("haiku"))];

pub struct WorkflowsPage {
    org: Option<String>,
    harness_repo: Option<String>,
    harness: Option<PathBuf>,
    offered: Vec<Offered>,
    specialists: Vec<Specialist>,
    current: usize,
    selected: Option<String>,
    /// Team workflows changed here and not committed yet, by id.
    team_changes: Vec<Workflow>,
    default_id: String,
    note: Option<String>,
    /// The inspector's text fields, for the step (or workflow) showing.
    name_field: Entity<editor::Editor>,
    command_field: Entity<editor::Editor>,
    focus_field: Entity<editor::Editor>,
    _fields: Vec<Subscription>,
}

fn field(placeholder: &str, window: &mut Window, cx: &mut Context<WorkflowsPage>) -> Entity<editor::Editor> {
    let placeholder = placeholder.to_string();
    cx.new(|cx| {
        let mut editor = editor::Editor::single_line(window, cx);
        editor.set_placeholder_text(&placeholder, window, cx);
        editor
    })
}

impl WorkflowsPage {
    pub fn new(org: Option<String>, harness_repo: Option<String>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let name_field = field("Name", window, cx);
        let command_field = field("npm test", window, cx);
        let focus_field = field("What to look for, in a few words", window, cx);
        let subs = vec![
            cx.observe(&name_field, |this, f, cx| {
                let text = f.read(cx).text(cx);
                this.edit(cx, |w, _| {
                    if !text.trim().is_empty() {
                        w.name = text.trim().to_string()
                    }
                });
            }),
            cx.observe(&command_field, |this, f, cx| {
                let text = f.read(cx).text(cx);
                this.edit_step(cx, |s| {
                    if s.command.is_some() {
                        s.command = Some(text.clone())
                    }
                });
            }),
            cx.observe(&focus_field, |this, f, cx| {
                let text = f.read(cx).text(cx);
                this.edit_step(cx, |s| s.focus = (!text.trim().is_empty()).then(|| text.trim().to_string()));
            }),
        ];
        let mut page = Self {
            org: None,
            harness_repo: None,
            harness: None,
            offered: Vec::new(),
            specialists: Vec::new(),
            current: 0,
            selected: None,
            team_changes: Vec::new(),
            default_id: workflows::BUILT_IN.into(),
            note: None,
            name_field,
            command_field,
            focus_field,
            _fields: subs,
        };
        page.set_project(org, harness_repo, cx);
        page
    }

    /// The window's org and project: which harness's workflows.
    pub fn set_project(&mut self, org: Option<String>, harness_repo: Option<String>, cx: &mut Context<Self>) {
        self.harness = match (&org, &harness_repo) {
            (Some(org), Some(repo)) => Some(crate::launch::harness_path(org, repo)),
            _ => None,
        };
        self.org = org;
        self.harness_repo = harness_repo;
        self.reload(cx);
    }

    pub fn reload(&mut self, cx: &mut Context<Self>) {
        let keep = self.offered.get(self.current).map(|o| o.workflow.id.clone());
        self.offered = workflows::offered(ACTIVITY, self.harness.as_deref());
        // Team edits not committed yet stay in place of the harness's copy.
        for change in &self.team_changes {
            if let Some(o) = self.offered.iter_mut().find(|o| o.whose == Whose::Team && o.workflow.id == change.id) {
                o.workflow = change.clone();
            }
        }
        self.specialists = self.harness.as_deref().map(workflows::specialists).unwrap_or_default();
        self.default_id = workflows::default_for(ACTIVITY, self.harness.as_deref()).id;
        self.current = keep.and_then(|id| self.offered.iter().position(|o| o.workflow.id == id)).unwrap_or(0);
        cx.notify();
    }

    fn whose(&self) -> Whose {
        self.offered.get(self.current).map(|o| o.whose).unwrap_or(Whose::Gannin)
    }

    fn workflow(&self) -> Option<&Workflow> {
        self.offered.get(self.current).map(|o| &o.workflow)
    }

    fn step(&self) -> Option<&Step> {
        let id = self.selected.as_ref()?;
        self.workflow()?.stages.iter().flat_map(|s| s.steps.iter()).find(|s| &s.id == id)
    }

    /// Changes the workflow showing: yours save now, the team's wait.
    fn edit(&mut self, cx: &mut Context<Self>, change: impl FnOnce(&mut Workflow, &[Specialist])) {
        let whose = self.whose();
        if whose == Whose::Gannin {
            return;
        }
        let specialists = self.specialists.clone();
        let Some(offered) = self.offered.get_mut(self.current) else { return };
        let before = offered.workflow.clone();
        change(&mut offered.workflow, &specialists);
        if offered.workflow == before {
            return;
        }
        let workflow = offered.workflow.clone();
        match whose {
            Whose::Mine => {
                if let Err(e) = workflows::save_mine(ACTIVITY, &workflow) {
                    self.note = Some(format!("Couldn't save it: {e}"));
                }
            }
            Whose::Team => {
                self.team_changes.retain(|w| w.id != workflow.id);
                self.team_changes.push(workflow);
            }
            Whose::Gannin => {}
        }
        cx.notify();
    }

    fn edit_step(&mut self, cx: &mut Context<Self>, change: impl FnOnce(&mut Step)) {
        let Some(id) = self.selected.clone() else { return };
        self.edit(cx, |w, _| {
            if let Some(step) = w.stages.iter_mut().flat_map(|s| s.steps.iter_mut()).find(|s| s.id == id) {
                change(step);
            }
        });
    }

    fn select(&mut self, id: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        self.selected = id;
        let (command, focus) = self.step().map(|s| (s.command.clone().unwrap_or_default(), s.focus.clone().unwrap_or_default())).unwrap_or_default();
        let name = self.workflow().map(|w| w.name.clone()).unwrap_or_default();
        self.name_field.update(cx, |e, cx| e.set_text(name, window, cx));
        self.command_field.update(cx, |e, cx| e.set_text(command, window, cx));
        self.focus_field.update(cx, |e, cx| e.set_text(focus, window, cx));
        cx.notify();
    }

    fn add_step(&mut self, when: When, window: &mut Window, cx: &mut Context<Self>) {
        let id = workflows::new_id();
        let new_id = id.clone();
        self.edit(cx, move |w, _| {
            let mut step = Step { id: new_id, ..Default::default() };
            if when == When::Local {
                step.rounds = Some(3);
                step.holds = Some("blocker-major".into());
            }
            let staged: Vec<When> = w.staged().iter().map(|(k, _)| *k).collect();
            match staged.iter().rposition(|k| *k == when) {
                Some(at) => w.stages[at].steps.push(step),
                None => {
                    // A stage of its own, in order among the others.
                    let at = staged.iter().position(|k| *k > when).unwrap_or(w.stages.len());
                    w.stages.insert(at, Stage { id: workflows::new_id(), when: Some(when.key().into()), steps: vec![step], extra: Default::default() });
                }
            }
            // Stages say when they run, so a new one isn't read by position.
            let kinds: Vec<When> = w.staged().iter().map(|(k, _)| *k).collect();
            for (stage, kind) in w.stages.iter_mut().zip(kinds) {
                stage.when.get_or_insert_with(|| kind.key().to_string());
            }
        });
        self.select(Some(id), window, cx);
    }

    fn remove_step(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.selected.clone() else { return };
        self.edit(cx, |w, _| {
            for stage in &mut w.stages {
                stage.steps.retain(|s| s.id != id || s.is_session());
            }
            w.stages.retain(|s| !s.steps.is_empty());
        });
        self.select(None, window, cx);
    }

    /// A new one of your own, from Gannin's (New) or the one showing
    /// (Duplicate).
    fn make_mine(&mut self, copy: bool, window: &mut Window, cx: &mut Context<Self>) {
        let mut workflow = if copy { self.workflow().cloned().unwrap_or_else(Workflow::built_in) } else { Workflow::built_in() };
        workflow.id = workflows::new_id();
        workflow.name = if copy { format!("{} copy", workflow.name) } else { "My workflow".into() };
        for stage in &mut workflow.stages {
            stage.id = workflows::new_id();
            for step in &mut stage.steps {
                step.id = workflows::new_id();
            }
        }
        if let Err(e) = workflows::save_mine(ACTIVITY, &workflow) {
            self.note = Some(format!("Couldn't save it: {e}"));
        }
        self.reload(cx);
        self.current = self.offered.iter().position(|o| o.workflow.id == workflow.id).unwrap_or(0);
        self.select(None, window, cx);
    }

    fn delete_mine(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.workflow().map(|w| w.id.clone()) else { return };
        let answer = window.prompt(gpui::PromptLevel::Warning, "Delete this workflow?", Some("It's yours, on this Mac only."), &["Delete", "Cancel"], cx);
        cx.spawn_in(window, async move |this, cx| {
            if answer.await == Ok(0) {
                let _ = workflows::delete_mine(ACTIVITY, &id);
                this.update_in(cx, |this, window, cx| {
                    this.current = 0;
                    this.reload(cx);
                    this.select(None, window, cx);
                })
                .ok();
            }
        })
        .detach();
    }

    /// Commits the team's changed workflows to the harness, after asking:
    /// each replaces its copy (by id) in the harness's file as it is at
    /// the head, so others' changes stay.
    fn commit_team(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let (Some(repo), false) = (self.harness_repo.clone(), self.team_changes.is_empty()) else { return };
        let changes = self.team_changes.clone();
        let names: Vec<String> = changes.iter().map(|w| w.name.clone()).collect();
        let answer = window.prompt(
            gpui::PromptLevel::Info,
            &format!("Commit {} to {repo}?", if names.len() == 1 { format!("\u{201c}{}\u{201d}", names[0]) } else { format!("{} workflows", names.len()) }),
            Some("One commit to .gannin/agent-workflows.json on the harness's default branch, as you. Everyone's Gannin picks it up on its next harness refresh."),
            &["Commit", "Cancel"],
            cx,
        );
        cx.spawn_in(window, async move |this, cx| {
            if answer.await != Ok(0) {
                return;
            }
            let outcome = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or("Sign in first.".to_string())?;
                    let headline = format!("Gannin: Work on This workflow{} {}", if names.len() == 1 { "" } else { "s" }, names.join(", "));
                    crate::review_record::commit_file(&token, &repo, ".gannin/agent-workflows.json", &headline, &|head| {
                        let mut library: workflows::Library = head
                            .and_then(|t| serde_json::from_str::<serde_json::Value>(t).ok())
                            .and_then(|v| v.as_object().cloned())
                            .map(|m| m.into_iter().filter_map(|(k, v)| Some((k, serde_json::from_value(v).ok()?))).collect())
                            .unwrap_or_default();
                        let activity = library.entry(ACTIVITY.into()).or_default();
                        for change in &changes {
                            match activity.workflows.iter_mut().find(|w| w.id == change.id) {
                                Some(held) => *held = change.clone(),
                                None => activity.workflows.push(change.clone()),
                            }
                        }
                        let text = workflows::encode(&library);
                        (head != Some(text.as_str())).then_some(text)
                    })
                })
                .await;
            this.update(cx, |this, cx| {
                match outcome {
                    Ok(note) => {
                        this.team_changes.clear();
                        this.note = Some(note.unwrap_or_else(|| "Committed to the harness. It shows here once the harness is pulled.".into()));
                    }
                    Err(error) => this.note = Some(format!("Couldn't commit: {error}")),
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn button(id: impl Into<SharedString>, label: impl Into<SharedString>, on: bool, enabled: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(gpui::ElementId::Name(id.into()))
            .flex_none()
            .px_2()
            .py_0p5()
            .rounded_md()
            .text_sm()
            .border_1()
            .border_color(if on { theme.selected } else { theme.border })
            .when(on, |d| d.bg(theme.selected.opacity(0.15)).text_color(theme.selected))
            .when(enabled, |d| d.cursor_pointer().hover(|s| s.bg(theme.row_selected)))
            .when(!enabled, |d| d.opacity(0.4))
            .child(label.into())
    }

    fn tint(step: &Step, theme: &Theme) -> Hsla {
        if step.command.is_some() {
            theme.secondary
        } else if step.provider.as_deref() == Some("junie") {
            gpui::rgb(0xA259FF).into()
        } else {
            theme.blue()
        }
    }

    fn toolbar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let whose = self.whose();
        let dirty = !self.team_changes.is_empty();
        div()
            .flex_none()
            .flex()
            .flex_row()
            .flex_wrap()
            .items_center()
            .gap_2()
            .px_4()
            .py_2()
            .border_b_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .child(div().text_sm().text_color(theme.secondary).child("Work on This"))
            .children(self.offered.iter().enumerate().map(|(i, o)| {
                let default = o.workflow.id == self.default_id;
                Self::button(format!("wf-{i}"), format!("{}{}", o.workflow.name, if default { " ★" } else { "" }), i == self.current, true, theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                    this.current = i;
                    this.select(None, window, cx);
                }))
            }))
            .child(div().px_1p5().rounded_full().text_xs().bg(theme.grid).child(whose.title()))
            .child(div().flex_1())
            .child(Self::button("wf-new", "New", false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.make_mine(false, window, cx))))
            .child(Self::button("wf-duplicate", "Duplicate", false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.make_mine(true, window, cx))))
            .child(Self::button("wf-default", "Make My Default", false, self.workflow().is_some_and(|w| w.id != self.default_id), theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                if let Some(id) = this.workflow().map(|w| w.id.clone()) {
                    let _ = workflows::set_default(ACTIVITY, &id);
                    this.reload(cx);
                }
            })))
            .when(dirty, |d| {
                d.child(Self::button("wf-commit", format!("Commit {} to Harness", self.team_changes.len()), true, true, theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.commit_team(window, cx))))
            })
    }

    fn canvas(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(workflow) = self.workflow().cloned() else { return div().into_any_element() };
        let editable = self.whose() != Whose::Gannin;
        let staged = workflow.staged();
        div()
            .id("wf-canvas")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p_4()
            .flex()
            .flex_row()
            .gap_3()
            .children(COLUMNS.into_iter().enumerate().map(|(ci, (when, title, caption))| {
                let steps: Vec<Step> = staged.iter().filter(|(w, _)| *w == when).flat_map(|(_, s)| s.steps.clone()).collect();
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
                            .child(div().flex().flex_row().gap_1p5().child(div().text_xs().text_color(theme.tertiary).child(format!("{}", ci + 1))).child(div().font_weight(FontWeight::SEMIBOLD).child(title)))
                            .child(div().text_xs().text_color(theme.secondary).child(caption)),
                    )
                    .children(steps.into_iter().map(|step| {
                        let on = self.selected.as_deref() == Some(step.id.as_str());
                        let id = step.id.clone();
                        let detail = match (&step.command, step.is_session()) {
                            (Some(c), _) => c.clone(),
                            (_, true) => "Claude Code".into(),
                            _ => format!("{}{}", if step.provider.as_deref() == Some("junie") { "Junie" } else { "Claude Code" }, if step.round_count() > 1 { format!(" · up to {} rounds", step.round_count()) } else { String::new() }),
                        };
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
                            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.select(Some(id.clone()), window, cx)))
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap_1p5()
                                    .child(div().size(px(7.)).rounded_full().bg(Self::tint(&step, theme)))
                                    .child(div().flex_1().truncate().font_weight(FontWeight::MEDIUM).child(step.label(&self.specialists))),
                            )
                            .child(div().text_xs().text_color(theme.secondary).truncate().child(detail))
                    }))
                    .when(editable && when != When::Session, |d| {
                        d.child(
                            div()
                                .id(SharedString::from(format!("add-{ci}")))
                                .py_1()
                                .rounded_lg()
                                .border_1()
                                .border_color(theme.border)
                                .flex()
                                .justify_center()
                                .text_sm()
                                .text_color(theme.secondary)
                                .cursor_pointer()
                                .hover(|s| s.bg(theme.row_selected))
                                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.add_step(when, window, cx)))
                                .child("+ Step"),
                        )
                    })
            }))
            .into_any_element()
    }

    fn inspector(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let editable = self.whose() != Whose::Gannin;
        let label = |text: &str| div().text_xs().text_color(theme.secondary).child(text.to_string());
        let input = |e: &Entity<editor::Editor>| div().px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).text_sm().child(e.clone());
        let chips = |items: Vec<(String, bool, Box<dyn Fn(&mut Self, &mut Context<Self>)>)>, prefix: &str, cx: &mut Context<Self>| {
            div().flex().flex_row().flex_wrap().gap_1().children(items.into_iter().enumerate().map(|(i, (name, on, act))| {
                Self::button(format!("{prefix}-{i}"), name, on, editable, theme).when(editable, |b| b.on_click(cx.listener(move |this, _: &ClickEvent, _, cx| act(this, cx))))
            }))
        };
        let Some(step) = self.step().cloned() else {
            // No step: the workflow's own settings.
            let whose = self.whose();
            return div()
                .flex()
                .flex_col()
                .gap_3()
                .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(self.workflow().map(|w| w.name.clone()).unwrap_or_default()))
                .child(div().text_sm().text_color(theme.secondary).child(match whose {
                    Whose::Gannin => "Gannin's own: the session alone, exactly as Work on This always ran. It can't be changed; Duplicate it to make your own.",
                    Whose::Mine => "Yours, on this Mac only. Changes save as you make them.",
                    Whose::Team => "The team's, in the harness. Changes wait until Commit to Harness.",
                }))
                .when(editable, |d| d.child(label("Name")).child(input(&self.name_field)))
                .child(div().text_sm().text_color(theme.secondary).child("Pick a step to set it, or + Step to add one."))
                .when(whose == Whose::Mine, |d| d.child(Self::button("wf-delete", "Delete Workflow", false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.delete_mine(window, cx)))))
                .into_any_element();
        };
        let session = step.is_session();
        let local = self.workflow().is_some_and(|w| w.staged().iter().any(|(k, s)| *k == When::Local && s.steps.iter().any(|x| x.id == step.id)));
        let provider = if step.command.is_some() { 2 } else if step.provider.as_deref() == Some("junie") { 1 } else { 0 };
        let providers = chips(
            vec![
                ("Claude Code".into(), provider == 0, Box::new(|this: &mut Self, cx: &mut Context<Self>| this.edit_step(cx, |s| {
                    s.provider = None;
                    s.command = None;
                }))),
                ("Junie".into(), provider == 1, Box::new(|this: &mut Self, cx: &mut Context<Self>| this.edit_step(cx, |s| {
                    s.provider = Some("junie".into());
                    s.command = None;
                }))),
                ("Command".into(), provider == 2, Box::new(|this: &mut Self, cx: &mut Context<Self>| this.edit_step(cx, |s| {
                    s.provider = None;
                    s.command = Some("npm test".into());
                }))),
            ],
            "prov",
            cx,
        );
        let mut specialist_items: Vec<(String, bool, Box<dyn Fn(&mut Self, &mut Context<Self>)>)> = vec![("None".into(), step.specialist.is_none(), Box::new(|this: &mut Self, cx: &mut Context<Self>| this.edit_step(cx, |s| s.specialist = None)))];
        for s in &self.specialists {
            let name = s.name.clone();
            specialist_items.push((s.title.clone(), step.specialist.as_deref().is_some_and(|n| n.eq_ignore_ascii_case(&s.name)), Box::new(move |this: &mut Self, cx: &mut Context<Self>| {
                let name = name.clone();
                this.edit_step(cx, move |st| st.specialist = Some(name))
            })));
        }
        let models: Vec<(String, bool, Box<dyn Fn(&mut Self, &mut Context<Self>)>)> = MODELS
            .iter()
            .map(|(title, value)| {
                let value = value.map(str::to_string);
                let on = step.model == value;
                (title.to_string(), on, Box::new(move |this: &mut Self, cx: &mut Context<Self>| {
                    let value = value.clone();
                    this.edit_step(cx, move |s| s.model = value)
                }) as Box<dyn Fn(&mut Self, &mut Context<Self>)>)
            })
            .collect();
        let holds_all = step.holds.as_deref() == Some("all");
        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(step.label(&self.specialists)))
            .when(!session, |d| d.child(label("Provider")).child(providers))
            .map(|d| {
                if step.command.is_some() {
                    d.child(label("Command")).child(input(&self.command_field)).child(div().text_xs().text_color(theme.secondary).child(
                        "Runs in the worktree and must pass before the push. The session's brief lists it, exactly as it runs, so it runs it as it works.",
                    ))
                } else {
                    d.child(label("Specialist"))
                        .child(chips(specialist_items, "spec", cx))
                        .when_some(step.specialist.as_deref().and_then(|n| self.specialists.iter().find(|s| s.name.eq_ignore_ascii_case(n))).map(|s| s.summary.clone()).filter(|s| !s.is_empty()), |d, summary| {
                            d.child(div().text_xs().text_color(theme.secondary).child(summary))
                        })
                        .when(self.specialists.is_empty(), |d| d.child(div().text_xs().text_color(theme.secondary).child("The harness has no specialists yet (specialists/<name>.md).")))
                        .when(step.provider.as_deref() != Some("junie"), |d| d.child(label("Model")).child(chips(models, "model", cx)))
                        .child(label("Focus"))
                        .child(input(&self.focus_field))
                        .when(!session, |d| {
                            let rounds = step.round_count();
                            d.child(label("Rounds")).child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap_2()
                                    .child(Self::button("rounds-less", "−", false, editable && rounds > 1, theme).when(editable, |b| b.on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.edit_step(cx, |s| s.rounds = Some(s.round_count().saturating_sub(1).max(1)))))))
                                    .child(div().text_sm().child(format!("Up to {rounds}")))
                                    .child(Self::button("rounds-more", "+", false, editable && rounds < 5, theme).when(editable, |b| b.on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.edit_step(cx, |s| s.rounds = Some((s.round_count() + 1).min(5))))))),
                            )
                        })
                        .when(local, |d| {
                            d.child(label("Holds the push on")).child(chips(
                                vec![
                                    ("Blockers and majors".into(), !holds_all, Box::new(|this: &mut Self, cx: &mut Context<Self>| this.edit_step(cx, |s| s.holds = Some("blocker-major".into())))),
                                    ("Every finding".into(), holds_all, Box::new(|this: &mut Self, cx: &mut Context<Self>| this.edit_step(cx, |s| s.holds = Some("all".into())))),
                                ],
                                "holds",
                                cx,
                            ))
                        })
                }
            })
            .when(editable && !session, |d| d.child(Self::button("remove-step", "Remove Step", false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.remove_step(window, cx)))))
            .into_any_element()
    }
}

impl Render for WorkflowsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let body = if self.harness.is_none() {
            div().p_6().text_color(theme.secondary).child("Pick a project with a harness: workflows live in it.").into_any_element()
        } else {
            div()
                .flex_1()
                .min_h_0()
                .flex()
                .flex_row()
                .child(div().flex_1().min_w_0().flex().flex_col().child(self.canvas(&theme, cx)).when_some(self.note.clone(), |d, note| d.child(div().px_4().py_2().text_sm().text_color(theme.secondary).child(note))))
                .child(div().id("wf-inspector").w(px(320.)).flex_none().h_full().overflow_y_scroll().p_4().border_l_1().border_color(theme.border).bg(theme.sidebar).child(self.inspector(&theme, cx)))
                .into_any_element()
        };
        div().size_full().flex().flex_col().bg(theme.bg).child(self.toolbar(&theme, cx)).child(body)
    }
}
