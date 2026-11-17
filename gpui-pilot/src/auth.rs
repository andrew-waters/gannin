//! Signing in with GitHub, as Gannin does (`AuthStore`, `DeviceFlow`): the
//! OAuth device flow on Gannin's OAuth app, then the viewer's login, name
//! and avatar from GraphQL.
//!
//! The token is the pilot's own, in a keychain item of its own, so signing
//! out here never signs Gannin out. The keychain is reached through the
//! system's `security` tool, with the token on its standard input rather
//! than its command line: an unsigned binary that changes every build
//! would otherwise be asked to allow access after each one.
//!
//! These are the pilot's only calls to GitHub besides avatars, and they're
//! reads: the device flow, and `viewer { login name avatarUrl }`.

use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

/// Gannin's GitHub OAuth app (`GitHubOAuthConfig`).
const CLIENT_ID: &str = "Ov23lict75KEMvZoPley";
const SCOPES: &str = "read:user read:org repo project";
const SERVICE: &str = "dev.andon.gannin.gpui-pilot.github";
const ACCOUNT: &str = "access_token";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Viewer {
    pub login: String,
    pub name: Option<String>,
    pub avatar_url: Option<String>,
}

#[derive(Clone, Debug)]
pub struct DeviceCode {
    device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    expires_in: u64,
    interval: u64,
}

fn viewer_path() -> PathBuf {
    crate::paths::app_dir().join("viewer.json")
}

// MARK: - Keychain

fn security(args: &[&str], stdin: Option<&str>) -> Option<String> {
    let mut child = Command::new("/usr/bin/security")
        .args(args)
        .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    if let (Some(input), Some(mut pipe)) = (stdin, child.stdin.take()) {
        pipe.write_all(input.as_bytes()).ok()?;
    }
    let output = child.wait_with_output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
}

pub fn token() -> Option<String> {
    security(&["find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w"], None).filter(|t| !t.is_empty())
}

fn set_token(token: &str) -> Result<(), String> {
    // GitHub's tokens are letters, digits and underscores: nothing to quote.
    if !token.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Err("GitHub sent a token in an unexpected form".into());
    }
    let command = format!("add-generic-password -U -s {SERVICE} -a {ACCOUNT} -w {token}\n");
    security(&["-i"], Some(&command)).map(|_| ()).ok_or_else(|| "Couldn't save the token in the keychain".into())
}

// MARK: - The signed-in viewer

/// Who was signed in last, while the keychain still has the token.
pub fn saved_viewer() -> Option<Viewer> {
    let viewer = std::fs::read(viewer_path()).ok().and_then(|b| serde_json::from_slice(&b).ok())?;
    token().map(|_| viewer)
}

fn save_viewer(viewer: &Viewer) {
    let path = viewer_path();
    if let Some(folder) = path.parent() {
        let _ = std::fs::create_dir_all(folder);
    }
    if let Ok(json) = serde_json::to_vec_pretty(viewer) {
        let _ = std::fs::write(path, json);
    }
}

pub fn sign_out() {
    let _ = security(&["delete-generic-password", "-s", SERVICE, "-a", ACCOUNT], None);
    let _ = std::fs::remove_file(viewer_path());
}

// MARK: - GitHub

/// A POST with curl; the token, when there is one, goes in a config read
/// from standard input so it never shows in the process list.
fn post(url: &str, form: &[(&str, &str)], token: Option<&str>, json: Option<&str>) -> Result<serde_json::Value, String> {
    let mut config = String::new();
    if let Some(token) = token {
        config.push_str(&format!("header = \"Authorization: bearer {token}\"\n"));
    }
    if let Some(json) = json {
        config.push_str("header = \"Content-Type: application/json\"\n");
        config.push_str(&format!("data = \"{}\"\n", json.replace('\\', "\\\\").replace('"', "\\\"")));
    }
    let mut command = Command::new("/usr/bin/curl");
    command.args(["-sS", "--max-time", "20", "-X", "POST", "-H", "Accept: application/json", "-K", "-"]);
    for (key, value) in form {
        command.arg("--data-urlencode").arg(format!("{key}={value}"));
    }
    command.arg(url).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|e| format!("Couldn't run curl: {e}"))?;
    if let Some(mut pipe) = child.stdin.take() {
        pipe.write_all(config.as_bytes()).map_err(|e| e.to_string())?;
    }
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!("Network error: {}", String::from_utf8_lossy(&output.stderr).trim()));
    }
    serde_json::from_slice(&output.stdout).map_err(|_| "Couldn't read GitHub's answer".to_string())
}

