//! A port of the parts of `ActionsMetrics.swift` the overview uses: the
//! window and the period before it, outcome counts, percentiles, duration
//! buckets, day and week trends and per-repo stats. Repo exclusions
//! (`OrgConfig`) and default-branch health are left out of the pilot.

use crate::data::{History, Outcome, WorkflowRun};
use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, Utc};
use std::collections::HashMap;

#[derive(Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum Granularity {
    Day,
    Week,
}

impl Granularity {
    pub fn start_of(self, date: NaiveDate) -> NaiveDate {
        match self {
            Granularity::Day => date,
            // ISO 8601 weeks, from Monday, as `Calendar.metrics`.
            Granularity::Week => date - Duration::days(date.weekday().num_days_from_monday() as i64),
        }
    }

    pub fn next(self, start: NaiveDate) -> NaiveDate {
        match self {
            Granularity::Day => start + Duration::days(1),
            Granularity::Week => start + Duration::days(7),
        }
    }

    /// "Week of 7 Sep" or "7 Sep 2026", for hover lines.
    pub fn label(self, start: NaiveDate) -> String {
        match self {
            Granularity::Week => format!("Week of {}", start.format("%-d %b")),
            Granularity::Day => start.format("%-d %b %Y").to_string(),
        }
    }
}

pub fn local_date(time: DateTime<Utc>) -> NaiveDate {
    time.with_timezone(&Local).date_naive()
}

/// Median, p75 and p90, interpolated as `PercentileStat`.
#[derive(Clone, Default)]
pub struct Percentiles {
    pub median: Option<f64>,
    #[allow(dead_code)] // Shown by the workflow page, which isn't ported.
    pub p75: Option<f64>,
    pub p90: Option<f64>,
    pub count: usize,
}

impl Percentiles {
    pub fn new(mut values: Vec<f64>) -> Self {
        values.sort_by(|a, b| a.total_cmp(b));
        Self {
            median: percentile(&values, 0.5),
            p75: percentile(&values, 0.75),
            p90: percentile(&values, 0.9),
            count: values.len(),
        }
    }
}

fn percentile(sorted: &[f64], p: f64) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = p * (sorted.len() - 1) as f64;
    let (lower, upper) = (rank.floor() as usize, rank.ceil() as usize);
    Some(sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - lower as f64))
}

#[derive(Clone, Copy, Default)]
pub struct OutcomeCounts {
    pub succeeded: usize,
    pub failed: usize,
    pub cancelled: usize,
    pub skipped: usize,
    pub running: usize,
}

impl OutcomeCounts {
    pub fn of<'a>(runs: impl IntoIterator<Item = &'a WorkflowRun>) -> Self {
        let mut counts = Self::default();
        for run in runs {
            match run.outcome() {
                Outcome::Success => counts.succeeded += 1,
                Outcome::Failure => counts.failed += 1,
                Outcome::Cancelled => counts.cancelled += 1,
                Outcome::Skipped => counts.skipped += 1,
                Outcome::Running => counts.running += 1,
            }
        }
        counts
    }

    /// Failed out of those that passed or failed.
    pub fn failure_rate(&self) -> Option<f64> {
        let decided = self.succeeded + self.failed;
        (decided > 0).then(|| self.failed as f64 / decided as f64)
    }
}

/// Up to a minute, 5, 10, 20 and 60 minutes, and longer.
pub const HISTOGRAM_BOUNDS: [f64; 5] = [60.0, 300.0, 600.0, 1200.0, 3600.0];
pub const HISTOGRAM_LABELS: [&str; 6] = ["60s", "5min", "10min", "20min", "60min", "60min+"];

#[derive(Clone, Default)]
pub struct Histogram {
    pub counts: [usize; 6],
}

impl Histogram {
    pub fn new(durations: impl IntoIterator<Item = f64>) -> Self {
        let mut counts = [0; 6];
        for duration in durations {
            let bucket = HISTOGRAM_BOUNDS.iter().position(|bound| duration <= *bound).unwrap_or(5);
            counts[bucket] += 1;
        }
        Self { counts }
    }
}

#[derive(Clone, Default)]
pub struct PeriodSummary {
    pub runs: usize,
    pub run_time: f64,
    pub counts: OutcomeCounts,
    pub duration: Percentiles,
}

impl PeriodSummary {
    fn new(runs: &[&WorkflowRun]) -> Self {
        let durations: Vec<f64> = runs.iter().filter_map(|run| run.duration()).collect();
        Self {
            runs: runs.len(),
            run_time: durations.iter().sum(),
            counts: OutcomeCounts::of(runs.iter().copied()),
            duration: Percentiles::new(durations),
        }
    }
}

/// A day or week of runs.
#[derive(Clone)]
pub struct Bucket {
    pub start: NaiveDate,
    pub counts: OutcomeCounts,
    pub duration: Percentiles,
    pub run_time: f64,
}

fn buckets(runs: &[&WorkflowRun], granularity: Granularity, from: NaiveDate, to: NaiveDate) -> Vec<Bucket> {
    let mut by_start: HashMap<NaiveDate, Vec<&WorkflowRun>> = HashMap::new();
    for run in runs {
        by_start.entry(granularity.start_of(local_date(run.created_at))).or_default().push(*run);
    }
    let mut out = Vec::new();
    let mut start = granularity.start_of(from);
    while start <= to {
        let runs = by_start.get(&start).map(Vec::as_slice).unwrap_or(&[]);
        let durations: Vec<f64> = runs.iter().filter_map(|run| run.duration()).collect();
        out.push(Bucket {
            start,
            counts: OutcomeCounts::of(runs.iter().copied()),
            run_time: durations.iter().sum(),
            duration: Percentiles::new(durations),
        });
        start = granularity.next(start);
    }
    out
}

