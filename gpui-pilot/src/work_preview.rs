//! Work Preview: a Work on This session's tab in each of its states, from a
//! made-up issue, to refine the UI before it's wired to real sessions. No
//! claude runs and nothing is written.

use crate::charts::Theme;
use crate::work_panel::{Ask, ChangedFile, Feedback, PrState, Question, WorkData, WorkPanel, WorkPr, WorkState, Worktree};
use gpui::{div, prelude::*, ClickEvent, Context, Entity, SharedString, Window};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mock {
    Starting,
    Working,
    Permission,
    Question,
    YourTurn,
    PrOpened,
    ChecksFailing,
    ChangesRequested,
    Conflicts,
    Merged,
    Exited,
    Stale,
}

impl Mock {
    const ALL: [Mock; 12] = [
        Mock::Starting,
        Mock::Working,
        Mock::Permission,
        Mock::Question,
        Mock::YourTurn,
        Mock::PrOpened,
        Mock::ChecksFailing,
        Mock::ChangesRequested,
        Mock::Conflicts,
        Mock::Merged,
        Mock::Exited,
        Mock::Stale,
    ];

    fn title(self) -> &'static str {
        match self {
            Mock::Starting => "Starting",
            Mock::Working => "Working",
            Mock::Permission => "Permission",
            Mock::Question => "Question",
            Mock::YourTurn => "Your turn",
            Mock::PrOpened => "PR opened",
            Mock::ChecksFailing => "Checks failing",
            Mock::ChangesRequested => "Changes requested",
            Mock::Conflicts => "Conflicts",
            Mock::Merged => "Merged",
            Mock::Exited => "Claude exited",
            Mock::Stale => "Stale",
        }
    }

    /// The pane the state is mostly about.
    fn pane(self) -> &'static str {
        match self {
            Mock::Working | Mock::YourTurn => "changes",
            Mock::PrOpened | Mock::ChecksFailing | Mock::ChangesRequested | Mock::Conflicts => "prs",
            _ => "issue",
        }
    }
}

fn files() -> Vec<ChangedFile> {
    vec![
        ChangedFile {
            status: 'M',
            path: "src/webhooks/sender.rs".into(),
            additions: 38,
            deletions: 6,
            staged: true,
            diff: vec![
                "@@ -42,12 +42,44 @@ impl Sender {".into(),
                "     pub async fn send(&self, hook: &Hook, event: &Event) -> Result<()> {".into(),
                "-        self.client.post(&hook.url).json(event).send().await?;".into(),
                "-        Ok(())".into(),
                "+        let mut delay = Duration::from_secs(1);".into(),
                "+        for attempt in 1..=self.max_attempts {".into(),
                "+            match self.client.post(&hook.url).json(event).send().await {".into(),
                "+                Ok(r) if r.status().is_success() => return Ok(()),".into(),
                "+                _ if attempt == self.max_attempts => break,".into(),
                "+                _ => sleep(delay).await,".into(),
                "+            }".into(),
                "+            delay = (delay * 2).min(Duration::from_secs(60));".into(),
                "+        }".into(),
                "+        self.dead_letters.push(hook, event).await".into(),
                "     }".into(),
            ],
        },
        ChangedFile {
            status: 'A',
            path: "src/webhooks/dead_letters.rs".into(),
            additions: 52,
            deletions: 0,
            staged: false,
            diff: vec!["@@ -0,0 +1,52 @@".into(), "+//! Webhooks that failed every attempt, kept to replay.".into(), "+pub struct DeadLetters { store: Store }".into()],
        },
        ChangedFile {
            status: 'M',
            path: "tests/webhooks.rs".into(),
            additions: 64,
            deletions: 2,
            staged: false,
            diff: vec!["@@ -10,4 +10,66 @@".into(), "+#[tokio::test]".into(), "+async fn retries_with_backoff() {".into()],
        },
    ]
}

fn pr(state: PrState, review: Option<&str>, conflicts: bool, failed: Vec<&str>, pending: Vec<&str>, passed: usize, feedback: Vec<Feedback>) -> WorkPr {
    WorkPr {
        repo: "acme/api".into(),
        number: 418,
        title: "Retry failed webhooks with exponential backoff".into(),
        state,
        review: review.map(str::to_string),
        conflicts,
        failed: failed.into_iter().map(str::to_string).collect(),
        pending: pending.into_iter().map(str::to_string).collect(),
        passed,
        failures_sent: false,
        feedback,
    }
}