pub fn request_code() -> Result<DeviceCode, String> {
    let json = post("https://github.com/login/device/code", &[("client_id", CLIENT_ID), ("scope", SCOPES)], None, None)?;
    let field = |key: &str| json.get(key).and_then(|v| v.as_str()).map(str::to_string);
    let number = |key: &str| json.get(key).and_then(|v| v.as_u64());
    match (field("device_code"), field("user_code"), field("verification_uri"), number("expires_in"), number("interval")) {
        (Some(device_code), Some(user_code), Some(verification_uri), Some(expires_in), Some(interval)) => {
            Ok(DeviceCode { device_code, user_code, verification_uri, expires_in, interval })
        }
        _ => Err(field("error_description").unwrap_or_else(|| "GitHub's answer was missing the code".into())),
    }
}

/// What one poll for the token found.
pub enum Poll {
    Token(String),
    /// Ask again after this long.
    Wait(Duration),
    Failed(String),
}

pub fn poll(code: &DeviceCode, interval: Duration) -> Poll {
    let json = match post(
        "https://github.com/login/oauth/access_token",
        &[
            ("client_id", CLIENT_ID),
            ("device_code", &code.device_code),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
        ],
        None,
        None,
    ) {
        Ok(json) => json,
        // A dropped connection isn't the end of the sign-in: ask again.
        Err(_) => return Poll::Wait(interval),
    };
    if let Some(token) = json.get("access_token").and_then(|v| v.as_str()) {
        return Poll::Token(token.to_string());
    }
    match json.get("error").and_then(|v| v.as_str()) {
        Some("authorization_pending") => Poll::Wait(interval),
        Some("slow_down") => {
            let asked = json.get("interval").and_then(|v| v.as_u64()).unwrap_or(0);
            Poll::Wait(Duration::from_secs((interval.as_secs() + 5).max(asked)))
        }
        Some("expired_token") => Poll::Failed("The code expired before you authorised. Try again.".into()),
        Some("access_denied") => Poll::Failed("Authorisation was denied.".into()),
        _ => Poll::Failed(
            json.get("error_description").and_then(|v| v.as_str()).unwrap_or("GitHub refused the sign-in").to_string(),
        ),
    }
}

impl DeviceCode {
    pub fn interval(&self) -> Duration {
        Duration::from_secs(self.interval.max(1))
    }

    pub fn expires_in(&self) -> Duration {
        Duration::from_secs(self.expires_in)
    }
}

/// Why the viewer couldn't be read.
pub enum ViewerError {
    /// GitHub rejected the token: it was revoked or expired.
    Unauthorised,
    Other(String),
}

pub fn fetch_viewer(token: &str) -> Result<Viewer, ViewerError> {
    let json = post(
        "https://api.github.com/graphql",
        &[],
        Some(token),
        Some(r#"{"query":"query { viewer { login name avatarUrl } }"}"#),
    )
    .map_err(ViewerError::Other)?;
    if json.get("message").and_then(|m| m.as_str()).is_some_and(|m| m.contains("Bad credentials")) {
        return Err(ViewerError::Unauthorised);
    }
    json.get("data")
        .and_then(|d| d.get("viewer"))
        .and_then(|v| serde_json::from_value(v.clone()).ok())
        .ok_or_else(|| ViewerError::Other("GitHub's answer had no viewer".into()))
}

/// Saves the token and who it belongs to, once GitHub has said who.
pub fn complete(token: &str) -> Result<Viewer, String> {
    let viewer = fetch_viewer(token).map_err(|e| match e {
        ViewerError::Unauthorised => "GitHub rejected the new token".to_string(),
        ViewerError::Other(message) => message,
    })?;
    set_token(token)?;
    save_viewer(&viewer);
    Ok(viewer)
}

/// Refreshes the saved profile; signs out when GitHub rejects the token.
/// Other failures keep the saved session, so offline launches still work.
pub fn validate() -> Option<Option<Viewer>> {
    let token = token()?;
    match fetch_viewer(&token) {
        Ok(viewer) => {
            save_viewer(&viewer);
            Some(Some(viewer))
        }
        Err(ViewerError::Unauthorised) => {
            sign_out();
            Some(None)
        }
        Err(ViewerError::Other(_)) => None,
    }
}
