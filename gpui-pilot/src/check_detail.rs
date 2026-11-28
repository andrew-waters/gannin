//! One check of a pull request, read when it's opened: what the check
//! reported (its title, summary and annotations), and for a GitHub Actions
//! job its log in a read-only editor, timestamps and colour codes taken
//! out, with the lines it marked as errors listed above it.
//!
//! The PR page knows only each check's name and outcome; this asks GitHub
//! for the rest (REST check run, annotations and the job's log). Read only.

use crate::charts::Theme;
use crate::markdown::markdown;
use editor::{Editor, EditorMode};
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, FontWeight, Window};
use language::{Buffer, Capability};
use multi_buffer::MultiBuffer;
use serde_json::Value;

struct Annotation {
    path: String,
    line: Option<i64>,
    level: String,
    message: String,
}

struct Report {
    title: Option<String>,
    summary: Option<String>,
    text: Option<String>,
    annotations: Vec<Annotation>,
    /// Whether it's a GitHub Actions job, which has a log.
    actions: bool,
}

/// The check run's report, and its job's log when it's an Actions job.
/// Blocking.
fn read(repo: &str, id: i64) -> Result<(Report, Option<Result<String, String>>), String> {
    let token = crate::auth::token().ok_or("Sign in to read the check.")?;
    let run = crate::github::rest_get(&token, &format!("repos/{repo}/check-runs/{id}")).map_err(|(_, e)| e)?;
    let output = &run["output"];
    let text = |v: &Value| v.as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
    let annotations = if output["annotations_count"].as_i64().unwrap_or(0) > 0 {
        crate::github::rest_get(&token, &format!("repos/{repo}/check-runs/{id}/annotations?per_page=50"))
            .ok()
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default()
            .iter()
            .map(|a| Annotation {
                path: a["path"].as_str().unwrap_or_default().to_string(),
                line: a["start_line"].as_i64(),
                level: a["annotation_level"].as_str().unwrap_or("notice").to_string(),
                message: a["message"].as_str().unwrap_or_default().to_string(),
            })
            .collect()
    } else {
        Vec::new()
    };
    let actions = run["app"]["slug"] == "github-actions";
    let report = Report { title: text(&output["title"]), summary: text(&output["summary"]), text: text(&output["text"]), annotations, actions };
    let log = actions.then(|| crate::github::rest_text(&token, &format!("repos/{repo}/actions/jobs/{id}/logs")).map(|l| clean(&l)));
    Ok((report, log))
}

/// A log without each line's timestamp or terminal colour codes.
fn clean(log: &str) -> String {
    let mut out = String::with_capacity(log.len());
    for line in log.lines() {
        // "2026-11-21T10:04:05.1234567Z message"
        let line = match line.split_once(' ') {
            Some((stamp, rest)) if stamp.len() >= 20 && stamp.ends_with('Z') && stamp.as_bytes().first().is_some_and(u8::is_ascii_digit) => rest,
            _ => line,
        };
        let mut chars = line.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\u{1b}' && chars.peek() == Some(&'[') {
                chars.next();
                for c in chars.by_ref() {
                    if c.is_ascii_alphabetic() {
                        break;
                    }
                }
            } else {
                out.push(c);
            }
        }
        out.push('\n');
    }
    out
}

enum State {
    Loading,
    Failed(String),
    Ready(Report),
}

pub struct CheckDetail {
    name: String,
    url: Option<String>,
    state: State,
    /// The job's log, or why there's none.
    log: Option<Result<Entity<Editor>, String>>,
    /// Lines the log marked as errors (`##[error]`).
    errors: Vec<String>,
}

