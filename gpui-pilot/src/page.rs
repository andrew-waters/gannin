//! The Actions overview: stat tiles, the three trend charts with hover, and
//! the Repositories table, as `ActionsView` lays them out.

use crate::charts::{self, histogram_cell, legend, spark_bars, Scale, Theme};
use crate::data::{self, History, CURRENT_VERSION};
use crate::format::{compact_duration, duration_or_dash, percent, thousands, Change};
use crate::state::CiSaved;
use crate::metrics::{ActionsMetrics, Granularity, RepoStats, Stacked};
use chrono::{Local, Utc};
use gpui::{
    div, prelude::*, px, ClickEvent, Context, EventEmitter, FontWeight, Hsla, SharedString, Subscription, Window,
    WindowAppearance,
};
use std::sync::Arc;
use std::time::Instant;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ChartKey {
    RunTime,
    Runs,
    Duration,
}

impl ChartKey {
    pub fn id(self) -> &'static str {
        match self {
            ChartKey::RunTime => "run-time",
            ChartKey::Runs => "runs",
            ChartKey::Duration => "duration",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum RepoSort {
    Name,
    RunTime,
    Runs,
    Failure,
    P90,
}

enum LoadState {
    Empty(String),
    Loading,
    Failed(String),
    Ready,
}

/// A repo row was clicked; the workspace opens it in the inspector.
pub struct OpenRepo(pub RepoStats);

impl EventEmitter<OpenRepo> for ActionsPage {}

pub struct ActionsPage {
    org: Option<String>,
    /// The project's repos, when one is picked.
    focus: Option<Vec<String>>,
    days: i64,
    granularity: Granularity,
    history: Option<Arc<History>>,
    metrics: Option<Arc<ActionsMetrics>>,
    state: LoadState,
    /// Parse and compute times, shown at the foot of the page.
    timings: String,
    hover: Option<(ChartKey, usize)>,
    repo_sort: (RepoSort, bool),
    /// Bumped on every load, so a slow one finishing late is dropped.
    generation: u64,
    _appearance: Subscription,
}

impl ActionsPage {
    pub fn new(org: Option<String>, saved: &CiSaved, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut page = Self {
            state: if org.is_some() {
                LoadState::Loading
            } else {
                LoadState::Empty(format!("No Actions cache in {}. Open Actions in Gannin first.", data::cache_dir().display()))
            },
            org,
            focus: None,
            days: saved.days,
            granularity: saved.granularity,
            history: None,
            metrics: None,
            timings: String::new(),
            hover: None,
            repo_sort: (RepoSort::RunTime, true),
            generation: 0,
            _appearance: cx.observe_window_appearance(window, |_, _, cx| cx.notify()),
        };
        page.load(cx);
        page
    }

    /// The controls to restore on the next launch.
    pub fn saved(&self) -> CiSaved {
        CiSaved { days: self.days, granularity: self.granularity }
    }

    /// For the status bar.
    pub fn status(&self) -> String {
        match (&self.state, &self.history, &self.metrics) {
            (LoadState::Ready, Some(history), Some(metrics)) => format!(
                "{} runs in {} days · cache synced {} · {}",
                thousands(metrics.current.runs),
                metrics.days,
                history.synced_at.with_timezone(&Local).format("%-d %b %H:%M"),
                self.timings
            ),
            (LoadState::Loading, _, _) => "Loading CI".into(),
            _ => "No CI cache".into(),
        }
    }

    /// Keeps the page to a project's repos, or every repo for none.
    pub fn set_focus(&mut self, focus: Option<Vec<String>>, cx: &mut Context<Self>) {
        if focus != self.focus {
            self.focus = focus;
            self.hover = None;
            self.load(cx);
        }
    }

    pub fn set_org(&mut self, org: Option<String>, cx: &mut Context<Self>) {
        if org == self.org {
            return;
        }
        self.org = org;
        self.hover = None;
        self.load(cx);
    }

    /// Reads the org's cache and computes its metrics off the main thread.
    fn load(&mut self, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        self.generation += 1;
        let generation = self.generation;
        let days = self.days;
        let focus = self.focus.clone();
        let history = self.history.clone().filter(|h| h.org_login.eq_ignore_ascii_case(&org));
        if history.is_none() {
            self.history = None;
            self.metrics = None;
            self.state = LoadState::Loading;
        }
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let started = Instant::now();
                    let (history, read) = match history {
                        Some(history) => (history, None),
                        None => {
                            let bytes = std::fs::read(data::cache_path(&org)).map_err(|e| e.to_string())?;
                            let history: History = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
                            if history.version != CURRENT_VERSION {
                                return Err(format!("Cache version {} isn't {CURRENT_VERSION}", history.version));
                            }
                            (Arc::new(history), Some((bytes.len(), started.elapsed())))
                        }
                    };
                    let computing = Instant::now();
                    let metrics = ActionsMetrics::new(&history, days, focus.as_deref(), Utc::now());
                    Ok((history, Arc::new(metrics), read, computing.elapsed()))
                })
                .await;
            this.update(cx, |page, cx| {
                if page.generation != generation {
                    return;
                }
                match result {
                    Ok((history, metrics, read, computed)) => {
                        let read = read
                            .map(|(bytes, time)| {
                                format!("Read {:.1} MB, {} runs, in {} ms; ", bytes as f64 / 1e6, history.runs.len(), time.as_millis())
                            })
                            .unwrap_or_default();
                        page.timings = format!("{read}metrics in {} ms", computed.as_millis());
                        page.history = Some(history);
                        page.metrics = Some(metrics);
                        page.state = LoadState::Ready;
                    }
                    Err(error) => page.state = LoadState::Failed(error),
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    pub fn set_hover(&mut self, key: ChartKey, index: usize, hovered: bool, cx: &mut Context<Self>) {
        if hovered {
            self.hover = Some((key, index));
        } else if self.hover == Some((key, index)) {
            self.hover = None;
        } else {
            return;
        }
        cx.notify();
    }

    fn hovered(&self, key: ChartKey) -> Option<usize> {
        self.hover.filter(|(k, _)| *k == key).map(|(_, i)| i)
    }

    // MARK: Controls

    fn segmented<T: Copy + PartialEq + 'static>(
        &self,
        id: &'static str,
        options: Vec<(SharedString, T)>,
        selected: T,
        on_select: fn(&mut Self, T, &mut Context<Self>),
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        div()
            .flex()
            .flex_row()
            .rounded_md()
            .border_1()
            .border_color(theme.border)
            .overflow_hidden()
            .children(options.into_iter().enumerate().map(|(i, (label, value))| {
                let is_selected = value == selected;
                div()
                    .id((id, i))
                    .px_3()
                    .py_0p5()
                    .text_sm()
                    .cursor_pointer()
                    .when(is_selected, |d| d.bg(theme.selected).text_color(theme.on_selected))
                    .when(!is_selected, |d| d.hover(|s| s.bg(theme.tile)))
                    .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| on_select(page, value, cx)))
                    .child(label)
            }))
    }

    fn header(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap_4()
            .child(div().text_xl().font_weight(FontWeight::SEMIBOLD).child("CI"))
            .child(div().flex_1())
            .child(self.segmented(
                "window",
                vec![("7 days".into(), 7), ("30 days".into(), 30), ("90 days".into(), 90)],
                self.days,
                |page, days, cx| {
                    page.days = days;
                    page.load(cx);
                },
                theme,
                cx,
            ))
    }

    // MARK: Sections

    fn tiles(&self, m: &ActionsMetrics, theme: &Theme) -> impl IntoElement {
        let previous = m.has_previous.then_some(&m.previous);
        let current = &m.current;
        let per_day = current.runs as f64 / m.days.max(1) as f64;
        let per_day = if per_day < 10.0 { format!("{per_day:.1}") } else { format!("{per_day:.0}") };
        let rerun = (current.runs > 0).then(|| m.retried as f64 / current.runs as f64);
        let p90_change = previous.and_then(|p| Change::percent(current.duration.p90?, p.duration.p90?, Some(true)));
        div()
            .flex()
            .flex_row()
            .flex_wrap()
            .gap_3()
            .child(tile(
                "Run time",
                compact_duration(current.run_time),
                "Wall clock, summed".into(),
                previous.and_then(|p| Change::percent(current.run_time, p.run_time, Some(true))),
                theme,
            ))
            .child(tile(
                "Runs",
                current.runs.to_string(),
                format!("{per_day} a day · {} repos", m.repo_count),
                previous.and_then(|p| Change::percent(current.runs as f64, p.runs as f64, None)),
                theme,
            ))
            .child(tile(
                "Failure rate",
                percent(current.counts.failure_rate()),
                "All runs, PRs included".into(),
                previous.and_then(|p| Change::points(current.counts.failure_rate(), p.counts.failure_rate(), true)),
                theme,
            ))
            .child(tile(
                "Typical run (p90)",
                duration_or_dash(current.duration.p90),
                current.duration.median.map(|m| format!("Median {}", compact_duration(m))).unwrap_or_default(),
                p90_change,
                theme,
            ))
            .child(tile(
                "Re-run",
                percent(rerun),
                format!("{} passed only on a re-run", m.passed_on_retry),
                None,
                theme,
            ))
    }

    fn trends(&self, m: &ActionsMetrics, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let granularity = self.granularity;
        let trend = m.trend(granularity);
        let buckets = &trend.buckets;
        let x_labels: Vec<String> = buckets.iter().map(|b| b.start.format("%-d %b").to_string()).collect();
        let per = if granularity == Granularity::Day { "day" } else { "week" };

        // Run time by repository.
        let stacked: &Stacked = &trend.by_repo;
        let series_color = |i: usize, name: &str| if name == Stacked::OTHERS { theme.neutral() } else { theme.slot(i) };
        let run_time_columns: Vec<Vec<(f64, Hsla)>> = buckets
            .iter()
            .map(|b| {
                let values = stacked.values.get(&b.start);
                stacked
                    .series
                    .iter()
                    .enumerate()
                    .map(|(i, name)| (values.map(|v| v[i]).unwrap_or(0.0), series_color(i, name)))
                    .collect()
            })
            .collect();
        let run_time_hover = self.hovered(ChartKey::RunTime);
        let run_time_line = match run_time_hover.and_then(|i| buckets.get(i)) {
            Some(bucket) => {
                let mut values: Vec<(&String, f64)> = stacked
                    .series
                    .iter()
                    .zip(stacked.values.get(&bucket.start).cloned().unwrap_or_default())
                    .filter(|(_, v)| *v > 0.0)
                    .collect();
                values.sort_by(|a, b| b.1.total_cmp(&a.1));
                let total: f64 = values.iter().map(|(_, v)| v).sum();
                let top: Vec<String> =
                    values.iter().take(4).map(|(name, v)| format!("{name} {}", compact_duration(*v))).collect();
                (format!("{}: {} in all · {}", granularity.label(bucket.start), compact_duration(total), top.join(", ")), true)
            }
            None => ("Wall-clock run time, summed. Hover for values.".to_string(), false),
        };

        // Runs by outcome.
        let runs_columns: Vec<Vec<(f64, Hsla)>> = buckets
            .iter()
            .map(|b| {
                vec![
                    (b.counts.succeeded as f64, theme.good()),
                    (b.counts.failed as f64, theme.critical()),
                    (b.counts.cancelled as f64, theme.neutral()),
                ]
            })
            .collect();
        let runs_hover = self.hovered(ChartKey::Runs);
        let runs_line = match runs_hover.and_then(|i| buckets.get(i)) {
            Some(b) => (
                format!(
                    "{}: {} succeeded, {} failed, {} cancelled · failure rate {}",
                    granularity.label(b.start),
                    b.counts.succeeded,
                    b.counts.failed,
                    b.counts.cancelled,
                    percent(b.counts.failure_rate())
                ),
                true,
            ),
            None => ("Hover for values.".to_string(), false),
        };

        // Duration, median and p90.
        let duration_hover = self.hovered(ChartKey::Duration);
        let duration_line = match duration_hover.and_then(|i| buckets.get(i)) {
            Some(b) => (
                format!(
                    "{}: median {}, p90 {} over {} runs",
                    granularity.label(b.start),
                    duration_or_dash(b.duration.median),
                    duration_or_dash(b.duration.p90),
                    b.duration.count
                ),
                true,
            ),
            None => ("Hover for values.".to_string(), false),
        };
        let duration_series = vec![
            (buckets.iter().map(|b| b.duration.median).collect(), theme.blue()),
            (buckets.iter().map(|b| b.duration.p90).collect(), theme.orange()),
        ];

        let run_time_legend: Vec<(String, Hsla)> =
            stacked.series.iter().enumerate().map(|(i, name)| (name.clone(), series_color(i, name))).collect();

        div()
            .flex()
            .flex_col()
            .gap_6()
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .border_b_1()
                    .border_color(theme.border)
                    .pb_2()
                    .child(div().flex_1().text_lg().font_weight(FontWeight::SEMIBOLD).child("Trends"))
                    .child(self.segmented(
                        "granularity",
                        vec![("Day".into(), Granularity::Day), ("Week".into(), Granularity::Week)],
                        granularity,
                        |page, granularity, cx| {
                            page.granularity = granularity;
                            page.hover = None;
                            cx.notify();
                        },
                        theme,
                        cx,
                    )),
            )
            .child(chart_block(
                "Run time by repository".into(),
                charts::stacked_bars(ChartKey::RunTime, run_time_columns, x_labels.clone(), Scale::Duration, 200., run_time_hover, theme, cx)
                    .into_any_element(),
                legend(run_time_legend, theme).into_any_element(),
                run_time_line,
                theme,
            ))
            .child(chart_block(
                format!("Runs per {per}"),
                charts::stacked_bars(ChartKey::Runs, runs_columns, x_labels.clone(), Scale::Count, 160., runs_hover, theme, cx)
                    .into_any_element(),
                legend(
                    vec![
                        ("Succeeded".into(), theme.good()),
                        ("Failed".into(), theme.critical()),
                        ("Cancelled".into(), theme.neutral()),
                    ],
                    theme,
                )
                .into_any_element(),
                runs_line,
                theme,
            ))
            .child(chart_block(
                format!("Run duration per {per}"),
                charts::lines(
                    ChartKey::Duration,
                    duration_series,
                    x_labels,
                    140.,
                    duration_hover,
                    granularity == Granularity::Week,
                    theme,
                    cx,
                )
                .into_any_element(),
                legend(vec![("Median".into(), theme.blue()), ("p90".into(), theme.orange())], theme).into_any_element(),
                duration_line,
                theme,
            ))
    }

