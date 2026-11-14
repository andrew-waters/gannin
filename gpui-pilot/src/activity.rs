//! Activity, after Gannin's `WorkLogPage`: who did what, day by day (or
//! week by week), for the org's members.
//!
//! - Work log: a grid of people and days, a dot per event (a commit, a
//!   review, a PR opened or merged, an issue opened or commented on),
//!   packed in a spiral as Gannin packs them, commits sized by lines.
//! - Threads: a lane per person, each PR they opened as a bar from its
//!   first commit to merge (or now while open), with its commits on it.
//!
//! Events come from Gannin's caches, read only: each PR's work log, and the
//! issues in `WorkLog/<org>.json`; people are the org's members from its
//! snapshot, less excluded authors and bots. Punchcards aren't here yet.

use crate::avatars::avatar;
use crate::charts::Theme;
use crate::issues::Tooltip;
use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, TimeZone, Utc};
use gpui::{div, prelude::*, px, ClickEvent, Context, EventEmitter, FontWeight, Hsla, SharedString, Window};
use serde_json::Value;
use std::collections::{BTreeSet, HashMap};

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub enum EventKind {
    Commit,
    Review,
    PrOpened,
    PrMerged,
    IssueOpened,
    IssueComment,
}

impl EventKind {
    const ALL: [EventKind; 6] = [EventKind::Commit, EventKind::Review, EventKind::PrOpened, EventKind::PrMerged, EventKind::IssueOpened, EventKind::IssueComment];

    fn title(self) -> &'static str {
        match self {
            EventKind::Commit => "Commit",
            EventKind::Review => "Review",
            EventKind::PrOpened => "PR opened",
            EventKind::PrMerged => "PR merged",
            EventKind::IssueOpened => "Issue opened",
            EventKind::IssueComment => "Issue comment",
        }
    }

    /// The palette slot Gannin gives each kind.
    fn color(self, theme: &Theme) -> Hsla {
        theme.slot(match self {
            EventKind::Commit => 0,
            EventKind::Review => 1,
            EventKind::PrOpened => 2,
            EventKind::PrMerged => 3,
            EventKind::IssueOpened => 4,
            EventKind::IssueComment => 5,
        })
    }
}

#[derive(Clone)]
struct Event {
    kind: EventKind,
    login: String,
    at: DateTime<Utc>,
    repo: String,
    number: i64,
    title: String,
    url: String,
    /// The issue's node ID, to open it in a drawer.
    issue_id: Option<String>,
    lines: i64,
}

impl Event {
    fn radius(&self) -> f32 {
        match self.kind {
            EventKind::Commit => (3. + 1.6 * (1. + self.lines as f32).log10()).min(9.),
            EventKind::Review => 5.,
            EventKind::IssueComment => 4.,
            _ => 6.5,
        }
    }
}

/// A PR someone opened, for Threads.
#[derive(Clone)]
struct Thread {
    login: String,
    start: DateTime<Utc>,
    end: Option<DateTime<Utc>>,
    merged: bool,
    closed: bool,
    commits: Vec<(DateTime<Utc>, i64)>,
    reviews: usize,
    repo: String,
    number: i64,
    title: String,
    url: String,
}

#[derive(Clone)]
struct Person {
    login: String,
    name: String,
    avatar: Option<String>,
}

#[derive(Clone, Default)]
pub struct Data {
    people: Vec<Person>,
    events: Vec<Event>,
    threads: Vec<Thread>,
}

fn date(v: &Value) -> Option<DateTime<Utc>> {
    v.as_str()?.parse().ok()
}

fn read(path: std::path::PathBuf) -> Value {
    std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(Value::Null)
}

