//! What the menu bar's "Your work" shows: PRs whose review is asked of you,
//! your own open PRs with what they need, and issues assigned to you.
//! Signed in, it's live, from `EngineerWatch`'s one query across every org.
//! Signed out, it's read from the org's PR cache, as fresh as its last
//! sync, where mergeability isn't kept (so Conflicts can't show) and team
//! review requests aren't resolved.

use chrono::{DateTime, Utc};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Clone)]
pub struct Pr {
    pub repo: String,
    pub number: i64,
    pub title: String,
    pub url: String,
    pub author: Option<String>,
    pub draft: bool,
    pub review: Option<String>,
    pub checks: Option<String>,
    /// MERGEABLE, CONFLICTING or UNKNOWN; live only.
    pub mergeable: Option<String>,
    pub updated: DateTime<Utc>,
}

/// An issue assigned to you, from the live query.
#[derive(Clone)]
pub struct Issue {
    pub id: String,
    pub repo: String,
    pub number: i64,
    pub title: String,
    pub url: String,
    pub updated: DateTime<Utc>,
}

impl Pr {
    fn failing(&self) -> bool {
        matches!(self.checks.as_deref(), Some("FAILURE" | "ERROR"))
    }

    /// What it needs from you as its author, as `PullRequestItem.needs`.
    pub fn needs(&self) -> Option<&'static str> {
        if self.failing() {
            return Some("Checks failing");
        }
        if self.review.as_deref() == Some("CHANGES_REQUESTED") {
            return Some("Changes requested");
        }
        if self.mergeable.as_deref() == Some("CONFLICTING") {
            return Some("Conflicts");
        }
        if self.review.as_deref() == Some("APPROVED") && self.checks.as_deref() != Some("PENDING") && !self.draft {
            return Some("Ready to merge");
        }
        None
    }

    /// The line under its title when it needs nothing.
    pub fn standing(&self) -> &'static str {
        self.needs().unwrap_or(if self.draft {
            "Draft"
        } else if self.checks.as_deref() == Some("PENDING") {
            "Checks running"
        } else {
            "In review"
        })
    }

    pub fn short_repo(&self) -> &str {
        self.repo.rsplit('/').next().unwrap_or(&self.repo)
    }
}

#[derive(Default, Clone)]
pub struct Work {
    pub login: Option<String>,
    pub reviews: Vec<Pr>,
    pub mine: Vec<Pr>,
    /// Live: issues assigned to you in every org. Nil from the cache,
    /// where the Issues store answers instead.
    pub issues: Option<Vec<Issue>>,
    pub live: bool,
}

const LIVE_PR_FIELDS: &str = "id number title url isDraft createdAt updatedAt reviewDecision mergeable author { login } repository { nameWithOwner } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }";

