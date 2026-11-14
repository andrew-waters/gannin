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
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

// MARK: - Data

#[derive(Clone)]
struct MergedPr {
    author: String,
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
    author: String,
    created: DateTime<Utc>,
    /// (reviewer, asked).
    requested: Vec<(String, DateTime<Utc>)>,
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

/// A completed issue: when it closed, its repo, its assignees, and how long
/// it was in progress (`IssueCycleTime`).
#[derive(Clone)]
struct DoneIssue {
    closed: DateTime<Utc>,
    cycle: Option<f64>,
    assignees: Vec<String>,
}

#[derive(Clone, Default)]
pub struct Data {
    /// The org's members, by login: name and avatar.
    people: HashMap<String, (String, Option<String>)>,
    issues: Vec<DoneIssue>,
    issues_covered_from: Option<DateTime<Utc>>,
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
    let config = crate::projects::effective_config(org);
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
                        // A metric's goal is in the metric's unit, as Gannin's `effectiveUnit`.
                        unit: g["metric"].as_str().map(metric_unit).unwrap_or_else(|| g["unit"].as_str().unwrap_or("number")).to_string(),
                        at_least: g["comparison"].as_str() != Some("atMost"),
                        target: g["target"].as_f64(),
                        values: g["values"].as_object().map(|m| m.iter().filter_map(|(k, v)| Some((k.clone(), v.as_f64()?))).collect()).unwrap_or_default(),
                        notes: g["notes"].as_str().map(str::to_string),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let covered_from = std::fs::read(crate::cache::path(crate::cache::Kind::Metrics, org))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|m| date(&m["coveredFrom"]));
    let store: Value = std::fs::read(crate::cache::path(crate::cache::Kind::PullRequests, org))
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
                            .filter_map(|(login, at)| Some((login.clone(), date(at)?)))
                            .collect()
                    })
                    .unwrap_or_default();
                open.push(OpenPr { author: author.clone(), created, requested });
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
            author,
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
    // Issues completed, and their time in progress under the org's
    // workflow: spells in an in-progress status on its board, else from the
    // first linked PR to closing.
    let workflow = crate::projects::load(org).workflow;
    let issues_covered_from = std::fs::read(crate::cache::path(crate::cache::Kind::IssueHistory, org))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| date(&v["coveredFrom"]));
    let issue_store: Value = std::fs::read(crate::cache::path(crate::cache::Kind::Issues, org)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(Value::Null);
    let mut issues = Vec::new();
    for issue in issue_store["issues"].as_object().into_iter().flat_map(|m| m.values()) {
        let (core, history) = (&issue["core"], &issue["history"]);
        let Some(closed) = date(&core["closedAt"]) else { continue };
        if history["stateReason"].as_str() != Some("COMPLETED") || excluded_repos.contains(core["repo"].as_str().unwrap_or("")) {
            continue;
        }
        let mut changes: Vec<(DateTime<Utc>, String)> = history["statusChanges"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter(|c| workflow.project_number.is_none_or(|n| c["projectNumber"].as_i64() == Some(n)))
                    .filter_map(|c| Some((date(&c["at"])?, c["status"].as_str()?.to_string())))
                    .collect()
            })
            .unwrap_or_default();
        changes.sort_by_key(|c| c.0);
        let mut total = 0.;
        let mut spells = 0;
        let mut open_since: Option<DateTime<Utc>> = None;
        for (at, status) in &changes {
            let working = workflow.is_in_progress(status);
            match (working, open_since) {
                (true, None) => open_since = Some(*at),
                (false, Some(since)) => {
                    total += seconds(*at - since).max(0.);
                    spells += 1;
                    open_since = None;
                }
                _ => {}
            }
        }
        if let Some(since) = open_since {
            total += seconds(closed - since).max(0.);
            spells += 1;
        }
        let cycle = if spells > 0 {
            Some(total)
        } else if workflow.fall_back_to_pull_requests {
            history["linkedPullRequests"]
                .as_array()
                .and_then(|prs| prs.iter().filter_map(|p| date(&p["createdAt"])).min())
                .map(|first| seconds(closed - first).max(0.))
        } else {
            None
        };
        let assignees = core["assignees"].as_array().map(|a| a.iter().filter_map(|p| p["login"].as_str().map(str::to_string)).collect()).unwrap_or_default();
        issues.push(DoneIssue { closed, cycle, assignees });
    }
    let snapshot: Value = std::fs::read(crate::cache::path(crate::cache::Kind::Snapshots, org)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(Value::Null);
    let people = snapshot["members"]
        .as_array()
        .map(|m| {
            m.iter()
                .filter_map(|p| {
                    let login = p["login"].as_str()?.to_string();
                    let name = p["name"].as_str().filter(|n| !n.is_empty()).unwrap_or(&login).to_string();
                    Some((login, (name, p["avatarUrl"].as_str().map(str::to_string))))
                })
                .collect()
        })
        .unwrap_or_default();
    Data { people, issues, issues_covered_from, merged, open, covered_from, goals, without_review }
}

