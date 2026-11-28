//! Servers sessions can run on, added as Zed adds a remote: you type the
//! ssh command you'd use (`ssh aw@mini.home -p 22`, or just `mini`), read
//! with Zed's own parser, and the server is kept only once a connection
//! works. Kept in `servers.json` in the pilot's folder, shaped like Zed's
//! `ssh_connections` (host, username, port, args, nickname).
//!
//! A session started in a window whose folder is on a server (Open Recent)
//! keeps that server (`Launch::server`), and everything about it goes over one
//! ssh connection per server (a ControlMaster, as Zed's):
//!
//! - its terminal: the session's folder is copied up, then `start.sh` runs
//!   there in a login shell, through `ssh -t`;
//! - a mirror: every two seconds the hook files (state, tool.json, pr,
//!   changed, started) and new lines of claude's transcript are copied back
//!   into the session's folder here, so everything that reads them works as
//!   it does for a session on this Mac;
//! - git in the session's worktrees, for Changes, over ssh.
//!
//! The harness is wherever the window's folder has it on the server. Batch mode: ssh never asks for
//! a password, so a server needs key (or agent) sign-in, as Zed recommends.

use base64::Engine;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};

/// Where ssh keeps each shared connection. Short, as a socket's path must
/// be under 104 bytes on macOS, which Application Support isn't.
const CONTROL_PATH: &str = "/tmp/gannin-pilot-%C";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Server {
    pub host: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    /// ssh options kept from the command typed (`-i key`, `-J jump`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nickname: Option<String>,
}

impl Server {
    /// From the ssh command as typed, read as Zed's Connect New Server reads
    /// it: options that would break the connection (`-t`, `-N`, `-f`) are
    /// refused.
    pub fn parse(command: &str, nickname: &str) -> Result<Server, String> {
        let command = command.trim();
        if command.is_empty() {
            return Err("Type the ssh command you use to reach it, such as ssh me@devbox.".into());
        }
        let options = ::remote::SshConnectionOptions::parse_command_line(command).map_err(|e| format!("{e}"))?;
        Ok(Server {
            host: options.host.to_string(),
            username: options.username,
            port: options.port,
            args: options.args.unwrap_or_default(),
            nickname: Some(nickname.trim().to_string()).filter(|n| !n.is_empty()),
        })
    }

    /// `user@host:port`, as much as was given: what tells two servers apart.
    pub fn key(&self) -> String {
        let host = match self.port {
            Some(port) => format!("{}:{port}", self.host),
            None => self.host.clone(),
        };
        match &self.username {
            Some(user) => format!("{user}@{host}"),
            None => host,
        }
    }

    /// Its nickname, else its key.
    pub fn name(&self) -> String {
        self.nickname.clone().unwrap_or_else(|| self.key())
    }

    fn destination(&self) -> String {
        match &self.username {
            Some(user) => format!("{user}@{}", self.host),
            None => self.host.clone(),
        }
    }

    /// ssh's arguments up to the remote command: the shared connection,
    /// then batch mode (or a terminal, for a session), the server's own
    /// options, its port and where to.
    pub fn ssh_args(&self, terminal: bool) -> Vec<String> {
        // A terminal gets its own connection: through the shared master,
        // a resize goes to the master, which has no terminal to read the
        // size from, so the server's stays at what the tab first had.
        let mut args: Vec<String> = if terminal {
            ["-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ServerAliveInterval=30"].map(str::to_string).to_vec()
        } else {
            ["-o", "ControlMaster=auto", "-o", &format!("ControlPath={CONTROL_PATH}"), "-o", "ControlPersist=300", "-o", "ServerAliveInterval=30"].map(str::to_string).to_vec()
        };
        if terminal {
            args.push("-t".into());
        } else {
            args.extend(["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"].map(str::to_string));
        }
        args.extend(self.args.iter().cloned());
        if let Some(port) = self.port {
            args.extend(["-p".to_string(), port.to_string()]);
        }
        args.push(self.destination());
        args
    }

