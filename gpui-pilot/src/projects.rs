//! An org's projects and issue workflow, from the pilot's own data:
//!
//! - The org's settings in `~/.gannin/orgs/<org>.json`, the pilot's own,
//!   in the shape of Gannin's `OrgConfig` (`harness`, `otherHarnesses`,
//!   `repoProjects`, `issueWorkflow`, `scorecard`, `excludedRepos` and so on).
//!   Nothing is copied from the Swift app: an org starts with none.
//! - Which harnesses the org has: those its settings name, then each found
//!   in a folder opened here, added to its settings the first time so the
//!   home harness stays the same whatever's opened later.
//! - Each harness's `.gannin/` team files (`project.json`, `workflow.json`,
//!   `scorecard.json`, `exclusions.json` and the rest), read with git from
//!   its default branch (`harness_git`), winning over the settings as
//!   Gannin's `HarnessTeamData` does.
//!
//! A project per harness, as `OrgConfigStore.projects` makes them; an org
//! whose harnesses have no project file falls back to its list of
//! repo projects (the home harness's `repo-projects.json`, else its settings').

use crate::detail::Workflow;
use serde::Deserialize;
use serde_json::{json, Value};
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

#[derive(Deserialize)]
struct LegacyProject {
    name: String,
    #[serde(default)]
    repos: Vec<String>,
}

#[derive(Deserialize)]
struct ProjectFile {
    name: String,
    #[serde(default)]
    repos: Vec<String>,
}

fn settings_path(org: &str) -> PathBuf {
    let safe: String = org.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' { c } else { '_' }).collect();
    crate::paths::app_dir().join("orgs").join(format!("{safe}.json"))
}

/// The orgs with settings of their own here.
pub fn orgs_with_settings() -> Vec<String> {
    std::fs::read_dir(crate::paths::app_dir().join("orgs"))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.path().file_stem().map(|s| s.to_string_lossy().into_owned()))
        .collect()
}

/// The org's settings, as JSON. Null when there are none.
pub fn config_json(org: &str) -> Value {
    std::fs::read(settings_path(org)).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or(Value::Null)
}

fn save_config(org: &str, config: &Value) {
    let path = settings_path(org);
    if let Some(folder) = path.parent() {
        let _ = std::fs::create_dir_all(folder);
    }
    let Ok(bytes) = serde_json::to_vec_pretty(config) else { return };
    let partial = path.with_extension("json.part");
    if std::fs::write(&partial, bytes).is_ok() {
        let _ = std::fs::rename(&partial, &path);
    }
}

/// The org's harnesses, home first: those its settings name, in order, then
/// any found in folders opened here, which are added to its settings (the
/// first becoming home) so the order holds. Cheap: no git, no network.
pub fn harness_repos(org: &str) -> Vec<String> {
    let mut config = config_json(org);
    if !config.is_object() {
        config = json!({});
    }
    let named = |v: &Value| v["repo"].as_str().map(str::to_string);
    let mut repos: Vec<String> = named(&config["harness"]).into_iter().chain(config["otherHarnesses"].as_array().into_iter().flatten().filter_map(named)).collect();
    let mut added = false;
    // One removed in Settings stays removed, though a folder still has it.
    let removed: Vec<String> = config["removedHarnesses"].as_array().into_iter().flatten().filter_map(|r| r.as_str().map(str::to_lowercase)).collect();
    for recent in crate::folders::recent() {
        for found in recent.harnesses {
            let Some(repo) = found.repo else { continue };
            let owner = repo.split('/').next().unwrap_or("");
            if !owner.eq_ignore_ascii_case(org) || repos.iter().any(|r| r.eq_ignore_ascii_case(&repo)) || removed.contains(&repo.to_lowercase()) {
                continue;
            }
            if config["harness"]["repo"].is_string() {
                if !config["otherHarnesses"].is_array() {
                    config["otherHarnesses"] = json!([]);
                }
                if let Some(others) = config["otherHarnesses"].as_array_mut() {
                    others.push(json!({ "repo": repo }));
                }
            } else {
                config["harness"] = json!({ "repo": repo });
            }
            repos.push(repo);
            added = true;
        }
    }
    if added {
        save_config(org, &config);
    }
    repos
}

