//! The folder a window opens, as Zed opens a project: on this Mac, or on a
//! server (the title bar's Remotes) as Zed opens a remote project.
//!
//! A folder is a harness, or an org's folder holding one or more harnesses
//! (and the code repos beside them). Each harness is a project; a harness
//! belongs to one org, read from its git remote, and an org may have several.
//! A folder with no harness is offered the starter harness Gannin's Set Up
//! Harness makes (`HarnessSkeleton`), as a local git repo: nothing is written
//! to GitHub.
//!
//! Folders opened are kept, most recent first, in `folders.json` in the
//! pilot's own folder, for Open Recent.

use crate::servers::Server;
use base64::Engine;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Where a folder is: its path, and the server it's on (None is this Mac).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Location {
    pub path: PathBuf,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server: Option<Server>,
}

impl Location {
    pub fn here(path: PathBuf) -> Self {
        Self { path, server: None }
    }

    /// Tells folders apart: the server's key before the path.
    pub fn key(&self) -> String {
        match &self.server {
            Some(server) => format!("{}:{}", server.key(), self.path.display()),
            None => self.path.display().to_string(),
        }
    }

    /// The folder's own name, as Zed's title bar shows a project.
    pub fn name(&self) -> String {
        self.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| self.path.display().to_string())
    }

    /// Where it is, home as `~`, after the server's name when it's on one.
    pub fn place(&self) -> String {
        let path = self.path.display().to_string();
        match &self.server {
            Some(server) => format!("{}: {path}", server.name()),
            None => {
                let home = std::env::var("HOME").unwrap_or_default();
                if !home.is_empty() && path.starts_with(&home) {
                    format!("~{}", &path[home.len()..])
                } else {
                    path
                }
            }
        }
    }
}

/// A git checkout found in a folder.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Found {
    pub path: PathBuf,
    /// `owner/name`, from its origin on GitHub.
    #[serde(default)]
    pub repo: Option<String>,
    /// Its `.gannin/project.json`: the project's name and code repos.
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub repos: Vec<String>,
}

impl Found {
    pub fn owner(&self) -> Option<&str> {
        self.repo.as_deref().and_then(|r| r.split_once('/')).map(|(owner, _)| owner)
    }

    /// The harness's repo, as projects are keyed: its origin, else the org
    /// and its folder's name (a harness set up here, not on GitHub yet).
    pub fn repo_id(&self, org: &str) -> String {
        self.repo.clone().unwrap_or_else(|| format!("{org}/{}", self.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()))
    }
}

/// What's in a folder.
#[derive(Clone, Debug, PartialEq)]
pub struct Opened {
    /// With its path made absolute (`~` read on the server it's on).
    pub location: Location,
    /// The folder itself, if it's one, then those in it.
    pub harnesses: Vec<Found>,
    /// Other git checkouts: the code repos.
    pub repos: Vec<Found>,
    /// Nothing in it at all.
    pub empty: bool,
}

impl Opened {
    /// Whose it is: the owner most of its harnesses have, else most of its
    /// repos, else an org with the folder's name.
    pub fn org(&self, orgs: &[String]) -> Option<String> {
        let most = |found: &[Found]| {
            let mut counts: Vec<(String, usize)> = Vec::new();
            for owner in found.iter().filter_map(Found::owner) {
                match counts.iter_mut().find(|(o, _)| o.eq_ignore_ascii_case(owner)) {
                    Some((_, n)) => *n += 1,
                    None => counts.push((owner.to_string(), 1)),
                }
            }
            counts.into_iter().max_by_key(|(_, n)| *n).map(|(o, _)| o)
        };
        let named = || orgs.iter().find(|o| o.eq_ignore_ascii_case(&self.location.name())).cloned();
        let owner = most(&self.harnesses).or_else(|| most(&self.repos)).or_else(named)?;
        // Spelled as the org's cache is, when there's one.
        Some(orgs.iter().find(|o| o.eq_ignore_ascii_case(&owner)).cloned().unwrap_or(owner))
    }

    /// The harnesses that are the org's: its remote's owner, or none yet.
    pub fn harnesses_of(&self, org: &str) -> Vec<&Found> {
        self.harnesses.iter().filter(|h| h.owner().is_none_or(|o| o.eq_ignore_ascii_case(org))).collect()
    }
}

