//! The org's harnesses, read with git: what's on GitHub's default branch,
//! as Gannin's harness index holds it, without needing the Swift app.
//!
//! A harness checked out here (a folder opened in a window, or one of the
//! usual places) is fetched and read from `origin`'s default branch with
//! `git ls-tree` and `git cat-file`, so the working tree, its branch and
//! anything uncommitted are never touched. A harness with no checkout here
//! is cloned, without a working tree, into `~/.gannin/harnesses/`.
//!
//! Fetches go at most every few minutes per harness; what's read is kept
//! per commit, so reading again costs one `git rev-parse`. Network calls
//! carry the pilot's GitHub token as a header (in git's environment, never
//! its command line) and never prompt.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// How long a fetch stands before the next read fetches again.
const FETCH_EVERY: Duration = Duration::from_secs(5 * 60);

/// One harness as its default branch has it: the documents' folders and
/// the team's data under `.gannin/`.
pub struct Snapshot {
    /// `owner/name`.
    pub repo: String,
    /// The default branch's name, for links.
    pub branch: String,
    pub commit: String,
    /// Path and text, in path order.
    pub files: Vec<(String, String)>,
}

impl Snapshot {
    pub fn file(&self, path: &str) -> Option<&str> {
        self.files.iter().find(|(p, _)| p == path).map(|(_, t)| t.as_str())
    }

    /// A team data file read as JSON, or None when it's missing or unreadable.
    pub fn json(&self, path: &str) -> Option<serde_json::Value> {
        self.file(path).and_then(|t| serde_json::from_str(t).ok())
    }

    /// Every file whose path starts with `prefix`.
    pub fn under<'a>(&'a self, prefix: &'a str) -> impl Iterator<Item = &'a (String, String)> + 'a {
        self.files.iter().filter(move |(p, _)| p.starts_with(prefix))
    }
}

/// The documents' top folders, as `HarnessKind(path:)` reads them, and
/// `notes/`, people's shared notes (`notes.rs`).
const DOC_FOLDERS: [&str; 12] = ["plans", "requirements", "decisions", "findings", "skills", "prompts", "learnings", "research", "refines", "specialists", "shortcuts", "notes"];

/// What a snapshot keeps: Markdown in the documents' folders, and JSON
/// under `.gannin/` (`HarnessDataFile.isData`).
fn wanted(path: &str) -> bool {
    if path.starts_with(".gannin/") {
        return path.ends_with(".json");
    }
    path.ends_with(".md") && path.split('/').next().is_some_and(|top| DOC_FOLDERS.contains(&top))
}

/// Every harness of the org's, home first, each as it is on GitHub. Fetches
/// and runs git: call off the main thread.
pub fn snapshots(org: &str) -> Vec<Arc<Snapshot>> {
    crate::projects::harness_repos(org).iter().filter_map(|repo| snapshot(org, repo)).collect()
}

/// One harness as it is on GitHub, or None when it can't be read (no
/// checkout and no clone, or git failing).
pub fn snapshot(org: &str, repo: &str) -> Option<Arc<Snapshot>> {
    let path = checkout(org, repo)?;
    fetch(&path);
    let reference = default_ref(&path)?;
    let commit = git(&path, &["rev-parse", "--verify", "--quiet", &format!("{reference}^{{commit}}")])?;
    static READ: Mutex<Option<HashMap<PathBuf, Arc<Snapshot>>>> = Mutex::new(None);
    if let Some(held) = READ.lock().ok().and_then(|r| r.as_ref().and_then(|m| m.get(&path).cloned())) {
        if held.commit == commit {
            return Some(held);
        }
    }
    let files = read_files(&path, &commit)?;
    let branch = reference.strip_prefix("origin/").unwrap_or(&reference).to_string();
    let snapshot = Arc::new(Snapshot { repo: repo.to_string(), branch, commit, files });
    if let Ok(mut read) = READ.lock() {
        read.get_or_insert_with(HashMap::new).insert(path, snapshot.clone());
    }
    Some(snapshot)
}

/// Where the harness is: a checkout here, else the pilot's own clone,
/// made the first time it's asked for.
fn checkout(org: &str, repo: &str) -> Option<PathBuf> {
    let local = crate::launch::harness_path(org, repo);
    if local.join(".git").exists() {
        return Some(local);
    }
    let (owner, name) = repo.split_once('/')?;
    let clone = crate::paths::app_dir().join("harnesses").join(owner).join(name);
    if clone.join(".git").exists() {
        return Some(clone);
    }
    std::fs::create_dir_all(clone.parent()?).ok()?;
    let url = format!("https://github.com/{repo}.git");
    let made = with_auth(Command::new("git").args(["clone", "--quiet", "--no-checkout", &url]).arg(&clone)).status().ok()?.success();
    if !made {
        let _ = std::fs::remove_dir_all(&clone);
        return None;
    }
    // Remembered as fetched just now.
    fetched_at().lock().ok()?.insert(clone.clone(), Instant::now());
    Some(clone)
}