/// Rewrites which harnesses are the org's projects, home first: `change`
/// gets each harness's entry (`{"repo": ..}` and anything else it holds).
fn update_harnesses(org: &str, change: impl FnOnce(&mut Vec<Value>)) {
    let mut config = config_json(org);
    if !config.is_object() {
        config = json!({});
    }
    let mut entries: Vec<Value> = std::iter::once(config["harness"].clone()).filter(|h| h["repo"].is_string()).chain(config["otherHarnesses"].as_array().cloned().unwrap_or_default()).collect();
    change(&mut entries);
    let mut entries = entries.into_iter();
    match entries.next() {
        Some(home) => config["harness"] = home,
        None => {
            if let Some(map) = config.as_object_mut() {
                map.remove("harness");
            }
        }
    }
    config["otherHarnesses"] = Value::Array(entries.collect());
    save_config(org, &config);
}

fn is(entry: &Value, repo: &str) -> bool {
    entry["repo"].as_str().is_some_and(|r| r.eq_ignore_ascii_case(repo))
}

/// Makes `repo` one of the org's projects, home when it has none. Local:
/// which harnesses are projects is each person's own.
pub fn add_harness(org: &str, repo: &str) {
    let mut config = config_json(org);
    if let Some(removed) = config["removedHarnesses"].as_array_mut() {
        removed.retain(|r| !r.as_str().is_some_and(|r| r.eq_ignore_ascii_case(repo)));
        save_config(org, &config);
    }
    update_harnesses(org, |entries| {
        if !entries.iter().any(|e| is(e, repo)) {
            entries.push(json!({ "repo": repo }));
        }
    });
}

/// Stops reading `repo` as a project; the harness itself is untouched. The
/// next becomes home when it was.
pub fn remove_harness(org: &str, repo: &str) {
    update_harnesses(org, |entries| entries.retain(|e| !is(e, repo)));
    let mut config = config_json(org);
    if !config["removedHarnesses"].is_array() {
        config["removedHarnesses"] = json!([]);
    }
    if let Some(removed) = config["removedHarnesses"].as_array_mut() {
        if !removed.iter().any(|r| r.as_str().is_some_and(|r| r.eq_ignore_ascii_case(repo))) {
            removed.push(json!(repo));
        }
    }
    save_config(org, &config);
}

/// Makes `repo` home: the org-wide data (exclusions, the working week and
/// the rest) is read from its harness from then on. Nothing is copied.
pub fn make_home(org: &str, repo: &str) {
    update_harnesses(org, |entries| {
        if let Some(i) = entries.iter().position(|e| is(e, repo)) {
            let home = entries.remove(i);
            entries.insert(0, home);
        }
    });
}

/// JSON as Gannin's team files are written (`TeamCoding`): keys sorted,
/// two-space indents and `"key" : value`, so a file the Swift app wrote
/// changes only where it's edited.
pub fn team_json(value: &Value) -> String {
    fn write(value: &Value, indent: usize, out: &mut String) {
        let pad = "  ".repeat(indent + 1);
        let close = "  ".repeat(indent);
        match value {
            Value::Object(map) => {
                if map.is_empty() {
                    out.push_str("{\n\n");
                    out.push_str(&close);
                    out.push('}');
                    return;
                }
                let mut keys: Vec<&String> = map.keys().collect();
                keys.sort();
                out.push_str("{\n");
                for (i, key) in keys.iter().enumerate() {
                    out.push_str(&pad);
                    out.push_str(&Value::String((*key).clone()).to_string());
                    out.push_str(" : ");
                    write(&map[*key], indent + 1, out);
                    if i + 1 < keys.len() {
                        out.push(',');
                    }
                    out.push('\n');
                }
                out.push_str(&close);
                out.push('}');
            }
            Value::Array(items) => {
                if items.is_empty() {
                    out.push_str("[\n\n");
                    out.push_str(&close);
                    out.push(']');
                    return;
                }
                out.push_str("[\n");
                for (i, item) in items.iter().enumerate() {
                    out.push_str(&pad);
                    write(item, indent + 1, out);
                    if i + 1 < items.len() {
                        out.push(',');
                    }
                    out.push('\n');
                }
                out.push_str(&close);
                out.push(']');
            }
            other => out.push_str(&other.to_string()),
        }
    }
    let mut out = String::new();
    write(value, 0, &mut out);
    out.push('\n');
    out
}

/// A project's `.gannin/project.json` with its name and repos set,
/// keeping whatever else the file holds (its boards repo and anything
/// newer).
pub fn project_file(existing: Option<&str>, name: &str, repos: &[String]) -> String {
    let mut file: Value = existing.and_then(|t| serde_json::from_str(t).ok()).filter(Value::is_object).unwrap_or_else(|| json!({}));
    file["name"] = json!(name);
    file["repos"] = json!(repos);
    team_json(&file)
}

