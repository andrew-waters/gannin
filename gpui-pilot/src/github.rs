//! GitHub's GraphQL API, with Gannin's guards (`GitHubAPI`, `RateLimit`):
//! every query asks for the rate limit, a refusal pauses every request
//! until GitHub's reset, and automatic syncs hold off when the budget runs
//! low. Requests go through the system's curl, with the token in a config
//! on standard input so it never shows in the process list.
//!
//! Mostly reads. `mutate` sends a write; its only callers are the New
//! Issue form's Create on GitHub, after the form has shown what will be sent.

use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Value};
use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::Mutex;

#[derive(Clone, Copy, Debug)]
pub struct RateLimit {
    pub remaining: i64,
    pub limit: i64,
    pub reset_at: DateTime<Utc>,
}

impl RateLimit {
    /// Under the reserve (500, or half the limit), before the reset.
    pub fn is_low(&self) -> bool {
        self.remaining < reserve().min(self.limit / 2) && self.reset_at > Utc::now()
    }
}

/// Points kept for what's done by hand (Settings: Keep in reserve).
static RESERVE: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(500);

pub fn reserve() -> i64 {
    RESERVE.load(std::sync::atomic::Ordering::Relaxed)
}

pub fn set_reserve(points: i64) {
    RESERVE.store(points, std::sync::atomic::Ordering::Relaxed);
}

struct Budget {
    rate: Option<RateLimit>,
    paused_until: Option<DateTime<Utc>>,
}

static BUDGET: Mutex<Budget> = Mutex::new(Budget { rate: None, paused_until: None });

pub fn rate_limit() -> Option<RateLimit> {
    BUDGET.lock().ok().and_then(|b| b.rate)
}

pub fn paused_until() -> Option<DateTime<Utc>> {
    BUDGET.lock().ok().and_then(|b| b.paused_until).filter(|until| *until > Utc::now())
}

/// Automatic syncs wait: refused, or under the reserve.
pub fn should_hold_off() -> bool {
    paused_until().is_some() || rate_limit().is_some_and(|r| r.is_low())
}

fn pause(until: DateTime<Utc>) {
    if let Ok(mut budget) = BUDGET.lock() {
        budget.paused_until = Some(until);
    }
}

#[derive(Debug)]
pub enum Error {
    /// GitHub refused for its rate limit; nothing is asked until then.
    Paused(DateTime<Utc>),
    /// The token was rejected.
    Unauthorised,
    Other(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Paused(until) => write!(f, "GitHub's rate limit is spent until {}", until.with_timezone(&chrono::Local).format("%H:%M")),
            Error::Unauthorised => write!(f, "GitHub rejected the sign-in"),
            Error::Other(message) => write!(f, "{message}"),
        }
    }
}

/// Puts ` rateLimit { ... } ` just inside the query's first brace.
fn asking_for_rate_limit(query: &str) -> String {
    if query.trim_start().starts_with("mutation") {
        return query.to_string();
    }
    match query.find('{') {
        Some(at) => format!("{} rateLimit {{ cost remaining limit resetAt }} {}", &query[..=at], &query[at + 1..]),
        None => query.to_string(),
    }
}