/// Lists a folder: the folder, then each folder in it, as a git checkout
/// that's a harness (`.gannin/`, or `projects/` beside `plans/`) or a repo, with its origin
/// and project file. The same script runs here and on a server.
const INSPECT: &str = r#"
case "$1" in "~") set -- "$HOME" ;; "~/"*) set -- "$HOME/${1#\~/}" ;; esac
cd "$1" 2>/dev/null || { echo missing; exit 0; }
printf 'at\t%s\n' "$(pwd)"
[ -z "$(ls -A 2>/dev/null)" ] && echo empty
for d in . */; do
  d=${d%/}
  [ -e "$d/.git" ] || continue
  o=$(git -C "$d" remote get-url origin 2>/dev/null)
  if [ -d "$d/.gannin" ] || { [ -d "$d/projects" ] && [ -d "$d/plans" ]; }; then k=harness; else k=repo; fi
  p=
  [ -f "$d/.gannin/project.json" ] && p=$(base64 < "$d/.gannin/project.json" | tr -d '\n')
  printf '%s\t%s\t%s\t%s\n' "$k" "$(cd "$d" && pwd)" "$o" "$p"
done
exit 0
"#;

/// `owner/name` from a GitHub remote URL (https or ssh).
fn repo_of(url: &str) -> Option<String> {
    let url = url.trim().trim_end_matches('/').trim_end_matches(".git");
    let rest = url.split_once("github.com").map(|(_, rest)| rest)?;
    let rest = rest.trim_start_matches([':', '/']);
    let mut parts = rest.split('/');
    let (owner, name) = (parts.next()?, parts.next()?);
    (!owner.is_empty() && !name.is_empty()).then(|| format!("{owner}/{name}"))
}

/// Reads what's in a folder, here or over ssh. Blocks: call it off the
/// main thread.
pub fn inspect(location: &Location) -> Result<Opened, String> {
    let path = location.path.display().to_string();
    let output = match &location.server {
        Some(server) => crate::servers::script(server, &format!("set -- {}\n{INSPECT}", crate::launch::quote(&path)))?,
        None => {
            let out = Command::new("/bin/bash").arg("-c").arg(INSPECT).arg("gannin").arg(&path).output().map_err(|e| e.to_string())?;
            String::from_utf8_lossy(&out.stdout).into_owned()
        }
    };
    if output.lines().any(|l| l == "missing") {
        return Err(format!("There's no folder at {}.", location.place()));
    }
    let mut opened = Opened { location: location.clone(), harnesses: Vec::new(), repos: Vec::new(), empty: false };
    for line in output.lines() {
        let fields: Vec<&str> = line.split('\t').collect();
        match fields.as_slice() {
            ["at", at] => opened.location.path = PathBuf::from(at),
            ["empty"] => opened.empty = true,
            [kind @ ("harness" | "repo"), path, origin, project] => {
                let file: serde_json::Value = base64::engine::general_purpose::STANDARD
                    .decode(project)
                    .ok()
                    .and_then(|b| serde_json::from_slice(&b).ok())
                    .unwrap_or_default();
                let found = Found {
                    path: PathBuf::from(path),
                    repo: repo_of(origin),
                    name: file["name"].as_str().map(str::to_string).filter(|n| !n.trim().is_empty()),
                    repos: file["repos"].as_array().map(|a| a.iter().filter_map(|r| r.as_str().map(str::to_string)).collect()).unwrap_or_default(),
                };
                if *kind == "harness" {
                    opened.harnesses.push(found);
                } else {
                    opened.repos.push(found);
                }
            }
            _ => {}
        }
    }
    Ok(opened)
}

// MARK: - Open Recent

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Recent {
    pub location: Location,
    #[serde(default)]
    pub org: Option<String>,
    /// Its harnesses when it was last opened, so a session's harness is
    /// found here without asking the folder again.
    #[serde(default)]
    pub harnesses: Vec<Found>,
    pub opened_at: chrono::DateTime<chrono::Utc>,
}

fn recents_path() -> PathBuf {
    crate::paths::app_dir().join("folders.json")
}