/// A metric's unit, as Gannin's `Metric.unit`.
fn metric_unit(metric: &str) -> &'static str {
    match metric {
        "cycleTime" | "firstReview" | "issueCycleTime" | "ciTimePerPR" => "hours",
        "rework" | "unreviewed" | "answered" => "percent",
        _ => "number",
    }
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
            Resolution::Day => start.format("%a %-d %b").to_string(),
            // One line: "9-15 Nov", or "28 Sep-4 Oct" across months.
            Resolution::Week => {
                let end = start + Duration::days(6);
                if start.month() == end.month() {
                    format!("{}-{}", start.format("%-d"), end.format("%-d %b"))
                } else {
                    format!("{}-{}", start.format("%-d %b"), end.format("%-d %b"))
                }
            }
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
    println!("covered from {:?}; {} merged PRs with metrics; {} open; {} completed issues; goals: {:?}", data.covered_from, data.merged.len(), data.open.len(), data.issues.len(), data.goals.iter().map(|g| (&g.name, &g.unit, g.target)).collect::<Vec<_>>());
    for period in periods(Resolution::Week, weeks) {
        let row: Vec<String> = ["throughput", "cycleTime", "firstReview", "prSize", "prFiles", "issueCycleTime"]
            .iter()
            .map(|m| {
                let (v, n) = measure(m, &data, &period, now, None);
                format!("{m}={}({n})", v.map(|v| format!("{v:.2}")).unwrap_or("-".into()))
            })
            .collect();
        println!("{} {}", period.label, row.join(" "));
    }
}

