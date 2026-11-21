//! The pilot's own copies of Gannin's GitHub caches, in the same formats,
//! in a hidden folder in the org's home harness checkout
//! (`<harness>/.gannin-cache/`), which ignores itself in git so it's never
//! committed. With no checkout of the harness on this Mac they're kept in
//! `~/.gannin/caches/`. The first read of one
//! copies the pilot's earlier copy (from before they moved into the harness)
//! as a start; the pilot's sync keeps its copy current. The Swift app's
//! caches are never read.

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

/// The file name for an org, percent-encoded as `OrgJSONCache` does.
fn file_name(org: &str) -> String {
    let encoded = org.replace('%', "%25").replace(' ', "%20").replace('/', "%2F");
    format!("{encoded}.json")
}

/// Where the pilot kept its caches before they moved into the harness, and
/// still keeps them for an org with no harness checkout here.
fn fallback() -> PathBuf {
    crate::paths::app_dir().join("caches")
}

/// The folder an org's synced data lives in: `.gannin-cache/` in its home
/// harness (its first project's, as the pages order them) when that's
/// checked out here, else the fallback. Worked out once per org.
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
    let repo = crate::projects::harness_repos(org).into_iter().next().filter(|id| id.contains('/'))?;
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

/// The pilot's copy, made from its earlier copy the first time it's asked
/// for.
pub fn path(kind: Kind, org: &str) -> PathBuf {
    let path = root(org).join(kind.folder()).join(file_name(org));
    seed(&path, &fallback().join(kind.folder()).join(file_name(org)));
    path
}

/// The orgs with a copy in the fallback folder, from before an org's caches
/// moved into its harness.
pub fn fallback_orgs() -> Vec<String> {
    let mut orgs = Vec::new();
    for kind in [Kind::PullRequests, Kind::Issues, Kind::Actions] {
        for entry in std::fs::read_dir(fallback().join(kind.folder())).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|e| e == "json") {
                if let Some(stem) = path.file_stem() {
                    orgs.push(crate::data::percent_decode(&stem.to_string_lossy()));
                }
            }
        }
    }
    orgs
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
