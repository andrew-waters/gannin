//! Schedule: the scheduler's one page (docs/scheduler.md), on this Mac's
//! `schedule.json`. A week (days across, hours down) or a month, with review
//! windows shaded, issue starts at their time, a sequence's items laid out
//! from its start (two hours each until they've run), recurring prompts on
//! their days, and how each went. An empty half hour adds one of the four
//! kinds there; a block opens its settings on the right. The clock that
//! runs them is the workspace's (`schedule_tick`); Run Now asks it.

use crate::charts::Theme;
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
    picking: Option<Picking>,
    name_field: Entity<editor::Editor>,
    time_field: Entity<editor::Editor>,
    text_field: Entity<editor::Editor>,
    search_field: Entity<editor::Editor>,
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
            picking: None,
            name_field,
            time_field,
            text_field,
            search_field,
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

    fn change_all(&mut self, cx: &mut Context<Self>, f: impl FnOnce(&mut Schedule)) {
        let mut fresh = Schedule::load();
        f(&mut fresh);
        fresh.save();
        self.schedule = fresh;
        cx.notify();
    }

    /// The blocks on a date.
    fn blocks(&self, date: NaiveDate) -> Vec<Block> {
        let s = &self.schedule;
        let today = Local::now().date_naive();
        let weekday = date.weekday().num_days_from_monday();
        let mut out = Vec::new();
        for w in s.windows.iter().filter(|w| w.weekdays.contains(&weekday)) {
            out.push(Block { kind: Kind::Window, id: w.id.clone(), title: w.name.clone(), start: w.start, length: w.length, status: "", paused: w.paused, place: None });
        }
        for st in &s.starts {
            let (d, m) = local(st.at);
            if d == date {
                out.push(Block { kind: Kind::Start, id: st.id.clone(), title: st.issue.label(), start: m, length: 90, status: status_of(&st.run), paused: st.paused, place: None });
            }
        }
        for q in &s.sequences {
            // Each item at when it started, or two hours after the one before.
            let (mut d, mut m) = local(q.start);
            for (i, item) in q.items.iter().enumerate() {
                let run = q.runs.get(i).cloned().unwrap_or_default();
                if let RunState::Started { at, .. } | RunState::Done { at, .. } = &run {
                    if i > 0 {
                        (d, m) = local(*at);
                    }
                }
                if d == date {
                    out.push(Block { kind: Kind::Sequence, id: q.id.clone(), title: item.label(), start: m, length: 110, status: status_of(&run), paused: q.paused, place: Some((i + 1, q.items.len())) });
                }
                m += 120;
                if m >= 24 * 60 {
                    m -= 24 * 60;
                    d = d.succ_opt().unwrap_or(d);
                }
            }
        }
        for p in s.prompts.iter().filter(|p| p.weekdays.contains(&weekday)) {
            // A past day's run, from what ran.
            let status = if date <= today {
                s.ran.iter().rev().find(|r| r.item == p.id && local(r.at).0 == date).map(|r| match r.outcome.as_str() {
                    "missed" => "missed",
                    "failed" => "failed",
                    _ => "done",
                })
            } else {
                None
            };
            out.push(Block { kind: Kind::Prompt, id: p.id.clone(), title: p.name.clone(), start: p.start, length: 20, status: status.unwrap_or(""), paused: p.paused, place: None });
        }
        out.sort_by_key(|b| b.start);
        out
    }

    fn select(&mut self, id: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        self.selected = id.clone();
        self.adding = None;
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
                let new = ReviewWindow { id: id.clone(), name: "Reviews".into(), weekdays: days, start: minute, length: 60, paused: false };
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
                            let mut items: Vec<(IssueRef, usize)> = org
                                .and_then(|o| crate::issues::load(&o).ok())
                                .unwrap_or_default()
                                .into_iter()
                                .filter(|i| i.closed_at.is_none())
                                .map(|i| (IssueRef { id: i.id, repo: i.repo, number: i.number, title: i.title, url: i.url }, i.sub_issues))
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
                let seq = Sequence { id: id.clone(), name, start: at, items: picking.picked.clone(), runs: vec![RunState::Waiting; picking.picked.len()], paused: false };
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
            .child(Self::button("approve", "Approve by itself", settings.approve_by_itself, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.change_all(cx, |s| s.settings.approve_by_itself = !s.settings.approve_by_itself)
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
                    .child(div().text_xs().text_color(theme.secondary).child(format!(
                        "Reviews of pull requests where you're a requested reviewer start in it, {} at once, and post by themselves{}.",
                        s.settings.reviews_at_once,
                        if s.settings.approve_by_itself { ", approving when the review says to" } else { "; an approval posts as a comment for you to approve" }
                    )));
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
                    .child(div().text_xs().text_color(theme.secondary).child("The next starts once one's pull request is open, its checks pass and no review threads are left open. A failed item pauses the sequence."));
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