impl CheckDetail {
    pub fn new(repo: String, id: i64, name: String, url: Option<String>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        cx.spawn_in(window, async move |this, cx| {
            let found = cx.background_executor().spawn(async move { read(&repo, id) }).await;
            this.update_in(cx, |view, window, cx| {
                match found {
                    Ok((report, log)) => {
                        view.log = log.map(|log| {
                            log.map(|text| {
                                view.errors = text.lines().filter_map(|l| l.strip_prefix("##[error]")).map(|l| l.trim().to_string()).take(20).collect();
                                let buffer = cx.new(|cx| {
                                    let mut buffer = Buffer::local(text, cx);
                                    buffer.set_capability(Capability::ReadOnly, cx);
                                    buffer
                                });
                                let multibuffer = cx.new(|cx| MultiBuffer::singleton(buffer, cx));
                                cx.new(|cx| {
                                    let mut editor = Editor::new(EditorMode::full(), multibuffer, None, window, cx);
                                    editor.set_read_only(true);
                                    editor
                                })
                            })
                        });
                        view.state = State::Ready(report);
                    }
                    Err(e) => view.state = State::Failed(e),
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
        Self { name, url, state: State::Loading, log: None, errors: Vec::new() }
    }
}

impl Render for CheckDetail {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let quiet = |text: String| div().text_sm().text_color(theme.secondary).child(text);
        let mut report = div().flex().flex_col().gap_3();
        match &self.state {
            State::Loading => report = report.child(quiet("Reading the check from GitHub".into())),
            State::Failed(e) => report = report.child(quiet(format!("Couldn't read the check: {e}"))),
            State::Ready(r) => {
                if let Some(title) = &r.title {
                    report = report.child(div().font_weight(FontWeight::SEMIBOLD).child(title.clone()));
                }
                if let Some(summary) = &r.summary {
                    report = report.child(markdown("check-summary", summary, &theme));
                }
                if let Some(text) = &r.text {
                    report = report.child(markdown("check-text", text, &theme));
                }
                if !r.annotations.is_empty() {
                    report = report.child(div().text_sm().font_weight(FontWeight::SEMIBOLD).child(format!("Annotations {}", r.annotations.len()))).child(
                        div().flex().flex_col().rounded_lg().border_1().border_color(theme.border).children(r.annotations.iter().enumerate().map(|(i, a)| {
                            let tint = match a.level.as_str() {
                                "failure" => theme.critical(),
                                "warning" => theme.orange(),
                                _ => theme.secondary,
                            };
                            div()
                                .flex()
                                .flex_row()
                                .gap_2()
                                .px_3()
                                .py_1p5()
                                .when(i > 0, |d| d.border_t_1().border_color(theme.border))
                                .child(div().flex_none().mt(px(6.)).size(px(7.)).rounded_full().bg(tint))
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .flex()
                                        .flex_col()
                                        .child(div().text_xs().font_family(crate::zed::MONO).text_color(theme.secondary).child(match a.line {
                                            Some(line) => format!("{}:{line}", a.path),
                                            None => a.path.clone(),
                                        }))
                                        .child(div().text_sm().child(a.message.clone())),
                                )
                        })),
                    );
                }
                if !self.errors.is_empty() {
                    report = report
                        .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.critical()).child("Errors in the log"))
                        .children(self.errors.iter().map(|e| div().text_sm().font_family(crate::zed::MONO).child(e.clone())));
                }
                if r.title.is_none() && r.summary.is_none() && r.annotations.is_empty() && self.errors.is_empty() {
                    report = report.child(quiet("It reported nothing beyond its outcome.".into()));
                }
                if !r.actions {
                    report = report.child(quiet("Not a GitHub Actions job, so its log is wherever it ran.".into()));
                }
            }
        }
        let url = self.url.clone();
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .px_4()
                    .py_2()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(div().flex_1().min_w_0().truncate().font_weight(FontWeight::SEMIBOLD).child(self.name.clone()))
                    .when_some(url, |d, url| {
                        d.child(
                            div()
                                .id("check-github")
                                .flex_none()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap_1p5()
                                .px_2()
                                .py_0p5()
                                .rounded_md()
                                .border_1()
                                .border_color(theme.border)
                                .text_sm()
                                .cursor_pointer()
                                .hover(|s| s.bg(theme.row_selected))
                                .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                                .child(gpui::svg().path("icons/github.svg").size(px(14.)).flex_none().text_color(theme.fg))
                                .child("Open on GitHub"),
                        )
                    }),
            )
            .child(div().id("check-report").flex_none().max_h(gpui::relative(0.45)).overflow_y_scroll().px_4().py_3().child(report))
            .map(|d| match &self.log {
                Some(Ok(editor)) => d.child(div().flex_1().min_h_0().border_t_1().border_color(theme.border).child(editor.clone())),
                Some(Err(e)) => d.child(div().px_4().py_2().border_t_1().border_color(theme.border).child(quiet(e.clone()))),
                None => d,
            })
    }
}
