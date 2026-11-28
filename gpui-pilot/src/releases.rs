//! Releases, after Gannin's `ReleasesView`: the org's GitHub Releases, with
//! downloads and stars over time, the repos with releases, every release
//! (each linked to the milestone it shipped) and their stargazers, for every
//! repo or one; and its milestones, grouped by title across repos, with
//! GitHub's progress and what the issue history says is in progress and
//! merged. A release or milestone opens out in place rather than on a page
//! of its own.
//!
//! The data is the pilot's own, fetched as Gannin's `ReleaseStore` fetches
//! it and kept in the same format beside the other caches. Read-only: it
//! never writes to GitHub. The download history is Gannin's own record (
//! GitHub keeps only running totals), so it lives in `~/.gannin`, outside
//! the caches, and nothing clears it.

use crate::charts::Theme;
use crate::issues::Tooltip;
use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, TimeZone, Utc};
use gpui::{
    canvas, div, fill, point, prelude::*, px, relative, size, AnyElement, Bounds, ClickEvent, Context, Entity, EventEmitter, FontWeight,
    Hsla, MouseMoveEvent, PathBuilder, Pixels, SharedString, Subscription, Window,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::rc::Rc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

// MARK: - Data

const VERSION: i64 = 4;
const DOWNLOADS_VERSION: i64 = 1;
/// Repos not pushed to for this long are left out.
const QUIET_REACH_DAYS: i64 = 365;
/// A star history's backfill stops after this many stars, the older ones
/// counted at its start.
pub const STAR_REACH: usize = 10_000;
const CONCURRENCY: usize = 4;
/// Fetched again once the copy is this old, or on Refresh.
const EVERY: Duration = Duration::hours(1);
/// "Lately": the last 30 days.
const LATELY_DAYS: i64 = 30;
/// New stars go by week until the history runs longer than this, then by month.
const WEEKLY_REACH_DAYS: i64 = 182;
/// Release marks on the stars line past this many would hide it.
const RELEASE_MARK_LIMIT: usize = 30;
/// The tables list at most this many rows.
const ROW_LIMIT: usize = 300;
const STARGAZER_LIMIT: usize = 500;

/// A repo's milestone, with GitHub's own counts of its issues and pull
/// requests, which its progress counts together.
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Milestone {
    pub id: String,
    pub repo: String,
    pub number: i64,
    pub title: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub due_on: Option<DateTime<Utc>>,
    pub is_open: bool,
    #[serde(default)]
    pub closed_at: Option<DateTime<Utc>>,
    pub updated_at: DateTime<Utc>,
    pub url: String,
    pub open_issues: i64,
    pub closed_issues: i64,
    pub open_pull_requests: i64,
    /// Merged ones too.
    pub closed_pull_requests: i64,
}

impl Milestone {
    fn closed(&self) -> i64 {
        self.closed_issues + self.closed_pull_requests
    }
    fn total(&self) -> i64 {
        self.open_issues + self.open_pull_requests + self.closed()
    }
}

/// A file attached to a release, with GitHub's running count of its downloads.
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Asset {
    pub name: String,
    pub download_count: i64,
    pub size: i64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Release {
    pub id: String,
    pub repo: String,
    #[serde(default)]
    pub name: Option<String>,
    pub tag_name: String,
    pub url: String,
    pub created_at: DateTime<Utc>,
    /// None for a draft.
    #[serde(default)]
    pub published_at: Option<DateTime<Utc>>,
    pub is_draft: bool,
    pub is_prerelease: bool,
    pub is_latest: bool,
    #[serde(default)]
    pub author: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub assets: Vec<Asset>,
}

impl Release {
    pub fn downloads(&self) -> i64 {
        self.assets.iter().map(|a| a.download_count).sum()
    }

    /// Its name, else its tag.
    pub fn title(&self) -> &str {
        self.name.as_deref().map(str::trim).filter(|n| !n.is_empty()).unwrap_or(&self.tag_name)
    }

    pub fn date(&self) -> DateTime<Utc> {
        self.published_at.unwrap_or(self.created_at)
    }
}

/// A repo with releases: its stars now, and how many releases GitHub says it has.
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Repository {
    pub name: String,
    pub stars: i64,
    pub release_count: i64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct History {
    pub version: i64,
    pub org_login: String,
    pub synced_at: DateTime<Utc>,
    pub milestones: Vec<Milestone>,
    pub releases: Vec<Release>,
    /// Repos with at least one release.
    pub repositories: Vec<Repository>,
    /// By repo.
    #[serde(default)]
    pub stars: BTreeMap<String, StarHistory>,
}

/// When a repo's current stargazers starred it, as stars per day, and who
/// they are. Those who unstarred are gone from it.
#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct StarHistory {
    /// Stars a day, by the day's start, oldest first.
    pub days: Vec<StarDay>,
    /// The latest star counted, where the next fetch stops.
    #[serde(default)]
    pub newest: Option<DateTime<Utc>>,
    /// Stars older than the backfill reached, counted before the first day.
    #[serde(default)]
    pub before: i64,
    /// Newest first, as far as the backfill reached.
    #[serde(default)]
    pub stargazers: Vec<Stargazer>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct StarDay {
    pub day: DateTime<Utc>,
    pub count: i64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Stargazer {
    pub login: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default, rename = "avatarURL")]
    pub avatar_url: Option<String>,
    #[serde(default)]
    pub company: Option<String>,
    #[serde(default)]
    pub location: Option<String>,
    #[serde(default)]
    pub followers: i64,
    pub starred_at: DateTime<Utc>,
}

fn local_midnight(date: NaiveDate) -> DateTime<Utc> {
    Local.from_local_datetime(&date.and_hms_opt(0, 0, 0).unwrap_or_default()).earliest().map(|t| t.with_timezone(&Utc)).unwrap_or_default()
}

fn local_day(time: DateTime<Utc>) -> NaiveDate {
    time.with_timezone(&Local).date_naive()
}

impl StarHistory {
    /// Adds stars (any order) to their days, and the stargazers among them,
    /// one each, the latest star winning.
    fn add(&mut self, dates: &[DateTime<Utc>], new: Vec<Stargazer>) {
        let Some(latest) = dates.iter().max().copied() else { return };
        let mut counts: BTreeMap<DateTime<Utc>, i64> = BTreeMap::new();
        for day in &self.days {
            *counts.entry(day.day).or_default() += day.count;
        }
        for date in dates {
            *counts.entry(local_midnight(local_day(*date))).or_default() += 1;
        }
        self.days = counts.into_iter().map(|(day, count)| StarDay { day, count }).collect();
        self.newest = Some(self.newest.map_or(latest, |n| n.max(latest)));
        let mut all = new;
        all.append(&mut self.stargazers);
        all.sort_by(|a, b| b.starred_at.cmp(&a.starred_at));
        let mut seen = HashSet::new();
        all.retain(|s| seen.insert(s.login.clone()));
        all.truncate(STAR_REACH);
        self.stargazers = all;
    }

    fn gained(&self, since: DateTime<Utc>) -> i64 {
        self.days.iter().filter(|d| d.day >= since).map(|d| d.count).sum()
    }
}

/// Download totals recorded once a day, oldest first.
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct DownloadHistory {
    pub version: i64,
    pub org_login: String,
    pub snapshots: Vec<Snapshot>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Snapshot {
    pub day: DateTime<Utc>,
    /// Downloads by repo.
    pub repos: BTreeMap<String, i64>,
}

impl Snapshot {
    fn total(&self, included: &dyn Fn(&str) -> bool) -> i64 {
        self.repos.iter().filter(|(repo, _)| included(repo)).map(|(_, n)| n).sum()
    }
}

impl DownloadHistory {
    /// Records the totals as the day's, replacing any recorded earlier that day.
    fn record(&mut self, totals: BTreeMap<String, i64>, at: DateTime<Utc>) {
        let day = local_midnight(local_day(at));
        self.snapshots.retain(|s| s.day != day);
        self.snapshots.push(Snapshot { day, repos: totals });
        self.snapshots.sort_by_key(|s| s.day);
    }
}

// MARK: - Storage

fn history_path(org: &str) -> std::path::PathBuf {
    crate::cache::path(crate::cache::Kind::Releases, org)
}

/// Outside the caches: it can't be fetched again.
fn downloads_path(org: &str) -> std::path::PathBuf {
    crate::paths::app_dir().join("ReleaseDownloads").join(crate::cache::file_name(org))
}

fn read_history(org: &str) -> Option<History> {
    let bytes = std::fs::read(history_path(org)).ok()?;
    serde_json::from_slice::<History>(&bytes).ok().filter(|h| h.version == VERSION)
}

fn read_downloads(org: &str) -> Option<DownloadHistory> {
    let bytes = std::fs::read(downloads_path(org)).ok()?;
    serde_json::from_slice::<DownloadHistory>(&bytes).ok().filter(|h| h.version == DOWNLOADS_VERSION)
}

fn write_atomic(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(folder) = path.parent() {
        std::fs::create_dir_all(folder)?;
    }
    let partial = path.with_extension("json.part");
    std::fs::write(&partial, bytes)?;
    std::fs::rename(&partial, path)
}

fn record_downloads(history: &History, at: DateTime<Utc>) {
    let mut downloads = read_downloads(&history.org_login).unwrap_or(DownloadHistory { version: DOWNLOADS_VERSION, org_login: history.org_login.clone(), snapshots: Vec::new() });
    let mut totals: BTreeMap<String, i64> = BTreeMap::new();
    for release in &history.releases {
        *totals.entry(release.repo.clone()).or_default() += release.downloads();
    }
    downloads.record(totals, at);
    if let Ok(bytes) = serde_json::to_vec(&downloads) {
        let _ = write_atomic(&downloads_path(&history.org_login), &bytes);
    }
}

/// The org's excluded repos, lowercased: all of them, and those also left
/// unfetched (excluded and named by no project).
fn exclusions(org: &str) -> (HashSet<String>, HashSet<String>) {
    let config = crate::projects::effective_config(org);
    let named: HashSet<String> = crate::projects::load(org).projects.into_iter().flat_map(|p| p.repos).map(|r| r.to_lowercase()).collect();
    let excluded: HashSet<String> = config["excludedRepos"].as_array().into_iter().flatten().filter_map(|r| r.as_str()).map(str::to_lowercase).collect();
    let unfetched = excluded.iter().filter(|r| !named.contains(*r)).cloned().collect();
    (excluded, unfetched)
}

// MARK: - Fetching

fn date(v: &Value) -> Option<DateTime<Utc>> {
    v.as_str()?.parse().ok()
}

fn text(v: &Value) -> Option<String> {
    v.as_str().map(str::to_string)
}

fn nodes(v: &Value) -> &[Value] {
    v["nodes"].as_array().map(Vec::as_slice).unwrap_or(&[])
}

const RELEASE_FIELDS: &str = "pageInfo { hasNextPage endCursor } totalCount nodes { id name tagName url createdAt publishedAt isDraft isPrerelease isLatest author { login } description releaseAssets(first: 50) { nodes { name downloadCount size } } }";
const MILESTONE_FIELDS: &str = "nodes { id number title description dueOn state closedAt updatedAt url openIssues: issues(states: [OPEN]) { totalCount } closedIssues: issues(states: [CLOSED]) { totalCount } openPullRequests: pullRequests(states: [OPEN]) { totalCount } closedPullRequests: pullRequests(states: [CLOSED, MERGED]) { totalCount } }";

fn parse_releases(connection: &Value, repo: &str) -> Vec<Release> {
    nodes(connection)
        .iter()
        .filter_map(|r| {
            Some(Release {
                id: text(&r["id"])?,
                repo: repo.to_string(),
                name: text(&r["name"]),
                tag_name: text(&r["tagName"])?,
                url: text(&r["url"])?,
                created_at: date(&r["createdAt"])?,
                published_at: date(&r["publishedAt"]),
                is_draft: r["isDraft"].as_bool().unwrap_or(false),
                is_prerelease: r["isPrerelease"].as_bool().unwrap_or(false),
                is_latest: r["isLatest"].as_bool().unwrap_or(false),
                author: text(&r["author"]["login"]),
                notes: text(&r["description"]),
                assets: nodes(&r["releaseAssets"])
                    .iter()
                    .filter_map(|a| Some(Asset { name: text(&a["name"])?, download_count: a["downloadCount"].as_i64().unwrap_or(0), size: a["size"].as_i64().unwrap_or(0) }))
                    .collect(),
            })
        })
        .collect()
}

fn parse_milestone(m: &Value, repo: &str) -> Option<Milestone> {
    let count = |key: &str| m[key]["totalCount"].as_i64().unwrap_or(0);
    Some(Milestone {
        id: text(&m["id"])?,
        repo: repo.to_string(),
        number: m["number"].as_i64()?,
        title: text(&m["title"])?,
        description: text(&m["description"]),
        due_on: date(&m["dueOn"]),
        is_open: m["state"] == "OPEN",
        closed_at: date(&m["closedAt"]),
        updated_at: date(&m["updatedAt"])?,
        url: text(&m["url"])?,
        open_issues: count("openIssues"),
        closed_issues: count("closedIssues"),
        open_pull_requests: count("openPullRequests"),
        closed_pull_requests: count("closedPullRequests"),
    })
}

/// Runs `work` for each item, a few at once, results in the items' order.
fn each<T: Sync, R: Send>(items: &[T], work: impl Fn(&T) -> R + Sync) -> Vec<R> {
    let next = AtomicUsize::new(0);
    let results: Mutex<Vec<Option<R>>> = Mutex::new((0..items.len()).map(|_| None).collect());
    std::thread::scope(|threads| {
        for _ in 0..CONCURRENCY.min(items.len()) {
            threads.spawn(|| loop {
                let i = next.fetch_add(1, Ordering::Relaxed);
                let Some(item) = items.get(i) else { break };
                let result = work(item);
                if let Ok(mut results) = results.lock() {
                    results[i] = Some(result);
                }
            });
        }
    });
    results.into_inner().unwrap_or_default().into_iter().flatten().collect()
}

fn split(repo: &str) -> (&str, &str) {
    repo.split_once('/').unwrap_or((repo, repo))
}

/// A repo's releases after `cursor`, to the end.
fn older_releases(token: &str, repo: &str, cursor: &str) -> Result<Vec<Release>, String> {
    let (owner, name) = split(repo);
    let query = format!("query($owner: String!, $name: String!, $cursor: String) {{ repository(owner: $owner, name: $name) {{ releases(first: 50, after: $cursor, orderBy: {{ field: CREATED_AT, direction: DESC }}) {{ {RELEASE_FIELDS} }} }} }}");
    let mut after = cursor.to_string();
    let mut releases = Vec::new();
    loop {
        let data = crate::github::graphql(token, &query, json!({ "owner": owner, "name": name, "cursor": after })).map_err(|e| e.to_string())?;
        let page = &data["repository"]["releases"];
        if page.is_null() {
            break;
        }
        releases.extend(parse_releases(page, repo));
        match (page["pageInfo"]["hasNextPage"].as_bool(), page["pageInfo"]["endCursor"].as_str()) {
            (Some(true), Some(next)) => after = next.to_string(),
            _ => break,
        }
    }
    Ok(releases)
}

/// When a repo's stargazers starred it, newest first, and who they are,
/// stopping at the first at or before `since` or after `limit`. The flag is
/// false when the limit cut it short.
fn stargazers(token: &str, repo: &str, since: Option<DateTime<Utc>>, limit: usize) -> Result<(Vec<DateTime<Utc>>, Vec<Stargazer>, bool), String> {
    let (owner, name) = split(repo);
    let query = "query($owner: String!, $name: String!, $cursor: String) { repository(owner: $owner, name: $name) { stargazers(first: 100, after: $cursor, orderBy: { field: STARRED_AT, direction: DESC }) { pageInfo { hasNextPage endCursor } edges { starredAt node { login name avatarUrl(size: 64) company location followers { totalCount } } } } } }";
    let mut dates = Vec::new();
    let mut people = Vec::new();
    let mut cursor: Option<String> = None;
    while dates.len() < limit {
        let data = crate::github::graphql(token, query, json!({ "owner": owner, "name": name, "cursor": cursor })).map_err(|e| e.to_string())?;
        let page = &data["repository"]["stargazers"];
        let Some(edges) = page["edges"].as_array() else { return Ok((dates, people, true)) };
        for edge in edges {
            let Some(at) = date(&edge["starredAt"]) else { continue };
            if since.is_some_and(|since| at <= since) {
                return Ok((dates, people, true));
            }
            dates.push(at);
            let user = &edge["node"];
            // An account GitHub won't describe still counts as a star.
            if let Some(login) = text(&user["login"]) {
                people.push(Stargazer {
                    login,
                    name: text(&user["name"]),
                    avatar_url: text(&user["avatarUrl"]),
                    company: text(&user["company"]),
                    location: text(&user["location"]),
                    followers: user["followers"]["totalCount"].as_i64().unwrap_or(0),
                    starred_at: at,
                });
            }
        }
        match (page["pageInfo"]["hasNextPage"].as_bool(), page["pageInfo"]["endCursor"].as_str()) {
            (Some(true), Some(next)) => cursor = Some(next.to_string()),
            _ => return Ok((dates, people, true)),
        }
    }
    Ok((dates, people, false))
}

/// A repo's star history: new stars on top of `previous`, else a backfill
/// to its first star or `STAR_REACH`, the stars beyond counted at the start.
fn star_history(token: &str, repo: &Repository, previous: Option<&StarHistory>) -> Result<StarHistory, String> {
    if let Some(previous) = previous.filter(|h| h.newest.is_some()) {
        let mut history = previous.clone();
        let (dates, people, _) = stargazers(token, &repo.name, history.newest, STAR_REACH)?;
        history.add(&dates, people);
        return Ok(history);
    }
    let (dates, people, reached_end) = stargazers(token, &repo.name, None, STAR_REACH)?;
    let mut history = StarHistory::default();
    history.add(&dates, people);
    if !reached_end {
        history.before = (repo.stars - dates.len() as i64).max(0);
    }
    Ok(history)
}

static SYNCING: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Fetches the org's milestones, every release and the stars of repos with
/// releases, when the copy is older than `EVERY` or `force`d, and records
/// the day's downloads. True when it fetched.
pub fn sync(org: &str, force: bool) -> Result<bool, String> {
    {
        let mut syncing = SYNCING.lock().map_err(|_| "busy")?;
        if syncing.iter().any(|o| o == org) {
            return Ok(false);
        }
        syncing.push(org.to_string());
    }
    struct Done(String);
    impl Drop for Done {
        fn drop(&mut self) {
            if let Ok(mut syncing) = SYNCING.lock() {
                syncing.retain(|o| o != &self.0);
            }
        }
    }
    let _done = Done(org.to_string());
    let token = crate::auth::token().ok_or("Sign in to fetch releases.")?;
    let held = read_history(org);
    let now = Utc::now();
    if !force && held.as_ref().is_some_and(|h| now - h.synced_at < EVERY) {
        return Ok(false);
    }
    if !force && held.is_some() && crate::github::should_hold_off() {
        return Ok(false);
    }
    let (_, unfetched) = exclusions(org);
    let since = now - Duration::days(QUIET_REACH_DAYS);
    let query = format!(
        "query($login: String!, $cursor: String) {{ repositoryOwner(login: $login) {{ repositories(first: 25, after: $cursor, isArchived: false, ownerAffiliations: [OWNER], orderBy: {{ field: PUSHED_AT, direction: DESC }}) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ nameWithOwner pushedAt stargazerCount openMilestones: milestones(first: 25, states: [OPEN], orderBy: {{ field: DUE_DATE, direction: ASC }}) {{ {MILESTONE_FIELDS} }} closedMilestones: milestones(first: 10, states: [CLOSED], orderBy: {{ field: UPDATED_AT, direction: DESC }}) {{ {MILESTONE_FIELDS} }} releases(first: 25, orderBy: {{ field: CREATED_AT, direction: DESC }}) {{ {RELEASE_FIELDS} }} }} }} }} }}"
    );
    let mut repos: Vec<Value> = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let data = crate::github::graphql(&token, &query, json!({ "login": org, "cursor": cursor })).map_err(|e| e.to_string())?;
        let connection = &data["repositoryOwner"]["repositories"];
        let page = nodes(connection).to_vec();
        let reached_older = page.last().is_some_and(|r| date(&r["pushedAt"]).is_none_or(|p| p < since));
        repos.extend(page);
        if reached_older || repos.len() >= 1000 {
            break;
        }
        match (connection["pageInfo"]["hasNextPage"].as_bool(), connection["pageInfo"]["endCursor"].as_str()) {
            (Some(true), Some(next)) => cursor = Some(next.to_string()),
            _ => break,
        }
    }
    repos.retain(|r| date(&r["pushedAt"]).is_some_and(|p| p >= since) && r["nameWithOwner"].as_str().is_some_and(|n| !unfetched.contains(&n.to_lowercase())));

    let mut milestones = Vec::new();
    let mut releases = Vec::new();
    let mut repositories = Vec::new();
    let mut more: Vec<(String, String)> = Vec::new();
    for repo in &repos {
        let Some(name) = repo["nameWithOwner"].as_str() else { continue };
        for key in ["openMilestones", "closedMilestones"] {
            milestones.extend(nodes(&repo[key]).iter().filter_map(|m| parse_milestone(m, name)));
        }
        let page = &repo["releases"];
        releases.extend(parse_releases(page, name));
        let total = page["totalCount"].as_i64().unwrap_or(0);
        if total > 0 {
            repositories.push(Repository { name: name.to_string(), stars: repo["stargazerCount"].as_i64().unwrap_or(0), release_count: total });
        }
        if let (Some(true), Some(next)) = (page["pageInfo"]["hasNextPage"].as_bool(), page["pageInfo"]["endCursor"].as_str()) {
            more.push((name.to_string(), next.to_string()));
        }
    }
    for older in each(&more, |(repo, cursor)| older_releases(&token, repo, cursor)) {
        releases.extend(older?);
    }
    // A repo whose stars can't be read keeps what it had.
    let previous = held.map(|h| h.stars).unwrap_or_default();
    let stars: BTreeMap<String, StarHistory> = repositories
        .iter()
        .zip(each(&repositories, |repo| star_history(&token, repo, previous.get(&repo.name)).ok().or_else(|| previous.get(&repo.name).cloned())))
        .filter_map(|(repo, history)| history.map(|h| (repo.name.clone(), h)))
        .collect();
    let history = History { version: VERSION, org_login: org.to_string(), synced_at: now, milestones, releases, repositories, stars };
    let bytes = serde_json::to_vec(&history).map_err(|e| e.to_string())?;
    crate::cache::write(crate::cache::Kind::Releases, org, &bytes).map_err(|e| e.to_string())?;
    record_downloads(&history, now);
    Ok(true)
}

// MARK: - Milestones

/// Milestones with the same title (case aside) across repos, as one.
#[derive(Clone)]
struct Group {
    key: String,
    title: String,
    /// By repo.
    milestones: Vec<Milestone>,
}

fn milestone_key(title: &str) -> String {
    title.trim().to_lowercase()
}

impl Group {
    fn repos(&self) -> impl Iterator<Item = &str> {
        self.milestones.iter().map(|m| m.repo.as_str())
    }
    fn is_open(&self) -> bool {
        self.milestones.iter().any(|m| m.is_open)
    }
    fn closed(&self) -> i64 {
        self.milestones.iter().map(Milestone::closed).sum()
    }
    fn total(&self) -> i64 {
        self.milestones.iter().map(Milestone::total).sum()
    }
    /// Issues alone, which is all the issue history holds.
    fn issue_total(&self) -> i64 {
        self.milestones.iter().map(|m| m.open_issues + m.closed_issues).sum()
    }
    /// The soonest due among the open ones, else the latest.
    fn due_on(&self) -> Option<DateTime<Utc>> {
        self.milestones.iter().filter(|m| m.is_open).filter_map(|m| m.due_on).min().or_else(|| self.milestones.iter().filter_map(|m| m.due_on).max())
    }
    fn closed_at(&self) -> Option<DateTime<Utc>> {
        if self.is_open() {
            None
        } else {
            self.milestones.iter().filter_map(|m| m.closed_at).max()
        }
    }
    fn description(&self) -> Option<&str> {
        self.milestones.iter().filter_map(|m| m.description.as_deref()).find(|d| !d.trim().is_empty())
    }
}

/// Grouped by title, leaving out excluded repos: open ones first, by due
/// date (none last), then closed ones, most recently closed first.
fn groups(milestones: &[Milestone], visible: &dyn Fn(&str) -> bool) -> Vec<Group> {
    let mut by_key: BTreeMap<String, Vec<Milestone>> = BTreeMap::new();
    for m in milestones.iter().filter(|m| visible(&m.repo)) {
        by_key.entry(milestone_key(&m.title)).or_default().push(m.clone());
    }
    let mut groups: Vec<Group> = by_key
        .into_iter()
        .map(|(key, mut milestones)| {
            milestones.sort_by(|a, b| a.repo.cmp(&b.repo));
            // The open one's spelling, if titles differ in case.
            let title = milestones.iter().find(|m| m.is_open).unwrap_or(&milestones[0]).title.clone();
            Group { key, title, milestones }
        })
        .collect();
    groups.sort_by(|a, b| {
        use std::cmp::Ordering::*;
        match (a.is_open(), b.is_open()) {
            (true, false) => Less,
            (false, true) => Greater,
            (true, true) => match (a.due_on(), b.due_on()) {
                (Some(x), Some(y)) if x != y => x.cmp(&y),
                (Some(_), None) => Less,
                (None, Some(_)) => Greater,
                _ => a.title.to_lowercase().cmp(&b.title.to_lowercase()),
            },
            (false, false) => b.closed_at().cmp(&a.closed_at()),
        }
    });
    groups
}

/// Milestones and releases matched by name: a milestone titled as a
/// release's tag or name (case and a leading `v` aside) in one of its repos.
fn normalised(text: &str) -> String {
    let text = text.trim().to_lowercase();
    match text.strip_prefix('v') {
        Some(rest) if rest.starts_with(|c: char| c.is_ascii_digit()) => rest.to_string(),
        _ => text,
    }
}

fn matches(group: &Group, release: &Release) -> bool {
    if !group.repos().any(|r| r == release.repo) {
        return false;
    }
    let title = normalised(&group.title);
    normalised(&release.tag_name) == title || release.name.as_deref().is_some_and(|n| normalised(n) == title)
}

/// The release a milestone shipped as: the first published, else a draft.
fn release_for<'a>(group: &Group, releases: &'a [Release]) -> Option<&'a Release> {
    releases.iter().filter(|r| matches(group, r)).min_by_key(|r| (r.is_draft, r.date()))
}

