//! Assistant Preview: a clickable mock-up of the assistant panel, from
//! made-up sessions, questions and investigations, to shape its UI before
//! any of it is built. Nothing here runs claude, reads a session or calls
//! GitHub: replies and events are canned, on timers.
//!
//! Run it on its own with `--assistant-preview`: it opens only this window,
//! never the workspace, so it doesn't touch a running Gannin.

use crate::charts::{self, Theme};
use gpui::{div, prelude::*, px, AnyElement, ClickEvent, Context, Entity, FocusHandle, Focusable, FontWeight, Hsla, KeyDownEvent, SharedString, Window};
use std::collections::HashSet;
use std::time::Duration;

// MARK: - Model

#[derive(Clone, Copy, PartialEq, Eq)]
enum Lane {
    Build,
    Review,
    Ask,
}

impl Lane {
    fn title(self) -> &'static str {
        match self {
            Lane::Build => "Build",
            Lane::Review => "Review",
            Lane::Ask => "Ask",
        }
    }
}

/// Why an item needs you, which orders the queue: a blocked session wastes
/// time while it waits, so it comes first.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Need {
    Blocked,
    Decide,
    Respond,
    Back,
}

impl Need {
    fn title(self) -> &'static str {
        match self {
            Need::Blocked => "Blocked",
            Need::Decide => "Decide",
            Need::Respond => "Respond",
            Need::Back => "Back",
        }
    }
}

#[derive(Clone)]
struct Item {
    lane: Lane,
    need: Need,
    subject: String,
    /// What to do, as a task: "Review ready to post".
    task: String,
    detail: String,
    minutes: u32,
    /// The first is the main action (Return).
    actions: Vec<&'static str>,
    thread: Option<usize>,
    scope: usize,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Main,
    Question,
    Investigation,
    Build,
    Review,
}

impl Kind {
    fn title(self) -> &'static str {
        match self {
            Kind::Main => "",
            Kind::Question => "Question",
            Kind::Investigation => "Investigation",
            Kind::Build => "Build",
            Kind::Review => "Review",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Working,
    Done,
    Parked,
    Waiting,
}

impl State {
    fn glyph(self) -> &'static str {
        match self {
            State::Working => "◐",
            State::Done => "✓",
            State::Parked => "⏸",
            State::Waiting => "●",
        }
    }
}

#[derive(Clone)]
enum Who {
    You,
    Assistant,
    Worker,
    Event,
}

#[derive(Clone)]
enum Body {
    Text(String),
    /// A question's answer card.
    Answer { headline: String, figures: Vec<(String, String)>, spark: Vec<f64>, caveat: String, how: String, skill: String },
    /// An investigation's findings.
    Findings { cause: String, evidence: Vec<String>, confidence: String, unknown: String },
    /// "Since you looked", at the top of a session's thread.
    Since { what: String, since: String, wants: String },
    /// Catch me up: a line per unread thread.
    CatchUp(Vec<(usize, String)>),
}

#[derive(Clone)]
struct Message {
    who: Who,
    body: Body,
}

#[derive(Clone)]
struct Thread {
    title: String,
    kind: Kind,
    state: State,
    /// The newest line, shown in the list.
    last: String,
    /// What it's doing now, while it works.
    doing: Option<String>,
    unread: bool,
    muted: bool,
    pinned: bool,
    minutes: u32,
    scope: usize,
    messages: Vec<Message>,
}

struct Toast {
    id: usize,
    title: String,
    body: String,
    actions: Vec<&'static str>,
    thread: Option<usize>,
}

const SCOPES: [&str; 4] = ["All", "ctrl-hub harness", "andrew-waters harness", "mini (server)"];

// MARK: - Seed data

fn text(who: Who, s: &str) -> Message {
    Message { who, body: Body::Text(s.into()) }
}

