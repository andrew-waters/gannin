//! Scorecards, after Gannin's `ScorecardView`: the org's goals (from its
//! settings), each a delivery metric or a number entered by hand, with a
//! target, measured in a column per period, newest first, the period under
//! way shaded. Tiles above show each goal's last whole period against the
//! one before.
//!
//! Metrics follow Gannin's definitions (`Scorecard.Data.measure`): medians
//! (interpolated) or shares or counts over merged PRs bucketed by when they
//! merged, leaving out bots, excluded authors and repos. Periods before the
//! metrics history Gannin has show "-". The metrics and the goals are read
//! from Gannin's own files, read only: the pilot doesn't sync them.
//!
//! Not here yet: per-person breakdowns, the issue and CI metrics, Team and
//! Owner filters, and adding or editing goals (Gannin keeps them in its
//! settings, which the pilot never writes).

use crate::charts::{spark_bars, Theme};
use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, TimeZone, Utc};
use gpui::{div, prelude::*, px, ClickEvent, Context, FontWeight, Hsla, SharedString, Window};
use serde_json::Value;
use std::collections::{BTreeMap, HashSet};

// MARK: - Data

#[derive(Clone)]
struct MergedPr {
    repo: String,
    created: DateTime<Utc>,
    merged: DateTime<Utc>,
    first_commit: Option<DateTime<Utc>>,
    ready: Option<DateTime<Utc>>,
    /// (login, state, submitted), oldest first.
    reviews: Vec<(String, String, DateTime<Utc>)>,
    /// (login, requested, removed).
    requests: Vec<(String, DateTime<Utc>, Option<DateTime<Utc>>)>,
    size: i64,
    files: Option<i64>,
}

#[derive(Clone)]
struct OpenPr {
    created: DateTime<Utc>,
    requested: Vec<DateTime<Utc>>,
}

#[derive(Clone, PartialEq)]
struct Goal {
    name: String,
    cadence: Resolution,
    metric: Option<String>,
    unit: String,
    at_least: bool,
    target: Option<f64>,
    values: BTreeMap<String, f64>,
    notes: Option<String>,
}

#[derive(Clone, Default)]
pub struct Data {
    merged: Vec<MergedPr>,
    open: Vec<OpenPr>,
    covered_from: Option<DateTime<Utc>>,
    goals: Vec<Goal>,
    without_review: HashSet<String>,
}

fn date(v: &Value) -> Option<DateTime<Utc>> {
    v.as_str()?.parse().ok()
}

/// Gannin's `config.excludes`: listed authors, and bots unless included.
fn excluded(login: &str, config: &Value) -> bool {
    let listed = |key: &str| config[key].as_array().is_some_and(|a| a.iter().any(|v| v.as_str() == Some(login)));
    let lower = login.to_lowercase();
    listed("excludedAuthors") || ((lower.ends_with("-bot") || lower.ends_with("[bot]")) && !listed("includedAuthors"))
}