/// The folders opened, most recent first.
pub fn recent() -> Vec<Recent> {
    std::fs::read(recents_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

/// Puts a folder at the top of Open Recent.
pub fn remember(opened: &Opened, org: Option<&str>) {
    let mut list = recent();
    let key = opened.location.key();
    list.retain(|r| r.location.key() != key);
    list.insert(0, Recent { location: opened.location.clone(), org: org.map(str::to_string), harnesses: opened.harnesses.clone(), opened_at: chrono::Utc::now() });
    list.truncate(20);
    if let Some(dir) = recents_path().parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(recents_path(), serde_json::to_vec_pretty(&list).unwrap_or_default());
}

/// Takes a folder off Open Recent (the folder itself is left alone).
pub fn forget(key: &str) {
    let mut list = recent();
    list.retain(|r| r.location.key() != key);
    let _ = std::fs::write(recents_path(), serde_json::to_vec_pretty(&list).unwrap_or_default());
}

/// Where a harness is on this Mac, from the folders opened here.
pub fn known_path(repo: &str) -> Option<PathBuf> {
    recent()
        .into_iter()
        .filter(|r| r.location.server.is_none())
        .flat_map(|r| r.harnesses)
        .find(|h| h.repo.as_deref().is_some_and(|r| r.eq_ignore_ascii_case(repo)) && h.path.is_dir())
        .map(|h| h.path)
}

// MARK: - Set Up Harness

const SKELETON: &str = include_str!("harness_skeleton.json");

/// Where a new harness goes: the folder itself when it's empty, else a
/// `harness` folder in it.
pub fn new_harness_path(opened: &Opened) -> PathBuf {
    if opened.empty {
        opened.location.path.clone()
    } else {
        opened.location.path.join("harness")
    }
}

/// Writes the starter harness Gannin's Set Up Harness makes, with
/// `.gannin/project.json`, and commits it to a new local git repo whose
/// origin is `org/<folder name>` on GitHub (not created: that's for the
/// person, when they're ready). Never writes over a folder that has
/// anything in it. Blocks: call it off the main thread.
pub fn set_up_harness(opened: &Opened, org: &str) -> Result<PathBuf, String> {
    if opened.harnesses.iter().any(|h| h.path == opened.location.path) {
        return Err(format!("{} is a harness already.", opened.location.place()));
    }
    let target = new_harness_path(opened);
    let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "harness".into());
    let repo = format!("{org}/{name}");
    let files: std::collections::BTreeMap<String, String> = serde_json::from_str(SKELETON).map_err(|e| e.to_string())?;
    // Built in a folder of its own here, then moved into place (copied up,
    // on a server), so a half-made harness is never left in the folder.
    let staging = std::env::temp_dir().join(format!("gannin-harness-{}", uuid::Uuid::new_v4()));
    let write = || -> std::io::Result<()> {
        for (path, text) in &files {
            let file = staging.join(path);
            if let Some(dir) = file.parent() {
                std::fs::create_dir_all(dir)?;
            }
            std::fs::write(file, text.replace("{{ORG}}", org).replace("{{REPO}}", &repo))?;
        }
        let project = serde_json::json!({ "name": name, "repos": [] });
        std::fs::write(staging.join(".gannin/project.json"), serde_json::to_vec_pretty(&project).unwrap_or_default())?;
        Ok(())
    };
    write().map_err(|e| format!("Couldn't write the starter files: {e}"))?;
    let init = format!(
        "git init -q -b main && git add -A && git commit -q -m 'Set up the harness' && git remote add origin {}",
        crate::launch::quote(&format!("https://github.com/{repo}.git"))
    );
    let result = match &opened.location.server {
        None => (|| {
            if target.exists() && std::fs::read_dir(&target).map(|mut d| d.next().is_some()).unwrap_or(true) {
                return Err(format!("{} already has something in it.", target.display()));
            }
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            if target.exists() {
                std::fs::remove_dir(&target).map_err(|e| e.to_string())?;
            }
            std::fs::rename(&staging, &target).or_else(|_| copy_dir(&staging, &target)).map_err(|e| format!("Couldn't put it in place: {e}"))?;
            let out = Command::new("/bin/sh").arg("-c").arg(&init).current_dir(&target).output().map_err(|e| e.to_string())?;
            if out.status.success() {
                Ok(target.clone())
            } else {
                Err(format!("The files are there, but git didn't commit them: {}", String::from_utf8_lossy(&out.stderr).trim()))
            }
        })(),
        Some(server) => (|| {
            let tar = Command::new("tar").env("COPYFILE_DISABLE", "1").arg("-C").arg(&staging).args(["-cf", "-", "."]).output().map_err(|e| e.to_string())?;
            let dir = crate::launch::quote_path(&target);
            let unpack = format!("if [ -e {dir} ] && [ -n \"$(ls -A {dir} 2>/dev/null)\" ]; then echo 'It already has something in it.' >&2; exit 1; fi; mkdir -p {dir} && tar -C {dir} -xf - && cd {dir} && {init}");
            crate::servers::command(server, &unpack, Some(&tar.stdout)).map(|_| target.clone())
        })(),
    };
    let _ = std::fs::remove_dir_all(&staging);
    result
}

fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_github_remotes() {
        assert_eq!(repo_of("https://github.com/acme/harness.git").as_deref(), Some("acme/harness"));
        assert_eq!(repo_of("git@github.com:acme/harness.git").as_deref(), Some("acme/harness"));
        assert_eq!(repo_of("ssh://git@github.com/acme/api").as_deref(), Some("acme/api"));
        assert_eq!(repo_of("https://gitlab.com/acme/api"), None);
    }
}