/// `EngineerWatch.engineerWork()`: one query, three searches, every org.
pub fn load_live(token: &str, login: Option<String>) -> Result<Work, crate::github::Error> {
    let query = format!(
        "query {{ reviews: search(type: ISSUE, query: \"is:open is:pr review-requested:@me archived:false sort:updated-desc\", first: 40) {{ nodes {{ __typename ... on PullRequest {{ {LIVE_PR_FIELDS} }} }} }} mine: search(type: ISSUE, query: \"is:open is:pr author:@me archived:false sort:updated-desc\", first: 40) {{ nodes {{ __typename ... on PullRequest {{ {LIVE_PR_FIELDS} }} }} }} issues: search(type: ISSUE, query: \"is:open is:issue assignee:@me archived:false sort:updated-desc\", first: 25) {{ nodes {{ __typename ... on Issue {{ id number title url updatedAt repository {{ nameWithOwner }} }} }} }} }}"
    );
    let data = crate::github::graphql(token, &query, serde_json::json!({}))?;
    let pr = |node: &serde_json::Value| -> Option<Pr> {
        Some(Pr {
            repo: node["repository"]["nameWithOwner"].as_str()?.to_string(),
            number: node["number"].as_i64()?,
            title: node["title"].as_str()?.to_string(),
            url: node["url"].as_str()?.to_string(),
            author: node["author"]["login"].as_str().map(str::to_string),
            draft: node["isDraft"].as_bool().unwrap_or(false),
            review: node["reviewDecision"].as_str().map(str::to_string),
            checks: node["commits"]["nodes"].as_array().and_then(|n| n.last()).and_then(|c| c["commit"]["statusCheckRollup"]["state"].as_str()).map(str::to_string),
            mergeable: node["mergeable"].as_str().map(str::to_string),
            updated: node["updatedAt"].as_str()?.parse().ok()?,
        })
    };
    let list = |key: &str| -> Vec<serde_json::Value> { data[key]["nodes"].as_array().cloned().unwrap_or_default() };
    let issues = list("issues")
        .iter()
        .filter_map(|node| {
            Some(Issue {
                id: node["id"].as_str()?.to_string(),
                repo: node["repository"]["nameWithOwner"].as_str()?.to_string(),
                number: node["number"].as_i64()?,
                title: node["title"].as_str()?.to_string(),
                url: node["url"].as_str()?.to_string(),
                updated: node["updatedAt"].as_str()?.parse().ok()?,
            })
        })
        .collect();
    Ok(Work {
        login,
        reviews: list("reviews").iter().filter_map(pr).collect(),
        mine: list("mine").iter().filter_map(pr).collect(),
        issues: Some(issues),
        live: true,
    })
}

#[derive(Deserialize)]
struct Store {
    #[serde(rename = "pullRequests", default)]
    pull_requests: HashMap<String, Stored>,
}

#[derive(Deserialize)]
struct Stored {
    core: Core,
    workload: Option<Workload>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Core {
    number: i64,
    title: String,
    url: String,
    repo: String,
    author: Option<Person>,
}

#[derive(Deserialize)]
struct Person {
    login: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Workload {
    state: String,
    #[serde(default)]
    is_draft: bool,
    review_decision: Option<String>,
    checks: Option<String>,
    #[serde(default)]
    requested_reviewers: Vec<Person>,
    updated_at: DateTime<Utc>,
}

fn store_path(org: &str) -> PathBuf {
    crate::cache::path(crate::cache::Kind::PullRequests, org)
}

/// Reads the org's PR cache as `login`, else as the pilot's signed-in
/// viewer; call off the main thread (it can be tens of MB).
pub fn load(org: &str, login: Option<String>) -> Work {
    let login = login.or_else(|| crate::auth::saved_viewer().map(|v| v.login));
    let mut work = Work { login: login.clone(), ..Default::default() };
    let Some(login) = login else { return work };
    let Ok(bytes) = std::fs::read(store_path(org)) else { return work };
    let Ok(store) = serde_json::from_slice::<Store>(&bytes) else { return work };
    for stored in store.pull_requests.into_values() {
        let Some(workload) = stored.workload else { continue };
        if workload.state != "OPEN" {
            continue;
        }
        let author = stored.core.author.map(|a| a.login);
        let asked = workload.requested_reviewers.iter().any(|p| p.login == login);
        let pr = Pr {
            repo: stored.core.repo,
            number: stored.core.number,
            title: stored.core.title,
            url: stored.core.url,
            author: author.clone(),
            draft: workload.is_draft,
            review: workload.review_decision,
            checks: workload.checks,
            mergeable: None,
            updated: workload.updated_at,
        };
        if author.as_deref() == Some(login.as_str()) {
            work.mine.push(pr);
        } else if asked && !pr.draft {
            work.reviews.push(pr);
        }
    }
    work.reviews.sort_by_key(|p| std::cmp::Reverse(p.updated));
    work.mine.sort_by_key(|p| std::cmp::Reverse(p.updated));
    work
}