    /// `ssh <arguments>` as one shell command line.
    pub fn ssh_command(&self, terminal: bool) -> String {
        std::iter::once("ssh".to_string()).chain(self.ssh_args(terminal).iter().map(|a| crate::launch::quote(a))).collect::<Vec<_>>().join(" ")
    }
}

// MARK: - Saved servers

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Servers {
    #[serde(default)]
    pub servers: Vec<Server>,
    /// Before a window's folder said where its sessions run: the server
    /// they all ran on. Kept so the file reads back; no longer used.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_on: Option<String>,
}

fn servers_path() -> PathBuf {
    crate::paths::app_dir().join("servers.json")
}

pub fn load() -> Servers {
    std::fs::read(servers_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

pub fn save(servers: &Servers) {
    if let Some(dir) = servers_path().parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(servers_path(), serde_json::to_vec_pretty(servers).unwrap_or_default());
}

/// The hosts named in `~/.ssh/config` (not patterns), offered when adding
/// a server.
pub fn config_hosts() -> Vec<String> {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let text = std::fs::read_to_string(home.join(".ssh/config")).unwrap_or_default();
    let mut hosts: Vec<String> = text
        .lines()
        .map(str::trim)
        .filter_map(|line| {
            let (key, rest) = line.split_once(char::is_whitespace)?;
            key.eq_ignore_ascii_case("host").then(|| rest.split_whitespace().filter(|h| !h.contains(['*', '?', '!'])).map(str::to_string).collect::<Vec<_>>())
        })
        .flatten()
        .collect();
    hosts.dedup();
    hosts
}

// MARK: - Running things there

/// Runs `command` on the server through its shell, in batch mode: what it
/// printed, or why it failed.
pub fn command(server: &Server, command: &str, input: Option<&[u8]>) -> Result<Vec<u8>, String> {
    command_within(server, command, input, None)
}

/// How long a read that runs over and over (the mirror, the Changes pane's
/// git) may take before it's given up on.
pub const READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);

/// `command`, killed once `timeout` passes. Never leave a repeated read
/// unbounded: a client of a wedged shared connection can wait forever, and
/// the mirror is one thread for every session, so one stuck read froze every
/// server session's state. Each stuck client also holds one of the server's
/// sessions on that connection (sshd's MaxSessions, 10 by default).
pub fn command_within(server: &Server, command: &str, input: Option<&[u8]>, timeout: Option<std::time::Duration>) -> Result<Vec<u8>, String> {
    let mut child = Command::new("ssh")
        .args(server.ssh_args(false))
        .arg(command)
        .stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Couldn't run ssh: {e}"))?;
    let Some(timeout) = timeout else {
        if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
            let _ = stdin.write_all(input);
        }
        let out = child.wait_with_output().map_err(|e| e.to_string())?;
        return finished(out.status, out.stdout, &out.stderr);
    };
    // Every pipe on its own thread, so a write or a read that blocks can't
    // keep the deadline from being checked.
    let writer = input.map(<[u8]>::to_vec).zip(child.stdin.take()).map(|(input, mut stdin)| std::thread::spawn(move || drop(stdin.write_all(&input))));
    fn drain(pipe: Option<impl std::io::Read + Send + 'static>) -> std::thread::JoinHandle<Vec<u8>> {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(mut pipe) = pipe {
                let _ = pipe.read_to_end(&mut bytes);
            }
            bytes
        })
    }
    let (stdout, stderr) = (drain(child.stdout.take()), drain(child.stderr.take()));
    let deadline = std::time::Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if std::time::Instant::now() < deadline => std::thread::sleep(std::time::Duration::from_millis(50)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                // Not joined: a process ssh left behind could still hold a pipe open.
                return Err(format!("{} didn't answer within {} seconds", server.name(), timeout.as_secs()));
            }
            Err(e) => return Err(e.to_string()),
        }
    };
    if let Some(writer) = writer {
        let _ = writer.join();
    }
    let (stdout, stderr) = (stdout.join().unwrap_or_default(), stderr.join().unwrap_or_default());
    finished(status, stdout, &stderr)
}