fn milestone_for<'a>(release: &Release, groups: &'a [Group]) -> Option<&'a Group> {
    groups.iter().find(|g| matches(g, release))
}

/// An issue with a milestone, from the issue history.
#[derive(Clone)]
struct MilestoneIssue {
    id: String,
    repo: String,
    number: i64,
    title: String,
    url: String,
    open: bool,
    closed_at: Option<DateTime<Utc>>,
    assignees: Vec<String>,
    /// Its last status on the workflow's board.
    status: Option<String>,
    in_progress: bool,
    merged_pr: bool,
}

/// The issue history's issues with a milestone, by repo and milestone key.
fn milestone_issues(org: &str) -> HashMap<(String, String), Vec<MilestoneIssue>> {
    let workflow = crate::projects::load(org).workflow;
    let store: Value = std::fs::read(crate::cache::path(crate::cache::Kind::Issues, org)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(Value::Null);
    let mut index: HashMap<(String, String), Vec<MilestoneIssue>> = HashMap::new();
    for issue in store["issues"].as_object().into_iter().flat_map(|m| m.values()) {
        let (core, history) = (&issue["core"], &issue["history"]);
        let Some(milestone) = history["milestone"].as_str() else { continue };
        let (Some(id), Some(repo), Some(number)) = (text(&core["id"]), text(&core["repo"]), core["number"].as_i64()) else { continue };
        let open = core["closedAt"].is_null() && core["state"].as_str().is_none_or(|s| s == "OPEN");
        let status = history["statusChanges"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|c| workflow.project_number.is_none_or(|n| c["projectNumber"].as_i64() == Some(n)))
            .filter_map(|c| c["status"].as_str())
            .last()
            .map(str::to_string);
        let in_progress = open && status.as_deref().is_some_and(|s| workflow.is_in_progress(s));
        let merged_pr = history["linkedPullRequests"].as_array().into_iter().flatten().any(|p| !p["mergedAt"].is_null());
        index.entry((repo.clone(), milestone_key(milestone))).or_default().push(MilestoneIssue {
            id,
            repo,
            number,
            title: text(&core["title"]).unwrap_or_default(),
            url: text(&core["url"]).unwrap_or_default(),
            open,
            closed_at: date(&core["closedAt"]),
            assignees: core["assignees"].as_array().into_iter().flatten().filter_map(|a| text(&a["login"])).collect(),
            status,
            in_progress,
            merged_pr,
        });
    }
    index
}

// MARK: - Usage

/// What the Releases part charts, over the repos shown.
#[derive(Default)]
struct Usage {
    repositories: Vec<Repository>,
    downloads: i64,
    stars: i64,
    /// Recorded totals, one a day.
    downloads_over_time: Vec<(NaiveDate, i64)>,
    /// Downloads since the snapshot nearest 30 days ago, when one is that old.
    downloads_lately: Option<i64>,
    /// Downloads of the releases published each month, by the month's start.
    downloads_by_month: Vec<(NaiveDate, i64)>,
    /// Cumulative stars by day, ending today.
    stars_over_time: Vec<(NaiveDate, i64)>,
    stars_lately: i64,
    stars_gained: HashMap<String, i64>,
    stars_before: i64,
    new_stars: Vec<(NaiveDate, i64)>,
    weekly: bool,
}

fn month_start(day: NaiveDate) -> NaiveDate {
    day.with_day(1).unwrap_or(day)
}

fn week_start(day: NaiveDate) -> NaiveDate {
    day - Duration::days(day.weekday().num_days_from_monday() as i64)
}

/// Stars per day added up by week or month, with empty buckets between the
/// first and last as zero, so quiet spells show.
fn new_stars(per_day: &BTreeMap<NaiveDate, i64>, weekly: bool) -> Vec<(NaiveDate, i64)> {
    let start_of = |d: NaiveDate| if weekly { week_start(d) } else { month_start(d) };
    let mut counts: BTreeMap<NaiveDate, i64> = BTreeMap::new();
    for (day, count) in per_day {
        *counts.entry(start_of(*day)).or_default() += count;
    }
    let (Some(first), Some(last)) = (counts.keys().next().copied(), counts.keys().last().copied()) else { return Vec::new() };
    let mut points = Vec::new();
    let mut start = first;
    while start <= last {
        points.push((start, counts.get(&start).copied().unwrap_or(0)));
        start = if weekly { start + Duration::days(7) } else { start.checked_add_months(chrono::Months::new(1)).unwrap_or(last + Duration::days(1)) };
    }
    points
}

impl Usage {
    fn new(history: &History, downloads: Option<&DownloadHistory>, releases: &[&Release], included: &dyn Fn(&str) -> bool, now: DateTime<Utc>) -> Self {
        let repositories: Vec<Repository> = history.repositories.iter().filter(|r| included(&r.name)).cloned().collect();
        let total: i64 = releases.iter().map(|r| r.downloads()).sum();
        let stars = repositories.iter().map(|r| r.stars).sum();
        let snapshots = downloads.map(|d| d.snapshots.as_slice()).unwrap_or(&[]);
        let cutoff = now - Duration::days(LATELY_DAYS);
        let downloads_over_time = snapshots.iter().map(|s| (local_day(s.day), s.total(included))).collect();
        let downloads_lately = snapshots.iter().rev().find(|s| s.day <= cutoff).map(|s| total - s.total(included));

        let mut months: BTreeMap<NaiveDate, i64> = BTreeMap::new();
        for release in releases.iter().filter(|r| !r.is_draft) {
            *months.entry(month_start(local_day(release.date()))).or_default() += release.downloads();
        }

        let histories: Vec<&StarHistory> = repositories.iter().filter_map(|r| history.stars.get(&r.name)).collect();
        let stars_before = histories.iter().map(|h| h.before).sum();
        let stars_gained: HashMap<String, i64> = repositories.iter().map(|r| (r.name.clone(), history.stars.get(&r.name).map_or(0, |h| h.gained(cutoff)))).collect();
        let stars_lately = stars_gained.values().sum();
        let mut per_day: BTreeMap<NaiveDate, i64> = BTreeMap::new();
        for day in histories.iter().flat_map(|h| &h.days) {
            *per_day.entry(local_day(day.day)).or_default() += day.count;
        }
        let mut running = stars_before;
        let mut stars_over_time: Vec<(NaiveDate, i64)> = per_day
            .iter()
            .map(|(day, count)| {
                running += count;
                (*day, running)
            })
            .collect();
        let today = local_day(now);
        if let Some(&(last, value)) = stars_over_time.last() {
            if last < today {
                stars_over_time.push((today, value));
            }
        }
        let first_star = per_day.keys().next().copied().unwrap_or(today);
        let weekly = (today - first_star).num_days() <= WEEKLY_REACH_DAYS;
        Usage {
            repositories,
            downloads: total,
            stars,
            downloads_over_time,
            downloads_lately,
            downloads_by_month: months.into_iter().collect(),
            stars_over_time,
            stars_lately,
            stars_gained,
            stars_before,
            new_stars: new_stars(&per_day, weekly),
            weekly,
        }
    }
}

// MARK: - The page

/// What's read from disk for the org.
struct Loaded {
    history: Option<History>,
    downloads: Option<DownloadHistory>,
    issues: HashMap<(String, String), Vec<MilestoneIssue>>,
    /// Lowercased.
    excluded: HashSet<String>,
}

fn load(org: &str) -> Loaded {
    let (excluded, _) = exclusions(org);
    let history = read_history(org);
    Loaded { downloads: read_downloads(org), issues: milestone_issues(org), history, excluded }
}

#[derive(Clone, Copy, PartialEq)]
enum Part {
    Releases,
    Milestones,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
enum Chart {
    Downloads,
    ByMonth,
    Stars,
    NewStars,
}

#[derive(Clone, Copy, PartialEq)]
enum Table {
    Repos,
    Releases,
    Stargazers,
}

/// A row of the repositories table.
struct RepoRow {
    repository: Repository,
    latest: Option<(String, DateTime<Utc>)>,
    downloads: i64,
    stars_lately: i64,
}

/// What follows the repo picked: worked out when it or the data changes,
/// never on a redraw.
#[derive(Default)]
struct Overview {
    usage: Usage,
    repos: Vec<RepoRow>,
    /// Published releases (not drafts) in view.
    published: usize,
    latest: Option<(String, String, DateTime<Utc>)>,
    /// Release marks for the stars line: (day, label).
    marks: Vec<(NaiveDate, String)>,
}

pub struct ReleasesPage {
    org: Option<String>,
    /// The window's project's repos; none for every repo.
    focus: Option<Vec<String>>,
    /// Milestones grouped by title, over the repos on the page.
    groups: Vec<Group>,
    data: Option<Arc<Loaded>>,
    overview: Arc<Overview>,
    /// The first `STARGAZER_LIMIT` in the table's order, and how many match.
    stargazers: (Vec<(String, Stargazer)>, usize),
    part: Part,
    /// The repo shown, none for all of them.
    repo: Option<String>,
    repo_menu: bool,
    prereleases: bool,
    closed_too: bool,
    search: Entity<editor::Editor>,
    star_search: Entity<editor::Editor>,
    /// (column, descending) for each table.
    sorts: [(&'static str, bool); 3],
    expanded_release: Option<String>,
    expanded_milestone: Option<String>,
    hover: Option<(Chart, usize)>,
    /// Each line chart's plot, as last laid out, for hovering.
    plots: Rc<RefCell<HashMap<Chart, Bounds<Pixels>>>>,
    syncing: bool,
    error: Option<String>,
    generation: u64,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<crate::activity::OpenItem> for ReleasesPage {}

fn short(repo: &str) -> &str {
    repo.rsplit('/').next().unwrap_or(repo)
}

fn count(n: i64) -> String {
    let digits = crate::format::thousands(n.unsigned_abs() as usize);
    if n < 0 {
        format!("-{digits}")
    } else {
        digits
    }
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{} {}", crate::format::thousands(n), if n == 1 { one } else { many })
}

fn day_label(day: NaiveDate) -> String {
    day.format("%-d %b %Y").to_string()
}

fn bytes(size: i64) -> String {
    let size = size as f64;
    if size >= 1e9 {
        format!("{:.1} GB", size / 1e9)
    } else if size >= 1e6 {
        format!("{:.1} MB", size / 1e6)
    } else if size >= 1e3 {
        format!("{:.0} KB", size / 1e3)
    } else {
        format!("{size} bytes")
    }
}

/// About four round ticks from zero to at least `max`.
fn ticks(max: i64) -> Vec<i64> {
    let max = max.max(1) as f64;
    let raw = max / 4.;
    let magnitude = 10f64.powf(raw.log10().floor());
    let step = [1., 2., 5., 10.].iter().map(|m| m * magnitude).find(|s| *s >= raw).unwrap_or(raw).max(1.) as i64;
    let steps = (max / step as f64).ceil() as i64;
    (0..=steps).map(|i| i * step).collect()
}

const AXIS: f32 = 56.;

impl ReleasesPage {
    pub fn new(org: Option<String>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let field = |placeholder: &str, window: &mut Window, cx: &mut Context<Self>| {
            let placeholder = placeholder.to_string();
            cx.new(|cx| {
                let mut editor = editor::Editor::single_line(window, cx);
                editor.set_placeholder_text(&placeholder, window, cx);
                editor
            })
        };
        let search = field("Search releases", window, cx);
        let star_search = field("Search stargazers", window, cx);
        let subscriptions = vec![
            cx.subscribe(&search, |_, _, event: &editor::EditorEvent, cx| {
                if matches!(event, editor::EditorEvent::BufferEdited) {
                    cx.notify();
                }
            }),
            cx.subscribe(&star_search, |page, _, event: &editor::EditorEvent, cx| {
                if matches!(event, editor::EditorEvent::BufferEdited) {
                    page.list_stargazers(cx);
                    cx.notify();
                }
            }),
            cx.observe_window_appearance(window, |_, _, cx| cx.notify()),
        ];
        let mut page = Self {
            org,
            focus: None,
            groups: Vec::new(),
            data: None,
            overview: Arc::default(),
            stargazers: (Vec::new(), 0),
            part: Part::Releases,
            repo: None,
            repo_menu: false,
            prereleases: true,
            closed_too: false,
            search,
            star_search,
            sorts: [("downloads", true), ("published", true), ("starred", true)],
            expanded_release: None,
            expanded_milestone: None,
            hover: None,
            plots: Rc::default(),
            syncing: false,
            error: None,
            generation: 0,
            _subscriptions: subscriptions,
        };
        page.load(true, cx);
        page
    }

    pub fn set_org(&mut self, org: Option<String>, cx: &mut Context<Self>) {
        if org != self.org {
            self.org = org;
            self.data = None;
            self.repo = None;
            self.expanded_release = None;
            self.expanded_milestone = None;
            self.error = None;
            self.load(true, cx);
        }
    }

    /// Keeps the page to the window's project's repos, or every repo for none.
    pub fn set_focus(&mut self, focus: Option<Vec<String>>, cx: &mut Context<Self>) {
        if focus != self.focus {
            self.focus = focus;
            self.hover = None;
            self.recompute(cx);
            cx.notify();
        }
    }

    /// Reads the copy on disk again (after the workspace's sync).
    pub fn reload(&mut self, cx: &mut Context<Self>) {
        self.load(false, cx);
    }

    /// Reads the org's copy off the main thread, then fetches when it's old.
    fn load(&mut self, then_sync: bool, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        self.generation += 1;
        let generation = self.generation;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let loaded = cx.background_executor().spawn({
                let org = org.clone();
                async move { load(&org) }
            }).await;
            this.update(cx, |page, cx| {
                if page.generation != generation {
                    return;
                }
                page.data = Some(Arc::new(loaded));
                page.recompute(cx);
                if then_sync {
                    page.sync(false, cx);
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn sync(&mut self, force: bool, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        if self.syncing {
            return;
        }
        self.syncing = true;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let synced = cx.background_executor().spawn({
                let org = org.clone();
                async move { sync(&org, force) }
            }).await;
            this.update(cx, |page, cx| {
                page.syncing = false;
                if page.org.as_deref() != Some(org.as_str()) {
                    return;
                }
                match synced {
                    Ok(true) => {
                        page.error = None;
                        page.load(false, cx);
                    }
                    Ok(false) => {}
                    Err(error) => page.error = Some(error),
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// The repos with releases in view, sorted by name.
    fn repo_names(&self) -> Vec<String> {
        let Some(data) = &self.data else { return Vec::new() };
        let mut names: Vec<String> = data.history.iter().flat_map(|h| &h.repositories).map(|r| r.name.clone()).filter(|n| self.visible(n)).collect();
        names.sort_by_key(|n| n.to_lowercase());
        names
    }

    /// Whether a repo belongs on the page: one of the window's project's
    /// repos (which count even when excluded org-wide), else any repo not
    /// excluded.
    fn visible(&self, repo: &str) -> bool {
        match &self.focus {
            Some(focus) => focus.iter().any(|r| r.eq_ignore_ascii_case(repo)),
            None => !self.data.as_ref().is_some_and(|d| d.excluded.contains(&repo.to_lowercase())),
        }
    }

    /// Whether a repo is in view: on the page, and the one picked if any.
    fn included(&self, repo: &str) -> bool {
        self.visible(repo) && self.repo.as_deref().is_none_or(|r| r == repo)
    }

    fn releases_in_view(&self) -> Vec<&Release> {
        let Some(history) = self.data.as_ref().and_then(|d| d.history.as_ref()) else { return Vec::new() };
        history.releases.iter().filter(|r| self.included(&r.repo)).collect()
    }

    /// Works out the tiles, charts and repositories for the repo picked.
    fn recompute(&mut self, cx: &mut Context<Self>) {
        // A repo picked that's gone from view is all of them.
        if self.repo.as_ref().is_some_and(|r| !self.repo_names().contains(r)) {
            self.repo = None;
        }
        let Some(data) = self.data.clone() else { return };
        self.groups = data.history.as_ref().map(|h| groups(&h.milestones, &|repo| self.visible(repo))).unwrap_or_default();
        let Some(history) = &data.history else {
            self.overview = Arc::default();
            self.list_stargazers(cx);
            return;
        };
        let releases = self.releases_in_view();
        let included = |repo: &str| self.included(repo);
        let usage = Usage::new(history, data.downloads.as_ref(), &releases, &included, Utc::now());
        let mut by_repo: HashMap<&str, Vec<&Release>> = HashMap::new();
        for release in &releases {
            by_repo.entry(release.repo.as_str()).or_default().push(release);
        }
        let repos = usage
            .repositories
            .iter()
            .map(|repository| {
                let releases = by_repo.get(repository.name.as_str()).map(Vec::as_slice).unwrap_or(&[]);
                RepoRow {
                    repository: repository.clone(),
                    latest: releases.iter().filter(|r| !r.is_draft).max_by_key(|r| r.date()).map(|r| (r.tag_name.clone(), r.date())),
                    downloads: releases.iter().map(|r| r.downloads()).sum(),
                    stars_lately: usage.stars_gained.get(&repository.name).copied().unwrap_or(0),
                }
            })
            .collect();
        let published: Vec<&&Release> = releases.iter().filter(|r| !r.is_draft).collect();
        let latest = published.iter().max_by_key(|r| r.date()).map(|r| (r.tag_name.clone(), r.repo.clone(), r.date()));
        let marks = match usage.stars_over_time.first() {
            Some(&(first, _)) => {
                let marked: Vec<&&&Release> = published.iter().filter(|r| !r.is_prerelease && local_day(r.date()) >= first).collect();
                if self.repo.is_some() || marked.len() <= RELEASE_MARK_LIMIT {
                    marked.iter().map(|r| (local_day(r.date()), if self.repo.is_some() { r.tag_name.clone() } else { format!("{} {}", short(&r.repo), r.tag_name) })).collect()
                } else {
                    Vec::new()
                }
            }
            None => Vec::new(),
        };
        self.overview = Arc::new(Overview { published: published.len(), latest, marks, usage, repos });
        self.list_stargazers(cx);
    }

    /// Every word of the stargazer search in their login, name, company,
    /// location or repo, sorted as the table is before cutting.
    fn list_stargazers(&mut self, cx: &mut Context<Self>) {
        let words: Vec<String> = self.star_search.read(cx).text(cx).to_lowercase().split_whitespace().map(str::to_string).collect();
        let mut all: Vec<(String, Stargazer)> = Vec::new();
        if let Some(history) = self.data.as_ref().and_then(|d| d.history.as_ref()) {
            for (repo, stars) in history.stars.iter().filter(|(repo, _)| self.included(repo)) {
                for person in &stars.stargazers {
                    if !words.is_empty() {
                        let text = [person.login.as_str(), person.name.as_deref().unwrap_or(""), person.company.as_deref().unwrap_or(""), person.location.as_deref().unwrap_or(""), repo].join(" ").to_lowercase();
                        if !words.iter().all(|w| text.contains(w.as_str())) {
                            continue;
                        }
                    }
                    all.push((repo.clone(), person.clone()));
                }
            }
        }
        let (column, descending) = self.sorts[Table::Stargazers as usize];
        let lower = |s: &Option<String>| s.as_deref().unwrap_or("").to_lowercase();
        all.sort_by(|(ra, a), (rb, b)| {
            let order = match column {
                "who" => a.login.to_lowercase().cmp(&b.login.to_lowercase()),
                "repo" => ra.to_lowercase().cmp(&rb.to_lowercase()),
                "company" => lower(&a.company).cmp(&lower(&b.company)),
                "location" => lower(&a.location).cmp(&lower(&b.location)),
                "followers" => a.followers.cmp(&b.followers),
                _ => a.starred_at.cmp(&b.starred_at),
            };
            if descending {
                order.reverse()
            } else {
                order
            }
        });
        let matching = all.len();
        all.truncate(STARGAZER_LIMIT);
        self.stargazers = (all, matching);
    }

    fn words(&self, cx: &Context<Self>) -> Vec<String> {
        self.search.read(cx).text(cx).to_lowercase().split_whitespace().map(str::to_string).collect()
    }

    fn shown_releases<'a>(&self, releases: &[&'a Release], cx: &Context<Self>) -> Vec<&'a Release> {
        let words = self.words(cx);
        let mut shown: Vec<&Release> = releases
            .iter()
            .copied()
            .filter(|r| self.prereleases || !r.is_prerelease)
            .filter(|r| {
                let text = format!("{} {} {} {}", r.title(), r.tag_name, r.repo, r.author.as_deref().unwrap_or("")).to_lowercase();
                words.iter().all(|w| text.contains(w.as_str()))
            })
            .collect();
        let (column, descending) = self.sorts[Table::Releases as usize];
        let groups = self.groups.as_slice();
        shown.sort_by(|a, b| {
            let order = match column {
                "release" => a.title().to_lowercase().cmp(&b.title().to_lowercase()),
                "repo" => a.repo.to_lowercase().cmp(&b.repo.to_lowercase()),
                "author" => a.author.as_deref().unwrap_or("").to_lowercase().cmp(&b.author.as_deref().unwrap_or("").to_lowercase()),
                "downloads" => a.downloads().cmp(&b.downloads()),
                "milestone" => milestone_for(a, groups).map(|g| g.title.to_lowercase()).cmp(&milestone_for(b, groups).map(|g| g.title.to_lowercase())),
                _ => a.date().cmp(&b.date()),
            };
            if descending {
                order.reverse()
            } else {
                order
            }
        });
        shown
    }

    fn shown_groups<'a>(&self, groups: &'a [Group], cx: &Context<Self>) -> Vec<&'a Group> {
        let words = self.words(cx);
        groups
            .iter()
            .filter(|g| self.closed_too || g.is_open())
            .filter(|g| {
                let text = std::iter::once(g.title.as_str()).chain(g.repos()).collect::<Vec<_>>().join(" ").to_lowercase();
                words.iter().all(|w| text.contains(w.as_str()))
            })
            .collect()
    }

    fn set_part(&mut self, part: Part, window: &mut Window, cx: &mut Context<Self>) {
        if self.part != part {
            self.part = part;
            self.repo_menu = false;
            let placeholder = if part == Part::Milestones { "Search milestones" } else { "Search releases" };
            self.search.update(cx, |editor, cx| editor.set_placeholder_text(placeholder, window, cx));
            cx.notify();
        }
    }

    fn pick_repo(&mut self, repo: Option<String>, cx: &mut Context<Self>) {
        self.repo = repo;
        self.repo_menu = false;
        self.hover = None;
        self.recompute(cx);
        cx.notify();
    }

    fn sort(&mut self, table: Table, column: &'static str, cx: &mut Context<Self>) {
        let slot = &mut self.sorts[table as usize];
        *slot = if slot.0 == column { (column, !slot.1) } else { (column, !matches!(column, "release" | "repo" | "author" | "who" | "company" | "location" | "milestone")) };
        if table == Table::Stargazers {
            self.list_stargazers(cx);
        }
        cx.notify();
    }

    fn set_hover(&mut self, hover: Option<(Chart, usize)>, cx: &mut Context<Self>) {
        if self.hover != hover {
            self.hover = hover;
            cx.notify();
        }
    }

    fn hovered(&self, chart: Chart) -> Option<usize> {
        self.hover.filter(|(c, _)| *c == chart).map(|(_, i)| i)
    }

    /// Opens a milestone from a release, in the Milestones part.
    fn show_milestone(&mut self, key: String, window: &mut Window, cx: &mut Context<Self>) {
        self.closed_too = self.closed_too || self.groups.iter().any(|g| g.key == key && !g.is_open());
        self.expanded_milestone = Some(key);
        self.search.update(cx, |editor, cx| editor.set_text("", window, cx));
        self.set_part(Part::Milestones, window, cx);
    }

    /// Opens a release from a milestone, in the Releases part.
    fn show_release(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        self.expanded_release = Some(id);
        self.prereleases = true;
        self.search.update(cx, |editor, cx| editor.set_text("", window, cx));
        if self.repo.is_some() {
            self.pick_repo(None, cx);
        }
        self.set_part(Part::Releases, window, cx);
    }

    // MARK: Controls

    fn chip(id: impl Into<SharedString>, label: impl Into<SharedString>, on: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(gpui::ElementId::Name(id.into()))
            .flex_none()
            .px_2()
            .py_0p5()
            .rounded_md()
            .text_xs()
            .cursor_pointer()
            .text_color(if on { theme.fg } else { theme.secondary })
            .when(on, |d| d.bg(theme.row_selected))
            .hover(|s| s.bg(theme.row_selected))
            .child(label.into())
    }

    fn checkbox(id: &'static str, label: &'static str, on: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(id)
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .gap_1p5()
            .text_xs()
            .cursor_pointer()
            .text_color(theme.secondary)
            .child(
                div()
                    .size(px(12.))
                    .rounded(px(3.))
                    .border_1()
                    .border_color(if on { theme.selected } else { theme.secondary })
                    .when(on, |d| d.bg(theme.selected))
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_color(theme.on_selected)
                    .child(if on { "✓" } else { "" }),
            )
            .child(label)
    }

    fn toolbar(&self, count: usize, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let parts = div()
            .p_0p5()
            .flex()
            .flex_row()
            .gap_0p5()
            .rounded_md()
            .bg(theme.tile)
            .child(Self::chip("part-releases", "Releases", self.part == Part::Releases, theme).on_click(cx.listener(|page, _: &ClickEvent, window, cx| page.set_part(Part::Releases, window, cx))))
            .child(Self::chip("part-milestones", "Milestones", self.part == Part::Milestones, theme).on_click(cx.listener(|page, _: &ClickEvent, window, cx| page.set_part(Part::Milestones, window, cx))));
        let repos = self.repo_names();
        let noun = if self.part == Part::Milestones { ("milestone", "milestones") } else { ("release", "releases") };
        let status = if self.syncing {
            "Fetching releases".to_string()
        } else if let Some(at) = self.data.as_ref().and_then(|d| d.history.as_ref()).map(|h| h.synced_at) {
            format!("Fetched {}", crate::format::relative_date(at, Utc::now()))
        } else {
            String::new()
        };
        div()
            .flex_none()
            .flex()
            .flex_col()
            .gap_2()
            .px_4()
            .py_3()
            .border_b_1()
            .border_color(theme.border)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .child(parts)
                    .child(div().w(px(240.)).px_2().py_0p5().rounded_full().bg(theme.tile).border_1().border_color(theme.border).child(self.search.clone()))
                    .map(|d| match self.part {
                        Part::Milestones => d.child(Self::checkbox("closed-too", "Closed too", self.closed_too, theme).on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                            page.closed_too = !page.closed_too;
                            cx.notify();
                        }))),
                        Part::Releases => d
                            .when(repos.len() > 1, |d| {
                                let label = self.repo.as_deref().map(short).unwrap_or("All Repositories").to_string();
                                d.child(
                                    Self::chip("repo-menu", format!("{label} ▾"), self.repo.is_some() || self.repo_menu, theme)
                                        .border_1()
                                        .border_color(if self.repo.is_some() { theme.selected } else { theme.border })
                                        .tooltip(|_, cx| cx.new(|_| Tooltip("Show one repository's releases, downloads and stars".into())).into())
                                        .on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                                            page.repo_menu = !page.repo_menu;
                                            cx.notify();
                                        })),
                                )
                            })
                            .child(Self::checkbox("prereleases", "Pre-releases", self.prereleases, theme).on_click(cx.listener(|page, _: &ClickEvent, _, cx| {
                                page.prereleases = !page.prereleases;
                                cx.notify();
                            }))),
                    })
                    .child(div().flex_1())
                    .child(div().text_xs().text_color(theme.tertiary).child(status))
                    .child(div().text_sm().text_color(theme.secondary).child(plural(count, noun.0, noun.1)))
                    .child(
                        Self::chip("refresh", "Refresh", false, theme)
                            .when(self.syncing, |d| d.opacity(0.4))
                            .on_click(cx.listener(|page, _: &ClickEvent, _, cx| page.sync(true, cx))),
                    ),
            )
            .when(self.repo_menu && self.part == Part::Releases, |d| {
                d.child(
                    div()
                        .flex()
                        .flex_row()
                        .flex_wrap()
                        .gap_1()
                        .p_2()
                        .rounded_md()
                        .border_1()
                        .border_color(theme.border)
                        .child(Self::chip("repo-all", "All Repositories", self.repo.is_none(), theme).on_click(cx.listener(|page, _: &ClickEvent, _, cx| page.pick_repo(None, cx))))
                        .children(repos.into_iter().map(|repo| {
                            let on = self.repo.as_deref() == Some(repo.as_str());
                            Self::chip(format!("repo-{repo}"), short(&repo).to_string(), on, theme).on_click(cx.listener(move |page, _: &ClickEvent, _, cx| page.pick_repo(Some(repo.clone()), cx)))
                        })),
                )
            })
    }

    // MARK: Pieces

    fn section(title: &str, count: Option<usize>, theme: &Theme) -> impl IntoElement {
        div()
            .flex()
            .flex_row()
            .items_baseline()
            .gap_2()
            .pt_6()
            .pb_2()
            .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child(title.to_string()))
            .when_some(count, |d, n| d.child(div().text_sm().text_color(theme.secondary).child(crate::format::thousands(n))))
    }

    fn tile(title: &str, value: String, detail: String, theme: &Theme) -> impl IntoElement {
        div()
            .flex_1()
            .min_w(px(160.))
            .flex()
            .flex_col()
            .gap_1()
            .p_3()
            .rounded_lg()
            .bg(theme.tile)
            .child(div().text_xs().text_color(theme.secondary).child(title.to_string()))
            .child(div().text_2xl().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).truncate().child(value))
            .child(div().text_xs().text_color(theme.secondary).truncate().child(detail))
    }

    fn badge(label: &'static str, color: Hsla) -> impl IntoElement {
        div().flex_none().px_1p5().rounded_full().text_xs().border_1().border_color(color.opacity(0.6)).text_color(color).child(label)
    }

    fn badges(release: &Release, theme: &Theme) -> impl IntoElement {
        div()
            .flex()
            .flex_row()
            .gap_1()
            .when(release.is_latest, |d| d.child(Self::badge("Latest", theme.good())))
            .when(release.is_prerelease, |d| d.child(Self::badge("Pre-release", theme.orange())))
            .when(release.is_draft, |d| d.child(Self::badge("Draft", theme.secondary)))
    }

    /// "3 of 8" over a bar, green once everything's closed.
    fn progress(closed: i64, total: i64, width: f32, theme: &Theme) -> impl IntoElement {
        let fraction = if total > 0 { (closed as f32 / total as f32).clamp(0., 1.) } else { 0. };
        div()
            .flex_none()
            .w(px(width))
            .flex()
            .flex_col()
            .items_end()
            .gap_1()
            .child(div().text_sm().text_color(if total == 0 { theme.secondary } else { theme.fg }).child(if total == 0 { "Empty".to_string() } else { format!("{closed} of {total}") }))
            .child(div().w_full().h(px(4.)).rounded_full().bg(theme.grid).child(div().h_full().rounded_full().w(relative(fraction)).bg(if total > 0 && fraction >= 1. { theme.good() } else { theme.blue() })))
    }

    /// A due date, red once it's passed and orange within the week.
    fn due(due: DateTime<Utc>, theme: &Theme) -> impl IntoElement {
        let days = (local_day(due) - Local::now().date_naive()).num_days();
        let words = match days {
            d if d < 0 => format!("{}d overdue", -d),
            0 => "Due today".to_string(),
            1 => "Due tomorrow".to_string(),
            _ => format!("Due {}", local_day(due).format("%-d %b")),
        };
        div().flex_none().text_sm().text_color(if days < 0 { theme.critical() } else if days < 7 { theme.orange() } else { theme.secondary }).child(words)
    }

    fn link(id: impl Into<SharedString>, label: impl Into<SharedString>, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div().id(gpui::ElementId::Name(id.into())).flex_none().text_sm().text_color(theme.blue()).cursor_pointer().hover(|s| s.underline()).child(label.into())
    }

    // MARK: Tables

    /// A header row: the first column takes the width, the rest are fixed.
    fn header(&self, table: Table, columns: &[(&'static str, &'static str, f32, &'static str)], theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let (sorted, descending) = self.sorts[table as usize];
        div().flex().flex_row().items_center().gap_3().px_2().py_1().border_b_1().border_color(theme.border).children(columns.iter().enumerate().map(|(i, &(id, title, width, help))| {
            let arrow = if sorted == id { if descending { " ↓" } else { " ↑" } } else { "" };
            div()
                .id(SharedString::from(format!("sort-{}-{id}", table as usize)))
                .map(|d| if i == 0 { d.flex_1().min_w_0() } else { d.w(px(width)).flex_none().flex().justify_end() })
                .text_xs()
                .text_color(if sorted == id { theme.fg } else { theme.secondary })
                .cursor_pointer()
                .tooltip(move |_, cx| cx.new(|_| Tooltip(help.into())).into())
                .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| page.sort(table, id, cx)))
                .child(format!("{title}{arrow}"))
        }))
    }

    fn cell(width: f32, child: impl IntoElement) -> impl IntoElement {
        div().w(px(width)).flex_none().flex().justify_end().text_sm().whitespace_nowrap().overflow_hidden().child(child)
    }

    fn number(n: i64, theme: &Theme) -> impl IntoElement {
        div().text_color(if n == 0 { theme.tertiary } else { theme.fg }).child(count(n))
    }

    fn repositories_table(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let overview = self.overview.clone();
        if overview.repos.is_empty() {
            return div().text_sm().text_color(theme.secondary).child("No repository in view has published a release.").into_any_element();
        }
        let (column, descending) = self.sorts[Table::Repos as usize];
        let mut rows: Vec<&RepoRow> = overview.repos.iter().collect();
        rows.sort_by(|a, b| {
            let order = match column {
                "repo" => a.repository.name.to_lowercase().cmp(&b.repository.name.to_lowercase()),
                "releases" => a.repository.release_count.cmp(&b.repository.release_count),
                "latest" => a.latest.as_ref().map(|l| l.1).cmp(&b.latest.as_ref().map(|l| l.1)),
                "stars" => a.repository.stars.cmp(&b.repository.stars),
                "starsLately" => a.stars_lately.cmp(&b.stars_lately),
                _ => a.downloads.cmp(&b.downloads),
            };
            if descending {
                order.reverse()
            } else {
                order
            }
        });
        let columns = [
            ("repo", "Repository", 0., "Click one to show it alone, and again to show them all"),
            ("releases", "Releases", 70., "Releases on GitHub, drafts included when you can see them"),
            ("latest", "Latest", 170., "Its most recently published release"),
            ("downloads", "Downloads", 90., "Every release asset's downloads, as GitHub counts them"),
            ("stars", "Stars", 70., "Stars now"),
            ("starsLately", "30 days", 70., "Stars in the last 30 days, from those still starring it"),
        ];
        let now = Utc::now();
        div()
            .flex()
            .flex_col()
            .child(self.header(Table::Repos, &columns, theme, cx))
            .children(rows.into_iter().map(|row| {
                let name = row.repository.name.clone();
                let picked = self.repo.as_deref() == Some(name.as_str());
                div()
                    .id(SharedString::from(format!("repo-row-{name}")))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .px_2()
                    .py_1p5()
                    .border_b_1()
                    .border_color(theme.grid)
                    .cursor_pointer()
                    .when(picked, |d| d.bg(theme.row_selected))
                    .hover(|s| s.bg(theme.row_selected))
                    .on_click(cx.listener({
                        let name = name.clone();
                        move |page, _: &ClickEvent, _, cx| {
                            let pick = if page.repo.as_deref() == Some(name.as_str()) { None } else { Some(name.clone()) };
                            page.pick_repo(pick, cx);
                        }
                    }))
                    .child(div().flex_1().min_w_0().truncate().text_sm().font_weight(FontWeight::MEDIUM).child(short(&name).to_string()))
                    .child(Self::cell(70., Self::number(row.repository.release_count, theme)))
                    .child(Self::cell(
                        170.,
                        match &row.latest {
                            Some((tag, at)) => div().truncate().child(format!("{tag} · {}", crate::format::relative_date(*at, now))),
                            None => div().text_color(theme.tertiary).child("-"),
                        },
                    ))
                    .child(Self::cell(90., Self::number(row.downloads, theme)))
                    .child(Self::cell(70., Self::number(row.repository.stars, theme)))
                    .child(Self::cell(70., div().text_color(if row.stars_lately == 0 { theme.tertiary } else { theme.good() }).child(if row.stars_lately == 0 { "0".to_string() } else { format!("+{}", count(row.stars_lately)) })))
            }))
            .into_any_element()
    }

    fn releases_table(&self, shown: &[&Release], any: bool, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        if shown.is_empty() {
            let text = if any { "No matching releases. Try another search." } else { "GitHub Releases in the org's repositories show here." };
            return div().text_sm().text_color(theme.secondary).child(text).into_any_element();
        }
        let groups = self.groups.as_slice();
        let columns = [
            ("release", "Release", 0., "Its name, its tag when that differs, and how it's marked"),
            ("repo", "Repository", 130., "The repository it's in"),
            ("published", "Published", 100., "When it was published, or drafted for a draft"),
            ("author", "Author", 110., "Who published it"),
            ("downloads", "Downloads", 90., "Its assets' downloads, as GitHub counts them"),
            ("milestone", "Milestone", 130., "The milestone it shipped, titled as its tag or name"),
        ];
        div()
            .flex()
            .flex_col()
            .child(self.header(Table::Releases, &columns, theme, cx))
            .children(shown.iter().take(ROW_LIMIT).map(|release| {
                let open = self.expanded_release.as_deref() == Some(release.id.as_str());
                let milestone = milestone_for(release, groups);
                let id = release.id.clone();
                div()
                    .flex()
                    .flex_col()
                    .border_b_1()
                    .border_color(theme.grid)
                    .child(
                        div()
                            .id(SharedString::from(format!("release-{}", release.id)))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_3()
                            .px_2()
                            .py_1p5()
                            .cursor_pointer()
                            .when(open, |d| d.bg(theme.row_selected))
                            .hover(|s| s.bg(theme.row_selected))
                            .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                                page.expanded_release = if page.expanded_release.as_deref() == Some(id.as_str()) { None } else { Some(id.clone()) };
                                cx.notify();
                            }))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap_1p5()
                                    .child(gpui::svg().path(if open { "icons/chevron_down.svg" } else { "icons/chevron_right.svg" }).size(px(12.)).flex_none().text_color(theme.tertiary))
                                    .child(div().min_w_0().truncate().text_sm().font_weight(FontWeight::MEDIUM).child(release.title().to_string()))
                                    .when(release.title() != release.tag_name, |d| d.child(div().flex_none().text_xs().text_color(theme.secondary).child(release.tag_name.clone())))
                                    .child(Self::badges(release, theme)),
                            )
                            .child(Self::cell(130., div().truncate().child(short(&release.repo).to_string())))
                            .child(Self::cell(100., div().text_color(if release.is_draft { theme.secondary } else { theme.fg }).child(if release.is_draft { "Draft".to_string() } else { local_day(release.date()).format("%-d %b %Y").to_string() })))
                            .child(Self::cell(110., div().truncate().text_color(if release.author.is_none() { theme.tertiary } else { theme.fg }).child(release.author.clone().unwrap_or_else(|| "-".into()))))
                            .child(Self::cell(90., if release.assets.is_empty() { div().text_color(theme.tertiary).child("-") } else { div().child(Self::number(release.downloads(), theme)) }))
                            .child(Self::cell(130., match milestone {
                                Some(group) => {
                                    let key = group.key.clone();
                                    Self::link(format!("ms-link-{}", release.id), group.title.clone(), theme)
                                        .truncate()
                                        .on_click(cx.listener(move |page, _: &ClickEvent, window, cx| {
                                            cx.stop_propagation();
                                            page.show_milestone(key.clone(), window, cx);
                                        }))
                                        .into_any_element()
                                }
                                None => div().text_color(theme.tertiary).child("-").into_any_element(),
                            })),
                    )
                    .when(open, |d| d.child(self.release_detail(release, milestone, theme, cx)))
            }))
            .when(shown.len() > ROW_LIMIT, |d| d.child(div().pt_2().text_sm().text_color(theme.tertiary).child(format!("Showing the first {} of {}. Search or pick a repository to narrow them.", ROW_LIMIT, crate::format::thousands(shown.len())))))
            .into_any_element()
    }

    /// A release opened out: its facts, assets and notes.
    fn release_detail(&self, release: &Release, milestone: Option<&Group>, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let fact = |label: &str, value: AnyElement| div().flex().flex_row().gap_3().text_sm().child(div().w(px(90.)).flex_none().text_color(theme.secondary).child(label.to_string())).child(value);
        let url = release.url.clone();
        let repo_url = format!("https://github.com/{}/releases", release.repo);
        let notes = release.notes.as_deref().map(str::trim).filter(|n| !n.is_empty());
        let mut assets: Vec<&Asset> = release.assets.iter().collect();
        assets.sort_by(|a, b| b.download_count.cmp(&a.download_count));
        div()
            .flex()
            .flex_col()
            .gap_3()
            .px_6()
            .py_3()
            .bg(theme.tile)
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(fact("Repository", div().child(release.repo.clone()).into_any_element()))
                    .child(fact("Tag", div().child(release.tag_name.clone()).into_any_element()))
                    .child(fact(if release.is_draft { "Drafted" } else { "Published" }, div().child(release.date().with_timezone(&Local).format("%-d %b %Y, %H:%M").to_string()).into_any_element()))
                    .when_some(release.author.clone(), |d, author| d.child(fact("Author", div().child(author).into_any_element())))
                    .child(fact("Downloads", div().child(if release.assets.is_empty() { "No assets".to_string() } else { count(release.downloads()) }).into_any_element()))
                    .when_some(milestone, |d, group| {
                        let key = group.key.clone();
                        d.child(fact(
                            "Milestone",
                            Self::link(format!("ms-detail-{}", release.id), group.title.clone(), theme)
                                .on_click(cx.listener(move |page, _: &ClickEvent, window, cx| page.show_milestone(key.clone(), window, cx)))
                                .into_any_element(),
                        ))
                    })
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .gap_4()
                            .pt_1()
                            .child(Self::link(format!("gh-{}", release.id), "Open on GitHub", theme).on_click(move |_, _, cx| cx.open_url(&url)))
                            .child(Self::link(format!("gh-all-{}", release.id), "All releases on GitHub", theme).on_click(move |_, _, cx| cx.open_url(&repo_url))),
                    ),
            )
            .when(!assets.is_empty(), |d| {
                d.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_0p5()
                        .child(div().text_xs().text_color(theme.secondary).child("Assets"))
                        .children(assets.into_iter().map(|asset| {
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap_3()
                                .text_sm()
                                .child(div().flex_1().min_w_0().truncate().child(asset.name.clone()))
                                .child(div().flex_none().text_color(theme.secondary).child(bytes(asset.size)))
                                .child(div().w(px(130.)).flex_none().flex().justify_end().child(format!("{} downloads", count(asset.download_count))))
                        })),
                )
            })
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(div().text_xs().text_color(theme.secondary).child("Notes"))
                    .child(match notes {
                        Some(notes) => crate::markdown::markdown(&format!("release-notes-{}", release.id), notes, theme),
                        None => div().text_sm().text_color(theme.secondary).child("No release notes.").into_any_element(),
                    }),
            )
    }

    fn stargazers_section(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let (rows, matching) = (&self.stargazers.0, self.stargazers.1);
        let any = self.data.as_ref().and_then(|d| d.history.as_ref()).is_some_and(|h| h.stars.iter().any(|(repo, s)| self.included(repo) && !s.stargazers.is_empty()));
        let columns = [
            ("who", "Stargazer", 0., "Their login and name. Click one to open their profile on GitHub"),
            ("repo", "Repository", 130., "The repository they starred"),
            ("company", "Company", 140., "As their GitHub profile has it"),
            ("location", "Location", 140., "As their GitHub profile has it"),
            ("followers", "Followers", 80., "Their followers on GitHub when they were fetched"),
            ("starred", "Starred", 100., "When they starred it"),
        ];
        let optional = |text: &Option<String>| match text.as_deref().map(str::trim).filter(|t| !t.is_empty()) {
            Some(text) => div().truncate().child(text.to_string()),
            None => div().text_color(theme.tertiary).child("-"),
        };
        div()
            .flex()
            .flex_col()
            .gap_2()
            .child(Self::section("Stargazers", Some(matching), theme))
            .child(div().w(px(240.)).px_2().py_0p5().rounded_full().bg(theme.tile).border_1().border_color(theme.border).child(self.star_search.clone()))
            .map(|d| {
                if rows.is_empty() {
                    d.child(div().text_sm().text_color(theme.secondary).child(if any { "No matching stargazers. Try another search." } else { "Who starred the repositories with releases shows here." }))
                } else {
                    d.child(
                        div()
                            .flex()
                            .flex_col()
                            .child(self.header(Table::Stargazers, &columns, theme, cx))
                            .children(rows.iter().enumerate().map(|(i, (repo, person))| {
                                let profile = format!("https://github.com/{}", person.login);
                                div()
                                    .id(("stargazer", i))
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap_3()
                                    .px_2()
                                    .py_1()
                                    .border_b_1()
                                    .border_color(theme.grid)
                                    .cursor_pointer()
                                    .hover(|s| s.bg(theme.row_selected))
                                    .on_click(move |_, _, cx| cx.open_url(&profile))
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w_0()
                                            .flex()
                                            .flex_row()
                                            .items_center()
                                            .gap_2()
                                            .text_sm()
                                            .child(crate::avatars::avatar(&person.login, person.avatar_url.as_deref(), 20., theme, cx))
                                            .child(div().flex_none().font_weight(FontWeight::MEDIUM).child(person.login.clone()))
                                            .when_some(person.name.clone().filter(|n| !n.is_empty()), |d, name| d.child(div().min_w_0().truncate().text_color(theme.secondary).child(name))),
                                    )
                                    .child(Self::cell(130., div().truncate().child(short(repo).to_string())))
                                    .child(Self::cell(140., optional(&person.company)))
                                    .child(Self::cell(140., optional(&person.location)))
                                    .child(Self::cell(80., Self::number(person.followers, theme)))
                                    .child(Self::cell(100., local_day(person.starred_at).format("%-d %b %Y").to_string()))
                            })),
                    )
                    .when(matching > STARGAZER_LIMIT, |d| {
                        d.child(div().text_sm().text_color(theme.tertiary).child(format!("Showing the first {} of {}. Search or pick a repository to narrow them.", STARGAZER_LIMIT, crate::format::thousands(matching))))
                    })
                }
            })
    }

    // MARK: Charts

    /// The value axis and grid around a plot.
    fn plot_frame(max: i64, height: f32, x_labels: Vec<(f32, String)>, theme: &Theme, body: AnyElement) -> impl IntoElement {
        let ticks = ticks(max);
        let top = (*ticks.last().unwrap_or(&1)).max(1) as f32;
        let y = move |v: i64| height - v as f32 / top * height;
        div()
            .flex()
            .flex_col()
            .gap_1()
            .child(
                div()
                    .flex()
                    .flex_row()
                    .child(div().relative().w(px(AXIS)).h(px(height)).flex_none().children(ticks.iter().map(|t| div().absolute().right(px(8.)).top(px(y(*t) - 7.)).text_xs().text_color(theme.secondary).child(count(*t)))))
                    .child(
                        div()
                            .relative()
                            .flex_1()
                            .h(px(height))
                            .children(ticks.iter().map(|t| div().absolute().left_0().right_0().top(px(y(*t))).h(px(1.)).bg(theme.grid)))
                            .child(div().absolute().top_0().left_0().right_0().bottom_0().child(body)),
                    ),
            )
            .child(
                div().flex().flex_row().child(div().w(px(AXIS)).flex_none()).child(div().flex_1().relative().h(px(14.)).children(x_labels.into_iter().map(|(fraction, label)| {
                    div().absolute().left(relative(fraction)).text_xs().text_color(theme.secondary).whitespace_nowrap().child(label)
                }))),
            )
    }

    fn chart_title(title: &str, theme: &Theme) -> impl IntoElement {
        div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.fg).child(title.to_string())
    }

    fn caption(text: String, strong: bool, theme: &Theme) -> impl IntoElement {
        div().text_xs().text_color(if strong { theme.secondary } else { theme.tertiary }).truncate().child(text)
    }

    /// A running total by day as a stepped line, with release marks as
    /// dashed rules; hovering names the day.
    fn line_chart(&self, chart: Chart, title: &str, points: &[(NaiveDate, i64)], noun: &str, note: Option<String>, marks: &[(NaiveDate, String)], theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        if points.is_empty() {
            return div().flex().flex_col().gap_2().child(Self::chart_title(title, theme)).child(Self::caption("Nothing yet.".into(), true, theme)).into_any_element();
        }
        let height = 170.;
        let first = points[0].0;
        let last = points[points.len() - 1].0;
        let span = (last - first).num_days().max(1) as f32;
        let x = move |d: NaiveDate| (d - first).num_days() as f32 / span;
        let max = points.iter().map(|p| p.1).max().unwrap_or(1);
        let top = (*ticks(max).last().unwrap_or(&1)).max(1) as f32;
        let hovered = self.hovered(chart).and_then(|i| points.get(i).copied());
        let xy: Vec<(f32, f32)> = points.iter().map(|(d, v)| (x(*d), *v as f32 / top)).collect();
        let mark_x: Vec<f32> = marks.iter().map(|(d, _)| x(*d)).collect();
        let hover_point = hovered.map(|(d, v)| (x(d), v as f32 / top));
        let color = theme.blue();
        let rule = theme.secondary;
        let plots = self.plots.clone();
        let plot = canvas(
            move |bounds, _, _| {
                plots.borrow_mut().insert(chart, bounds);
            },
            move |bounds, _, window, _| paint_steps(bounds, &xy, &mark_x, hover_point, color, rule, window),
        )
        .size_full();
        let dates: Vec<NaiveDate> = points.iter().map(|p| p.0).collect();
        let plots = self.plots.clone();
        let body = div()
            .id(SharedString::from(format!("line-{chart:?}")))
            .size_full()
            .child(plot)
            .on_mouse_move(cx.listener(move |page, event: &MouseMoveEvent, _, cx| {
                let Some(bounds) = plots.borrow().get(&chart).copied() else { return };
                let fraction = ((f32::from(event.position.x) - f32::from(bounds.origin.x)) / f32::from(bounds.size.width).max(1.)).clamp(0., 1.);
                let day = first + Duration::days((fraction * span).round() as i64);
                let index = dates.iter().rposition(|d| *d <= day).unwrap_or(0);
                page.set_hover(Some((chart, index)), cx);
            }))
            .on_hover(cx.listener(move |page, hovered: &bool, _, cx| {
                if !*hovered && page.hover.is_some_and(|(c, _)| c == chart) {
                    page.set_hover(None, cx);
                }
            }))
            .into_any_element();
        let labels = vec![(0., day_label(first)), (0.42, day_label(first + Duration::days((span / 2.) as i64))), (0.84, day_label(last))];
        let caption = match hovered {
            Some((day, value)) => {
                let released: Vec<&str> = marks.iter().filter(|(d, _)| *d == day).map(|(_, l)| l.as_str()).collect();
                let released = if released.is_empty() { String::new() } else { format!(" · released {}", released.join(", ")) };
                Self::caption(format!("{}: {} {noun}{released}", day_label(day), count(value)), true, theme)
            }
            None => Self::caption(note.unwrap_or_else(|| "Hover for values.".into()), false, theme),
        };
        div().flex().flex_col().gap_2().child(Self::chart_title(title, theme)).child(Self::plot_frame(max, height, labels, theme, body)).child(caption).into_any_element()
    }

    /// A count by week or month as bars.
    #[allow(clippy::too_many_arguments)]
    fn bar_chart(&self, chart: Chart, title: &str, points: &[(NaiveDate, i64)], monthly: bool, noun: &str, caption: &str, empty: &str, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        if points.is_empty() {
            return div().flex().flex_col().gap_2().child(Self::chart_title(title, theme)).child(Self::caption(empty.into(), true, theme)).into_any_element();
        }
        let height = 150.;
        let max = points.iter().map(|p| p.1).max().unwrap_or(1);
        let top = (*ticks(max).last().unwrap_or(&1)).max(1) as f32;
        let hovered = self.hovered(chart);
        let color = theme.blue();
        let body = div()
            .size_full()
            .flex()
            .flex_row()
            .children(points.iter().enumerate().map(|(i, (_, value))| {
                div()
                    .id(SharedString::from(format!("bar-{chart:?}-{i}")))
                    .flex_1()
                    .h_full()
                    .flex()
                    .flex_col()
                    .justify_end()
                    .items_center()
                    .on_hover(cx.listener(move |page, hovered: &bool, _, cx| {
                        if *hovered {
                            page.set_hover(Some((chart, i)), cx);
                        } else if page.hover == Some((chart, i)) {
                            page.set_hover(None, cx);
                        }
                    }))
                    .child(div().w(relative(0.7)).max_w(px(28.)).h(px(*value as f32 / top * height)).rounded_t(px(3.)).bg(color.opacity(if hovered.is_none() || hovered == Some(i) { 1. } else { 0.5 })))
            }))
            .into_any_element();
        let every = points.len().div_ceil(6).max(1);
        let n = points.len() as f32;
        let labels = points
            .iter()
            .enumerate()
            .filter(|(i, _)| i % every == 0)
            .map(|(i, (d, _))| (i as f32 / n, if monthly { d.format("%b %Y").to_string() } else { d.format("%-d %b").to_string() }))
            .collect();
        let caption = match hovered.and_then(|i| points.get(i)) {
            Some((day, value)) => {
                let when = if monthly { day.format("%B %Y").to_string() } else { format!("Week of {}", day_label(*day)) };
                Self::caption(format!("{when}: {} {noun}", count(*value)), true, theme)
            }
            None => Self::caption(caption.to_string(), false, theme),
        };
        div().flex().flex_col().gap_2().child(Self::chart_title(title, theme)).child(Self::plot_frame(max, height, labels, theme, body)).child(caption).into_any_element()
    }

    // MARK: Parts

    fn releases_part(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let overview = self.overview.clone();
        let usage = &overview.usage;
        let releases = self.releases_in_view();
        let shown = self.shown_releases(&releases, cx);
        let now = Utc::now();
        let tiles = div()
            .flex()
            .flex_row()
            .flex_wrap()
            .gap_3()
            .child(Self::tile(
                "Downloads",
                count(usage.downloads),
                usage.downloads_lately.map(|n| format!("{} in the last 30 days", count(n))).unwrap_or_else(|| "Every release asset, as GitHub counts them".into()),
                theme,
            ))
            .child(Self::tile("Stars", count(usage.stars), format!("{} in the last 30 days", count(usage.stars_lately)), theme))
            .child(Self::tile("Releases", count(overview.published as i64), plural(usage.repositories.len(), "repository", "repositories"), theme))
            .when_some(overview.latest.clone(), |d, (tag, repo, at)| d.child(Self::tile("Latest", tag, format!("{} · {}", short(&repo), crate::format::relative_date(at, now)), theme)));
        let downloads = if usage.downloads_over_time.len() >= 2 {
            let since = day_label(usage.downloads_over_time[0].0);
            self.line_chart(Chart::Downloads, "Downloads", &usage.downloads_over_time, "downloads", Some(format!("Recorded once a day since {since}, as GitHub keeps only the running total.")), &[], theme, cx)
        } else {
            div()
                .flex()
                .flex_col()
                .gap_2()
                .child(Self::chart_title("Downloads", theme))
                .child(Self::caption("GitHub keeps only each asset's running total, so the pilot records it once a day from its first fetch. The line starts once there are two days to draw.".into(), true, theme))
                .into_any_element()
        };
        let by_month = self.bar_chart(Chart::ByMonth, "Downloads by release month", &usage.downloads_by_month, true, "downloads of releases published then", "Each release's downloads so far, by the month it came out. Hover for values.", "No published releases yet.", theme, cx);
        let stars_note = (usage.stars_before > 0).then(|| format!("Starts at {} for stars older than the {} newest of a repository.", count(usage.stars_before), crate::format::thousands(STAR_REACH)));
        let stars = self.line_chart(Chart::Stars, "Stars", &usage.stars_over_time, "stars", stars_note, &overview.marks, theme, cx);
        let new_stars = self.bar_chart(
            Chart::NewStars,
            if usage.weekly { "New stars by week" } else { "New stars by month" },
            &usage.new_stars,
            !usage.weekly,
            "new stars",
            "Stars from those still starring, by when they starred. Hover for values.",
            "No stars yet.",
            theme,
            cx,
        );
        div()
            .flex()
            .flex_col()
            .child(tiles)
            .child(Self::section("Over time", None, theme))
            .child(div().flex().flex_col().gap_6().child(downloads).child(by_month).child(stars).child(new_stars))
            .child(Self::section("Repositories", Some(usage.repositories.len()), theme))
            .child(self.repositories_table(theme, cx))
            .child(Self::section("Releases", Some(shown.len()), theme))
            .child(self.releases_table(&shown, !releases.is_empty(), theme, cx))
            .child(self.stargazers_section(theme, cx))
            .into_any_element()
    }

    fn milestones_part(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let Some(data) = self.data.clone() else { return div().into_any_element() };
        let shown = self.shown_groups(&self.groups, cx);
        if shown.is_empty() {
            let (title, detail) = if self.groups.is_empty() {
                ("No milestones", "Milestones in the org's repositories show here.")
            } else {
                ("No matching milestones", "Try another search, or show closed ones too.")
            };
            return div()
                .flex()
                .flex_col()
                .items_center()
                .gap_1()
                .pt_12()
                .child(div().text_lg().text_color(theme.fg).child(title))
                .child(div().text_sm().text_color(theme.secondary).child(detail))
                .into_any_element();
        }
        let releases: Vec<Release> = data.history.as_ref().map(|h| h.releases.iter().filter(|r| self.visible(&r.repo)).cloned().collect()).unwrap_or_default();
        div()
            .flex()
            .flex_col()
            .children(shown.into_iter().map(|group| {
                let issues: Vec<&MilestoneIssue> = group.repos().flat_map(|repo| data.issues.get(&(repo.to_string(), group.key.clone())).into_iter().flatten()).collect();
                let in_progress = issues.iter().filter(|i| i.in_progress).count();
                let merged = issues.iter().filter(|i| i.merged_pr).count();
                let release = release_for(group, &releases);
                let open = self.expanded_milestone.as_deref() == Some(group.key.as_str());
                let key = group.key.clone();
                let repos = group.repos().map(short).collect::<Vec<_>>().join(", ");
                div()
                    .flex()
                    .flex_col()
                    .border_b_1()
                    .border_color(theme.grid)
                    .child(
                        div()
                            .id(SharedString::from(format!("milestone-{}", group.key)))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_4()
                            .px_2()
                            .py_2()
                            .cursor_pointer()
                            .when(open, |d| d.bg(theme.row_selected))
                            .hover(|s| s.bg(theme.row_selected))
                            .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                                page.expanded_milestone = if page.expanded_milestone.as_deref() == Some(key.as_str()) { None } else { Some(key.clone()) };
                                cx.notify();
                            }))
                            .child(gpui::svg().path(if open { "icons/chevron_down.svg" } else { "icons/chevron_right.svg" }).size(px(12.)).flex_none().text_color(theme.tertiary))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .flex()
                                    .flex_col()
                                    .gap_0p5()
                                    .child(
                                        div()
                                            .flex()
                                            .flex_row()
                                            .items_center()
                                            .gap_2()
                                            .child(div().min_w_0().truncate().text_sm().font_weight(FontWeight::MEDIUM).child(group.title.clone()))
                                            .when(!group.is_open(), |d| d.child(div().flex_none().text_xs().text_color(theme.slot(6)).child("Closed")))
                                            .when_some(release, |d, release| {
                                                d.child(
                                                    div()
                                                        .flex_none()
                                                        .flex()
                                                        .flex_row()
                                                        .items_center()
                                                        .gap_1()
                                                        .text_xs()
                                                        .text_color(if release.is_draft { theme.secondary } else { theme.good() })
                                                        .child(gpui::svg().path("icons/box.svg").size(px(11.)).text_color(if release.is_draft { theme.secondary } else { theme.good() }))
                                                        .child(if release.is_draft { format!("Draft {}", release.tag_name) } else { format!("Released as {}", release.tag_name) }),
                                                )
                                            }),
                                    )
                                    .child(div().text_xs().text_color(theme.secondary).truncate().child(repos)),
                            )
                            .map(|d| match (group.is_open(), group.due_on(), group.closed_at()) {
                                (true, Some(due), _) => d.child(Self::due(due, theme)),
                                (false, _, Some(closed)) => d.child(div().flex_none().text_sm().text_color(theme.secondary).child(format!("Closed {}", crate::format::relative_date(closed, Utc::now())))),
                                _ => d,
                            })
                            .when(merged > 0, |d| {
                                d.child(
                                    div()
                                        .id(SharedString::from(format!("merged-{}", group.key)))
                                        .flex_none()
                                        .text_sm()
                                        .text_color(theme.secondary)
                                        .tooltip(|_, cx| cx.new(|_| Tooltip("Issues in it with a merged PR, from the issue history".into())).into())
                                        .child(format!("{merged} merged")),
                                )
                            })
                            .when(in_progress > 0, |d| d.child(div().flex_none().text_sm().text_color(theme.blue()).child(format!("{in_progress} in progress"))))
                            .child(Self::progress(group.closed(), group.total(), 120., theme)),
                    )
                    .when(open, |d| d.child(self.milestone_detail(group, &issues, release, theme, cx)))
            }))
            .into_any_element()
    }

    /// A milestone opened out: each repo's progress, its description and its
    /// issues from the issue history.
    fn milestone_detail(&self, group: &Group, issues: &[&MilestoneIssue], release: Option<&Release>, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let mut in_progress: Vec<&MilestoneIssue> = issues.iter().copied().filter(|i| i.in_progress).collect();
        in_progress.sort_by(|a, b| b.number.cmp(&a.number));
        let mut open: Vec<&MilestoneIssue> = issues.iter().copied().filter(|i| i.open && !i.in_progress).collect();
        open.sort_by(|a, b| b.number.cmp(&a.number));
        let mut closed: Vec<&MilestoneIssue> = issues.iter().copied().filter(|i| !i.open).collect();
        closed.sort_by(|a, b| b.closed_at.cmp(&a.closed_at));
        let heading = |text: String| div().pt_2().text_xs().text_color(theme.secondary).child(text);
        let issue_rows = |title: &str, list: Vec<&MilestoneIssue>, cx: &mut Context<Self>| -> Option<AnyElement> {
            if list.is_empty() {
                return None;
            }
            Some(
                div()
                    .flex()
                    .flex_col()
                    .child(heading(format!("{title} ({})", list.len())))
                    .children(list.into_iter().map(|issue| {
                        let open_item = crate::activity::OpenItem { issue_id: Some(issue.id.clone()), url: issue.url.clone() };
                        div()
                            .id(SharedString::from(format!("ms-issue-{}", issue.id)))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .py_0p5()
                            .text_sm()
                            .cursor_pointer()
                            .hover(|s| s.bg(theme.row_selected))
                            .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(crate::activity::OpenItem { issue_id: open_item.issue_id.clone(), url: open_item.url.clone() })))
                            .child(gpui::svg().path(crate::icons::issue(issue.open)).size(px(13.)).flex_none().text_color(if issue.open { theme.good() } else { theme.slot(6) }))
                            .child(div().flex_1().min_w_0().truncate().child(issue.title.clone()))
                            .when(!issue.assignees.is_empty(), |d| d.child(div().flex_none().max_w(px(160.)).truncate().text_color(theme.secondary).child(issue.assignees.join(", "))))
                            .when_some(issue.status.clone(), |d, status| d.child(div().flex_none().text_color(theme.secondary).child(status)))
                            .child(div().flex_none().text_color(theme.secondary).child(format!("{}#{}", short(&issue.repo), issue.number)))
                            .into_any_element()
                    }))
                    .into_any_element(),
            )
        };
        let sections: Vec<AnyElement> = [("In progress", in_progress), ("Open", open), ("Closed", closed)].into_iter().filter_map(|(title, list)| issue_rows(title, list, cx)).collect();
        let shortfall = (issues.len() as i64) < group.issue_total();
        div()
            .flex()
            .flex_col()
            .gap_2()
            .px_6()
            .py_3()
            .bg(theme.tile)
            .when_some(release, |d, release| {
                let id = release.id.clone();
                let when = if release.is_draft { "draft".to_string() } else { local_day(release.date()).format("%-d %b %Y").to_string() };
                d.child(
                    div()
                        .flex()
                        .flex_row()
                        .gap_2()
                        .text_sm()
                        .child(div().text_color(theme.secondary).child("Release"))
                        .child(Self::link(format!("ms-release-{}", group.key), format!("{} · {when}", release.title()), theme).on_click(cx.listener(move |page, _: &ClickEvent, window, cx| page.show_release(id.clone(), window, cx)))),
                )
            })
            .child(heading(if group.milestones.len() == 1 { "Repository".into() } else { "Repositories".into() }))
            .children(group.milestones.iter().map(|m| {
                let url = m.url.clone();
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(div().text_sm().truncate().child(m.repo.clone()))
                            .map(|d| match (m.is_open, m.due_on) {
                                (false, _) => d.child(div().text_xs().text_color(theme.slot(6)).child("Closed")),
                                (true, Some(due)) if Some(due) != group.due_on() => d.child(Self::due(due, theme)),
                                _ => d,
                            }),
                    )
                    .child(Self::progress(m.closed(), m.total(), 120., theme))
                    .child(Self::link(format!("ms-gh-{}", m.id), "GitHub", theme).on_click(move |_, _, cx| cx.open_url(&url)))
            }))
            .when_some(group.description().map(str::to_string), |d, description| d.child(heading("Description".into())).child(crate::markdown::markdown(&format!("ms-desc-{}", group.key), &description, theme)))
            .children(sections)
            .when(shortfall, |d| {
                d.child(div().pt_1().text_xs().text_color(theme.tertiary).child(format!(
                    "GitHub counts {}; the issue history has {}, as it keeps only those closed since its start.",
                    plural(group.issue_total() as usize, "issue", "issues"),
                    issues.len()
                )))
            })
    }
}

