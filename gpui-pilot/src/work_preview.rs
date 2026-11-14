//! Work Preview: a Work on This session's tab in each of its states, from a
//! made-up issue, to refine the UI before it's wired to real sessions. No
//! claude runs and nothing is written.

use crate::charts::Theme;
use crate::work_panel::{Ask, ChangedFile, Feedback, LocalFinding, PrState, Question, StageRun, StageStatus, StepRun, WorkData, WorkPanel, WorkPr, WorkState, WorkflowRun, Worktree};
use gpui::{div, prelude::*, ClickEvent, Context, Entity, SharedString, Window};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mock {
    Starting,
    Working,
    Permission,
    Question,
    YourTurn,
    LocalReview,
    CommandFailing,
    PrOpened,
    ChecksFailing,
    ChangesRequested,
    Conflicts,
    Merged,
    Exited,
    Stale,
}

impl Mock {
    const ALL: [Mock; 14] = [
        Mock::Starting,
        Mock::Working,
        Mock::Permission,
        Mock::Question,
        Mock::YourTurn,
        Mock::LocalReview,
        Mock::CommandFailing,
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
            Mock::LocalReview => "Local review",
            Mock::CommandFailing => "Command failing",
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
            Mock::LocalReview | Mock::CommandFailing => "workflow",
            Mock::PrOpened | Mock::ChecksFailing | Mock::ChangesRequested | Mock::Conflicts => "issue",
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
        Mock::Working | Mock::Permission | Mock::Question | Mock::YourTurn | Mock::LocalReview | Mock::CommandFailing => {
            vec![Worktree { name: "api".into(), path: String::new(), unpushed: None, base: "main".into(), files: files(), uncommitted: files().into_iter().skip(1).collect() }]
        }
        Mock::Merged => vec![Worktree { name: "api".into(), path: String::new(), unpushed: Some(0), base: "main".into(), files: Vec::new(), uncommitted: Vec::new() }],
        _ => vec![Worktree { name: "api".into(), path: String::new(), unpushed: Some(0), base: "main".into(), files: files(), uncommitted: Vec::new() }],
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
        cost: Some(1.84),
        context: if mock == Mock::Working { 0.74 } else { 0.42 },
        last_check: if matches!(mock, Mock::Starting) { None } else { Some(mock != Mock::ChecksFailing) },
        idle_days: if mock == Mock::Stale { 5 } else { 0 },
        workflow: Some(workflow(mock)),
    }
}

/// The made-up workflow "Careful": a scout, the session, a local review by
/// two reviewers and two commands, then a reviewer on the PR and the bots.
fn workflow(mock: Mock) -> WorkflowRun {
    use StageStatus::*;
    let step = |name: &str, provider: &str, status: StageStatus, summary: &str, findings: Vec<LocalFinding>| StepRun { name: name.into(), provider: provider.into(), status, summary: summary.into(), findings };
    let finding = |severity: &str, path: &str, text: &str, outcome: Option<&str>| LocalFinding { severity: severity.into(), path: path.into(), text: text.into(), outcome: outcome.map(str::to_string) };
    // How far each mock has got: before the local review, in it, past it.
    let (prepare, session, local, pr, done) = match mock {
        Mock::Starting => (Running, Waiting, Waiting, Waiting, Waiting),
        Mock::Working | Mock::Permission | Mock::Question => (Done, Running, Waiting, Waiting, Waiting),
        Mock::YourTurn => (Done, Done, Waiting, Waiting, Waiting),
        Mock::LocalReview | Mock::CommandFailing => (Done, Running, Holding, Waiting, Waiting),
        Mock::PrOpened | Mock::ChangesRequested | Mock::Conflicts => (Done, Done, Done, Running, Waiting),
        Mock::ChecksFailing => (Done, Done, Done, Failed, Waiting),
        Mock::Merged => (Done, Done, Done, Done, Done),
        Mock::Exited | Mock::Stale => (Done, Done, Done, Running, Waiting),
    };
    let reviewing = mock == Mock::LocalReview;
    let failing = mock == Mock::CommandFailing;
    let local_steps = if local == Waiting {
        vec![
            step("Correctness reviewer", "Claude Code", Waiting, "", vec![]),
            step("Junie", "Junie", Waiting, "", vec![]),
            step("cargo test", "Command", Waiting, "", vec![]),
            step("cargo clippy -- -D warnings", "Command", Waiting, "", vec![]),
        ]
    } else {
        vec![
            step(
                "Correctness reviewer",
                "Claude Code",
                if reviewing { Holding } else { Done },
                if reviewing { "Round 2 of 3: 1 blocker still open." } else { "Settled in round 2." },
                vec![
                    finding("blocker", "src/webhooks/sender.rs:51", "Retries share one delay, so every failed hook retries at the same moment. Add jitter.", if reviewing { None } else { Some("Fixed in 7c1e9a2") }),
                    finding("major", "src/webhooks/dead_letters.rs:18", "Dead letters are kept forever; add an expiry.", Some("Fixed in 3b8d410")),
                    finding("nit", "tests/webhooks.rs:40", "The test name says backoff but checks retries only.", Some("Answered: renamed in the next commit, with the backoff check added.")),
                ],
            ),
            step("Junie", "Junie", Done, "Found nothing new in round 2.", vec![]),
            step(
                "cargo test",
                "Command",
                if failing { Failed } else { Done },
                if failing { "Failed: webhooks::retries_with_backoff panicked at 'attempt 3 waited 4s, expected 2s'" } else { "Passed in 48s." },
                vec![],
            ),
            step("cargo clippy -- -D warnings", "Command", Done, "Passed in 12s.", vec![]),
        ]
    };
    WorkflowRun {
        name: "Careful".into(),
        stages: vec![
            StageRun {
                title: "Prepare".into(),
                status: prepare,
                note: String::new(),
                steps: vec![step(
                    "Scout",
                    "Claude Code",
                    prepare,
                    if prepare == Done { "Mapped the webhook sender, its callers and the retry settings; noted the dead letters table doesn't exist yet." } else { "Reading the code" },
                    vec![],
                )],
            },
            StageRun { title: "Session".into(), status: session, note: String::new(), steps: vec![step("Session", "Claude Code", session, "The implementer: the terminal on the left.", vec![])] },
            StageRun {
                title: "Local review".into(),
                status: local,
                note: match (reviewing, failing, local) {
                    (true, _, _) => "Round 2 · 1 blocker".into(),
                    (_, true, _) => "cargo test failing".into(),
                    (_, _, Done) => "Clear".into(),
                    _ => String::new(),
                },
                steps: local_steps,
            },
            StageRun {
                title: "On the PR".into(),
                status: pr,
                note: match mock {
                    Mock::ChecksFailing => "Checks failing".into(),
                    Mock::ChangesRequested => "2 comments".into(),
                    _ => String::new(),
                },
                steps: vec![
                    step("Security reviewer", "Claude Code", if pr == Waiting { Waiting } else { Done }, if pr == Waiting { "" } else { "No findings." }, vec![]),
                    step("Bot comments", "Session", pr, if pr == Waiting { "" } else { "CodeRabbit: 1 comment, sent to the session." }, vec![]),
                ],
            },
            StageRun { title: "Done".into(), status: done, note: String::new(), steps: vec![] },
        ],
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