/// The org's settings with what its harnesses keep winning, as Gannin's
/// `HarnessTeamData` applies them: org-wide files from the home harness
/// (exclusions, the working week, leave, accounting, authoring, issue
/// strategy) and a project's own from it too (workflow, goals, scorecard,
/// investments, R&D, recap). Runs git: call off the main thread.
pub fn effective_config(org: &str) -> Value {
    let mut config = config_json(org);
    if !config.is_object() {
        config = json!({});
    }
    let Some(home) = crate::harness_git::snapshots(org).into_iter().next() else { return config };
    let file = |name: &str| home.json(&format!(".gannin/{name}"));
    if let Some(scorecard) = file("scorecard.json").filter(|v| v.is_array()) {
        config["scorecard"] = scorecard;
    }
    if let Some(exclusions) = file("exclusions.json") {
        for (from, to) in [("people", "excludedAuthors"), ("includedPeople", "includedAuthors"), ("repos", "excludedRepos"), ("reposWithoutReview", "reposWithoutReview"), ("reposNeedingMac", "reposNeedingMac")] {
            if let Some(value) = exclusions.get(from).filter(|v| v.is_array()) {
                config[to] = value.clone();
            }
        }
    }
    for (name, key) in [
        ("workflow.json", "issueWorkflow"),
        ("goals.json", "goals"),
        ("investments.json", "investments"),
        ("rnd.json", "rnd"),
        ("recap.json", "recap"),
        ("working-week.json", "workWeek"),
        ("leave.json", "leave"),
        ("accounting.json", "accounting"),
        ("authoring.json", "authoring"),
        ("issue-strategy.json", "issueStrategy"),
    ] {
        if let Some(value) = file(name) {
            config[key] = value;
        }
    }
    config
}

/// The org's projects and workflow. Fetches and reads its harnesses with
/// git, so runs off the main thread.
pub fn load(org: &str) -> OrgSettings {
    let snapshots = crate::harness_git::snapshots(org);
    let recent = crate::folders::recent();
    let mut projects: Vec<Project> = crate::projects::harness_repos(org)
        .into_iter()
        .filter_map(|repo| {
            let snapshot = snapshots.iter().find(|s| s.repo.eq_ignore_ascii_case(&repo));
            // The harness's project file on GitHub, else as its folder had
            // it when last opened (a harness not on GitHub yet).
            let file = snapshot.and_then(|s| s.file(".gannin/project.json")).and_then(|t| serde_json::from_str::<ProjectFile>(t).ok()).or_else(|| {
                recent
                    .iter()
                    .flat_map(|r| &r.harnesses)
                    .find(|h| h.repo.as_deref().is_some_and(|r| r.eq_ignore_ascii_case(&repo)))
                    .and_then(|h| h.name.clone().map(|name| ProjectFile { name, repos: h.repos.clone() }))
            })?;
            Some(Project { id: repo, name: file.name, repos: file.repos })
        })
        .collect();
    let config = effective_config(org);
    if projects.is_empty() {
        let legacy = snapshots.first().and_then(|s| s.json(".gannin/repo-projects.json")).or_else(|| Some(config["repoProjects"].clone()));
        projects = legacy
            .and_then(|v| serde_json::from_value::<Vec<LegacyProject>>(v).ok())
            .unwrap_or_default()
            .into_iter()
            .map(|p| Project { id: p.name.clone(), name: p.name, repos: p.repos })
            .collect();
    }
    let workflow = serde_json::from_value(config["issueWorkflow"].clone()).unwrap_or_default();
    OrgSettings { projects, workflow }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_file_keeps_other_keys_and_writes_as_gannin_does() {
        let existing = "{\n  \"boardsRepo\" : \"andrew-waters/gannin\",\n  \"name\" : \"gannin\",\n  \"repos\" : [\n    \"andrew-waters/gannin\"\n  ]\n}\n";
        assert_eq!(project_file(Some(existing), "gannin", &["andrew-waters/gannin".to_string()]), existing);
        let changed = project_file(Some(existing), "Gannin", &[]);
        assert_eq!(changed, "{\n  \"boardsRepo\" : \"andrew-waters/gannin\",\n  \"name\" : \"Gannin\",\n  \"repos\" : [\n\n  ]\n}\n");
        assert_eq!(project_file(None, "x", &["o/a".into(), "o/b".into()]), "{\n  \"name\" : \"x\",\n  \"repos\" : [\n    \"o/a\",\n    \"o/b\"\n  ]\n}\n");
    }
}
