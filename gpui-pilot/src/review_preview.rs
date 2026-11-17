//! Review Preview: the review panel in each of its states, from a made-up
//! pull request, to refine the review UI without running claude or posting
//! to GitHub. Pick a state along the top; the panel below is built afresh
//! for it. Post to GitHub here only pretends.

use crate::charts::Theme;
use crate::review::{self, Snapshot};
use crate::review_panel::{Post, ReviewPanel};
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, SharedString, Window};
use std::collections::HashSet;
use std::sync::Arc;

const REPO: &str = "acme/ledger";
const NUMBER: i64 = 214;

/// What claude ends its reply with, in each case: the same fenced JSON a
/// real review ends with, read by the same parser.
const FINDINGS: &str = r#"I read the diff and the surrounding code.

```json
{
  "headline": "Adds idempotency keys to the payments API so a retried request can't charge twice.",
  "summary": "A careful change: the key is checked before any work starts, and the tests cover the retry paths. A few things to look at before merging:\n\n**Blocker**\n- The lookup and the insert aren't in one transaction, so two retries at once can both pass the check.\n\n**Major**\n- Keys never expire, so the table grows without bound.\n\n**Minor**\n- The 409 body doesn't say which request the key belonged to.\n\n**Nit**\n- A leftover debug log in the handler.",
  "verdict": "request_changes",
  "effort": 3,
  "walkthrough": [
    {"title": "Storage", "summary": "A new idempotency_keys table and its migration, keyed by account and key.", "files": ["migrations/0042_idempotency_keys.sql", "src/store/keys.rs"]},
    {"title": "Request handling", "summary": "The payments handler checks the key first and replays the stored response on a match.", "files": ["src/api/payments.rs", "src/api/errors.rs"]},
    {"title": "Tests", "summary": "Retry, conflict and replay cases.", "files": ["tests/payments_idempotency.rs"]}
  ],
  "flow": ["The client sends POST /payments with an Idempotency-Key header", "The handler looks the key up for the account", "On a match it replays the stored response; on a conflict it returns 409", "Otherwise it charges, then stores the key with the response"],
  "findings": [
    {"path": "src/api/payments.rs", "line": 88, "severity": "blocker", "category": "correctness", "comment": "The lookup at line 88 and the insert at line 131 run in separate transactions, so two concurrent retries can both miss the key and both charge. Take the lock (or insert first with ON CONFLICT DO NOTHING) inside one transaction.", "suggestion": "let mut tx = store.begin().await?;"},
    {"path": "src/store/keys.rs", "line": 24, "severity": "major", "category": "stability", "comment": "Keys are never deleted. Add an expiry (24 hours is common) and a sweep, or the table grows forever."},
    {"path": "src/api/errors.rs", "line": 57, "severity": "minor", "category": "maintainability", "comment": "The 409 body is just \"conflict\". Say that the key was used for a different request, so a client can tell this from other conflicts."},
    {"path": "src/api/payments.rs", "line": 140, "severity": "nit", "category": "maintainability", "comment": "Leftover debug log.", "suggestion": ""},
    {"path": "README.md", "line": 12, "severity": "minor", "category": "maintainability", "comment": "The README's API section doesn't mention the new header."}
  ],
  "risk": {
    "alignment": {"verdict": "good", "reason": "Does what the issue asks, and nothing else."},
    "impact": {"verdict": "medium", "reason": "Every payment request goes through the new check."},
    "verification": {"verdict": "decent", "reason": "Retries are tested; concurrent retries aren't."},
    "rollback": {"verdict": "medium", "reason": "Reverting leaves the new table behind, which is harmless."},
    "detection": {"verdict": "poor", "reason": "A double charge would only show up when a customer reports it."},
    "gaps": ["A test with two concurrent retries of one key (`tests/payments_idempotency.rs`)", "A metric or alert on 409s from the payments handler (`src/api/payments.rs:95`)"]
  },
  "criteria": [
    {"criterion": "A retried request with the same key never charges twice", "issue": "acme/api#311", "status": "partial", "evidence": "Sequential retries are tested; concurrent ones can still both charge."},
    {"criterion": "A reused key with a different body returns 409", "issue": "acme/api#311", "status": "met", "evidence": "tests/payments_idempotency.rs: conflicting_body_is_409"},
    {"criterion": "Keys expire after 24 hours", "issue": "acme/api#311", "status": "missing", "evidence": "No expiry or sweep in src/store/keys.rs."}
  ],
  "resolved": [],
  "applied": [],
  "learnings": []
}
```"#;

