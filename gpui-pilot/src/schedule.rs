//! The scheduler (docs/scheduler.md): what claude does unattended, kept on
//! this Mac only (`schedule.json` in the app's folder), and run only while
//! the app is open. Four kinds of thing:
//!
//! - Review windows: spans of the week when reviews of pull requests asked
//!   of you start by themselves, and post by themselves.
//! - Issue starts: Work on This on an issue at a set time.
//! - Sequences: issues one after another, each to completion (its PR open,
//!   checks passing, bots' comments dealt with) before the next.
//! - Recurring prompts: an Ask at a time on given weekdays.
//!
//! Times missed while the app was closed aren't caught up: they're marked
//! missed. Unattended pull requests keep at least the gap apart: a hook
//! holds `gh pr create` until the gap since the last has passed, and the
//! app tells the session when to go ahead.

use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, NaiveTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// How late a start can be and still run, else it's missed.
pub const GRACE_MINUTES: i64 = 10;

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct IssueRef {
    pub id: String,
    pub repo: String,
    pub number: i64,
    pub title: String,
    pub url: String,
}

impl IssueRef {
    pub fn label(&self) -> String {
        format!("#{} {}", self.number, self.title)
    }
}

/// Where a scheduled run is: waiting, started (its session's launch id),
/// done, failed or missed.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(tag = "state", rename_all = "lowercase")]
pub enum RunState {
    #[default]
    Waiting,
    Started { launch: String, at: DateTime<Utc> },
    Done { launch: String, at: DateTime<Utc> },
    Failed { reason: String, at: DateTime<Utc> },
    Missed { at: DateTime<Utc> },
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct ReviewWindow {
    pub id: String,
    pub name: String,
    /// 0 is Monday.
    pub weekdays: Vec<u32>,
    /// Minutes after midnight, local.
    pub start: u32,
    pub length: u32,
    #[serde(default)]
    pub paused: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct IssueStart {
    pub id: String,
    pub issue: IssueRef,
    pub at: DateTime<Utc>,
    #[serde(default)]
    pub paused: bool,
    #[serde(default)]
    pub run: RunState,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Sequence {
    pub id: String,
    pub name: String,
    pub start: DateTime<Utc>,
    pub items: Vec<IssueRef>,
    /// Each item's run, in step with `items`.
    #[serde(default)]
    pub runs: Vec<RunState>,
    #[serde(default)]
    pub paused: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Prompt {
    pub id: String,
    pub name: String,
    pub text: String,
    pub weekdays: Vec<u32>,
    pub start: u32,
    #[serde(default)]
    pub paused: bool,
    /// The day it last ran (or was missed), so it's once a day.
    #[serde(default)]
    pub last: Option<NaiveDate>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Settings {
    /// Minutes between unattended pull requests.
    pub gap_minutes: u32,
    pub paused_all: bool,
    /// A review window's reviews approve by themselves; otherwise an
    /// approve verdict posts as a comment.
    pub approve_by_itself: bool,
    /// At most this many window reviews at once.
    pub reviews_at_once: usize,
}

impl Default for Settings {
    fn default() -> Self {
        Self { gap_minutes: 30, paused_all: false, approve_by_itself: false, reviews_at_once: 2 }
    }
}

/// What ran, for the page's past blocks.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Ran {
    pub item: String,
    pub title: String,
    pub at: DateTime<Utc>,
    /// started, missed, failed, posted
    pub outcome: String,
    #[serde(default)]
    pub note: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Schedule {
    #[serde(default)]
    pub settings: Settings,
    #[serde(default)]
    pub windows: Vec<ReviewWindow>,
    #[serde(default)]
    pub starts: Vec<IssueStart>,
    #[serde(default)]
    pub sequences: Vec<Sequence>,
    #[serde(default)]
    pub prompts: Vec<Prompt>,
    #[serde(default)]
    pub ran: Vec<Ran>,
    /// When the last unattended pull request was let through.
    #[serde(default)]
    pub last_pr: Option<DateTime<Utc>>,
}

pub fn folder() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default().join("Library/Application Support/GanninGPUIPilot")
}

fn path() -> PathBuf {
    folder().join("schedule.json")
}

/// Where unattended sessions ask to open a pull request, and are let.
pub fn gap_dir() -> PathBuf {
    folder().join("pr-gap")
}

impl Schedule {
    pub fn load() -> Self {
        std::fs::read(path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save(&self) {
        let path = path();
        let _ = std::fs::create_dir_all(folder());
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, serde_json::to_vec_pretty(self).unwrap_or_default()).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }

    pub fn note(&mut self, item: &str, title: &str, outcome: &str, note: &str) {
        self.ran.push(Ran { item: item.into(), title: title.into(), at: Utc::now(), outcome: outcome.into(), note: note.into() });
        let keep = self.ran.len().saturating_sub(500);
        self.ran.drain(..keep);
    }

    /// The review window open now, if any.
    pub fn window_now(&self, now: DateTime<Local>) -> Option<&ReviewWindow> {
        let day = now.weekday().num_days_from_monday();
        let minute = now.time().signed_duration_since(NaiveTime::MIN).num_minutes() as u32;
        self.windows.iter().find(|w| !w.paused && w.weekdays.contains(&day) && w.start <= minute && minute < w.start + w.length)
    }
}

/// A local date and minute as an instant.
pub fn at(date: NaiveDate, minute: u32) -> DateTime<Utc> {
    let time = NaiveTime::from_hms_opt(minute / 60, minute % 60, 0).unwrap_or(NaiveTime::MIN);
    Local.from_local_datetime(&date.and_time(time)).earliest().map(|t| t.with_timezone(&Utc)).unwrap_or_else(Utc::now)
}

/// Whether a time that's come should run now, or was missed.
pub fn due(when: DateTime<Utc>, now: DateTime<Utc>) -> Option<bool> {
    if when > now {
        None
    } else {
        Some(now - when <= Duration::minutes(GRACE_MINUTES))
    }
}

pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_lowercase()
}

/// The PreToolUse hook that spaces unattended pull requests: `gh pr create`
/// waits until the gap since the last has passed (or the app has let this
/// session go), and asks to be told when.
pub fn gap_hook(launch_id: &str, gap_minutes: u32) -> String {
    let dir = gap_dir().to_string_lossy().replace('\'', "'\\''");
    format!(
        r#"input=$(cat); dir='{dir}'; id='{launch_id}'; gap={gap}
printf %s "$input" | grep -Eq '"tool_name": ?"Bash"' || exit 0
printf %s "$input" | grep -Eq '"command": ?"[^"]*gh pr create' || exit 0
mkdir -p "$dir/requests" "$dir/allow"
now=$(date +%s); last=$(cat "$dir/last" 2>/dev/null || echo 0)
if [ -e "$dir/allow/$id" ] || [ $((now - last)) -ge $((gap * 60)) ]; then
  rm -f "$dir/allow/$id" "$dir/requests/$id"; printf %s "$now" > "$dir/last"; exit 0
fi
printf %s "$now" > "$dir/requests/$id"
printf '{{"hookSpecificOutput":{{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Gannin spaces unattended pull requests %s minutes apart, and another opened recently. Wait without opening this one: Gannin will tell you here when to go ahead."}}}}' "$gap"
exit 0"#,
        gap = gap_minutes
    )
}

/// What an unattended session is told, ahead of its brief.
pub const UNATTENDED: &str = "\n## Nobody is watching\n\nThis session was started by Gannin's schedule, and nobody is watching it. Don't stop to ask questions: make the choice a careful teammate would, and say what you chose and why in the pull request's description. Take the work as far as a pull request that's ready for review; never merge it.\n";

/// An issue's open sub-issues, in the order set on GitHub (the local
/// cache knows only each one's parent). Read only.
pub fn sub_issues_in_order(token: &str, issue_id: &str) -> Result<Vec<IssueRef>, String> {
    let data = crate::github::graphql(
        token,
        "query($id: ID!) { node(id: $id) { ... on Issue { subIssues(first: 100) { nodes { id number title url state repository { nameWithOwner } } } } } }",
        serde_json::json!({ "id": issue_id }),
    )
    .map_err(|e| e.to_string())?;
    Ok(data["node"]["subIssues"]["nodes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|n| n["state"] == "OPEN")
        .filter_map(|n| {
            Some(IssueRef {
                id: n["id"].as_str()?.into(),
                repo: n["repository"]["nameWithOwner"].as_str()?.into(),
                number: n["number"].as_i64()?,
                title: n["title"].as_str().unwrap_or("").into(),
                url: n["url"].as_str().unwrap_or("").into(),
            })
        })
        .collect())
}
