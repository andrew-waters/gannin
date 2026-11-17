//! The pilot's own copies of Gannin's GitHub caches, in the same formats,
//! in a hidden folder in the org's home harness checkout
//! (`<harness>/.gannin-cache/`), which ignores itself in git so it's never
//! committed. With no checkout of the harness on this Mac they're kept in
//! `~/.gannin/caches/`. The first read of one
//! copies the pilot's earlier copy, else Gannin's, as a start; from then on
//! the pilot's sync keeps its copy current and Gannin's files are never
//! written, so the two apps can't overwrite each other.

use std::path::PathBuf;

/// A cache Gannin keeps per org.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Issues,
    PullRequests,
    Actions,
    /// How far back the PR store's metrics go (`MetricsHistory`).
    Metrics,
    /// How far back the issue store's history goes (`IssueHistory`).
    IssueHistory,
    /// The issues of the work log, and how far back it goes (`WorkLogHistory`).
    WorkLog,
    /// The workload snapshot: the org's members and teams (`OrgSnapshot`).
    Snapshots,
}

impl Kind {
    /// Its folder, named as Gannin names it.
    fn folder(self) -> &'static str {
        match self {
            Kind::Issues => "StoredIssues",
            Kind::PullRequests => "PullRequests",
            Kind::Actions => "Actions",
            Kind::Metrics => "Metrics",
            Kind::IssueHistory => "Issues",
            Kind::WorkLog => "WorkLog",
            Kind::Snapshots => "Snapshots",
        }
    }
}

fn support() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join("Library/Application Support")
}

/// The file name for an org, percent-encoded as `OrgJSONCache` does.
fn file_name(org: &str) -> String {
    let encoded = org.replace('%', "%25").replace(' ', "%20").replace('/', "%2F");
    format!("{encoded}.json")
}

/// Gannin's own copy, read only.
pub fn gannin_path(kind: Kind, org: &str) -> PathBuf {
    support().join(kind.folder()).join(file_name(org))
}

/// Where the pilot kept its caches before they moved into the harness, and
/// still keeps them for an org with no harness checkout here.
fn fallback() -> PathBuf {
    crate::paths::app_dir().join("caches")
}

/// The folder an org's synced data lives in: `.gannin-cache/` in its home
/// harness (its first project's, as the pages order them) when that's
/// checked out here, else the fallback. Worked out once per org, as it runs
/// git and reads the harness indexes.
pub fn root(org: &str) -> PathBuf {
    static ROOTS: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, PathBuf>>> = std::sync::OnceLock::new();
    let roots = ROOTS.get_or_init(Default::default);
    if let Some(root) = roots.lock().ok().and_then(|r| r.get(org).cloned()) {
        return root;
    }
    let root = harness_root(org).unwrap_or_else(fallback);
    if let Ok(mut roots) = roots.lock() {
        roots.insert(org.to_string(), root.clone());
    }
    root
}

fn harness_root(org: &str) -> Option<PathBuf> {
    if org.is_empty() {
        return None;
    }
    let repo = crate::projects::load(org).projects.first().map(|p| p.id.clone()).filter(|id| id.contains('/'))?;
    crate::paths::harness_cache(&crate::launch::harness_path(org, &repo))
}

/// Copies `source` to `path` through a temporary file, so a half-copied
/// cache is never read.
fn seed(path: &std::path::Path, source: &std::path::Path) {
    if path.exists() || !source.exists() {
        return;
    }
    if let Some(folder) = path.parent() {
        let _ = std::fs::create_dir_all(folder);
    }
    let partial = path.with_extension("json.part");
    if std::fs::copy(source, &partial).is_ok() {
        let _ = std::fs::rename(&partial, path);
    }
}

/// A file of the org's beside its caches (`synced.json`, `Details.json`),
/// started from the pilot's earlier copy of `earlier` the first time.
pub fn org_file(org: &str, name: &str, earlier: &str) -> PathBuf {
    let path = root(org).join(name);
    seed(&path, &fallback().join(earlier));
    path
}

/// The pilot's copy, made from its earlier copy or Gannin's the first time
/// it's asked for.
pub fn path(kind: Kind, org: &str) -> PathBuf {
    let path = root(org).join(kind.folder()).join(file_name(org));
    seed(&path, &fallback().join(kind.folder()).join(file_name(org)));
    seed(&path, &gannin_path(kind, org));
    path
}

/// Held while reading, changing and writing back a store that more than
/// one thread updates (the issue store: the sync, the issue history and a
/// drawer's refresh), so one never writes over another's change.
pub static STORE: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Writes a cache through a temporary file and a rename.
pub fn write(kind: Kind, org: &str, bytes: &[u8]) -> std::io::Result<()> {
    let path = path(kind, org);
    if let Some(folder) = path.parent() {
        std::fs::create_dir_all(folder)?;
    }
    let partial = path.with_extension("json.part");
    std::fs::write(&partial, bytes)?;
    std::fs::rename(&partial, &path)
}
