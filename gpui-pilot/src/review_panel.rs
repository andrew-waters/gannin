//! A review session's findings beside its terminal, as Gannin's review tab:
//! the headline, verdict and summary, each finding to keep or dismiss,
//! Review Again, and Post Review, whose sheet shows exactly what would go
//! to GitHub and posts only when the person clicks Post to GitHub.

use crate::charts::Theme;
use crate::launch::Launch;
use crate::markdown::markdown;
use crate::review::{self, Draft, ReviewResult, Snapshot};
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, FontWeight, Hsla, SharedString, Task, Window};
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use terminal::Terminal;

/// The Post Review sheet, step by step.
pub enum Post {
    Loading,
    Ready { snapshot: Arc<Snapshot>, draft: Arc<Draft>, event: &'static str, body: Entity<editor::Editor> },
    Posting,
    Posted(String),
    Failed(String),
}

/// Where a panel's review comes from: a live session, or the Review
/// Preview's made-up one, which never runs claude or calls GitHub.
enum Source {
    Live { launch: Launch, terminal: Entity<Terminal> },
    Preview { repo: String, number: i64, url: String, idle: bool, snapshot: Arc<Snapshot> },
}

pub struct ReviewPanel {
    source: Source,
    result: Option<ReviewResult>,
    dismissed: HashSet<String>,
    post: Option<Post>,
    _poll: Option<Task<()>>,
}

impl ReviewPanel {
    pub fn new(launch: Launch, terminal: Entity<Terminal>, cx: &mut Context<Self>) -> Self {
        let claude_id = launch.claude_id();
        // The transcript is read again every few seconds, off the main
        // thread, until a result is there and whenever it may have changed.
        let poll = cx.spawn(async move |this, cx| loop {
            let id = claude_id.clone();
            let result = cx.background_executor().spawn(async move { review::read_result(&id) }).await;
            if this
                .update(cx, |this, cx| {
                    if result.is_some() && this.result != result {
                        this.result = result;
                        cx.notify();
                    }
                })
                .is_err()
            {
                return;
            }
            cx.background_executor().timer(Duration::from_secs(4)).await;
        });
        Self { source: Source::Live { launch, terminal }, result: None, dismissed: HashSet::new(), post: None, _poll: Some(poll) }
    }

    /// A panel showing a made-up review in one state, for the Review
    /// Preview. `idle` is whether claude would be waiting for the person.
    pub fn preview(repo: &str, number: i64, result: Option<ReviewResult>, idle: bool, snapshot: Snapshot, post: Option<Post>) -> Self {
        Self {
            source: Source::Preview { repo: repo.into(), number, url: format!("https://github.com/{repo}/pull/{number}"), idle, snapshot: Arc::new(snapshot) },
            result,
            dismissed: HashSet::new(),
            post,
            _poll: None,
        }
    }

    fn subject(&self) -> (String, i64) {
        match &self.source {
            Source::Live { launch, .. } => launch.subject.as_ref().map(|s| (s.repo.clone(), s.number)).unwrap_or_default(),
            Source::Preview { repo, number, .. } => (repo.clone(), *number),
        }
    }

    fn url(&self) -> String {
        match &self.source {
            Source::Live { launch, .. } => launch.subject.as_ref().map(|s| s.url.clone()).unwrap_or_default(),
            Source::Preview { url, .. } => url.clone(),
        }
    }

    /// Whether claude is waiting for the person, so Review Again can go.
    fn idle(&self) -> bool {
        match &self.source {
            Source::Live { launch, .. } => matches!(launch.state().as_deref(), Some("idle")),
            Source::Preview { idle, .. } => *idle,
        }
    }

    /// Asks claude to review it afresh, as Gannin's Review Again.
    fn review_again(&mut self, cx: &mut Context<Self>) {
        if let Source::Live { terminal, .. } = &self.source {
            terminal.update(cx, |terminal, _| {
                terminal.paste(crate::launch::REVIEW_AGAIN);
                terminal.input(b"\r".to_vec());
            });
        }
    }

