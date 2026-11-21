//! Add to Schedule, from the Issues list: a sheet to pick when a sequence
//! of issues starts, seeing what's already on. Days across the top; the day
//! picked as half hours, each showing what's scheduled then (review windows,
//! issue starts, other sequences, prompts); a click sets the start. The
//! interval between starts is set here too, and where each issue would land
//! shows on the grid and in the list beside it, before anything is saved.

use crate::charts::Theme;
use crate::schedule::{self, IssueRef, RunState, Schedule, Sequence};
use chrono::{Duration, Local, NaiveDate, Timelike};
use gpui::{div, prelude::*, px, ClickEvent, Context, EventEmitter, FontWeight, Hsla, KeyDownEvent, SharedString, Window};

const FIRST: u32 = 6 * 60;
const LAST: u32 = 24 * 60;

/// The sheet's done: the sequence saved, or cancelled.
pub struct SheetEvent;

impl EventEmitter<SheetEvent> for ScheduleSheet {}

pub struct ScheduleSheet {
    name: String,
    items: Vec<IssueRef>,
    schedule: Schedule,
    day: NaiveDate,
    start: Option<u32>,
    interval: u32,
    focus: gpui::FocusHandle,
}

fn clock(m: u32) -> String {
    format!("{}:{:02}", m / 60, m % 60)
}

impl ScheduleSheet {
    pub fn new(name: String, items: Vec<IssueRef>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let now = Local::now();
        let next = (now.hour() * 60 + now.minute()) / 30 * 30 + 30;
        let (day, start) = if next >= LAST { (now.date_naive().succ_opt().unwrap_or(now.date_naive()), FIRST + 3 * 60) } else { (now.date_naive(), next.max(FIRST)) };
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        Self { name, items, schedule: Schedule::load(), day, start: Some(start), interval: 120, focus }
    }

    /// When each item would start, as a local date and minute.
    fn planned(&self) -> Vec<(NaiveDate, u32)> {
        let Some(start) = self.start else { return Vec::new() };
        let first = schedule::at(self.day, start);
        (0..self.items.len())
            .map(|i| {
                let at = (first + Duration::minutes((i as u32 * self.interval) as i64)).with_timezone(&Local);
                (at.date_naive(), at.hour() * 60 + at.minute())
            })
            .collect()
    }

    fn save(&mut self, cx: &mut Context<Self>) {
        let Some(start) = self.start else { return };
        let mut sched = Schedule::load();
        sched.sequences.push(Sequence {
            id: schedule::new_id(),
            name: self.name.clone(),
            start: schedule::at(self.day, start),
            runs: vec![RunState::Waiting; self.items.len()],
            items: self.items.clone(),
            paused: false,
            interval: self.interval,
        });
        sched.save();
        cx.emit(SheetEvent);
    }

