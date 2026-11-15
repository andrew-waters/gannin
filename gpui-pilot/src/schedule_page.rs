//! Schedule: the scheduler's one page (docs/scheduler.md), on this Mac's
//! `schedule.json`. A week (days across, hours down) or a month, with review
//! windows shaded, issue starts at their time, a sequence's items laid out
//! from its start (two hours each until they've run), recurring prompts on
//! their days, and how each went. An empty half hour adds one of the four
//! kinds there; a block opens its settings on the right. The clock that
//! runs them is the workspace's (`schedule_tick`); Run Now asks it.

use crate::charts::Theme;
use crate::approve::ApproveRules;
use crate::schedule::{self, IssueRef, Prompt, ReviewWindow, RunState, Schedule, Sequence};
use chrono::{Datelike, Duration, Local, NaiveDate, Timelike};
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, EventEmitter, FontWeight, Hsla, SharedString, Subscription, Task, Window};

/// The whole day, opening scrolled to the morning.
const FIRST_HOUR: u32 = 0;
const LAST_HOUR: u32 = 24;
const OPENS_AT: u32 = 7;
const HOUR: f32 = 52.;
const DAYS: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/// Asks the workspace to run one now, by its id.
pub struct RunNow(pub String);

impl EventEmitter<RunNow> for SchedulePage {}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Window,
    Start,
    Sequence,
    Prompt,
}

impl Kind {
    fn title(self) -> &'static str {
        match self {
            Kind::Window => "Review window",
            Kind::Start => "Issue start",
            Kind::Sequence => "Sequence",
            Kind::Prompt => "Recurring prompt",
        }
    }

    fn tint(self, theme: &Theme) -> Hsla {
        match self {
            Kind::Window => theme.blue(),
            Kind::Start => theme.good(),
            Kind::Sequence => gpui::rgb(0xA259FF).into(),
            Kind::Prompt => theme.orange(),
        }
    }
}

/// One block on a day.
#[derive(Clone)]
struct Block {
    kind: Kind,
    id: String,
    title: String,
    start: u32,
    length: u32,
    /// done, failed, missed, running, or "" (to come)
    status: &'static str,
    paused: bool,
    place: Option<(usize, usize)>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum View {
    Week,
    Month,
}

/// Adding an issue start or a sequence: open issues to pick from.
struct Picking {
    kind: Kind,
    date: NaiveDate,
    minute: u32,
    /// Open issues, each with how many sub-issues it has.
    issues: Option<Vec<(IssueRef, usize)>>,
    picked: Vec<IssueRef>,
    /// An epic's sub-issues being read, by its id.
    reading: Option<String>,
}

pub struct SchedulePage {
    org: Option<String>,
    schedule: Schedule,
    view: View,
    week: NaiveDate,
    selected: Option<String>,
    adding: Option<(NaiveDate, u32)>,
    /// The panel of decisions waiting on you shows, and its submitted ones.
    deciding: bool,
    show_submitted: bool,
    picking: Option<Picking>,
    name_field: Entity<editor::Editor>,
    time_field: Entity<editor::Editor>,
    text_field: Entity<editor::Editor>,
    search_field: Entity<editor::Editor>,
    /// The window's author picker is open, filtered by `author_field`;
    /// the org's members it lists, read when it opens.
    picking_authors: bool,
    author_field: Entity<editor::Editor>,
    members: Vec<String>,
    _fields: Vec<Subscription>,
    _reload: Task<()>,
    /// The week's scroll, set to the morning the first time it shows.
    week_scroll: gpui::ScrollHandle,
    scrolled: bool,
}

fn monday(date: NaiveDate) -> NaiveDate {
    date - Duration::days(date.weekday().num_days_from_monday() as i64)
}

fn clock(minutes: u32) -> String {
    format!("{}:{:02}", minutes / 60, minutes % 60)
}

fn parse_clock(text: &str) -> Option<u32> {
    let (h, m) = text.trim().split_once(':')?;
    let (h, m): (u32, u32) = (h.trim().parse().ok()?, m.trim().parse().ok()?);
    (h < 24 && m < 60).then_some(h * 60 + m)
}

fn local(at: chrono::DateTime<chrono::Utc>) -> (NaiveDate, u32) {
    let l = at.with_timezone(&Local);
    (l.date_naive(), l.hour() * 60 + l.minute())
}

fn status_of(run: &RunState) -> &'static str {
    match run {
        RunState::Waiting => "",
        RunState::Started { .. } => "running",
        RunState::Done { .. } => "done",
        RunState::Failed { .. } => "failed",
        RunState::Missed { .. } => "missed",
    }
}

