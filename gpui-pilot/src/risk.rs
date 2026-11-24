//! Merge risk: how bad it'd be if merging went wrong, never how good the
//! code is (the findings say that). Claude grades five signals in the
//! review JSON (`risk`) and checks the linked issues' acceptance criteria
//! (`criteria`). The signals fall in two groups: exposure (impact, rollback
//! cost, error detection: what the change touches, which better code or
//! more tests can't lower) and confidence (verification, alignment: whether
//! we can tell it works). The grade is exposure, moved by confidence only
//! at the edges: worked out here with fixed weights so it's stable and can
//! be explained. Two floors claude can't argue past: a change touching a
//! path the team marks sensitive is at least medium impact, as is one
//! changing what coding agents load (`AGENT_CONTEXT`: it changes how every
//! later session behaves, so a person reviews it and it's never approved
//! by itself), and a missing acceptance criterion makes verification poor.
//!
//! The team marks sensitive paths in `.gannin/review.json`: a `sensitive`
//! list in the harness's `defaults` and `repos["owner/name"]`, and at the
//! top of the repo's own file. Each entry is a path (a folder ends in `/`,
//! `*` matches within a folder, `**` across folders), or `{"path", "why"}`.
//!
//! The grade a review reached is kept beside its session (`risk.json`) and
//! in memory, so the Pull Requests table shows it without the review open.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Level {
    Low,
    Medium,
    High,
}

impl Level {
    /// The colour it reads as at a glance, in a posted review.
    pub fn emoji(self) -> &'static str {
        match self {
            Level::Low => "🟢",
            Level::Medium => "🟠",
            Level::High => "🔴",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Level::Low => "low",
            Level::Medium => "medium",
            Level::High => "high",
        }
    }

    fn parse(text: &str) -> Option<Level> {
        match text {
            "low" => Some(Level::Low),
            "medium" => Some(Level::Medium),
            "high" => Some(Level::High),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Group {
    /// What the change touches: how bad a failure would be.
    Exposure,
    /// Whether we can tell it works.
    Confidence,
}

impl Group {
    pub fn title(self) -> &'static str {
        match self {
            Group::Exposure => "Exposure",
            Group::Confidence => "Confidence",
        }
    }

    /// The group's grade as a word: exposure low to high, confidence good
    /// to poor.
    pub fn word(self, score: u8) -> &'static str {
        match (self, score) {
            (Group::Exposure, 1) => "low",
            (Group::Exposure, 2) => "medium",
            (Group::Exposure, _) => "high",
            (Group::Confidence, 1) => "good",
            (Group::Confidence, 2) => "decent",
            (Group::Confidence, _) => "poor",
        }
    }
}

/// The five signals, in the order they're shown: key, title, group,
/// weight within the group, and the verdicts from good to bad.
pub const SIGNALS: [(&str, &str, Group, f32, [&str; 3]); 5] = [
    ("impact", "Impact", Group::Exposure, 2.0, ["small", "medium", "large"]),
    ("rollback", "Rollback cost", Group::Exposure, 1.5, ["low", "medium", "high"]),
    ("detection", "Error detection", Group::Exposure, 1.0, ["good", "decent", "poor"]),
    ("verification", "Verification", Group::Confidence, 2.0, ["good", "decent", "poor"]),
    ("alignment", "Alignment", Group::Confidence, 1.0, ["good", "decent", "poor"]),
];

#[derive(Clone, Debug, PartialEq)]
pub struct Signal {
    pub key: &'static str,
    pub title: &'static str,
    /// As claude gave it, else None (or "n/a" for error detection).
    pub verdict: Option<String>,
    pub reason: Option<String>,
    /// Raised by a floor: why.
    pub raised: Option<String>,
}

impl Signal {
    /// 1 good, 2 middle, 3 bad; None when unknown or not applicable.
    pub fn score(&self) -> Option<u8> {
        let verdicts = SIGNALS.iter().find(|s| s.0 == self.key)?.4;
        verdicts.iter().position(|v| Some(*v) == self.verdict.as_deref()).map(|i| i as u8 + 1)
    }

    fn weight(&self) -> f32 {
        SIGNALS.iter().find(|s| s.0 == self.key).map(|s| s.3).unwrap_or(1.0)
    }

    pub fn group(&self) -> Group {
        SIGNALS.iter().find(|s| s.0 == self.key).map(|s| s.2).unwrap_or(Group::Confidence)
    }

    /// Raises the verdict to at least `floor` (1 to 3), saying why.
    fn floor(&mut self, floor: u8, why: String) {
        let verdicts = SIGNALS.iter().find(|s| s.0 == self.key).map(|s| s.4).unwrap_or(["", "", ""]);
        if self.score().is_none_or(|s| s < floor) {
            self.verdict = Some(verdicts[floor as usize - 1].to_string());
            self.raised = Some(why);
        }
    }
}