fn finished(status: std::process::ExitStatus, stdout: Vec<u8>, stderr: &[u8]) -> Result<Vec<u8>, String> {
    if status.success() {
        Ok(stdout)
    } else {
        let error = String::from_utf8_lossy(stderr);
        Err(error.lines().rev().find(|l| !l.trim().is_empty()).map(str::to_string).unwrap_or_else(|| format!("ssh exited with {status}")))
    }
}

/// Runs a bash script there in a login shell, so it finds what a session
/// would (the PATH from the shell's profile).
pub fn script(server: &Server, script: &str) -> Result<String, String> {
    command(server, r#"exec "${SHELL:-/bin/bash}" -lc 'exec bash -s'"#, Some(script.as_bytes())).map(|o| String::from_utf8_lossy(&o).into_owned())
}

/// `script`, given up on once `timeout` passes.
pub fn script_within(server: &Server, script: &str, timeout: std::time::Duration) -> Result<String, String> {
    command_within(server, r#"exec "${SHELL:-/bin/bash}" -lc 'exec bash -s'"#, Some(script.as_bytes()), Some(timeout)).map(|o| String::from_utf8_lossy(&o).into_owned())
}

/// git in a folder there, as the Changes pane runs it here.
pub fn git(server: &Server, dir: &Path, args: &[&str]) -> Result<Vec<u8>, String> {
    let args: Vec<String> = args.iter().map(|a| crate::launch::quote(a)).collect();
    command_within(server, &format!("git -C {} {}", crate::launch::quote_path(dir), args.join(" ")), None, Some(READ_TIMEOUT))
}

/// The git checkouts in a folder there, by name, as the worktree list
/// reads a folder here.
pub fn checkouts(server: &Server, dir: &Path) -> Vec<String> {
    let script = format!(r#"cd {} 2>/dev/null || exit 0; for d in */; do [ -e "$d.git" ] && printf '%s\n' "${{d%/}}"; done; exit 0"#, crate::launch::quote_path(dir));
    let listed = command_within(server, "bash -s", Some(script.as_bytes()), Some(READ_TIMEOUT)).unwrap_or_default();
    String::from_utf8_lossy(&listed).lines().filter(|l| !l.is_empty()).map(str::to_string).collect()
}

// MARK: - Checking a server

#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub label: &'static str,
    pub ok: bool,
    /// What was found, or what to do.
    pub detail: String,
    /// Sessions can't run without it.
    pub needed: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Check {
    pub at: chrono::DateTime<chrono::Utc>,
    /// Why it couldn't connect; the items are empty then.
    pub error: Option<String>,
    pub items: Vec<Item>,
}

impl Check {
    pub fn ready(&self) -> bool {
        self.error.is_none() && self.items.iter().all(|i| i.ok || !i.needed)
    }
}

/// Each server's last check, by key, for every window: the title bar's dot
/// and the Remotes popover read it. Absent while it's never been checked.
fn checks() -> &'static Mutex<HashMap<String, Check>> {
    static CHECKS: OnceLock<Mutex<HashMap<String, Check>>> = OnceLock::new();
    CHECKS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn last_check(server: &Server) -> Option<Check> {
    checks().lock().ok()?.get(&server.key()).cloned()
}

pub fn forget_check(server: &Server) {
    if let Ok(mut checks) = checks().lock() {
        checks.remove(&server.key());
    }
}

/// Connects and looks for what sessions need there. Never reads claude's
/// sign-in: a session asks for it when it starts.
pub fn check(server: &Server) -> Check {
    const PROBE: &str = r#"
printf 'os=%s\n' "$( (sw_vers -productVersion 2>/dev/null || uname -sr) | head -1) $(uname -m)"
if [ "$(uname)" = Darwin ] && ! xcode-select -p >/dev/null 2>&1; then echo git=; else printf 'git=%s\n' "$(git --version 2>/dev/null)"; fi
printf 'claude=%s\n' "$(claude --version 2>/dev/null | head -1)"
printf 'gh=%s\n' "$(gh --version 2>/dev/null | head -1)"
printf 'ghauth=%s\n' "$(gh auth status 2>&1 | sed -n 's/.*Logged in to \([^ ]*\) account \([^ ]*\).*/\2/p' | head -1)"
printf 'container=%s\n' "$(container --version 2>/dev/null | head -1)"
"#;
    let check = probe(server, PROBE);
    if let Ok(mut checks) = checks().lock() {
        checks.insert(server.key(), check.clone());
    }
    check
}

fn probe(server: &Server, script_text: &str) -> Check {
    let at = chrono::Utc::now();
    let output = match script(server, script_text) {
        Ok(output) => output,
        Err(error) => return Check { at, error: Some(error), items: Vec::new() },
    };
    let found: HashMap<&str, &str> = output.lines().filter_map(|l| l.split_once('=')).map(|(k, v)| (k, v.trim())).collect();
    let get = |key: &str| found.get(key).copied().filter(|v| !v.is_empty()).map(str::to_string);
    let item = |label, value: Option<String>, missing: &str, needed| Item { label, ok: value.is_some(), detail: value.unwrap_or_else(|| missing.to_string()), needed };
    let items = vec![
        item("Connected", get("os"), "", true),
        item("git", get("git"), "Missing. On a Mac: xcode-select --install", true),
        item("Claude Code", get("claude"), "Missing. curl -fsSL https://claude.ai/install.sh | bash", true),
        item("gh", get("gh").map(|v| v.replace("gh version ", "")), "Missing. Sessions use it for pull requests.", false),
        item("gh signed in", get("ghauth").map(|login| format!("as {login}")), "Not signed in. Run gh auth login there.", false),
        item("Apple container", get("container"), "Not installed. Only sandboxed sessions need it.", false),
    ];
    Check { at, error: None, items }
}

// MARK: - Sessions there

#[derive(Clone)]
struct Watched {
    server: Server,
    /// The session's folder here, which the mirror fills.
    local: PathBuf,
    claude_id: String,
    /// Its folder in the harness, the same path there as here.
    folder: PathBuf,
}

fn watched() -> &'static Mutex<HashMap<String, Watched>> {
    static WATCHED: OnceLock<Mutex<HashMap<String, Watched>>> = OnceLock::new();
    WATCHED.get_or_init(|| Mutex::new(HashMap::new()))
}

/// git's environment for anything run there: gh as github.com's credential
/// helper, and never a prompt (see `start_command`).
pub const GIT_ENV: &str = "GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0= GIT_CONFIG_KEY_1=credential.https://github.com.helper 'GIT_CONFIG_VALUE_1=!gh auth git-credential' GIT_TERMINAL_PROMPT=0";

/// The shell command that starts a session on its server: copies the
/// session's folder up (not the files the server writes back), sets its
/// state, then runs `start.sh` there in a login shell with a terminal.
pub fn start_command(server: &Server, launch: &crate::launch::Launch) -> String {
    let local = launch.dir();
    let remote = crate::launch::quote_path(&local);
    let keep = ["state", "started", "changed", "pr", "tool.json", "transcript.jsonl", "risk.json", "auto-posted", "posted.json", "decisions.json", "gate"];
    let excludes: String = keep.iter().map(|f| format!(" --exclude {}", crate::launch::quote(&format!("./{f}")))).collect();
    let unpack = format!("mkdir -p {remote} && tar -C {remote} -xf - && printf starting > {remote}/state");
    // git's own helper there is the macOS keychain, which ssh can't unlock
    // ("User interaction is not allowed"), so git asks for a username and
    // the session hangs. gh keeps its token where ssh can read it: the
    // session's git (the harness pull, worktrees, claude's pushes) uses gh
    // for github.com, and never prompts. The server's git config is left as it is.
    let run = format!(r#"exec env {GIT_ENV} "${{SHELL:-/bin/bash}}" -lic 'exec bash "$0"' {remote}/start.sh"#);
    format!(
        "printf '\\033[90m%s\\033[0m\\n' {note} && COPYFILE_DISABLE=1 tar -C {local}{excludes} -cf - . | {upload} {unpack} || {{ printf '\\033[31mGannin: %s\\033[0m\\n' {failed}; exec \"${{SHELL:-/bin/zsh}}\" -l; }}; exec {terminal} {run}",
        note = crate::launch::quote(&format!("Starting on {}", server.name())),
        local = crate::launch::quote(&local.to_string_lossy()),
        upload = server.ssh_command(false),
        unpack = crate::launch::quote(&unpack),
        failed = crate::launch::quote(&format!("Couldn't reach {} to start the session. Check it from the server button in the title bar.", server.name())),
        terminal = server.ssh_command(true),
        run = crate::launch::quote(&run),
    )
}

/// Starts mirroring a session on a server back here.
pub fn watch(launch: &crate::launch::Launch) {
    let Some(server) = launch.server.clone() else { return };
    let entry = Watched { server, local: launch.dir(), claude_id: launch.claude_id(), folder: launch.folder() };
    if let Ok(mut map) = watched().lock() {
        map.insert(launch.id.clone(), entry);
    }
    static MIRROR: OnceLock<()> = OnceLock::new();
    MIRROR.get_or_init(|| {
        std::thread::spawn(|| loop {
            let jobs: Vec<Watched> = watched().lock().map(|m| m.values().cloned().collect()).unwrap_or_default();
            for job in jobs {
                let _ = pull(&job);
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
        });
    });
}

pub fn unwatch(launch_id: &str) {
    if let Ok(mut map) = watched().lock() {
        map.remove(launch_id);
    }
}

/// The server a path there belongs to: inside a watched session's folder.
pub fn server_for(path: &Path) -> Option<Server> {
    watched().lock().ok()?.values().find(|w| path.starts_with(&w.folder)).map(|w| w.server.clone())
}

/// One round of the mirror: the hook files, whole (they're small), and the
/// transcript from where the copy here ends.
fn pull(job: &Watched) -> Result<(), String> {
    let transcript = job.local.join("transcript.jsonl");
    let have = std::fs::metadata(&transcript).map(|m| m.len()).unwrap_or(0);
    let probe = format!(
        r#"cd {remote} 2>/dev/null || exit 0
for f in state tool.json pr changed started gate/request; do [ -f "$f" ] && printf '%s %s\n' "$f" "$(base64 < "$f" | tr -d '\n')"; done
t=$(ls "$HOME"/.claude/projects/*/{id}.jsonl 2>/dev/null | head -1)
if [ -n "$t" ]; then printf 'size %s\n' "$(wc -c < "$t" | tr -d ' ')"; printf 'transcript %s\n' "$(tail -c +{from} "$t" | base64 | tr -d '\n')"; fi
w={work}
if [ -d "$w" ]; then for f in "$w"/planning.json "$w"/shape/* "$w"/architecture/*; do [ -f "$f" ] && printf 'sum %s %s\n' "$(cksum < "$f" | cut -d' ' -f1-2 | tr ' ' '-')" "$(printf %s "${{f#$w/}}" | base64 | tr -d '\n')"; done; fi
# A glob matching nothing leaves the loop's last test false: that's no failure.
exit 0
"#,
        remote = crate::launch::quote_path(&job.local),
        work = crate::launch::quote_path(&job.folder),
        id = job.claude_id,
        from = have + 1,
    );
    // bash, not the login shell: zsh stops at a glob that matches nothing.
    let output = command_within(&job.server, "bash -s", Some(probe.as_bytes()), Some(READ_TIMEOUT))?;
    let output = String::from_utf8_lossy(&output);
    let decode = |text: &str| base64::engine::general_purpose::STANDARD.decode(text.trim()).ok();
    let mut shrank = false;
    let mut changed: Vec<(String, String)> = Vec::new();
    for line in output.lines() {
        let (name, value) = line.split_once(' ').unwrap_or((line, ""));
        match name {
            // A file of the session's own in the harness (a plan, its
            // screens and architecture), by checksum: fetched when it changes.
            "sum" => {
                let Some((sum, rel)) = value.split_once(' ') else { continue };
                let Some(rel) = decode(rel).and_then(|b| String::from_utf8(b).ok()) else { continue };
                if rel.starts_with('/') || rel.split('/').any(|p| p == "..") {
                    continue;
                }
                let key = format!("{}\n{rel}", job.local.display());
                let seen = sums().lock().ok().and_then(|m| m.get(&key).cloned());
                if seen.as_deref() != Some(sum) || !job.local.join("folder").join(&rel).exists() {
                    changed.push((rel, sum.to_string()));
                }
            }
            "size" => shrank = value.trim().parse::<u64>().is_ok_and(|size| size < have),
            "transcript" if shrank => {
                // Rewritten there: start the copy again next round.
                let _ = std::fs::remove_file(&transcript);
            }
            "transcript" => {
                if let Some(bytes) = decode(value).filter(|b| !b.is_empty()) {
                    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(&transcript).map_err(|e| e.to_string())?;
                    file.write_all(&bytes).map_err(|e| e.to_string())?;
                }
            }
            "state" | "tool.json" | "pr" | "changed" | "started" | "gate/request" => {
                let Some(bytes) = decode(value) else { continue };
                let path = job.local.join(name);
                // A workflow's held push asks for its round in gate/.
                if let Some(folder) = path.parent() {
                    let _ = std::fs::create_dir_all(folder);
                }
                if std::fs::read(&path).ok().as_deref() != Some(bytes.as_slice()) {
                    let _ = std::fs::write(&path, bytes);
                }
            }
            _ => {}
        }
    }
    if !changed.is_empty() {
        let mut fetch = format!("cd {} 2>/dev/null || exit 0\n", crate::launch::quote_path(&job.folder));
        for (rel, _) in &changed {
            fetch.push_str(&format!("[ -f {q} ] && printf 'got %s %s\\n' {b} \"$(base64 < {q} | tr -d '\\n')\"\n", q = crate::launch::quote(rel), b = crate::launch::quote(&base64::engine::general_purpose::STANDARD.encode(rel))));
        }
        fetch.push_str("exit 0\n");
        let got = command_within(&job.server, "bash -s", Some(fetch.as_bytes()), Some(READ_TIMEOUT))?;
        for line in String::from_utf8_lossy(&got).lines() {
            let mut parts = line.splitn(3, ' ');
            let (Some("got"), Some(rel), Some(body)) = (parts.next(), parts.next(), parts.next()) else { continue };
            let (Some(rel), Some(bytes)) = (decode(rel).and_then(|b| String::from_utf8(b).ok()), decode(body)) else { continue };
            let Some((_, sum)) = changed.iter().find(|(r, _)| *r == rel) else { continue };
            let path = job.local.join("folder").join(&rel);
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            if std::fs::write(&path, bytes).is_ok() {
                if let Ok(mut m) = sums().lock() {
                    m.insert(format!("{}\n{rel}", job.local.display()), sum.clone());
                }
            }
        }
    }
    Ok(())
}

/// The checksum of each session file the mirror last copied, by session
/// folder and path.
fn sums() -> &'static Mutex<HashMap<String, String>> {
    static SUMS: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    SUMS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_as_zed_does() {
        let server = Server::parse("ssh -p 2222 aw@mini.home", "mini").unwrap();
        assert_eq!((server.host.as_str(), server.username.as_deref(), server.port), ("mini.home", Some("aw"), Some(2222)));
        assert_eq!(server.key(), "aw@mini.home:2222");
        assert_eq!(server.name(), "mini");
        assert!(Server::parse("ssh -t mini", "").is_err());
        assert_eq!(Server::parse("mini", "").unwrap().key(), "mini");
    }
}
