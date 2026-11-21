//! Agents › Metrics, as Gannin's `AgentMetricsPage`: how Claude's reviews
//! land, from the records each review commits to the harness
//! (`.gannin/reviews/...`, read with git from the org's harnesses), so
//! it's the team's, not only this Mac's: who reviews with Gannin, how many
//! findings are posted and dismissed, and how many of those posted were
//! acted on (their threads resolved), by severity and category, and how
//! risky and how much work the reviews judged the PRs to be.

use crate::charts::Theme;
use chrono::{DateTime, Datelike, Duration, NaiveDate, Utc};
use gpui::{div, prelude::*, px, uniform_list, ClickEvent, Context, FontWeight, Hsla, SharedString, Window};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};

#[derive(Clone, Debug)]
struct Finding {
    severity: String,
    category: Option<String>,
    posted: bool,
    resolved: bool,
    dismissed: bool,
}

#[derive(Clone, Debug)]
struct Record {
    repo: String,
    number: i64,
    title: String,
    author: Option<String>,
    reviewer: String,
    verdict: Option<String>,
    effort: Option<i64>,
    /// low, medium or high, as the review graded it; none before reviews
    /// recorded it.
    merge_risk: Option<String>,
    state: Option<String>,
    started_at: DateTime<Utc>,
    posted_at: Option<DateTime<Utc>>,
    merged_at: Option<DateTime<Utc>>,
    updated_at: DateTime<Utc>,
    automatic: bool,
    findings: Vec<Finding>,
}

impl Record {
    fn date(&self) -> DateTime<Utc> {
        self.posted_at.unwrap_or(self.started_at)
    }
    fn posted(&self) -> impl Iterator<Item = &Finding> {
        self.findings.iter().filter(|f| f.posted)
    }
    fn accepted(&self) -> usize {
        self.findings.iter().filter(|f| f.posted && f.resolved).count()
    }
    fn dismissed(&self) -> usize {
        self.findings.iter().filter(|f| f.dismissed).count()
    }
}

/// Every review record in the org's harnesses, one per PR and reviewer
/// (the newest copy), read leniently.
fn load(org: &str) -> Vec<Record> {
    let time = |v: &Value| v.as_str().and_then(|t| t.parse::<DateTime<Utc>>().ok());
    let text = |v: &Value| v.as_str().filter(|s| !s.is_empty()).map(str::to_string);
    let mut records: HashMap<String, Record> = HashMap::new();
    for snapshot in crate::harness_git::snapshots(org) {
        for (path, body) in snapshot.under(".gannin/reviews/") {
            if !path.ends_with(".json") {
                continue;
            }
            let Some(r) = serde_json::from_str::<Value>(body).ok() else { continue };
            let (Some(repo), Some(number), Some(reviewer), Some(started_at)) = (text(&r["repo"]), r["number"].as_i64(), text(&r["reviewer"]), time(&r["started_at"])) else { continue };
            let record = Record {
                title: text(&r["title"]).unwrap_or_default(),
                author: text(&r["author"]),
                verdict: text(&r["verdict"]),
                effort: r["effort"].as_i64(),
                merge_risk: text(&r["merge_risk"]),
                state: text(&r["state"]),
                posted_at: time(&r["posted_at"]),
                merged_at: time(&r["merged_at"]),
                updated_at: time(&r["updated_at"]).unwrap_or(started_at),
                automatic: r["posted_automatically"] == true,
                findings: r["findings"]
                    .as_array()
                    .map(|a| {
                        a.iter()
                            .map(|f| Finding {
                                severity: text(&f["severity"]).unwrap_or_else(|| "minor".into()),
                                category: text(&f["category"]),
                                posted: f["posted_at"].is_string(),
                                resolved: f["resolved_at"].is_string(),
                                dismissed: f["decision"] == "dismissed",
                            })
                            .collect()
                    })
                    .unwrap_or_default(),
                repo,
                number,
                reviewer,
                started_at,
            };
            let id = format!("{}#{}-{}", record.repo, record.number, record.reviewer.to_lowercase());
            if records.get(&id).is_none_or(|old| old.updated_at < record.updated_at) {
                records.insert(id, record);
            }
        }
    }
    let mut all: Vec<Record> = records.into_values().collect();
    all.sort_by(|a, b| b.date().cmp(&a.date()));
    all
}

