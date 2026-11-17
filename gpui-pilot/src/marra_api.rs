//! Marra's HTTP API, for a phone on the local network (docs/marra.md, "The
//! API and a phone"; the endpoints are in docs/marra-api.md).
//!
//! - Off until switched on in Marra's menu, and only while on: the
//!   listener is dropped when it goes off.
//! - The local network only: a connection from anything but a private,
//!   link-local or loopback address is refused before it's read.
//! - Each device pairs once with a six-digit code shown in Marra's menu
//!   (good for ten minutes, once) and gets a token of its own. Only the
//!   tokens' SHA-256 is kept (`devices.json`, 0600); revoking forgets them.
//! - Never through it: the GitHub token, claude's login, a raw terminal.
//!
//! As the MCP server does, the server threads only parse: each request goes
//! to the app's main thread (`ApiCall`) and the reply comes back on a
//! channel. `GET /v1/events` is a Server-Sent Events stream that says
//! `changed` whenever Marra's state moves on.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::net::{IpAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const PORT: u16 = 47870;
const CODE_LIFE: Duration = Duration::from_secs(10 * 60);

/// A request for the main thread: the method, the path after `/v1` and
/// the body (from a paired device).
pub struct ApiCall {
    pub method: String,
    pub path: String,
    pub body: Value,
    pub reply: Sender<(u16, Value)>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub paired: String,
    /// SHA-256 of its token, hex.
    hash: String,
}

fn devices_file() -> std::path::PathBuf {
    crate::marra::dir().join("devices.json")
}

pub fn devices() -> Vec<Device> {
    std::fs::read(devices_file()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn save_devices(list: &[Device]) {
    let _ = std::fs::create_dir_all(crate::marra::dir());
    if let Ok(bytes) = serde_json::to_vec_pretty(list) {
        let path = devices_file();
        if std::fs::write(&path, bytes).is_ok() {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
            }
        }
    }
}

pub fn revoke_all() {
    save_devices(&[]);
}

fn hash(token: &str) -> String {
    Sha256::digest(token.as_bytes()).iter().map(|b| format!("{b:02x}")).collect()
}

/// The private ranges a home or office network uses, and this Mac.
fn local(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_private() || v4.is_loopback() || v4.is_link_local(),
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return v4.is_private() || v4.is_loopback() || v4.is_link_local();
            }
            let first = v6.segments()[0];
            v6.is_loopback() || (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80
        }
    }
}

/// The running server, while phone access is on.
pub struct Api {
    on: Arc<AtomicBool>,
    pub version: Arc<AtomicU64>,
    pairing: Arc<Mutex<Option<(String, Instant)>>>,
    pub calls: Receiver<ApiCall>,
}

impl Api {
    /// Starts listening on every interface (refusing anything not local).
    pub fn start() -> Result<Self, String> {
        let listener = TcpListener::bind(("0.0.0.0", PORT)).map_err(|e| format!("Couldn't listen on port {PORT}: {e}"))?;
        listener.set_nonblocking(true).map_err(|e| e.to_string())?;
        let on = Arc::new(AtomicBool::new(true));
        let version = Arc::new(AtomicU64::new(1));
        let pairing = Arc::new(Mutex::new(None));
        let (tx, rx) = channel();
        let (flag, ver, pair) = (on.clone(), version.clone(), pairing.clone());
        std::thread::spawn(move || {
            while flag.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((stream, peer)) => {
                        if !local(peer.ip()) {
                            continue;
                        }
                        let _ = stream.set_nonblocking(false);
                        let (tx, flag, ver, pair) = (tx.clone(), flag.clone(), ver.clone(), pair.clone());
                        std::thread::spawn(move || {
                            let _ = handle(stream, &tx, &flag, &ver, &pair);
                        });
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(200)),
                    Err(_) => std::thread::sleep(Duration::from_millis(500)),
                }
            }
            // Dropping the listener here stops listening.
        });
        Ok(Self { on, version, pairing, calls: rx })
    }

    /// A fresh pairing code, good for ten minutes and one device.
    pub fn new_code(&self) -> String {
        let n = u128::from_le_bytes(*uuid::Uuid::new_v4().as_bytes()) % 1_000_000;
        let code = format!("{n:06}");
        if let Ok(mut p) = self.pairing.lock() {
            *p = Some((code.clone(), Instant::now()));
        }
        code
    }

    pub fn code(&self) -> Option<String> {
        self.pairing.lock().ok().and_then(|p| p.clone()).filter(|(_, at)| at.elapsed() < CODE_LIFE).map(|(c, _)| c)
    }

    pub fn changed(&self) {
        self.version.fetch_add(1, Ordering::Relaxed);
    }
}

