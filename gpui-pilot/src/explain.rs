//! Explain a pull request, as Gannin's Explain window: a conversation with
//! claude without a terminal, in a sheet over the window. Each turn is one
//! `claude -p --output-format stream-json` run in a scratch folder: the
//! first with a new session id and Gannin's prompt (with the review's
//! walkthrough when there is one), follow-ups with `--resume` and the
//! question alone. Text streams in as claude writes it, and the final
//! `result` replaces it, dropping any preamble before a tool call. Closing
//! discards the conversation, as Gannin's does.

use crate::charts::Theme;
use crate::launch::Subject;
use crate::markdown::markdown;
use crate::review::Area;
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, EventEmitter, FontWeight, KeyDownEvent, Task, Window};
use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub struct CloseExplain;

impl EventEmitter<CloseExplain> for ExplainSheet {}

/// One turn: the question (none for the explanation) and the reply so far.
#[derive(Clone, Default)]
struct Turn {
    question: Option<String>,
    reply: String,
}

/// What a run shares with the sheet as it goes.
#[derive(Default)]
struct Run {
    text: String,
    done: bool,
    error: Option<String>,
}

pub struct ExplainSheet {
    subject: Subject,
    walkthrough: Vec<Area>,
    session: String,
    turns: Vec<Turn>,
    working: bool,
    status: Option<String>,
    question: Entity<editor::Editor>,
    _watch: Option<Task<()>>,
}

impl ExplainSheet {
    pub fn new(subject: Subject, walkthrough: Vec<Area>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let question = cx.new(|cx| {
            let mut editor = editor::Editor::auto_height(1, 4, window, cx);
            editor.set_placeholder_text("Ask a follow-up question", window, cx);
            editor
        });
        let mut sheet = Self { subject, walkthrough, session: String::new(), turns: Vec::new(), working: false, status: None, question, _watch: None };
        sheet.explain(cx);
        sheet
    }

    fn prompt(&self) -> String {
        let s = &self.subject;
        let note = if self.walkthrough.is_empty() {
            String::new()
        } else {
            let areas: Vec<String> = self
                .walkthrough
                .iter()
                .map(|a| {
                    let summary = a.summary.as_deref().map(|s| format!(": {s}")).unwrap_or_default();
                    format!("- {}{summary} ({})", a.title, a.files.join(", "))
                })
                .collect();
            format!(
                "\nA review has already split this PR into these areas, in reading order:\n{}\n\nBuild on that structure rather than working it out again, but explain the code in your own words, not the review's.\n",
                areas.join("\n")
            )
        };
        format!(
            "Explain pull request {repo}#{n}, \"{title}\" ({url}), for someone who hasn't read it: explain the code, not just the PR description.\n\nRead the actual changes with `gh pr diff {n} --repo {repo}` first, then `gh pr view {n} --repo {repo} --comments` for the stated intent and discussion. Base the explanation on what the diff does, not a reworded version of the title or description.\n\nReply with the explanation only, no preamble, in Markdown: a short paragraph on what the code does and why, then a few bullet points on the notable changes if there are several, naming the functions, types or files involved. Where a short snippet would make a change clearer than naming it, include one as a fenced code block (with a language and, where it helps, the file path above it), taken from the actual diff rather than paraphrased. Don't review it or suggest changes.\n{note}\nI may ask follow-up questions about this PR afterwards; answer those from the diff and discussion you've already read, in the same plain Markdown style, with no preamble.",
            repo = s.repo,
            n = s.number,
            title = s.title,
            url = s.url
        )
    }

    /// The explanation, afresh: a new session and folder.
    fn explain(&mut self, cx: &mut Context<Self>) {
        if self.working {
            return;
        }
        self.session = uuid::Uuid::new_v4().to_string();
        self.turns = vec![Turn::default()];
        self.status = None;
        let prompt = self.prompt();
        self.run(prompt, false, cx);
    }

    fn ask(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.question.read(cx).text(cx).trim().to_string();
        if text.is_empty() || self.working || self.turns.first().is_none_or(|t| t.reply.is_empty()) {
            return;
        }
        self.question.update(cx, |editor, cx| editor.set_text("", window, cx));
        self.turns.push(Turn { question: Some(text.clone()), reply: String::new() });
        self.run(text, true, cx);
    }

