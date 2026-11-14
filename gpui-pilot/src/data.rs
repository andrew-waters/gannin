//! The Swift app's Actions cache, read as it is on disk:
//! `~/Library/Application Support/Actions/<org>.json`, written by
//! `OrgJSONCache` (dates as ISO 8601). Only the fields the page uses are
//! decoded; jobs are skipped.

use chrono::{DateTime, Utc};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::PathBuf;

/// `ActionsHistory.currentVersion` in the Swift app.
pub const CURRENT_VERSION: i64 = 1;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct History {
    pub version: i64,
    pub org_login: String,
    pub synced_at: DateTime<Utc>,
    pub repositories: HashMap<String, Repository>,
    /// Keyed by run ID; Swift writes `[Int: WorkflowRun]` with string keys.
    pub runs: HashMap<String, WorkflowRun>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Repository {
    pub covered_from: DateTime<Utc>,
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowRun {
    pub repo: String,
    pub attempt: i64,
    pub status: String,
    pub conclusion: Option<String>,
    pub created_at: DateTime<Utc>,
    pub started_at: Option<DateTime<Utc>>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Success,
    Failure,
    Cancelled,
    Skipped,
    Running,
}

impl WorkflowRun {
    pub fn is_completed(&self) -> bool {
        self.status == "completed"
    }

    pub fn outcome(&self) -> Outcome {
        if !self.is_completed() {
            return Outcome::Running;
        }
        match self.conclusion.as_deref() {
            Some("success") => Outcome::Success,
            Some("failure" | "timed_out" | "startup_failure") => Outcome::Failure,
            Some("cancelled") => Outcome::Cancelled,
            _ => Outcome::Skipped,
        }
    }

    /// Wall-clock seconds of the latest attempt, for completed runs that ran.
    pub fn duration(&self) -> Option<f64> {
        if !self.is_completed() || self.outcome() == Outcome::Skipped {
            return None;
        }
        let started = self.started_at?;
        let seconds = (self.updated_at - started).num_milliseconds() as f64 / 1000.0;
        (seconds >= 0.0).then_some(seconds)
    }

    pub fn passed_on_retry(&self) -> bool {
        self.outcome() == Outcome::Success && self.attempt > 1
    }

    pub fn short_name(&self) -> &str {
        self.repo.rsplit('/').next().unwrap_or(&self.repo)
    }
}

/// The shared Application Support folder the Swift app writes to (it isn't
/// sandboxed, so this is not a container).
pub fn cache_dir() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join("Library/Application Support/Actions")
}

pub fn cache_path(org: &str) -> PathBuf {
    let encoded: String = org.replace('%', "%25").replace(' ', "%20");
    cache_dir().join(format!("{encoded}.json"))
}

/// Orgs with a saved file, by name.
pub fn orgs() -> Vec<String> {
    let mut orgs: Vec<String> = std::fs::read_dir(cache_dir())
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if path.extension()? != "json" {
                return None;
            }
            Some(percent_decode(&path.file_stem()?.to_string_lossy()))
        })
        .collect();
    orgs.sort_by_key(|org| org.to_lowercase());
    orgs
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(byte) = u8::from_str_radix(&text[i + 1..i + 3], 16) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}
