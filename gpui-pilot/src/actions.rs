//! The org's GitHub Actions runs, synced by the pilot itself as Gannin's
//! `ActionsStore.sync` does, into the same `ActionsHistory` file the CI
//! page reads (`data.rs`). Runs only: the page doesn't read jobs, and jobs
//! already held (from an earlier copy) are kept.
//!
//! Runs are only in the REST API, repo by repo. Repos pushed to since 60
//! days before the range are listed (scheduled workflows run without
//! pushes), then each is backfilled to the range's start and topped up
//! since its last sync, a day back for re-runs. A range GitHub caps at
//! 1,000 runs is halved until each half fits. Four repos are fetched at
//! once, and runs older than 190 days are dropped.

use chrono::{DateTime, Datelike, Duration, Local, TimeZone, Utc};
use serde_json::{json, Map, Value};
use std::collections::HashSet;
use std::sync::Mutex;

/// Every ten minutes, as Gannin's default for Actions.
const EVERY: Duration = Duration::minutes(10);
const OVERLAP: Duration = Duration::hours(24);
const QUIET_REACH: Duration = Duration::days(60);
const KEPT_DAYS: i64 = 190;
const CONCURRENCY: usize = 4;

/// The orgs syncing now, so two never run at once.
static SYNCING: Mutex<Vec<String>> = Mutex::new(Vec::new());