/// Paints a stepped line with the area under it, dashed release rules and
/// the hovered point. Coordinates are fractions of the plot.
fn paint_steps(bounds: Bounds<Pixels>, points: &[(f32, f32)], marks: &[f32], hovered: Option<(f32, f32)>, color: Hsla, rule: Hsla, window: &mut Window) {
    let (x0, y0) = (f32::from(bounds.origin.x), f32::from(bounds.origin.y));
    let (width, height) = (f32::from(bounds.size.width), f32::from(bounds.size.height));
    let at = |(x, y): (f32, f32)| point(px(x0 + x * width), px(y0 + height - y * height));
    for x in marks {
        let mut y = 0.;
        while y < height {
            window.paint_quad(fill(Bounds::new(point(px(x0 + x * width), px(y0 + y)), size(px(1.), px(3.))), rule.opacity(0.35)));
            y += 6.;
        }
    }
    if points.is_empty() {
        return;
    }
    // Step: across at the old value, then up to the new one.
    let mut steps: Vec<Point> = vec![at(points[0])];
    for pair in points.windows(2) {
        steps.push(at((pair[1].0, pair[0].1)));
        steps.push(at(pair[1]));
    }
    let mut area = PathBuilder::fill();
    area.move_to(point(steps[0].x, px(y0 + height)));
    for p in &steps {
        area.line_to(*p);
    }
    area.line_to(point(steps[steps.len() - 1].x, px(y0 + height)));
    area.close();
    if let Ok(path) = area.build() {
        window.paint_path(path, color.opacity(0.12));
    }
    if steps.len() >= 2 {
        let mut line = PathBuilder::stroke(px(2.));
        line.move_to(steps[0]);
        for p in &steps[1..] {
            line.line_to(*p);
        }
        if let Ok(path) = line.build() {
            window.paint_path(path, color);
        }
    }
    if let Some(p) = hovered {
        let center = at(p);
        window.paint_quad(fill(Bounds::new(point(center.x, px(y0)), size(px(1.), px(height))), rule.opacity(0.5)));
        let r = 4.;
        window.paint_quad(fill(Bounds::new(point(center.x - px(r), center.y - px(r)), size(px(r * 2.), px(r * 2.))), color).corner_radii(px(r)));
    }
}

