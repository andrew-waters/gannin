//! Move to Server: a stopped session started on this Mac, moved to a
//! server so it resumes there. Nothing goes through GitHub (no push):
//!
//! 1. The harness is cloned there if it isn't yet, at the same place under
//!    home, as a session there expects.
//! 2. Each worktree in the session's folder is made there: its code repo
//!    (`projects/<name>`) cloned if missing, the branch carried over as a
//!    git bundle of what origin doesn't have, and checked out at the same
//!    commit in the same place.
//! 3. What isn't committed goes as files: changed and new files (not
//!    ignored ones, so no `node_modules`), deletions, and everything else in
//!    the folder (the brief, Ask's files, the context).
//! 4. Claude's conversation (`~/.claude/projects/<harness>/<id>.jsonl` and
//!    its folder) goes to the project folder for the harness's path there,
//!    and the session is marked started, so it resumes rather than starts.
//! 5. The session's record says the server; Resume then runs it there.
//!
//! The copies here are left as they were. Blocks: call off the main thread.

use crate::launch::{quote, quote_path, Launch};
use crate::servers::Server;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git").arg("-C").arg(dir).args(args).stdin(Stdio::null()).output().map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

/// Runs a bash script there in a login shell, with git using gh for
/// github.com as sessions there do.
fn remote(server: &Server, script: &str) -> Result<String, String> {
    crate::servers::script(server, &format!("set -e\nexport {}\n{script}", crate::servers::GIT_ENV))
}

/// Sends `bytes` to a file there.
fn upload(server: &Server, path: &str, bytes: &[u8]) -> Result<(), String> {
    crate::servers::command(server, &format!("cat > {path}"), Some(bytes)).map(|_| ())
}