    fn chip(id: impl Into<SharedString>, label: impl Into<SharedString>, on: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
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

    fn tint(kind: &str, theme: &Theme) -> Hsla {
        match kind {
            "window" => theme.blue(),
            "start" => theme.good(),
            "sequence" => gpui::rgb(0xA259FF).into(),
            _ => theme.orange(),
        }
    }
}

impl Render for ScheduleSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let today = Local::now().date_naive();
        let busy = self.schedule.busy(self.day);
        let planned = self.planned();
        let new_tint: Hsla = gpui::rgb(0xA259FF).into();
        let days = div().flex().flex_row().flex_wrap().gap_1().children((0..7).map(|n| {
            let date = today + Duration::days(n);
            let label = match n {
                0 => "Today".to_string(),
                1 => "Tomorrow".to_string(),
                _ => date.format("%a %-d").to_string(),
            };
            let count = self.schedule.busy(date).iter().filter(|b| b.kind != "window").count();
            Self::chip(format!("day-{n}"), if count > 0 { format!("{label} · {count}") } else { label }, date == self.day, &theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.day = date;
                cx.notify();
            }))
        }));
        let interval = self.interval;
        let intervals = div()
            .flex()
            .flex_row()
            .items_center()
            .gap_1()
            .child(div().text_sm().text_color(theme.secondary).pr_1().child("Interval"))
            .child(Self::chip("int-less", "−", false, &theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.interval = this.interval.saturating_sub(5).max(5);
                cx.notify();
            })))
            .child(div().w(px(70.)).text_center().text_sm().child(format!("{interval} min")))
            .child(Self::chip("int-more", "+", false, &theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.interval = (this.interval + 5).min(24 * 60);
                cx.notify();
            })))
            .children([60u32, 90, 120, 180].map(|m| {
                Self::chip(format!("int-{m}"), format!("{}h{}", m / 60, if m % 60 == 0 { String::new() } else { format!("{:02}", m % 60) }), interval == m, &theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.interval = m;
                    cx.notify();
                }))
            }));
        // The day's half hours: what's on, and where the new ones land.
        let rows = (FIRST..LAST).step_by(30).map(|m| {
            let here: Vec<&schedule::Busy> = busy.iter().filter(|b| b.start < m + 30 && m < b.start + b.length.max(20)).collect();
            let windows: Vec<&&schedule::Busy> = here.iter().filter(|b| b.kind == "window").collect();
            let others: Vec<&&schedule::Busy> = here.iter().filter(|b| b.kind != "window" && b.start >= m && b.start < m + 30).collect();
            let landing: Vec<usize> = planned.iter().enumerate().filter(|(_, (d, pm))| *d == self.day && *pm >= m && *pm < m + 30).map(|(i, _)| i).collect();
            let picked = self.start == Some(m);
            let in_window = !windows.is_empty();
            let busy_now = here.iter().any(|b| b.kind != "window");
            div()
                .id(SharedString::from(format!("slot-{m}")))
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .h(px(26.))
                .px_2()
                .border_b_1()
                .border_color(theme.grid)
                .cursor_pointer()
                .when(in_window, |d| d.bg(theme.blue().opacity(0.07)))
                .when(picked, |d| d.bg(theme.selected.opacity(0.18)))
                .hover(|s| s.bg(theme.row_selected.opacity(0.5)))
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.start = Some(m);
                    cx.notify();
                }))
                .child(div().w(px(44.)).flex_none().text_xs().text_color(if m % 60 == 0 { theme.secondary } else { theme.tertiary }).child(clock(m)))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_row()
                        .gap_1()
                        .overflow_hidden()
                        .when(in_window && m == windows[0].start / 30 * 30, |d| {
                            d.child(div().flex_none().text_xs().text_color(theme.blue()).child(format!("{} (reviews)", windows[0].title)))
                        })
                        .children(others.iter().map(|b| {
                            let tint = Self::tint(b.kind, &theme);
                            div().flex_none().max_w(px(220.)).truncate().px_1p5().rounded_sm().text_xs().bg(tint.opacity(0.18)).text_color(tint).child(match b.place {
                                Some((n, of)) => format!("{n}/{of} {}", b.title),
                                None => b.title.clone(),
                            })
                        }))
                        .children(landing.iter().map(|i| {
                            div().flex_none().max_w(px(260.)).truncate().px_1p5().rounded_sm().text_xs().border_1().border_color(new_tint).text_color(new_tint).child(format!("{} {}", i + 1, self.items[*i].label()))
                        })),
                )
                .when(busy_now && landing.is_empty(), |d| d.child(div().flex_none().size(px(6.)).rounded_full().bg(theme.orange())))
        });
        let last = planned.last().copied();
        let list = div()
            .flex()
            .flex_col()
            .gap_1()
            .child(div().font_weight(FontWeight::SEMIBOLD).text_sm().child("In order"))
            .children(self.items.iter().enumerate().map(|(i, item)| {
                let when = planned.get(i).map(|(d, m)| if *d == self.day { clock(*m) } else { format!("{} {}", d.format("%a"), clock(*m)) }).unwrap_or_default();
                div()
                    .flex()
                    .flex_row()
                    .gap_2()
                    .text_sm()
                    .child(div().w(px(18.)).flex_none().text_color(new_tint).child(format!("{}", i + 1)))
                    .child(div().w(px(70.)).flex_none().text_color(theme.secondary).child(when))
                    .child(div().flex_1().min_w_0().truncate().child(item.label()))
            }))
            .when_some(last, |d, (date, m)| {
                d.child(div().pt_2().text_xs().text_color(theme.secondary).child(format!(
                    "The last is planned for {} at {}. Each starts once the one before is done and {} minutes have passed since it started.",
                    date.format("%a %-d %b"),
                    clock(m),
                    self.interval
                )))
            });
        div()
            .id("schedule-sheet")
            .track_focus(&self.focus)
            .occlude()
            .w(px(940.))
            .h(px(620.))
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
                    cx.emit(SheetEvent);
                }
            }))
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .p_3()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(format!("Schedule {}", self.name)))
                    .child(days)
                    .child(intervals),
            )
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_row()
                    .child(div().id("sheet-day").flex_1().min_w_0().h_full().overflow_y_scroll().children(rows))
                    .child(div().id("sheet-list").w(px(320.)).flex_none().h_full().overflow_y_scroll().p_3().border_l_1().border_color(theme.border).bg(theme.sidebar).child(list)),
            )
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
                    .child(div().flex_1().min_w_0().text_sm().text_color(theme.secondary).child(match self.start {
                        Some(m) => format!("Starts {} at {}", self.day.format("%a %-d %b"), clock(m)),
                        None => "Pick a time to start".into(),
                    }))
                    .child(Self::chip("sheet-cancel", "Cancel", false, &theme).on_click(cx.listener(|_, _: &ClickEvent, _, cx| cx.emit(SheetEvent))))
                    .child(Self::chip("sheet-save", format!("Schedule {}", if self.items.len() == 1 { "It".to_string() } else { format!("{}", self.items.len()) }), true, &theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.save(cx)))),
            )
    }
}