type Point = gpui::Point<Pixels>;

impl Render for ReleasesPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let has_history = self.data.as_ref().is_some_and(|d| d.history.is_some());
        let count = match self.part {
            Part::Milestones => self.shown_groups(&self.groups, cx).len(),
            Part::Releases => {
                let releases = self.releases_in_view();
                self.shown_releases(&releases, cx).len()
            }
        };
        let body = if self.org.is_none() {
            div().text_sm().text_color(theme.secondary).child("Open a folder to choose an org.").into_any_element()
        } else if !has_history {
            let text = match (&self.error, self.syncing || self.data.is_none()) {
                (Some(error), false) => format!("Couldn't load releases: {error}"),
                _ => "Fetching milestones, releases and stars. A first fetch reads every release and stargazer, so it can take a minute.".into(),
            };
            div().text_sm().text_color(theme.secondary).child(text).into_any_element()
        } else {
            match self.part {
                Part::Releases => self.releases_part(&theme, cx),
                Part::Milestones => self.milestones_part(&theme, cx),
            }
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .text_color(theme.fg)
            .font_weight(FontWeight::NORMAL)
            .child(self.toolbar(count, &theme, cx))
            .when_some(self.error.clone().filter(|_| has_history), |d, error| d.child(div().px_4().py_1().text_xs().text_color(theme.critical()).child(format!("Couldn't fetch: {error}"))))
            .child(div().id("releases-body").flex_1().min_h_0().overflow_y_scroll().px_4().pb_6().pt_3().child(body))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(y: i32, m: u32, d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, d).unwrap()
    }

    #[test]
    fn new_stars_fill_quiet_weeks_and_months() {
        let per_day: BTreeMap<NaiveDate, i64> = [(day(2026, 11, 2), 2), (day(2026, 11, 4), 1), (day(2026, 11, 18), 3)].into_iter().collect();
        // Mondays 2, 9 and 16 November.
        assert_eq!(new_stars(&per_day, true), vec![(day(2026, 11, 2), 3), (day(2026, 11, 9), 0), (day(2026, 11, 16), 3)]);
        let per_day: BTreeMap<NaiveDate, i64> = [(day(2026, 1, 31), 1), (day(2026, 4, 2), 2)].into_iter().collect();
        assert_eq!(new_stars(&per_day, false), vec![(day(2026, 1, 1), 1), (day(2026, 2, 1), 0), (day(2026, 3, 1), 0), (day(2026, 4, 1), 2)]);
        assert!(new_stars(&BTreeMap::new(), true).is_empty());
    }

    #[test]
    fn milestones_match_releases_by_tag_or_name() {
        let at = Utc::now();
        let milestone = |repo: &str, title: &str| Milestone {
            id: format!("{repo}{title}"),
            repo: repo.into(),
            number: 1,
            title: title.into(),
            description: None,
            due_on: None,
            is_open: true,
            closed_at: None,
            updated_at: at,
            url: String::new(),
            open_issues: 1,
            closed_issues: 2,
            open_pull_requests: 0,
            closed_pull_requests: 1,
        };
        let release = |repo: &str, tag: &str, draft: bool| Release {
            id: format!("{repo}{tag}{draft}"),
            repo: repo.into(),
            name: None,
            tag_name: tag.into(),
            url: String::new(),
            created_at: at,
            published_at: (!draft).then_some(at),
            is_draft: draft,
            is_prerelease: false,
            is_latest: false,
            author: None,
            notes: None,
            assets: Vec::new(),
        };
        let groups = groups(&[milestone("o/a", "1.2"), milestone("o/b", "1.2 "), milestone("o/c", "Version")], &|_| true);
        assert_eq!(groups.len(), 2);
        let both = groups.iter().find(|g| g.key == "1.2").unwrap();
        assert_eq!((both.closed(), both.total()), (6, 8));
        let releases = [release("o/b", "v1.2", true), release("o/a", "V1.2", false), release("o/z", "1.2", false)];
        // The published one wins over a draft; another repo's never matches.
        assert_eq!(release_for(both, &releases).unwrap().repo, "o/a");
        assert!(milestone_for(&releases[2], &groups).is_none());
        assert_eq!(normalised("version"), "version");
    }

    #[test]
    fn star_history_counts_days_and_keeps_one_of_each() {
        let now = Utc::now();
        let at = |h: i64| now - Duration::hours(h);
        let person = |login: &str, starred_at| Stargazer { login: login.into(), name: None, avatar_url: None, company: None, location: None, followers: 0, starred_at };
        let mut history = StarHistory::default();
        history.add(&[at(1), at(2)], vec![person("a", at(1)), person("b", at(2))]);
        history.add(&[at(0)], vec![person("a", at(0))]);
        assert_eq!(history.days.iter().map(|d| d.count).sum::<i64>(), 3);
        assert_eq!(history.stargazers.iter().map(|s| s.login.as_str()).collect::<Vec<_>>(), ["a", "b"]);
        assert_eq!(history.newest, Some(at(0)));
    }
}