/// A tar of `paths` (relative to `root`, NUL-separated), unpacked into
/// `into` there.
fn copy_files(server: &Server, root: &Path, paths: &[String], into: &str) -> Result<(), String> {
    if paths.is_empty() {
        return Ok(());
    }
    let list: Vec<u8> = paths.iter().flat_map(|p| p.bytes().chain(std::iter::once(0))).collect();
    let mut tar = Command::new("tar")
        .env("COPYFILE_DISABLE", "1")
        .arg("-C")
        .arg(root)
        .args(["--null", "-T", "-", "-cf", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Couldn't run tar: {e}"))?;
    let mut input = tar.stdin.take().ok_or("tar")?;
    std::thread::spawn(move || {
        let _ = input.write_all(&list);
    });
    let out = tar.wait_with_output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!("Couldn't pack the files: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    crate::servers::command(server, &format!("mkdir -p {into} && tar -C {into} -xf -"), Some(&out.stdout)).map(|_| ())
}

/// A worktree's own path relative to `root`, as tar takes it.
fn relative(root: &Path, path: &Path) -> String {
    path.strip_prefix(root).unwrap_or(path).to_string_lossy().into_owned()
}

/// One worktree made there, at the same commit, with what isn't
/// committed.
fn move_worktree(server: &Server, launch: &Launch, worktree: &Path, step: &dyn Fn(&str)) -> Result<(), String> {
    let name = worktree.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let fail = |what: &str, e: String| format!("{name}: {what}: {e}");
    let common = PathBuf::from(git(worktree, &["rev-parse", "--path-format=absolute", "--git-common-dir"]).map_err(|e| fail("not a git worktree", e))?);
    let main = common.parent().ok_or_else(|| fail("no repository", String::new()))?.to_path_buf();
    let origin = git(&main, &["remote", "get-url", "origin"]).map_err(|e| fail("no origin", e))?;
    let head = git(worktree, &["rev-parse", "HEAD"]).map_err(|e| fail("no commit", e))?;
    let branch = git(worktree, &["symbolic-ref", "--quiet", "--short", "HEAD"]).ok();

    // What origin's default branch doesn't have, as a bundle: none at all
    // when the branch adds nothing.
    let tip = branch.as_deref().unwrap_or("HEAD");
    let base = git(worktree, &["rev-parse", "--verify", "--quiet", "refs/remotes/origin/HEAD"]).ok();
    let bundle_path = std::env::temp_dir().join(format!("gannin-move-{}-{name}.bundle", launch.id));
    let mut args = vec!["bundle".to_string(), "create".into(), "--quiet".into(), bundle_path.to_string_lossy().into_owned(), tip.to_string()];
    if let Some(base) = &base {
        args.push(format!("^{base}"));
    }
    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
    let bundled = git(worktree, &arg_refs).is_ok() && bundle_path.exists();
    let bundle = if bundled { std::fs::read(&bundle_path).ok() } else { None };
    let _ = std::fs::remove_file(&bundle_path);
    let remote_bundle = format!("/tmp/gannin-move-{}-{}.bundle", launch.id, name.replace(|c: char| !c.is_ascii_alphanumeric(), "-"));
    if let Some(bytes) = &bundle {
        step("sending the branch");
        upload(server, &quote(&remote_bundle), bytes).map_err(|e| fail("couldn't send the branch", e))?;
    }

    let checkout = match &branch {
        Some(b) => format!("-B {}", quote(b)),
        None => "--detach".into(),
    };
    let script = format!(
        r#"main={main}
wt={wt}
if [ ! -e "$main/.git" ]; then mkdir -p "$(dirname "$main")"; git clone --quiet {origin} "$main"; fi
git -C "$main" fetch --quiet origin || true
{fetch_bundle}
git -C "$main" cat-file -e {head}^{{commit}} || {{ echo "The commit isn't there" >&2; exit 1; }}
if [ -e "$wt/.git" ]; then
  git -C "$wt" checkout --quiet -f {checkout} {head}
else
  mkdir -p "$(dirname "$wt")"
  git -C "$main" worktree add --quiet -f {checkout} "$wt" {head}
fi
"#,
        main = quote_path(&main),
        wt = quote_path(worktree),
        origin = quote(&origin),
        head = quote(&head),
        fetch_bundle = if bundle.is_some() {
            let tip_ref = branch.as_ref().map_or("HEAD".to_string(), |b| format!("refs/heads/{b}"));
            format!("git -C \"$main\" fetch --quiet {b} {r}; rm -f {b}", b = quote(&remote_bundle), r = quote(&tip_ref))
        } else {
            String::new()
        },
    );
    step("checking it out there");
    remote(server, &script).map_err(|e| fail("couldn't make the worktree there", e))?;

    // What isn't committed: changed and new files, then deletions.
    let changed = git(worktree, &["ls-files", "-z", "--modified", "--others", "--exclude-standard"]).unwrap_or_default();
    let deleted = git(worktree, &["ls-files", "-z", "--deleted"]).unwrap_or_default();
    let deleted: Vec<&str> = deleted.split('\0').filter(|p| !p.is_empty()).collect();
    let changed: Vec<String> = changed.split('\0').filter(|p| !p.is_empty() && !deleted.contains(p)).map(str::to_string).collect();
    step("copying what isn't committed");
    copy_files(server, worktree, &changed, &quote_path(worktree)).map_err(|e| fail("couldn't copy the uncommitted files", e))?;
    if !deleted.is_empty() {
        let removals: String = deleted.iter().map(|p| format!("rm -f -- {}\n", quote(p))).collect();
        remote(server, &format!("cd {}\n{removals}", quote_path(worktree))).map_err(|e| fail("couldn't remove the deleted files", e))?;
    }
    Ok(())
}

/// Moves the session to `server`. The session must be stopped. The moved
/// launch, saved, on success. `progress` hears each step as it starts.
pub fn move_to(launch: &Launch, server: &Server, progress: &dyn Fn(String)) -> Result<Launch, String> {
    if launch.server.is_some() {
        return Err("It already runs on a server.".into());
    }
    progress(format!("Getting the harness ready on {}", server.name()));
    let harness = quote_path(&launch.harness_path);
    remote(
        server,
        &format!(
            "harness={harness}\nif [ ! -e \"$harness/.git\" ]; then mkdir -p \"$(dirname \"$harness\")\"; if command -v gh >/dev/null 2>&1; then gh repo clone {repo} \"$harness\" -- --quiet; else git clone --quiet {url} \"$harness\"; fi; fi\n",
            repo = quote(&launch.harness_repo),
            url = quote(&format!("https://github.com/{}.git", launch.harness_repo)),
        ),
    )
    .map_err(|e| format!("Couldn't reach the harness on {}: {e}", server.name()))?;

    // The worktrees, then the rest of the folder as files.
    let folder = launch.folder();
    let mut worktrees = Vec::new();
    let mut others = Vec::new();
    for entry in std::fs::read_dir(&folder).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.is_dir() && path.join(".git").exists() {
            worktrees.push(path);
        } else {
            others.push(relative(&folder, &path));
        }
    }
    worktrees.sort();
    let count = worktrees.len();
    for (index, worktree) in worktrees.iter().enumerate() {
        let name = worktree.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let step = |what: &str| progress(if count > 1 { format!("Worktree {} of {count}, {name}: {what}", index + 1) } else { format!("{name}: {what}") });
        move_worktree(server, launch, worktree, &step)?;
    }
    progress("Copying the session's files".into());
    copy_files(server, &folder, &others, &quote_path(&folder)).map_err(|e| format!("Couldn't copy the session's files: {e}"))?;

    // Claude's conversation, into the project folder Claude Code keeps for
    // the harness's path there (every character but letters and digits as -).
    if let Some(transcript) = crate::review::transcript_path(&launch.claude_id()) {
        progress("Copying Claude's conversation".into());
        let project = transcript.parent().ok_or("transcript")?.to_path_buf();
        let id = launch.claude_id();
        let mut files = vec![format!("{id}.jsonl")];
        if project.join(&id).is_dir() {
            files.push(id.clone());
        }
        let into = remote(server, &format!("p={harness}\nprintf '%s' \"$HOME/.claude/projects/$(printf '%s' \"$p\" | sed 's/[^A-Za-z0-9]/-/g')\"\n"))
            .map_err(|e| format!("Couldn't find Claude's folder there: {e}"))?;
        let into = into.trim();
        if into.is_empty() {
            return Err("Couldn't find Claude's folder there.".into());
        }
        copy_files(server, &project, &files, &quote(into)).map_err(|e| format!("Couldn't copy the conversation: {e}"))?;
    }

    // Marked started there, so it resumes; the folder itself goes up with
    // every start.
    let dir = launch.dir();
    if dir.join("started").exists() {
        let remote_dir = quote_path(&dir);
        remote(server, &format!("mkdir -p {remote_dir} && touch {remote_dir}/started")).map_err(|e| format!("Couldn't mark it started there: {e}"))?;
    }

    progress("Saving the session".into());
    let mut moved = launch.clone();
    moved.server = Some(server.clone());
    std::fs::write(dir.join("session.json"), serde_json::to_vec_pretty(&moved).unwrap_or_default()).map_err(|e| format!("Couldn't save the session: {e}"))?;
    Ok(moved)
}
