//! Agents › Planning: the org's planning sessions on this Mac (or this
//! window's server), newest first, each with the stage it's on and whether
//! the room has agreed it. A row opens its session (claude resuming); New
//! starts one; Try the Preview opens the made-up plan, which calls nothing.
//! Read from the sessions kept on disk, again every few seconds.

use crate::charts::Theme;
use crate::launch::{Flow, Launch};
use crate::marra_view::button;
use crate::planning::{Agreed, Stage, State};
use gpui::{div, prelude::*, px, ClickEvent, Context, EventEmitter, FontWeight, SharedString, Task, Window};
use std::time::Duration;

pub enum PlanningAction {
    Open(Launch),
    New,
    Preview,
}

impl EventEmitter<PlanningAction> for PlanningPage {}

#[derive(Clone)]
struct Row {
    launch: Launch,
    title: String,
    stage: Option<Stage>,
    agreed: Option<String>,
    started_from: Option<String>,
}

pub struct PlanningPage {
    rows: Vec<Row>,
    loaded: bool,
    _poll: Task<()>,
}

/// The org's planning sessions run where `server` says, read from disk.
fn rows(org: Option<&str>, server: Option<&crate::servers::Server>) -> Vec<Row> {
    crate::launch::saved()
        .into_iter()
        .filter(|l| l.flow == Flow::Plan && org.is_none_or(|o| l.org.eq_ignore_ascii_case(o)) && l.server.as_ref() == server)
        .map(|launch| {
            let state = State::read(&launch.folder().join("planning.json"));
            let agreed = Agreed::load(&launch.dir());
            Row {
                title: state.as_ref().map(|s| s.title.clone()).filter(|t| !t.is_empty()).unwrap_or_else(|| launch.title.trim_start_matches("Plan: ").to_string()),
                stage: state.as_ref().map(State::stage),
                agreed: agreed.finished().then(|| agreed.plan_path.clone()),
                started_from: launch.subject.as_ref().map(|s| format!("{}#{}", s.repo, s.number)),
                launch,
            }
        })
        .collect()
}

impl PlanningPage {
    pub fn new(org: Option<String>, server: Option<crate::servers::Server>, cx: &mut Context<Self>) -> Self {
        let (o, s) = (org, server);
        let poll = cx.spawn(async move |this, cx| loop {
            let (o, s) = (o.clone(), s.clone());
            let found = cx.background_executor().spawn(async move { rows(o.as_deref(), s.as_ref()) }).await;
            if this
                .update(cx, |this, cx| {
                    this.rows = found;
                    this.loaded = true;
                    cx.notify();
                })
                .is_err()
            {
                return;
            }
            cx.background_executor().timer(Duration::from_secs(5)).await;
        });
        Self { rows: Vec::new(), loaded: false, _poll: poll }
    }
}

impl Render for PlanningPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let header = div()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .px_4()
            .py_3()
            .border_b_1()
            .border_color(theme.border)
            .child(
                div()
                    .flex_1()
                    .flex()
                    .flex_col()
                    .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child("Planning"))
                    .child(div().text_xs().text_color(theme.secondary).child("Where new initiatives, epics and issues start: the outcome, the requirement, the shape, the design and its security review, then the breakdown the room agrees.")),
            )
            .child(button("planning-preview", "Try the Preview", false, &theme).on_click(cx.listener(|_, _: &ClickEvent, _, cx| cx.emit(PlanningAction::Preview))))
            .child(button("planning-new", "New Initiative, Epic or Issue", true, &theme).on_click(cx.listener(|_, _: &ClickEvent, _, cx| cx.emit(PlanningAction::New))));
        let list = div().id("planning-sessions").flex_1().min_h_0().overflow_y_scroll().flex().flex_col().children(self.rows.iter().enumerate().map(|(i, row)| {
            let launch = row.launch.clone();
            let (status, tint) = match (&row.agreed, row.stage) {
                (Some(_), _) => ("Agreed".to_string(), theme.selected),
                (None, Some(Stage::Agree)) => ("Ready to agree".to_string(), theme.orange()),
                (None, Some(stage)) => (stage.title().to_string(), theme.secondary),
                (None, None) => ("Starting".to_string(), theme.tertiary),
            };
            let detail = [
                Some(row.launch.created_at.with_timezone(&chrono::Local).format("%-d %b %Y").to_string()),
                row.started_from.clone().map(|s| format!("from {s}")),
                row.agreed.clone(),
                Some(row.launch.harness_repo.clone()),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join("  ·  ");
            div()
                .id(SharedString::from(format!("planning-row-{i}")))
                .flex()
                .flex_row()
                .items_center()
                .gap_3()
                .px_4()
                .py_2()
                .border_b_1()
                .border_color(theme.border)
                .cursor_pointer()
                .hover(|d| d.bg(theme.tile))
                .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(PlanningAction::Open(launch.clone()))))
                .child(div().w(px(110.)).flex_none().text_xs().text_color(tint).child(status))
                .child(div().flex_1().min_w_0().flex().flex_col().child(div().truncate().child(row.title.clone())).child(div().text_xs().text_color(theme.secondary).truncate().child(detail)))
        }));
        let empty = (self.loaded && self.rows.is_empty()).then(|| {
            div().p_4().text_sm().text_color(theme.secondary).child("No planning sessions here yet. Start one with New Initiative, Epic or Issue, or Plan This on an issue.")
        });
        div().size_full().flex().flex_col().bg(theme.bg).text_color(theme.fg).child(header).children(empty).child(list)
    }
}
