//! Where the window was left: its org, tabs, panels and each page's
//! controls, restored on the next launch. Kept in the pilot's own folder,
//! never in Gannin's, and written whenever it changes (a quit isn't always
//! clean, so saving only then would lose it).

use crate::issues::IssuesSaved;
use crate::metrics::Granularity;
use crate::shell::Nav;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Serialize, Deserialize, Clone, PartialEq)]
#[serde(default)]
pub struct SavedState {
    pub org: Option<String>,
    /// The project picked, by its harness repo.
    pub project: Option<String>,
    pub tabs: Vec<Nav>,
    pub active: usize,
    pub sidebar_open: bool,
    pub inspector_open: bool,
    pub dock_open: bool,
    pub sidebar_width: f32,
    pub inspector_width: f32,
    pub dock_height: f32,
    pub collapsed_sections: Vec<String>,
    pub expanded_groups: Vec<Nav>,
    pub ci: CiSaved,
    pub issues: IssuesSaved,
}

#[derive(Serialize, Deserialize, Clone, PartialEq)]
#[serde(default)]
pub struct CiSaved {
    pub days: i64,
    pub granularity: Granularity,
}

impl Default for CiSaved {
    fn default() -> Self {
        Self { days: 30, granularity: Granularity::Day }
    }
}

impl Default for SavedState {
    fn default() -> Self {
        Self {
            org: None,
            project: None,
            tabs: vec![Nav::Ci],
            active: 0,
            sidebar_open: true,
            inspector_open: false,
            dock_open: false,
            sidebar_width: 230.0,
            inspector_width: 340.0,
            dock_height: 220.0,
            // Closed to start with, as in the Swift sidebar.
            collapsed_sections: vec!["rituals".into(), "harness".into()],
            expanded_groups: Vec::new(),
            ci: CiSaved::default(),
            issues: IssuesSaved::default(),
        }
    }
}

fn path() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join("Library/Application Support/GanninGPUIPilot/state.json")
}

impl SavedState {
    /// The last state saved, or the defaults when there's none or it can't
    /// be read.
    pub fn load() -> Self {
        std::fs::read(path()).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default()
    }

    /// Writes to a temporary file and moves it over, so a half-written file
    /// is never read back.
    pub fn save(&self) {
        let path = path();
        let Ok(json) = serde_json::to_vec_pretty(self) else { return };
        if let Some(folder) = path.parent() {
            let _ = std::fs::create_dir_all(folder);
        }
        let temporary = path.with_extension("json.tmp");
        if std::fs::write(&temporary, json).is_ok() {
            let _ = std::fs::rename(&temporary, &path);
        }
    }
}