impl Drop for Api {
    fn drop(&mut self) {
        self.on.store(false, Ordering::Relaxed);
    }
}

/// This Mac's address on the local network, for the menu.
pub fn address() -> Option<String> {
    for interface in ["en0", "en1"] {
        let out = std::process::Command::new("/usr/sbin/ipconfig").args(["getifaddr", interface]).output().ok()?;
        let ip = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !ip.is_empty() {
            return Some(format!("{ip}:{PORT}"));
        }
    }
    None
}

fn handle(mut stream: TcpStream, calls: &Sender<ApiCall>, on: &AtomicBool, version: &AtomicU64, pairing: &Mutex<Option<(String, Instant)>>) -> std::io::Result<()> {
    use crate::marra_mcp::respond;
    let request = crate::marra_mcp::read_request(&stream)?;
    let reply = |stream: &mut TcpStream, status: u16, body: Value| respond(stream, status, "application/json", &body.to_string());
    let Some(path) = request.path.strip_prefix("/v1") else { return reply(&mut stream, 404, json!({ "error": "Not found" })) };
    let path = path.split('?').next().unwrap_or_default().to_string();
    // Pairing is the one call without a token.
    if request.method == "POST" && path == "/pair" {
        let body: Value = serde_json::from_slice(&request.body).unwrap_or_default();
        let offered = body["code"].as_str().unwrap_or_default();
        let valid = pairing.lock().ok().is_some_and(|mut p| match p.as_ref() {
            Some((code, at)) if code == offered && at.elapsed() < CODE_LIFE => {
                *p = None;
                true
            }
            _ => false,
        });
        if !valid {
            return reply(&mut stream, 403, json!({ "error": "That code isn't right or has expired. Make a new one in Marra's menu." }));
        }
        let token = format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple());
        let id = uuid::Uuid::new_v4().simple().to_string()[..8].to_string();
        let name = body["name"].as_str().unwrap_or("A device").chars().take(60).collect::<String>();
        let mut list = devices();
        list.push(Device { id: id.clone(), name, paired: crate::marra::now(), hash: hash(&token) });
        save_devices(&list);
        return reply(&mut stream, 200, json!({ "device": id, "token": token }));
    }
    let token = request.headers.get("authorization").and_then(|a| a.strip_prefix("Bearer ")).unwrap_or_default().to_string();
    let hashed = hash(&token);
    if !devices().into_iter().any(|d| !token.is_empty() && d.hash == hashed) {
        return reply(&mut stream, 401, json!({ "error": "Pair this device first." }));
    }
    if request.method == "GET" && path == "/events" {
        return events(stream, on, version);
    }
    let body: Value = if request.body.is_empty() { Value::Null } else { serde_json::from_slice(&request.body).unwrap_or(Value::Null) };
    let (tx, rx) = channel();
    if calls.send(ApiCall { method: request.method, path, body, reply: tx }).is_err() {
        return reply(&mut stream, 503, json!({ "error": "Gannin isn't listening." }));
    }
    match rx.recv_timeout(Duration::from_secs(30)) {
        Ok((status, body)) => reply(&mut stream, status, body),
        Err(_) => reply(&mut stream, 503, json!({ "error": "Gannin didn't answer in time." })),
    }
}

/// Server-Sent Events: `changed` with a version whenever Marra moves on,
/// and a comment every 20 seconds to keep the connection open.
fn events(mut stream: TcpStream, on: &AtomicBool, version: &AtomicU64) -> std::io::Result<()> {
    use std::io::Write;
    write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n")?;
    let mut last = 0;
    let mut quiet = Instant::now();
    while on.load(Ordering::Relaxed) {
        let now = version.load(Ordering::Relaxed);
        if now != last {
            last = now;
            write!(stream, "event: changed\ndata: {{\"version\": {now}}}\n\n")?;
            stream.flush()?;
            quiet = Instant::now();
        } else if quiet.elapsed() > Duration::from_secs(20) {
            write!(stream, ": still here\n\n")?;
            stream.flush()?;
            quiet = Instant::now();
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_local_addresses() {
        assert!(local("192.168.1.20".parse().unwrap()));
        assert!(local("10.0.0.5".parse().unwrap()));
        assert!(local("127.0.0.1".parse().unwrap()));
        assert!(local("fe80::1".parse().unwrap()));
        assert!(local("::ffff:192.168.1.2".parse().unwrap()));
        assert!(!local("8.8.8.8".parse().unwrap()));
        assert!(!local("2a00:1450::1".parse().unwrap()));
        assert!(!local("100.64.0.1".parse().unwrap()));
    }
}