/// Reads Gannin's PR cache, metrics coverage and the org's goals. Large:
/// call off the main thread.
pub fn load(org: &str) -> Data {
    let config = crate::projects::config_json(org);
    let excluded_repos: HashSet<String> = config["excludedRepos"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default();
    let without_review = config["reposWithoutReview"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default();
    let goals = config["scorecard"]
        .as_array()
        .map(|goals| {
            goals
                .iter()
                .filter_map(|g| {
                    Some(Goal {
                        name: g["name"].as_str()?.to_string(),
                        cadence: Resolution::from_cadence(g["cadence"].as_str()?)?,
                        metric: g["metric"].as_str().map(str::to_string),
                        unit: g["unit"].as_str().unwrap_or("number").to_string(),
                        at_least: g["comparison"].as_str() != Some("atMost"),
                        target: g["target"].as_f64(),
                        values: g["values"].as_object().map(|m| m.iter().filter_map(|(k, v)| Some((k.clone(), v.as_f64()?))).collect()).unwrap_or_default(),
                        notes: g["notes"].as_str().map(str::to_string),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let support = std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_default().join("Library/Application Support");
    let covered_from = std::fs::read(support.join("Metrics").join(format!("{}.json", org.replace('%', "%25").replace(' ', "%20"))))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|m| date(&m["coveredFrom"]));
    let store: Value = std::fs::read(crate::cache::gannin_path(crate::cache::Kind::PullRequests, org))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or(Value::Null);
    let mut merged = Vec::new();
    let mut open = Vec::new();
    for pr in store["pullRequests"].as_object().into_iter().flat_map(|m| m.values()) {
        let core = &pr["core"];
        let author = core["author"]["login"].as_str().unwrap_or("").to_string();
        let repo = core["repo"].as_str().unwrap_or("").to_string();
        if excluded_repos.contains(&repo) || excluded(&author, &config) {
            continue;
        }
        if pr["workload"]["state"] == "OPEN" {
            if let Some(created) = date(&core["createdAt"]) {
                let requested = pr["workload"]["reviewRequestedAt"]
                    .as_object()
                    .map(|m| {
                        m.iter()
                            .filter(|(login, _)| pr["workload"]["requestedReviewers"].as_array().is_some_and(|r| r.iter().any(|p| p["login"].as_str() == Some(login.as_str()))))
                            .filter(|(login, _)| !excluded(login, &config))
                            .filter_map(|(_, at)| date(at))
                            .collect()
                    })
                    .unwrap_or_default();
                open.push(OpenPr { created, requested });
            }
        }
        let metrics = &pr["metrics"];
        let (Some(merged_at), Some(created)) = (date(&core["mergedAt"]), date(&core["createdAt"])) else { continue };
        if metrics.is_null() || core["authorIsBot"] == true {
            continue;
        }
        let mut reviews: Vec<(String, String, DateTime<Utc>)> = metrics["reviews"]
            .as_array()
            .map(|a| a.iter().filter_map(|r| Some((r["login"].as_str()?.to_string(), r["state"].as_str()?.to_string(), date(&r["submittedAt"])?))).filter(|(l, _, _)| !excluded(l, &config)).collect())
            .unwrap_or_default();
        reviews.sort_by_key(|r| r.2);
        let requests = metrics["reviewRequests"]
            .as_array()
            .map(|a| a.iter().filter_map(|r| Some((r["login"].as_str()?.to_string(), date(&r["requestedAt"])?, date(&r["removedAt"])))).filter(|(l, _, _)| !excluded(l, &config)).collect())
            .unwrap_or_default();
        merged.push(MergedPr {
            repo,
            created,
            merged: merged_at,
            first_commit: date(&metrics["firstCommitAt"]),
            ready: date(&metrics["readyAt"]),
            reviews,
            requests,
            size: core["additions"].as_i64().unwrap_or(0) + core["deletions"].as_i64().unwrap_or(0),
            files: core["changedFiles"].as_i64(),
        });
    }
    Data { merged, open, covered_from, goals, without_review }
}

// MARK: - Periods

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Resolution {
    Day,
    Week,
    Month,
    Quarter,
    Year,
}

impl Resolution {
    const ALL: [Resolution; 5] = [Resolution::Day, Resolution::Week, Resolution::Month, Resolution::Quarter, Resolution::Year];

    fn from_cadence(cadence: &str) -> Option<Self> {
        Some(match cadence {
            "weekly" => Resolution::Week,
            "monthly" => Resolution::Month,
            "quarterly" => Resolution::Quarter,
            "annual" => Resolution::Year,
            _ => return None,
        })
    }

    fn noun(self) -> &'static str {
        match self {
            Resolution::Day => "day",
            Resolution::Week => "week",
            Resolution::Month => "month",
            Resolution::Quarter => "quarter",
            Resolution::Year => "year",
        }
    }

    fn cadence_title(self) -> &'static str {
        match self {
            Resolution::Week => "Weekly",
            Resolution::Month => "Monthly",
            Resolution::Quarter => "Quarterly",
            Resolution::Year => "Annual",
            Resolution::Day => "Daily",
        }
    }

    fn days(self) -> f64 {
        match self {
            Resolution::Day => 1.,
            Resolution::Week => 7.,
            Resolution::Month => 365.25 / 12.,
            Resolution::Quarter => 365.25 / 4.,
            Resolution::Year => 365.25,
        }
    }

    /// The range choices, as Gannin's, and the default.
    fn ranges(self) -> (&'static [usize], usize) {
        match self {
            Resolution::Day => (&[2, 14, 30, 60, 90], 14),
            Resolution::Week => (&[2, 13, 26, 52, 104], 13),
            Resolution::Month => (&[2, 6, 12, 24, 36], 12),
            Resolution::Quarter => (&[2, 4, 8, 12], 8),
            Resolution::Year => (&[2, 3, 5], 5),
        }
    }

    /// The start of the period containing `date`, in local time; weeks
    /// start on Monday, as `Calendar.metrics`.
    fn start(self, date: NaiveDate) -> NaiveDate {
        match self {
            Resolution::Day => date,
            Resolution::Week => date - Duration::days(date.weekday().num_days_from_monday() as i64),
            Resolution::Month => date.with_day(1).unwrap_or(date),
            Resolution::Quarter => NaiveDate::from_ymd_opt(date.year(), (date.month0() / 3) * 3 + 1, 1).unwrap_or(date),
            Resolution::Year => NaiveDate::from_ymd_opt(date.year(), 1, 1).unwrap_or(date),
        }
    }

    fn step(self, date: NaiveDate, by: i32) -> NaiveDate {
        let months = |n: i32| {
            if n >= 0 {
                date.checked_add_months(chrono::Months::new(n as u32))
            } else {
                date.checked_sub_months(chrono::Months::new((-n) as u32))
            }
            .unwrap_or(date)
        };
        match self {
            Resolution::Day => date + Duration::days(by as i64),
            Resolution::Week => date + Duration::days(7 * by as i64),
            Resolution::Month => months(by),
            Resolution::Quarter => months(3 * by),
            Resolution::Year => months(12 * by),
        }
    }

    fn heading(self, start: NaiveDate) -> String {
        match self {
            Resolution::Day => start.format("%a\n%-d %b").to_string(),
            Resolution::Week => format!("{}\n{}", start.format("%-d %b"), (start + Duration::days(6)).format("%-d %b")),
            Resolution::Month => start.format("%b %Y").to_string(),
            Resolution::Quarter => format!("Q{} {}", start.month0() / 3 + 1, start.year()),
            Resolution::Year => start.format("%Y").to_string(),
        }
    }
}

#[derive(Clone, Copy)]
struct Period {
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    label: NaiveDate,
}

fn local_midnight(date: NaiveDate) -> DateTime<Utc> {
    Local.from_local_datetime(&date.and_hms_opt(0, 0, 0).unwrap_or_default()).earliest().map(|t| t.with_timezone(&Utc)).unwrap_or_default()
}

/// `count` periods, newest (under way) first.
fn periods(resolution: Resolution, count: usize) -> Vec<Period> {
    let current = resolution.start(Local::now().date_naive());
    (0..count as i32)
        .map(|i| {
            let start = resolution.step(current, -i);
            Period { start: local_midnight(start), end: local_midnight(resolution.step(start, 1)), label: start }
        })
        .collect()
}

// MARK: - Measures

fn median(mut values: Vec<f64>) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let rank = 0.5 * (values.len() - 1) as f64;
    let (low, high) = (rank.floor() as usize, rank.ceil() as usize);
    Some(values[low] + (values[high] - values[low]) * (rank - low as f64))
}

fn seconds(d: Duration) -> f64 {
    d.num_seconds() as f64
}

impl MergedPr {
    fn reviews_before_merge(&self) -> impl Iterator<Item = &(String, String, DateTime<Utc>)> {
        self.reviews.iter().filter(|r| r.2 <= self.merged)
    }

    fn first_review(&self) -> Option<DateTime<Utc>> {
        self.reviews_before_merge().next().map(|r| r.2)
    }

    /// The first review, by the requested login, between the request and
    /// its deadline (withdrawn, else merged); `None` to skip a request
    /// withdrawn unanswered.
    fn answer(&self, login: &str, requested: DateTime<Utc>, removed: Option<DateTime<Utc>>) -> Option<Option<DateTime<Utc>>> {
        let deadline = removed.unwrap_or(self.merged);
        let response = self.reviews.iter().find(|r| r.0 == login && r.2 >= requested && r.2 <= deadline).map(|r| r.2);
        if response.is_none() && removed.is_some() {
            return None;
        }
        Some(response)
    }
}

/// Each metric for the last `weeks` weeks, newest first, for checking from
/// a shell.
pub fn print_weeks(org: &str, weeks: usize) {
    let data = load(org);
    let now = Utc::now();
    println!("covered from {:?}; {} merged PRs with metrics; {} open; {} goals", data.covered_from, data.merged.len(), data.open.len(), data.goals.len());
    for period in periods(Resolution::Week, weeks) {
        let row: Vec<String> = ["throughput", "cycleTime", "firstReview", "rework", "unreviewed", "prSize", "answered", "slowReviews", "openPullRequests"]
            .iter()
            .map(|m| {
                let (v, n) = measure(m, &data, &period, now);
                format!("{m}={}({n})", v.map(|v| format!("{v:.2}")).unwrap_or("-".into()))
            })
            .collect();
        println!("{} {}", period.label, row.join(" "));
    }
}

/// A metric's raw value in a period (seconds, a share 0-1, or a count) and
/// how many it's from. `None` when there's nothing to measure.
fn measure(metric: &str, data: &Data, period: &Period, now: DateTime<Utc>) -> (Option<f64>, usize) {
    let bucket: Vec<&MergedPr> = data.merged.iter().filter(|p| p.merged >= period.start && p.merged < period.end).collect();
    let n = bucket.len();
    match metric {
        "throughput" => (Some(n as f64), n),
        "cycleTime" => (
            median(bucket.iter().map(|p| seconds(p.merged - p.first_commit.unwrap_or(p.created).min(p.created))).collect()),
            n,
        ),
        "firstReview" => {
            let waits: Vec<f64> = bucket.iter().filter_map(|p| p.first_review().map(|f| seconds(f - p.ready.unwrap_or(p.created)).max(0.))).collect();
            let count = waits.len();
            (median(waits), count)
        }
        "rework" => {
            let spans: Vec<f64> = bucket
                .iter()
                .filter_map(|p| {
                    let first = p.first_review()?;
                    let approved = p.reviews_before_merge().filter(|r| r.1 == "APPROVED").last()?.2;
                    Some(seconds(approved - first).max(0.))
                })
                .collect();
            if n == 0 {
                (None, 0)
            } else if spans.is_empty() {
                (Some(0.), n)
            } else {
                (Some(spans.iter().filter(|d| **d >= 60.).count() as f64 / spans.len() as f64), n)
            }
        }
        "unreviewed" => {
            let needing: Vec<&&MergedPr> = bucket.iter().filter(|p| !data.without_review.contains(&p.repo)).collect();
            if needing.is_empty() {
                return (None, 0);
            }
            (Some(needing.iter().filter(|p| p.first_review().is_none()).count() as f64 / needing.len() as f64), needing.len())
        }
        "prSize" => {
            let mut sizes: Vec<i64> = bucket.iter().map(|p| p.size).collect();
            sizes.sort();
            (sizes.get(sizes.len() / 2).map(|s| *s as f64), n)
        }
        "prFiles" => {
            let mut files: Vec<i64> = bucket.iter().filter_map(|p| p.files).collect();
            files.sort();
            let count = files.len();
            (files.get(count / 2).map(|s| *s as f64), count)
        }
        "answered" => {
            let (mut requests, mut answered) = (0, 0);
            for pr in &bucket {
                for (login, at, removed) in &pr.requests {
                    if let Some(response) = pr.answer(login, *at, *removed) {
                        requests += 1;
                        answered += usize::from(response.is_some());
                    }
                }
            }
            ((requests > 0).then(|| answered as f64 / requests as f64), requests)
        }
        "slowReviews" => {
            let (mut requests, mut slow) = (0, 0);
            for pr in &data.merged {
                for (login, at, removed) in pr.requests.iter().filter(|r| r.1 >= period.start && r.1 < period.end) {
                    if let Some(response) = pr.answer(login, *at, *removed) {
                        requests += 1;
                        let answered = response.unwrap_or(removed.unwrap_or(pr.merged));
                        slow += usize::from(seconds(answered - *at) > 86_400.);
                    }
                }
            }
            for pr in &data.open {
                for at in pr.requested.iter().filter(|at| **at >= period.start && **at < period.end) {
                    requests += 1;
                    slow += usize::from(seconds(now - *at) > 86_400.);
                }
            }
            (Some(slow as f64), requests)
        }
        "openPullRequests" => {
            let at = period.end.min(now);
            let count = data.merged.iter().filter(|p| p.created <= at && at < p.merged).count() + data.open.iter().filter(|p| p.created <= at).count();
            (Some(count as f64), count)
        }
        _ => (None, 0),
    }
}

fn metric_title(metric: &str) -> (&'static str, &'static str) {
    match metric {
        "throughput" => ("PRs merged", "Merged in the period"),
        "cycleTime" => ("Cycle time", "Median, first commit to merge"),
        "firstReview" => ("First review", "Median wait for the first review once ready"),
        "rework" => ("PRs with rework", "Changes asked for after the first review"),
        "unreviewed" => ("Merged without review", "In repos that need a review"),
        "prSize" => ("PR size", "Median lines changed"),
        "prFiles" => ("Files changed", "Median files changed per PR"),
        "answered" => ("Review requests answered", "Before the PR merged, or the request was withdrawn"),
        "slowReviews" => ("Reviews waiting over a day", "Requests made in the period not answered within a day"),
        "openPullRequests" => ("Open PRs", "Open at the period's end, or now"),
        "issueCycleTime" => ("Issue cycle time", "Not in the pilot yet"),
        "flakyRuns" => ("Flaky CI runs", "Not in the pilot yet"),
        "ciTimePerPR" => ("CI time per PR", "Not in the pilot yet"),
        _ => ("Metric", ""),
    }
}

fn accumulates(metric: Option<&str>) -> bool {
    matches!(metric, Some("throughput" | "slowReviews" | "flakyRuns"))
}

/// `compactDuration`.
fn compact_duration(seconds: f64) -> String {
    if seconds < 59.5 {
        format!("{:.0}s", seconds)
    } else if seconds < 3600. {
        format!("{:.0}m", seconds / 60.)
    } else if seconds < 48. * 3600. {
        let h = seconds / 3600.;
        if h < 10. { format!("{h:.1}h") } else { format!("{h:.0}h") }
    } else {
        let d = seconds / 86_400.;
        if d < 10. { format!("{d:.1}d") } else { format!("{d:.0}d") }
    }
}

/// A goal's value for display units (hours, percent 0-100, or as is).
fn display(goal: &Goal, raw: f64) -> f64 {
    match goal.unit.as_str() {
        "hours" if goal.metric.is_some() => raw / 3600.,
        "percent" if goal.metric.is_some() => raw * 100.,
        _ => raw,
    }
}

fn format_value(goal: &Goal, raw: f64) -> String {
    match goal.unit.as_str() {
        "hours" if goal.metric.is_some() => compact_duration(raw),
        "percent" => {
            let v = display(goal, raw);
            if (v - v.round()).abs() < 0.05 { format!("{v:.0}%") } else { format!("{v:.1}%") }
        }
        "hours" => format!("{raw:.0}h"),
        "days" => format!("{raw:.0}d"),
        _ => {
            if (raw - raw.round()).abs() < 0.05 { format!("{raw:.0}") } else { format!("{raw:.1}") }
        }
    }
}

/// One cell: its raw value, how many it's from, whether it meets the
/// target, and whether there's history for it.
struct Cell {
    value: Option<f64>,
    count: usize,
    meets: Option<bool>,
    covered: bool,
    goal: Option<f64>,
}

fn cell(goal: &Goal, data: &Data, period: &Period, resolution: Resolution, now: DateTime<Utc>) -> Cell {
    let share = ((seconds(now - period.start) / seconds(period.end - period.start)).clamp(0., 1.)) * resolution.days() / goal.cadence.days();
    let target = goal.target.map(|t| if accumulates(goal.metric.as_deref()) { (t * share).floor() } else { t });
    let (value, count, covered, judged) = match &goal.metric {
        Some(metric) => {
            let covered = data.covered_from.is_some_and(|from| from <= period.start);
            if covered {
                let (value, count) = measure(metric, data, period, now);
                (value, count, true, true)
            } else {
                (None, 0, false, false)
            }
        }
        None if resolution == goal.cadence => {
            (goal.values.get(&period.label.format("%Y-%m-%d").to_string()).copied(), 0, true, true)
        }
        None => (None, 0, true, false),
    };
    let meets = match (judged, value, target) {
        (true, Some(value), Some(target)) => {
            let v = display(goal, value);
            Some(if goal.at_least { v >= target } else { v <= target })
        }
        _ => None,
    };
    Cell { value, count, meets, covered, goal: target }
}

// MARK: - The page

pub struct ScorecardPage {
    org: Option<String>,
    data: Option<Data>,
    cadence: Resolution,
    resolution: Resolution,
    range: usize,
    generation: u64,
}

impl ScorecardPage {
    pub fn new(org: Option<String>, cx: &mut Context<Self>) -> Self {
        let mut page = Self { org, data: None, cadence: Resolution::Week, resolution: Resolution::Week, range: 13, generation: 0 };
        page.load(cx);
        page
    }

    pub fn set_org(&mut self, org: Option<String>, cx: &mut Context<Self>) {
        if org != self.org {
            self.org = org;
            self.load(cx);
        }
    }

    pub fn reload(&mut self, cx: &mut Context<Self>) {
        self.load(cx);
    }

    fn load(&mut self, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        self.generation += 1;
        let generation = self.generation;
        cx.spawn(async move |this, cx| {
            let data = cx.background_executor().spawn(async move { load(&org) }).await;
            this.update(cx, |page, cx| {
                if page.generation == generation {
                    // Show the cadence that has goals, if Weekly has none.
                    if !data.goals.iter().any(|g| g.cadence == page.cadence) {
                        if let Some(goal) = data.goals.first() {
                            page.cadence = goal.cadence;
                        }
                    }
                    page.data = Some(data);
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
    }

    fn chip(&self, id: SharedString, label: String, on: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(id)
            .px_2()
            .py_0p5()
            .rounded_md()
            .text_xs()
            .cursor_pointer()
            .text_color(if on { theme.fg } else { theme.secondary })
            .when(on, |d| d.bg(theme.row_selected))
            .hover(|s| s.bg(theme.row_selected))
            .child(label)
    }

    fn toolbar(&self, data: &Data, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let group = |children: Vec<gpui::AnyElement>| div().p_0p5().flex().flex_row().gap_0p5().rounded_md().bg(theme.tile).children(children);
        let cadences: Vec<gpui::AnyElement> = [Resolution::Week, Resolution::Month, Resolution::Quarter, Resolution::Year]
            .into_iter()
            .map(|c| {
                let n = data.goals.iter().filter(|g| g.cadence == c).count();
                self.chip(SharedString::from(format!("cadence-{}", c.noun())), format!("{} ({n})", c.cadence_title()), c == self.cadence, theme)
                    .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                        page.cadence = c;
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();
        let resolutions: Vec<gpui::AnyElement> = Resolution::ALL
            .into_iter()
            .map(|r| {
                let title = format!("{}{}", &r.noun()[..1].to_uppercase(), &r.noun()[1..]);
                self.chip(SharedString::from(format!("view-{}", r.noun())), title, r == self.resolution, theme)
                    .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                        page.resolution = r;
                        page.range = r.ranges().1;
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();
        let (choices, _) = self.resolution.ranges();
        let ranges: Vec<gpui::AnyElement> = choices
            .iter()
            .map(|&n| {
                let label = if n == 2 { format!("Last {}", self.resolution.noun()) } else { format!("Last {n} {}s", self.resolution.noun()) };
                self.chip(SharedString::from(format!("range-{n}")), label, n == self.range, theme)
                    .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                        page.range = n;
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();
        div()
            .flex_none()
            .flex()
            .flex_row()
            .flex_wrap()
            .items_center()
            .gap_3()
            .px_4()
            .py_3()
            .child(group(cadences))
            .child(div().flex_1())
            .child(div().text_xs().text_color(theme.secondary).child("View by"))
            .child(group(resolutions))
            .child(group(ranges))
    }

    fn tile(&self, goal: &Goal, data: &Data, theme: &Theme) -> impl IntoElement {
        let now = Utc::now();
        let periods = periods(self.resolution, 13);
        let cells: Vec<Cell> = periods.iter().map(|p| cell(goal, data, p, self.resolution, now)).collect();
        let last = &cells[1];
        let before = &cells[if self.resolution == Resolution::Day { 8.min(cells.len() - 1) } else { 2 }];
        let value = last.value.map(|v| format_value(goal, v)).unwrap_or_else(|| "N/A".into());
        let change = match (last.value, before.value) {
            (Some(now_v), Some(before_v)) if goal.unit == "percent" => {
                let points = ((now_v - before_v) * 100.).round() as i64;
                Some(format!("{}{points} pp", if points > 0 { "+" } else { "" }))
            }
            (Some(now_v), Some(before_v)) if before_v > 0. => {
                let pct = ((now_v / before_v - 1.) * 100.).round() as i64;
                Some(if pct == 0 { "0%".into() } else { format!("{}{pct}%", if pct > 0 { "↑ " } else { "↓ " }) })
            }
            _ => None,
        };
        let off = last.meets == Some(false);
        let change_tint = if off { theme.critical() } else { theme.secondary };
        let caption = match self.resolution {
            Resolution::Day if periods[1].label == Local::now().date_naive() - Duration::days(1) => "Yesterday".to_string(),
            r => r.heading(periods[1].label).replace('\n', " to "),
        };
        let target = goal.target.map(|t| {
            let sign = if goal.at_least { "≥" } else { "≤" };
            let per = if accumulates(goal.metric.as_deref()) { format!(" a {}", goal.cadence.noun()) } else { String::new() };
            format!("Target {sign} {}{per}", format_target(goal, t))
        });
        let history: Vec<f64> = cells[1..].iter().rev().map(|c| c.value.map(|v| display(goal, v)).unwrap_or(0.)).collect();
        div()
            .w(px(220.))
            .h(px(150.))
            .p_3()
            .flex()
            .flex_col()
            .gap_1()
            .rounded_lg()
            .bg(theme.tile)
            .child(div().text_xs().text_color(theme.secondary).truncate().child(goal.name.clone()))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_end()
                    .gap_2()
                    .child(div().text_2xl().font_weight(FontWeight::SEMIBOLD).text_color(match last.meets {
                        Some(true) => theme.good(),
                        Some(false) => theme.critical(),
                        None => theme.fg,
                    }).child(value))
                    .when_some(change, |d, c| d.child(div().pb_1().text_xs().text_color(change_tint).child(c))),
            )
            .child(div().text_xs().text_color(theme.secondary).child(caption))
            .when_some(target, |d, t| d.child(div().text_xs().text_color(theme.tertiary).child(t)))
            .child(div().flex_1())
            .child(spark_bars(&history, theme))
    }

    fn table(&self, goals: &[&Goal], data: &Data, theme: &Theme) -> impl IntoElement {
        let now = Utc::now();
        let periods = periods(self.resolution, self.range);
        let header = div()
            .flex()
            .flex_row()
            .items_end()
            .border_b_1()
            .border_color(theme.border)
            .text_xs()
            .font_weight(FontWeight::MEDIUM)
            .text_color(theme.secondary)
            .child(div().w(px(250.)).flex_none().px_2().py_1().child("NAME"))
            .child(div().w(px(100.)).flex_none().px_2().py_1().child("TARGET"))
            .child(div().w(px(70.)).flex_none().px_2().py_1().child("HIT"))
            .children(periods.iter().enumerate().map(|(i, p)| {
                div()
                    .w(px(86.))
                    .flex_none()
                    .px_2()
                    .py_1()
                    .when(i == 0, |d| d.bg(theme.secondary.opacity(0.1)))
                    .child(self.resolution.heading(p.label))
            }));
        let rows = goals.iter().map(|goal| {
            let cells: Vec<Cell> = periods.iter().map(|p| cell(goal, data, p, self.resolution, now)).collect();
            let judged: Vec<&Cell> = cells[1..].iter().filter(|c| c.meets.is_some()).collect();
            let hit = judged.iter().filter(|c| c.meets == Some(true)).count();
            let caption = match &goal.metric {
                Some(metric) => metric_title(metric).1.to_string(),
                None => "Entered by hand".into(),
            };
            let target = match (goal.target, cells.get(1).and_then(|c| c.goal)) {
                (Some(_), Some(t)) => format!("{} {}", if goal.at_least { "≥" } else { "≤" }, format_target(goal, t)),
                _ => "No target".into(),
            };
            div()
                .h(px(48.))
                .flex()
                .flex_row()
                .items_center()
                .border_b_1()
                .border_color(theme.grid)
                .child(
                    div()
                        .w(px(250.))
                        .flex_none()
                        .px_2()
                        .flex()
                        .flex_col()
                        .child(div().truncate().child(goal.name.clone()))
                        .child(div().text_xs().text_color(theme.secondary).truncate().child(caption)),
                )
                .child(div().w(px(100.)).flex_none().px_2().text_color(theme.secondary).child(target))
                .child(div().w(px(70.)).flex_none().px_2().text_color(theme.secondary).child(if judged.is_empty() { "-".into() } else { format!("{hit}/{}", judged.len()) }))
                .children(cells.iter().enumerate().map(|(i, c)| {
                    let (text, tint): (String, Hsla) = match (c.covered, c.value) {
                        (false, _) => ("-".into(), theme.tertiary),
                        (true, None) => ("N/A".into(), theme.tertiary),
                        (true, Some(v)) => (
                            format_value(goal, v),
                            match c.meets {
                                Some(true) => theme.good(),
                                Some(false) => theme.critical(),
                                None => theme.secondary,
                            },
                        ),
                    };
                    div()
                        .w(px(86.))
                        .h_full()
                        .flex_none()
                        .px_2()
                        .flex()
                        .flex_col()
                        .justify_center()
                        .when(i == 0, |d| d.bg(theme.secondary.opacity(0.1)))
                        .child(div().text_color(tint).when(c.meets.is_some(), |d| d.font_weight(FontWeight::SEMIBOLD)).child(text))
                        .when(c.count > 0 && goal.metric.is_some(), |d| d.child(div().text_xs().text_color(theme.tertiary).child(format!("{} PRs", c.count))))
                }))
        });
        div().flex().flex_col().child(header).children(rows)
    }
}

fn format_target(goal: &Goal, target: f64) -> String {
    match goal.unit.as_str() {
        "hours" => format!("{target:.0}h"),
        "percent" => format!("{target:.0}%"),
        "days" => format!("{target:.0}d"),
        _ => format!("{target:.0}"),
    }
}

impl Render for ScorecardPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let Some(data) = self.data.clone() else {
            return div().size_full().p_4().bg(theme.bg).text_color(theme.secondary).child("Loading").into_any_element();
        };
        let goals: Vec<&Goal> = data.goals.iter().filter(|g| g.cadence == self.cadence).collect();
        let body = if goals.is_empty() {
            div()
                .p_8()
                .flex()
                .flex_col()
                .items_center()
                .gap_2()
                .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(format!("No {} goals", self.cadence.cadence_title().to_lowercase())))
                .child(div().text_color(theme.secondary).child(format!(
                    "Add what the team looks at each {}: one of Gannin's delivery numbers with a target, or one you enter yourself, like costs. Goals are added in Gannin's Scorecards for now.",
                    self.cadence.noun()
                )))
                .into_any_element()
        } else {
            let covered_note = data
                .covered_from
                .filter(|from| goals.iter().any(|g| g.metric.is_some()) && periods(self.resolution, self.range).last().is_some_and(|p| p.start < *from))
                .map(|from| format!("Merged PRs go back to {} so far. Earlier periods fill in as Gannin fetches them.", from.with_timezone(&Local).format("%-d %b %Y")));
            div()
                .flex()
                .flex_col()
                .gap_4()
                .px_4()
                .pb_4()
                .child(div().flex().flex_row().flex_wrap().gap_3().children(goals.iter().map(|g| self.tile(g, &data, &theme))))
                .child(div().id("scorecard-table").overflow_x_scroll().child(self.table(&goals, &data, &theme)))
                .when_some(covered_note, |d, note| d.child(div().text_xs().text_color(theme.secondary).child(note)))
                .when(goals.iter().any(|g| g.notes.is_some()), |d| d)
                .into_any_element()
        };
        div()
            .id("scorecard")
            .size_full()
            .flex()
            .flex_col()
            .overflow_y_scroll()
            .bg(theme.bg)
            .child(self.toolbar(&data, &theme, cx))
            .child(body)
            .into_any_element()
    }
}
