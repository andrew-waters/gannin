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
    /// Whether its reviews approve by themselves, and when.
    #[serde(default)]
    pub approve: crate::approve::ApproveRules,
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
    /// Minutes from one item's start to the next's, at the least: the
    /// next starts once the one before is done and this long has passed.
    #[serde(default = "default_interval")]
    pub interval: u32,
}

fn default_interval() -> u32 {
    120
}

impl Sequence {
    /// When each item starts, or is planned to: as it ran, else an interval
    /// after the one before.
    pub fn planned(&self) -> Vec<DateTime<Utc>> {
        let mut out = Vec::with_capacity(self.items.len());
        let mut at = self.start;
        for i in 0..self.items.len() {
            if let Some(RunState::Started { at: ran, .. } | RunState::Done { at: ran, .. }) = self.runs.get(i) {
                if i > 0 {
                    at = *ran;
                }
            }
            out.push(at);
            at += Duration::minutes(self.interval.max(5) as i64);
        }
        out
    }
}

/// What's on a day, for the page and for picking a free time: each
/// thing's kind, id, title, start and length (minutes), its run's state,
/// whether it's paused, and its place in a sequence.
#[derive(Clone, Debug)]
pub struct Busy {
    pub kind: &'static str,
    pub id: String,
    pub title: String,
    pub start: u32,
    pub length: u32,
    pub status: &'static str,
    pub paused: bool,
    pub place: Option<(usize, usize)>,
    /// The issue it works on, for its readiness.
    pub issue: Option<String>,
}

pub fn status_of(run: &RunState) -> &'static str {
    match run {
        RunState::Waiting => "",
        RunState::Started { .. } => "running",
        RunState::Done { .. } => "done",
        RunState::Failed { .. } => "failed",
        RunState::Missed { .. } => "missed",
    }
}

fn local(at: DateTime<Utc>) -> (NaiveDate, u32) {
    let l = at.with_timezone(&Local);
    (l.date_naive(), (l.time().signed_duration_since(NaiveTime::MIN).num_minutes()) as u32)
}

impl Schedule {
    pub fn busy(&self, date: NaiveDate) -> Vec<Busy> {
        let today = Local::now().date_naive();
        let weekday = date.weekday().num_days_from_monday();
        let mut out = Vec::new();
        for w in self.windows.iter().filter(|w| w.weekdays.contains(&weekday)) {
            out.push(Busy { kind: "window", id: w.id.clone(), title: w.name.clone(), start: w.start, length: w.length, status: "", paused: w.paused, place: None, issue: None });
        }
        for st in &self.starts {
            let (d, m) = local(st.at);
            if d == date {
                out.push(Busy { kind: "start", id: st.id.clone(), title: st.issue.label(), start: m, length: 90, status: status_of(&st.run), paused: st.paused, place: None, issue: Some(st.issue.id.clone()) });
            }
        }
        for q in &self.sequences {
            let planned = q.planned();
            for (i, (item, at)) in q.items.iter().zip(planned).enumerate() {
                let (d, m) = local(at);
                if d == date {
                    let run = q.runs.get(i).cloned().unwrap_or_default();
                    out.push(Busy { kind: "sequence", id: q.id.clone(), title: item.label(), start: m, length: q.interval.max(15).saturating_sub(5), status: status_of(&run), paused: q.paused, place: Some((i + 1, q.items.len())), issue: Some(item.id.clone()) });
                }
            }
        }
        for p in self.prompts.iter().filter(|p| p.weekdays.contains(&weekday)) {
            let status = if date <= today {
                self.ran.iter().rev().find(|r| r.item == p.id && local(r.at).0 == date).map(|r| match r.outcome.as_str() {
                    "missed" => "missed",
                    "failed" => "failed",
                    _ => "done",
                })
            } else {
                None
            };
            out.push(Busy { kind: "prompt", id: p.id.clone(), title: p.name.clone(), start: p.start, length: 20, status: status.unwrap_or(""), paused: p.paused, place: None, issue: None });
        }
        out.sort_by_key(|b| b.start);
        out
    }
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
    /// The old global switch, now each window's: read so a schedule saved
    /// with it on carries over (see `Schedule::load`), never written.
    #[serde(default, skip_serializing)]
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
    /// Each scheduled issue's scouting, by its id.
    #[serde(default)]
    pub readiness: std::collections::BTreeMap<String, Readiness>,
}