/// One acceptance criterion from an issue the PR is for, as claude found it.
#[derive(Clone, Debug, PartialEq)]
pub struct Criterion {
    pub criterion: String,
    pub issue: Option<String>,
    /// met, partial, missing, untestable, or later (another PR's, or
    /// checked by people after merge: never a floor or a gap).
    pub status: String,
    pub evidence: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Risk {
    pub signals: Vec<Signal>,
    /// What would bring the risk down, as claude lists it.
    pub gaps: Vec<String>,
    pub criteria: Vec<Criterion>,
    /// Changed files in the team's sensitive areas, with why when given.
    pub sensitive: Vec<(String, Option<String>)>,
    /// Changed files coding agents load as instructions or context.
    pub agent_context: Vec<String>,
}

/// What coding agents load as instructions or context, wherever it sits
/// in a repo: a change to one is a person's to review, whatever its size.
pub const AGENT_CONTEXT: [&str; 14] = [
    "**/AGENTS.md",
    "**/AGENT.md",
    "**/CLAUDE.md",
    "**/CLAUDE.local.md",
    "**/GEMINI.md",
    "**/.claude/**",
    "**/.cursorrules",
    "**/.cursor/rules/**",
    "**/.github/copilot-instructions.md",
    "**/.github/instructions/**",
    "**/.windsurfrules",
    "**/SKILL.md",
    "**/.mcp.json",
    "**/.gannin/**",
];

/// Whether coding agents load `path` (`AGENT_CONTEXT`).
pub fn is_agent_context(path: &str) -> bool {
    AGENT_CONTEXT.iter().any(|p| matches(p, path))
}

/// The `risk` and `criteria` parts of the review JSON, read leniently: a
/// malformed signal is just unknown. None when there's neither.
pub fn parse(value: &Value) -> Option<Risk> {
    let text = |v: &Value| v.as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
    let risk = &value["risk"];
    let criteria: Vec<Criterion> = value["criteria"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|c| {
                    Some(Criterion {
                        criterion: text(&c["criterion"])?,
                        issue: text(&c["issue"]),
                        status: text(&c["status"]).map(|s| s.to_lowercase()).unwrap_or_else(|| "untestable".into()),
                        evidence: text(&c["evidence"]),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    if !risk.is_object() && criteria.is_empty() {
        return None;
    }
    let signals = SIGNALS
        .iter()
        .map(|(key, title, _, _, _)| {
            let entry = &risk[*key];
            // A bare string is the verdict alone.
            let verdict = text(&entry["verdict"]).or_else(|| text(entry)).map(|v| v.to_lowercase());
            Signal { key: *key, title: *title, verdict, reason: text(&entry["reason"]), raised: None }
        })
        .collect();
    let gaps = risk["gaps"].as_array().map(|a| a.iter().filter_map(text).collect()).unwrap_or_default();
    Some(Risk { signals, gaps, criteria, sensitive: Vec::new(), agent_context: Vec::new() })
}

impl Risk {
    /// With the floors applied: the sensitive files changed (from the
    /// review's walkthrough) and the criteria claude checked.
    pub fn assessed(mut self, changed: &[String], sensitive: &[Sensitive]) -> Risk {
        self.sensitive = changed
            .iter()
            .filter_map(|path| sensitive.iter().find(|s| matches(&s.path, path)).map(|s| (path.clone(), s.why.clone())))
            .collect();
        if !self.sensitive.is_empty() {
            let n = self.sensitive.len();
            let why = format!("Touches {} the team marks sensitive", if n == 1 { "a path".to_string() } else { format!("{n} paths") });
            if let Some(impact) = self.signals.iter_mut().find(|s| s.key == "impact") {
                impact.floor(2, why);
            }
        }
        self.agent_context = changed.iter().filter(|p| is_agent_context(p)).cloned().collect();
        if !self.agent_context.is_empty() {
            let n = self.agent_context.len();
            let why = format!("Changes {} coding agents load, which a person reviews", if n == 1 { "a file".to_string() } else { format!("{n} files") });
            if let Some(impact) = self.signals.iter_mut().find(|s| s.key == "impact") {
                impact.floor(2, why);
            }
        }
        let missing = self.criteria.iter().filter(|c| c.status == "missing").count();
        let partial = self.criteria.iter().filter(|c| c.status == "partial").count();
        if let Some(verification) = self.signals.iter_mut().find(|s| s.key == "verification") {
            if missing > 0 {
                verification.floor(3, format!("{missing} acceptance criteri{} not met", if missing == 1 { "on" } else { "a" }));
            } else if partial > 0 {
                verification.floor(2, format!("{partial} acceptance criteri{} only partly met", if partial == 1 { "on" } else { "a" }));
            }
        }
        self
    }

    /// A group's grade, 1 to 3: the weighted mean of its known signals,
    /// 1 under 1.5, 3 from 2.25. None until its main signal (impact,
    /// verification) is known.
    pub fn group_score(&self, group: Group) -> Option<u8> {
        let main = if group == Group::Exposure { "impact" } else { "verification" };
        if !self.signals.iter().any(|s| s.key == main && s.score().is_some()) {
            return None;
        }
        let known: Vec<(f32, f32)> = self.signals.iter().filter(|s| s.group() == group).filter_map(|s| s.score().map(|score| (score as f32, s.weight()))).collect();
        let total: f32 = known.iter().map(|(_, w)| w).sum();
        let mean = known.iter().map(|(s, w)| s * w).sum::<f32>() / total;
        Some(if mean < 1.5 {
            1
        } else if mean < 2.25 {
            2
        } else {
            3
        })
    }

    /// Exposure sets the grade; confidence moves it a step only at the
    /// edges. High exposure is never low, however well tested ("some
    /// things are just risky"), and is high unless confidence is good;
    /// medium is medium, or high when confidence is poor; low exposure is
    /// low, or medium when confidence is poor. None until both are known.
    pub fn level(&self) -> Option<Level> {
        let (exposure, confidence) = (self.group_score(Group::Exposure)?, self.group_score(Group::Confidence)?);
        Some(match (exposure, confidence) {
            (1, 3) => Level::Medium,
            (1, _) => Level::Low,
            (2, 3) => Level::High,
            (2, _) => Level::Medium,
            (_, 1) => Level::Medium,
            _ => Level::High,
        })
    }

    /// The one thing to look at before merging: the worst signal in the
    /// group that set the grade (confidence when it raised it, else
    /// exposure).
    pub fn next_step(&self) -> String {
        let Some(level) = self.level() else { return "Not enough to grade it.".into() };
        if level == Level::Low {
            return "Safe to merge once the findings are dealt with.".into();
        }
        let confidence = self.group_score(Group::Confidence).unwrap_or(1);
        let exposure = self.group_score(Group::Exposure).unwrap_or(1);
        let group = if confidence == 3 || (exposure == 3 && confidence == 2) { Group::Confidence } else { Group::Exposure };
        let worst = self.signals.iter().filter(|s| s.group() == group && s.score().is_some_and(|s| s > 1)).max_by(|a, b| {
            let weigh = |s: &Signal| s.score().unwrap_or(0) as f32 * s.weight();
            weigh(a).partial_cmp(&weigh(b)).unwrap_or(std::cmp::Ordering::Equal)
        });
        match (group, worst) {
            (Group::Confidence, Some(s)) => format!("Look at {} before merging.", s.title.to_lowercase()),
            (Group::Exposure, Some(s)) => format!("{} keeps it {}: a person should look before merging.", s.title, level.title()),
            (_, None) => "Look it over before merging.".into(),
        }
    }

    /// How a group's grade was reached, for the posted review: what each
    /// signal measures, the weighted mean with this review's numbers, and
    /// the cut-offs.
    pub fn group_working(&self, group: Group) -> Vec<String> {
        let mut lines: Vec<String> = SIGNALS.iter().filter(|s| s.2 == group).map(|s| format!("{}: {}", s.1, meaning(s.0))).collect();
        let scored: Vec<(&Signal, u8)> = self.signals.iter().filter(|s| s.group() == group).filter_map(|s| s.score().map(|score| (s, score))).collect();
        let scale = SIGNALS.iter().filter(|s| s.2 == group).map(|s| format!("{} ×{}", s.1.to_lowercase(), s.3)).collect::<Vec<_>>().join(", ");
        lines.push(format!(
            "Each signal scores 1 ({}) to 3 ({}), weighted {scale}; one not graded, or n/a, is left out.",
            if group == Group::Exposure { "small, low, good" } else { "good" },
            if group == Group::Exposure { "large, high, poor" } else { "poor" }
        ));
        if let Some(score) = self.group_score(group) {
            let total: f32 = scored.iter().map(|(s, _)| s.weight()).sum();
            let sum: f32 = scored.iter().map(|(s, n)| s.weight() * *n as f32).sum();
            let terms = scored.iter().map(|(s, n)| format!("{}×{n}", s.weight())).collect::<Vec<_>>().join(" + ");
            lines.push(format!(
                "Here ({terms}) / {total} = {:.2}. Under 1.5 is {}, from 2.25 is {}, between is {}: so {}.",
                sum / total,
                group.word(1),
                group.word(3),
                group.word(2),
                group.word(score)
            ));
        }
        let raised: Vec<String> = self.signals.iter().filter(|s| s.group() == group).filter_map(|s| s.raised.as_ref().map(|r| format!("{} was raised: {}.", s.title, r.to_lowercase()))).collect();
        lines.extend(raised);
        lines
    }

    /// How the overall grade came from the two groups.
    pub fn level_working(&self) -> Vec<String> {
        let mut lines = vec![
            "Merge risk is how bad it would be if merging went wrong, not how good the code is: the comments below cover that.".to_string(),
            "Exposure (what the change touches) sets it; confidence (whether we can tell it works) moves it a step only at the edges:".to_string(),
            "- High exposure: medium with good confidence, otherwise high. Never low, however well tested.".to_string(),
            "- Medium exposure: medium, or high with poor confidence.".to_string(),
            "- Low exposure: low, or medium with poor confidence.".to_string(),
            "A path the team marks sensitive, or a file coding agents load (AGENTS.md, CLAUDE.md, rules, skills), makes impact at least medium, and an acceptance criterion not met makes verification at least decent (poor when missing).".to_string(),
        ];
        if let (Some(e), Some(c), Some(level)) = (self.group_score(Group::Exposure), self.group_score(Group::Confidence), self.level()) {
            lines.push(format!("Here exposure is {} and confidence {}, so {}.", Group::Exposure.word(e), Group::Confidence.word(c), level.title()));
        }
        lines
    }

    /// Whether an acceptance criterion this PR is for isn't done: an
    /// approval never goes by itself then, whatever the grade.
    pub fn criteria_missing(&self) -> bool {
        self.criteria.iter().any(|c| c.status == "missing")
    }
}

impl Risk {
    /// The merge risk as it goes in the posted review's body: the grade and
    /// what to look at, exposure and confidence with each signal graded
    /// and why, the acceptance criteria not met and the sensitive paths
    /// touched. None when there's nothing graded to say.
    pub fn markdown(&self) -> Option<String> {
        Some(self.alert(&self.lines()?))
    }

    /// The body's lines, before they go in the alert.
    fn lines(&self) -> Option<Vec<String>> {
        let graded: Vec<&Signal> = self.signals.iter().filter(|s| s.verdict.as_deref().is_some_and(|v| v != "n/a")).collect();
        if graded.is_empty() && self.criteria.is_empty() {
            return None;
        }
        let mut out = vec![match self.level() {
            Some(level) => format!("{} **Merge risk: {}.** {}", level.emoji(), level.title(), self.next_step()),
            None => "**Merge risk:** not enough to grade it.".to_string(),
        }];
        if self.level().is_some() {
            out.extend(details("How the merge risk is worked out", &self.level_working()));
        }
        for group in [Group::Exposure, Group::Confidence] {
            let signals: Vec<&&Signal> = graded.iter().filter(|s| s.group() == group).collect();
            if signals.is_empty() {
                continue;
            }
            out.push(String::new());
            out.push(match self.group_score(group) {
                Some(score) => format!("**{}: {}**", group.title(), group.word(score)),
                None => format!("**{}**", group.title()),
            });
            for s in signals {
                // Never "- `": the body's findings are read back by that.
                let mut line = format!("- {}: {}", s.title, s.verdict.clone().unwrap_or_default());
                if let Some(reason) = &s.reason {
                    line.push_str(&format!(". {}", reason.trim_end_matches('.')));
                }
                if let Some(raised) = &s.raised {
                    line.push_str(&format!(" (raised: {})", raised.to_lowercase()));
                }
                line.push('.');
                out.push(line);
            }
            out.extend(details(&format!("How {} is worked out", group.title().to_lowercase()), &self.group_working(group)));
        }
        let unmet: Vec<&Criterion> = self.criteria.iter().filter(|c| c.status == "missing" || c.status == "partial").collect();
        if !unmet.is_empty() {
            out.push(String::new());
            out.push("**Acceptance criteria not met**".into());
            for c in unmet {
                let issue = c.issue.as_ref().map(|i| format!(" ({i})")).unwrap_or_default();
                let status = if c.status == "missing" { "missing" } else { "partly met" };
                out.push(format!("- {}{issue}: {status}{}", c.criterion, c.evidence.as_ref().map(|e| format!(". {e}")).unwrap_or_default()));
            }
        }
        if !self.sensitive.is_empty() {
            out.push(String::new());
            out.push("**Touches paths the team marks sensitive**".into());
            for (path, why) in &self.sensitive {
                out.push(format!("- {path}{}", why.as_ref().map(|w| format!(": {w}")).unwrap_or_default()));
            }
        }
        if !self.agent_context.is_empty() {
            out.push(String::new());
            out.push("**Changes what coding agents load**".into());
            out.push("A person should review these: they change how every later session behaves.".into());
            for path in &self.agent_context {
                out.push(format!("- {path}"));
            }
        }
        // The gaps stay out of the body: a list there can't be resolved
        // point by point. Those claude can place in the code come as
        // findings, so inline threads; the rest show only in the panel.
        Some(out)
    }

    /// A GitHub alert, so it's marked off from the review beneath: its
    /// colour follows the grade.
    fn alert(&self, out: &[String]) -> String {
        let kind = match self.level() {
            Some(Level::Low) => "TIP",
            Some(Level::Medium) => "WARNING",
            Some(Level::High) => "CAUTION",
            None => "NOTE",
        };
        let mut alert = vec![format!("> [!{kind}]")];
        alert.extend(out.iter().map(|line| if line.is_empty() { ">".to_string() } else { format!("> {line}") }));
        alert.join("\n")
    }

    /// The merge risk for a review after an earlier one posted its own
    /// (`previous`, that review's body): only what changed, so the same
    /// large block isn't repeated each time. Unchanged, it's one line;
    /// changed, the grade's move and the signals, criteria and sensitive
    /// paths that moved. The whole of it follows, collapsed, which is
    /// also what the next review compares against. Falls back to the full
    /// block when `previous` holds none to compare.
    pub fn markdown_since(&self, previous: &str) -> Option<String> {
        let lines = self.lines()?;
        let Some(before) = Prior::read(previous) else { return Some(self.alert(&lines)) };
        let level = self.level().map(Level::title);
        let mut changes: Vec<String> = Vec::new();
        for s in self.signals.iter().filter(|s| s.verdict.as_deref().is_some_and(|v| v != "n/a")) {
            let now = s.verdict.clone().unwrap_or_default();
            match before.signals.get(s.title) {
                Some(was) if *was == now => {}
                Some(was) => changes.push(format!("- {}: {now} (was {was}){}", s.title, s.reason.as_ref().map(|r| format!(". {}", r.trim_end_matches('.'))).unwrap_or_default())),
                None => changes.push(format!("- {}: {now}, newly graded", s.title)),
            }
        }
        let unmet: Vec<(String, &str)> = self.criteria.iter().filter(|c| c.status == "missing" || c.status == "partial").map(|c| (c.key(), if c.status == "missing" { "missing" } else { "partly met" })).collect();
        for (key, status) in &unmet {
            match before.unmet.iter().find(|(k, _)| k == key) {
                Some((_, was)) if was == status => {}
                Some((_, was)) => changes.push(format!("- Acceptance criterion {key}: {status} (was {was})")),
                None => changes.push(format!("- Acceptance criterion {key}: {status}")),
            }
        }
        for (key, _) in before.unmet.iter().filter(|(k, _)| !unmet.iter().any(|(u, _)| u == k)) {
            changes.push(format!("- Acceptance criterion {key}: now met"));
        }
        for (path, _) in self.sensitive.iter().filter(|(p, _)| !before.sensitive.contains(p)) {
            changes.push(format!("- Now touches {path}, which the team marks sensitive"));
        }
        let emoji = self.level().map(Level::emoji).unwrap_or("⚪");
        let same_level = level.map(str::to_string) == before.level;
        let head = match (level, same_level, changes.is_empty()) {
            (None, _, _) => "**Merge risk:** not enough to grade it.".to_string(),
            (Some(l), true, true) => format!("{emoji} **Merge risk: {l}, unchanged since the last review.** {}", self.next_step()),
            (Some(l), true, false) => format!("{emoji} **Merge risk: still {l}.** {}", self.next_step()),
            (Some(l), false, _) => format!(
                "{emoji} **Merge risk: {l}{}.** {}",
                before.level.as_ref().map(|was| format!(" (was {was})")).unwrap_or_default(),
                self.next_step()
            ),
        };
        let mut out = vec![head];
        if !changes.is_empty() {
            out.push(String::new());
            out.push("Since the last review:".into());
            out.extend(changes);
        }
        let mut body = self.alert(&out);
        body.push_str("\n\n");
        body.push_str(&details("The whole merge risk", &lines).join("\n"));
        Some(body)
    }
}

impl Criterion {
    /// How it's named in a posted review: the criterion, and its issue.
    fn key(&self) -> String {
        format!("{}{}", self.criterion, self.issue.as_ref().map(|i| format!(" ({i})")).unwrap_or_default())
    }
}

/// What an earlier review's merge risk said, read back from its body.
struct Prior {
    level: Option<String>,
    /// Signal title -> verdict.
    signals: HashMap<String, String>,
    /// Criterion (as `Criterion::key`) and "missing" or "partly met".
    unmet: Vec<(String, String)>,
    sensitive: Vec<String>,
}

impl Prior {
    /// None when the body has no graded merge risk to compare with. Reads
    /// the lines `Risk::lines` writes, in or out of an alert or a
    /// collapsed section.
    fn read(body: &str) -> Option<Prior> {
        #[derive(PartialEq)]
        enum Section {
            None,
            Signals,
            Unmet,
            Sensitive,
        }
        let mut prior = Prior { level: None, signals: HashMap::new(), unmet: Vec::new(), sensitive: Vec::new() };
        let mut section = Section::None;
        for raw in body.lines() {
            let line = raw.trim_start_matches('>').trim();
            if let Some(rest) = line.split("**Merge risk: ").nth(1) {
                let word: String = rest.chars().take_while(|c| c.is_ascii_alphabetic()).collect();
                // "still medium", "low, unchanged": the grade's word.
                let word = if word == "still" { rest.trim_start_matches("still ").chars().take_while(|c| c.is_ascii_alphabetic()).collect() } else { word };
                if prior.level.is_none() && Level::parse(&word).is_some() {
                    prior.level = Some(word);
                }
                continue;
            }
            if line.starts_with("**") {
                section = if line.starts_with("**Exposure") || line.starts_with("**Confidence") {
                    Section::Signals
                } else if line.starts_with("**Acceptance criteria not met") {
                    Section::Unmet
                } else if line.starts_with("**Touches paths") {
                    Section::Sensitive
                } else {
                    Section::None
                };
                continue;
            }
            if line.starts_with('<') {
                // A collapsed section's working, never signals.
                if line.starts_with("<details") {
                    section = Section::None;
                }
                continue;
            }
            let Some(item) = line.strip_prefix("- ") else { continue };
            match section {
                Section::Signals => {
                    if let Some((title, rest)) = item.split_once(": ") {
                        if SIGNALS.iter().any(|s| s.1 == title) && !prior.signals.contains_key(title) {
                            let verdict: String = rest.split(['.', '(']).next().unwrap_or("").trim().to_string();
                            prior.signals.insert(title.to_string(), verdict);
                        }
                    }
                }
                Section::Unmet => {
                    for status in ["missing", "partly met"] {
                        if let Some((key, _)) = item.rsplit_once(&format!(": {status}")) {
                            if !prior.unmet.iter().any(|(k, _)| k == key) {
                                prior.unmet.push((key.to_string(), status.to_string()));
                            }
                            break;
                        }
                    }
                }
                Section::Sensitive => prior.sensitive.push(item.split(": ").next().unwrap_or(item).to_string()),
                Section::None => {}
            }
        }
        (prior.level.is_some() || !prior.signals.is_empty()).then_some(prior)
    }
}

/// What a signal measures, as the posted review explains it (the prompt
/// says the same to claude).
fn meaning(key: &str) -> &'static str {
    match key {
        "impact" => "how much can behave differently at run time, and how much that matters (auth, payments, data, config weigh more), not how many files changed.",
        "rollback" => "whether a revert undoes it (low) or it's a one-way door such as a destructive migration or a sent message (high).",
        "detection" => "whether a failure would show in logs, monitoring or errors before users report it.",
        "verification" => "whether tests, screenshots or measurements show the behaviour that changes at run time works.",
        "alignment" => "whether every behaviour change is the one the PR and its issue describe, with nothing unmentioned.",
        _ => "",
    }
}

/// A collapsed section for a GitHub body: closed until clicked. The blank
/// lines let markdown inside it render.
fn details(summary: &str, lines: &[String]) -> Vec<String> {
    let mut out = vec![String::new(), format!("<details><summary>{summary}</summary>"), String::new()];
    // Never "- `": the body's findings are read back by that.
    out.extend(lines.iter().flat_map(|l| [l.clone(), String::new()]));
    out.push("</details>".into());
    out
}

// MARK: - Sensitive areas

#[derive(Clone, Debug, PartialEq)]
pub struct Sensitive {
    pub path: String,
    pub why: Option<String>,
}

/// The sensitive paths for `repo`: the harness's defaults and the repo's
/// section, then the repo's own file in its shared clone, when there is one.
pub fn sensitive_paths(harness: &Path, repo: &str) -> Vec<Sensitive> {
    let name = repo.rsplit('/').next().unwrap_or(repo);
    let read = |path: PathBuf| std::fs::read(path).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok());
    let entries = |v: &Value| -> Vec<Sensitive> {
        v["sensitive"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|e| match e {
                        Value::String(path) => Some(Sensitive { path: path.clone(), why: None }),
                        _ => Some(Sensitive { path: e["path"].as_str()?.to_string(), why: e["why"].as_str().map(str::to_string) }),
                    })
                    .collect()
            })
            .unwrap_or_default()
    };
    let mut all = Vec::new();
    if let Some(config) = read(harness.join(".gannin/review.json")) {
        all.extend(entries(&config["defaults"]));
        all.extend(entries(&config["repos"][repo]));
    }
    if let Some(config) = read(harness.join("projects").join(name).join(".gannin/review.json")) {
        all.extend(entries(&config));
    }
    let mut seen = std::collections::HashSet::new();
    all.retain(|s| seen.insert(s.path.clone()));
    all
}

/// Whether `path` is in `pattern`: a folder ending in `/` holds everything
/// under it; `*` matches within one folder, `**` across folders.
pub fn matches(pattern: &str, path: &str) -> bool {
    let pattern = pattern.trim().trim_start_matches("./");
    if pattern.is_empty() {
        return false;
    }
    if !pattern.contains('*') {
        return if pattern.ends_with('/') { path.starts_with(pattern) } else { path == pattern || path.starts_with(&format!("{pattern}/")) };
    }
    fn glob(p: &[u8], s: &[u8]) -> bool {
        match p {
            [] => s.is_empty(),
            [b'*', b'*', rest @ ..] => {
                let rest = rest.strip_prefix(b"/").unwrap_or(rest);
                (0..=s.len()).any(|i| glob(rest, &s[i..]))
            }
            [b'*', rest @ ..] => (0..=s.len()).take_while(|&i| i == 0 || s[i - 1] != b'/').any(|i| glob(rest, &s[i..])),
            [c, rest @ ..] => s.first() == Some(c) && glob(rest, &s[1..]),
        }
    }
    let pattern = if pattern.ends_with('/') { format!("{pattern}**") } else { pattern.to_string() };
    glob(pattern.as_bytes(), path.as_bytes())
}

/// The sensitive paths as the review prompt names them, after what
/// always counts: files coding agents load.
pub fn prompt_part(sensitive: &[Sensitive]) -> String {
    let agents = "\n\nA change to what coding agents load as instructions or context (AGENTS.md, CLAUDE.md, GEMINI.md, `.claude/`, Cursor and Copilot rules, skills, `.mcp.json`) is at least medium impact, however small and even with nothing changing at run time: it changes how every later session behaves and what each must read, so a person reviews it. Grade impact by that, and say in its reason which files and whether they add to what's loaded.";
    if sensitive.is_empty() {
        return agents.to_string();
    }
    let lines: Vec<String> = sensitive
        .iter()
        .map(|s| match &s.why {
            Some(why) => format!("- `{}`: {why}", s.path),
            None => format!("- `{}`", s.path),
        })
        .collect();
    format!("{agents}\n\nThe team marks these paths as sensitive. A change touching one is at least medium impact, whatever its size:\n{}", lines.join("\n"))
}

// MARK: - The grades reviews reached

fn store() -> &'static Mutex<HashMap<String, (Level, chrono::DateTime<chrono::Utc>)>> {
    static STORE: OnceLock<Mutex<HashMap<String, (Level, chrono::DateTime<chrono::Utc>)>>> = OnceLock::new();
    STORE.get_or_init(|| {
        // Reviews from earlier runs, from what each kept beside its session.
        let mut map = HashMap::new();
        for launch in crate::launch::saved().into_iter().filter(|l| l.flow == crate::launch::Flow::Review) {
            let Some(subject) = launch.subject.as_ref() else { continue };
            let Some(saved) = std::fs::read(launch.dir().join("risk.json")).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) else { continue };
            let (Some(level), Some(at)) = (saved["level"].as_str().and_then(Level::parse), saved["at"].as_str().and_then(|t| t.parse().ok())) else { continue };
            let entry = map.entry(subject.id.clone()).or_insert((level, at));
            if at > entry.1 {
                *entry = (level, at);
            }
        }
        Mutex::new(map)
    })
}

