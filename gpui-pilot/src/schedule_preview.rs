//! Schedule Preview: one page for everything claude does unattended (see
//! docs/scheduler.md), from made-up items, to shape before it's wired: a
//! week (days across, hours down) or a month, with review windows shaded,
//! issues pinned to a time, a sequence's items end to end, recurring
//! prompts at each time they recur, and what already ran. A block opens
//! its detail on the right; an empty slot offers to add one of the four
//! kinds there. Nothing runs.

use crate::charts::Theme;
use chrono::{Datelike, Duration, Local, NaiveDate, Timelike, Weekday};
use gpui::{div, prelude::*, px, ClickEvent, Context, FontWeight, Hsla, SharedString, Window};

const FIRST_HOUR: u32 = 7;
const LAST_HOUR: u32 = 20;
const HOUR: f32 = 52.;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    ReviewWindow,
    IssueStart,
    Sequence,
    Prompt,
}

impl Kind {
    fn title(self) -> &'static str {
        match self {
            Kind::ReviewWindow => "Review window",
            Kind::IssueStart => "Issue start",
            Kind::Sequence => "Sequence",
            Kind::Prompt => "Recurring prompt",
        }
    }

    fn tint(self, theme: &Theme) -> Hsla {
        match self {
            Kind::ReviewWindow => theme.blue(),
            Kind::IssueStart => theme.good(),
            Kind::Sequence => gpui::rgb(0xA259FF).into(),
            Kind::Prompt => theme.orange(),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Status {
    Upcoming,
    Running,
    Done,
    Failed,
    Missed,
}

impl Status {
    fn label(self) -> &'static str {
        match self {
            Status::Upcoming => "Upcoming",
            Status::Running => "Running",
            Status::Done => "Done",
            Status::Failed => "Failed",
            Status::Missed => "Missed",
        }
    }
}

#[derive(Clone)]
struct Item {
    id: usize,
    kind: Kind,
    title: String,
    /// When it is: a date, or every given weekday (recurring).
    date: Option<NaiveDate>,
    weekdays: Vec<Weekday>,
    start: u32,
    length: u32,
    status: Status,
    paused: bool,
    /// For a sequence's item: its place, of how many.
    place: Option<(usize, usize)>,
    detail: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum View {
    Week,
    Month,
}

pub struct SchedulePreview {
    view: View,
    /// The Monday of the week showing (the month is the one it's in).
    week: NaiveDate,
    items: Vec<Item>,
    selected: Option<usize>,
    /// An empty slot clicked: its date and minute, to add something there.
    adding: Option<(NaiveDate, u32)>,
    paused_all: bool,
    gap: u32,
}

fn monday(date: NaiveDate) -> NaiveDate {
    date - Duration::days(date.weekday().num_days_from_monday() as i64)
}

fn clock(minutes: u32) -> String {
    format!("{}:{:02}", minutes / 60, minutes % 60)
}

fn sample(today: NaiveDate) -> Vec<Item> {
    let week = monday(today);
    let day = |n: i64| Some(week + Duration::days(n));
    let weekdays = vec![Weekday::Mon, Weekday::Tue, Weekday::Wed, Weekday::Thu, Weekday::Fri];
    let past = |date: Option<NaiveDate>, done: Status| if date.is_some_and(|d| d < today) { done } else { Status::Upcoming };
    let mut items = vec![
        Item {
            id: 0,
            kind: Kind::ReviewWindow,
            title: "Morning reviews".into(),
            date: None,
            weekdays: weekdays.clone(),
            start: 9 * 60,
            length: 120,
            status: Status::Upcoming,
            paused: false,
            place: None,
            detail: "Reviews of pull requests where you're a requested reviewer start in this window. They post by themselves; an approve verdict posts as a comment unless Approve by itself is on.".into(),
        },
        Item {
            id: 1,
            kind: Kind::ReviewWindow,
            title: "Afternoon reviews".into(),
            date: None,
            weekdays: vec![Weekday::Tue, Weekday::Thu],
            start: 14 * 60,
            length: 90,
            status: Status::Upcoming,
            paused: false,
            place: None,
            detail: "Reviews of pull requests where you're a requested reviewer.".into(),
        },
        Item {
            id: 2,
            kind: Kind::Prompt,
            title: "Monday report".into(),
            date: None,
            weekdays: vec![Weekday::Mon],
            start: 8 * 60 + 30,
            length: 20,
            status: Status::Upcoming,
            paused: false,
            place: None,
            detail: "Every Monday at 8:30: \"Summarise last week: what merged, what's stuck in review, and what's due this week.\"".into(),
        },
        Item {
            id: 3,
            kind: Kind::Prompt,
            title: "Friday wrap-up".into(),
            date: None,
            weekdays: vec![Weekday::Fri],
            start: 16 * 60,
            length: 20,
            status: Status::Upcoming,
            paused: false,
            place: None,
            detail: "Every Friday at 16:00: \"List my open pull requests and what each is waiting on.\"".into(),
        },
        Item {
            id: 4,
            kind: Kind::IssueStart,
            title: "#412 Retry failed webhooks".into(),
            date: day(1),
            weekdays: Vec::new(),
            start: 7 * 60 + 30,
            length: 90,
            status: past(day(1), Status::Done),
            paused: false,
            place: None,
            detail: "Work on This starts at 7:30, unattended, up to a ready pull request.".into(),
        },
        Item {
            id: 5,
            kind: Kind::IssueStart,
            title: "#418 Paginate the audit log".into(),
            date: day(3),
            weekdays: Vec::new(),
            start: 12 * 60,
            length: 90,
            status: past(day(3), Status::Failed),
            paused: false,
            place: None,
            detail: "Work on This starts at 12:00, unattended, up to a ready pull request.".into(),
        },
    ];
    // A sequence: each item to completion (PR open, checks passing, bot
    // comments dealt with) before the next.
    let seq = ["#420 Rename the tenant column", "#421 Backfill tenant ids", "#422 Drop the old tenant table"];
    for (i, title) in seq.iter().enumerate() {
        let date = day(2);
        items.push(Item {
            id: 6 + i,
            kind: Kind::Sequence,
            title: (*title).into(),
            date,
            weekdays: Vec::new(),
            start: 12 * 60 + 30 + i as u32 * 120,
            length: 110,
            status: if date.is_some_and(|d| d < today) { [Status::Done, Status::Done, Status::Missed][i] } else { Status::Upcoming },
            paused: false,
            place: Some((i + 1, seq.len())),
            detail: "Tenant migration: each item runs to completion before the next starts. Times are the latest it should start, from the items before.".into(),
        });
    }
    // Whatever's on now, today, is running.
    let now = Local::now();
    let minute = now.hour() * 60 + now.minute();
    for item in &mut items {
        if item.date == Some(today) && item.start <= minute && minute < item.start + item.length {
            item.status = Status::Running;
        }
    }
    items
}

impl SchedulePreview {
    pub fn new(_: &mut Window, _: &mut Context<Self>) -> Self {
        let today = Local::now().date_naive();
        Self { view: View::Week, week: monday(today), items: sample(today), selected: None, adding: None, paused_all: false, gap: 30 }
    }

    /// The items on a date, recurring ones included.
    fn on(&self, date: NaiveDate) -> Vec<&Item> {
        let mut items: Vec<&Item> = self.items.iter().filter(|i| i.date == Some(date) || (i.date.is_none() && i.weekdays.contains(&date.weekday()))).collect();
        items.sort_by_key(|i| i.start);
        items
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
                if self.week.month() == end.month() {
                    format!("{} to {} {}", self.week.day(), end.day(), end.format("%b %Y"))
                } else {
                    format!("{} to {}", self.week.format("%-d %b"), end.format("%-d %b %Y"))
                }
            }
            View::Month => self.week.format("%B %Y").to_string(),
        };
        let step = |by: i64, view: View| match view {
            View::Week => Duration::days(7 * by),
            View::Month => Duration::days(28 * by),
        };
        let view = self.view;
        div()
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .px_4()
            .py_2()
            .border_b_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .child(Self::button("view-week", "Week", view == View::Week, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.view = View::Week;
                cx.notify();
            })))
            .child(Self::button("view-month", "Month", view == View::Month, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.view = View::Month;
                cx.notify();
            })))
            .child(div().w(px(8.)))
            .child(Self::button("prev", "‹", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.week = monday(this.week - step(1, view));
                cx.notify();
            })))
            .child(Self::button("today", "Today", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.week = monday(Local::now().date_naive());
                cx.notify();
            })))
            .child(Self::button("next", "›", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.week = monday(this.week + step(1, view));
                cx.notify();
            })))
            .child(div().pl_2().font_weight(FontWeight::SEMIBOLD).child(label))
            .child(div().flex_1())
            .child(div().text_sm().text_color(theme.secondary).child(format!("Unattended PRs at least {} min apart", self.gap)))
            .child(Self::button("gap", "Change", false, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.gap = match this.gap {
                    15 => 30,
                    30 => 60,
                    60 => 120,
                    _ => 15,
                };
                cx.notify();
            })))
            .child(Self::button("pause-all", if self.paused_all { "Resume All" } else { "Pause All" }, self.paused_all, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.paused_all = !this.paused_all;
                cx.notify();
            })))
    }

    fn block(&self, item: &Item, theme: &Theme, cx: &mut Context<Self>) -> gpui::Stateful<gpui::Div> {
        let tint = item.kind.tint(theme);
        let paused = item.paused || self.paused_all;
        let on = self.selected == Some(item.id);
        let id = item.id;
        let (mark, mark_tint) = match item.status {
            Status::Done => ("✓", theme.good()),
            Status::Failed => ("✕", theme.critical()),
            Status::Missed => ("○", theme.secondary),
            Status::Running => ("●", theme.good()),
            Status::Upcoming => ("", theme.secondary),
        };
        div()
            .id(SharedString::from(format!("block-{}-{}", item.id, item.date.map(|d| d.to_string()).unwrap_or_default())))
            .overflow_hidden()
            .rounded_md()
            .px_1p5()
            .py_0p5()
            .cursor_pointer()
            .border_1()
            .border_color(if on { tint } else { tint.opacity(0.5) })
            .bg(tint.opacity(if matches!(item.status, Status::Done | Status::Missed) { 0.08 } else { 0.18 }))
            .when(paused, |d| d.opacity(0.5))
            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                cx.stop_propagation();
                this.selected = Some(id);
                this.adding = None;
                cx.notify();
            }))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1()
                    .text_xs()
                    .when(!mark.is_empty(), |d| d.child(div().text_color(mark_tint).child(mark)))
                    .when_some(item.place, |d, (n, of)| d.child(div().text_color(tint).font_weight(FontWeight::SEMIBOLD).child(format!("{n}/{of}"))))
                    .child(div().truncate().font_weight(FontWeight::MEDIUM).child(item.title.clone())),
            )
            .child(div().text_xs().text_color(theme.secondary).child(if item.kind == Kind::ReviewWindow {
                format!("{} to {}", clock(item.start), clock(item.start + item.length))
            } else {
                clock(item.start)
            }))
    }

    fn week_view(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let today = Local::now().date_naive();
        let now = Local::now();
        let hours = LAST_HOUR - FIRST_HOUR;
        let top = |minutes: u32| (minutes.saturating_sub(FIRST_HOUR * 60)) as f32 / 60. * HOUR;
        let header = div()
            .flex_none()
            .flex()
            .flex_row()
            .border_b_1()
            .border_color(theme.border)
            .child(div().w(px(52.)).flex_none())
            .children((0..7).map(|n| {
                let date = self.week + Duration::days(n);
                let is_today = date == today;
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
                    .child(
                        div()
                            .px_1p5()
                            .rounded_full()
                            .font_weight(FontWeight::SEMIBOLD)
                            .when(is_today, |d| d.bg(theme.critical()).text_color(gpui::white()))
                            .child(date.day().to_string()),
                    )
            }));
        let gutter = div().w(px(52.)).flex_none().relative().h(px(hours as f32 * HOUR)).children((FIRST_HOUR..LAST_HOUR).map(|h| {
            div().absolute().top(px((h - FIRST_HOUR) as f32 * HOUR - 6.)).right(px(6.)).text_xs().text_color(theme.tertiary).child(format!("{h}:00"))
        }));
        let columns = (0..7).map(|n| {
            let date = self.week + Duration::days(n);
            let items = self.on(date);
            let windows: Vec<&Item> = items.iter().copied().filter(|i| i.kind == Kind::ReviewWindow).collect();
            let others: Vec<&Item> = items.iter().copied().filter(|i| i.kind != Kind::ReviewWindow).collect();
            // Blocks that overlap the one before go in a second lane.
            let mut lanes: Vec<(u32, &Item)> = Vec::new();
            let mut ends = [0u32; 2];
            for item in others {
                let lane = if item.start >= ends[0] { 0 } else { 1 };
                ends[lane] = item.start + item.length.max(30);
                lanes.push((lane as u32, item));
            }
            let two = lanes.iter().any(|(l, _)| *l == 1);
            div()
                .id(SharedString::from(format!("day-{n}")))
                .flex_1()
                .relative()
                .h(px(hours as f32 * HOUR))
                .border_l_1()
                .border_color(theme.border)
                .when(date == today, |d| d.bg(theme.selected.opacity(0.03)))
                // Hour lines, each half an empty slot to add at.
                .children((FIRST_HOUR..LAST_HOUR).flat_map(|h| [0u32, 30].map(move |m| (h, m))).map(|(h, m)| {
                    let minute = h * 60 + m;
                    let adding = self.adding == Some((date, minute));
                    div()
                        .id(SharedString::from(format!("slot-{n}-{minute}")))
                        .absolute()
                        .top(px(top(minute)))
                        .left_0()
                        .right_0()
                        .h(px(HOUR / 2.))
                        .when(m == 0, |d| d.border_t_1().border_color(theme.grid))
                        .when(adding, |d| d.bg(theme.selected.opacity(0.15)))
                        .hover(|s| s.bg(theme.row_selected.opacity(0.3)))
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.adding = Some((date, minute));
                            this.selected = None;
                            cx.notify();
                        }))
                }))
                // Review windows, shaded behind.
                .children(windows.into_iter().map(|w| {
                    self.block(w, theme, cx).absolute().top(px(top(w.start))).h(px(w.length as f32 / 60. * HOUR)).left(px(2.)).right(px(2.))
                }))
                .children(lanes.into_iter().map(|(lane, item)| {
                    let height = (item.length.max(30) as f32 / 60. * HOUR - 2.).max(22.);
                    let block = self.block(item, theme, cx).absolute().top(px(top(item.start) + 1.)).h(px(height));
                    match (two, lane) {
                        (false, _) => block.left(px(10.)).right(px(4.)),
                        (true, 0) => block.left(px(10.)).right(gpui::relative(0.5)),
                        _ => block.left(gpui::relative(0.5)).right(px(4.)),
                    }
                }))
                // Now, as a line across today.
                .when(date == today && now.hour() >= FIRST_HOUR && now.hour() < LAST_HOUR, |d| {
                    d.child(div().absolute().top(px(top(now.hour() * 60 + now.minute()))).left_0().right_0().h(px(2.)).bg(theme.critical()))
                })
        });
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(header)
            .child(div().id("week-body").flex_1().min_h_0().overflow_y_scroll().child(div().flex().flex_row().pt_2().child(gutter).children(columns)))
    }

    fn month_view(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let today = Local::now().date_naive();
        let first = self.week.with_day(1).unwrap_or(self.week);
        let start = monday(first);
        let month = first.month();
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_row()
                    .border_b_1()
                    .border_color(theme.border)
                    .children(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map(|d| div().flex_1().py_1p5().text_center().text_sm().text_color(theme.secondary).child(d))),
            )
            .children((0..6).map(|week| {
                div().flex_1().min_h_0().flex().flex_row().border_b_1().border_color(theme.border).children((0..7).map(|n| {
                    let date = start + Duration::days(week * 7 + n);
                    let items = self.on(date);
                    let more = items.len().saturating_sub(4);
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
                        .when(date.month() != month, |d| d.opacity(0.4))
                        .cursor_pointer()
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.view = View::Week;
                            this.week = monday(date);
                            cx.notify();
                        }))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .child(div().px_1().rounded_full().text_xs().font_weight(FontWeight::SEMIBOLD).when(date == today, |d| d.bg(theme.critical()).text_color(gpui::white())).child(date.day().to_string())),
                        )
                        .children(items.into_iter().take(4).map(|i| {
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap_1()
                                .text_xs()
                                .child(div().size(px(6.)).flex_none().rounded_full().bg(i.kind.tint(theme)))
                                .child(div().flex_none().text_color(theme.secondary).child(clock(i.start)))
                                .child(div().truncate().child(i.title.clone()))
                        }))
                        .when(more > 0, |d| d.child(div().text_xs().text_color(theme.secondary).child(format!("{more} more"))))
                }))
            }))
    }

    /// The right-hand panel: the block picked, or what to add at a slot.
    fn side(&self, theme: &Theme, cx: &mut Context<Self>) -> Option<impl IntoElement> {
        if let Some((date, minute)) = self.adding {
            return Some(
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(format!("Add at {} on {}", clock(minute), date.format("%a %-d %b"))))
                    .children([Kind::ReviewWindow, Kind::IssueStart, Kind::Sequence, Kind::Prompt].map(|kind| {
                        let (title, caption) = match kind {
                            Kind::ReviewWindow => ("Review window", "Reviews of PRs asked of you start in it, and post by themselves."),
                            Kind::IssueStart => ("Issue start", "Work on This starts on an issue at this time, unattended."),
                            Kind::Sequence => ("Sequence", "Issues one after another, each to completion before the next."),
                            Kind::Prompt => ("Recurring prompt", "A prompt that runs at this time every day or week you pick."),
                        };
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
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                let id = this.items.len() + 100;
                                this.items.push(Item {
                                    id,
                                    kind,
                                    title: format!("New {}", kind.title().to_lowercase()),
                                    date: (kind != Kind::Prompt && kind != Kind::ReviewWindow).then_some(date),
                                    weekdays: if matches!(kind, Kind::Prompt | Kind::ReviewWindow) { vec![date.weekday()] } else { Vec::new() },
                                    start: minute,
                                    length: if kind == Kind::ReviewWindow { 60 } else { 60 },
                                    status: Status::Upcoming,
                                    paused: false,
                                    place: (kind == Kind::Sequence).then_some((1, 1)),
                                    detail: "Made in the preview; nothing runs.".into(),
                                });
                                this.adding = None;
                                this.selected = Some(id);
                                cx.notify();
                            }))
                            .child(div().w(px(4.)).flex_none().rounded_full().bg(kind.tint(theme)))
                            .child(div().flex().flex_col().child(div().font_weight(FontWeight::MEDIUM).child(title)).child(div().text_sm().text_color(theme.secondary).child(caption)))
                    }))
                    .into_any_element(),
            );
        }
        let item = self.items.iter().find(|i| Some(i.id) == self.selected)?.clone();
        let tint = item.kind.tint(theme);
        let when = match (item.date, item.weekdays.as_slice()) {
            (Some(date), _) => format!("{} at {}", date.format("%a %-d %b"), clock(item.start)),
            (None, days) if days.len() == 5 && !days.contains(&Weekday::Sat) && !days.contains(&Weekday::Sun) => format!("Weekdays, {}", clock(item.start)),
            (None, days) => format!("Every {}, {}", days.iter().map(|d| format!("{d}")).collect::<Vec<_>>().join(", "), clock(item.start)),
        };
        let id = item.id;
        let paused = item.paused;
        Some(
            div()
                .flex()
                .flex_col()
                .gap_3()
                .child(div().flex().flex_row().items_center().gap_2().child(div().size(px(8.)).rounded_full().bg(tint)).child(div().text_xs().text_color(tint).child(item.kind.title())))
                .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(item.title.clone()))
                .child(div().text_sm().child(if item.kind == Kind::ReviewWindow { format!("{when} to {}", clock(item.start + item.length)) } else { when }))
                .when_some(item.place, |d, (n, of)| d.child(div().text_sm().text_color(theme.secondary).child(format!("Item {n} of {of} in its sequence"))))
                .child(div().text_sm().text_color(theme.secondary).child(item.detail.clone()))
                .child(div().text_sm().child(format!("Last run: {}", item.status.label())))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .flex_wrap()
                        .gap_2()
                        .child(Self::button("run-now", "Run Now", false, theme))
                        .child(Self::button("pause-item", if paused { "Resume" } else { "Pause" }, paused, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            if let Some(i) = this.items.iter_mut().find(|i| i.id == id) {
                                i.paused = !i.paused;
                            }
                            cx.notify();
                        })))
                        .child(Self::button("edit-item", "Edit", false, theme))
                        .child(Self::button("delete-item", "Delete", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.items.retain(|i| i.id != id);
                            this.selected = None;
                            cx.notify();
                        }))),
                )
                .into_any_element(),
        )
    }
}

impl Render for SchedulePreview {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let side = self.side(&theme, cx);
        let body = match self.view {
            View::Week => self.week_view(&theme, cx).into_any_element(),
            View::Month => self.month_view(&theme, cx).into_any_element(),
        };
        div()
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
                    .when_some(side, |d, side| {
                        d.child(
                            div()
                                .id("schedule-side")
                                .w(px(320.))
                                .flex_none()
                                .h_full()
                                .overflow_y_scroll()
                                .p_4()
                                .border_l_1()
                                .border_color(theme.border)
                                .bg(theme.sidebar)
                                .child(side),
                        )
                    }),
            )
    }
}