fn fetched_at() -> &'static Mutex<HashMap<PathBuf, Instant>> {
    static FETCHED: std::sync::OnceLock<Mutex<HashMap<PathBuf, Instant>>> = std::sync::OnceLock::new();
    FETCHED.get_or_init(Default::default)
}

/// `git fetch origin`, unless it was fetched in the last few minutes. A
/// failed fetch (offline) leaves what was fetched before.
fn fetch(path: &Path) {
    {
        let Ok(mut fetched) = fetched_at().lock() else { return };
        if fetched.get(path).is_some_and(|at| at.elapsed() < FETCH_EVERY) {
            return;
        }
        // Marked before fetching, so two reads at once fetch once.
        fetched.insert(path.to_path_buf(), Instant::now());
    }
    let _ = with_auth(Command::new("git").arg("-C").arg(path).args(["fetch", "--quiet", "origin"])).status();
}

/// `origin/<default>`: origin's HEAD, else main or master.
fn default_ref(path: &Path) -> Option<String> {
    if let Some(head) = git(path, &["rev-parse", "--abbrev-ref", "origin/HEAD"]).filter(|h| h.starts_with("origin/") && h != "origin/HEAD") {
        return Some(head);
    }
    ["origin/main", "origin/master"].into_iter().find(|r| git(path, &["rev-parse", "--verify", "--quiet", r]).is_some()).map(str::to_string)
}

/// The wanted files at `commit`, read in one `git cat-file --batch`.
fn read_files(path: &Path, commit: &str) -> Option<Vec<(String, String)>> {
    let listed = git_bytes(path, &["ls-tree", "-r", "-z", "--name-only", commit])?;
    let paths: Vec<String> = listed.split(|b| *b == 0).filter_map(|p| std::str::from_utf8(p).ok()).filter(|p| wanted(p)).map(str::to_string).collect();
    if paths.is_empty() {
        return Some(Vec::new());
    }
    let mut child = Command::new("git").arg("-C").arg(path).args(["cat-file", "--batch"]).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;
    let mut input = child.stdin.take()?;
    let requests: String = paths.iter().map(|p| format!("{commit}:{p}\n")).collect();
    // Written from a thread of its own, so a full output pipe can't stall it.
    let writer = std::thread::spawn(move || {
        let _ = input.write_all(requests.as_bytes());
    });
    let mut out = BufReader::new(child.stdout.take()?);
    let mut files = Vec::with_capacity(paths.len());
    for path in &paths {
        let mut header = String::new();
        if out.read_line(&mut header).ok()? == 0 {
            break;
        }
        // "<sha> blob <size>", or "<name> missing".
        let size = header.split_whitespace().nth(2).and_then(|s| s.parse::<usize>().ok());
        let Some(size) = size else { continue };
        let mut body = vec![0; size + 1];
        out.read_exact(&mut body).ok()?;
        body.pop();
        if let Ok(text) = String::from_utf8(body) {
            files.push((path.clone(), text));
        }
    }
    let _ = writer.join();
    let _ = child.wait();
    Some(files)
}

fn git(path: &Path, args: &[&str]) -> Option<String> {
    git_bytes(path, args).map(|b| String::from_utf8_lossy(&b).trim().to_string()).filter(|s| !s.is_empty())
}

fn git_bytes(path: &Path, args: &[&str]) -> Option<Vec<u8>> {
    let output = Command::new("git").arg("-C").arg(path).args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    output.status.success().then_some(output.stdout)
}

/// Never prompts, and sends the pilot's token to github.com (only), through
/// git's environment so it's not on the command line.
fn with_auth(command: &mut Command) -> &mut Command {
    use base64::Engine;
    command.env("GIT_TERMINAL_PROMPT", "0").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    // An ssh remote mustn't wait on a passphrase either.
    if std::env::var_os("GIT_SSH_COMMAND").is_none() {
        command.env("GIT_SSH_COMMAND", "ssh -o BatchMode=yes");
    }
    if let Some(token) = crate::auth::token() {
        let basic = base64::engine::general_purpose::STANDARD.encode(format!("x-access-token:{token}"));
        command
            .env("GIT_CONFIG_COUNT", "1")
            .env("GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader")
            .env("GIT_CONFIG_VALUE_0", format!("AUTHORIZATION: basic {basic}"));
    }
    command
}