fn iso(time: DateTime<Utc>) -> String {
    time.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn time(value: &Value) -> Option<DateTime<Utc>> {
    value.as_str().and_then(|t| t.parse().ok())
}

/// The local Monday on or before `days` before now, as
/// `MetricsStore.coverageStart`: the window's start week.
fn coverage_start(days: i64, now: DateTime<Utc>) -> DateTime<Utc> {
    let local = (now - Duration::days(days)).with_timezone(&Local).date_naive();
    let monday = local - Duration::days(local.weekday().num_days_from_monday() as i64);
    Local.from_local_datetime(&monday.and_hms_opt(0, 0, 0).unwrap_or_default()).earliest().map(|t| t.with_timezone(&Utc)).unwrap_or(now)
}

/// Brings the org's runs up to date for a window of `days` (and the one
/// before it), unless it was synced in the last ten minutes and covers it.
/// `force` (Refresh) syncs anyway. Ok(true) when the file changed. Blocks:
/// call off the main thread.
pub fn sync(org: &str, days: i64, force: bool) -> Result<bool, String> {
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
    let token = crate::auth::token().ok_or("Sign in to fetch the workflow runs.")?;
    let path = crate::data::cache_path(org);
    let mut history: Value = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).filter(|h: &Value| h["version"] == crate::data::CURRENT_VERSION).unwrap_or_else(|| {
        json!({ "version": crate::data::CURRENT_VERSION, "orgLogin": org, "syncedAt": iso(DateTime::UNIX_EPOCH), "repositories": {}, "runs": {}, "jobs": {}, "jobsAttempt": {} })
    });
    let now = Utc::now();
    let start = coverage_start(days * 2, now);
    let repos_held = history["repositories"].as_object().cloned().unwrap_or_default();
    let fresh = time(&history["syncedAt"]).is_some_and(|at| now - at < EVERY);
    let covered = repos_held.values().all(|r| time(&r["coveredFrom"]).is_some_and(|c| c <= start));
    if !force && fresh && covered && !repos_held.is_empty() {
        return Ok(false);
    }
    if !force && !repos_held.is_empty() && crate::github::should_hold_off() {
        return Ok(false);
    }

    // Repos the org's settings leave out, unless a project names them.
    let config = crate::projects::effective_config(org);
    let named: HashSet<String> = crate::projects::load(org).projects.into_iter().flat_map(|p| p.repos).map(|r| r.to_lowercase()).collect();
    let excluded: HashSet<String> = config["excludedRepos"].as_array().into_iter().flatten().filter_map(|r| r.as_str()).map(str::to_lowercase).filter(|r| !named.contains(r)).collect();

    let listed = repositories(&token, org, start - QUIET_REACH)?;
    let runs_held = history["runs"].as_object().cloned().unwrap_or_default();
    let mut plans: Vec<(String, Option<String>, Vec<(DateTime<Utc>, DateTime<Utc>)>)> = Vec::new();
    for (name, branch) in listed.into_iter().filter(|(n, _)| !excluded.contains(&n.to_lowercase())) {
        let held = repos_held.get(&name);
        let covered_from = held.and_then(|r| time(&r["coveredFrom"]));
        let mut ranges = Vec::new();
        match (covered_from, held.and_then(|r| time(&r["syncedAt"]))) {
            (Some(from), Some(synced)) => {
                if start < from {
                    ranges.push((start, from));
                }
                let unfinished = runs_held.values().filter(|r| r["repo"] == name.as_str() && r["status"] != "completed").filter_map(|r| time(&r["createdAt"])).min();
                let top_up = (synced - OVERLAP).min(unfinished.unwrap_or(DateTime::<Utc>::MAX_UTC));
                ranges.push((top_up.max(start), now));
            }
            _ => ranges.push((start, now)),
        }
        plans.push((name, branch, ranges));
    }

    // Four repos at once; the first error stops the rest.
    let next = Mutex::new(0usize);
    let results: Mutex<Vec<(usize, Vec<Value>)>> = Mutex::new(Vec::new());
    let failure: Mutex<Option<String>> = Mutex::new(None);
    std::thread::scope(|scope| {
        for _ in 0..CONCURRENCY.min(plans.len()) {
            scope.spawn(|| loop {
                if failure.lock().map(|f| f.is_some()).unwrap_or(true) {
                    return;
                }
                let index = {
                    let Ok(mut n) = next.lock() else { return };
                    let i = *n;
                    *n += 1;
                    i
                };
                let Some((repo, _, ranges)) = plans.get(index) else { return };
                let mut runs = Vec::new();
                for (from, to) in ranges.iter().filter(|(f, t)| f < t) {
                    match workflow_runs(&token, repo, *from, *to) {
                        Ok(mut more) => runs.append(&mut more),
                        // Actions turned off, or the repo hidden from this token.
                        Err((404 | 410 | 451, _)) => {}
                        Err((403, body)) if !body.to_lowercase().contains("rate limit") => {}
                        Err((status, body)) => {
                            if let Ok(mut f) = failure.lock() {
                                f.get_or_insert(if status == 0 { body } else { format!("GitHub refused the runs for {repo} ({status})") });
                            }
                            return;
                        }
                    }
                }
                if let Ok(mut r) = results.lock() {
                    r.push((index, runs));
                }
            });
        }
    });
    if let Some(error) = failure.into_inner().ok().flatten() {
        return Err(error);
    }

    let runs = history["runs"].as_object_mut().ok_or("bad history")?;
    let mut repositories = repos_held;
    for (index, fetched) in results.into_inner().unwrap_or_default() {
        for mut run in fetched {
            let id = run["id"].to_string();
            // GitHub stops listing a PR once it merges: keep the one listed
            // when the run was fetched before.
            let listed = run["pullRequests"].as_array().is_some_and(|a| !a.is_empty());
            if !listed {
                if let Some(held) = runs.get(&id).map(|r| r["pullRequests"].clone()).filter(|p| p.as_array().is_some_and(|a| !a.is_empty())) {
                    run["pullRequests"] = held;
                }
            }
            runs.insert(id, run);
        }
        let (name, branch, _) = &plans[index];
        let covered_from = repositories.get(name).and_then(|r| time(&r["coveredFrom"])).map_or(start, |c| c.min(start));
        repositories.insert(name.clone(), json!({ "name": name, "defaultBranch": branch, "coveredFrom": iso(covered_from), "syncedAt": iso(now) }));
    }
    // What's older than the kept days goes.
    let cutoff = now - Duration::days(KEPT_DAYS);
    let old: Vec<String> = runs.iter().filter(|(_, r)| time(&r["createdAt"]).is_some_and(|c| c < cutoff)).map(|(id, _)| id.clone()).collect();
    for id in &old {
        runs.remove(id);
    }
    for key in ["jobs", "jobsAttempt"] {
        if let Some(map) = history[key].as_object_mut() {
            for id in &old {
                map.remove(id);
            }
        }
    }
    for repo in repositories.values_mut() {
        if time(&repo["coveredFrom"]).is_some_and(|c| c < cutoff) {
            repo["coveredFrom"] = json!(iso(cutoff));
        }
    }
    history["repositories"] = Value::Object(repositories);
    history["syncedAt"] = json!(iso(now));
    crate::cache::write(crate::cache::Kind::Actions, org, &serde_json::to_vec(&history).unwrap_or_default()).map_err(|e| format!("Couldn't save the runs: {e}"))?;
    Ok(true)
}