/// A decision a scout found the work needs, its options (the first
/// recommended, when it said), and the answer given.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Decision {
    pub question: String,
    pub options: Vec<(String, String)>,
    #[serde(default)]
    pub recommended: Option<usize>,
    #[serde(default)]
    pub answer: Option<String>,
}

/// What scouting an issue found when it was scheduled, so its run starts
/// with the decisions made: notes for the session, decisions to answer and
/// blockers to clear.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Readiness {
    /// scouting, ready, needs, blocked, failed
    pub state: String,
    #[serde(default)]
    pub notes: String,
    #[serde(default)]
    pub decisions: Vec<Decision>,
    #[serde(default)]
    pub blockers: Vec<String>,
    #[serde(default)]
    pub scouted_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub error: Option<String>,
    /// Submitted from Waiting on you: decided, off the list.
    #[serde(default)]
    pub submitted: bool,
    /// Blockers submitted without clearing, told to the session as known.
    #[serde(default)]
    pub acknowledged: Vec<String>,
}

impl Readiness {
    /// Submit: what's unanswered takes the recommended option (or "your
    /// call"), blockers left become known ones for the session, and it's
    /// ready.
    pub fn submit(&mut self) {
        for d in &mut self.decisions {
            if d.answer.is_none() {
                d.answer = Some(d.recommended.and_then(|r| d.options.get(r)).map(|o| o.0.clone()).unwrap_or_else(|| "Your call".into()));
            }
        }
        self.acknowledged.append(&mut self.blockers);
        self.submitted = true;
        self.state = "ready".into();
    }

    /// Ready once every decision has an answer and nothing blocks it.
    pub fn settle(&mut self) {
        if self.state == "scouting" || self.state == "failed" {
            return;
        }
        self.state = if !self.blockers.is_empty() {
            "blocked".into()
        } else if self.decisions.iter().any(|d| d.answer.is_none()) {
            "needs".into()
        } else {
            "ready".into()
        };
    }

    pub fn is_ready(&self) -> bool {
        self.state == "ready"
    }

    /// What goes in the session's brief: the scout's notes and the
    /// decisions made.
    pub fn brief(&self) -> String {
        let mut out = String::from("\n## Prepared when it was scheduled\n\nThis issue was scouted when it was scheduled, and its decisions were made then. Follow them.\n");
        if !self.notes.trim().is_empty() {
            out.push_str(&format!("\n### Notes\n\n{}\n", self.notes.trim()));
        }
        let made: Vec<String> = self.decisions.iter().filter_map(|d| Some(format!("- {}: {}", d.question, d.answer.as_ref()?))).collect();
        if !made.is_empty() {
            out.push_str(&format!("\n### Decisions made\n\n{}\n", made.join("\n")));
        }
        if !self.acknowledged.is_empty() {
            out.push_str(&format!(
                "\n### Known blockers\n\nThe scout found these and they were accepted as they are: work around them, and say in the pull request how.\n\n{}\n",
                self.acknowledged.iter().map(|b| format!("- {b}")).collect::<Vec<_>>().join("\n")
            ));
        }
        out
    }
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
        let mut s: Self = std::fs::read(path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        s.migrate();
        s
    }

    /// A schedule saved with the old global Approve by itself on: every
    /// window approves, with no conditions, as it did.
    pub(crate) fn migrate(&mut self) {
        if std::mem::take(&mut self.settings.approve_by_itself) {
            for w in &mut self.windows {
                w.approve.enabled = true;
            }
        }
    }

