//! The pilot's own copies of Gannin's GitHub caches, in the same formats,
//! under `Application Support/GanninGPUIPilot/Caches/`. The first read of
//! one copies Gannin's file as a start; from then on the pilot's sync keeps
//! its copy current and Gannin's files are never written, so the two apps
//! can't overwrite each other.

use std::path::PathBuf;

/// A cache Gannin keeps per org.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Issues,
    PullRequests,
    Actions,
}

impl Kind {
    /// Its folder, named as Gannin names it.
    fn folder(self) -> &'static str {
        match self {
            Kind::Issues => "StoredIssues",
            Kind::PullRequests => "PullRequests",
            Kind::Actions => "Actions",
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

/// The pilot's copy, made from Gannin's the first time it's asked for.
pub fn path(kind: Kind, org: &str) -> PathBuf {
    let folder = support().join("GanninGPUIPilot/Caches").join(kind.folder());
    let path = folder.join(file_name(org));
    if !path.exists() {
        let source = gannin_path(kind, org);
        if source.exists() {
            let _ = std::fs::create_dir_all(&folder);
            // Through a temporary file, so a half-copied cache is never read.
            let partial = path.with_extension("json.part");
            if std::fs::copy(&source, &partial).is_ok() {
                let _ = std::fs::rename(&partial, &path);
            }
        }
    }
    path
}

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
