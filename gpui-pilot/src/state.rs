//! Where the window was left: its org, tabs, panels and each page's
//! controls, restored on the next launch. Kept in the pilot's own folder,
//! never in Gannin's, and written whenever it changes (a quit isn't always
//! clean, so saving only then would lose it).

use crate::issues::IssuesSaved;
use crate::prs::PrsSaved;
use crate::metrics::Granularity;
use crate::shell::Nav;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// A tab: its page, the name given it, and that page's controls.
#[derive(Serialize, Deserialize, Clone, PartialEq)]
pub struct SavedTab {
    pub nav: Nav,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub issues: Option<IssuesSaved>,
    #[serde(default)]
    pub prs: Option<PrsSaved>,
    #[serde(default)]
    pub ci: Option<CiSaved>,
}

#[derive(Serialize, Deserialize, Clone, PartialEq)]
#[serde(default)]
pub struct SavedState {
    pub org: Option<String>,
    /// The project picked, by its harness repo.
    pub project: Option<String>,
    /// Before tabs had their own controls: the pages, in order. Read once
    /// when `views` is empty.
    pub tabs: Vec<Nav>,
    pub views: Vec<SavedTab>,
    /// The launches of the session tabs that were open, in tab order, to
    /// open again (claude resumes in each).
    pub sessions: Vec<String>,
    /// The session tab that was showing, by its launch, to show again.
    pub active_session: Option<String>,
    pub active: usize,
    pub sidebar_open: bool,
    /// The Harness panel, beside the navigation.
    pub harness_open: bool,
    /// The tab bar's filter by kind, and whether tabs group by kind.
    pub tab_filter: Option<crate::shell::TabKind>,
    pub group_tabs: bool,
    pub inspector_open: bool,
    pub dock_open: bool,
    pub sidebar_width: f32,
    pub inspector_width: f32,
    pub dock_height: f32,
    pub collapsed_sections: Vec<String>,
    pub expanded_groups: Vec<Nav>,
    /// Names given to tabs, in place of the page's own.
    pub tab_names: Vec<(Nav, String)>,
    /// What a new tab of each page starts from (its filters reset).
    pub ci: CiSaved,
    pub issues: IssuesSaved,
    pub prs: PrsSaved,
    pub sync: SyncPrefs,
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
            views: Vec::new(),
            sessions: Vec::new(),
            active_session: None,
            active: 0,
            sidebar_open: true,
            harness_open: false,
            tab_filter: None,
            group_tabs: false,
            inspector_open: false,
            dock_open: false,
            sidebar_width: 230.0,
            inspector_width: 340.0,
            dock_height: 220.0,
            // Closed to start with, as in the Swift sidebar.
            collapsed_sections: vec!["rituals".into(), "harness".into()],
            expanded_groups: Vec::new(),
            tab_names: Vec::new(),
            ci: CiSaved::default(),
            issues: IssuesSaved::default(),
            prs: PrsSaved::default(),
            sync: SyncPrefs::default(),
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

/// Sync settings, as Gannin's Settings › Sync for what the pilot fetches,
/// kept in the pilot's own state.
#[derive(Serialize, Deserialize, Clone, PartialEq)]
#[serde(default)]
pub struct SyncPrefs {
    /// Open PRs and issues: minutes between syncs.
    pub workload_minutes: u32,
    /// Everything searched again: hours between full searches.
    pub full_hours: u32,
    /// Your reviews and PRs (Your Work's live query): minutes, 0 for off.
    pub work_minutes: u32,
    /// Merged work from the last this many days; Gannin's when unset.
    pub lookback_days: Option<i64>,
    /// Points kept for what you do by hand.
    pub reserve: i64,
}

impl Default for SyncPrefs {
    fn default() -> Self {
        Self { workload_minutes: 5, full_hours: 24, work_minutes: 5, lookback_days: None, reserve: 500 }
    }
}