/// A metric's raw value in a period (seconds, a share 0-1, or a count) and
/// how many it's from. `None` when there's nothing to measure.
/// `who` narrows it to one person, as Gannin's breakdown: PRs they wrote,
/// requests made of them, issues assigned to them.
fn measure(metric: &str, data: &Data, period: &Period, now: DateTime<Utc>, who: Option<&str>) -> (Option<f64>, usize) {
    let mine = |login: &str| who.is_none_or(|w| w == login);
    let bucket: Vec<&MergedPr> = data.merged.iter().filter(|p| p.merged >= period.start && p.merged < period.end && mine(&p.author)).collect();
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
            for pr in data.merged.iter().filter(|p| p.merged >= period.start && p.merged < period.end) {
                for (login, at, removed) in pr.requests.iter().filter(|r| mine(&r.0)) {
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
                for (login, at, removed) in pr.requests.iter().filter(|r| r.1 >= period.start && r.1 < period.end && mine(&r.0)) {
                    if let Some(response) = pr.answer(login, *at, *removed) {
                        requests += 1;
                        let answered = response.unwrap_or(removed.unwrap_or(pr.merged));
                        slow += usize::from(seconds(answered - *at) > 86_400.);
                    }
                }
            }
            for pr in &data.open {
                for (_, at) in pr.requested.iter().filter(|(login, at)| *at >= period.start && *at < period.end && mine(login)) {
                    requests += 1;
                    slow += usize::from(seconds(now - *at) > 86_400.);
                }
            }
            (Some(slow as f64), requests)
        }
        "issueCycleTime" => {
            let cycles: Vec<f64> = data
                .issues
                .iter()
                .filter(|i| i.closed >= period.start && i.closed < period.end && who.is_none_or(|w| i.assignees.iter().any(|a| a == w)))
                .filter_map(|i| i.cycle)
                .collect();
            let count = cycles.len();
            (median(cycles), count)
        }
        "openPullRequests" => {
            let at = period.end.min(now);
            let count = data.merged.iter().filter(|p| p.created <= at && at < p.merged && mine(&p.author)).count()
                + data.open.iter().filter(|p| p.created <= at && mine(&p.author)).count();
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
        "issueCycleTime" => ("Issue cycle time", "Median time in progress, of issues completed"),
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

fn cell(goal: &Goal, data: &Data, period: &Period, resolution: Resolution, now: DateTime<Utc>, who: Option<&str>) -> Cell {
    let share = ((seconds(now - period.start) / seconds(period.end - period.start)).clamp(0., 1.)) * resolution.days() / goal.cadence.days();
    // A person's share of a team count isn't judged against the team's target.
    let personal_count = who.is_some() && accumulates(goal.metric.as_deref());
    let target = goal.target.filter(|_| !personal_count).map(|t| if accumulates(goal.metric.as_deref()) { (t * share).floor() } else { t });
    let (value, count, covered, judged) = match &goal.metric {
        Some(metric) => {
            let from = if metric == "issueCycleTime" { data.issues_covered_from } else { data.covered_from };
            let covered = from.is_some_and(|from| from <= period.start);
            if covered {
                let (value, count) = measure(metric, data, period, now, who);
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
    /// Goals opened to show each person's part, by name.
    expanded: HashSet<String>,
    /// The page's width, measured as it's laid out, for how many period
    /// columns fit; and how many columns back from the newest the table
    /// starts.
    width: std::rc::Rc<std::cell::Cell<f32>>,
    column_offset: usize,
    generation: u64,
}

impl ScorecardPage {
    pub fn new(org: Option<String>, cx: &mut Context<Self>) -> Self {
        let mut page = Self { org, data: None, cadence: Resolution::Week, resolution: Resolution::Week, range: 13, expanded: HashSet::new(), width: Default::default(), column_offset: 0, generation: 0 };
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
                        page.column_offset = 0;
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
                        page.column_offset = 0;
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
        let cells: Vec<Cell> = periods.iter().map(|p| cell(goal, data, p, self.resolution, now, None)).collect();
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
        let target = goal.target.map(|t| {
            let sign = if goal.at_least { "≥" } else { "≤" };
            let per = if accumulates(goal.metric.as_deref()) { format!(" a {}", goal.cadence.noun()) } else { String::new() };
            format!("{sign} {}{per}", format_target(goal, t))
        });
        let history: Vec<f64> = cells[1..].iter().rev().map(|c| c.value.map(|v| display(goal, v)).unwrap_or(0.)).collect();
        div()
            .flex_1()
            .min_w(px(190.))
            .h(px(132.))
            .overflow_hidden()
            .p_3()
            .flex()
            .flex_col()
            .gap_1()
            .rounded_lg()
            .bg(theme.tile)
            // The name, and its target opposite.
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1().min_w_0().text_sm().text_color(theme.secondary).truncate().child(goal.name.clone()))
                    .when_some(target, |d, t| d.child(div().flex_none().text_xs().text_color(theme.tertiary).child(t))),
            )
            .child(
                div()
                    .flex_none()
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
            .child(div().flex_1())
            .child(div().flex_none().h(px(22.)).overflow_hidden().child(spark_bars(&history, theme)))
    }

    /// How many period columns fit beside the name, target and hit columns.
    fn columns_that_fit(&self) -> usize {
        let width = self.width.get();
        if width <= 0. {
            return self.range;
        }
        (((width - 420.) / 86.).floor().max(1.) as usize).min(self.range)
    }

    fn table(&self, goals: &[&Goal], data: &Data, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let now = Utc::now();
        let all = periods(self.resolution, self.range);
        let fit = self.columns_that_fit();
        let start = self.column_offset.min(all.len().saturating_sub(fit));
        let periods: Vec<Period> = all[start..(start + fit).min(all.len())].to_vec();
        let paged = fit < all.len();
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
                    .when(i + start == 0, |d| d.bg(theme.secondary.opacity(0.1)))
                    .whitespace_nowrap()
                    .child(self.resolution.heading(p.label))
            }));
        let mut rows: Vec<gpui::AnyElement> = Vec::new();
        for goal in goals {
            // HIT and the target count every period; the row shows those that fit.
            let all_cells: Vec<Cell> = all.iter().map(|p| cell(goal, data, p, self.resolution, now, None)).collect();
            let judged: Vec<&Cell> = all_cells[1..].iter().filter(|c| c.meets.is_some()).collect();
            let hit = judged.iter().filter(|c| c.meets == Some(true)).count();
            let caption = match &goal.metric {
                Some(metric) => metric_title(metric).1.to_string(),
                None => "Entered by hand".into(),
            };
            let target = match (goal.target, all_cells.get(1).and_then(|c| c.goal)) {
                (Some(_), Some(t)) => format!("{} {}", if goal.at_least { "≥" } else { "≤" }, format_target(goal, t)),
                _ => "No target".into(),
            };
            let expanded = self.expanded.contains(&goal.name);
            let toggled = goal.name.clone();
            rows.push(
                div()
                    .h(px(48.))
                    .flex()
                    .flex_row()
                    .items_center()
                    .border_b_1()
                    .border_color(theme.grid)
                    .child(
                        div()
                            .id(SharedString::from(format!("goal-{}", goal.name)))
                            .w(px(250.))
                            .h_full()
                            .flex_none()
                            .px_2()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_1()
                            // A metric opens to show each person's part, as Gannin's.
                            .when(goal.metric.is_some(), |d| {
                                d.cursor_pointer()
                                    .hover(|s| s.bg(theme.row_selected))
                                    .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                                        if !page.expanded.remove(&toggled) {
                                            page.expanded.insert(toggled.clone());
                                        }
                                        cx.notify();
                                    }))
                                    .child(div().w(px(12.)).text_xs().text_color(theme.tertiary).child(if expanded { "▾" } else { "▸" }))
                            })
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .flex()
                                    .flex_col()
                                    .child(div().truncate().child(goal.name.clone()))
                                    .child(div().text_xs().text_color(theme.secondary).truncate().child(caption)),
                            ),
                    )
                    .child(div().w(px(100.)).flex_none().px_2().text_color(theme.secondary).child(target))
                    .child(div().w(px(70.)).flex_none().px_2().text_color(theme.secondary).child(if judged.is_empty() { "-".into() } else { format!("{hit}/{}", judged.len()) }))
                    .children(self.cell_views(goal, &all_cells[start..start + periods.len()], &goal.name, start, theme))
                    .into_any_element(),
            );
            if expanded {
                if let Some(metric) = goal.metric.as_deref() {
                    rows.extend(self.breakdown(goal, metric, data, &periods, start, theme, cx));
                }
            }
        }
        // ‹ Newer and Older › page through the columns that don't fit.
        let step = fit.max(1);
        let (newer, older) = (start > 0, start + fit < all.len());
        let button = |id: &'static str, label: &'static str, enabled: bool| {
            div()
                .id(id)
                .px_2()
                .py_0p5()
                .rounded_md()
                .text_xs()
                .border_1()
                .border_color(theme.border)
                .text_color(if enabled { theme.fg } else { theme.tertiary })
                .when(enabled, |d| d.cursor_pointer().hover(|s| s.bg(theme.row_selected)))
                .child(label)
        };
        let noun = self.resolution.noun();
        let pager = div()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .pb_1()
            .child(button("columns-newer", "‹ Newer", newer).when(newer, |d| {
                d.on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                    page.column_offset = start.saturating_sub(step);
                    cx.notify();
                }))
            }))
            .child(div().flex_1().flex().justify_center().text_xs().text_color(theme.secondary).child(format!(
                "{}s {}-{} of {}, newest first",
                format!("{}{}", &noun[..1].to_uppercase(), &noun[1..]),
                start + 1,
                start + periods.len(),
                all.len()
            )))
            .child(button("columns-older", "Older ›", older).when(older, |d| {
                d.on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                    page.column_offset = start + step;
                    cx.notify();
                }))
            }));
        div().flex().flex_col().when(paged, |d| d.child(pager)).child(header).children(rows)
    }
}

