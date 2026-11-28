//! Agent workflows, as Gannin keeps them (`AgentWorkflows.swift`):
//!
//! - The team's, in the harness's `.gannin/agent-workflows.json`, keyed by
//!   activity (`work`, `review`, and so on). Read from the harness checkout
//!   on this Mac; written through GitHub's API (see `commit_team`).
//! - Each person's own ("Just me"), which never go in a harness: kept here
//!   in the app's own `agent-workflows.json`, with their default per
//!   activity. The team file's `default` is ignored, so each person picks.
//! - Specialists, `specialists/<name>.md` in the harness: front matter
//!   `name`, `title`, `summary`, `provider`, `model`, `focus`, and the soul.
//!
//! What's new here (docs/workflows.md): a stage may say when it runs
//! (`"when"`: `prepare`, `session`, `local`, `pr`), and a step may be a
//! `"command"` that must pass, with `"holds"` for what holds a local gate.
//! A stage without `when` keeps its meaning: before the session it
//! prepares, after it it's on the PR. Unknown keys are kept, entries this
//! build can't read are skipped, and every list keeps its `id`s, so the
//! Swift app's three-way merge still works.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};

pub const BUILT_IN: &str = "built-in";

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Step {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub specialist: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub focus: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rounds: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interactive: Option<bool>,
    /// A step that's a command to pass, run in the worktree.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// A local reviewer: what holds the push ("blocker-major", "all").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub holds: Option<String>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl Step {
    pub fn is_session(&self) -> bool {
        self.interactive == Some(true)
    }

    pub fn round_count(&self) -> u32 {
        self.rounds.unwrap_or(1).clamp(1, 5)
    }

    /// Who it is, for the strip and the editor.
    pub fn label(&self, specialists: &[Specialist]) -> String {
        if let Some(command) = &self.command {
            return command.clone();
        }
        if self.is_session() {
            return "Session".into();
        }
        match self.specialist.as_deref() {
            Some(name) => specialists.iter().find(|s| s.name.eq_ignore_ascii_case(name)).map(|s| s.title.clone()).unwrap_or_else(|| name.to_string()),
            None if self.provider.as_deref() == Some("junie") => "Junie".into(),
            None => "Gannin's reviewer".into(),
        }
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Stage {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub when: Option<String>,
    pub steps: Vec<Step>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Workflow {
    pub id: String,
    pub name: String,
    pub stages: Vec<Stage>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

/// When a stage runs, said or worked out from where it sits.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum When {
    Prepare,
    Session,
    Local,
    Pr,
}

impl When {
    pub fn key(self) -> &'static str {
        match self {
            When::Prepare => "prepare",
            When::Session => "session",
            When::Local => "local",
            When::Pr => "pr",
        }
    }
}

impl Workflow {
    /// Gannin's own: the session alone, exactly as Work on This always ran.
    pub fn built_in() -> Self {
        Self {
            id: BUILT_IN.into(),
            name: "Gannin's default".into(),
            stages: vec![Stage { id: BUILT_IN.into(), when: None, steps: vec![Step { id: BUILT_IN.into(), interactive: Some(true), ..Default::default() }], extra: Map::new() }],
            extra: Map::new(),
        }
    }

    pub fn is_built_in(&self) -> bool {
        self.id == BUILT_IN
    }

    /// Each stage with when it runs.
    pub fn staged(&self) -> Vec<(When, &Stage)> {
        let session = self.stages.iter().position(|s| s.steps.iter().any(Step::is_session));
        self.stages
            .iter()
            .enumerate()
            .map(|(i, stage)| {
                let when = match stage.when.as_deref() {
                    Some("prepare") => When::Prepare,
                    Some("session") => When::Session,
                    Some("local") => When::Local,
                    Some("pr") => When::Pr,
                    _ => match session {
                        Some(at) if i < at => When::Prepare,
                        Some(at) if i == at => When::Session,
                        _ => When::Pr,
                    },
                };
                (when, stage)
            })
            .collect()
    }

    pub fn steps_when(&self, when: When) -> Vec<&Step> {
        self.staged().into_iter().filter(|(w, _)| *w == when).flat_map(|(_, s)| s.steps.iter()).collect()
    }
}

/// One activity's workflows, its default (only read from one's own) and
/// routing rules (kept as they are; the pilot doesn't route yet).
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Activity {
    #[serde(default, deserialize_with = "lenient_workflows")]
    pub workflows: Vec<Workflow>,
    #[serde(rename = "default", skip_serializing_if = "Option::is_none")]
    pub default: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rules: Option<Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

/// A workflow this build can't read is left out, not the whole file.
fn lenient_workflows<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<Workflow>, D::Error> {
    let values: Vec<Value> = Vec::deserialize(d).unwrap_or_default();
    Ok(values.into_iter().filter_map(|v| serde_json::from_value(v).ok()).collect())
}

/// The whole file: activities by name at the top level.
pub type Library = std::collections::BTreeMap<String, Activity>;

pub fn team_path(harness: &Path) -> PathBuf {
    harness.join(".gannin/agent-workflows.json")
}

fn own_path() -> PathBuf {
    crate::paths::app_dir().join("agent-workflows.json")
}

fn read(path: &Path) -> Library {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v.as_object().cloned())
        .map(|m| m.into_iter().filter_map(|(k, v)| Some((k, serde_json::from_value(v).ok()?))).collect())
        .unwrap_or_default()
}

pub fn team(harness: &Path) -> Library {
    read(&team_path(harness))
}

pub fn own() -> Library {
    read(&own_path())
}

pub fn save_own(library: &Library) -> std::io::Result<()> {
    let path = own_path();
    if let Some(folder) = path.parent() {
        std::fs::create_dir_all(folder)?;
    }
    std::fs::write(path, encode(library))
}

/// Keys sorted at every level, as the team files are written.
pub fn encode(library: &Library) -> String {
    fn sorted(v: Value) -> Value {
        match v {
            Value::Object(m) => {
                let mut e: Vec<(String, Value)> = m.into_iter().collect();
                e.sort_by(|a, b| a.0.cmp(&b.0));
                Value::Object(e.into_iter().map(|(k, v)| (k, sorted(v))).collect())
            }
            Value::Array(a) => Value::Array(a.into_iter().map(sorted).collect()),
            other => other,
        }
    }
    let value = sorted(serde_json::to_value(library).unwrap_or(Value::Null));
    let mut text = serde_json::to_string_pretty(&value).unwrap_or_default();
    text.push('\n');
    text
}

/// A workflow on offer: whose it is, and it.
#[derive(Clone, Debug)]
pub struct Offered {
    pub whose: Whose,
    pub workflow: Workflow,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Whose {
    Gannin,
    Team,
    Mine,
}

impl Whose {
    pub fn title(self) -> &'static str {
        match self {
            Whose::Gannin => "Gannin's",
            Whose::Team => "Team",
            Whose::Mine => "Just me",
        }
    }
}

/// An activity's workflows: Gannin's first, then yours, then the team's.
pub fn offered(activity: &str, harness: Option<&Path>) -> Vec<Offered> {
    let mut out = vec![Offered { whose: Whose::Gannin, workflow: Workflow::built_in() }];
    out.extend(own().get(activity).into_iter().flat_map(|a| a.workflows.clone()).filter(|w| !w.is_built_in()).map(|workflow| Offered { whose: Whose::Mine, workflow }));
    if let Some(harness) = harness {
        out.extend(team(harness).get(activity).into_iter().flat_map(|a| a.workflows.clone()).filter(|w| !w.is_built_in()).map(|workflow| Offered { whose: Whose::Team, workflow }));
    }
    out
}

/// The workflow an activity runs for you: your default if it's still
/// there, else Gannin's. The team file's default is each person's to pick,
/// so it's ignored.
pub fn default_for(activity: &str, harness: Option<&Path>) -> Workflow {
    let id = own().get(activity).and_then(|a| a.default.clone());
    id.and_then(|id| offered(activity, harness).into_iter().find(|o| o.workflow.id == id).map(|o| o.workflow)).unwrap_or_else(Workflow::built_in)
}

pub fn set_default(activity: &str, id: &str) -> std::io::Result<()> {
    let mut library = own();
    library.entry(activity.to_string()).or_default().default = Some(id.to_string());
    save_own(&library)
}

/// Saves one of your own workflows (adding or replacing it).
pub fn save_mine(activity: &str, workflow: &Workflow) -> std::io::Result<()> {
    let mut library = own();
    let entry = library.entry(activity.to_string()).or_default();
    match entry.workflows.iter_mut().find(|w| w.id == workflow.id) {
        Some(held) => *held = workflow.clone(),
        None => entry.workflows.push(workflow.clone()),
    }
    save_own(&library)
}

pub fn delete_mine(activity: &str, id: &str) -> std::io::Result<()> {
    let mut library = own();
    if let Some(entry) = library.get_mut(activity) {
        entry.workflows.retain(|w| w.id != id);
        if entry.default.as_deref() == Some(id) {
            entry.default = None;
        }
    }
    save_own(&library)
}

// MARK: - Specialists

#[derive(Clone, Debug, Default)]
pub struct Specialist {
    pub name: String,
    pub title: String,
    pub summary: String,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub focus: Option<String>,
    pub soul: String,
}

/// The harness's specialists, from `specialists/*.md`; one with prose only
/// is named by its file.
pub fn specialists(harness: &Path) -> Vec<Specialist> {
    let mut out: Vec<Specialist> = std::fs::read_dir(harness.join("specialists"))
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "md"))
        .filter_map(|e| {
            let text = std::fs::read_to_string(e.path()).ok()?;
            let file = e.path().file_stem()?.to_string_lossy().to_string();
            let (front, soul) = match text.strip_prefix("---\n").and_then(|rest| rest.split_once("\n---")) {
                Some((front, body)) => (front.to_string(), body.trim_start_matches('\n').to_string()),
                None => (String::new(), text.clone()),
            };
            let field = |key: &str| front.lines().find_map(|l| l.strip_prefix(&format!("{key}:")).map(|v| v.trim().trim_matches('"').to_string())).filter(|v| !v.is_empty());
            Some(Specialist {
                name: field("name").unwrap_or_else(|| file.clone()),
                title: field("title").unwrap_or_else(|| file.replace('-', " ")),
                summary: field("summary").unwrap_or_default(),
                provider: field("provider"),
                model: field("model"),
                focus: field("focus"),
                soul,
            })
        })
        .collect();
    out.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
    out
}

pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_lowercase()
}