/// One POST; returns the status, headers (lowercased names) and body.
fn post(token: &str, body: &str) -> Result<(u16, Vec<(String, String)>, String), Error> {
    let escape = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
    let config = format!(
        "header = \"Authorization: Bearer {token}\"\nheader = \"Content-Type: application/json\"\nheader = \"User-Agent: gannin-gpui-pilot\"\ndata = \"{}\"\n",
        escape(body)
    );
    let mut child = Command::new("/usr/bin/curl")
        .args(["-sS", "--max-time", "60", "-X", "POST", "-D", "-", "-w", "\n%{http_code}", "-K", "-", "https://api.github.com/graphql"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| Error::Other(format!("Couldn't run curl: {e}")))?;
    if let Some(mut pipe) = child.stdin.take() {
        pipe.write_all(config.as_bytes()).map_err(|e| Error::Other(e.to_string()))?;
    }
    let output = child.wait_with_output().map_err(|e| Error::Other(e.to_string()))?;
    if !output.status.success() {
        return Err(Error::Other(format!("Network error: {}", String::from_utf8_lossy(&output.stderr).trim())));
    }
    let text = String::from_utf8_lossy(&output.stdout).into_owned();
    let (rest, code) = text.rsplit_once('\n').ok_or_else(|| Error::Other("No answer from GitHub".into()))?;
    let status: u16 = code.trim().parse().unwrap_or(0);
    // Headers end at the last blank line before the body (a 100 Continue
    // would add a block of its own before).
    let split = rest.rfind("\r\n\r\n").map(|i| (i, 4)).or_else(|| rest.rfind("\n\n").map(|i| (i, 2)));
    let (head, body) = match split {
        Some((at, len)) => (&rest[..at], &rest[at + len..]),
        None => ("", rest),
    };
    let headers = head
        .lines()
        .filter_map(|line| line.split_once(':').map(|(k, v)| (k.trim().to_lowercase(), v.trim().to_string())))
        .collect();
    Ok((status, headers, body.to_string()))
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers.iter().rev().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
}

/// Runs a query with variables and returns its `data`. Partial data with
/// errors is accepted, as Gannin does; a 502-504 is tried twice more.
pub fn graphql(token: &str, query: &str, variables: Value) -> Result<Value, Error> {
    let (data, errors) = request(token, query, variables)?;
    match data {
        Some(data) => Ok(data),
        None => Err(Error::Other(errors.first().and_then(|e| e["message"].as_str()).unwrap_or("GitHub sent no data").to_string())),
    }
}

/// A write. GitHub answers a refused mutation (no write access, a repo
/// gone read-only) with its payload null beside an error, so a null
/// `payload` is a failure with GitHub's message, never a quiet success.
pub fn mutate(token: &str, query: &str, variables: Value, payload: &str) -> Result<Value, Error> {
    let (data, errors) = request(token, query, variables)?;
    let message = || errors.first().and_then(|e| e["message"].as_str()).unwrap_or("GitHub didn't take it").to_string();
    match data.as_ref().map(|d| &d[payload]) {
        Some(value) if !value.is_null() => Ok(value.clone()),
        _ => Err(Error::Other(message())),
    }
}

/// Sends a query or mutation; its `data` (when there is any) and errors.
fn request(token: &str, query: &str, variables: Value) -> Result<(Option<Value>, Vec<Value>), Error> {
    if let Some(until) = paused_until() {
        return Err(Error::Paused(until));
    }
    let body = json!({ "query": asking_for_rate_limit(query), "variables": variables }).to_string();
    let mut attempt = 0;
    let (status, headers, text) = loop {
        let answer = post(token, &body)?;
        if (502..=504).contains(&answer.0) && attempt < 2 {
            attempt += 1;
            std::thread::sleep(std::time::Duration::from_secs(2 * attempt));
            continue;
        }
        break answer;
    };
    if status == 401 {
        return Err(Error::Unauthorised);
    }
    if status == 403 || status == 429 {
        let until = if let Some(after) = header(&headers, "retry-after").and_then(|v| v.parse::<i64>().ok()) {
            Some(Utc::now() + Duration::seconds(after.max(1)))
        } else if header(&headers, "x-ratelimit-remaining") == Some("0") {
            header(&headers, "x-ratelimit-reset").and_then(|v| v.parse::<i64>().ok()).and_then(|t| DateTime::from_timestamp(t, 0))
        } else if text.to_lowercase().contains("rate limit") {
            Some(Utc::now() + Duration::seconds(60))
        } else {
            None
        };
        if let Some(until) = until {
            pause(until);
            return Err(Error::Paused(until));
        }
        return Err(Error::Other(format!("GitHub refused the request ({status})")));
    }
    let json: Value = serde_json::from_str(&text).map_err(|_| Error::Other(format!("GitHub sent something unreadable ({status})")))?;
    let rate = json["data"]["rateLimit"].as_object().map(|r| RateLimit {
        remaining: r.get("remaining").and_then(Value::as_i64).unwrap_or(5000),
        limit: r.get("limit").and_then(Value::as_i64).unwrap_or(5000),
        reset_at: r.get("resetAt").and_then(Value::as_str).and_then(|s| s.parse().ok()).unwrap_or_else(Utc::now),
    });
    if let Some(rate) = rate {
        if let Ok(mut budget) = BUDGET.lock() {
            budget.rate = Some(rate);
        }
    }
    let errors = json["errors"].as_array().cloned().unwrap_or_default();
    if errors.iter().any(|e| e["type"] == "RATE_LIMITED") {
        let until = header(&headers, "x-ratelimit-reset")
            .and_then(|v| v.parse::<i64>().ok())
            .and_then(|t| DateTime::from_timestamp(t, 0))
            .or(rate.map(|r| r.reset_at))
            .unwrap_or_else(|| Utc::now() + Duration::seconds(60));
        pause(until);
        return Err(Error::Paused(until));
    }
    Ok((json.get("data").filter(|d| !d.is_null()).cloned(), errors))
}

/// A search's nodes, page by page, up to GitHub's 1000; also whether
/// GitHub had more than that (`issueCount > 1000`).
/// Tells `on_page` after each page how many it has and how many there are
/// (capped at 1000), for a progress bar.
pub fn search_reporting(token: &str, query: &str, page_size: usize, fields: &str, on_page: &dyn Fn(usize, usize)) -> Result<(Vec<Value>, bool), Error> {
    let text = format!(
        "query($q: String!, $cursor: String) {{ search(query: $q, type: ISSUE, first: {page_size}, after: $cursor) {{ issueCount pageInfo {{ hasNextPage endCursor }} nodes {{ {fields} }} }} }}"
    );
    let mut nodes = Vec::new();
    let mut cursor: Option<String> = None;
    let mut truncated;
    loop {
        let data = graphql(token, &text, json!({ "q": query, "cursor": cursor }))?;
        let search = &data["search"];
        truncated = search["issueCount"].as_i64().unwrap_or(0) > 1000;
        nodes.extend(search["nodes"].as_array().cloned().unwrap_or_default().into_iter().filter(|n| n.get("id").is_some()));
        let total = (search["issueCount"].as_i64().unwrap_or(0).max(0) as usize).min(1000);
        on_page(nodes.len().min(total.max(nodes.len())), total.max(nodes.len()));
        let more = search["pageInfo"]["hasNextPage"].as_bool().unwrap_or(false);
        cursor = search["pageInfo"]["endCursor"].as_str().map(str::to_string);
        if !more || cursor.is_none() || nodes.len() >= 1000 {
            break;
        }
    }
    Ok((nodes, truncated))
}