    fn repositories(&self, m: &ActionsMetrics, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let (sort, descending) = self.repo_sort;
        let mut repos: Vec<&RepoStats> = m.repos.iter().collect();
        repos.sort_by(|a, b| {
            let order = match sort {
                RepoSort::Name => b.short_name.to_lowercase().cmp(&a.short_name.to_lowercase()),
                RepoSort::RunTime => a.current.run_time.total_cmp(&b.current.run_time),
                RepoSort::Runs => a.current.runs.cmp(&b.current.runs),
                RepoSort::Failure => {
                    a.current.counts.failure_rate().unwrap_or(-1.0).total_cmp(&b.current.counts.failure_rate().unwrap_or(-1.0))
                }
                RepoSort::P90 => a.current.duration.p90.unwrap_or(-1.0).total_cmp(&b.current.duration.p90.unwrap_or(-1.0)),
            };
            if descending { order.reverse() } else { order }
        });
        let has_previous = m.has_previous;

        let header = |label: &'static str, column: Option<RepoSort>, width: Option<f32>, cx: &mut Context<Self>| {
            let marker = match column {
                Some(c) if c == sort => if descending { " ↓" } else { " ↑" },
                _ => "",
            };
            div()
                .id(label)
                .when_some(width, |d, w| d.w(px(w)).flex_none())
                .when(width.is_none(), |d| d.flex_1().min_w(px(140.)))
                .text_xs()
                .font_weight(FontWeight::MEDIUM)
                .text_color(theme.secondary)
                .when_some(column, |d, column| {
                    d.cursor_pointer().on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                        page.repo_sort = if page.repo_sort.0 == column {
                            (column, !page.repo_sort.1)
                        } else {
                            (column, column != RepoSort::Name)
                        };
                        cx.notify();
                    }))
                })
                .child(format!("{label}{marker}"))
        };

        let header_row = div()
            .flex()
            .flex_row()
            .items_center()
            .gap_3()
            .py_1()
            .border_b_1()
            .border_color(theme.border)
            .child(header("Repository", Some(RepoSort::Name), None, cx))
            .child(header("Run time", Some(RepoSort::RunTime), Some(90.), cx))
            .child(header("Share", None, Some(50.), cx))
            .child(header("Runs", Some(RepoSort::Runs), Some(70.), cx))
            .child(header("Failure rate", Some(RepoSort::Failure), Some(90.), cx))
            .child(header("p90", Some(RepoSort::P90), Some(60.), cx))
            .child(header("Weekly run time", None, Some(130.), cx))
            .child(header("Durations", None, Some(90.), cx));

        let rows = repos.into_iter().enumerate().map(|(index, repo)| {
            let opened = repo.clone();
            let previous = has_previous.then_some(&repo.previous);
            let change = previous.and_then(|p| Change::percent(repo.current.run_time, p.run_time, Some(true)));
            div()
                .id(("repo-row", index))
                .flex()
                .flex_row()
                .items_center()
                .gap_3()
                .py_1p5()
                .border_b_1()
                .border_color(theme.grid)
                .cursor_pointer()
                .hover(|s| s.bg(theme.tile))
                .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(OpenRepo(opened.clone()))))
                .child(div().flex_1().min_w(px(140.)).overflow_hidden().whitespace_nowrap().child(repo.short_name.clone()))
                .child(
                    div()
                        .w(px(90.))
                        .flex_none()
                        .flex()
                        .flex_row()
                        .gap_1p5()
                        .child(compact_duration(repo.current.run_time))
                        .children(change.map(|c| change_label(c, theme))),
                )
                .child(div().w(px(50.)).flex_none().text_color(theme.secondary).child(percent(Some(repo.share))))
                .child(div().w(px(70.)).flex_none().child(repo.current.runs.to_string()))
                .child(div().w(px(90.)).flex_none().child(percent(repo.current.counts.failure_rate())))
                .child(div().w(px(60.)).flex_none().child(duration_or_dash(repo.current.duration.p90)))
                .child(
                    div()
                        .w(px(130.))
                        .flex_none()
                        .child(spark_bars(&repo.weeks.iter().map(|w| w.run_time).collect::<Vec<_>>(), theme)),
                )
                .child(div().w(px(90.)).flex_none().child(histogram_cell(&repo.histogram, theme)))
        });

        div()
            .flex()
            .flex_col()
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_baseline()
                    .gap_2()
                    .pb_2()
                    .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child("Repositories"))
                    .child(div().text_color(theme.secondary).child(m.repos.len().to_string())),
            )
            .child(header_row)
            .children(rows)
    }
}