impl SchedulePage {
    pub fn new(org: Option<String>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let field = |placeholder: &str, window: &mut Window, cx: &mut Context<Self>| {
            let placeholder = placeholder.to_string();
            cx.new(|cx| {
                let mut e = editor::Editor::single_line(window, cx);
                e.set_placeholder_text(&placeholder, window, cx);
                e
            })
        };
        let name_field = field("Name", window, cx);
        let time_field = field("9:00", window, cx);
        let search_field = field("Search issues", window, cx);
        let author_field = field("Filter people", window, cx);
        let text_field = cx.new(|cx| {
            let mut e = editor::Editor::auto_height(3, 10, window, cx);
            e.set_placeholder_text("What claude should do, as you'd ask it", window, cx);
            e
        });
        let subs = vec![
            cx.observe(&name_field, |this, f, cx| {
                let text = f.read(cx).text(cx).trim().to_string();
                if !text.is_empty() {
                    this.change(cx, |s, id| {
                        if let Some(w) = s.windows.iter_mut().find(|w| w.id == id) {
                            w.name = text.clone();
                        }
                        if let Some(p) = s.prompts.iter_mut().find(|p| p.id == id) {
                            p.name = text.clone();
                        }
                        if let Some(q) = s.sequences.iter_mut().find(|q| q.id == id) {
                            q.name = text.clone();
                        }
                    });
                }
            }),
            cx.observe(&time_field, |this, f, cx| {
                let Some(minute) = parse_clock(&f.read(cx).text(cx)) else { return };
                this.change(cx, |s, id| {
                    if let Some(w) = s.windows.iter_mut().find(|w| w.id == id) {
                        w.start = minute;
                    }
                    if let Some(p) = s.prompts.iter_mut().find(|p| p.id == id) {
                        p.start = minute;
                    }
                    if let Some(st) = s.starts.iter_mut().find(|x| x.id == id) {
                        st.at = schedule::at(local(st.at).0, minute);
                    }
                    if let Some(q) = s.sequences.iter_mut().find(|q| q.id == id) {
                        q.start = schedule::at(local(q.start).0, minute);
                    }
                });
            }),
            cx.observe(&text_field, |this, f, cx| {
                let text = f.read(cx).text(cx);
                this.change(cx, |s, id| {
                    if let Some(p) = s.prompts.iter_mut().find(|p| p.id == id) {
                        p.text = text.clone();
                    }
                });
            }),
            cx.observe(&search_field, |_, _, cx| cx.notify()),
            cx.observe(&author_field, |_, _, cx| cx.notify()),
        ];
        // The clock changes the file as it runs things: read it again now and then.
        let reload = cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(std::time::Duration::from_secs(10)).await;
            let fresh = cx.background_executor().spawn(async { Schedule::load() }).await;
            if this
                .update(cx, |this, cx| {
                    if this.schedule != fresh {
                        this.schedule = fresh;
                        cx.notify();
                    }
                })
                .is_err()
            {
                return;
            }
        });
        Self {
            org,
            schedule: Schedule::load(),
            view: View::Week,
            week: monday(Local::now().date_naive()),
            selected: None,
            adding: None,
            deciding: false,
            show_submitted: false,
            picking: None,
            name_field,
            time_field,
            text_field,
            search_field,
            picking_authors: false,
            author_field,
            members: Vec::new(),
            _fields: subs,
            _reload: reload,
            week_scroll: gpui::ScrollHandle::new(),
            scrolled: false,
        }
    }

    pub fn set_org(&mut self, org: Option<String>, cx: &mut Context<Self>) {
        self.org = org;
        cx.notify();
    }

    /// Changes the schedule (the selected item, by id) and saves it.
    fn change(&mut self, cx: &mut Context<Self>, f: impl FnOnce(&mut Schedule, &str)) {
        let Some(id) = self.selected.clone() else { return };
        let mut fresh = Schedule::load();
        f(&mut fresh, &id);
        if fresh != self.schedule {
            fresh.save();
            self.schedule = fresh;
            cx.notify();
        }
    }

    /// Changes the selected window's approving rules.
    fn change_rules(&mut self, cx: &mut Context<Self>, f: impl FnOnce(&mut ApproveRules)) {
        self.change(cx, |s, id| {
            if let Some(w) = s.windows.iter_mut().find(|w| w.id == id) {
                f(&mut w.approve);
            }
        })
    }

    /// The org's members' logins, from the people cache, sorted.
    fn read_members(&mut self) {
        let Some(org) = self.org.as_deref() else { return };
        let snapshot: serde_json::Value = std::fs::read(crate::cache::path(crate::cache::Kind::Snapshots, org)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let mut logins: Vec<String> = snapshot["members"].as_array().into_iter().flatten().filter_map(|m| m["login"].as_str().map(str::to_string)).collect();
        logins.sort_by_key(|l| l.to_lowercase());
        self.members = logins;
    }

    fn change_all(&mut self, cx: &mut Context<Self>, f: impl FnOnce(&mut Schedule)) {
        let mut fresh = Schedule::load();
        f(&mut fresh);
        fresh.save();
        self.schedule = fresh;
        cx.notify();
    }

    /// The blocks on a date, from the schedule's own view of the day.
    fn blocks(&self, date: NaiveDate) -> Vec<Block> {
        self.schedule
            .busy(date)
            .into_iter()
            .map(|b| Block {
                kind: match b.kind {
                    "window" => Kind::Window,
                    "start" => Kind::Start,
                    "sequence" => Kind::Sequence,
                    _ => Kind::Prompt,
                },
                id: b.id,
                title: b.title,
                start: b.start,
                length: b.length,
                // One still to run shows where its scouting stands.
                status: match (b.status, b.issue.as_ref().and_then(|i| self.schedule.readiness.get(i))) {
                    ("", Some(r)) => match r.state.as_str() {
                        "scouting" => "scouting",
                        "needs" => "needs",
                        "blocked" => "blocked",
                        "failed" => "scoutfail",
                        _ => "",
                    },
                    ("", None) if b.issue.is_some() => "scouting",
                    (status, _) => status,
                },
                paused: b.paused,
                place: b.place,
            })
            .collect()
    }

    /// Scheduled issues waiting on you: decisions to make, blockers to
    /// clear, or a scout that failed.
    /// Scouted and not submitted yet.
    fn waiting_on_you(&self) -> Vec<(String, String)> {
        self.scouted(&["needs", "blocked", "failed", "ready"]).into_iter().filter(|(id, _)| !self.schedule.readiness.get(id).is_some_and(|r| r.submitted)).collect()
    }

    /// Scheduled issues whose scouting is in one of `states`, in schedule
    /// order.
    fn scouted(&self, states: &[&str]) -> Vec<(String, String)> {
        let mut out: Vec<(String, String)> = Vec::new();
        let titles = self.schedule.starts.iter().map(|x| x.issue.clone()).chain(self.schedule.sequences.iter().flat_map(|q| q.items.clone()));
        for issue in titles {
            if let Some(r) = self.schedule.readiness.get(&issue.id) {
                if states.contains(&r.state.as_str()) && !out.iter().any(|(id, _)| *id == issue.id) {
                    out.push((issue.id.clone(), issue.label()));
                }
            }
        }
        out
    }

    /// The panel of what's waiting on you: each issue's decisions as
    /// options to pick, its blockers to clear, or Scout Again.
    fn decisions_panel(&self, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        // Those waiting; then, folded, the submitted ones to see and change.
        let mut waiting = self.waiting_on_you();
        let submitted: Vec<(String, String)> = self.scouted(&["ready", "needs", "blocked"]).into_iter().filter(|(id, _)| self.schedule.readiness.get(id).is_some_and(|r| r.submitted)).collect();
        let first_ready = waiting.len();
        let submitted_count = submitted.len();
        if self.show_submitted {
            waiting.extend(submitted);
        }
        let mut body = div().flex().flex_col().gap_4().child(div().font_weight(FontWeight::SEMIBOLD).child("Waiting on you")).child(div().text_xs().text_color(theme.secondary).child(
            "Scouted when they were scheduled. Pick answers (each saves as you pick it), then Submit: anything unanswered takes the recommendation, blockers left are told to the session as known, and it's ready and off the list. One not ready at its time is skipped, and starts once it's ready.",
        ));
        if first_ready == 0 {
            body = body.child(div().text_sm().text_color(theme.secondary).child("Nothing: every scheduled issue is ready or still being scouted."));
        }
        for (n, (issue_id, title)) in waiting.into_iter().enumerate() {
            if n == first_ready {
                body = body.child(div().pt_2().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.good()).child("SUBMITTED"));
            }
            let Some(r) = self.schedule.readiness.get(&issue_id).cloned() else { continue };
            // How far along it is, saved as each option is picked.
            let decided = r.decisions.iter().filter(|d| d.answer.is_some()).count();
            let mut parts = Vec::new();
            if !r.decisions.is_empty() {
                parts.push(format!("{decided} of {} decided", r.decisions.len()));
            }
            if !r.blockers.is_empty() {
                parts.push(format!("{} blocker{} left", r.blockers.len(), if r.blockers.len() == 1 { "" } else { "s" }));
            }
            let (status, tint) = match r.state.as_str() {
                "ready" => ("Ready: it runs with these decisions".to_string(), theme.good()),
                "failed" => ("The scout couldn't finish".to_string(), theme.critical()),
                _ => (parts.join(" · "), if r.blockers.is_empty() { theme.orange() } else { theme.critical() }),
            };
            let mut card = div()
                .flex()
                .flex_col()
                .gap_2()
                .p(px(10.))
                .rounded_lg()
                .bg(theme.bg)
                .border_1()
                .border_color(if r.state == "ready" { theme.good().opacity(0.5) } else { theme.border })
                .child(div().font_weight(FontWeight::MEDIUM).text_sm().child(title))
                .child(div().text_xs().text_color(tint).child(status));
            if let Some(error) = &r.error {
                card = card.child(div().text_xs().text_color(theme.critical()).child(format!("The scout couldn't finish: {error}")));
            }
            for (di, d) in r.decisions.iter().enumerate() {
                let answered = d.answer.clone();
                card = card.child(div().text_sm().child(d.question.clone())).child(div().flex().flex_row().flex_wrap().gap_1().children(d.options.iter().enumerate().map(|(oi, (label, desc))| {
                    let on = answered.as_deref() == Some(label.as_str());
                    let (iid, label2) = (issue_id.clone(), label.clone());
                    let mark = if d.recommended == Some(oi) { " (recommended)" } else { "" };
                    div()
                        .id(SharedString::from(format!("dec-{issue_id}-{di}-{oi}")))
                        .px_2()
                        .py_0p5()
                        .rounded_md()
                        .text_xs()
                        .cursor_pointer()
                        .border_1()
                        .border_color(if on { theme.selected } else { theme.border })
                        .when(on, |d| d.bg(theme.selected.opacity(0.15)).text_color(theme.selected))
                        .hover(|s| s.bg(theme.row_selected))
                        .tooltip({
                            let desc = desc.clone();
                            move |_, cx| cx.new(|_| crate::issues::Tooltip(desc.clone())).into()
                        })
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            let (iid, label2) = (iid.clone(), label2.clone());
                            this.change_all(cx, move |s| {
                                if let Some(r) = s.readiness.get_mut(&iid) {
                                    if let Some(d) = r.decisions.get_mut(di) {
                                        d.answer = Some(label2);
                                    }
                                    r.settle();
                                }
                            })
                        }))
                        .child(format!("{label}{mark}"))
                })));
            }
            for (bi, b) in r.blockers.iter().enumerate() {
                let iid = issue_id.clone();
                card = card.child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(div().flex_1().text_sm().text_color(theme.critical()).child(format!("Blocked: {b}")))
                        .child(Self::button(format!("clear-{issue_id}-{bi}"), "Cleared", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            let iid = iid.clone();
                            this.change_all(cx, move |s| {
                                if let Some(r) = s.readiness.get_mut(&iid) {
                                    if bi < r.blockers.len() {
                                        r.blockers.remove(bi);
                                    }
                                    r.settle();
                                }
                            })
                        }))),
                );
            }
            let iid = issue_id.clone();
            let submit_id = issue_id.clone();
            let open_left = r.decisions.iter().filter(|d| d.answer.is_none()).count() + r.blockers.len();
            card = card.child(
                div()
                    .flex()
                    .flex_row()
                    .gap_2()
                    .when(!r.submitted, |d| {
                        d.child(
                            Self::button(format!("submit-{issue_id}"), if open_left > 0 { "Submit, taking the recommendations" } else { "Submit" }, true, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                let id = submit_id.clone();
                                this.change_all(cx, move |s| {
                                    if let Some(r) = s.readiness.get_mut(&id) {
                                        r.submit();
                                    }
                                })
                            })),
                        )
                    })
                    .child(Self::button(format!("rescout-{issue_id}"), "Scout Again", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        let iid = iid.clone();
                        this.change_all(cx, move |s| {
                            s.readiness.remove(&iid);
                        })
                    }))),
            );
            body = body.child(card);
        }
        if submitted_count > 0 {
            body = body.child(Self::button("show-submitted", if self.show_submitted { format!("Hide Submitted ({submitted_count})") } else { format!("Show Submitted ({submitted_count})") }, false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.show_submitted = !this.show_submitted;
                cx.notify();
            })));
        }
        body.into_any_element()
    }

    fn select(&mut self, id: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        self.selected = id.clone();
        self.picking_authors = false;
        self.adding = None;
        self.deciding = false;
        let s = &self.schedule;
        let (name, time, text) = match id.as_deref() {
            Some(id) => {
                if let Some(w) = s.windows.iter().find(|w| w.id == id) {
                    (w.name.clone(), clock(w.start), String::new())
                } else if let Some(p) = s.prompts.iter().find(|p| p.id == id) {
                    (p.name.clone(), clock(p.start), p.text.clone())
                } else if let Some(st) = s.starts.iter().find(|x| x.id == id) {
                    (st.issue.label(), clock(local(st.at).1), String::new())
                } else if let Some(q) = s.sequences.iter().find(|q| q.id == id) {
                    (q.name.clone(), clock(local(q.start).1), String::new())
                } else {
                    Default::default()
                }
            }
            None => Default::default(),
        };
        self.name_field.update(cx, |e, cx| e.set_text(name, window, cx));
        self.time_field.update(cx, |e, cx| e.set_text(time, window, cx));
        self.text_field.update(cx, |e, cx| e.set_text(text, window, cx));
        cx.notify();
    }

    fn add(&mut self, kind: Kind, date: NaiveDate, minute: u32, window: &mut Window, cx: &mut Context<Self>) {
        let id = schedule::new_id();
        let weekday = date.weekday().num_days_from_monday();
        match kind {
            Kind::Window => {
                let days = if weekday < 5 { vec![0, 1, 2, 3, 4] } else { vec![weekday] };
                let new = ReviewWindow { id: id.clone(), name: "Reviews".into(), weekdays: days, start: minute, length: 60, paused: false, approve: Default::default() };
                self.change_all(cx, |s| s.windows.push(new));
                self.select(Some(id), window, cx);
            }
            Kind::Prompt => {
                let new = Prompt { id: id.clone(), name: "New prompt".into(), text: String::new(), weekdays: vec![weekday], start: minute, paused: false, last: None };
                self.change_all(cx, |s| s.prompts.push(new));
                self.select(Some(id), window, cx);
            }
            Kind::Start | Kind::Sequence => {
                self.adding = None;
                self.picking = Some(Picking { kind, date, minute, issues: None, picked: Vec::new(), reading: None });
                self.search_field.update(cx, |e, cx| e.set_text("", window, cx));
                let org = self.org.clone();
                cx.spawn(async move |this, cx| {
                    let issues = cx
                        .background_executor()
                        .spawn(async move {
                            let all = org.and_then(|o| crate::issues::load(&o).ok()).unwrap_or_default();
                            // How many open sub-issues each has: the loaded list
                            // knows only each one's parent.
                            let mut subs: std::collections::HashMap<String, usize> = Default::default();
                            for i in all.iter().filter(|i| i.closed_at.is_none()) {
                                if let Some(parent) = &i.parent_id {
                                    *subs.entry(parent.clone()).or_default() += 1;
                                }
                            }
                            let mut items: Vec<(IssueRef, usize)> = all
                                .into_iter()
                                .filter(|i| i.closed_at.is_none())
                                .map(|i| {
                                    let n = subs.get(&i.id).copied().unwrap_or(0);
                                    (IssueRef { id: i.id, repo: i.repo, number: i.number, title: i.title, url: i.url }, n)
                                })
                                .collect();
                            items.sort_by(|a, b| b.0.number.cmp(&a.0.number));
                            items
                        })
                        .await;
                    this.update(cx, |this, cx| {
                        if let Some(p) = this.picking.as_mut() {
                            p.issues = Some(issues);
                        }
                        cx.notify();
                    })
                    .ok();
                })
                .detach();
            }
        }
    }

    /// The issues picked become a start or a sequence at the slot.
    fn finish_picking(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(picking) = self.picking.take() else { return };
        if picking.picked.is_empty() {
            return cx.notify();
        }
        let id = schedule::new_id();
        let at = schedule::at(picking.date, picking.minute);
        match picking.kind {
            Kind::Start => {
                let starts: Vec<schedule::IssueStart> =
                    picking.picked.iter().map(|issue| schedule::IssueStart { id: schedule::new_id(), issue: issue.clone(), at, paused: false, run: RunState::Waiting }).collect();
                let first = starts[0].id.clone();
                self.change_all(cx, |s| s.starts.extend(starts));
                self.select(Some(first), window, cx);
            }
            _ => {
                let name = if picking.picked.len() == 1 { picking.picked[0].label() } else { format!("{} issues", picking.picked.len()) };
                let seq = Sequence { id: id.clone(), name, start: at, items: picking.picked.clone(), runs: vec![RunState::Waiting; picking.picked.len()], paused: false, interval: 120 };
                self.change_all(cx, |s| s.sequences.push(seq));
                self.select(Some(id), window, cx);
            }
        }
    }

    /// Adds an epic's open sub-issues to the sequence being picked, in the
    /// order set on GitHub, after any already picked.
    fn add_sub_issues(&mut self, epic: IssueRef, cx: &mut Context<Self>) {
        let Some(p) = self.picking.as_mut() else { return };
        p.reading = Some(epic.id.clone());
        cx.notify();
        cx.spawn(async move |this, cx| {
            let id = epic.id.clone();
            let found = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or("Sign in first.".to_string())?;
                    schedule::sub_issues_in_order(&token, &id)
                })
                .await;
            this.update(cx, |this, cx| {
                let Some(p) = this.picking.as_mut() else { return };
                p.reading = None;
                match found {
                    Ok(subs) => {
                        for sub in subs {
                            if !p.picked.iter().any(|x| x.id == sub.id) {
                                p.picked.push(sub);
                            }
                        }
                    }
                    Err(e) => eprintln!("Couldn't read the sub-issues: {e}"),
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// The window's Approves by itself toggle and, when it's on, its
    /// conditions.
    fn approve_section(&self, w: &ReviewWindow, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        let label = |text: &str| div().text_xs().text_color(theme.secondary).child(text.to_string());
        let rules = w.approve.clone();
        let mut section = div().flex().flex_col().gap_2().child(
            div().flex().flex_row().child(Self::button("approve-on", "Approves by itself", rules.enabled, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.change_rules(cx, |r| r.enabled = !r.enabled)
            }))),
        );
        if !rules.enabled {
            return section.into_any_element();
        }
        // Authors: anyone, or the members picked.
        let authors = if rules.authors.is_empty() { "Anyone".to_string() } else { rules.authors.join(", ") };
        section = section
            .child(label("Authors"))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_wrap()
                    .gap_1()
                    .child(Self::button("authors", format!("{authors} ▾"), self.picking_authors, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.picking_authors = !this.picking_authors;
                        if this.picking_authors {
                            this.read_members();
                        }
                        cx.notify();
                    })))
                    .child(Self::button("bots", "Bots allowed", rules.allow_bots, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.change_rules(cx, |r| r.allow_bots = !r.allow_bots)
                    }))),
            );
        if self.picking_authors {
            let filter = self.author_field.read(cx).text(cx).trim().to_lowercase();
            // Picked logins first (some may have left the org), then the rest.
            let mut listed: Vec<String> = rules.authors.clone();
            listed.extend(self.members.iter().filter(|m| !rules.authors.iter().any(|a| a.eq_ignore_ascii_case(m))).cloned());
            let shown: Vec<String> = listed.into_iter().filter(|l| filter.is_empty() || l.to_lowercase().contains(&filter)).take(200).collect();
            let picked = rules.authors.clone();
            section = section.child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .p_2()
                    .rounded_md()
                    .border_1()
                    .border_color(theme.border)
                    .bg(theme.bg)
                    .child(div().px_2().py_1().rounded_md().border_1().border_color(theme.border).text_sm().child(self.author_field.clone()))
                    .child(
                        div()
                            .id("author-list")
                            .max_h(px(220.))
                            .overflow_y_scroll()
                            .flex()
                            .flex_col()
                            .when(shown.is_empty(), |d| d.child(label(if self.members.is_empty() { "No people cached for this org yet." } else { "Nobody matches." })))
                            .children(shown.into_iter().map(|login| {
                                let on = picked.iter().any(|a| a.eq_ignore_ascii_case(&login));
                                div()
                                    .id(SharedString::from(format!("author-{login}")))
                                    .flex()
                                    .flex_row()
                                    .gap_2()
                                    .px_1()
                                    .py_0p5()
                                    .rounded_md()
                                    .text_sm()
                                    .cursor_pointer()
                                    .hover(|s| s.bg(theme.row_selected))
                                    .child(div().w(px(12.)).text_color(theme.selected).child(if on { "✓" } else { "" }))
                                    .child(login.clone())
                                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                        let login = login.clone();
                                        this.change_rules(cx, move |r| {
                                            if let Some(at) = r.authors.iter().position(|a| a.eq_ignore_ascii_case(&login)) {
                                                r.authors.remove(at);
                                            } else {
                                                r.authors.push(login);
                                            }
                                        })
                                    }))
                            })),
                    )
                    .when(!picked.is_empty(), |d| {
                        d.child(div().flex().flex_row().child(Self::button("authors-any", "Anyone", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                            this.change_rules(cx, |r| r.authors.clear())
                        }))))
                    }),
            );
        }
        // Size: no limit, or a step on the scale.
        const LINES: [u32; 7] = [25, 50, 100, 200, 400, 800, 1600];
        const FILES: [u32; 7] = [1, 2, 3, 5, 10, 20, 50];
        let stepper = |id: &'static str, value: Option<u32>, unit: &'static str, steps: &'static [u32], set: fn(&mut ApproveRules, Option<u32>), cx: &mut Context<Self>| {
            let at = value.and_then(|v| steps.iter().position(|s| *s >= v));
            let less = match at {
                None => None,
                Some(0) => Some(None),
                Some(i) => Some(Some(steps[i - 1])),
            };
            let more = match at {
                None => Some(Some(steps[0])),
                Some(i) if i + 1 < steps.len() => Some(Some(steps[i + 1])),
                Some(_) => Some(None),
            };
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .child(Self::button(format!("{id}-less"), "−", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    if let Some(v) = less {
                        this.change_rules(cx, |r| set(r, v))
                    }
                })))
                .child(div().text_sm().child(match value {
                    Some(v) => format!("At most {v} {unit}"),
                    None => "No limit".to_string(),
                }))
                .child(Self::button(format!("{id}-more"), "+", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    if let Some(v) = more {
                        this.change_rules(cx, |r| set(r, v))
                    }
                })))
        };
        section = section
            .child(label("Lines changed"))
            .child(stepper("lines", rules.max_lines, "lines", &LINES, |r, v| r.max_lines = v, cx))
            .child(label("Files changed"))
            .child(stepper("files", rules.max_files, "files", &FILES, |r, v| r.max_files = v, cx));
        let choices = |id: &'static str, options: Vec<(&'static str, Option<String>)>, current: Option<String>, set: fn(&mut ApproveRules, Option<String>), cx: &mut Context<Self>| {
            div().flex().flex_row().flex_wrap().gap_1().children(options.into_iter().map(|(text, value)| {
                let on = value == current;
                Self::button(format!("{id}-{text}"), text, on, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    let value = value.clone();
                    this.change_rules(cx, |r| set(r, value))
                }))
            }))
        };
        let effort_options = std::iter::once(("Any", None)).chain([("1", "1"), ("2", "2"), ("3", "3"), ("4", "4")].map(|(t, v)| (t, Some(v.to_string())))).collect();
        section
            .child(label("Effort, at most"))
            .child(choices("effort", effort_options, rules.max_effort.map(|e| e.to_string()), |r, v| r.max_effort = v.and_then(|v| v.parse().ok()), cx))
            .child(label("Findings"))
            .child(choices(
                "severity",
                vec![
                    ("Any", None),
                    ("No blockers", Some("blocker".into())),
                    ("No majors or worse", Some("major".into())),
                    ("No minors or worse", Some("minor".into())),
                    ("No findings", Some("nit".into())),
                ],
                rules.block_severity.clone(),
                |r, v| r.block_severity = v,
                cx,
            ))
            .child(label("Risk"))
            .child(choices("risk", vec![("Any", None), ("Low only", Some("low".into())), ("Medium or lower", Some("medium".into()))], rules.max_risk.clone(), |r, v| r.max_risk = v, cx))
            .child(label("A condition the review or GitHub can't answer (no effort or risk given, size unknown) counts as failed."))
            .into_any_element()
    }

    /// A window's last few posts, from the schedule's history: approved,
    /// or commented and why.
    fn last_runs(&self, id: &str, theme: &Theme) -> impl IntoElement {
        let runs = self.schedule.ran_for(id, 5);
        div().when(!runs.is_empty(), |d| {
            d.flex().flex_col().gap_1().child(div().text_xs().text_color(theme.secondary).child("Last runs")).children(runs.into_iter().map(|r| {
                div()
                    .flex()
                    .flex_col()
                    .text_sm()
                    .child(div().flex().flex_row().gap_2().child(div().text_color(theme.secondary).child(r.at.with_timezone(&Local).format("%a %-d %b %H:%M").to_string())).child(r.title.clone()))
                    .when(!r.note.is_empty(), |d| d.child(div().text_xs().text_color(theme.secondary).child(r.note.clone())))
            }))
        })
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

    fn toolbar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let label = match self.view {
            View::Week => {
                let end = self.week + Duration::days(6);
                format!("{} to {}", self.week.format("%-d %b"), end.format("%-d %b %Y"))
            }
            View::Month => self.week.format("%B %Y").to_string(),
        };
        let step = match self.view {
            View::Week => Duration::days(7),
            View::Month => Duration::days(28),
        };
        let settings = self.schedule.settings.clone();
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
            .child(Self::button("view-week", "Week", self.view == View::Week, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.view = View::Week;
                cx.notify();
            })))
            .child(Self::button("view-month", "Month", self.view == View::Month, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.view = View::Month;
                cx.notify();
            })))
            .child(Self::button("prev", "‹", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.week = monday(this.week - step);
                cx.notify();
            })))
            .child(Self::button("today", "Today", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.week = monday(Local::now().date_naive());
                cx.notify();
            })))
            .child(Self::button("next", "›", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.week = monday(this.week + step);
                cx.notify();
            })))
            .child(div().pl_2().font_weight(FontWeight::SEMIBOLD).child(label))
            .child(div().flex_1())
            .child({
                let n = self.waiting_on_you().len();
                Self::button("waiting", if n == 0 { "Waiting on you".to_string() } else { format!("Waiting on you · {n}") }, self.deciding, theme)
                    .when(n > 0, |b| b.text_color(theme.orange()))
                    .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.deciding = !this.deciding;
                        this.adding = None;
                        this.selected = None;
                        cx.notify();
                    }))
            })
            .child(Self::button("gap", format!("PRs {} min apart", settings.gap_minutes), false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.change_all(cx, |s| {
                    s.settings.gap_minutes = match s.settings.gap_minutes {
                        15 => 30,
                        30 => 60,
                        60 => 120,
                        _ => 15,
                    }
                })
            })))
            .child(Self::button("at-once", format!("{} review{} at once", settings.reviews_at_once, if settings.reviews_at_once == 1 { "" } else { "s" }), false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.change_all(cx, |s| s.settings.reviews_at_once = s.settings.reviews_at_once % 3 + 1)
            })))
            .child(Self::button("pause-all", if settings.paused_all { "Resume All" } else { "Pause All" }, settings.paused_all, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.change_all(cx, |s| s.settings.paused_all = !s.settings.paused_all)
            })))
    }

    fn block(&self, b: &Block, date: NaiveDate, theme: &Theme, cx: &mut Context<Self>) -> gpui::Stateful<gpui::Div> {
        let tint = b.kind.tint(theme);
        let on = self.selected.as_deref() == Some(b.id.as_str());
        let id = b.id.clone();
        let (mark, mark_tint) = match b.status {
            "done" => ("✓", theme.good()),
            "failed" => ("✕", theme.critical()),
            "missed" => ("○", theme.secondary),
            "running" => ("●", theme.good()),
            "needs" => ("?", theme.orange()),
            "blocked" => ("!", theme.critical()),
            "scoutfail" => ("!", theme.secondary),
            "scouting" => ("◌", theme.secondary),
            _ => ("", theme.secondary),
        };
        div()
            .id(SharedString::from(format!("block-{}-{}-{}", b.id, date, b.place.map(|p| p.0).unwrap_or(0))))
            .overflow_hidden()
            .rounded_md()
            .px_1p5()
            .py_0p5()
            .cursor_pointer()
            .border_1()
            .border_color(if on { tint } else { tint.opacity(0.5) })
            .bg(tint.opacity(if matches!(b.status, "done" | "missed") { 0.08 } else { 0.18 }))
            .when(b.paused || self.schedule.settings.paused_all, |d| d.opacity(0.5))
            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                cx.stop_propagation();
                this.select(Some(id.clone()), window, cx);
            }))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1()
                    .text_xs()
                    .when(!mark.is_empty(), |d| d.child(div().text_color(mark_tint).child(mark)))
                    .when_some(b.place, |d, (n, of)| d.child(div().text_color(tint).font_weight(FontWeight::SEMIBOLD).child(format!("{n}/{of}"))))
                    .child(div().truncate().font_weight(FontWeight::MEDIUM).child(b.title.clone())),
            )
            .child(div().text_xs().text_color(theme.secondary).child(if b.kind == Kind::Window { format!("{} to {}", clock(b.start), clock(b.start + b.length)) } else { clock(b.start) }))
    }

    fn week_view(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let today = Local::now().date_naive();
        let now = Local::now();
        let hours = LAST_HOUR - FIRST_HOUR;
        let top = |m: u32| (m.saturating_sub(FIRST_HOUR * 60)) as f32 / 60. * HOUR;
        let header = div().flex_none().flex().flex_row().border_b_1().border_color(theme.border).child(div().w(px(52.)).flex_none()).children((0..7).map(|n| {
            let date = self.week + Duration::days(n);
            div()
                .flex_1()
                .py_1p5()
                .flex()
                .flex_row()
                .justify_center()
                .gap_1p5()
                .text_sm()
                .border_l_1()
                .border_color(theme.border)
                .child(div().text_color(theme.secondary).child(date.format("%a").to_string()))
                .child(div().px_1p5().rounded_full().font_weight(FontWeight::SEMIBOLD).when(date == today, |d| d.bg(theme.critical()).text_color(gpui::white())).child(date.day().to_string()))
        }));
        let gutter = div().w(px(52.)).flex_none().relative().h(px(hours as f32 * HOUR)).children((FIRST_HOUR..LAST_HOUR).map(|h| {
            div().absolute().top(px((h - FIRST_HOUR) as f32 * HOUR - 6.)).right(px(6.)).text_xs().text_color(theme.tertiary).child(format!("{h}:00"))
        }));
        let columns = (0..7).map(|n| {
            let date = self.week + Duration::days(n);
            let blocks = self.blocks(date);
            let windows: Vec<Block> = blocks.iter().filter(|b| b.kind == Kind::Window).cloned().collect();
            let others: Vec<Block> = blocks.iter().filter(|b| b.kind != Kind::Window).cloned().collect();
            let mut lanes: Vec<(usize, Block)> = Vec::new();
            let mut ends = [0u32; 2];
            for b in others {
                let lane = if b.start >= ends[0] { 0 } else { 1 };
                ends[lane] = b.start + b.length.max(30);
                lanes.push((lane, b));
            }
            let two = lanes.iter().any(|(l, _)| *l == 1);
            div()
                .flex_1()
                .relative()
                .h(px(hours as f32 * HOUR))
                .border_l_1()
                .border_color(theme.border)
                .when(date == today, |d| d.bg(theme.selected.opacity(0.03)))
                .children((FIRST_HOUR..LAST_HOUR).flat_map(|h| [0u32, 30].map(move |m| h * 60 + m)).map(|minute| {
                    let adding = self.adding == Some((date, minute));
                    div()
                        .id(SharedString::from(format!("slot-{date}-{minute}")))
                        .absolute()
                        .top(px(top(minute)))
                        .left_0()
                        .right_0()
                        .h(px(HOUR / 2.))
                        .when(minute % 60 == 0, |d| d.border_t_1().border_color(theme.grid))
                        .when(adding, |d| d.bg(theme.selected.opacity(0.15)))
                        .hover(|s| s.bg(theme.row_selected.opacity(0.3)))
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.adding = Some((date, minute));
                            this.deciding = false;
                            this.selected = None;
                            cx.notify();
                        }))
                }))
                .children(windows.iter().map(|w| self.block(w, date, theme, cx).absolute().top(px(top(w.start))).h(px(w.length as f32 / 60. * HOUR)).left(px(2.)).right(px(2.))))
                .children(lanes.iter().map(|(lane, b)| {
                    let height = (b.length.max(30) as f32 / 60. * HOUR - 2.).max(22.);
                    let block = self.block(b, date, theme, cx).absolute().top(px(top(b.start) + 1.)).h(px(height));
                    match (two, lane) {
                        (false, _) => block.left(px(10.)).right(px(4.)),
                        (true, 0) => block.left(px(10.)).right(gpui::relative(0.5)),
                        _ => block.left(gpui::relative(0.5)).right(px(4.)),
                    }
                }))
                .when(date == today && now.hour() >= FIRST_HOUR && now.hour() < LAST_HOUR, |d| {
                    d.child(div().absolute().top(px(top(now.hour() * 60 + now.minute()))).left_0().right_0().h(px(2.)).bg(theme.critical()))
                })
        });
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(header)
            .child(div().id("week-body").flex_1().min_h_0().overflow_y_scroll().track_scroll(&self.week_scroll).child(div().flex().flex_row().pt_2().child(gutter).children(columns)))
    }

    fn month_view(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let today = Local::now().date_naive();
        let first = self.week.with_day(1).unwrap_or(self.week);
        let start = monday(first);
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(div().flex_none().flex().flex_row().border_b_1().border_color(theme.border).children(DAYS.map(|d| div().flex_1().py_1p5().text_center().text_sm().text_color(theme.secondary).child(d))))
            .children((0..6).map(|week| {
                div().flex_1().min_h_0().flex().flex_row().border_b_1().border_color(theme.border).children((0..7).map(|n| {
                    let date = start + Duration::days(week * 7 + n);
                    let blocks = self.blocks(date);
                    let more = blocks.len().saturating_sub(4);
                    div()
                        .id(SharedString::from(format!("month-{date}")))
                        .flex_1()
                        .min_w_0()
                        .p_1()
                        .flex()
                        .flex_col()
                        .gap_0p5()
                        .border_l_1()
                        .border_color(theme.border)
                        .when(date.month() != first.month(), |d| d.opacity(0.4))
                        .cursor_pointer()
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.view = View::Week;
                            this.week = monday(date);
                            cx.notify();
                        }))
                        .child(div().flex().flex_row().child(div().px_1().rounded_full().text_xs().font_weight(FontWeight::SEMIBOLD).when(date == today, |d| d.bg(theme.critical()).text_color(gpui::white())).child(date.day().to_string())))
                        .children(blocks.into_iter().take(4).map(|b| {
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap_1()
                                .text_xs()
                                .child(div().size(px(6.)).flex_none().rounded_full().bg(b.kind.tint(theme)))
                                .child(div().flex_none().text_color(theme.secondary).child(clock(b.start)))
                                .child(div().truncate().child(b.title))
                        }))
                        .when(more > 0, |d| d.child(div().text_xs().text_color(theme.secondary).child(format!("{more} more"))))
                }))
            }))
    }

    fn side(&self, theme: &Theme, cx: &mut Context<Self>) -> Option<gpui::AnyElement> {
        let label = |text: &str| div().text_xs().text_color(theme.secondary).child(text.to_string());
        let input = |e: &Entity<editor::Editor>| div().px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).text_sm().child(e.clone());
        if self.deciding {
            return Some(self.decisions_panel(theme, cx));
        }
        if let Some((date, minute)) = self.adding {
            return Some(
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(format!("Add at {} on {}", clock(minute), date.format("%a %-d %b"))))
                    .children([
                        (Kind::Window, "Reviews of PRs asked of you start in it, and post by themselves."),
                        (Kind::Start, "Work on This starts on an issue at this time, unattended."),
                        (Kind::Sequence, "Issues one after another, each to completion before the next."),
                        (Kind::Prompt, "A prompt that runs at this time on the days you pick."),
                    ]
                    .map(|(kind, caption)| {
                        div()
                            .id(SharedString::from(format!("add-{}", kind.title())))
                            .flex()
                            .flex_row()
                            .gap_2()
                            .p_2()
                            .rounded_lg()
                            .cursor_pointer()
                            .border_1()
                            .border_color(theme.border)
                            .hover(|s| s.bg(theme.row_selected))
                            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.add(kind, date, minute, window, cx)))
                            .child(div().w(px(4.)).flex_none().rounded_full().bg(kind.tint(theme)))
                            .child(div().flex_1().min_w_0().flex().flex_col().child(div().font_weight(FontWeight::MEDIUM).child(kind.title())).child(div().text_sm().text_color(theme.secondary).child(caption)))
                    }))
                    .into_any_element(),
            );
        }
        let id = self.selected.clone()?;
        let s = &self.schedule;
        let weekdays_row = |days: Vec<u32>, cx: &mut Context<Self>| {
            div().flex().flex_row().flex_wrap().gap_1().children((0..7u32).map(|d| {
                let on = days.contains(&d);
                Self::button(format!("day-{d}"), DAYS[d as usize], on, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.change(cx, |s, id| {
                        let toggle = |days: &mut Vec<u32>| {
                            if let Some(at) = days.iter().position(|x| *x == d) {
                                if days.len() > 1 {
                                    days.remove(at);
                                }
                            } else {
                                days.push(d);
                                days.sort();
                            }
                        };
                        if let Some(w) = s.windows.iter_mut().find(|w| w.id == id) {
                            toggle(&mut w.weekdays);
                        }
                        if let Some(p) = s.prompts.iter_mut().find(|p| p.id == id) {
                            toggle(&mut p.weekdays);
                        }
                    })
                }))
            }))
        };
        let (kind, paused) = if let Some(w) = s.windows.iter().find(|w| w.id == id) {
            (Kind::Window, w.paused)
        } else if let Some(p) = s.prompts.iter().find(|p| p.id == id) {
            (Kind::Prompt, p.paused)
        } else if let Some(x) = s.starts.iter().find(|x| x.id == id) {
            (Kind::Start, x.paused)
        } else if let Some(q) = s.sequences.iter().find(|q| q.id == id) {
            (Kind::Sequence, q.paused)
        } else {
            return None;
        };
        let tint = kind.tint(theme);
        let mut body = div()
            .flex()
            .flex_col()
            .gap_3()
            .child(div().flex().flex_row().items_center().gap_2().child(div().size(px(8.)).rounded_full().bg(tint)).child(div().text_xs().text_color(tint).child(kind.title())));
        match kind {
            Kind::Window => {
                let w = s.windows.iter().find(|w| w.id == id).cloned().unwrap_or_default();
                body = body
                    .child(label("Name"))
                    .child(input(&self.name_field))
                    .child(label("Days"))
                    .child(weekdays_row(w.weekdays.clone(), cx))
                    .child(label("Starts at"))
                    .child(input(&self.time_field))
                    .child(label("Length"))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .child(Self::button("len-less", "−", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.change(cx, |s, id| {
                                if let Some(w) = s.windows.iter_mut().find(|w| w.id == id) {
                                    w.length = w.length.saturating_sub(15).max(15);
                                }
                            }))))
                            .child(div().text_sm().child(format!("{} min, to {}", w.length, clock(w.start + w.length))))
                            .child(Self::button("len-more", "+", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.change(cx, |s, id| {
                                if let Some(w) = s.windows.iter_mut().find(|w| w.id == id) {
                                    w.length = (w.length + 15).min(12 * 60);
                                }
                            })))),
                    )
                    .child(self.approve_section(&w, theme, cx))
                    .child(div().text_xs().text_color(theme.secondary).child(format!(
                        "Reviews of pull requests where you're a requested reviewer start in it, {} at once, and post by themselves. {}",
                        s.settings.reviews_at_once,
                        if !w.approve.enabled {
                            "An approval posts as a comment for you to approve."
                        } else if w.approve == (ApproveRules { enabled: true, ..Default::default() }) {
                            "They approve when the review says to, except on your own pull requests."
                        } else {
                            "They approve when the review says to and every condition above passes; otherwise the approval posts as a comment, saying why."
                        }
                    )))
                    .child(self.last_runs(&w.id, theme));
            }
            Kind::Prompt => {
                let p = s.prompts.iter().find(|p| p.id == id).cloned().unwrap_or_default();
                body = body
                    .child(label("Name"))
                    .child(input(&self.name_field))
                    .child(label("Days"))
                    .child(weekdays_row(p.weekdays.clone(), cx))
                    .child(label("At"))
                    .child(input(&self.time_field))
                    .child(label("Prompt"))
                    .child(input(&self.text_field))
                    .child(div().text_xs().text_color(theme.secondary).child("Opens an Ask with it, unattended, in this window's project."));
            }
            Kind::Start => {
                let x = s.starts.iter().find(|x| x.id == id).cloned().unwrap_or_default();
                let (date, _) = local(x.at);
                body = body
                    .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(x.issue.label()))
                    .child(div().text_sm().text_color(theme.secondary).child(x.issue.repo.clone()))
                    .child(label("On"))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .child(Self::button("day-back", "‹", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.change(cx, |s, id| {
                                if let Some(x) = s.starts.iter_mut().find(|x| x.id == id) {
                                    x.at -= Duration::days(1);
                                }
                            }))))
                            .child(div().text_sm().child(date.format("%a %-d %b").to_string()))
                            .child(Self::button("day-on", "›", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.change(cx, |s, id| {
                                if let Some(x) = s.starts.iter_mut().find(|x| x.id == id) {
                                    x.at += Duration::days(1);
                                }
                            })))),
                    )
                    .child(label("At"))
                    .child(input(&self.time_field))
                    .child(div().text_sm().child(match &x.run {
                        RunState::Waiting => "Waiting for its time.".to_string(),
                        RunState::Started { .. } => "Started: its session is in a tab.".into(),
                        RunState::Done { .. } => "Done.".into(),
                        RunState::Failed { reason, .. } => format!("Failed: {reason}"),
                        RunState::Missed { .. } => "Missed: the app wasn't open.".into(),
                    }));
            }
            Kind::Sequence => {
                let q = s.sequences.iter().find(|q| q.id == id).cloned().unwrap_or_default();
                let (date, _) = local(q.start);
                let editable = q.runs.iter().all(|r| *r == RunState::Waiting);
                body = body
                    .child(label("Name"))
                    .child(input(&self.name_field))
                    .child(label("Starts"))
                    .child(div().text_sm().child(date.format("%a %-d %b").to_string()))
                    .child(input(&self.time_field))
                    .child(label("Interval"))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .child(Self::button("int-less", "−", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.change(cx, |s, id| {
                                if let Some(q) = s.sequences.iter_mut().find(|q| q.id == id) {
                                    q.interval = q.interval.saturating_sub(5).max(5);
                                }
                            }))))
                            .child(div().text_sm().child(format!("{} min between starts", q.interval)))
                            .child(Self::button("int-more", "+", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.change(cx, |s, id| {
                                if let Some(q) = s.sequences.iter_mut().find(|q| q.id == id) {
                                    q.interval = (q.interval + 5).min(24 * 60);
                                }
                            })))),
                    )
                    .child(label("Each to completion, in order"))
                    .children(q.items.iter().enumerate().map(|(i, item)| {
                        let run = q.runs.get(i).cloned().unwrap_or_default();
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .text_sm()
                            .child(div().w(px(18.)).text_color(tint).child(format!("{}", i + 1)))
                            .child(div().flex_1().truncate().child(item.label()))
                            .child(div().text_xs().text_color(theme.secondary).child(status_of(&run)))
                            .when(editable && i > 0, |d| {
                                d.child(Self::button(format!("up-{i}"), "↑", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.change(cx, |s, id| {
                                    if let Some(q) = s.sequences.iter_mut().find(|q| q.id == id) {
                                        q.items.swap(i, i - 1);
                                    }
                                }))))
                            })
                            .when(editable && q.items.len() > 1, |d| {
                                d.child(Self::button(format!("drop-{i}"), "×", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.change(cx, |s, id| {
                                    if let Some(q) = s.sequences.iter_mut().find(|q| q.id == id) {
                                        q.items.remove(i);
                                        q.runs.truncate(q.items.len());
                                    }
                                }))))
                            })
                    }))
                    .child(div().text_xs().text_color(theme.secondary).child("The next starts once one's pull request is open, its checks pass and no review threads are left open, and the interval since it started has passed. A failed item pauses the sequence."));
            }
        }
        let runs_now = kind != Kind::Window;
        body = body.child(
            div()
                .flex()
                .flex_row()
                .flex_wrap()
                .gap_2()
                .when(runs_now, |d| d.child(Self::button("run-now", "Run Now", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                    if let Some(id) = this.selected.clone() {
                        cx.emit(RunNow(id));
                    }
                }))))
                .child(Self::button("pause-item", if paused { "Resume" } else { "Pause" }, paused, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.change(cx, |s, id| {
                    s.windows.iter_mut().filter(|w| w.id == id).for_each(|w| w.paused = !w.paused);
                    s.prompts.iter_mut().filter(|w| w.id == id).for_each(|w| w.paused = !w.paused);
                    s.starts.iter_mut().filter(|w| w.id == id).for_each(|w| w.paused = !w.paused);
                    s.sequences.iter_mut().filter(|w| w.id == id).for_each(|w| w.paused = !w.paused);
                }))))
                .child(Self::button("delete-item", "Delete", false, theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                    this.change(cx, |s, id| {
                        s.windows.retain(|w| w.id != id);
                        s.prompts.retain(|w| w.id != id);
                        s.starts.retain(|w| w.id != id);
                        s.sequences.retain(|w| w.id != id);
                    });
                    this.select(None, window, cx);
                }))),
        );
        Some(body.into_any_element())
    }

    fn picker(&self, picking: &Picking, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let search = self.search_field.read(cx).text(cx).to_lowercase();
        let multi = picking.kind == Kind::Sequence;
        let list: Vec<(IssueRef, usize)> = picking
            .issues
            .clone()
            .unwrap_or_default()
            .into_iter()
            .filter(|(i, _)| search.split_whitespace().all(|w| i.title.to_lowercase().contains(w) || i.repo.to_lowercase().contains(w) || i.number.to_string() == w.trim_start_matches('#')))
            .take(200)
            .collect();
        div()
            .id("issue-picker")
            .occlude()
            .w(px(600.))
            .h(px(520.))
            .flex()
            .flex_col()
            .bg(theme.popover)
            .border_1()
            .border_color(theme.border)
            .rounded_xl()
            .shadow_lg()
            .overflow_hidden()
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .p_3()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(if multi {
                        format!("Issues for a sequence at {} on {}: pick them in order", clock(picking.minute), picking.date.format("%a %-d %b"))
                    } else {
                        format!("Start an issue at {} on {}", clock(picking.minute), picking.date.format("%a %-d %b"))
                    }))
                    .child(div().px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).child(self.search_field.clone())),
            )
            .child(
                div()
                    .id("issue-picker-rows")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .when(picking.issues.is_none(), |d| d.child(div().p_4().text_sm().text_color(theme.secondary).child("Loading issues")))
                    .children(list.into_iter().map(|(issue, subs)| {
                        let epic = issue.clone();
                        let reading = picking.reading.as_deref() == Some(issue.id.as_str());
                        let place = picking.picked.iter().position(|p| p.id == issue.id);
                        let key = issue.id.clone();
                        let (title, repo) = (format!("#{} {}", issue.number, issue.title), issue.repo.clone());
                        div()
                            .id(SharedString::from(format!("pick-{key}")))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .px_3()
                            .py_1p5()
                            .cursor_pointer()
                            .when(place.is_some(), |d| d.bg(theme.selected.opacity(0.15)))
                            .hover(|s| s.bg(theme.row_selected.opacity(0.6)))
                            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                                let Some(p) = this.picking.as_mut() else { return };
                                if let Some(at) = p.picked.iter().position(|x| x.id == issue.id) {
                                    p.picked.remove(at);
                                } else {
                                    p.picked.push(issue.clone());
                                }
                                if p.kind == Kind::Start {
                                    this.finish_picking(window, cx);
                                }
                                cx.notify();
                            }))
                            .child(div().w(px(18.)).text_sm().text_color(theme.selected).child(place.map(|n| (n + 1).to_string()).unwrap_or_default()))
                            .child(div().flex_1().min_w_0().flex().flex_col().child(div().truncate().text_sm().child(title)).child(div().text_xs().text_color(theme.secondary).child(repo)))
                            // An epic adds its sub-issues, in the order set on GitHub.
                            .when(multi && subs > 0, |d| {
                                d.child(
                                    Self::button(format!("subs-{}", epic.id), if reading { "Reading".to_string() } else { format!("Add its {subs} sub-issues") }, false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                        cx.stop_propagation();
                                        this.add_sub_issues(epic.clone(), cx);
                                    })),
                                )
                            })
                    })),
            )
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap_2()
                    .px_3()
                    .py_2()
                    .border_t_1()
                    .border_color(theme.border)
                    .child(Self::button("picker-cancel", "Cancel", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.picking = None;
                        cx.notify();
                    })))
                    .when(multi, |d| {
                        d.child(Self::button("picker-done", format!("Make Sequence ({})", picking.picked.len()), true, theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.finish_picking(window, cx))))
                    }),
            )
    }
}

impl Render for SchedulePage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        if !self.scrolled {
            self.scrolled = true;
            self.week_scroll.set_offset(gpui::point(px(0.), px(-((OPENS_AT - FIRST_HOUR) as f32) * HOUR)));
        }
        let side = self.side(&theme, cx);
        let body = match self.view {
            View::Week => self.week_view(&theme, cx).into_any_element(),
            View::Month => self.month_view(&theme, cx).into_any_element(),
        };
        let picker = self.picking.as_ref().map(|p| self.picker(p, &theme, cx).into_any_element());
        div()
            .relative()
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
                    .child(div().flex_1().min_w_0().h_full().child(body))
                    .when_some(side, |d, side| d.child(div().id("schedule-side").w(px(320.)).flex_none().h_full().overflow_y_scroll().p_4().border_l_1().border_color(theme.border).bg(theme.sidebar).child(side))),
            )
            .when_some(picker, |d, picker| d.child(div().absolute().top_0().left_0().right_0().bottom_0().bg(gpui::black().opacity(0.3)).flex().justify_center().pt(px(60.)).child(picker)))
    }
}