/// The latest grade a review gave the PR, by its node ID.
pub fn level_for(pr_id: &str) -> Option<Level> {
    store().lock().ok()?.get(pr_id).map(|e| e.0)
}

/// Keeps a review's grade, beside its session and for the table. Says
/// whether it changed what the table shows.
pub fn remember(pr_id: &str, session_dir: &Path, level: Level, at: chrono::DateTime<chrono::Utc>) -> bool {
    let _ = std::fs::write(session_dir.join("risk.json"), json!({ "level": level.title(), "at": at.to_rfc3339() }).to_string());
    let Ok(mut map) = store().lock() else { return false };
    match map.get(pr_id) {
        Some((old, when)) if *when > at || *old == level => false,
        _ => {
            map.insert(pr_id.to_string(), (level, at));
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn globs() {
        assert!(matches("db/migrations/", "db/migrations/001.sql"));
        assert!(matches("src/auth", "src/auth/login.rs"));
        assert!(!matches("src/auth", "src/authz.rs"));
        assert!(matches("**/*.sql", "a/b/c.sql"));
        assert!(matches("infra/*.tf", "infra/main.tf"));
        assert!(!matches("infra/*.tf", "infra/mod/main.tf"));
    }

    #[test]
    fn deltas() {
        let graded = |verification: &str| {
            parse(&serde_json::json!({ "risk": {
                "impact": { "verdict": "small", "reason": "One page." }, "rollback": "low", "detection": "good",
                "verification": { "verdict": verification, "reason": "Unit tests." }, "alignment": "good"
            }}))
            .unwrap()
        };
        let first = graded("decent").markdown().unwrap();
        // Nothing moved: one line, and the whole of it collapsed.
        let same = graded("decent").markdown_since(&first).unwrap();
        assert!(same.contains("**Merge risk: low, unchanged since the last review.**"));
        assert!(!same.contains("Since the last review:"));
        assert!(same.contains("<details><summary>The whole merge risk</summary>"));
        // Read back from a delta review too, through its collapsed copy.
        let moved = graded("poor").markdown_since(&same).unwrap();
        assert!(moved.contains("**Merge risk: medium (was low).**"));
        assert!(moved.contains("- Verification: poor (was decent). Unit tests"));
        assert!(!moved.contains("- Impact:  "));
        // No earlier merge risk: the full block.
        assert_eq!(graded("decent").markdown_since("Looks good."), Some(first));
    }

    #[test]
    fn grades() {
        let value = serde_json::json!({ "risk": {
            "alignment": { "verdict": "good" }, "impact": { "verdict": "small" },
            "verification": { "verdict": "poor" }, "rollback": { "verdict": "low" }, "detection": "decent"
        }});
        let risk = parse(&value).unwrap();
        // Exposure (2 + 1.5 + 2) / 4.5 = 1.22, low; confidence (6 + 1) / 3
        // = 2.33, poor: an untested change is a step up even when small.
        assert_eq!(risk.group_score(Group::Exposure), Some(1));
        assert_eq!(risk.group_score(Group::Confidence), Some(3));
        assert_eq!(risk.level(), Some(Level::Medium));
        let raised = risk.assessed(&["db/migrations/1.sql".into()], &[Sensitive { path: "db/migrations/".into(), why: None }]);
        let impact = raised.signals.iter().find(|s| s.key == "impact").unwrap();
        assert_eq!(impact.verdict.as_deref(), Some("medium"));
        // Medium exposure with poor confidence.
        assert_eq!(raised.level(), Some(Level::High));
    }

    #[test]
    fn exposure_sets_the_grade() {
        let grade = |impact: &str, rollback: &str, verification: &str| {
            parse(&serde_json::json!({ "risk": {
                "alignment": "good", "impact": impact, "verification": verification, "rollback": rollback, "detection": "decent"
            }}))
            .unwrap()
            .level()
        };
        // Some things are just risky: well tested, still never low.
        assert_eq!(grade("large", "high", "good"), Some(Level::Medium));
        assert_eq!(grade("large", "high", "decent"), Some(Level::High));
        // A small, revertable change isn't raised by tests a little thin.
        assert_eq!(grade("small", "low", "decent"), Some(Level::Low));
        // Nor is a medium one lowered by good tests.
        assert_eq!(grade("medium", "medium", "good"), Some(Level::Medium));
    }

    #[test]
    fn gaps_stay_out_of_the_body() {
        let risk = parse(&serde_json::json!({ "risk": {
            "impact": "small", "verification": "good", "gaps": ["A recording of the empty state"]
        }}))
        .unwrap();
        let body = risk.markdown().unwrap();
        assert!(body.contains("**Exposure: low**") && body.contains("**Confidence: good**"));
        assert!(!body.contains("empty state"));
        assert!(body.contains("> <details><summary>How exposure is worked out</summary>"));
        assert!(body.contains("Here (2×1) / 2 = 1.00"));
        assert!(body.contains("Here exposure is low and confidence good, so low."));
        // The body's findings are read back by "- `": the working never starts a line so.
        assert!(!body.lines().any(|l| l.trim_start_matches("> ").starts_with("- `")));
    }

    #[test]
    fn later_criteria_are_no_floor() {
        let value = serde_json::json!({
            "risk": { "alignment": { "verdict": "good" }, "impact": { "verdict": "small" }, "verification": { "verdict": "good" } },
            "criteria": [{ "criterion": "Checked on staging", "status": "later" }]
        });
        let risk = parse(&value).unwrap().assessed(&[], &[]);
        let verification = risk.signals.iter().find(|s| s.key == "verification").unwrap();
        assert_eq!(verification.verdict.as_deref(), Some("good"));
        assert_eq!(risk.level(), Some(Level::Low));
    }

    #[test]
    fn what_agents_load_is_never_low() {
        let value = serde_json::json!({ "risk": { "alignment": "good", "impact": "small", "verification": "good", "rollback": "low" } });
        assert_eq!(parse(&value).unwrap().assessed(&["src/a.ts".into()], &[]).level(), Some(Level::Low));
        // ctrl-hub/clients#2565: docs only, nothing at run time, still a person's.
        let risk = parse(&value).unwrap().assessed(&["base/ui/AGENTS.md".into(), ".claude/rules/storybook-a11y.md".into()], &[]);
        assert_eq!(risk.agent_context.len(), 2);
        assert_eq!(risk.level(), Some(Level::Medium));
        assert!(risk.markdown().unwrap().contains("**Changes what coding agents load**"));
        for path in ["AGENTS.md", "CLAUDE.md", "apps/web/CLAUDE.md", ".claude/skills/x/SKILL.md", ".github/copilot-instructions.md", ".cursor/rules/a.mdc"] {
            assert!(is_agent_context(path), "{path}");
        }
        for path in ["README.md", "docs/agents.md", "src/claude.rs"] {
            assert!(!is_agent_context(path), "{path}");
        }
    }
}