fn data(mock: Mock) -> WorkData {
    let (state, ask) = match mock {
        Mock::Starting => (WorkState::Starting, None),
        Mock::Working => (WorkState::Working, None),
        Mock::Permission => (
            WorkState::NeedsYou,
            Some(Ask::Permission { tool: "Bash".into(), text: "cargo test --workspace webhooks -- --include-ignored".into(), choices: vec!["Yes, and don't ask again for cargo test".into()] }),
        ),
        Mock::Question => (
            WorkState::NeedsYou,
            Some(Ask::Questions(vec![
                Question {
                    header: "Backoff".into(),
                    question: "How long should the longest wait between attempts be?".into(),
                    multi: false,
                    options: vec![
                        ("60 seconds".into(), "Five attempts span about a minute; quick to give up.".into(), true),
                        ("10 minutes".into(), "Rides out a short outage on the receiver's side.".into(), false),
                        ("1 hour".into(), "Matches what Stripe and GitHub do for their own webhooks.".into(), false),
                    ],
                },
                Question {
                    header: "Dead letters".into(),
                    question: "Where should webhooks that fail every attempt go?".into(),
                    multi: false,
                    options: vec![
                        ("A table to replay".into(), "Kept in Postgres, with a replay endpoint.".into(), true),
                        ("Just a log line".into(), "Nothing to replay; the error is logged.".into(), false),
                    ],
                },
            ])),
        ),
        Mock::Exited | Mock::Stale => (WorkState::Exited, None),
        _ => (WorkState::YourTurn, None),
    };
    let worktrees = match mock {
        Mock::Starting => Vec::new(),
        Mock::Working | Mock::Permission | Mock::Question | Mock::YourTurn => {
            vec![Worktree { name: "api".into(), unpushed: None, base: "main".into(), files: files() }]
        }
        Mock::Merged => vec![Worktree { name: "api".into(), unpushed: Some(0), base: "main".into(), files: Vec::new() }],
        _ => vec![Worktree { name: "api".into(), unpushed: Some(0), base: "main".into(), files: files() }],
    };
    let feedback = vec![
        Feedback {
            author: "sam".into(),
            location: Some("src/webhooks/sender.rs:51".into()),
            verdict: Some("Changes requested".into()),
            body: "The delay should have jitter, or every hook that failed at once retries at once.".into(),
            sent: false,
        },
        Feedback { author: "sam".into(), location: None, verdict: None, body: "Can the max attempts come from config rather than a constant?".into(), sent: false },
    ];
    let prs = match mock {
        Mock::PrOpened => vec![pr(PrState::Open, Some("REVIEW_REQUIRED"), false, vec![], vec!["test (ubuntu)", "lint"], 3, vec![])],
        Mock::ChecksFailing => vec![pr(PrState::Open, Some("REVIEW_REQUIRED"), false, vec!["test (ubuntu)"], vec![], 4, vec![])],
        Mock::ChangesRequested => vec![pr(PrState::Open, Some("CHANGES_REQUESTED"), false, vec![], vec![], 5, feedback)],
        Mock::Conflicts => vec![pr(PrState::Open, Some("APPROVED"), true, vec![], vec![], 5, vec![])],
        Mock::Merged => vec![pr(PrState::Merged, Some("APPROVED"), false, vec![], vec![], 5, vec![])],
        Mock::Exited | Mock::Stale => vec![pr(PrState::Open, Some("REVIEW_REQUIRED"), false, vec![], vec![], 5, vec![])],
        _ => Vec::new(),
    };
    let activity = match mock {
        Mock::Starting => Vec::new(),
        _ => vec![
            ("10:02".into(), "Read the issue and src/webhooks/sender.rs".into()),
            ("10:05".into(), "Edited src/webhooks/sender.rs".into()),
            ("10:07".into(), "Ran cargo test webhooks: 14 passed".into()),
            ("10:09".into(), "Added src/webhooks/dead_letters.rs".into()),
        ],
    };
    WorkData {
        reference: "acme/api#412".into(),
        title: "Retry failed webhooks with backoff".into(),
        issue_url: "https://github.com/acme/api/issues/412".into(),
        issue_body: "When a receiver is down, its webhooks are dropped after one attempt. Retry them with exponential backoff, and keep the ones that never get through so they can be replayed.\n\n- [ ] Retry with backoff\n- [ ] Keep dead letters\n- [ ] Tests".into(),
        state,
        branch: "issue-412-retry-webhooks".into(),
        folder: "~/Code/acme/harness/.worktrees/issue-412-retry-webhooks".into(),
        worktrees,
        prs,
        ask,
        activity,
        model: "claude-opus-5-5".into(),
        cost: 1.84,
        context: if mock == Mock::Working { 0.74 } else { 0.42 },
        last_check: if matches!(mock, Mock::Starting) { None } else { Some(mock != Mock::ChecksFailing) },
        idle_days: if mock == Mock::Stale { 5 } else { 0 },
    }
}

pub struct WorkPreview {
    mock: Mock,
    panel: Entity<WorkPanel>,
}

impl WorkPreview {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mock = Mock::Working;
        Self { mock, panel: Self::make(mock, window, cx) }
    }

    fn make(mock: Mock, window: &mut Window, cx: &mut Context<Self>) -> Entity<WorkPanel> {
        cx.new(|cx| {
            let mut panel = WorkPanel::new(data(mock), None, window, cx);
            panel.show_pane(mock.pane());
            panel
        })
    }
}

impl Render for WorkPreview {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_row()
                    .flex_wrap()
                    .items_center()
                    .gap_1()
                    .px_3()
                    .py_2()
                    .border_b_1()
                    .border_color(theme.border)
                    .bg(theme.sidebar)
                    .child(div().pr_2().text_xs().text_color(theme.secondary).child("State"))
                    .children(Mock::ALL.into_iter().enumerate().map(|(i, mock)| {
                        let on = mock == self.mock;
                        div()
                            .id(SharedString::from(format!("work-state-{i}")))
                            .px_2()
                            .py_0p5()
                            .rounded_md()
                            .text_xs()
                            .cursor_pointer()
                            .when(on, |d| d.bg(theme.selected).text_color(theme.on_selected))
                            .when(!on, |d| d.text_color(theme.secondary).hover(|s| s.bg(theme.row_selected)))
                            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                                this.mock = mock;
                                this.panel = Self::make(mock, window, cx);
                                cx.notify();
                            }))
                            .child(mock.title())
                    })),
            )
            .child(div().flex_1().min_h_0().child(self.panel.clone()))
    }
}