pub struct AgentMetricsPage {
    org: Option<String>,
    records: Option<Vec<Record>>,
    /// Days back, or 0 for all time.
    days: i64,
    /// One reviewer's, or everyone's.
    reviewer: Option<String>,
    /// The Reviews list, a view of its own, rather than the overview.
    listing: bool,
}

impl AgentMetricsPage {
    /// The records in the range, for the reviewer picked, newest first.
    fn shown(&self) -> Vec<&Record> {
        let since = (self.days > 0).then(|| Utc::now() - Duration::days(self.days));
        self.records
            .iter()
            .flatten()
            .filter(|r| since.is_none_or(|s| r.date() >= s) && self.reviewer.as_ref().is_none_or(|who| r.reviewer.eq_ignore_ascii_case(who)))
            .collect()
    }

    /// One review in the Reviews list; a click opens its PR.
    fn review_row(i: usize, r: &Record, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        let cell = |text: String, w: f32| div().w(px(w)).flex_none().truncate().child(text);
        let url = format!("https://github.com/{}/pull/{}", r.repo, r.number);
        div()
            .id(("review-row", i))
            .flex()
            .flex_row()
            .items_center()
            .gap_3()
            .px_2()
            .py_1()
            .text_sm()
            .cursor_pointer()
            .hover(|s| s.bg(theme.row_selected))
            .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(div().truncate().child(r.title.clone()))
                    .child(div().truncate().text_xs().text_color(theme.secondary).child(format!("{}#{}{}", r.repo, r.number, r.author.as_ref().map(|a| format!(" by @{a}")).unwrap_or_default()))),
            )
            .child(cell(format!("@{}", r.reviewer), 120.))
            .child(cell(verdict(r.verdict.as_deref()).into(), 120.).text_color(theme.secondary))
            .child(cell(r.merge_risk.as_deref().map(capitalised).unwrap_or_default(), 70.).text_color(r.merge_risk.as_deref().map_or(theme.secondary, |l| risk_tint(l, theme))))
            .child(cell(r.effort.map(|e| e.to_string()).unwrap_or_default(), 50.))
            .child(cell(if r.posted_at.is_none() { "Not yet".into() } else { format!("{} of {}", r.posted().count(), r.findings.len()) }, 70.))
            .child(cell(if r.posted().count() == 0 { String::new() } else { r.accepted().to_string() }, 70.))
            .child(cell(r.state.as_deref().map(capitalised).unwrap_or_default(), 70.).text_color(theme.secondary))
            .child(cell(ago(r.date()), 80.).text_color(theme.secondary))
            .into_any_element()
    }
    pub fn new(org: Option<String>, cx: &mut Context<Self>) -> Self {
        let mut page = Self { org, records: None, days: 30, reviewer: None, listing: false };
        page.reload(cx);
        page
    }

    pub fn set_org(&mut self, org: Option<String>, cx: &mut Context<Self>) {
        self.org = org;
        self.reviewer = None;
        self.reload(cx);
    }

    pub fn reload(&mut self, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        cx.spawn(async move |this, cx| {
            let records = cx.background_executor().spawn(async move { load(&org) }).await;
            this.update(cx, |this, cx| {
                this.records = Some(records);
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn percent(part: usize, whole: usize) -> String {
        if whole == 0 {
            "None".into()
        } else {
            format!("{}%", ((part as f64 / whole as f64) * 100.).round() as i64)
        }
    }

    fn chip(id: impl Into<SharedString>, label: String, on: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(gpui::ElementId::Name(id.into()))
            .px_2()
            .py_0p5()
            .rounded_md()
            .text_sm()
            .cursor_pointer()
            .text_color(if on { theme.fg } else { theme.secondary })
            .when(on, |d| d.bg(theme.row_selected))
            .hover(|s| s.bg(theme.row_selected))
            .child(label)
    }

    fn tile(title: &str, value: String, detail: String, theme: &Theme) -> impl IntoElement {
        div()
            .w(px(190.))
            .flex()
            .flex_col()
            .gap_1()
            .p_3()
            .rounded_lg()
            .bg(theme.tile)
            .child(div().text_sm().text_color(theme.secondary).child(title.to_string()))
            .child(div().text_2xl().font_weight(FontWeight::SEMIBOLD).child(value))
            .when(!detail.is_empty(), |d| d.child(div().text_xs().text_color(theme.secondary).child(detail)))
    }

    fn card(title: &str, help: &str, theme: &Theme) -> gpui::Div {
        div()
            .flex_1()
            .min_w_0()
            .flex()
            .flex_col()
            .gap_2()
            .p_3p5()
            .rounded_lg()
            .bg(theme.tile)
            .child(div().font_weight(FontWeight::SEMIBOLD).child(title.to_string()))
            .child(div().text_xs().text_color(theme.secondary).child(help.to_string()))
    }

    /// A rounded top for the axis and its step: 1, 2 or 5 times a power of
    /// ten, about four steps up.
    fn scale(max: usize) -> (usize, usize) {
        let max = max.max(1);
        let mut step = 1;
        loop {
            for m in [1, 2, 5] {
                if max.div_ceil(step * m) <= 4 {
                    let step = step * m;
                    return (max.div_ceil(step) * step, step);
                }
            }
            step *= 10;
        }
    }

    const AXIS: f32 = 40.;

    /// A plot `height` high: the y axis's labels down the left, gridlines
    /// at each step, and `bars` (a row aligned to the bottom) over them.
    fn plot(height: f32, top: usize, step: usize, bars: gpui::Div, theme: &Theme) -> impl IntoElement {
        let ticks: Vec<usize> = (0..=top).step_by(step.max(1)).collect();
        let at = |t: usize| t as f32 / top.max(1) as f32 * height;
        div()
            .flex()
            .flex_row()
            .child(div().relative().w(px(Self::AXIS)).h(px(height)).flex_none().children(ticks.iter().map(|&t| {
                div().absolute().right(px(8.)).bottom(px(at(t) - 7.)).text_xs().text_color(theme.tertiary).child(t.to_string())
            })))
            .child(
                div()
                    .relative()
                    .flex_1()
                    .min_w_0()
                    .h(px(height))
                    .border_b_1()
                    .border_color(theme.border)
                    .children(ticks.iter().filter(|&&t| t > 0).map(|&t| div().absolute().left_0().right_0().bottom(px(at(t))).h(px(1.)).bg(theme.border).opacity(0.5)))
                    .child(bars.absolute().inset_0().flex().flex_row().items_end()),
            )
    }

    /// A bar's height for `n` on an axis up to `top`: at least a sliver
    /// when it's not nothing, so a small count still shows.
    fn bar_height(n: usize, top: usize, height: f32) -> f32 {
        if n == 0 {
            0.
        } else {
            (n as f32 / top.max(1) as f32 * height).max(2.)
        }
    }

    /// Posted against acted on, a pair of bars a group with their counts,
    /// and each group's acted-on rate beneath.
    fn pairs(groups: Vec<(String, usize, usize)>, theme: &Theme) -> impl IntoElement {
        let (top, step) = Self::scale(groups.iter().map(|g| g.1).max().unwrap_or(0));
        let height = 180.;
        let (posted, acted) = (theme.orange(), theme.blue());
        let legend = |label: &str, tint: Hsla| div().flex().flex_row().items_center().gap_1().text_xs().text_color(theme.secondary).child(div().size(px(8.)).rounded_sm().bg(tint)).child(label.to_string());
        let bar = |n: usize, tint: Hsla| {
            div()
                .flex()
                .flex_col()
                .items_center()
                .gap_0p5()
                .child(div().text_xs().text_color(theme.secondary).child(if n > 0 { n.to_string() } else { String::new() }))
                .child(div().w(px(26.)).h(px(Self::bar_height(n, top, height))).rounded_t(px(3.)).bg(tint))
        };
        div()
            .flex()
            .flex_col()
            .gap_2()
            .child(div().flex().flex_row().gap_3().child(legend("Posted", posted)).child(legend("Acted on", acted)))
            .child(Self::plot(
                height,
                top,
                step,
                div().children(groups.iter().map(|(_, p, a)| div().flex_1().flex().flex_row().items_end().justify_center().gap(px(4.)).child(bar(*p, posted)).child(bar(*a, acted)))),
                theme,
            ))
            .child(div().flex().flex_row().pl(px(Self::AXIS)).children(groups.iter().map(|(name, p, a)| {
                div()
                    .flex_1()
                    .flex()
                    .flex_col()
                    .items_center()
                    .child(div().text_xs().text_color(theme.secondary).child(name.clone()))
                    .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).child(if *p > 0 { format!("{} acted on", Self::percent(*a, *p)) } else { "None".into() }))
            })))
    }

    /// How many reviews fell in each group: a bar a group in its colour,
    /// its count above and its share of them all beneath.
    fn counts(groups: Vec<(String, usize, Hsla)>, theme: &Theme) -> impl IntoElement {
        let total: usize = groups.iter().map(|g| g.1).sum();
        let (top, step) = Self::scale(groups.iter().map(|g| g.1).max().unwrap_or(0));
        let height = 150.;
        div()
            .flex()
            .flex_col()
            .gap_2()
            .child(Self::plot(
                height,
                top,
                step,
                div().children(groups.iter().map(|(_, n, tint)| {
                    div()
                        .flex_1()
                        .flex()
                        .flex_col()
                        .items_center()
                        .justify_end()
                        .gap_0p5()
                        .child(div().text_xs().text_color(theme.secondary).child(if *n > 0 { n.to_string() } else { String::new() }))
                        .child(div().w(px(34.)).h(px(Self::bar_height(*n, top, height))).rounded_t(px(3.)).bg(*tint))
                })),
                theme,
            ))
            .child(div().flex().flex_row().pl(px(Self::AXIS)).children(groups.iter().map(|(name, n, _)| {
                div()
                    .flex_1()
                    .flex()
                    .flex_col()
                    .items_center()
                    .child(div().text_xs().text_color(theme.secondary).child(name.clone()))
                    .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).child(Self::percent(*n, total)))
            })))
    }

    /// Reviews a week, stacked by who ran them: every week in the range,
    /// empty ones too, each with its total and its date.
    fn weekly(records: &[&Record], reviewers: &[String], since: Option<DateTime<Utc>>, theme: &Theme) -> impl IntoElement {
        let week = |d: DateTime<Utc>| {
            let day = d.date_naive();
            day - Duration::days(day.weekday().num_days_from_monday() as i64)
        };
        let mut weeks: BTreeMap<NaiveDate, HashMap<String, usize>> = BTreeMap::new();
        for r in records {
            *weeks.entry(week(r.date())).or_default().entry(r.reviewer.to_lowercase()).or_default() += 1;
        }
        // The weeks with none, from the range's start (or the first review)
        // to this one.
        if let Some(first) = since.map(week).or_else(|| weeks.keys().next().copied()) {
            let mut day = first;
            while day <= week(Utc::now()) {
                weeks.entry(day).or_default();
                day += Duration::days(7);
            }
        }
        let totals: Vec<usize> = weeks.values().map(|m| m.values().sum()).collect();
        let (top, step) = Self::scale(totals.iter().copied().max().unwrap_or(0));
        let height = 180.;
        let tint = |login: &str| theme.slot(reviewers.iter().position(|r| r == login).unwrap_or(0));
        // A date under every week, or every few when there are many.
        let every = weeks.len().div_ceil(12).max(1);
        div()
            .flex()
            .flex_col()
            .gap_2()
            .child(div().flex().flex_row().flex_wrap().gap_3().children(reviewers.iter().map(|login| {
                div().flex().flex_row().items_center().gap_1().text_xs().text_color(theme.secondary).child(div().size(px(8.)).rounded_sm().bg(tint(login))).child(format!("@{login}"))
            })))
            .child(Self::plot(
                height,
                top,
                step,
                div().gap_1().children(weeks.values().zip(&totals).map(|(by, &total)| {
                    let mut by: Vec<(&String, &usize)> = by.iter().collect();
                    by.sort();
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .items_center()
                        .gap_0p5()
                        .child(div().text_xs().text_color(theme.secondary).child(if total > 0 { total.to_string() } else { String::new() }))
                        .child(
                            div()
                                .w_full()
                                .max_w(px(56.))
                                .flex()
                                .flex_col()
                                .justify_end()
                                .rounded_t(px(3.))
                                .overflow_hidden()
                                .children(by.into_iter().map(|(login, n)| div().w_full().h(px(*n as f32 / top.max(1) as f32 * height)).bg(tint(login)))),
                        )
                })),
                theme,
            ))
            .child(div().flex().flex_row().gap_1().pl(px(Self::AXIS)).children(weeks.keys().enumerate().map(|(i, d)| {
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .justify_center()
                    .text_xs()
                    .text_color(theme.tertiary)
                    .child(if i % every == 0 { d.format("%-d %b").to_string() } else { String::new() })
            })))
    }
}

