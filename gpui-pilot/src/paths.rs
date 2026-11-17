//! Where the app keeps what's its own. Nothing goes in Application Support:
//!
//! - An org's synced GitHub data, and each session's folder, in the org's
//!   harness checkout, in `.gannin-cache/`, which ignores itself in git
//!   (`cache.rs`, `Launch::dir`).
//! - What isn't one org's (window state, the signed-in viewer, the review
//!   schedule, personal workflows, Open Recent, the session index) in
//!   `~/.gannin/`.
//!
//! Gannin's own Application Support files are still read, never written, to
//! start the app's copies from.

use std::path::{Path, PathBuf};

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

/// `~/.gannin`: what isn't one org's.
pub fn app_dir() -> PathBuf {
    home().join(".gannin")
}

/// Where everything was kept before it moved out of Application Support.
fn earlier_dir() -> PathBuf {
    home().join("Library/Application Support/GanninGPUIPilot")
}

/// Makes `<folder>/.gannin-cache`, ignoring itself so nothing in it is ever
/// committed and the harness's own .gitignore needn't change. None when
/// `folder` isn't a git checkout: a harness the start script will clone
/// needs an empty folder.
pub fn harness_cache(folder: &Path) -> Option<PathBuf> {
    if !folder.join(".git").exists() {
        return None;
    }
    let root = folder.join(".gannin-cache");
    std::fs::create_dir_all(&root).ok()?;
    let ignore = root.join(".gitignore");
    if !ignore.exists() {
        std::fs::write(&ignore, "# Gannin's synced GitHub data and session folders, kept on this Mac only.\n*\n").ok()?;
    }
    Some(root)
}

/// Moves what the app kept in Application Support to where it lives now,
/// once, as the window opens (never from a headless check, which could run
/// beside an app still using the old folders). Sessions go into their
/// harness, with the paths their scripts and hooks were written with
/// changed to match; the rest into `~/.gannin`.
pub fn migrate() {
    let earlier = earlier_dir();
    if !earlier.exists() {
        return;
    }
    let app = app_dir();
    let _ = std::fs::create_dir_all(app.join("sessions"));
    let sessions = earlier.join("Sessions");
    for entry in std::fs::read_dir(&sessions).into_iter().flatten().flatten() {
        move_session(&entry.path(), &earlier, &app);
    }
    if std::fs::read_dir(&sessions).map(|mut d| d.next().is_none()).unwrap_or(true) {
        let _ = std::fs::remove_dir(&sessions);
    }
    for entry in std::fs::read_dir(&earlier).into_iter().flatten().flatten() {
        let name = entry.file_name();
        if name == "Sessions" {
            continue;
        }
        let to = app.join(if name == "Caches" { "caches".into() } else { name });
        if !to.exists() {
            let _ = std::fs::rename(entry.path(), &to);
        }
    }
    // Only when everything went; anything left stays where it was.
    let _ = std::fs::remove_dir(&earlier);
}

fn move_session(from: &Path, earlier: &Path, app: &Path) {
    let Some(id) = from.file_name().map(|n| n.to_os_string()) else { return };
    let entry = app.join("sessions").join(&id);
    if entry.exists() || entry.is_symlink() {
        return;
    }
    let launch: Option<crate::launch::Launch> = std::fs::read(from.join("session.json")).ok().and_then(|b| serde_json::from_slice(&b).ok());
    let to = launch.as_ref().and_then(|l| harness_cache(&l.harness_path)).map(|root| root.join("sessions").join(&id)).unwrap_or_else(|| entry.clone());
    if let Some(parent) = to.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if std::fs::rename(from, &to).is_err() {
        return;
    }
    rewrite_paths(&to, from, &to, earlier, app);
    if to != entry {
        let _ = std::os::unix::fs::symlink(&to, &entry);
    }
}

/// Changes the session's own folder, then the app's folder, in every text
/// file in the session, in the two forms the scripts are written with: as
/// `"$HOME"/'<path under home>'` (`quote_path`) and in full.
fn rewrite_paths(folder: &Path, old_session: &Path, new_session: &Path, old_app: &Path, new_app: &Path) {
    let home = home();
    let under = |p: &Path| p.strip_prefix(&home).ok().map(|r| format!("/'{}", r.to_string_lossy()));
    let full = |p: &Path| p.to_string_lossy().to_string();
    let mut pairs = Vec::new();
    for (old, new) in [(old_session, new_session), (old_app, new_app)] {
        if let (Some(o), Some(n)) = (under(old), under(new)) {
            pairs.push((o, n));
        }
        pairs.push((full(old), full(new)));
    }
    let mut stack = vec![folder.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.is_symlink() {
                continue;
            }
            if path.is_dir() {
                stack.push(path);
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&path) else { continue };
            let mut changed = text.clone();
            for (old, new) in &pairs {
                changed = changed.replace(old.as_str(), new);
            }
            if changed != text {
                let _ = std::fs::write(&path, changed);
            }
        }
    }
}