    /// Opens the sheet: the PR, its files and what's been said, fetched now.
    fn open_post(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(result) = self.result.clone() else { return };
        if let Source::Preview { snapshot, .. } = &self.source {
            self.post = Some(Self::ready(&result, &self.dismissed, snapshot.clone(), window, cx));
            cx.notify();
            return;
        }
        self.post = Some(Post::Loading);
        let (repo, number) = self.subject();
        let dismissed = self.dismissed.clone();
        cx.notify();
        cx.spawn_in(window, async move |this, cx| {
            let fetched = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or("Sign in to post a review.")?;
                    review::snapshot(&token, &repo, number).map_err(|e| format!("Couldn't load the pull request: {e}"))
                })
                .await;
            this.update_in(cx, |this, window, cx| {
                this.post = Some(match fetched {
                    Ok(snapshot) => Self::ready(&result, &dismissed, Arc::new(snapshot), window, cx),
                    Err(error) => Post::Failed(error),
                });
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// The sheet ready to post: the draft from the findings kept, and the
    /// event the verdict suggests.
    pub fn ready(result: &ReviewResult, dismissed: &HashSet<String>, snapshot: Arc<Snapshot>, window: &mut Window, cx: &mut gpui::App) -> Post {
        let draft = review::draft(result, dismissed, &snapshot);
        let event = review::default_event(result, snapshot.is_own());
        let text = draft.body.clone();
        let body = cx.new(|cx| {
            let mut editor = editor::Editor::auto_height(4, 14, window, cx);
            editor.set_text(text, window, cx);
            editor
        });
        Post::Ready { snapshot, draft: Arc::new(draft), event, body }
    }

    /// Sends it: only from the person's click on Post to GitHub. A preview
    /// only pretends, after a moment.
    fn confirm_post(&mut self, cx: &mut Context<Self>) {
        let Some(Post::Ready { snapshot, draft, event, body }) = self.post.take() else { return };
        let text = body.read(cx).text(cx);
        let draft = Draft { body: text, comments: draft.comments.clone(), left_out: draft.left_out.clone() };
        let (repo, number) = self.subject();
        self.post = Some(Post::Posting);
        cx.notify();
        if matches!(self.source, Source::Preview { .. }) {
            let url = format!("{}#pullrequestreview-0", self.url());
            cx.spawn(async move |this, cx| {
                cx.background_executor().timer(Duration::from_millis(1200)).await;
                this.update(cx, |this, cx| {
                    this.post = Some(Post::Posted(url));
                    cx.notify();
                })
                .ok();
            })
            .detach();
            return;
        }
        cx.spawn(async move |this, cx| {
            let posted = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or("Sign in to post a review.")?;
                    review::post(&token, &repo, number, event, &draft, &snapshot)
                })
                .await;
            this.update(cx, |this, cx| {
                this.post = Some(match posted {
                    Ok(url) => Post::Posted(url),
                    Err(error) => Post::Failed(error.to_string()),
                });
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn severity_tint(severity: Option<&str>, theme: &Theme) -> Hsla {
        match severity {
            Some("blocker") => theme.critical(),
            Some("major") => theme.orange(),
            Some("minor") => gpui::rgb(0xEDA100).into(),
            _ => theme.secondary,
        }
    }

    fn button(id: &'static str, label: &str, prominent: bool, enabled: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(id)
            .px_2()
            .py_0p5()
            .rounded_md()
            .map(|d| if prominent { d.bg(theme.selected).text_color(theme.on_selected) } else { d.border_1().border_color(theme.border) })
            .when(enabled, |d| d.cursor_pointer().hover(|s| s.opacity(0.85)))
            .when(!enabled, |d| d.opacity(0.4))
            .child(label.to_string())
    }

    fn post_sheet(&self, post: &Post, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let (repo, number) = self.subject();
        let cancel = Self::button("post-cancel", "Cancel", false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
            this.post = None;
            cx.notify();
        }));
        let quiet = |text: String| div().text_xs().text_color(theme.secondary).child(text);
        let body = match post {
            Post::Loading => quiet("Loading the pull request".into()).into_any_element(),
            Post::Posting => quiet("Posting".into()).into_any_element(),
            Post::Posted(url) => {
                let url = url.clone();
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child("Posted to GitHub.")
                    .child(div().id("posted-link").text_color(theme.selected).cursor_pointer().on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url))).child("Open it"))
                    .into_any_element()
            }
            Post::Failed(error) => div().text_color(theme.critical()).child(error.clone()).into_any_element(),
            Post::Ready { snapshot, draft, event, body } => {
                let own = snapshot.is_own();
                let event_now = *event;
                let choice = |id: &'static str, label: &'static str, value: &'static str, cx: &mut Context<Self>| {
                    let on = event_now == value;
                    div()
                        .id(id)
                        .flex_1()
                        .py_0p5()
                        .flex()
                        .justify_center()
                        .rounded_md()
                        .cursor_pointer()
                        .text_color(if on { theme.fg } else { theme.secondary })
                        .when(on, |d| d.bg(theme.row_selected))
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            if let Some(Post::Ready { event, .. }) = this.post.as_mut() {
                                *event = value;
                            }
                            cx.notify();
                        }))
                        .child(label)
                };
                let mut events = div().p_0p5().flex().flex_row().gap_0p5().rounded_md().bg(theme.tile).text_xs().child(choice("event-comment", "Comment", "COMMENT", cx));
                if !own {
                    events = events.child(choice("event-approve", "Approve", "APPROVE", cx)).child(choice("event-changes", "Request Changes", "REQUEST_CHANGES", cx));
                }
                let general = draft.body.lines().filter(|l| l.starts_with("- `")).count();
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(div().flex().flex_col().gap_1().child(quiet("Review".into())).child(events).when(own, |d| {
                        d.child(quiet("It's your own pull request, so GitHub only takes a comment.".into()))
                    }))
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(quiet("Body".into()))
                            .child(div().p_2().rounded_md().border_1().border_color(theme.border).child(body.clone()))
                            .when(general > 0, |d| {
                                d.child(quiet(format!(
                                    "{general} finding{} {} on a line the diff shows, so {} in the body.",
                                    if general == 1 { "" } else { "s" },
                                    if general == 1 { "isn't" } else { "aren't" },
                                    if general == 1 { "it's" } else { "they're" }
                                )))
                            }),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(quiet(format!("{} inline comment{}", draft.comments.len(), if draft.comments.len() == 1 { "" } else { "s" })))
                            .children(draft.comments.iter().map(|(path, line, body)| {
                                div().flex().flex_col().child(div().text_xs().text_color(theme.selected).child(format!("{path}:{line}"))).child(div().text_xs().child(body.clone()))
                            })),
                    )
                    .when(!draft.left_out.is_empty(), |d| {
                        d.child(
                            div()
                                .flex()
                                .flex_col()
                                .gap_1()
                                .child(quiet(format!("{} finding{} left out", draft.left_out.len(), if draft.left_out.len() == 1 { "" } else { "s" })))
                                .children(draft.left_out.iter().map(|f| div().text_xs().text_color(theme.secondary).child(format!("{}:{}: {}", f.path, f.line.unwrap_or(0), f.comment))))
                                .child(quiet("A comment near its line, or an earlier review, already says much the same, so it isn't posted again.".into())),
                        )
                    })
                    .into_any_element()
            }
        };
        let can_post = matches!(post, Post::Ready { .. });
        div()
            .id("post-sheet")
            .absolute()
            .top_0()
            .left_0()
            .right_0()
            .bottom_0()
            .occlude()
            .bg(gpui::black().opacity(0.3))
            .flex()
            .justify_center()
            .pt_8()
            .child(
                div()
                    .id("post-sheet-body")
                    .w(px(560.))
                    .max_h(px(620.))
                    .overflow_y_scroll()
                    .p_4()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .bg(theme.popover)
                    .border_1()
                    .border_color(theme.border)
                    .rounded_xl()
                    .shadow_lg()
                    .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(format!("{repo}#{number}")))
                    .child(body)
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .gap_2()
                            .justify_end()
                            .child(cancel)
                            .when(can_post, |d| {
                                d.child(Self::button("post-confirm", "Post to GitHub", true, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.confirm_post(cx))))
                            }),
                    ),
            )
    }
}