/// Run time per period by group: the biggest few by name, the rest as Others.
#[derive(Clone, Default)]
pub struct Stacked {
    /// Biggest first, Others last when there are any.
    pub series: Vec<String>,
    /// A value per series, by period start.
    pub values: HashMap<NaiveDate, Vec<f64>>,
}

impl Stacked {
    pub const OTHERS: &'static str = "Others";

    fn new(items: &[(NaiveDate, &str, f64)], top: usize) -> Self {
        let mut totals: HashMap<&str, f64> = HashMap::new();
        for (_, group, value) in items {
            *totals.entry(*group).or_default() += *value;
        }
        let mut ranked: Vec<(&str, f64)> = totals.into_iter().collect();
        ranked.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(b.0)));
        let mut series: Vec<String> = ranked.iter().take(top).map(|(name, _)| name.to_string()).collect();
        if ranked.len() > top {
            series.push(Self::OTHERS.to_string());
        }
        let index: HashMap<&str, usize> = ranked.iter().take(top).enumerate().map(|(i, (name, _))| (*name, i)).collect();
        let mut values: HashMap<NaiveDate, Vec<f64>> = HashMap::new();
        for (start, group, value) in items {
            let slot = index.get(group).copied().unwrap_or(top);
            values.entry(*start).or_insert_with(|| vec![0.0; series.len()])[slot] += value;
        }
        Self { series, values }
    }
}

/// The charts for one granularity.
#[derive(Clone, Default)]
pub struct Trend {
    pub buckets: Vec<Bucket>,
    pub by_repo: Stacked,
}

#[derive(Clone)]
pub struct RepoStats {
    pub repo: String,
    pub short_name: String,
    pub current: PeriodSummary,
    pub previous: PeriodSummary,
    pub histogram: Histogram,
    pub weeks: Vec<Bucket>,
    /// Its share of the org's run time.
    pub share: f64,
}

pub struct ActionsMetrics {
    pub days: i64,
    pub current: PeriodSummary,
    pub previous: PeriodSummary,
    /// Every repo's runs reach back to the previous period's start.
    pub has_previous: bool,
    pub retried: usize,
    pub passed_on_retry: usize,
    pub repo_count: usize,
    /// By run time, most first.
    pub repos: Vec<RepoStats>,
    pub day: Trend,
    pub week: Trend,
}

impl ActionsMetrics {
    /// `focus`, when given, keeps only those repos: the project's.
    pub fn new(history: &History, days: i64, focus: Option<&[String]>, now: DateTime<Utc>) -> Self {
        let window_start = now - Duration::days(days);
        let previous_start = window_start - Duration::days(days);
        let included: Vec<&WorkflowRun> = history
            .runs
            .values()
            .filter(|run| run.created_at < now && focus.is_none_or(|repos| repos.contains(&run.repo)))
            .collect();
        let in_window: Vec<&WorkflowRun> = included.iter().copied().filter(|run| run.created_at >= window_start).collect();
        let before: Vec<&WorkflowRun> = included
            .iter()
            .copied()
            .filter(|run| run.created_at >= previous_start && run.created_at < window_start)
            .collect();
        let (from, to) = (local_date(window_start), local_date(now));

        let trend = |granularity: Granularity| {
            let items: Vec<(NaiveDate, &str, f64)> = in_window
                .iter()
                .filter_map(|run| {
                    let duration = run.duration()?;
                    Some((granularity.start_of(local_date(run.created_at)), run.short_name(), duration))
                })
                .collect();
            Trend { buckets: buckets(&in_window, granularity, from, to), by_repo: Stacked::new(&items, 7) }
        };

        let current = PeriodSummary::new(&in_window);
        let mut by_repo: HashMap<&str, Vec<&WorkflowRun>> = HashMap::new();
        for run in &in_window {
            by_repo.entry(run.repo.as_str()).or_default().push(*run);
        }
        let mut before_by_repo: HashMap<&str, Vec<&WorkflowRun>> = HashMap::new();
        for run in &before {
            before_by_repo.entry(run.repo.as_str()).or_default().push(*run);
        }
        let mut repos: Vec<RepoStats> = by_repo
            .iter()
            .map(|(repo, runs)| {
                let summary = PeriodSummary::new(runs);
                RepoStats {
                    repo: repo.to_string(),
                    short_name: runs[0].short_name().to_string(),
                    previous: PeriodSummary::new(before_by_repo.get(repo).map(Vec::as_slice).unwrap_or(&[])),
                    histogram: Histogram::new(runs.iter().filter_map(|run| run.duration())),
                    weeks: buckets(runs, Granularity::Week, from, to),
                    share: if current.run_time > 0.0 { summary.run_time / current.run_time } else { 0.0 },
                    current: summary,
                }
            })
            .collect();
        repos.sort_by(|a, b| b.current.run_time.total_cmp(&a.current.run_time).then_with(|| a.repo.cmp(&b.repo)));

        Self {
            days,
            has_previous: !history.repositories.is_empty()
                && history.repositories.values().all(|repo| repo.covered_from <= previous_start),
            previous: PeriodSummary::new(&before),
            retried: in_window.iter().filter(|run| run.attempt > 1).count(),
            passed_on_retry: in_window.iter().filter(|run| run.passed_on_retry()).count(),
            repo_count: by_repo.len(),
            repos,
            day: trend(Granularity::Day),
            week: trend(Granularity::Week),
            current,
        }
    }

    pub fn trend(&self, granularity: Granularity) -> &Trend {
        match granularity {
            Granularity::Day => &self.day,
            Granularity::Week => &self.week,
        }
    }
}