fn seed() -> (Vec<Thread>, Vec<Item>) {
    let threads = vec![
        Thread {
            title: "Main".into(),
            kind: Kind::Main,
            state: State::Done,
            last: "Posted mono#1533. Next: clients#2466?".into(),
            doing: None,
            unread: true,
            muted: false,
            pinned: true,
            minutes: 1,
            scope: 0,
            messages: vec![
                Message { who: Who::Event, body: Body::Text("Morning. 3 things need you, 2 sessions finished overnight on mini, 4 unread threads.".into()) },
                text(Who::You, "post the mono#1533 review"),
                text(Who::Assistant, "Posted mono#1533 as Approve with 2 nits, and resolved 1 thread of yours that's now dealt with."),
                text(Who::Assistant, "Next: clients#2466 has been waiting 3 minutes to run the e2e suite."),
            ],
        },
        Thread {
            title: "SGN permits last week".into(),
            kind: Kind::Question,
            state: State::Done,
            last: "SGN created 1,284 permits last week (+18%)".into(),
            doing: None,
            unread: true,
            muted: false,
            pinned: false,
            minutes: 2,
            scope: 1,
            messages: vec![
                text(Who::You, "how many permits did SGN create last week vs the week before?"),
                Message {
                    who: Who::Worker,
                    body: Body::Answer {
                        headline: "SGN created 1,284 permits last week, up 18% on the week before (1,088).".into(),
                        figures: vec![("Last week".into(), "1,284".into()), ("Week before".into(), "1,088".into()), ("Change".into(), "+18%".into())],
                        spark: vec![940., 1010., 1120., 1088., 1284.],
                        caveat: "Excludes drafts that were never submitted.".into(),
                        how: "ClickHouse (prod, read only)\nSELECT toStartOfWeek(created_at) AS week, count()\nFROM permits WHERE org = 'SGN' AND status != 'draft'\nGROUP BY week ORDER BY week DESC LIMIT 5".into(),
                        skill: "ch/analytics".into(),
                    },
                },
            ],
        },
        Thread {
            title: "product#4251 export times out".into(),
            kind: Kind::Investigation,
            state: State::Working,
            last: "Reading HyperDX traces for /permits/export".into(),
            doing: Some("Reading HyperDX traces for /permits/export".into()),
            unread: true,
            muted: false,
            pinned: false,
            minutes: 0,
            scope: 1,
            messages: vec![
                text(Who::You, "investigate product#4251"),
                text(Who::Worker, "Read the ticket: exports over ~5,000 permits time out for two orgs since Tuesday. Planning with triage: logs first, then the query, then the data."),
                text(Who::Worker, "Skills: triage, hyperdx, mongo (prod, read only)."),
            ],
        },
        Thread {
            title: "mono#1539 Add export retries".into(),
            kind: Kind::Review,
            state: State::Waiting,
            last: "Review ready: approve, 2 nits".into(),
            doing: None,
            unread: true,
            muted: false,
            pinned: false,
            minutes: 12,
            scope: 1,
            messages: vec![
                Message { who: Who::Event, body: Body::Since { what: "Adds retries with backoff to permit exports".into(), since: "3 commits, 1 comment from Sam, review re-run".into(), wants: "Post the review".into() } },
                text(Who::Worker, "Reviewed afresh after the 3 new commits. Verdict: approve. Two nits: a log line at debug that should be info, and a magic number for the backoff cap."),
            ],
        },
        Thread {
            title: "clients#2466 Serial search in Log a job".into(),
            kind: Kind::Build,
            state: State::Waiting,
            last: "Wants to run the e2e suite".into(),
            doing: None,
            unread: false,
            muted: false,
            pinned: false,
            minutes: 3,
            scope: 1,
            messages: vec![
                Message { who: Who::Event, body: Body::Since { what: "Serial number search in the mobile Log a job picker".into(), since: "Tests written, 6 files changed".into(), wants: "Allow `pnpm e2e` (about 8 minutes)".into() } },
                text(Who::Worker, "Unit tests pass. I'd like to run the e2e suite: `pnpm e2e --project mobile`."),
            ],
        },
        Thread {
            title: "mono#1528 Feedback subscriber pings CS".into(),
            kind: Kind::Build,
            state: State::Working,
            last: "Writing tests".into(),
            doing: Some("Writing tests for the subscriber".into()),
            unread: false,
            muted: false,
            pinned: false,
            minutes: 4,
            scope: 3,
            messages: vec![text(Who::Worker, "Subscriber done; writing its tests now.")],
        },
        Thread {
            title: "lib.slugify#1 First release".into(),
            kind: Kind::Review,
            state: State::Waiting,
            last: "Asked you a question".into(),
            doing: None,
            unread: false,
            muted: false,
            pinned: false,
            minutes: 40,
            scope: 2,
            messages: vec![text(Who::Worker, "Should I treat the missing CHANGELOG as a blocker, or a nit since it's a first release?")],
        },
        Thread {
            title: "api#12 Rate limit headers".into(),
            kind: Kind::Review,
            state: State::Done,
            last: "Posted as Comment".into(),
            doing: None,
            unread: false,
            muted: false,
            pinned: false,
            minutes: 64,
            scope: 2,
            messages: vec![text(Who::Worker, "Posted as Comment with 3 findings.")],
        },
    ];
    let items = vec![
        Item { lane: Lane::Build, need: Need::Blocked, subject: "clients#2466".into(), task: "Wants to run the e2e suite".into(), detail: "pnpm e2e --project mobile, about 8 minutes".into(), minutes: 3, actions: vec!["Allow", "Deny", "Open"], thread: Some(4), scope: 1 },
        Item { lane: Lane::Review, need: Need::Blocked, subject: "lib.slugify#1".into(), task: "Asked you a question".into(), detail: "Missing CHANGELOG: blocker, or nit for a first release?".into(), minutes: 40, actions: vec!["Nit", "Blocker", "Open"], thread: Some(6), scope: 2 },
        Item { lane: Lane::Review, need: Need::Decide, subject: "mono#1539".into(), task: "Review ready to post".into(), detail: "Approve, 2 nits".into(), minutes: 12, actions: vec!["Post as Approve", "Look", "Open"], thread: Some(3), scope: 1 },
        Item { lane: Lane::Review, need: Need::Respond, subject: "api#1544".into(), task: "Sam asked for changes".into(), detail: "On your PR: 2 comments on the retry loop".into(), minutes: 25, actions: vec!["Start fix", "Open on GitHub"], thread: None, scope: 1 },
        Item { lane: Lane::Review, need: Need::Decide, subject: "mono#1541".into(), task: "Review requested of you".into(), detail: "No session yet. Jo, 240 lines".into(), minutes: 55, actions: vec!["Start review", "Open on GitHub"], thread: None, scope: 1 },
    ];
    (threads, items)
}

// MARK: - The preview

pub struct AssistantPreview {
    focus: FocusHandle,
    composer: Entity<editor::Editor>,
    threads: Vec<Thread>,
    items: Vec<Item>,
    done: Vec<String>,
    selected: usize,
    lane: Option<Lane>,
    scope: usize,
    scope_menu: bool,
    more_menu: bool,
    later_menu: bool,
    unread_only: bool,
    open: Option<usize>,
    /// Answer cards whose "How I got it" is open: (thread, message).
    how_open: HashSet<(usize, usize)>,
    toasts: Vec<Toast>,
    next_toast: usize,
    focus_mode: bool,
    held: usize,
    /// What the fake workspace shows, after Open.
    workspace: String,
}

