//! The org's Actions history, in the Swift app's `ActionsHistory` shape
//! (dates as ISO 8601), kept by the pilot's own sync (`actions.rs`). Only
//! the fields the page uses are decoded; jobs are skipped.

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

pub fn cache_path(org: &str) -> PathBuf {
    crate::cache::path(crate::cache::Kind::Actions, org)
}

/// The orgs the pilot knows: those of folders opened here, those with
/// settings of their own, and those with caches from before they moved into
/// their harness. By name, once each.
pub fn orgs() -> Vec<String> {
    let mut orgs: Vec<String> = Vec::new();
    let found = crate::folders::recent().into_iter().filter_map(|r| r.org);
    for org in found.chain(crate::projects::orgs_with_settings()).chain(crate::cache::fallback_orgs()) {
        if !org.is_empty() && !orgs.iter().any(|o| o.eq_ignore_ascii_case(&org)) {
            orgs.push(org);
        }
    }
    orgs.sort_by_key(|org| org.to_lowercase());
    orgs
}

pub fn percent_decode(text: &str) -> String {
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