/// Reads Gannin's caches for the org. Large: call off the main thread.
pub fn load(org: &str) -> Data {
    let config = crate::projects::config_json(org);
    let listed = |key: &str, login: &str| config[key].as_array().is_some_and(|a| a.iter().any(|v| v.as_str() == Some(login)));
    let excluded = |login: &str| {
        let lower = login.to_lowercase();
        listed("excludedAuthors", login) || ((lower.ends_with("-bot") || lower.ends_with("[bot]")) && !listed("includedAuthors", login))
    };
    let support = std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_default().join("Library/Application Support");
    let encoded = org.replace('%', "%25").replace(' ', "%20");
    let snapshot = read(support.join("Snapshots").join(format!("{org}.json")));
    let mut people: Vec<Person> = snapshot["members"]
        .as_array()
        .map(|m| {
            m.iter()
                .filter_map(|p| {
                    let login = p["login"].as_str()?.to_string();
                    let name = p["name"].as_str().filter(|n| !n.is_empty()).unwrap_or(&login).to_string();
                    Some(Person { name, avatar: p["avatarUrl"].as_str().map(str::to_string), login })
                })
                .filter(|p| !excluded(&p.login))
                .collect()
        })
        .unwrap_or_default();
    people.sort_by_key(|p| p.name.to_lowercase());

    let excluded_repos: Vec<String> = config["excludedRepos"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default();
    let mut events = Vec::new();
    let mut threads = Vec::new();
    let store = read(crate::cache::gannin_path(crate::cache::Kind::PullRequests, org));
    for pr in store["pullRequests"].as_object().into_iter().flat_map(|m| m.values()) {
        let log = &pr["workLog"];
        if log.is_null() {
            continue;
        }
        let core = &pr["core"];
        let repo = core["repo"].as_str().unwrap_or("").to_string();
        if excluded_repos.contains(&repo) {
            continue;
        }
        let author = core["author"]["login"].as_str().unwrap_or("").to_string();
        let (number, title, url) = (core["number"].as_i64().unwrap_or(0), core["title"].as_str().unwrap_or("").to_string(), core["url"].as_str().unwrap_or("").to_string());
        let event = |kind, login: String, at, lines| Event { kind, login, at, repo: repo.clone(), number, title: title.clone(), url: url.clone(), issue_id: None, lines };
        let mut commits = Vec::new();
        for commit in log["commits"].as_array().into_iter().flatten() {
            let Some(at) = date(&commit["authoredAt"]) else { continue };
            let lines = commit["additions"].as_i64().unwrap_or(0) + commit["deletions"].as_i64().unwrap_or(0);
            commits.push((at, lines));
            let login = commit["author"].as_str().map(str::to_string).unwrap_or_else(|| author.clone());
            if !login.is_empty() {
                events.push(event(EventKind::Commit, login, at, lines));
            }
        }
        let mut reviews = 0;
        for review in log["reviews"].as_array().into_iter().flatten() {
            let (Some(login), Some(at)) = (review["author"].as_str(), date(&review["submittedAt"])) else { continue };
            if login != author {
                reviews += 1;
                events.push(event(EventKind::Review, login.to_string(), at, 0));
            }
        }
        let created = date(&core["createdAt"]);
        if let (Some(at), false) = (created, author.is_empty()) {
            events.push(event(EventKind::PrOpened, author.clone(), at, 0));
        }
        let merged = date(&core["mergedAt"]);
        if let Some(at) = merged {
            let by = log["mergedBy"].as_str().map(str::to_string).unwrap_or_else(|| author.clone());
            events.push(event(EventKind::PrMerged, by, at, 0));
        }
        if let Some(created) = created {
            let start = commits.iter().map(|c| c.0).min().map_or(created, |first| first.min(created));
            let closed = date(&log["closedAt"]);
            threads.push(Thread {
                login: author.clone(),
                start,
                end: merged.or(closed),
                merged: merged.is_some(),
                closed: merged.is_none() && closed.is_some(),
                commits,
                reviews,
                repo: repo.clone(),
                number,
                title: title.clone(),
                url: url.clone(),
            });
        }
    }
    let worklog = read(support.join("WorkLog").join(format!("{encoded}.json")));
    for issue in worklog["issues"].as_object().into_iter().flat_map(|m| m.values()) {
        let repo = issue["repo"].as_str().unwrap_or("").to_string();
        if excluded_repos.contains(&repo) {
            continue;
        }
        let base = |kind, login: &str, at| Event {
            kind,
            login: login.to_string(),
            at,
            repo: repo.clone(),
            number: issue["number"].as_i64().unwrap_or(0),
            title: issue["title"].as_str().unwrap_or("").to_string(),
            url: issue["url"].as_str().unwrap_or("").to_string(),
            issue_id: issue["id"].as_str().map(str::to_string),
            lines: 0,
        };
        if let (Some(author), Some(at)) = (issue["author"].as_str(), date(&issue["createdAt"])) {
            events.push(base(EventKind::IssueOpened, author, at));
        }
        for comment in issue["comments"].as_array().into_iter().flatten() {
            if let (Some(author), Some(at)) = (comment["author"].as_str(), date(&comment["createdAt"])) {
                events.push(base(EventKind::IssueComment, author, at));
            }
        }
    }
    Data { people, events, threads }
}

/// Counts by kind over the last 14 days, for checking from a shell.
pub fn print_summary(org: &str) {
    let data = load(org);
    let since = Utc::now() - Duration::days(14);
    let mut counts: std::collections::BTreeMap<&str, usize> = Default::default();
    for event in data.events.iter().filter(|e| e.at >= since) {
        *counts.entry(event.kind.title()).or_default() += 1;
    }
    println!("{} people, {} threads; last 14 days: {counts:?}", data.people.len(), data.threads.len());
}

// MARK: - The page

#[derive(Clone, Copy, PartialEq)]
enum Tab {
    WorkLog,
    Threads,
}

#[derive(Clone, Copy, PartialEq)]
enum Scale {
    Days,
    Weeks,
}

/// A dot or bar clicked: the workspace opens an issue in a drawer, else the
/// PR or issue on GitHub.
pub struct OpenItem {
    pub issue_id: Option<String>,
    pub url: String,
}

impl EventEmitter<OpenItem> for ActivityPage {}

pub struct ActivityPage {
    org: Option<String>,
    data: Option<Data>,
    tab: Tab,
    scale: Scale,
    /// Pages back from now.
    page: i64,
    hidden: BTreeSet<EventKind>,
    repo: Option<String>,
    filter_open: bool,
    generation: u64,
}

const NAME_WIDTH: f32 = 170.;
const COLUMN_WIDTH: f32 = 76.;
const ROW_HEIGHT: f32 = 104.;

fn local_midnight(date: NaiveDate) -> DateTime<Utc> {
    Local.from_local_datetime(&date.and_hms_opt(0, 0, 0).unwrap_or_default()).earliest().map(|t| t.with_timezone(&Utc)).unwrap_or_default()
}

impl ActivityPage {
    pub fn new(org: Option<String>, cx: &mut Context<Self>) -> Self {
        let mut page = Self { org, data: None, tab: Tab::WorkLog, scale: Scale::Days, page: 0, hidden: BTreeSet::new(), repo: None, filter_open: false, generation: 0 };
        page.load(cx);
        page
    }

    pub fn set_org(&mut self, org: Option<String>, cx: &mut Context<Self>) {
        if org != self.org {
            self.org = org;
            self.repo = None;
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
                    page.data = Some(data);
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
    }

    /// The columns shown, oldest first: 14 days or 12 weeks, paged back.
    fn columns(&self) -> Vec<(DateTime<Utc>, DateTime<Utc>, NaiveDate)> {
        let today = Local::now().date_naive();
        match self.scale {
            Scale::Days => (0..14)
                .rev()
                .map(|i| {
                    let day = today - Duration::days(i + self.page * 14);
                    (local_midnight(day), local_midnight(day + Duration::days(1)), day)
                })
                .collect(),
            Scale::Weeks => {
                let monday = today - Duration::days(today.weekday().num_days_from_monday() as i64);
                (0..12)
                    .rev()
                    .map(|i| {
                        let week = monday - Duration::days(7 * (i + self.page * 12));
                        (local_midnight(week), local_midnight(week + Duration::days(7)), week)
                    })
                    .collect()
            }
        }
    }

    fn shows(&self, event: &Event) -> bool {
        !self.hidden.contains(&event.kind) && self.repo.as_ref().is_none_or(|r| *r == event.repo)
    }

    fn chip(id: SharedString, label: String, on: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
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
        let columns = self.columns();
        let (first, last) = (columns[0].2, columns[columns.len() - 1].2);
        let last_day = if self.scale == Scale::Weeks { last + Duration::days(6) } else { last };
        let range = if first.month() == last_day.month() {
            format!("{} - {}", first.format("%-d"), last_day.format("%-d %b"))
        } else {
            format!("{} - {}", first.format("%-d %b"), last_day.format("%-d %b"))
        };
        let group = |children: Vec<gpui::AnyElement>| div().p_0p5().flex().flex_row().gap_0p5().rounded_md().bg(theme.tile).children(children);
        let tabs = vec![
            Self::chip("tab-work-log".into(), "Work log".into(), self.tab == Tab::WorkLog, theme)
                .on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                    page.tab = Tab::WorkLog;
                    cx.notify();
                }))
                .into_any_element(),
            Self::chip("tab-threads".into(), "Threads".into(), self.tab == Tab::Threads, theme)
                .on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                    page.tab = Tab::Threads;
                    cx.notify();
                }))
                .into_any_element(),
        ];
        let scales = vec![
            Self::chip("scale-days".into(), "Days".into(), self.scale == Scale::Days, theme)
                .on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                    page.scale = Scale::Days;
                    page.page = 0;
                    cx.notify();
                }))
                .into_any_element(),
            Self::chip("scale-weeks".into(), "Weeks".into(), self.scale == Scale::Weeks, theme)
                .on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                    page.scale = Scale::Weeks;
                    page.page = 0;
                    cx.notify();
                }))
                .into_any_element(),
        ];
        // Up to a year back, as Gannin pages.
        let can_go_back = (Utc::now() - columns[0].0).num_days() < 365;
        let paging = vec![
            Self::chip("earlier".into(), "‹ Earlier".into(), false, theme)
                .when(!can_go_back, |d| d.opacity(0.4))
                .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                    if can_go_back {
                        page.page += 1;
                        cx.notify();
                    }
                }))
                .into_any_element(),
            Self::chip("today".into(), "Today".into(), false, theme)
                .when(self.page == 0, |d| d.opacity(0.4))
                .on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                    page.page = 0;
                    cx.notify();
                }))
                .into_any_element(),
            Self::chip("later".into(), "Later ›".into(), false, theme)
                .when(self.page == 0, |d| d.opacity(0.4))
                .on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                    page.page = (page.page - 1).max(0);
                    cx.notify();
                }))
                .into_any_element(),
        ];
        let filtered = !self.hidden.is_empty() || self.repo.is_some();
        let mut repos: Vec<String> = data.events.iter().map(|e| e.repo.clone()).collect::<BTreeSet<_>>().into_iter().collect();
        repos.sort_by_key(|r| r.to_lowercase());
        div()
            .flex_none()
            .flex()
            .flex_col()
            .gap_2()
            .px_4()
            .py_3()
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .child(group(tabs))
                    .child(div().text_color(theme.secondary).child(range))
                    .child(group(scales))
                    .child(div().flex_1())
                    .when(self.tab == Tab::WorkLog, |d| {
                        d.child(
                            Self::chip("filter".into(), if filtered { "Filter ●".into() } else { "Filter".into() }, self.filter_open, theme)
                                .border_1()
                                .border_color(if filtered { theme.selected } else { theme.border })
                                .on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                                    page.filter_open = !page.filter_open;
                                    cx.notify();
                                })),
                        )
                    })
                    .child(group(paging)),
            )
            .when(self.filter_open && self.tab == Tab::WorkLog, |d| {
                d.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .p_2()
                        .rounded_md()
                        .border_1()
                        .border_color(theme.border)
                        .child(div().text_xs().text_color(theme.secondary).child("Show"))
                        .child(div().flex().flex_row().flex_wrap().gap_1().children(EventKind::ALL.into_iter().map(|kind| {
                            let on = !self.hidden.contains(&kind);
                            Self::chip(SharedString::from(format!("kind-{}", kind.title())), format!("{} {}", if on { "✓" } else { " " }, kind.title()), on, theme)
                                .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                                    if !page.hidden.remove(&kind) {
                                        page.hidden.insert(kind);
                                    }
                                    cx.notify();
                                }))
                        })))
                        .child(div().text_xs().text_color(theme.secondary).child("Repository"))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .flex_wrap()
                                .gap_1()
                                .child(Self::chip("repo-all".into(), "All Repositories".into(), self.repo.is_none(), theme).on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                                    page.repo = None;
                                    cx.notify();
                                })))
                                .children(repos.into_iter().enumerate().map(|(i, repo)| {
                                    let on = self.repo.as_deref() == Some(repo.as_str());
                                    let short = repo.rsplit('/').next().unwrap_or(&repo).to_string();
                                    Self::chip(SharedString::from(format!("repo-{i}")), short, on, theme).on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                                        page.repo = Some(repo.clone());
                                        cx.notify();
                                    }))
                                })),
                        ),
                )
            })
    }

    fn work_log(&self, data: &Data, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let columns = self.columns();
        let (from, to) = (columns[0].0, columns[columns.len() - 1].1);
        // Events by person and column.
        let mut cells: HashMap<(&str, usize), Vec<&Event>> = HashMap::new();
        for event in data.events.iter().filter(|e| e.at >= from && e.at < to && self.shows(e)) {
            if let Some(column) = columns.iter().position(|(start, end, _)| event.at >= *start && event.at < *end) {
                cells.entry((event.login.as_str(), column)).or_default().push(event);
            }
        }
        let header = div()
            .flex()
            .flex_row()
            .border_b_1()
            .border_color(theme.border)
            .child(div().w(px(NAME_WIDTH)).flex_none())
            .children(columns.iter().map(|(_, _, day)| {
                let (big, small) = match self.scale {
                    Scale::Days => (day.format("%-d").to_string(), day.format("%a").to_string().to_uppercase()),
                    Scale::Weeks => (day.format("%-d").to_string(), day.format("%b").to_string().to_uppercase()),
                };
                div()
                    .w(px(COLUMN_WIDTH))
                    .flex_none()
                    .py_1()
                    .flex()
                    .flex_col()
                    .items_center()
                    .child(div().text_lg().child(big))
                    .child(div().text_xs().text_color(theme.secondary).child(small))
            }));
        let rows = data.people.iter().enumerate().map(|(row, person)| {
            div()
                .h(px(ROW_HEIGHT))
                .flex()
                .flex_row()
                .border_b_1()
                .border_color(theme.grid)
                .child(
                    div()
                        .w(px(NAME_WIDTH))
                        .flex_none()
                        .px_2()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(avatar(&person.login, person.avatar.as_deref(), 22., theme, cx))
                        .child(div().truncate().child(person.name.clone())),
                )
                .children((0..columns.len()).map(|column| {
                    let mut events = cells.get(&(person.login.as_str(), column)).cloned().unwrap_or_default();
                    // Biggest first, spiralling out (golden angle).
                    events.sort_by(|a, b| b.radius().partial_cmp(&a.radius()).unwrap_or(std::cmp::Ordering::Equal));
                    let mut placed: Vec<(f32, f32, f32, &Event)> = Vec::new();
                    for (i, event) in events.iter().enumerate() {
                        let angle = i as f32 * 2.399_963;
                        let distance = 1.6 * (i as f32).sqrt() * 6.;
                        placed.push((distance * angle.cos(), distance * angle.sin(), event.radius(), event));
                    }
                    let extent = placed.iter().map(|(x, y, r, _)| (x * x + y * y).sqrt() + r).fold(0f32, f32::max);
                    let room = (COLUMN_WIDTH.min(ROW_HEIGHT) / 2.) - 6.;
                    let scale = if extent > room { room / extent } else { 1. };
                    div()
                        .w(px(COLUMN_WIDTH))
                        .h_full()
                        .flex_none()
                        .relative()
                        .children(placed.into_iter().enumerate().map(|(i, (x, y, r, event))| {
                            let size = (r * 2. * scale).max(3.);
                            let left = COLUMN_WIDTH / 2. + x * scale - size / 2.;
                            let top = ROW_HEIGHT / 2. + y * scale - size / 2.;
                            let tip = format!(
                                "{} · {}#{} {}{} · {}",
                                event.kind.title(),
                                event.repo.rsplit('/').next().unwrap_or(&event.repo),
                                event.number,
                                event.title,
                                if event.kind == EventKind::Commit { format!(" · {} lines", event.lines) } else { String::new() },
                                event.at.with_timezone(&Local).format("%a %-d %b, %H:%M")
                            );
                            let open = OpenItem { issue_id: event.issue_id.clone(), url: event.url.clone() };
                            div()
                                .id(SharedString::from(format!("dot-{row}-{column}-{i}")))
                                .absolute()
                                .left(px(left))
                                .top(px(top))
                                .size(px(size))
                                .rounded_full()
                                .bg(event.kind.color(theme))
                                .cursor_pointer()
                                .hover(|s| s.opacity(0.7))
                                .tooltip(move |_, cx| cx.new(|_| Tooltip(tip.clone())).into())
                                .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| {
                                    cx.emit(OpenItem { issue_id: open.issue_id.clone(), url: open.url.clone() })
                                }))
                        }))
                }))
        });
        let legend = div()
            .flex()
            .flex_row()
            .flex_wrap()
            .items_center()
            .gap_3()
            .pt_3()
            .children(EventKind::ALL.into_iter().filter(|k| !self.hidden.contains(k)).map(|kind| {
                div().flex().flex_row().items_center().gap_1().child(div().size(px(9.)).rounded_full().bg(kind.color(theme))).child(div().text_xs().child(kind.title()))
            }))
            .child(div().text_xs().text_color(theme.secondary).child("Commit dots grow with lines changed. Hover a dot for detail, click to open its PR or issue."));
        div().flex().flex_col().child(header).children(rows).child(legend)
    }

    fn threads(&self, data: &Data, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let columns = self.columns();
        let (from, to) = (columns[0].0, columns[columns.len() - 1].1);
        let now = Utc::now();
        let width = COLUMN_WIDTH * columns.len() as f32;
        let span = (to - from).num_seconds().max(1) as f32;
        let x = |t: DateTime<Utc>| ((t - from).num_seconds() as f32 / span * width).clamp(0., width);
        let lanes = data.people.iter().enumerate().map(|(lane, person)| {
            let mut bars: Vec<&Thread> = data.threads.iter().filter(|t| t.login == person.login && t.start < to && t.end.unwrap_or(now) >= from).collect();
            bars.sort_by_key(|t| t.start);
            // Rows, packed greedily by start.
            let mut rows: Vec<f32> = Vec::new();
            let mut placed = Vec::new();
            for bar in &bars {
                let (left, right) = (x(bar.start), x(bar.end.unwrap_or(now)).max(x(bar.start) + 4.));
                let row = rows.iter().position(|end| *end + width * 0.01 <= left).unwrap_or_else(|| {
                    rows.push(0.);
                    rows.len() - 1
                });
                rows[row] = right;
                placed.push((row, left, right, *bar));
            }
            let reviews = data.events.iter().filter(|e| e.login == person.login && e.kind == EventKind::Review && e.at >= from && e.at < to).count();
            let height = (rows.len().max(1) as f32) * 18. + 8.;
            div()
                .flex()
                .flex_row()
                .border_b_1()
                .border_color(theme.grid)
                .child(
                    div()
                        .w(px(NAME_WIDTH))
                        .flex_none()
                        .px_2()
                        .py_1()
                        .flex()
                        .flex_col()
                        .child(div().flex().flex_row().items_center().gap_2().child(avatar(&person.login, person.avatar.as_deref(), 22., theme, cx)).child(div().truncate().child(person.name.clone())))
                        .child(div().text_xs().text_color(theme.secondary).child(format!("{} PRs · {reviews} reviews", bars.len()))),
                )
                .child(div().w(px(width)).h(px(height)).flex_none().relative().children(placed.into_iter().enumerate().map(|(i, (row, left, right, bar))| {
                    let tint = if bar.closed { theme.neutral() } else { EventKind::PrOpened.color(theme) };
                    let tip = format!(
                        "{}#{} {}\nStarted {}{}\n{} commits · {} reviews",
                        bar.repo.rsplit('/').next().unwrap_or(&bar.repo),
                        bar.number,
                        bar.title,
                        bar.start.with_timezone(&Local).format("%-d %b"),
                        match (bar.merged, bar.end) {
                            (true, Some(end)) => format!(", merged {}", end.with_timezone(&Local).format("%-d %b")),
                            (false, Some(end)) => format!(", closed {}", end.with_timezone(&Local).format("%-d %b")),
                            _ => ", open".into(),
                        },
                        bar.commits.len(),
                        bar.reviews
                    );
                    let url = bar.url.clone();
                    div()
                        .id(SharedString::from(format!("bar-{lane}-{i}")))
                        .absolute()
                        .left(px(left))
                        .top(px(4. + row as f32 * 18.))
                        .w(px(right - left))
                        .h(px(12.))
                        .rounded_full()
                        .bg(tint.opacity(0.35))
                        .border_1()
                        .border_color(tint)
                        .cursor_pointer()
                        .tooltip(move |_, cx| cx.new(|_| Tooltip(tip.clone())).into())
                        .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(OpenItem { issue_id: None, url: url.clone() })))
                        .children(bar.commits.iter().filter(|(at, _)| *at >= from && *at < to).map(|(at, _)| {
                            div().absolute().left(px(x(*at) - left - 2.)).top(px(3.)).size(px(4.)).rounded_full().bg(EventKind::Commit.color(theme))
                        }))
                })))
        });
        div()
            .flex()
            .flex_col()
            .children(lanes)
            .child(div().pt_3().text_xs().text_color(theme.secondary).child("Bars are PRs they opened, from first commit to merge, or to now while open. Dots on a bar are its commits."))
    }
}

impl Render for ActivityPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let Some(data) = self.data.clone() else {
            return div().size_full().p_4().bg(theme.bg).text_color(theme.secondary).child("Loading recent activity").into_any_element();
        };
        let body = if data.people.is_empty() {
            div().p_4().text_color(theme.secondary).child("No members in Gannin's snapshot of this org yet.").into_any_element()
        } else {
            match self.tab {
                Tab::WorkLog => self.work_log(&data, &theme, cx).into_any_element(),
                Tab::Threads => self.threads(&data, &theme, cx).into_any_element(),
            }
        };
        div()
            .id("activity")
            .size_full()
            .flex()
            .flex_col()
            .overflow_y_scroll()
            .bg(theme.bg)
            .font_weight(FontWeight::NORMAL)
            .child(self.toolbar(&data, &theme, cx))
            .child(div().id("activity-body").overflow_x_scroll().px_4().pb_4().child(body))
            .into_any_element()
    }
}