impl AssistantPreview {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let composer = cx.new(|cx| {
            let mut editor = editor::Editor::single_line(window, cx);
            editor.set_placeholder_text("Ask anything, / for commands, @ to name a thread", window, cx);
            editor
        });
        let (threads, items) = seed();
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        Self {
            focus,
            composer,
            threads,
            items,
            done: vec!["Posted mono#1533 (approve)".into(), "Allowed mono#1528 to run migrations".into()],
            selected: 0,
            lane: None,
            scope: 0,
            scope_menu: false,
            more_menu: false,
            later_menu: false,
            unread_only: false,
            open: None,
            how_open: HashSet::new(),
            toasts: Vec::new(),
            next_toast: 0,
            focus_mode: false,
            held: 0,
            workspace: "Your tabs would be here.".into(),
        }
    }

    // MARK: Queries

    fn in_scope(&self, scope: usize) -> bool {
        self.scope == 0 || scope == 0 || scope == self.scope
    }

    /// The queue as shown: in scope and lane, blocked first, then oldest.
    fn queue(&self) -> Vec<usize> {
        let mut shown: Vec<usize> = (0..self.items.len()).filter(|&i| self.in_scope(self.items[i].scope) && self.lane.is_none_or(|l| self.items[i].lane == l)).collect();
        shown.sort_by(|&a, &b| self.items[a].need.cmp(&self.items[b].need).then(self.items[b].minutes.cmp(&self.items[a].minutes)));
        shown
    }

    /// Threads as listed: pinned, then unread, then newest.
    fn listed(&self) -> Vec<usize> {
        let mut shown: Vec<usize> = (0..self.threads.len()).filter(|&i| self.in_scope(self.threads[i].scope) && (!self.unread_only || self.is_unread(i))).collect();
        shown.sort_by(|&a, &b| {
            let (x, y) = (&self.threads[a], &self.threads[b]);
            y.pinned.cmp(&x.pinned).then(self.is_unread(b).cmp(&self.is_unread(a))).then(x.minutes.cmp(&y.minutes))
        });
        shown
    }

    fn is_unread(&self, i: usize) -> bool {
        self.threads[i].unread && !self.threads[i].muted
    }

    fn unread_count(&self) -> usize {
        (0..self.threads.len()).filter(|&i| self.in_scope(self.threads[i].scope) && self.is_unread(i)).count()
    }

    fn lane_count(&self, lane: Lane) -> usize {
        self.items.iter().filter(|i| i.lane == lane && self.in_scope(i.scope)).count()
    }

    // MARK: Actions

    fn act(&mut self, item: usize, action: &'static str, cx: &mut Context<Self>) {
        let Some(it) = self.items.get(item).cloned() else { return };
        self.later_menu = false;
        match action {
            "Open" | "Look" | "Open on GitHub" => {
                self.workspace = format!("Switched to {}'s tab.", it.subject);
                if let Some(t) = it.thread {
                    self.open_thread(t, cx);
                }
                cx.notify();
                return;
            }
            _ => {}
        }
        self.done.insert(0, format!("{}: {}", it.subject, action));
        if let Some(t) = it.thread {
            let thread = &mut self.threads[t];
            thread.unread = false;
            thread.state = State::Working;
            thread.last = format!("You: {action}");
            thread.messages.push(text(Who::You, action));
        }
        self.items.remove(item);
        self.selected = 0;
        if let Some(next) = self.queue().first().map(|&i| self.items[i].subject.clone()) {
            self.say(format!("Done: {} {}. Next: {next}?", it.subject, action.to_lowercase()));
        } else {
            self.say(format!("Done: {} {}. Nothing else needs you.", it.subject, action.to_lowercase()));
        }
        cx.notify();
    }

    fn later(&mut self, item: usize, when: &str, cx: &mut Context<Self>) {
        if item >= self.items.len() {
            return;
        }
        let it = self.items.remove(item);
        self.later_menu = false;
        self.selected = 0;
        if let Some(t) = it.thread {
            self.threads[t].state = State::Parked;
            self.threads[t].last = format!("Parked until {when}");
        }
        self.say(format!("Parked {} until {when}. It comes back here by itself.", it.subject));
        // Back after a moment, as if the time had come.
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(12)).await;
            this.update(cx, |this, cx| {
                let mut back = it.clone();
                back.need = Need::Back;
                back.task = format!("Back: {}", it.task.to_lowercase());
                back.minutes = 0;
                if let Some(t) = it.thread {
                    this.threads[t].state = State::Waiting;
                    this.threads[t].unread = true;
                    this.threads[t].last = "Back from Later".into();
                }
                this.notify(format!("{} is back", it.subject), it.task.clone(), it.actions.clone(), it.thread, cx);
                this.items.push(back);
                cx.notify();
            })
            .ok();
        })
        .detach();
        cx.notify();
    }

    fn say(&mut self, line: String) {
        self.threads[0].messages.push(text(Who::Assistant, &line));
        self.threads[0].last = line;
        self.threads[0].minutes = 0;
    }

    fn open_thread(&mut self, t: usize, cx: &mut Context<Self>) {
        self.open = Some(t);
        self.threads[t].unread = false;
        self.scope_menu = false;
        self.more_menu = false;
        cx.notify();
    }

    fn next_unread(&mut self, back: bool, cx: &mut Context<Self>) {
        let mut list = self.listed();
        if back {
            list.reverse();
        }
        let after = self.open.and_then(|o| list.iter().position(|&i| i == o)).map_or(0, |p| p + 1);
        let found = list.iter().skip(after).chain(list.iter().take(after)).copied().find(|&i| self.is_unread(i));
        if let Some(t) = found {
            self.open_thread(t, cx);
        }
    }

    /// A notification, as a banner in the corner. Held while Focus is on,
    /// unless something's blocked.
    fn notify(&mut self, title: String, body: String, actions: Vec<&'static str>, thread: Option<usize>, cx: &mut Context<Self>) {
        let blocked = title.contains("waiting") || title.contains("blocked");
        if self.focus_mode && !blocked {
            self.held += 1;
            cx.notify();
            return;
        }
        let id = self.next_toast;
        self.next_toast += 1;
        self.toasts.push(Toast { id, title, body, actions, thread });
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(9)).await;
            this.update(cx, |this, cx| {
                this.toasts.retain(|t| t.id != id);
                cx.notify();
            })
            .ok();
        })
        .detach();
        cx.notify();
    }

    fn send(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let typed = self.composer.read(cx).text(cx).trim().to_string();
        if typed.is_empty() {
            return;
        }
        self.composer.update(cx, |editor, cx| editor.set_text("", window, cx));
        // In an open thread other than Main, it goes to that thread's worker.
        if let Some(t) = self.open.filter(|&t| t != 0) {
            self.threads[t].messages.push(text(Who::You, &typed));
            self.threads[t].state = State::Working;
            self.threads[t].doing = Some("Reading your follow-up".into());
            self.threads[t].last = "Working on your follow-up".into();
            self.reply_later(t, 3, Message { who: Who::Worker, body: Body::Text("Split by region: North 512, Central 431, South 341. North is where the rise is (+34%).".into()) }, "Follow-up answered".into(), cx);
            cx.notify();
            return;
        }
        self.threads[0].messages.push(text(Who::You, &typed));
        let lower = typed.to_lowercase();
        if lower.starts_with("/waiting") {
            let lines: Vec<String> = self.queue().iter().map(|&i| format!("{}: {} ({}m)", self.items[i].subject, self.items[i].task.to_lowercase(), self.items[i].minutes)).collect();
            self.say(if lines.is_empty() { "Nothing needs you.".into() } else { lines.join("\n") });
        } else if lower.contains("catch me up") || lower.starts_with("/catch") {
            let lines: Vec<(usize, String)> = self.listed().into_iter().filter(|&i| i != 0 && self.is_unread(i)).map(|i| (i, format!("{}: {}", self.threads[i].title, self.threads[i].last))).collect();
            self.threads[0].messages.push(Message { who: Who::Assistant, body: Body::CatchUp(lines) });
        } else if lower.starts_with("investigate") || lower.contains('#') && lower.contains("bug") {
            self.start_investigation(typed, cx);
        } else {
            self.start_question(typed, cx);
        }
        self.open = Some(0);
        cx.notify();
    }

    fn start_question(&mut self, question: String, cx: &mut Context<Self>) {
        let title: String = question.chars().take(40).collect();
        self.threads.push(Thread {
            title: title.clone(),
            kind: Kind::Question,
            state: State::Working,
            last: "Picking a skill".into(),
            doing: Some("Picking a skill: ch/analytics in ctrl-hub".into()),
            unread: false,
            muted: false,
            pinned: false,
            minutes: 0,
            scope: 1,
            messages: vec![text(Who::You, &question), text(Who::Event, "Asking in ctrl-hub, with ch/analytics, on prod (read only)")],
        });
        let t = self.threads.len() - 1;
        self.say(format!("Asking in a thread: \"{title}\""));
        self.progress_later(t, 2, "Querying ClickHouse: permits by org, by week", cx);
        let answer = Message {
            who: Who::Worker,
            body: Body::Answer {
                headline: "Open permits are down 6% on last month: 3,912 now, against 4,160.".into(),
                figures: vec![("Now".into(), "3,912".into()), ("A month ago".into(), "4,160".into()), ("Change".into(), "-6%".into())],
                spark: vec![4300., 4210., 4160., 4050., 3912.],
                caveat: "Counts permits in Open or Active; Suspended isn't included.".into(),
                how: "ClickHouse (prod, read only)\nSELECT toStartOfWeek(snapshot_at) AS week, countIf(status IN ('open','active'))\nFROM permit_snapshots GROUP BY week ORDER BY week DESC LIMIT 5".into(),
                skill: "ch/analytics".into(),
            },
        };
        self.reply_later(t, 6, answer, "Open permits are down 6% on last month".into(), cx);
    }

    fn start_investigation(&mut self, ask: String, cx: &mut Context<Self>) {
        let title: String = ask.trim_start_matches("investigate").trim().chars().take(40).collect();
        self.threads.push(Thread {
            title: title.clone(),
            kind: Kind::Investigation,
            state: State::Working,
            last: "Reading the ticket".into(),
            doing: Some("Reading the ticket".into()),
            unread: false,
            muted: false,
            pinned: false,
            minutes: 0,
            scope: 1,
            messages: vec![text(Who::You, &ask), text(Who::Event, "Investigating in ctrl-hub with triage; read only until you Start fix")],
        });
        let t = self.threads.len() - 1;
        self.say(format!("Investigating in a thread: {title}"));
        self.progress_later(t, 2, "Reading HyperDX traces", cx);
        self.progress_later(t, 5, "Checking documents in mongo (prod, read only)", cx);
        let findings = Message {
            who: Who::Worker,
            body: Body::Findings {
                cause: "The export query lost its index on Tuesday: a migration renamed org_id to organisation_id, and the compound index still names the old field.".into(),
                evidence: vec![
                    "HyperDX: /permits/export p95 went from 2.1s to 31s on Tuesday 14:02".into(),
                    "mongo explain: COLLSCAN on permits, 1.2M documents examined".into(),
                    "Migration 0142 renamed the field; the index wasn't changed".into(),
                ],
                confidence: "High".into(),
                unknown: "Whether other queries use the old index too.".into(),
            },
        };
        self.reply_later(t, 9, findings, format!("{title}: likely cause found"), cx);
        let thread = t;
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(9)).await;
            this.update(cx, |this, cx| {
                this.items.push(Item { lane: Lane::Ask, need: Need::Decide, subject: this.threads[thread].title.clone(), task: "Investigated: decide next step".into(), detail: "Likely cause: an index on a renamed field".into(), minutes: 0, actions: vec!["Start fix", "Comment on ticket", "Dig further"], thread: Some(thread), scope: 1 });
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn progress_later(&mut self, t: usize, secs: u64, doing: &'static str, cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(secs)).await;
            this.update(cx, |this, cx| {
                this.threads[t].doing = Some(doing.into());
                this.threads[t].last = doing.into();
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn reply_later(&mut self, t: usize, secs: u64, message: Message, summary: String, cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(secs)).await;
            this.update(cx, |this, cx| {
                let thread = &mut this.threads[t];
                thread.messages.push(message);
                thread.state = State::Done;
                thread.doing = None;
                thread.last = summary.clone();
                thread.minutes = 0;
                if this.open != Some(t) {
                    thread.unread = true;
                    let title = if thread.kind == Kind::Investigation { "Investigation ready: decide next step".to_string() } else { "Answer ready".to_string() };
                    this.notify(title, summary, vec!["Open", "Copy"], Some(t), cx);
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// The scenario buttons along the top: events as they'd arrive.
    fn simulate(&mut self, which: usize, cx: &mut Context<Self>) {
        match which {
            0 => {
                self.items.push(Item { lane: Lane::Build, need: Need::Blocked, subject: "mono#1528".into(), task: "Wants to run migrations".into(), detail: "make migrate on the staging database".into(), minutes: 0, actions: vec!["Allow", "Deny", "Open"], thread: Some(5), scope: 3 });
                self.threads[5].state = State::Waiting;
                self.threads[5].unread = true;
                self.threads[5].doing = None;
                self.threads[5].last = "Wants to run migrations".into();
                self.notify("mono#1528 is waiting for you".into(), "Allow it to run make migrate on staging?".into(), vec!["Allow", "Deny", "Open"], Some(5), cx);
            }
            1 => {
                self.threads[7].state = State::Done;
                self.threads[7].unread = true;
                self.threads[7].last = "Sam replied: fixed in 3f2a1c".into();
                self.threads[7].minutes = 0;
                self.threads[7].messages.push(Message { who: Who::Event, body: Body::Text("Sam replied on your comment: \"fixed in 3f2a1c\"".into()) });
            }
            2 => {
                self.items.push(Item { lane: Lane::Review, need: Need::Decide, subject: "api#1550".into(), task: "Review ready to post".into(), detail: "Request changes: 1 blocker".into(), minutes: 0, actions: vec!["Post as Request changes", "Look", "Open"], thread: None, scope: 2 });
                self.notify("api#1550: review ready to post".into(), "Request changes, 1 blocker".into(), vec!["Post", "Open", "Later"], None, cx);
            }
            _ => {
                self.focus_mode = !self.focus_mode;
                if !self.focus_mode && self.held > 0 {
                    let held = self.held;
                    self.held = 0;
                    self.notify(format!("{held} things while you were busy"), "Open the assistant to see them".into(), vec!["Open"], None, cx);
                }
            }
        }
        cx.notify();
    }

    // MARK: Keys

    fn key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if self.composer.focus_handle(cx).is_focused(window) {
            if event.keystroke.key == "escape" {
                window.focus(&self.focus, cx);
            }
            return;
        }
        let shift = event.keystroke.modifiers.shift;
        let queue = self.queue();
        if self.later_menu {
            let when = match event.keystroke.key.as_str() {
                "1" => Some("30 minutes"),
                "2" => Some("after lunch"),
                "3" => Some("tomorrow morning"),
                "4" => Some("CI passes"),
                "escape" => {
                    self.later_menu = false;
                    cx.notify();
                    None
                }
                _ => None,
            };
            if let (Some(when), Some(&i)) = (when, queue.get(self.selected)) {
                self.later(i, when, cx);
            }
            return;
        }
        match event.keystroke.key.as_str() {
            "j" => self.selected = (self.selected + 1).min(queue.len().saturating_sub(1)),
            "k" => self.selected = self.selected.saturating_sub(1),
            "enter" => {
                if let Some(&i) = queue.get(self.selected) {
                    let action = self.items[i].actions[0];
                    self.act(i, action, cx);
                }
            }
            "o" => {
                if let Some(&i) = queue.get(self.selected) {
                    self.act(i, "Open", cx);
                }
            }
            "l" => self.later_menu = true,
            "b" => self.lane = if self.lane == Some(Lane::Build) { None } else { Some(Lane::Build) },
            "r" => self.lane = if self.lane == Some(Lane::Review) { None } else { Some(Lane::Review) },
            "a" => self.lane = if self.lane == Some(Lane::Ask) { None } else { Some(Lane::Ask) },
            "n" => self.next_unread(shift, cx),
            "u" if shift => {
                for t in &mut self.threads {
                    t.unread = false;
                }
            }
            "u" => {
                if let Some(t) = self.open {
                    self.threads[t].unread = !self.threads[t].unread;
                }
            }
            "escape" => {
                self.open = None;
                self.scope_menu = false;
                self.more_menu = false;
            }
            "/" => {
                window.focus(&self.composer.focus_handle(cx), cx);
            }
            _ => return,
        }
        cx.notify();
    }
}

// MARK: - Pieces

fn pill(id: impl Into<SharedString>, label: impl Into<SharedString>, on: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id.into())
        .px_2()
        .py_0p5()
        .rounded_md()
        .text_xs()
        .cursor_pointer()
        .when(on, |d| d.bg(theme.selected).text_color(theme.on_selected))
        .when(!on, |d| d.text_color(theme.secondary).hover(|s| s.bg(theme.row_selected)))
        .child(label.into())
}

fn button(id: impl Into<SharedString>, label: impl Into<SharedString>, primary: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id.into())
        .px_2()
        .py_0p5()
        .rounded_md()
        .text_xs()
        .cursor_pointer()
        .border_1()
        .when(primary, |d| d.bg(theme.selected).border_color(theme.selected).text_color(theme.on_selected))
        .when(!primary, |d| d.border_color(theme.border).text_color(theme.fg).hover(|s| s.bg(theme.row_selected)))
        .child(label.into())
}

fn section(label: impl Into<SharedString>, theme: &Theme) -> gpui::Div {
    div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(label.into())
}

fn ago(minutes: u32) -> String {
    match minutes {
        0 => "now".into(),
        m if m < 60 => format!("{m}m"),
        m => format!("{}h", m / 60),
    }
}

/// Waiting gets harder to ignore as it ages, without ever turning red.
fn age_color(minutes: u32, theme: &Theme) -> Hsla {
    match minutes {
        m if m >= 30 => theme.orange(),
        m if m >= 10 => theme.fg,
        _ => theme.secondary,
    }
}

impl AssistantPreview {
    fn header(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let waiting = self.queue().len();
        let working = (0..self.threads.len()).filter(|&i| self.in_scope(self.threads[i].scope) && self.threads[i].state == State::Working).count();
        let done = (0..self.threads.len()).filter(|&i| self.in_scope(self.threads[i].scope) && self.threads[i].state == State::Done && self.is_unread(i)).count();
        div()
            .flex_none()
            .flex()
            .flex_col()
            .gap_1()
            .px_3()
            .py_2()
            .border_b_1()
            .border_color(theme.border)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child("Assistant"))
                    .child(
                        div()
                            .id("scope")
                            .px_2()
                            .py_0p5()
                            .rounded_md()
                            .bg(theme.tile)
                            .text_xs()
                            .text_color(theme.fg)
                            .cursor_pointer()
                            .child(format!("{} ▾", SCOPES[self.scope]))
                            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                this.scope_menu = !this.scope_menu;
                                this.more_menu = false;
                                cx.notify();
                            })),
                    )
                    .child(div().flex_1())
                    .when(self.focus_mode, |d| d.child(div().text_xs().text_color(theme.blue()).child(format!("Focus{}", if self.held > 0 { format!(" · {} held", self.held) } else { String::new() }))))
                    .child(
                        div()
                            .id("more")
                            .px_1()
                            .rounded_md()
                            .text_sm()
                            .text_color(theme.secondary)
                            .cursor_pointer()
                            .hover(|s| s.bg(theme.row_selected))
                            .child("⋯")
                            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                this.more_menu = !this.more_menu;
                                this.scope_menu = false;
                                cx.notify();
                            })),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .gap_3()
                    .text_xs()
                    .child(div().text_color(if waiting > 0 { theme.orange() } else { theme.secondary }).child(format!("● {waiting} need you")))
                    .child(div().text_color(theme.blue()).child(format!("◐ {working} working")))
                    .child(div().text_color(theme.good()).child(format!("✓ {done} done, unread"))),
            )
    }

    fn menus(&self, theme: &Theme, cx: &mut Context<Self>) -> Option<AnyElement> {
        if self.scope_menu {
            return Some(
                div()
                    .absolute()
                    .top(px(36.))
                    .left(px(84.))
                    .w(px(240.))
                    .p_1()
                    .bg(theme.popover)
                    .border_1()
                    .border_color(theme.border)
                    .rounded_md()
                    .shadow_lg()
                    .occlude()
                    .children(SCOPES.iter().enumerate().map(|(i, name)| {
                        let need = self.items.iter().filter(|it| i == 0 || it.scope == i).count();
                        div()
                            .id(SharedString::from(format!("scope-{i}")))
                            .flex()
                            .flex_row()
                            .px_2()
                            .py_1()
                            .rounded_md()
                            .text_sm()
                            .cursor_pointer()
                            .when(i == self.scope, |d| d.bg(theme.row_selected))
                            .hover(|s| s.bg(theme.row_selected))
                            .child(div().flex_1().text_color(theme.fg).child(*name))
                            .child(div().text_xs().text_color(theme.secondary).child(format!("{need} need you")))
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.scope = i;
                                this.scope_menu = false;
                                this.selected = 0;
                                cx.notify();
                            }))
                    }))
                    .into_any_element(),
            );
        }
        if self.more_menu {
            let entries = ["Compact now", "New conversation", "Edit notes", "Mark all read", "Focus on/off"];
            return Some(
                div()
                    .absolute()
                    .top(px(36.))
                    .right(px(8.))
                    .w(px(220.))
                    .p_1()
                    .bg(theme.popover)
                    .border_1()
                    .border_color(theme.border)
                    .rounded_md()
                    .shadow_lg()
                    .occlude()
                    .children(entries.iter().enumerate().map(|(i, label)| {
                        div()
                            .id(SharedString::from(format!("more-{i}")))
                            .px_2()
                            .py_1()
                            .rounded_md()
                            .text_sm()
                            .text_color(theme.fg)
                            .cursor_pointer()
                            .hover(|s| s.bg(theme.row_selected))
                            .child(*label)
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.more_menu = false;
                                match i {
                                    0 => {
                                        this.threads[0].messages.push(text(Who::Event, "Compacted. Notes and threads are kept; the summary replaces older turns."));
                                    }
                                    1 => {
                                        this.threads[0].messages.push(text(Who::Event, "New conversation. assistant-notes.md loaded; the old one stays above."));
                                    }
                                    2 => this.workspace = "assistant-notes.md would open here:\n\n- Prefers Comment on Friday PRs\n- Watching mono#1539 for a re-review\n- SGN numbers: exclude drafts".into(),
                                    3 => {
                                        for t in &mut this.threads {
                                            t.unread = false;
                                        }
                                    }
                                    _ => this.simulate(3, cx),
                                }
                                cx.notify();
                            }))
                    }))
                    .child(div().mt_1().mx_2().h(px(3.)).rounded_full().bg(theme.grid).child(div().h_full().w(px(70.)).rounded_full().bg(theme.blue())))
                    .child(div().px_2().pt_0p5().pb_1().text_xs().text_color(theme.secondary).child("Context 38% full"))
                    .into_any_element(),
            );
        }
        None
    }

    fn queue_view(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let queue = self.queue();
        let selected = self.selected.min(queue.len().saturating_sub(1));
        div()
            .flex_none()
            .flex()
            .flex_col()
            .gap_1()
            .px_3()
            .py_2()
            .border_b_1()
            .border_color(theme.border)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1()
                    .child(section(format!("NEEDS YOU ({})", queue.len()), theme))
                    .child(div().flex_1())
                    .children([Lane::Build, Lane::Review, Lane::Ask].into_iter().map(|lane| {
                        pill(format!("lane-{}", lane.title()), format!("{} {}", lane.title(), self.lane_count(lane)), self.lane == Some(lane), theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.lane = if this.lane == Some(lane) { None } else { Some(lane) };
                            this.selected = 0;
                            cx.notify();
                        }))
                    })),
            )
            .when(queue.is_empty(), |d| d.child(div().py_2().text_sm().text_color(theme.secondary).child("Nothing needs you. ✓")))
            .children(queue.iter().enumerate().map(|(row, &i)| {
                let it = &self.items[i];
                let on = row == selected;
                div()
                    .id(SharedString::from(format!("item-{i}-{}", it.subject)))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .cursor_pointer()
                    .when(on, |d| d.bg(theme.tile).border_1().border_color(theme.border))
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.selected = row;
                        this.later_menu = false;
                        cx.notify();
                    }))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .child(div().text_xs().text_color(if it.need == Need::Blocked { theme.orange() } else { theme.secondary }).child(if on { "▶" } else { "○" }))
                            .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child(it.subject.clone()))
                            .child(div().flex_1().min_w_0().truncate().text_sm().text_color(theme.fg).child(it.task.clone()))
                            .child(div().text_xs().text_color(age_color(it.minutes, theme)).child(ago(it.minutes))),
                    )
                    .when(on, |d| {
                        d.child(
                            div()
                                .pl_5()
                                .flex()
                                .flex_row()
                                .gap_2()
                                .text_xs()
                                .text_color(theme.secondary)
                                .child(div().child(format!("{} · {}", it.need.title(), it.lane.title())))
                                .child(div().flex_1().min_w_0().truncate().child(it.detail.clone())),
                        )
                        .child(
                            div()
                                .pl_5()
                                .flex()
                                .flex_row()
                                .flex_wrap()
                                .gap_1()
                                .children(it.actions.iter().enumerate().map(|(n, &action)| {
                                    button(format!("act-{i}-{n}"), if n == 0 { format!("{action} ↩") } else { action.to_string() }, n == 0, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.act(i, action, cx)))
                                }))
                                .child(button(format!("later-{i}"), "Later ▾", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                    this.later_menu = !this.later_menu;
                                    cx.notify();
                                }))),
                        )
                        .when(self.later_menu, |d| {
                            d.child(
                                div().pl_5().flex().flex_row().flex_wrap().gap_1().children(["30 minutes", "after lunch", "tomorrow morning", "CI passes"].into_iter().enumerate().map(|(n, when)| {
                                    pill(format!("when-{n}"), format!("{} {}", n + 1, if n == 3 { "When CI passes".to_string() } else { when.to_string() }), false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.later(i, when, cx)))
                                })),
                            )
                        })
                    })
            }))
    }

    fn threads_view(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let listed = self.listed();
        let unread = self.unread_count();
        div()
            .id("threads")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .px_3()
            .py_2()
            .gap_0p5()
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1()
                    .pb_1()
                    .child(section("THREADS", theme))
                    .child(div().flex_1())
                    .child(pill("unread-only", format!("Unread {unread}"), self.unread_only, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.unread_only = true;
                        cx.notify();
                    })))
                    .child(pill("all-threads", "All", !self.unread_only, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.unread_only = false;
                        cx.notify();
                    }))),
            )
            .children(listed.into_iter().map(|t| {
                let thread = &self.threads[t];
                let unread = self.is_unread(t);
                let state_color = match thread.state {
                    State::Working => theme.blue(),
                    State::Done => theme.good(),
                    State::Parked => theme.secondary,
                    State::Waiting => theme.orange(),
                };
                div()
                    .id(SharedString::from(format!("thread-{t}")))
                    .flex()
                    .flex_row()
                    .gap_2()
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .cursor_pointer()
                    .hover(|s| s.bg(theme.row_selected))
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.open_thread(t, cx)))
                    .child(div().w(px(8.)).pt_1().text_xs().text_color(theme.selected).child(if unread { "●" } else { "" }))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap_2()
                                    .child(div().flex_1().min_w_0().truncate().text_sm().text_color(theme.fg).when(unread, |d| d.font_weight(FontWeight::SEMIBOLD)).child(format!("{}{}", if thread.pinned { "📌 " } else { "" }, thread.title)))
                                    .child(div().text_xs().text_color(theme.tertiary).child(thread.kind.title()))
                                    .child(div().text_xs().text_color(state_color).child(thread.state.glyph()))
                                    .child(div().w(px(28.)).text_xs().text_color(theme.secondary).child(ago(thread.minutes))),
                            )
                            .child(div().truncate().text_xs().text_color(if thread.muted { theme.tertiary } else { theme.secondary }).child(thread.last.clone())),
                    )
            }))
            .child(
                div()
                    .pt_3()
                    .flex()
                    .flex_col()
                    .gap_0p5()
                    .child(section("DONE TODAY", theme))
                    .children(self.done.iter().take(5).map(|d| div().text_xs().text_color(theme.secondary).child(format!("✓ {d}")))),
            )
    }

    fn message_view(&self, t: usize, m: usize, message: &Message, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let (label, color) = match message.who {
            Who::You => ("You", theme.fg),
            Who::Assistant => ("Assistant", theme.selected),
            Who::Worker => ("Worker", theme.good()),
            Who::Event => ("", theme.secondary),
        };
        let body: AnyElement = match &message.body {
            Body::Text(s) if matches!(message.who, Who::Event) => div().text_xs().text_color(theme.secondary).child(format!("· {s}")).into_any_element(),
            Body::Text(s) => div().text_sm().text_color(theme.fg).children(s.lines().map(|l| div().child(l.to_string()))).into_any_element(),
            Body::Answer { headline, figures, spark, caveat, how, skill } => {
                let open = self.how_open.contains(&(t, m));
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .p_3()
                    .rounded_lg()
                    .bg(theme.tile)
                    .border_1()
                    .border_color(theme.border)
                    .child(div().text_xs().text_color(theme.secondary).child(format!("Answer · {skill} · prod, read only")))
                    .child(div().text_base().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child(headline.clone()))
                    .child(div().flex().flex_row().gap_4().children(figures.iter().map(|(k, v)| div().flex().flex_col().child(div().text_xs().text_color(theme.secondary).child(k.clone())).child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child(v.clone())))))
                    .child(div().h(px(36.)).w(px(160.)).child(charts::spark_bars(spark, theme)))
                    .child(div().text_xs().text_color(theme.orange()).child(format!("Caveat: {caveat}")))
                    .child(
                        div()
                            .id(SharedString::from(format!("how-{t}-{m}")))
                            .text_xs()
                            .text_color(theme.secondary)
                            .cursor_pointer()
                            .child(if open { "▾ How I got it" } else { "▸ How I got it" })
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                if !this.how_open.remove(&(t, m)) {
                                    this.how_open.insert((t, m));
                                }
                                cx.notify();
                            })),
                    )
                    .when(open, |d| d.child(div().p_2().rounded_md().bg(theme.bg).font_family("Menlo").text_xs().text_color(theme.fg).children(how.lines().map(|l| div().child(l.to_string())))))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .flex_wrap()
                            .gap_1()
                            .children(["Copy", "Follow up", "Save to findings", "Save as /command", "Open session"].into_iter().enumerate().map(|(n, label)| {
                                button(format!("ans-{t}-{m}-{n}"), label, n == 0, theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                                    match label {
                                        "Follow up" => window.focus(&this.composer.focus_handle(cx), cx),
                                        "Copy" => this.notify("Copied".into(), "Plain text, ready for Slack or notes".into(), vec![], None, cx),
                                        _ => this.threads[t].messages.push(text(Who::Event, &format!("{label}: done (preview)"))),
                                    }
                                    cx.notify();
                                }))
                            })),
                    )
                    .into_any_element()
            }
            Body::Findings { cause, evidence, confidence, unknown } => div()
                .flex()
                .flex_col()
                .gap_2()
                .p_3()
                .rounded_lg()
                .bg(theme.tile)
                .border_1()
                .border_color(theme.border)
                .child(div().text_xs().text_color(theme.secondary).child(format!("Findings · confidence {confidence}")))
                .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child(cause.clone()))
                .child(section("Evidence", theme))
                .children(evidence.iter().map(|e| div().text_xs().text_color(theme.fg).child(format!("• {e}"))))
                .child(div().text_xs().text_color(theme.orange()).child(format!("Still unknown: {unknown}")))
                .child(div().flex().flex_row().flex_wrap().gap_1().children(["Start fix", "Comment on ticket", "Dig further", "Save to findings"].into_iter().enumerate().map(|(n, label)| {
                    button(format!("find-{t}-{m}-{n}"), label, n == 0, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        let note = match label {
                            "Start fix" => "Started Work on this for the ticket, with these findings in its brief.".to_string(),
                            "Comment on ticket" => "A summary for the ticket is drafted; posting asks you first.".to_string(),
                            other => format!("{other}: done (preview)"),
                        };
                        this.threads[t].messages.push(text(Who::Event, &note));
                        this.items.retain(|it| it.thread != Some(t));
                        cx.notify();
                    }))
                })))
                .into_any_element(),
            Body::Since { what, since, wants } => div()
                .flex()
                .flex_col()
                .gap_0p5()
                .p_2()
                .rounded_lg()
                .border_1()
                .border_color(theme.border)
                .bg(theme.sidebar)
                .child(div().text_xs().text_color(theme.secondary).child("Where you left off"))
                .child(div().text_sm().text_color(theme.fg).child(format!("What it is: {what}")))
                .child(div().text_sm().text_color(theme.fg).child(format!("Since you looked: {since}")))
                .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.orange()).child(format!("Wants from you: {wants}")))
                .into_any_element(),
            Body::CatchUp(lines) => div()
                .flex()
                .flex_col()
                .gap_1()
                .p_2()
                .rounded_lg()
                .bg(theme.tile)
                .child(div().text_xs().text_color(theme.secondary).child(format!("{} unread threads", lines.len())))
                .children(lines.iter().map(|(t, line)| {
                    let t = *t;
                    div()
                        .id(SharedString::from(format!("catch-{t}")))
                        .text_sm()
                        .text_color(theme.fg)
                        .cursor_pointer()
                        .hover(|s| s.text_color(theme.selected))
                        .child(format!("• {line}"))
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.open_thread(t, cx)))
                }))
                .child(div().flex().child(button(format!("catch-read-{m}"), "Mark these read", true, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    if let Body::CatchUp(lines) = &this.threads[t].messages[m].body {
                        for (i, _) in lines.clone() {
                            this.threads[i].unread = false;
                        }
                    }
                    cx.notify();
                }))))
                .into_any_element(),
        };
        div()
            .flex()
            .flex_col()
            .gap_0p5()
            .when(!label.is_empty(), |d| d.child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(color).child(label)))
            .child(body)
            .into_any_element()
    }

    fn thread_view(&self, t: usize, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let thread = &self.threads[t];
        div()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .px_3()
                    .py_2()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(button("back", "‹ Threads", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.open = None;
                        cx.notify();
                    })))
                    .child(div().flex_1().min_w_0().truncate().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child(thread.title.clone()))
                    .child(pill(format!("mute-{t}"), if thread.muted { "Muted" } else { "Mute" }, thread.muted, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.threads[t].muted = !this.threads[t].muted;
                        cx.notify();
                    })))
                    .child(pill(format!("pin-{t}"), if thread.pinned { "Pinned" } else { "Pin" }, thread.pinned, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.threads[t].pinned = !this.threads[t].pinned;
                        cx.notify();
                    })))
                    .child(pill(format!("unread-{t}"), "Mark unread", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.threads[t].unread = true;
                        this.open = None;
                        cx.notify();
                    }))),
            )
            .child(
                div()
                    .id(SharedString::from(format!("thread-body-{t}")))
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .px_3()
                    .py_3()
                    .children(thread.messages.iter().enumerate().map(|(m, message)| self.message_view(t, m, message, theme, cx)))
                    .when_some(thread.doing.clone(), |d, doing| d.child(div().text_xs().text_color(theme.blue()).child(format!("◐ {doing}")))),
            )
    }

    fn composer_view(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let target = match self.open {
            Some(t) if t != 0 => format!("To {}'s worker", self.threads[t].title),
            _ => "To the assistant".into(),
        };
        div()
            .flex_none()
            .flex()
            .flex_col()
            .gap_1()
            .px_3()
            .py_2()
            .border_t_1()
            .border_color(theme.border)
            .child(
                div().flex().flex_row().flex_wrap().gap_1().children(["Waiting", "Catch me up", "Standup", "Review next"].into_iter().enumerate().map(|(n, chip)| {
                    pill(format!("chip-{n}"), chip, false, theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                        let typed = match chip {
                            "Waiting" => "/waiting",
                            "Catch me up" => "catch me up",
                            "Standup" => "what did I do yesterday, for standup?",
                            _ => "/waiting",
                        };
                        this.open = Some(0);
                        this.composer.update(cx, |e, cx| e.set_text(typed, window, cx));
                        this.send(window, cx);
                    }))
                })),
            )
            .child(div().text_xs().text_color(theme.tertiary).child(target))
            .child(
                div()
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .border_1()
                    .border_color(theme.border)
                    .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                        if event.keystroke.key == "enter" {
                            cx.stop_propagation();
                            this.send(window, cx);
                        }
                    }))
                    .child(self.composer.clone()),
            )
    }

    fn toasts_view(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .absolute()
            .top(px(48.))
            .right(px(12.))
            .w(px(340.))
            .flex()
            .flex_col()
            .gap_2()
            .children(self.toasts.iter().map(|toast| {
                let id = toast.id;
                let thread = toast.thread;
                div()
                    .id(SharedString::from(format!("toast-{id}")))
                    .occlude()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .p_3()
                    .rounded_xl()
                    .bg(theme.popover)
                    .border_1()
                    .border_color(theme.border)
                    .shadow_lg()
                    .child(div().flex().flex_row().child(div().flex_1().text_xs().text_color(theme.secondary).child("Gannin")).child(div().text_xs().text_color(theme.tertiary).child("now")))
                    .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child(toast.title.clone()))
                    .child(div().text_sm().text_color(theme.fg).child(toast.body.clone()))
                    .when(!toast.actions.is_empty(), |d| {
                        d.child(div().flex().flex_row().gap_1().pt_1().children(toast.actions.iter().enumerate().map(|(n, &action)| {
                            button(format!("toast-{id}-{n}"), action, n == 0, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.toasts.retain(|t| t.id != id);
                                match (action, thread) {
                                    ("Open", Some(t)) => this.open_thread(t, cx),
                                    (_, Some(t)) => {
                                        if let Some(i) = this.items.iter().position(|it| it.thread == Some(t)) {
                                            this.act(i, action, cx);
                                        }
                                    }
                                    _ => {}
                                }
                                cx.notify();
                            }))
                        })))
                    })
            }))
    }
}

