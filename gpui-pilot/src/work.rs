//! What the menu bar's "Your work" shows, read from Gannin's caches: the
//! signed-in login, PRs whose review is asked of you and your own open PRs
//! with what they need. Gannin fetches these live (`EngineerWatch`); here
//! they're as fresh as the org's last refresh. Mergeability isn't cached,
//! so Conflicts never shows. Team review requests aren't resolved.

use chrono::{DateTime, Utc};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::{Command, Stdio};

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
}

/// The signed-in login from Gannin's `viewer` preference (JSON in a data
/// value), read with the system's tools.
fn viewer() -> Option<String> {
    #[derive(Deserialize)]
    struct Viewer {
        login: String,
    }
    let output = Command::new("/bin/sh")
        .arg("-c")
        .arg("/usr/bin/defaults export dev.andon.gannin - | /usr/bin/plutil -extract viewer raw -o - - | /usr/bin/base64 -d")
        .stdin(Stdio::null())
        .output()
        .ok()?;
    serde_json::from_slice::<Viewer>(&output.stdout).ok().map(|v| v.login)
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
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join("Library/Application Support/PullRequests").join(format!("{org}.json"))
}

/// Reads the org's PR cache as `login` (the pilot's signed-in viewer),
/// else as whoever Gannin is signed in as; call off the main thread (it
/// can be tens of MB).
pub fn load(org: &str, login: Option<String>) -> Work {
    let login = login.or_else(viewer);
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