impl Render for ReviewPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let quiet = |text: String| div().text_xs().text_color(theme.secondary).child(text);
        let content = match &self.result {
            None => div()
                .p_4()
                .flex()
                .flex_col()
                .gap_2()
                .child(div().font_weight(FontWeight::MEDIUM).child("Reviewing"))
                .child(quiet("Claude is reading the pull request. Its findings show here when it ends its reply with them.".into()))
                .into_any_element(),
            Some(result) => {
                let (verdict, tint) = match result.verdict.as_deref() {
                    Some("approve") => ("Approve", theme.good()),
                    Some("request_changes") => ("Request changes", theme.critical()),
                    _ => ("Comment", theme.secondary),
                };
                let mut findings = result.findings.clone();
                findings.sort_by_key(|f| f.rank());
                let kept = findings.iter().filter(|f| !self.dismissed.contains(&f.key())).count();
                div()
                    .id("review-body")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .p_4()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .when_some(result.headline.clone(), |d, h| d.child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(h)))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .child(crate::issues::pill(verdict, tint))
                            .when_some(result.effort, |d, e| d.child(quiet(format!("Effort {e} of 5")))),
                    )
                    .child(markdown("review-summary", &result.summary, &theme))
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(format!("Findings · {kept} of {}", findings.len())))
                    .children(findings.into_iter().enumerate().map(|(i, finding)| {
                        let key = finding.key();
                        let dismissed = self.dismissed.contains(&key);
                        let tint = Self::severity_tint(finding.severity.as_deref(), &theme);
                        div()
                            .flex()
                            .flex_row()
                            .gap_2()
                            .child(div().w(px(3.)).flex_none().rounded_full().bg(tint))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .flex()
                                    .flex_col()
                                    .gap_1()
                                    .when(dismissed, |d| d.opacity(0.45))
                                    .child(
                                        div()
                                            .flex()
                                            .flex_row()
                                            .items_center()
                                            .gap_2()
                                            .child(div().px_1p5().rounded_full().text_xs().bg(tint.opacity(0.2)).text_color(tint).child(finding.severity.clone().unwrap_or_else(|| "note".into())))
                                            .when_some(finding.category.clone(), |d, c| d.child(quiet(c)))
                                            .child(div().flex_1().truncate().text_xs().text_color(theme.selected).child(match finding.line {
                                                Some(line) => format!("{}:{line}", finding.path),
                                                None => finding.path.clone(),
                                            }))
                                            .child(
                                                div()
                                                    .id(("finding-toggle", i))
                                                    .px_1p5()
                                                    .rounded_md()
                                                    .text_xs()
                                                    .cursor_pointer()
                                                    .text_color(theme.secondary)
                                                    .hover(|s| s.bg(theme.row_selected))
                                                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                                        if !this.dismissed.remove(&key) {
                                                            this.dismissed.insert(key.clone());
                                                        }
                                                        cx.notify();
                                                    }))
                                                    .child(if dismissed { "Restore" } else { "Dismiss" }),
                                            ),
                                    )
                                    .child(markdown(&format!("finding-{i}"), &finding.comment, &theme))
                                    .when_some(finding.suggestion.clone(), |d, s| {
                                        d.child(div().p_2().rounded_md().bg(theme.good().opacity(0.12)).font_family("Menlo").text_xs().child(s))
                                    }),
                            )
                    }))
                    .into_any_element()
            }
        };
        let idle = self.idle();
        let has_result = self.result.is_some();
        let (repo, number) = self.subject();
        let url = self.url();
        let bar = div()
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .px_3()
            .py_2()
            .border_b_1()
            .border_color(theme.border)
            .child(div().flex_1().truncate().font_weight(FontWeight::MEDIUM).child(SharedString::from(format!("{repo}#{number}"))))
            .child(Self::button("review-github", "Open on GitHub", false, true, &theme).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url))))
            .child(Self::button("review-again", "Review Again", false, idle && has_result, &theme).when(idle && has_result, |d| {
                d.on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.review_again(cx)))
            }))
            .child(Self::button("review-post", "Post Review", true, has_result, &theme).when(has_result, |d| {
                d.on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.open_post(window, cx)))
            }));
        div()
            .relative()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .child(bar)
            .child(content)
            .when_some(self.post.as_ref(), |d, post| d.child(self.post_sheet(post, &theme, cx)))
    }
}