/// Non-archived repos pushed to since `since`, most recent first, with
/// their default branch (`actionsRepositories`). A personal account's own
/// repos the same way, through `repositoryOwner`.
fn repositories(token: &str, org: &str, since: DateTime<Utc>) -> Result<Vec<(String, Option<String>)>, String> {
    let query = "query($login: String!, $cursor: String) { repositoryOwner(login: $login) { repositories(first: 100, after: $cursor, isArchived: false, ownerAffiliations: [OWNER], orderBy: { field: PUSHED_AT, direction: DESC }) { pageInfo { hasNextPage endCursor } nodes { nameWithOwner pushedAt defaultBranchRef { name } } } } }";
    let mut repos = Vec::new();
    let mut cursor: Option<String> = None;
    for _ in 0..20 {
        let data = crate::github::graphql(token, query, json!({ "login": org, "cursor": cursor })).map_err(|e| e.to_string())?;
        let page = &data["repositoryOwner"]["repositories"];
        let mut reached_older = false;
        for node in page["nodes"].as_array().into_iter().flatten() {
            let pushed = time(&node["pushedAt"]).unwrap_or(DateTime::UNIX_EPOCH);
            if pushed < since {
                reached_older = true;
                continue;
            }
            if let Some(name) = node["nameWithOwner"].as_str() {
                repos.push((name.to_string(), node["defaultBranchRef"]["name"].as_str().map(str::to_string)));
            }
        }
        cursor = page["pageInfo"]["endCursor"].as_str().map(str::to_string);
        if reached_older || page["pageInfo"]["hasNextPage"] != true || cursor.is_none() {
            break;
        }
    }
    Ok(repos)
}

/// Runs created in `[from, to)` in one repo, in Gannin's `WorkflowRun`
/// shape. A range holding more than GitHub's 1,000 is split in half.
fn workflow_runs(token: &str, repo: &str, from: DateTime<Utc>, to: DateTime<Utc>) -> Result<Vec<Value>, (u16, String)> {
    let created = format!("{}..{}", iso(from), iso(to - Duration::seconds(1)));
    let mut runs = Vec::new();
    for page in 1..=10 {
        let path = format!("repos/{repo}/actions/runs?created={}&per_page=100&page={page}&exclude_pull_requests=true", created.replace(':', "%3A").replace('+', "%2B"));
        let response = crate::github::rest_get(token, &path)?;
        let total = response["total_count"].as_u64().unwrap_or(0) as usize;
        if page == 1 && total > 1000 && to - from > Duration::hours(1) {
            let middle = from + (to - from) / 2;
            let mut first = workflow_runs(token, repo, from, middle)?;
            first.extend(workflow_runs(token, repo, middle, to)?);
            return Ok(first);
        }
        let listed = response["workflow_runs"].as_array().cloned().unwrap_or_default();
        runs.extend(listed.iter().filter_map(|r| model(r, repo)));
        if listed.len() < 100 || runs.len() >= total.min(1000) {
            break;
        }
    }
    Ok(runs)
}

/// A REST run as Gannin stores it (`RawRun.model`).
fn model(r: &Value, repo: &str) -> Option<Value> {
    let id = r["id"].as_i64()?;
    let workflow_id = r["workflow_id"].as_i64()?;
    let path = r["path"].as_str().map(|p| p.split('@').next().unwrap_or(p).to_string());
    let name = r["name"].as_str().map(str::to_string).or_else(|| path.as_ref().and_then(|p| p.rsplit('/').next().map(str::to_string))).unwrap_or_else(|| format!("Workflow {workflow_id}"));
    let suffix = format!("/repos/{}", repo.to_lowercase());
    // Only PRs into this repo: GitHub also lists other repos' PRs whose head
    // is this branch, such as an upstream's from a fork.
    let prs: Vec<i64> = r["pull_requests"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|p| p["base"]["repo"]["url"].as_str().is_some_and(|u| u.to_lowercase().ends_with(&suffix)))
        .filter_map(|p| p["number"].as_i64())
        .collect();
    let mut run = Map::new();
    run.insert("id".into(), json!(id));
    run.insert("repo".into(), json!(repo));
    run.insert("workflowID".into(), json!(workflow_id));
    run.insert("name".into(), json!(name));
    run.insert("path".into(), json!(path.unwrap_or_default()));
    run.insert("event".into(), r["event"].clone());
    run.insert("branch".into(), r["head_branch"].clone());
    run.insert("headSha".into(), r["head_sha"].clone());
    run.insert("runNumber".into(), r["run_number"].clone());
    run.insert("attempt".into(), json!(r["run_attempt"].as_i64().unwrap_or(1)));
    run.insert("status".into(), json!(r["status"].as_str().unwrap_or("completed")));
    run.insert("conclusion".into(), r["conclusion"].clone());
    run.insert("createdAt".into(), json!(iso(time(&r["created_at"])?)));
    if let Some(started) = time(&r["run_started_at"]) {
        run.insert("startedAt".into(), json!(iso(started)));
    }
    run.insert("updatedAt".into(), json!(iso(time(&r["updated_at"])?)));
    run.insert("actor".into(), r["actor"]["login"].clone());
    run.insert("url".into(), r["html_url"].clone());
    run.insert("pullRequests".into(), json!(prs));
    Some(Value::Object(run))
}
