//! An org's projects and issue workflow, read from Gannin's own data:
//!
//! - Which harnesses the org uses, in order, and its issue workflow, from
//!   the org's settings in Gannin's SwiftData store
//!   (`UserData/Gannin.store`, SQLite underneath, read only).
//! - Each harness's `.gannin/project.json` (name, repos, boards repo), from
//!   the harness index Gannin caches (`Harness/<org>@<owner>~<name>.json`).
//!
//! A project per harness, as `OrgConfigStore.projects` makes them; an org
//! whose harnesses have no project file falls back to the old list of
//! projects kept in its settings.

use crate::detail::Workflow;
use serde::Deserialize;
use std::path::PathBuf;

#[derive(Clone, PartialEq)]
pub struct Project {
    /// Its harness's repo, as `RepoProject.id`.
    pub id: String,
    pub name: String,
    /// `owner/name`; empty for every repo.
    pub repos: Vec<String>,
}

pub struct OrgSettings {
    pub projects: Vec<Project>,
    pub workflow: Workflow,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Config {
    harness: Option<HarnessRef>,
    other_harnesses: Vec<HarnessRef>,
    repo_projects: Vec<LegacyProject>,
    issue_workflow: Option<Workflow>,
}

#[derive(Deserialize)]
struct HarnessRef {
    repo: String,
}

#[derive(Deserialize)]
struct LegacyProject {
    name: String,
    #[serde(default)]
    repos: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HarnessIndex {
    repo: String,
    #[serde(default)]
    data_files: Vec<DataFile>,
}

#[derive(Deserialize)]
struct DataFile {
    path: String,
    text: String,
}

#[derive(Deserialize)]
struct ProjectFile {
    name: String,
    #[serde(default)]
    repos: Vec<String>,
}

fn support() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join("Library/Application Support")
}

/// The org's settings as Gannin saved them, as JSON, for what this file
/// doesn't type (scorecard goals, exclusions). Null when there are none.
pub fn config_json(org: &str) -> serde_json::Value {
    use rusqlite::{Connection, OpenFlags};
    let path = support().join("UserData/Gannin.store");
    let Ok(db) = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX) else {
        return serde_json::Value::Null;
    };
    db.query_row("SELECT ZCONFIG FROM ZORGCONFIGRECORD WHERE ZORG = ?1", [org], |row| row.get::<_, Vec<u8>>(0))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or(serde_json::Value::Null)
}

/// The org's settings with what its harness keeps winning, as Gannin reads
/// them: the harness's `.gannin/scorecard.json` for the goals, and its
/// `.gannin/exclusions.json` for the people and repos left out.
pub fn effective_config(org: &str) -> serde_json::Value {
    let mut config = config_json(org);
    if !config.is_object() {
        config = serde_json::json!({});
    }
    // The org's home harness: its first project's, as the pages order them.
    let Some(harness) = load(org).projects.first().map(|p| p.id.clone()) else { return config };
    let index_path = support().join("Harness").join(format!("{org}@{}.json", harness.replace('/', "~")));
    let Some(index) = std::fs::read(index_path).ok().and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok()) else { return config };
    let file = |path: &str| {
        index["dataFiles"]
            .as_array()
            .and_then(|files| files.iter().find(|f| f["path"] == path))
            .and_then(|f| f["text"].as_str())
            .and_then(|text| serde_json::from_str::<serde_json::Value>(text).ok())
    };
    if let Some(scorecard) = file(".gannin/scorecard.json").filter(|v| v.is_array()) {
        config["scorecard"] = scorecard;
    }
    if let Some(exclusions) = file(".gannin/exclusions.json") {
        for (from, to) in [("people", "excludedAuthors"), ("includedPeople", "includedAuthors"), ("repos", "excludedRepos"), ("reposWithoutReview", "reposWithoutReview")] {
            if let Some(value) = exclusions.get(from).filter(|v| v.is_array()) {
                config[to] = value.clone();
            }
        }
    }
    config
}

/// The org's settings as Gannin saved them: a JSON blob per org.
fn config(org: &str) -> Config {
    use rusqlite::{Connection, OpenFlags};
    let path = support().join("UserData/Gannin.store");
    let Ok(db) = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX) else {
        return Config::default();
    };
    db.query_row("SELECT ZCONFIG FROM ZORGCONFIGRECORD WHERE ZORG = ?1", [org], |row| row.get::<_, Vec<u8>>(0))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

/// The org's projects and workflow. Reads large files, so runs off the main
/// thread.
pub fn load(org: &str) -> OrgSettings {
    let config = config(org);
    let order: Vec<String> = config.harness.iter().chain(&config.other_harnesses).map(|h| h.repo.clone()).collect();

    let prefix = format!("{org}@");
    let mut projects: Vec<Project> = std::fs::read_dir(support().join("Harness"))
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().starts_with(&prefix))
        .filter_map(|entry| {
            let index: HarnessIndex = serde_json::from_slice(&std::fs::read(entry.path()).ok()?).ok()?;
            let file = index.data_files.iter().find(|f| f.path == ".gannin/project.json")?;
            let project: ProjectFile = serde_json::from_str(&file.text).ok()?;
            Some(Project { id: index.repo, name: project.name, repos: project.repos })
        })
        .collect();
    // Home first, then the settings' order, then any others by name.
    projects.sort_by_key(|p| (order.iter().position(|r| *r == p.id).unwrap_or(usize::MAX), p.name.to_lowercase()));
    if projects.is_empty() {
        projects = config
            .repo_projects
            .into_iter()
            .map(|p| Project { id: p.name.clone(), name: p.name, repos: p.repos })
            .collect();
    }
    OrgSettings { projects, workflow: config.issue_workflow.unwrap_or_default() }
}