    /// Runs one turn in the background, copying its text into the last turn
    /// as it streams.
    fn run(&mut self, prompt: String, resume: bool, cx: &mut Context<Self>) {
        self.working = true;
        let shared = Arc::new(Mutex::new(Run::default()));
        let session = self.session.clone();
        let writer = shared.clone();
        std::thread::spawn(move || {
            let outcome = run_claude(&session, &prompt, resume, &writer);
            if let Ok(mut run) = writer.lock() {
                if let Err(error) = outcome {
                    run.error = Some(error);
                }
                run.done = true;
            }
        });
        self._watch = Some(cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(Duration::from_millis(120)).await;
            let (text, done, error) = match shared.lock() {
                Ok(run) => (run.text.clone(), run.done, run.error.clone()),
                Err(_) => return,
            };
            let gone = this
                .update(cx, |this, cx| {
                    if let Some(turn) = this.turns.last_mut() {
                        if turn.reply != text {
                            turn.reply = text.clone();
                            cx.notify();
                        }
                    }
                    if done {
                        this.working = false;
                        if let Some(error) = error.clone() {
                            match this.turns.last_mut() {
                                // A follow-up's error is its reply; the
                                // explanation's goes under it.
                                Some(turn) if turn.question.is_some() => turn.reply = error,
                                _ => this.status = Some(error),
                            }
                        }
                        cx.notify();
                    }
                })
                .is_err();
            if gone || done {
                return;
            }
        }));
        cx.notify();
    }

    fn copy(&mut self, cx: &mut Context<Self>) {
        let text: Vec<String> = self
            .turns
            .iter()
            .flat_map(|t| t.question.as_ref().map(|q| format!("**Q:** {q}")).into_iter().chain(std::iter::once(t.reply.clone())))
            .filter(|s| !s.is_empty())
            .collect();
        cx.write_to_clipboard(gpui::ClipboardItem::new_string(text.join("\n\n")));
        self.status = Some("Copied".into());
        cx.notify();
    }
}

/// One `claude -p` turn in its scratch folder, streaming text deltas into
/// `run` and ending with the final result. Blocking.
fn run_claude(session: &str, prompt: &str, resume: bool, run: &Arc<Mutex<Run>>) -> Result<(), String> {
    let folder = std::env::temp_dir().join(format!("gannin-explain-{session}"));
    std::fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
    std::fs::write(folder.join(".gannin-prompt"), prompt).map_err(|e| e.to_string())?;
    let script = format!(
        "set -e\ncd '{}'\ncommand -v claude >/dev/null 2>&1 || {{ echo 'Claude Code isn'\"'\"'t installed on this Mac.' >&2; exit 127; }}\nclaude -p --output-format stream-json --include-partial-messages --verbose --allowedTools Bash {} '{session}' < .gannin-prompt\n",
        folder.display(),
        if resume { "--resume" } else { "--session-id" }
    );
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let mut command = Command::new(shell);
    command.args(["-l", "-i", "-c", "bash -s"]).current_dir(std::env::var("HOME").unwrap_or_default()).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    for (key, _) in std::env::vars() {
        if key == "CLAUDECODE" || key.starts_with("CLAUDE_CODE_") {
            command.env_remove(key);
        }
    }
    let mut child = command.spawn().map_err(|e| format!("Couldn't start claude: {e}"))?;
    child.stdin.take().map(|mut stdin| stdin.write_all(script.as_bytes())).transpose().map_err(|e| e.to_string())?;
    let mut stderr = child.stderr.take();
    let mut result: Option<String> = None;
    if let Some(stdout) = child.stdout.take() {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let Ok(event) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
            if event["type"] == "stream_event" && event["event"]["type"] == "content_block_delta" && event["event"]["delta"]["type"] == "text_delta" {
                if let (Some(text), Ok(mut run)) = (event["event"]["delta"]["text"].as_str(), run.lock()) {
                    run.text.push_str(text);
                }
            } else if event["type"] == "result" {
                result = event["result"].as_str().map(str::to_string);
            }
        }
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    if let (Some(text), Ok(mut run)) = (result, run.lock()) {
        run.text = text.trim().to_string();
    }
    if !status.success() {
        let mut errors = String::new();
        if let Some(stderr) = stderr.as_mut() {
            let _ = stderr.read_to_string(&mut errors);
        }
        let lines: Vec<&str> = errors.lines().filter(|l| !l.contains("can't change option") && !l.contains("no job control") && !l.trim().is_empty()).collect();
        let tail = lines[lines.len().saturating_sub(3)..].join("\n");
        return Err(if tail.is_empty() { format!("Claude didn't answer (exit {}).", status.code().unwrap_or(-1)) } else { tail });
    }
    Ok(())
}

