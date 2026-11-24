//! The forms that start a session not about an issue or PR, after Gannin's
//! New Plan, New Ask and New Quick Change: which project (so which harness)
//! and what it's about. Fields are Zed's editor, so they have a cursor,
//! selection and undo.

use crate::charts::Theme;
use crate::issues::IssueItem;
use crate::launch::Flow;
use crate::projects::Project;
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, EventEmitter, Focusable, FontWeight, KeyDownEvent, Window};

/// What the form was filled in with.
pub struct Started {
    pub flow: Flow,
    pub harness: String,
    /// The plan's topic, the question, or the change's note.
    pub text: String,
    /// The quick change's title, or the plan's facilitator guidance.
    pub extra: String,
    /// The quick change's repository.
    pub repo: Option<String>,
    /// The issue a plan is for.
    pub issue: Option<IssueItem>,
    /// What the room expects a plan to be: initiative, epic or issue. None
    /// leaves it to the plan to propose.
    pub size: Option<&'static str>,
    /// Documents shared with a plan, and whether each may be committed.
    pub docs: Vec<(std::path::PathBuf, bool)>,
}

/// What a plan can be expected to become, as the form offers it.
const SIZES: [(Option<&str>, &str); 4] = [(None, "Let the Plan Say"), (Some("initiative"), "Initiative"), (Some("epic"), "Epic"), (Some("issue"), "Issue")];

pub enum FormEvent {
    Start(Started),
    Cancel,
}

impl EventEmitter<FormEvent> for LaunchForm {}

pub struct LaunchForm {
    flow: Flow,
    projects: Vec<Project>,
    project: usize,
    repo: Option<String>,
    issue: Option<IssueItem>,
    text: Entity<editor::Editor>,
    extra: Entity<editor::Editor>,
    error: Option<String>,
    size: Option<&'static str>,
    docs: Vec<(std::path::PathBuf, bool)>,
}

impl LaunchForm {
    pub fn new(flow: Flow, projects: Vec<Project>, issue: Option<IssueItem>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let text = cx.new(|cx| {
            let mut editor = match flow {
                Flow::Plan => editor::Editor::single_line(window, cx),
                _ => editor::Editor::auto_height(3, 10, window, cx),
            };
            let placeholder = match flow {
                Flow::Plan => "A topic, in a line or two",
                Flow::Ask => "How many users logged in today, pull last month's signups as a CSV, explain how billing works",
                _ => "The Save button on Settings sits too low on small windows, nudge it up",
            };
            editor.set_placeholder_text(placeholder, window, cx);
            if let Some(issue) = &issue {
                editor.set_text(issue.title.clone(), window, cx);
            }
            editor
        });
        let topic = issue.as_ref().map(|i| i.title.clone()).unwrap_or_else(|| "this".into());
        let extra = cx.new(|cx| {
            let mut editor = match flow {
                Flow::Plan => editor::Editor::auto_height(4, 12, window, cx),
                _ => editor::Editor::single_line(window, cx),
            };
            match flow {
                Flow::Plan => editor.set_text(crate::launch::suggested_planning_guidance(&topic), window, cx),
                _ => editor.set_placeholder_text("Its first line, if left empty", window, cx),
            }
            editor
        });
        // The project that covers the issue, else the first.
        let project = issue.as_ref().and_then(|i| projects.iter().position(|p| p.repos.contains(&i.repo))).unwrap_or(0);
        let repo = projects.get(project).and_then(|p| p.repos.first().cloned());
        let focus = text.focus_handle(cx);
        window.focus(&focus, cx);
        Self { flow, projects, project, repo, issue, text, extra, error: None, size: None, docs: Vec::new() }
    }