impl ScorecardPage {
    /// A row's cells: the value, green or red against the target, "-"
    /// before the history, "N/A" with nothing to measure; the count it's
    /// from on hover.
    /// `first` is the first cell's period, counted back from the current one.
    fn cell_views(&self, goal: &Goal, cells: &[Cell], key: &str, first: usize, theme: &Theme) -> Vec<gpui::AnyElement> {
        cells
            .iter()
            .enumerate()
            .map(|(i, c)| {
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
                let noun = match goal.metric.as_deref() {
                    Some("issueCycleTime") => "issues",
                    Some("answered" | "slowReviews") => "requests",
                    _ => "PRs",
                };
                let tip = match (c.covered, c.value, goal.metric.is_some()) {
                    (false, _, _) => "Before the history Gannin has".to_string(),
                    (true, None, _) => "Nothing to measure (yet)".to_string(),
                    (true, Some(_), true) => format!(
                        "{}, from {} {noun}{}",
                        match c.meets {
                            Some(true) => "On target",
                            Some(false) => "Off target",
                            None => "Not judged",
                        },
                        c.count,
                        if i + first == 0 { ", so far" } else { "" }
                    ),
                    (true, Some(_), false) => "Entered by hand".to_string(),
                };
                div()
                    .id(SharedString::from(format!("cell-{key}-{i}")))
                    .w(px(86.))
                    .h_full()
                    .flex_none()
                    .px_2()
                    .flex()
                    .items_center()
                    .when(i + first == 0, |d| d.bg(theme.secondary.opacity(0.1)))
                    .tooltip(move |_, cx| cx.new(|_| crate::issues::Tooltip(tip.clone())).into())
                    .child(div().text_color(tint).when(c.meets.is_some(), |d| d.font_weight(FontWeight::SEMIBOLD)).child(text))
                    .into_any_element()
            })
            .collect()
    }