const APPROVE: &str = r#"```json
{
  "headline": "Bumps the HTTP client to 2.4 and drops the retry shim it now makes unnecessary.",
  "summary": "A clean upgrade. The shim's behaviour is now the client's default, and the tests that covered it still pass against the new version.",
  "verdict": "approve",
  "effort": 1,
  "walkthrough": [{"title": "Dependency", "summary": "The version bump and the shim's removal.", "files": ["Cargo.toml", "src/http/retry.rs"]}],
  "flow": [],
  "findings": []
}
```"#;

const AGAIN: &str = r#"```json
{
  "headline": "Adds idempotency keys to the payments API so a retried request can't charge twice.",
  "summary": "Two new commits since the last review. The race is fixed: the lookup and insert now share a transaction. Keys expire after 24 hours with a nightly sweep.\n\nStill open:\n\n**Minor**\n- The 409 body still doesn't name the earlier request.",
  "verdict": "comment",
  "effort": 2,
  "walkthrough": [
    {"title": "Storage", "summary": "Expiry column and the sweep job.", "files": ["migrations/0043_key_expiry.sql", "src/store/keys.rs", "src/jobs/sweep_keys.rs"]},
    {"title": "Request handling", "summary": "One transaction around the check and the insert.", "files": ["src/api/payments.rs"]}
  ],
  "flow": [],
  "findings": [
    {"path": "src/api/errors.rs", "line": 57, "severity": "minor", "category": "maintainability", "comment": "The 409 body is still just \"conflict\"; say the key was used for a different request."}
  ],
  "resolved": ["PRRT_kwDOAbc123", "PRRT_kwDOAbc124"],
  "applied": [{"learning": "learnings/payments/transactions.md", "path": "src/api/payments.rs", "line": 88, "note": "Checked that the whole check-and-insert is one transaction, as the learning asks, rather than raising the lock order."}],
  "learnings": [{"path": "src/jobs/", "rule": "Sweep jobs delete in batches of 1000.", "reason": "A single large delete locked the table in production last year.", "source": "https://github.com/acme/ledger/pull/214#discussion_r1", "author": "sam"}]
}
```"#;

#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Reviewing,
    Findings,
    Approve,
    ReviewAgain,
    Ended,
    PostReady,
    PostOwn,
    Posting,
    Posted,
    PostFailed,
}

impl State {
    const ALL: [State; 10] = [
        State::Reviewing,
        State::Findings,
        State::Approve,
        State::ReviewAgain,
        State::Ended,
        State::PostReady,
        State::PostOwn,
        State::Posting,
        State::Posted,
        State::PostFailed,
    ];

    fn title(self) -> &'static str {
        match self {
            State::Reviewing => "Reviewing",
            State::Findings => "Findings",
            State::Approve => "Approve, none found",
            State::ReviewAgain => "Reviewed again",
            State::Ended => "Session ended",
            State::PostReady => "Post",
            State::PostOwn => "Post, own PR",
            State::Posting => "Posting",
            State::Posted => "Posted",
            State::PostFailed => "Post failed",
        }
    }
}

fn snapshot(own: bool) -> Snapshot {
    // The diff shows these lines; README.md isn't in it, so its finding goes
    // in the body.
    Snapshot::sample(own, &[("src/api/payments.rs", 80..=145), ("src/store/keys.rs", 1..=60), ("src/api/errors.rs", 50..=62)])
}

pub struct ReviewPreview {
    state: State,
    panel: Entity<ReviewPanel>,
}

impl ReviewPreview {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let panel = Self::make(State::Findings, window, cx);
        Self { state: State::Findings, panel }
    }

    fn make(state: State, window: &mut Window, cx: &mut Context<Self>) -> Entity<ReviewPanel> {
        let result = match state {
            State::Reviewing => None,
            State::Approve => review::parse(APPROVE),
            State::ReviewAgain => review::parse(AGAIN),
            _ => review::parse(FINDINGS),
        };
        let idle = !matches!(state, State::Reviewing | State::Ended);
        let working = state == State::Reviewing;
        let own = state == State::PostOwn;
        let post = match state {
            State::PostReady | State::PostOwn => result.as_ref().map(|r| ReviewPanel::ready(r, &HashSet::new(), Arc::new(snapshot(own)), window, cx)),
            State::Posting => Some(Post::Posting),
            State::Posted => Some(Post::Posted(format!("https://github.com/{REPO}/pull/{NUMBER}#pullrequestreview-0"))),
            State::PostFailed => Some(Post::Failed("GitHub refused the review (422): the commit it's for is no longer the head of the pull request.".into())),
            _ => None,
        };
        cx.new(|cx| ReviewPanel::preview(REPO, NUMBER, result, idle, working, snapshot(own), post, window, cx))
    }

    fn pick(&mut self, state: State, window: &mut Window, cx: &mut Context<Self>) {
        self.state = state;
        self.panel = Self::make(state, window, cx);
        cx.notify();
    }
}

impl Render for ReviewPreview {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let picker = div()
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
            .children(State::ALL.into_iter().enumerate().map(|(i, state)| {
                let on = state == self.state;
                div()
                    .id(SharedString::from(format!("preview-state-{i}")))
                    .px_2()
                    .py_0p5()
                    .rounded_md()
                    .text_xs()
                    .cursor_pointer()
                    .when(on, |d| d.bg(theme.selected).text_color(theme.on_selected))
                    .when(!on, |d| d.text_color(theme.secondary).hover(|s| s.bg(theme.row_selected)))
                    .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.pick(state, window, cx)))
                    .child(state.title())
            }));
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .child(picker)
            .child(div().flex_1().min_h_0().min_w(px(0.)).child(self.panel.clone()))
    }
}