fn change_label(change: Change, theme: &Theme) -> impl IntoElement {
    let color = match change.is_worse {
        Some(true) => theme.critical(),
        Some(false) => theme.good(),
        None => theme.secondary,
    };
    div().text_color(color).child(change.text)
}

fn tile(title: &'static str, value: String, detail: String, change: Option<Change>, theme: &Theme) -> impl IntoElement {
    div()
        .w(px(190.))
        .flex()
        .flex_col()
        .gap_1()
        .p_3()
        .rounded_lg()
        .bg(theme.tile)
        .child(div().text_sm().text_color(theme.secondary).child(title))
        .child(
            div()
                .flex()
                .flex_row()
                .items_baseline()
                .gap_2()
                .child(div().text_2xl().font_weight(FontWeight::SEMIBOLD).child(value))
                .children(change.map(|c| div().text_sm().font_weight(FontWeight::MEDIUM).child(change_label(c, theme)))),
        )
        .when(!detail.is_empty(), |d| d.child(div().text_xs().text_color(theme.secondary).child(detail)))
}

fn chart_block(title: String, chart: gpui::AnyElement, legend: gpui::AnyElement, line: (String, bool), theme: &Theme) -> impl IntoElement {
    let (text, active) = line;
    div()
        .flex()
        .flex_col()
        .gap_2()
        .child(div().font_weight(FontWeight::SEMIBOLD).child(title))
        .child(chart)
        .child(legend)
        .child(div().text_sm().text_color(if active { theme.secondary } else { theme.tertiary }).child(text))
}