    /// Documents for a plan: picked, each not committed until ticked.
    fn add_docs(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(gpui::PathPromptOptions { files: true, directories: false, multiple: true, prompt: Some("Share".into()) });
        cx.spawn_in(window, async move |this, cx| {
            let Ok(Ok(Some(paths))) = paths.await else { return };
            this.update(cx, |form, cx| {
                for path in paths {
                    if !form.docs.iter().any(|(p, _)| *p == path) {
                        form.docs.push((path, false));
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn start(&mut self, cx: &mut Context<Self>) {
        let text = self.text.read(cx).text(cx).trim().to_string();
        let extra = self.extra.read(cx).text(cx).trim().to_string();
        let Some(project) = self.projects.get(self.project) else {
            self.error = Some("Sessions run in the org's harness. Pick or create it in Gannin's org Settings, under Harness.".into());
            return cx.notify();
        };
        if text.is_empty() {
            self.error = Some(match self.flow {
                Flow::Plan => "Say what we're planning.".into(),
                Flow::Ask => "Ask something first.".into(),
                _ => "Say what to change.".into(),
            });
            return cx.notify();
        }
        if self.flow == Flow::QuickChange && self.repo.is_none() {
            self.error = Some("Pick the repository to change.".into());
            return cx.notify();
        }
        cx.emit(FormEvent::Start(Started {
            flow: self.flow,
            harness: project.id.clone(),
            text,
            extra,
            repo: self.repo.clone(),
            issue: self.issue.clone(),
            size: self.size,
            docs: self.docs.clone(),
        }));
    }
}

impl Render for LaunchForm {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let label = |text: &str| div().text_xs().text_color(theme.secondary).child(text.to_string());
        let field = |editor: &Entity<editor::Editor>| div().px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).child(editor.clone());
        let chip = |id: (&'static str, usize), text: String, on: bool| {
            div()
                .id(id)
                .px_2()
                .py_0p5()
                .rounded_md()
                .text_xs()
                .cursor_pointer()
                .border_1()
                .border_color(if on { theme.selected } else { theme.border })
                .text_color(if on { theme.selected } else { theme.fg })
                .hover(|s| s.bg(theme.row_selected))
                .child(text)
        };
        let (title, start, footer) = match self.flow {
            Flow::Plan => (
                if self.issue.is_some() { "Plan This" } else { "New Initiative, Epic or Issue" },
                "Start Planning",
                "Claude runs the session in the project's harness and asks the room one question at a time, starting from the outcome: what changes, for whom, and how you'll know. The room approves each stage; at Agree, Gannin writes the plan and files the issues.".to_string(),
            ),
            Flow::Ask => (
                "New Ask",
                "Start",
                format!(
                    "Claude Code runs in {} on this Mac, with its CLAUDE.md, skills and MCP servers. What it makes is saved in the session's files/ folder, and stays on this Mac unless you commit a file yourself.",
                    self.projects.get(self.project).map(|p| p.id.as_str()).unwrap_or("the harness")
                ),
            ),
            _ => (
                "New Quick Change",
                "Start",
                format!(
                    "For a snag, a tweak or a one-line fix: Claude Code starts on it straight away in {}, with a worktree and branch of its own, as Work on This does for an issue. No issue is filed for it.",
                    self.projects.get(self.project).map(|p| p.id.as_str()).unwrap_or("the harness")
                ),
            ),
        };
        let repos: Vec<String> = self.projects.get(self.project).map(|p| p.repos.clone()).unwrap_or_default();
        div()
            .id("launch-form")
            .w(px(560.))
            .p_5()
            .flex()
            .flex_col()
            .gap_3()
            .bg(theme.popover)
            .border_1()
            .border_color(theme.border)
            .rounded_xl()
            .shadow_lg()
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                if event.keystroke.key == "escape" {
                    cx.stop_propagation();
                    cx.emit(FormEvent::Cancel);
                } else if event.keystroke.key == "enter" && event.keystroke.modifiers.platform {
                    cx.stop_propagation();
                    this.start(cx);
                }
            }))
            .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(title))
            .when_some(self.issue.as_ref(), |d, issue| d.child(label(&format!("Planning {}#{}", issue.repo, issue.number))))
            .when(self.projects.len() > 1, |d| {
                d.child(label("Project")).child(div().flex().flex_row().flex_wrap().gap_1().children(self.projects.iter().enumerate().map(|(i, p)| {
                    chip(("form-project", i), p.name.clone(), i == self.project).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.project = i;
                        this.repo = this.projects.get(i).and_then(|p| p.repos.first().cloned());
                        cx.notify();
                    }))
                })))
            })
            .when(self.flow == Flow::QuickChange, |d| {
                d.child(label("Repository")).child(div().flex().flex_row().flex_wrap().gap_1().children(repos.into_iter().enumerate().map(|(i, repo)| {
                    let on = self.repo.as_deref() == Some(repo.as_str());
                    let short = repo.rsplit('/').next().unwrap_or(&repo).to_string();
                    chip(("form-repo", i), short, on).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.repo = Some(repo.clone());
                        cx.notify();
                    }))
                })))
            })
            .child(label(match self.flow {
                Flow::Plan => "What are we planning?",
                Flow::Ask => "Ask anything",
                _ => "What to change",
            }))
            .child(field(&self.text))
            .when(self.flow == Flow::Plan && self.issue.is_none(), |d| {
                d.child(label("What it'll become")).child(div().flex().flex_row().flex_wrap().gap_1().children(SIZES.iter().enumerate().map(|(i, (size, title))| {
                    let size = *size;
                    chip(("form-size", i), title.to_string(), self.size == size).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.size = size;
                        cx.notify();
                    }))
                })))
            })
            .when(self.flow == Flow::Plan, |d| {
                let docs = self.docs.clone();
                d.child(label("Documents for the room"))
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .children(docs.into_iter().enumerate().map(|(i, (path, commit))| {
                                let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                                div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap_2()
                                    .text_sm()
                                    .child(div().flex_1().truncate().child(name))
                                    .child(chip(("form-doc-commit", i), "Commit with the Plan".into(), commit).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                        if let Some(doc) = this.docs.get_mut(i) {
                                            doc.1 = !doc.1;
                                        }
                                        cx.notify();
                                    })))
                                    .child(chip(("form-doc-remove", i), "Remove".into(), false).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                        if i < this.docs.len() {
                                            this.docs.remove(i);
                                        }
                                        cx.notify();
                                    })))
                            }))
                            .child(div().flex().flex_row().child(chip(("form-doc-add", 0), "Add Documents".into(), false).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.add_docs(window, cx))))),
                    )
                    .child(div().text_xs().text_color(theme.tertiary).child("Claude reads them in the session. Only those ticked go into the harness with the plan, where git keeps them: leave anything sensitive unticked."))
            })
            .when(self.flow != Flow::Ask, |d| {
                d.child(label(if self.flow == Flow::Plan { "Prompt" } else { "Title" })).child(field(&self.extra))
            })
            .child(div().text_xs().text_color(theme.secondary).child(footer))
            .when_some(self.error.clone(), |d, e| d.child(div().text_color(theme.critical()).child(e)))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap_2()
                    .child(
                        div()
                            .id("form-cancel")
                            .px_3()
                            .py_1()
                            .rounded_md()
                            .border_1()
                            .border_color(theme.border)
                            .cursor_pointer()
                            .on_click(cx.listener(|_, _: &ClickEvent, _, cx| cx.emit(FormEvent::Cancel)))
                            .child("Cancel"),
                    )
                    .child(
                        div()
                            .id("form-start")
                            .px_3()
                            .py_1()
                            .rounded_md()
                            .bg(theme.selected)
                            .text_color(theme.on_selected)
                            .cursor_pointer()
                            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.start(cx)))
                            .child(format!("{start}  ⌘↩")),
                    ),
            )
    }
}