    /// A window's last runs, newest first.
    pub fn ran_for(&self, item: &str, count: usize) -> Vec<&Ran> {
        self.ran.iter().rev().filter(|r| r.item == item).take(count).collect()
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

/// Every scheduled issue still to run, with no scouting yet.
pub fn unscouted(s: &Schedule) -> Vec<IssueRef> {
    let mut out: Vec<IssueRef> = Vec::new();
    let waiting = s.starts.iter().filter(|x| x.run == RunState::Waiting).map(|x| x.issue.clone()).chain(
        s.sequences.iter().flat_map(|q| q.items.iter().enumerate().filter(|(i, _)| q.runs.get(*i).is_none_or(|r| *r == RunState::Waiting)).map(|(_, it)| it.clone())),
    );
    for issue in waiting {
        if !s.readiness.contains_key(&issue.id) && !out.iter().any(|o| o.id == issue.id) {
            out.push(issue);
        }
    }
    out
}

/// Scouts an issue in its harness, read only: notes for the session, the
/// decisions it needs (with options, the recommended one first), and what
/// blocks it. Blocking; a few minutes.
/// The issue's title, text and recent comments, read for the scout (it
/// can't run gh itself under its read-only rules).
fn issue_text(issue: &IssueRef) -> Option<String> {
    let token = crate::auth::token()?;
    let (owner, name) = issue.repo.split_once('/')?;
    let data = crate::github::graphql(
        &token,
        "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { issue(number: $number) { title body comments(last: 30) { nodes { author { login } body } } } } }",
        serde_json::json!({ "owner": owner, "name": name, "number": issue.number }),
    )
    .ok()?;
    let i = &data["repository"]["issue"];
    let comments: Vec<String> = i["comments"]["nodes"].as_array().into_iter().flatten().filter_map(|c| Some(format!("@{}: {}", c["author"]["login"].as_str().unwrap_or("someone"), c["body"].as_str()?.trim()))).collect();
    Some(format!("# {}\n\n{}\n\n## Comments\n\n{}", i["title"].as_str()?, i["body"].as_str().unwrap_or("").trim(), if comments.is_empty() { "None.".into() } else { comments.join("\n\n") }))
}

pub fn scout(harness: &std::path::Path, issue: &IssueRef) -> Readiness {
    let text = issue_text(issue).unwrap_or_else(|| "(Gannin couldn't read it: work from the title and the code.)".into());
    let prompt = format!(
        "Scout {repo}#{n}, \"{title}\" ({url}), ahead of an unattended Claude Code session that will work on it later with nobody watching. Don't change anything. The issue, as it is now:\n\n{text}\n\nRead the code it touches (the code repos are under projects/, or this checkout if it's the repo).\n\nFind what that session would otherwise have to stop and ask: choices the issue leaves open that a person should make (scope, approach, naming, behaviour), each with two to four options, the one you'd recommend first. Leave out choices a careful engineer would just make. Also list blockers: what would stop the work outright (missing access, another issue that must land first, an unclear requirement no option settles).\n\nEnd your reply with one fenced ```json block: {{\"notes\": \"<what the session should know: where the code is, how it fits, risks; Markdown>\", \"decisions\": [{{\"question\": \"<the question>\", \"options\": [{{\"label\": \"<short>\", \"description\": \"<what it means>\"}}], \"recommended\": 0}}], \"blockers\": [\"<what blocks it>\"]}}. Use [] for none.",
        repo = issue.repo,
        n = issue.number,
        title = issue.title,
        url = issue.url,
        text = text
    );
    let now = Utc::now();
    match crate::work_flow::ask_claude(harness, &prompt, None, std::time::Duration::from_secs(15 * 60)) {
        Ok(reply) => {
            let parsed = reply.rfind("```json").and_then(|start| {
                let start = start + "```json".len();
                let end = start + reply[start..].find("```")?;
                serde_json::from_str::<serde_json::Value>(reply[start..end].trim()).ok()
            });
            let Some(v) = parsed else {
                return Readiness { state: "failed".into(), error: Some("The scout gave no findings.".into()), scouted_at: Some(now), ..Default::default() };
            };
            let decisions = v["decisions"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|d| {
                    Some(Decision {
                        question: d["question"].as_str()?.to_string(),
                        options: d["options"].as_array().into_iter().flatten().filter_map(|o| Some((o["label"].as_str()?.to_string(), o["description"].as_str().unwrap_or("").to_string()))).collect(),
                        recommended: d["recommended"].as_u64().map(|r| r as usize),
                        answer: None,
                    })
                })
                .collect();
            let mut r = Readiness {
                state: String::new(),
                notes: v["notes"].as_str().unwrap_or("").to_string(),
                decisions,
                blockers: v["blockers"].as_array().into_iter().flatten().filter_map(|b| b.as_str().map(str::to_string)).collect(),
                scouted_at: Some(now),
                error: None,
                ..Default::default()
            };
            r.settle();
            r
        }
        Err(e) => Readiness { state: "failed".into(), error: Some(e), scouted_at: Some(now), ..Default::default() },
    }
}
