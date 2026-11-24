//! A planning session's state: what claude keeps in `planning.json` as the
//! room answers, read leniently (a field of the wrong shape is just empty,
//! never the end of the rest), and what Gannin keeps beside the session:
//! the room's approvals of each stage, its comments, and what Agree made.
//!
//! Only the room approves a stage, with Gannin's buttons, and Gannin
//! records it: claude moving `phase` on approves nothing. Each stage has
//! exit criteria checked here, and a stage changed after it was approved
//! shows as Recheck (its fields' fingerprint no longer matches).

use chrono::{DateTime, Utc};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;

/// The stages, in order. `ready` is Agree's key, as claude has always
/// written it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Stage {
    Outcome,
    Requirements,
    Design,
    Breakdown,
    Agree,
}

impl Stage {
    pub const ALL: [Stage; 5] = [Stage::Outcome, Stage::Requirements, Stage::Design, Stage::Breakdown, Stage::Agree];

    pub fn key(self) -> &'static str {
        match self {
            Stage::Outcome => "outcome",
            Stage::Requirements => "requirements",
            Stage::Design => "design",
            Stage::Breakdown => "breakdown",
            Stage::Agree => "ready",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Stage::Outcome => "Outcome",
            Stage::Requirements => "Requirements",
            Stage::Design => "Design",
            Stage::Breakdown => "Breakdown",
            Stage::Agree => "Agree",
        }
    }

    /// A stage by its key; the old `context` and `tasks` read as the
    /// stages that took their place, so earlier sessions still open.
    pub fn parse(key: &str) -> Option<Stage> {
        match key.trim().to_lowercase().as_str() {
            "outcome" | "context" => Some(Stage::Outcome),
            "requirements" => Some(Stage::Requirements),
            "design" => Some(Stage::Design),
            "breakdown" | "tasks" => Some(Stage::Breakdown),
            "ready" | "agree" => Some(Stage::Agree),
            _ => None,
        }
    }

    pub fn index(self) -> usize {
        Stage::ALL.iter().position(|s| *s == self).unwrap_or(0)
    }

    pub fn next(self) -> Option<Stage> {
        Stage::ALL.get(self.index() + 1).copied()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Measure {
    pub id: String,
    pub text: String,
    pub target: String,
}

/// What's different once it ships, and how the room will know: asked
/// before anything about how.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Outcome {
    pub change: String,
    pub measures: Vec<Measure>,
    pub if_not: String,
    pub smallest: String,
    pub premortem: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Criterion {
    pub id: String,
    pub text: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Requirement {
    pub problem: String,
    pub goal: String,
    pub users: String,
    pub scope: Vec<String>,
    pub non_goals: Vec<String>,
    pub acceptance: Vec<Criterion>,
    pub open_questions: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Finding {
    /// area, pattern or risk.
    pub kind: String,
    pub repo: String,
    pub path: String,
    pub note: String,
}

impl Finding {
    /// The finding's code on GitHub: `path` may carry `#L10-L24`.
    pub fn url(&self) -> Option<String> {
        if self.repo.is_empty() || self.path.is_empty() {
            return None;
        }
        Some(format!("https://github.com/{}/blob/HEAD/{}", self.repo, self.path.trim_start_matches('/')))
    }
}

/// One piece of the breakdown: an epic, or an issue (under an epic, or
/// the plan's top issue).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Task {
    pub title: String,
    pub body: String,
    pub repo: String,
    pub labels: Vec<String>,
    pub satisfies: Vec<String>,
    /// "epic" or "issue" (the default).
    pub level: String,
    /// The title of the epic it sits under.
    pub parent: String,
    pub test_plan: String,
    /// S, M or L.
    pub estimate: String,
    /// The titles of tasks to be done first.
    pub depends_on: Vec<String>,
}

impl Task {
    pub fn is_epic(&self) -> bool {
        self.level.eq_ignore_ascii_case("epic")
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Decision {
    pub question: String,
    pub answer: String,
    pub stage: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Scouting {
    pub why: String,
    pub paths: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct State {
    pub title: String,
    pub summary: String,
    pub phase: String,
    pub outcome: Outcome,
    pub requirement: Requirement,
    /// Markdown: how it'll be built and why.
    pub approach: String,
    pub scouting_now: Option<Scouting>,
    pub scouting: Vec<Finding>,
    /// initiative, epic or issue: what claude proposes the whole is.
    pub size: String,
    pub size_reason: String,
    pub tasks: Vec<Task>,
    pub decisions: Vec<Decision>,
    pub done: bool,
}

fn text(v: &Value) -> String {
    match v {
        Value::String(s) => s.trim().to_string(),
        Value::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

fn texts(v: &Value) -> Vec<String> {
    match v {
        Value::Array(a) => a.iter().map(text).filter(|s| !s.is_empty()).collect(),
        Value::String(s) if !s.trim().is_empty() => vec![s.trim().to_string()],
        _ => Vec::new(),
    }
}

/// A list's entries of the right shape; the others left out.
fn list<T: DeserializeOwned>(v: &Value) -> Vec<T> {
    v.as_array().map(|a| a.iter().filter_map(|e| serde_json::from_value(e.clone()).ok()).collect()).unwrap_or_default()
}

/// Entries given as objects with an id, or as plain strings numbered
/// with `prefix` (R1, M1) in order.
fn numbered(v: &Value, prefix: &str) -> Vec<(String, String, Value)> {
    v.as_array()
        .map(|a| {
            a.iter()
                .enumerate()
                .filter_map(|(i, e)| match e {
                    Value::String(s) if !s.trim().is_empty() => Some((format!("{prefix}{}", i + 1), s.trim().to_string(), Value::Null)),
                    Value::Object(_) => {
                        let body = text(&e["text"]);
                        (!body.is_empty()).then(|| (Some(text(&e["id"])).filter(|s| !s.is_empty()).unwrap_or_else(|| format!("{prefix}{}", i + 1)), body, e.clone()))
                    }
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default()
}

impl State {
    /// The state file's JSON, read leniently.
    pub fn parse(v: &Value) -> State {
        let o = &v["outcome"];
        let r = &v["requirement"];
        State {
            title: text(&v["title"]),
            summary: text(&v["summary"]),
            phase: text(&v["phase"]),
            outcome: Outcome {
                change: text(&o["change"]),
                measures: numbered(&o["measures"], "M").into_iter().map(|(id, body, e)| Measure { id, text: body, target: text(&e["target"]) }).collect(),
                if_not: text(&o["if_not"]),
                smallest: text(&o["smallest"]),
                premortem: texts(&o["premortem"]),
            },
            requirement: Requirement {
                problem: text(&r["problem"]),
                goal: text(&r["goal"]),
                users: text(&r["users"]),
                scope: texts(&r["scope"]),
                non_goals: texts(&r["non_goals"]),
                acceptance: numbered(&r["acceptance"], "R").into_iter().map(|(id, body, _)| Criterion { id, text: body }).collect(),
                open_questions: texts(&r["open_questions"]),
            },
            approach: text(&v["design"]["approach"]),
            scouting_now: serde_json::from_value::<Scouting>(v["scouting_now"].clone()).ok().filter(|s| !s.why.is_empty()),
            scouting: list(&v["scouting"]),
            size: text(&v["size"]).to_lowercase(),
            size_reason: text(&v["size_reason"]),
            tasks: list::<Task>(&v["tasks"]).into_iter().filter(|t| !t.title.trim().is_empty() || !t.body.trim().is_empty()).collect(),
            decisions: list(&v["decisions"]),
            done: v["done"].as_bool().unwrap_or(false),
        }
    }

    pub fn read(path: &Path) -> Option<State> {
        let bytes = std::fs::read(path).ok()?;
        serde_json::from_slice::<Value>(&bytes).ok().map(|v| State::parse(&v))
    }

    /// The stage claude says it's on; Outcome when it hasn't said.
    pub fn stage(&self) -> Stage {
        Stage::parse(&self.phase).unwrap_or(Stage::Outcome)
    }

    pub fn issues(&self) -> impl Iterator<Item = &Task> {
        self.tasks.iter().filter(|t| !t.is_epic())
    }

    pub fn epics(&self) -> impl Iterator<Item = &Task> {
        self.tasks.iter().filter(|t| t.is_epic())
    }

    /// Acceptance criteria no issue satisfies.
    pub fn uncovered(&self) -> Vec<&Criterion> {
        self.requirement.acceptance.iter().filter(|c| !self.issues().any(|t| t.satisfies.iter().any(|s| s.eq_ignore_ascii_case(&c.id)))).collect()
    }

    /// Why the room can't approve `stage` yet: empty when it can.
    pub fn unmet(&self, stage: Stage) -> Vec<String> {
        let mut out = Vec::new();
        match stage {
            Stage::Outcome => {
                if self.outcome.change.is_empty() {
                    out.push("Say what changes once it ships, and for whom.".to_string());
                }
                if self.outcome.measures.is_empty() {
                    out.push("Add a measure: how you'll know it worked.".to_string());
                }
            }
            Stage::Requirements => {
                if self.requirement.problem.is_empty() {
                    out.push("State the problem.".to_string());
                }
                if self.requirement.goal.is_empty() {
                    out.push("State the goal.".to_string());
                }
                if self.requirement.acceptance.is_empty() {
                    out.push("Add an acceptance criterion.".to_string());
                }
            }
            Stage::Design => {
                if self.approach.is_empty() {
                    out.push("Propose an approach.".to_string());
                }
            }
            Stage::Breakdown => {
                if self.issues().next().is_none() {
                    out.push("Break it into at least one issue.".to_string());
                }
                for t in &self.tasks {
                    let name = if t.title.trim().is_empty() { "An untitled task".to_string() } else { format!("\"{}\"", t.title) };
                    if t.title.trim().is_empty() {
                        out.push(format!("{name} needs a title."));
                    }
                    if t.repo.trim().is_empty() {
                        out.push(format!("{name} needs a repository."));
                    }
                    if !t.parent.trim().is_empty() && !self.epics().any(|e| e.title.eq_ignore_ascii_case(t.parent.trim())) {
                        out.push(format!("{name} sits under \"{}\", which isn't an epic here.", t.parent));
                    }
                }
                let uncovered: Vec<&str> = self.uncovered().iter().map(|c| c.id.as_str()).collect();
                if !uncovered.is_empty() {
                    out.push(format!("No issue satisfies {}.", uncovered.join(", ")));
                }
            }
            Stage::Agree => {}
        }
        out
    }

    /// A fingerprint of what a stage settled, to tell when it changed after
    /// the room approved it.
    pub fn fingerprint(&self, stage: Stage) -> String {
        use std::hash::{Hash, Hasher};
        let fields = match stage {
            Stage::Outcome => serde_json::to_string(&self.outcome),
            Stage::Requirements => serde_json::to_string(&self.requirement),
            Stage::Design => serde_json::to_string(&(&self.approach, &self.scouting)),
            Stage::Breakdown => serde_json::to_string(&(&self.size, &self.tasks)),
            Stage::Agree => Ok(String::new()),
        }
        .unwrap_or_default();
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        fields.hash(&mut hasher);
        format!("{:016x}", hasher.finish())
    }
}

// MARK: - What Gannin keeps beside the session

/// The room's approval of one stage.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Approval {
    pub stage: String,
    pub at: DateTime<Utc>,
    /// How many times it's been approved: a stage sent back and approved
    /// again is its second round.
    pub round: u32,
    pub fingerprint: String,
    /// Why it was approved with its exit criteria unmet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anyway: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Open,
    Approved,
    /// Approved, then changed.
    Recheck,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Approvals {
    #[serde(default)]
    pub stages: Vec<Approval>,
    /// Rounds of stages cleared by going back, so a re-approval counts on.
    #[serde(default)]
    pub rounds: std::collections::HashMap<String, u32>,
}

impl Approvals {
    pub const FILE: &'static str = "approvals.json";

    pub fn load(dir: &Path) -> Approvals {
        std::fs::read(dir.join(Self::FILE)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save(&self, dir: &Path) {
        let _ = std::fs::create_dir_all(dir);
        let _ = std::fs::write(dir.join(Self::FILE), serde_json::to_vec_pretty(self).unwrap_or_default());
    }

    pub fn get(&self, stage: Stage) -> Option<&Approval> {
        self.stages.iter().find(|a| Stage::parse(&a.stage) == Some(stage))
    }

    pub fn status(&self, stage: Stage, state: &State) -> Status {
        match self.get(stage) {
            None => Status::Open,
            Some(a) if a.fingerprint == state.fingerprint(stage) => Status::Approved,
            Some(_) => Status::Recheck,
        }
    }

    pub fn approve(&mut self, stage: Stage, state: &State, anyway: Option<String>, at: DateTime<Utc>) {
        let round = self.rounds.get(stage.key()).copied().unwrap_or(0) + 1;
        self.rounds.insert(stage.key().to_string(), round);
        self.stages.retain(|a| Stage::parse(&a.stage) != Some(stage));
        self.stages.push(Approval { stage: stage.key().to_string(), at, round, fingerprint: state.fingerprint(stage), anyway });
    }

    /// Going back to `stage`: it and every later one need approving again.
    pub fn reopen(&mut self, stage: Stage) {
        self.stages.retain(|a| Stage::parse(&a.stage).is_some_and(|s| s.index() < stage.index()));
    }

    /// The stages before Agree not approved as they stand.
    pub fn outstanding(&self, state: &State) -> Vec<(Stage, Status)> {
        Stage::ALL.iter().filter(|s| **s != Stage::Agree).map(|s| (*s, self.status(*s, state))).filter(|(_, st)| *st != Status::Approved).collect()
    }
}

/// Something said from the room, kept for the plan.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Comment {
    pub stage: String,
    pub text: String,
    pub at: DateTime<Utc>,
}

pub fn comments(dir: &Path) -> Vec<Comment> {
    std::fs::read(dir.join("room.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

pub fn add_comment(dir: &Path, comment: Comment) {
    let mut all = comments(dir);
    all.push(comment);
    let _ = std::fs::write(dir.join("room.json"), serde_json::to_vec_pretty(&all).unwrap_or_default());
}

/// A document shared at the start, and whether it may be committed with
/// the plan (copied in `docs/` beside the session).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Doc {
    pub name: String,
    pub commit: bool,
}

pub fn docs(dir: &Path) -> Vec<Doc> {
    std::fs::read(dir.join("docs.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

pub fn save_docs(dir: &Path, docs: &[Doc]) {
    let _ = std::fs::write(dir.join("docs.json"), serde_json::to_vec_pretty(docs).unwrap_or_default());
}

/// An issue Agree made (or found: the issue being planned), by its draft.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Made {
    pub key: String,
    pub id: String,
    pub repo: String,
    pub number: i64,
    pub url: String,
}

impl Made {
    pub fn reference(&self) -> String {
        format!("{}#{}", self.repo, self.number)
    }
}

/// What Agree has done so far, written after each step so a retry never
/// makes anything twice.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Agreed {
    #[serde(default)]
    pub at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub by: Vec<String>,
    #[serde(default)]
    pub plan_path: String,
    #[serde(default)]
    pub requirement_path: Option<String>,
    #[serde(default)]
    pub parent: Option<Made>,
    #[serde(default)]
    pub made: Vec<Made>,
    /// Drafts put under their epic or the top issue.
    #[serde(default)]
    pub placed: Vec<String>,
    /// The work merged into the parent's body instead of an issue of its own.
    #[serde(default)]
    pub merged_into_parent: bool,
    #[serde(default)]
    pub commit: Option<String>,
    #[serde(default)]
    pub commented: bool,
}

impl Agreed {
    pub const FILE: &'static str = "agreed.json";

    pub fn load(dir: &Path) -> Agreed {
        std::fs::read(dir.join(Self::FILE)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save(&self, dir: &Path) {
        let _ = std::fs::write(dir.join(Self::FILE), serde_json::to_vec_pretty(self).unwrap_or_default());
    }

    pub fn made(&self, key: &str) -> Option<&Made> {
        self.made.iter().find(|m| m.key == key)
    }

    pub fn finished(&self) -> bool {
        self.at.is_some()
    }
}

// MARK: - The breakdown as issues to make

/// A task as it'll be filed, with the room's edits.
#[derive(Clone, Debug, PartialEq)]
pub struct Draft {
    /// Stable across edits: from the task's title in the state file.
    pub key: String,
    pub include: bool,
    pub task: Task,
}

pub fn draft_key(task: &Task) -> String {
    format!("t:{}", task.title.trim().to_lowercase())
}

pub fn drafts(state: &State) -> Vec<Draft> {
    state.tasks.iter().map(|t| Draft { key: draft_key(t), include: true, task: t.clone() }).collect()
}

/// The order to make them in: epics first (their issues go under them),
/// then issues with what each depends on ahead of it, otherwise as given.
/// A loop is left in the order given.
pub fn creation_order(drafts: &[Draft]) -> Vec<usize> {
    let included: Vec<usize> = (0..drafts.len()).filter(|i| drafts[*i].include).collect();
    let mut out: Vec<usize> = included.iter().copied().filter(|i| drafts[*i].task.is_epic()).collect();
    let mut rest: Vec<usize> = included.iter().copied().filter(|i| !drafts[*i].task.is_epic()).collect();
    while !rest.is_empty() {
        let ready = rest.iter().position(|i| {
            drafts[*i].task.depends_on.iter().all(|dep| {
                // Ready when what it needs is made, isn't in the list, or is itself.
                let found = rest.iter().find(|j| drafts[**j].task.title.eq_ignore_ascii_case(dep.trim()));
                found.is_none_or(|j| j == i)
            })
        });
        let at = ready.unwrap_or(0);
        out.push(rest.remove(at));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_old_and_new_shapes() {
        // The shape before outcomes: context and tasks, strings for criteria.
        let old = State::parse(&json!({
            "phase": "tasks", "requirement": { "problem": "p", "acceptance": ["When x, y", { "id": "R7", "text": "When a, b" }] },
            "design": { "approach": "Do it" }, "tasks": [{ "title": "One", "repo": "o/r", "satisfies": ["R1"] }, "junk"], "decisions": 3
        }));
        assert_eq!(old.stage(), Stage::Breakdown);
        assert_eq!(old.requirement.acceptance, vec![Criterion { id: "R1".into(), text: "When x, y".into() }, Criterion { id: "R7".into(), text: "When a, b".into() }]);
        assert_eq!(old.tasks.len(), 1);
        assert!(old.decisions.is_empty());
        assert_eq!(State::parse(&json!({ "phase": "context" })).stage(), Stage::Outcome);
        let new = State::parse(&json!({
            "phase": "outcome", "outcome": { "change": "Ops see it", "measures": [{ "text": "Fewer tickets", "target": "-30%" }], "premortem": "Nobody used it" },
            "size": "Epic", "tasks": [{ "title": "E", "level": "epic", "repo": "o/r" }, { "title": "I", "parent": "E", "repo": "o/r", "depends_on": ["J"] }]
        }));
        assert_eq!(new.outcome.measures[0], Measure { id: "M1".into(), text: "Fewer tickets".into(), target: "-30%".into() });
        assert_eq!(new.outcome.premortem, vec!["Nobody used it".to_string()]);
        assert_eq!(new.size, "epic");
        assert_eq!(new.epics().count(), 1);
    }

    #[test]
    fn exit_criteria_say_why() {
        let mut s = State::default();
        assert_eq!(s.unmet(Stage::Outcome).len(), 2);
        s.outcome.change = "Ops see failures".into();
        s.outcome.measures.push(Measure { id: "M1".into(), text: "t".into(), target: String::new() });
        assert!(s.unmet(Stage::Outcome).is_empty());
        s.requirement.acceptance = vec![Criterion { id: "R1".into(), text: "a".into() }, Criterion { id: "R2".into(), text: "b".into() }];
        s.tasks = vec![
            Task { title: "E".into(), level: "epic".into(), repo: "o/r".into(), satisfies: vec!["R2".into()], ..Default::default() },
            Task { title: "I".into(), parent: "Nope".into(), repo: String::new(), satisfies: vec!["r1".into()], ..Default::default() },
        ];
        let why = s.unmet(Stage::Breakdown);
        // An epic covers nothing itself: R2 is still uncovered.
        assert!(why.iter().any(|w| w == "No issue satisfies R2."));
        assert!(why.iter().any(|w| w.contains("needs a repository")));
        assert!(why.iter().any(|w| w.contains("isn't an epic here")));
    }

    #[test]
    fn approvals_recheck_and_reopen() {
        let mut s = State { outcome: Outcome { change: "a".into(), ..Default::default() }, ..Default::default() };
        let mut a = Approvals::default();
        let now = Utc::now();
        a.approve(Stage::Outcome, &s, None, now);
        a.approve(Stage::Requirements, &s, Some("Agreed in the room".into()), now);
        assert_eq!(a.status(Stage::Outcome, &s), Status::Approved);
        s.outcome.change = "b".into();
        assert_eq!(a.status(Stage::Outcome, &s), Status::Recheck);
        // Requirements didn't change.
        assert_eq!(a.status(Stage::Requirements, &s), Status::Approved);
        a.reopen(Stage::Outcome);
        assert_eq!(a.status(Stage::Requirements, &s), Status::Open);
        a.approve(Stage::Outcome, &s, None, now);
        assert_eq!(a.get(Stage::Outcome).unwrap().round, 2);
        assert_eq!(a.outstanding(&s).iter().map(|(st, _)| *st).collect::<Vec<_>>(), vec![Stage::Requirements, Stage::Design, Stage::Breakdown]);
    }

    #[test]
    fn epics_first_then_what_is_needed_first() {
        let task = |title: &str, level: &str, deps: &[&str]| Draft {
            key: String::new(),
            include: true,
            task: Task { title: title.into(), level: level.into(), depends_on: deps.iter().map(|d| d.to_string()).collect(), ..Default::default() },
        };
        let mut d = vec![task("Web", "", &["API"]), task("API", "", &["Schema"]), task("Epic", "epic", &[]), task("Schema", "", &["Unknown"]), task("Loop A", "", &["Loop B"]), task("Loop B", "", &["Loop A"])];
        d[5].include = true;
        let names: Vec<&str> = creation_order(&d).into_iter().map(|i| d[i].task.title.as_str()).collect();
        assert_eq!(names, vec!["Epic", "Schema", "API", "Web", "Loop A", "Loop B"]);
        d[0].include = false;
        assert_eq!(creation_order(&d).len(), 5);
    }
}