impl Render for ActionsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::new(matches!(window.appearance(), WindowAppearance::Dark | WindowAppearance::VibrantDark));
        let body = match (&self.state, self.metrics.clone()) {
            (LoadState::Ready, Some(m)) if m.current.runs == 0 => {
                div().text_color(theme.secondary).child(format!("No workflow runs in the last {} days.", m.days)).into_any_element()
            }
            (LoadState::Ready, Some(m)) => div()
                .flex()
                .flex_col()
                .gap_8()
                .child(self.tiles(&m, &theme))
                .child(self.trends(&m, &theme, cx))
                .child(self.repositories(&m, &theme, cx))
                .child(div().text_xs().text_color(theme.tertiary).child(self.timings.clone()))
                .into_any_element(),
            (LoadState::Failed(error), _) => {
                div().text_color(theme.critical()).child(format!("Couldn't read the cache: {error}")).into_any_element()
            }
            (LoadState::Empty(message), _) => div().text_color(theme.secondary).child(message.clone()).into_any_element(),
            _ => div().text_color(theme.secondary).child("Loading").into_any_element(),
        };
        div()
            .id("page")
            .size_full()
            .overflow_y_scroll()
            .bg(theme.bg)
            .text_color(theme.fg)
            .font_family(".SystemUIFont")
            .text_sm()
            .child(div().flex().flex_col().gap_6().p_6().child(self.header(&theme, cx)).child(body))
    }
}