/// A merge risk's colour, as the review page's.
fn risk_tint(level: &str, theme: &Theme) -> Hsla {
    match level {
        "low" => theme.good(),
        "medium" => theme.orange(),
        "high" => theme.critical(),
        _ => theme.secondary,
    }
}

fn capitalised(text: &str) -> String {
    let lower = text.to_lowercase();
    let mut chars = lower.chars();
    chars.next().map(|c| c.to_uppercase().collect::<String>() + chars.as_str()).unwrap_or_default()
}

fn verdict(v: Option<&str>) -> &'static str {
    match v {
        Some("approve") => "Approve",
        Some("request_changes") => "Request changes",
        Some("comment") => "Comment",
        _ => "",
    }
}

fn ago(at: DateTime<Utc>) -> String {
    let d = Utc::now() - at;
    if d.num_days() >= 1 {
        format!("{}d ago", d.num_days())
    } else if d.num_hours() >= 1 {
        format!("{}h ago", d.num_hours())
    } else {
        format!("{}m ago", d.num_minutes().max(0))
    }
}

impl Render for AgentMetricsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let Some(all) = self.records.clone() else {
            return div().size_full().p_4().bg(theme.bg).text_color(theme.secondary).child("Reading the review records").into_any_element();
        };
        let records: Vec<Record> = self.shown().into_iter().cloned().collect();
        let records: Vec<&Record> = records.iter().collect();
        let mut reviewers: Vec<String> = all.iter().map(|r| r.reviewer.to_lowercase()).collect();
        reviewers.sort();
        reviewers.dedup();

        // The bar: range, then who.
        let ranges = [(7, "Last 7 days"), (30, "Last 30 days"), (90, "Last 90 days"), (0, "All time")].map(|(days, label)| {
            Self::chip(format!("range-{days}"), label.into(), self.days == days, &theme)
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.days = days;
                    cx.notify();
                }))
                .into_any_element()
        });
        let mut who = vec![Self::chip("who-all", "Everyone".into(), self.reviewer.is_none(), &theme)
            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.reviewer = None;
                cx.notify();
            }))
            .into_any_element()];
        for login in &reviewers {
            let on = self.reviewer.as_deref() == Some(login.as_str());
            let picked = login.clone();
            who.push(
                Self::chip(format!("who-{login}"), format!("@{login}"), on, &theme)
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.reviewer = if on { None } else { Some(picked.clone()) };
                        cx.notify();
                    }))
                    .into_any_element(),
            );
        }
        let listing = self.listing;
        let bar = div()
            .flex()
            .flex_row()
            .flex_wrap()
            .items_center()
            .gap_1()
            .px_4()
            .py_2()
            .border_b_1()
            .border_color(theme.border)
            .when(listing, |d| {
                d.child(Self::chip("back", "‹ Overview".into(), false, &theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                    this.listing = false;
                    cx.notify();
                })))
                .child(div().px_1().font_weight(FontWeight::SEMIBOLD).child("Reviews"))
                .child(div().w(px(12.)))
            })
            .children(ranges)
            .child(div().w(px(12.)))
            .children(who);

        if records.is_empty() {
            let text = if all.is_empty() {
                "No reviews yet. Review a PR with Claude and post it: each review is recorded in the project's harness, so everyone's show here."
            } else {
                "Nothing in this range. Try a longer one."
            };
            return div().size_full().flex().flex_col().bg(theme.bg).text_color(theme.fg).child(bar).child(div().p_6().text_color(theme.secondary).child(text)).into_any_element();
        }

        // Tiles.
        let posted: usize = records.iter().map(|r| r.posted().count()).sum();
        let accepted: usize = records.iter().map(|r| r.accepted()).sum();
        let decided: usize = records.iter().map(|r| r.findings.len()).sum();
        let dismissed: usize = records.iter().map(|r| r.dismissed()).sum();
        let was_posted = records.iter().filter(|r| r.posted_at.is_some()).count();
        let automatic = records.iter().filter(|r| r.automatic).count();
        let mut who_ran: Vec<String> = records.iter().map(|r| r.reviewer.to_lowercase()).collect();
        who_ran.sort();
        who_ran.dedup();
        let mut efforts: Vec<i64> = records.iter().filter_map(|r| r.effort).collect();
        efforts.sort();
        let mut to_merge: Vec<i64> = records.iter().filter_map(|r| Some((r.merged_at? - r.posted_at?).num_minutes()).filter(|m| *m > 0)).collect();
        to_merge.sort();
        let duration = |minutes: i64| if minutes >= 1440 { format!("{}d {}h", minutes / 1440, minutes % 1440 / 60) } else if minutes >= 60 { format!("{}h {}m", minutes / 60, minutes % 60) } else { format!("{minutes}m") };
        let mut tiles = vec![
            Self::tile("Reviews", records.len().to_string(), format!("{was_posted} posted{}", if automatic > 0 { format!(", {automatic} by themselves") } else { String::new() }), &theme).into_any_element(),
            Self::tile(
                "Reviewers",
                who_ran.len().to_string(),
                format!("{}{}", who_ran.iter().take(3).map(|l| format!("@{l}")).collect::<Vec<_>>().join(", "), if who_ran.len() > 3 { " and more" } else { "" }),
                &theme,
            )
            .into_any_element(),
            Self::tile("Findings posted", posted.to_string(), if was_posted > 0 { format!("{:.1} a review posted", posted as f64 / was_posted as f64) } else { String::new() }, &theme).into_any_element(),
            Self::tile("Acted on", Self::percent(accepted, posted), format!("{accepted} of {posted} threads resolved"), &theme).into_any_element(),
            Self::tile("Dismissed before posting", Self::percent(dismissed, decided), format!("{dismissed} of {decided} findings"), &theme).into_any_element(),
        ];
        if !efforts.is_empty() {
            tiles.push(Self::tile("Review effort", format!("{} of 5", efforts[efforts.len() / 2]), "Median, as the reviewer judged".into(), &theme).into_any_element());
        }
        let graded: Vec<&str> = records.iter().filter_map(|r| r.merge_risk.as_deref()).collect();
        let high = graded.iter().filter(|l| **l == "high").count();
        if !graded.is_empty() {
            tiles.push(Self::tile("High merge risk", Self::percent(high, graded.len()), format!("{high} of {} graded", graded.len()), &theme).into_any_element());
        }

        // Merge risk and effort, as the reviews judged them.
        let ungraded = records.len() - graded.len();
        let risk: Vec<(String, usize, Hsla)> = ["low", "medium", "high"].iter().map(|l| (capitalised(l), graded.iter().filter(|g| **g == *l).count(), risk_tint(l, &theme))).collect();
        let effort: Vec<(String, usize, Hsla)> = (1..=5).map(|e| (e.to_string(), efforts.iter().filter(|x| **x == e).count(), theme.blue().opacity(0.4 + 0.12 * e as f32))).collect();
        let risk_help = if ungraded > 0 {
            format!("How risky merging each PR was graded; {ungraded} {} from before reviews recorded it", if ungraded == 1 { "isn't graded, being" } else { "aren't graded, being" })
        } else {
            "How risky merging each PR was graded".to_string()
        };
        if !to_merge.is_empty() {
            tiles.push(Self::tile("Posted to merge", duration(to_merge[to_merge.len() / 2]), format!("Median, {} merged", to_merge.len()), &theme).into_any_element());
        }

        // By severity and by category.
        let findings: Vec<&Finding> = records.iter().flat_map(|r| r.posted()).collect();
        let tally = |pick: &dyn Fn(&Finding) -> bool| {
            let p: Vec<&&Finding> = findings.iter().filter(|f| pick(f)).collect();
            (p.len(), p.iter().filter(|f| f.resolved).count())
        };
        let severity: Vec<(String, usize, usize)> = ["blocker", "major", "minor", "nit"]
            .iter()
            .map(|s| {
                let (p, a) = tally(&|f: &Finding| f.severity == *s || (*s == "minor" && !["blocker", "major", "nit"].contains(&f.severity.as_str())));
                (capitalised(s), p, a)
            })
            .collect();
        let categories = ["correctness", "data", "stability", "security", "performance", "maintainability"];
        let mut category: Vec<(String, usize, usize)> = categories
            .iter()
            .map(|c| {
                let (p, a) = tally(&|f: &Finding| f.category.as_deref() == Some(*c));
                (capitalised(c), p, a)
            })
            .collect();
        let (p, a) = tally(&|f: &Finding| !f.category.as_deref().is_some_and(|c| categories.contains(&c)));
        category.push(("Other".into(), p, a));
        category.retain(|g| g.1 > 0);

        // Reviewers.
        let mut by_reviewer: Vec<(String, Vec<&Record>)> = who_ran.iter().map(|l| (l.clone(), records.iter().copied().filter(|r| r.reviewer.eq_ignore_ascii_case(l)).collect())).collect();
        by_reviewer.sort_by(|a, b| b.1.len().cmp(&a.1.len()));
        let header = |cells: Vec<(&str, f32)>| {
            div().flex().flex_row().gap_3().px_2().py_1().text_xs().font_weight(FontWeight::MEDIUM).text_color(theme.secondary).border_b_1().border_color(theme.border).children(cells.into_iter().map(|(label, w)| {
                if w == 0. { div().flex_1().min_w_0().child(label.to_string()) } else { div().w(px(w)).flex_none().child(label.to_string()) }
            }))
        };
        let cell = |text: String, w: f32| div().w(px(w)).flex_none().truncate().child(text);
        let reviewer_rows = by_reviewer.iter().map(|(login, mine)| {
            let posted: usize = mine.iter().map(|r| r.posted().count()).sum();
            let picked = login.clone();
            div()
                .id(SharedString::from(format!("reviewer-{login}")))
                .flex()
                .flex_row()
                .gap_3()
                .px_2()
                .py_1()
                .text_sm()
                .cursor_pointer()
                .hover(|s| s.bg(theme.row_selected))
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.reviewer = if this.reviewer.as_deref() == Some(picked.as_str()) { None } else { Some(picked.clone()) };
                    cx.notify();
                }))
                .child(div().flex_1().min_w_0().font_weight(FontWeight::MEDIUM).child(format!("@{login}")))
                .child(cell(mine.len().to_string(), 70.))
                .child(cell(mine.iter().filter(|r| r.automatic).count().to_string(), 100.))
                .child(cell(posted.to_string(), 70.))
                .child(cell(mine.iter().map(|r| r.dismissed()).sum::<usize>().to_string(), 80.))
                .child(cell(Self::percent(mine.iter().map(|r| r.accepted()).sum(), posted), 80.))
                .child(cell(mine.iter().map(|r| r.date()).max().map(ago).unwrap_or_default(), 90.).text_color(theme.secondary))
        });

        let reviewer_rows: Vec<gpui::AnyElement> = reviewer_rows.map(|r| r.into_any_element()).collect();

        if listing {
            return div()
                .size_full()
                .flex()
                .flex_col()
                .bg(theme.bg)
                .text_color(theme.fg)
                .child(bar)
                .child(
                    // Every review in the range, drawn only as it scrolls
                    // into view, so the whole history shows.
                    div()
                        .flex_1()
                        .min_h_0()
                        .p_5()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .child(div().text_xs().text_color(theme.secondary).child(format!("All {} reviews in the range, newest first. Click one to open its PR.", records.len())))
                        .child(header(vec![("Pull request", 0.), ("Reviewer", 120.), ("Verdict", 120.), ("Risk", 70.), ("Effort", 50.), ("Posted", 70.), ("Acted on", 70.), ("PR", 70.), ("When", 80.)]))
                        .child(
                            uniform_list(
                                "agent-reviews",
                                records.len(),
                                cx.processor(|page, range: std::ops::Range<usize>, window, cx| {
                                    let theme = Theme::for_window(window);
                                    let shown = page.shown();
                                    range.filter_map(|i| shown.get(i).map(|r| Self::review_row(i, r, &theme, cx))).collect::<Vec<_>>()
                                }),
                            )
                            .flex_1()
                            .min_h_0(),
                        )
                        .child(div().pt_2().text_xs().text_color(theme.secondary).child("\"Acted on\" is a posted finding whose GitHub thread was resolved (fixed, or answered), as last looked at: when the review was posted again, finished, or its PR merged or closed while watched.")),
                )
                .into_any_element();
        }
        let count = records.len();
        let section = |title: &str, help: &str| div().flex().flex_col().child(div().font_weight(FontWeight::SEMIBOLD).child(title.to_string())).child(div().text_xs().text_color(theme.secondary).child(help.to_string()));

        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .text_color(theme.fg)
            .child(bar)
            .child(
                div().id("agent-metrics").flex_1().min_h_0().overflow_y_scroll().child(
                    div()
                        .p_5()
                        .flex()
                        .flex_col()
                        .gap_6()
                        .child(div().flex().flex_row().flex_wrap().gap_3().children(tiles))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .gap_4()
                                .child(Self::card("By severity", "Findings posted, and those whose threads were resolved", &theme).child(Self::pairs(severity, &theme)))
                                .child(Self::card("By category", "The same by category; reviews before categories count as Other", &theme).child(Self::pairs(category, &theme))),
                        )
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .gap_4()
                                .child(Self::card("Merge risk", &risk_help, &theme).child(Self::counts(risk, &theme)))
                                .child(Self::card("Review effort", "How much work reviewing each PR by hand was judged, 1 a glance to 5 hours", &theme).child(Self::counts(effort, &theme))),
                        )
                        .child(Self::card("Reviews a week", "By who ran them", &theme).child(Self::weekly(&records, &reviewers, (self.days > 0).then(|| Utc::now() - Duration::days(self.days)), &theme)))
                        .child(
                            div()
                                .flex()
                                .flex_col()
                                .gap_2()
                                .child(section("Reviewers", "Who reviews with Gannin, and how their reviews land. Click one to see only theirs."))
                                .child(header(vec![("Reviewer", 0.), ("Reviews", 70.), ("By themselves", 100.), ("Posted", 70.), ("Dismissed", 80.), ("Acted on", 80.), ("Last review", 90.)]))
                                .children(reviewer_rows),
                        )
                        // Every review is a view of its own.
                        .child(
                            div()
                                .id("see-reviews")
                                .text_sm()
                                .text_color(theme.selected)
                                .cursor_pointer()
                                .hover(|s| s.opacity(0.8))
                                .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                    this.listing = true;
                                    cx.notify();
                                }))
                                .child(format!("See all {count} review{} ›", if count == 1 { "" } else { "s" })),
                        ),
                ),
            )
            .into_any_element()
    }
}