impl Focusable for AssistantPreview {
    fn focus_handle(&self, _: &gpui::App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for AssistantPreview {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let scenarios = ["Session blocked", "Comment on a done thread", "Review finished", if self.focus_mode { "Focus off" } else { "Focus on" }];
        let controls = div()
            .flex_none()
            .flex()
            .flex_row()
            .flex_wrap()
            .items_center()
            .gap_1()
            .pl(px(84.))
            .pr_3()
            .py_2()
            .border_b_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .child(div().pr_2().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child("Assistant Preview"))
            .child(div().pr_1().text_xs().text_color(theme.secondary).child("Simulate:"))
            .children(scenarios.into_iter().enumerate().map(|(n, label)| pill(format!("sim-{n}"), label, n == 3 && self.focus_mode, &theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.simulate(n, cx)))))
            .child(div().flex_1())
            .child(div().text_xs().text_color(theme.tertiary).child("J/K move · ↩ do · O open · L later · B/R/A lane · N next unread · U unread · / type · Esc back"));
        let workspace = div()
            .flex_1()
            .min_w_0()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .child(
                div().flex_none().flex().flex_row().gap_1().px_3().py_2().border_b_1().border_color(theme.border).children(["Issues", "mono#1539", "clients#2466", "mono#1528", "api#12"].into_iter().map(|tab| {
                    div().px_2().py_0p5().rounded_md().text_xs().text_color(theme.secondary).bg(theme.tile).child(tab)
                })),
            )
            .child(div().flex_1().flex().items_center().justify_center().p_8().text_sm().text_color(theme.tertiary).children(self.workspace.lines().map(|l| div().child(l.to_string()))));
        let menus = self.menus(&theme, cx);
        let panel = div()
            .relative()
            .w(px(460.))
            .flex_none()
            .flex()
            .flex_col()
            .border_l_1()
            .border_color(theme.border)
            .bg(theme.bg)
            .child(self.header(&theme, cx))
            .map(|d| match self.open {
                Some(t) => d.child(self.thread_view(t, &theme, cx)),
                None => d.child(self.queue_view(&theme, cx)).child(self.threads_view(&theme, cx)),
            })
            .child(self.composer_view(&theme, cx))
            .when_some(menus, |d, menus| d.child(menus));
        div()
            .id("assistant-preview")
            .track_focus(&self.focus)
            .on_key_down(cx.listener(Self::key))
            .relative()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .child(controls)
            .child(div().flex_1().min_h_0().flex().flex_row().child(workspace).child(panel))
            .child(self.toasts_view(&theme, cx))
    }
}