impl Render for ExplainSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let has_text = self.turns.first().is_some_and(|t| !t.reply.is_empty());
        let spinner = |id: &'static str| {
            use gpui::{Animation, AnimationExt, Transformation};
            gpui::svg()
                .path("icons/arrow_circle.svg")
                .size(px(14.))
                .flex_none()
                .text_color(theme.secondary)
                .with_animation(id, Animation::new(Duration::from_millis(1200)).repeat(), |svg, delta| svg.with_transformation(Transformation::rotate(gpui::percentage(delta))))
        };
        let mut transcript = div().flex().flex_col().gap_4().p_6();
        if !has_text {
            transcript = transcript.child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .when(self.working, |d| d.child(spinner("explain-reading")))
                    .child(div().text_color(theme.secondary).child(if self.working { "Claude is reading it." } else { "Nothing yet." })),
            );
        }
        for (i, turn) in self.turns.iter().enumerate() {
            match &turn.question {
                None => {
                    if !turn.reply.is_empty() {
                        transcript = transcript.child(markdown(&format!("explain-{i}"), &turn.reply, &theme));
                    }
                }
                Some(question) => {
                    transcript = transcript
                        .child(div().flex().flex_row().child(div().w(px(40.)).flex_none()).child(div().flex_1().flex().justify_end().child(
                            div().px(px(10.)).py(px(6.)).rounded(px(10.)).bg(theme.selected.opacity(0.18)).child(question.clone()),
                        )))
                        .child(div().flex().flex_row().child(
                            div().flex_1().child(div().px(px(10.)).py(px(6.)).rounded(px(10.)).bg(theme.secondary.opacity(0.12)).map(|d| {
                                if turn.reply.is_empty() {
                                    d.child(spinner("explain-reply"))
                                } else {
                                    d.child(markdown(&format!("explain-{i}"), &turn.reply, &theme))
                                }
                            })),
                        ).child(div().w(px(40.)).flex_none()));
                }
            }
        }
        let s = &self.subject;
        div()
            .id("explain-sheet")
            .occlude()
            .w(px(680.))
            .h(px(560.))
            .flex()
            .flex_col()
            .bg(theme.popover)
            .border_1()
            .border_color(theme.border)
            .rounded_xl()
            .shadow_lg()
            .overflow_hidden()
            .on_key_down(cx.listener(|_, event: &KeyDownEvent, _, cx| {
                if event.keystroke.key == "escape" {
                    cx.emit(CloseExplain);
                }
            }))
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .px_4()
                    .py_2p5()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(div().font_weight(FontWeight::SEMIBOLD).child(format!("Explain {}#{}", s.repo, s.number)))
                            .child(div().truncate().text_xs().text_color(theme.secondary).child(s.title.clone())),
                    )
                    .child(
                        div()
                            .id("explain-close")
                            .px_2()
                            .rounded_md()
                            .cursor_pointer()
                            .text_color(theme.secondary)
                            .hover(|d| d.bg(theme.row_selected))
                            .on_click(cx.listener(|_, _: &ClickEvent, _, cx| cx.emit(CloseExplain)))
                            .child("×"),
                    ),
            )
            .child(div().id("explain-transcript").flex_1().min_h_0().overflow_y_scroll().child(transcript))
            .when(has_text, |d| {
                d.child(
                    div()
                        .flex_none()
                        .flex()
                        .flex_row()
                        .items_end()
                        .gap_2()
                        .p_3()
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
                                .bg(theme.bg)
                                .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                                    if event.keystroke.key == "enter" && !event.keystroke.modifiers.shift {
                                        cx.stop_propagation();
                                        this.ask(window, cx);
                                    }
                                }))
                                .child(self.question.clone()),
                        )
                        .child(button("explain-ask", "Ask", true, !self.working, &theme).when(!self.working, |b| b.on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.ask(window, cx))))),
                )
            })
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
                    .child(div().flex_1().min_w_0().text_sm().text_color(theme.secondary).children(self.status.clone()))
                    .when(self.working, |d| d.child(spinner("explain-working")))
                    .child(button("explain-again", if has_text { "Explain Again" } else { "Explain" }, false, !self.working, &theme).when(!self.working, |b| {
                        b.on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.explain(cx)))
                    }))
                    .child(button("explain-copy", "Copy", false, has_text, &theme).when(has_text, |b| b.on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.copy(cx))))),
            )
    }
}

fn button(id: &'static str, label: &'static str, prominent: bool, enabled: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .px_2()
        .py_0p5()
        .rounded_md()
        .text_sm()
        .map(|d| if prominent { d.bg(theme.selected).text_color(theme.on_selected) } else { d.border_1().border_color(theme.border) })
        .when(enabled, |d| d.cursor_pointer().hover(|s| s.opacity(0.85)))
        .when(!enabled, |d| d.opacity(0.4))
        .child(label)
}