    /// A goal's metric for each person with something in these periods,
    /// sorted by name, as Gannin's breakdown.
    fn breakdown(&self, goal: &Goal, metric: &str, data: &Data, periods: &[Period], first: usize, theme: &Theme, cx: &mut Context<Self>) -> Vec<gpui::AnyElement> {
        let now = Utc::now();
        let (from, to) = (periods.last().map(|p| p.start).unwrap_or(now), periods.first().map(|p| p.end).unwrap_or(now));
        let within = |t: DateTime<Utc>| t >= from && t < to;
        // Who could have a part: authors, reviewers asked, assignees.
        let mut logins: BTreeSet<String> = BTreeSet::new();
        match metric {
            "answered" | "slowReviews" => {
                logins.extend(data.merged.iter().flat_map(|p| p.requests.iter().filter(|r| within(r.1)).map(|r| r.0.clone())));
                logins.extend(data.open.iter().flat_map(|p| p.requested.iter().filter(|r| within(r.1)).map(|r| r.0.clone())));
            }
            "issueCycleTime" => logins.extend(data.issues.iter().filter(|i| within(i.closed)).flat_map(|i| i.assignees.iter().cloned())),
            _ => {
                logins.extend(data.merged.iter().filter(|p| within(p.merged) || (metric == "openPullRequests" && p.created < to)).map(|p| p.author.clone()));
                if metric == "openPullRequests" {
                    logins.extend(data.open.iter().map(|p| p.author.clone()));
                }
            }
        }
        let mut people: Vec<(String, String, Option<String>, Vec<Cell>)> = logins
            .into_iter()
            .filter(|l| !l.is_empty())
            .filter_map(|login| {
                let cells: Vec<Cell> = periods.iter().map(|p| cell(goal, data, p, self.resolution, now, Some(&login))).collect();
                if !cells.iter().any(|c| c.count > 0) {
                    return None;
                }
                let (name, avatar) = data.people.get(&login).cloned().unwrap_or_else(|| (login.clone(), None));
                Some((login, name, avatar, cells))
            })
            .collect();
        people.sort_by_key(|p| p.1.to_lowercase());
        if people.is_empty() {
            return vec![div().h(px(36.)).px_6().flex().items_center().text_xs().text_color(theme.secondary).child("Nobody to show in these periods yet.").into_any_element()];
        }
        people
            .into_iter()
            .map(|(login, name, avatar_url, cells)| {
                div()
                    .h(px(36.))
                    .flex()
                    .flex_row()
                    .items_center()
                    .bg(theme.secondary.opacity(0.04))
                    .border_b_1()
                    .border_color(theme.grid)
                    .child(
                        div()
                            .w(px(420.))
                            .flex_none()
                            .pl_6()
                            .pr_2()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .child(crate::avatars::avatar(&login, avatar_url.as_deref(), 18., theme, cx))
                            .child(div().text_xs().truncate().child(name)),
                    )
                    .children(self.cell_views(goal, &cells, &format!("{}-{login}", goal.name), first, theme))
                    .into_any_element()
            })
            .collect()
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
                .w_full()
                .min_w_0()
                .overflow_hidden()
                .flex()
                .flex_col()
                .gap_4()
                .px_4()
                .pb_4()
                .child(div().flex().flex_row().flex_wrap().gap_3().children(goals.iter().map(|g| self.tile(g, &data, &theme))))
                .child(
                    // Held to the page's width, so a table wider than it
                    // scrolls sideways.
                    // Measures the width the table has, so the columns that
                    // fit are shown and the rest paged to.
                    div().w_full().h(px(0.)).child({
                        let width = self.width.clone();
                        gpui::canvas(
                            move |bounds, window, _| {
                                let now = f32::from(bounds.size.width);
                                if (now - width.get()).abs() > 1. {
                                    width.set(now);
                                    window.refresh();
                                }
                            },
                            |_, _, _, _| {},
                        )
                        .w_full()
                        .h(px(0.))
                    }),
                )
                .child(self.table(&goals, &data, &theme, cx))
                .when_some(covered_note, |d, note| d.child(div().text_xs().text_color(theme.secondary).child(note)))
                .when(goals.iter().any(|g| g.notes.is_some()), |d| d)
                .into_any_element()
        };
        div()
            .id("scorecard")
            .size_full()
            .min_w_0()

            .flex()
            .flex_col()
            .overflow_y_scroll()
            .bg(theme.bg)
            .child(self.toolbar(&data, &theme, cx))
            .child(body)
            .into_any_element()
    }
}
