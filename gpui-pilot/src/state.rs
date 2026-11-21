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
    /// The folder the window has open (Open Recent), here or on a server.
    pub folder: Option<crate::folders::Location>,
    /// Before tabs had their own controls: the pages, in order. Read once
    /// when `views` is empty.
    #[serde(deserialize_with = "lenient")]
    pub tabs: Vec<Nav>,
    #[serde(deserialize_with = "lenient")]
    pub views: Vec<SavedTab>,
    /// The launches of the session tabs that were open, in tab order, to
    /// open again (claude resumes in each).
    pub sessions: Vec<String>,
    /// The plain Claude Code sessions among them (`plain:<id>` in
    /// `sessions`): where each runs, to open there and resume.
    pub plain_sessions: Vec<PlainSession>,
    /// The session tab that was showing, by its launch, to show again.
    pub active_session: Option<String>,
    pub active: usize,
    pub sidebar_open: bool,
    /// The Harness panel, beside the navigation.
    pub harness_open: bool,
    /// The tab bar's filter by kind, and whether tabs group by kind.
    pub tab_filter: Option<crate::shell::TabKind>,
    /// Tabs shown by whether their session runs: active or stopped.
    pub tab_status: Option<crate::shell::TabStatus>,
    pub group_tabs: bool,
    pub collapsed_kinds: Vec<crate::shell::TabKind>,
    /// Tabs in a column on the left, in place of the bar across the top.
    pub tabs_on_left: bool,
    pub inspector_open: bool,
    pub dock_open: bool,
    pub sidebar_width: f32,
    pub inspector_width: f32,
    pub dock_height: f32,
    pub collapsed_sections: Vec<String>,
    #[serde(deserialize_with = "lenient")]
    pub expanded_groups: Vec<Nav>,
    /// Names given to tabs, in place of the page's own.
    pub tab_names: Vec<(Nav, String)>,
    /// Tabs pinned so they can't be closed by accident: a session's by its
    /// saved key (as in `sessions`), a page's by its `Nav` as JSON.
    pub pinned_tabs: Vec<String>,
    /// Names given to session tabs, by the session's saved key (as in
    /// `sessions`), put back when each reopens.
    pub session_names: Vec<(String, String)>,
    /// Where the window was and how big, so each window comes back where
    /// it was rather than all of them centred on one another.
    pub window: Option<SavedBounds>,
    /// What a new tab of each page starts from (its filters reset).
    pub ci: CiSaved,
    pub issues: IssuesSaved,
    pub prs: PrsSaved,
    pub sync: SyncPrefs,
}

/// A window's place on screen, in points.
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq)]
pub struct SavedBounds {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    /// Zoomed to fill the screen (its bounds are where it returns to).
    #[serde(default)]
    pub maximized: bool,
}

/// A plain Claude Code session: its conversation ID and where it runs.
#[derive(Serialize, Deserialize, Clone, PartialEq)]
pub struct PlainSession {
    pub id: String,
    pub location: crate::folders::Location,
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
            folder: None,
            tabs: vec![Nav::Ci],
            views: Vec::new(),
            sessions: Vec::new(),
            plain_sessions: Vec::new(),
            active_session: None,
            active: 0,
            sidebar_open: true,
            tabs_on_left: false,
            harness_open: false,
            tab_filter: None,
            tab_status: None,
            group_tabs: false,
            collapsed_kinds: Vec::new(),
            inspector_open: false,
            dock_open: false,
            sidebar_width: 230.0,
            inspector_width: 340.0,
            dock_height: 220.0,
            // Closed to start with, as in the Swift sidebar.
            collapsed_sections: vec!["rituals".into(), "harness".into()],
            expanded_groups: Vec::new(),
            tab_names: Vec::new(),
            pinned_tabs: Vec::new(),
            session_names: Vec::new(),
            window: None,
            ci: CiSaved::default(),
            issues: IssuesSaved::default(),
            prs: PrsSaved::default(),
            sync: SyncPrefs::default(),
        }
    }
}

fn folder() -> PathBuf {
    crate::paths::app_dir()
}

/// A window's state: the first window's is state.json, others' state-<n>.json.
fn path_for(slot: usize) -> PathBuf {
    folder().join(if slot == 0 { "state.json".to_string() } else { format!("state-{slot}.json") })
}

/// The windows besides the first that were open, by their slot.
pub fn extra_slots() -> Vec<usize> {
    let mut slots: Vec<usize> = std::fs::read_dir(folder())
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().to_str()?.strip_prefix("state-")?.strip_suffix(".json")?.parse().ok())
        .filter(|&n: &usize| n > 0)
        .collect();
    slots.sort();
    slots
}

/// A closed window's state goes, so it doesn't open again: the first
/// window's too, which then opens only when no other window was saved.
pub fn remove_slot(slot: usize) {
    let _ = std::fs::remove_file(path_for(slot));
}

/// Whether a window's state was saved, so it opens at launch.
pub fn has_slot(slot: usize) -> bool {
    path_for(slot).exists()
}

impl SavedState {
    /// The last state saved, or the defaults when there's none or it can't
    /// be read.
    pub fn load() -> Self {
        Self::load_slot(0)
    }

    pub fn load_slot(slot: usize) -> Self {
        std::fs::read(path_for(slot)).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default()
    }

    /// Writes to a temporary file and moves it over, so a half-written file
    /// is never read back.
    pub fn save_slot(&self, slot: usize) {
        let path = path_for(slot);
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

/// A list read item by item: one this build can't read (a page that's
/// gone, say) is dropped, not the whole saved state with it.
fn lenient<'de, D: serde::Deserializer<'de>, T: serde::de::DeserializeOwned>(d: D) -> Result<Vec<T>, D::Error> {
    let values: Vec<serde_json::Value> = serde::Deserialize::deserialize(d).unwrap_or_default();
    Ok(values.into_iter().filter_map(|v| serde_json::from_value(v).ok()).collect())
}
