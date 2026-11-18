//! Merge risk: how dangerous merging a PR is, apart from how much is wrong
//! with it. Claude grades five signals in the review JSON (`risk`) and
//! checks the linked issues' acceptance criteria (`criteria`); the overall
//! grade is worked out here, with fixed weights, so it's stable and can be
//! explained. Two floors claude can't argue past: a change touching a path
//! the team marks sensitive is at least medium impact, and a missing
//! acceptance criterion makes verification poor.
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

/// The five signals, in the order they're shown: key, title, weight, and
/// the verdicts from good to bad.
pub const SIGNALS: [(&str, &str, f32, [&str; 3]); 5] = [
    ("alignment", "Alignment", 1.0, ["good", "decent", "poor"]),
    ("impact", "Impact", 2.0, ["small", "medium", "large"]),
    ("verification", "Verification", 2.0, ["good", "decent", "poor"]),
    ("rollback", "Rollback cost", 1.5, ["low", "medium", "high"]),
    ("detection", "Error detection", 1.0, ["good", "decent", "poor"]),
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
        let verdicts = SIGNALS.iter().find(|s| s.0 == self.key)?.3;
        verdicts.iter().position(|v| Some(*v) == self.verdict.as_deref()).map(|i| i as u8 + 1)
    }

    fn weight(&self) -> f32 {
        SIGNALS.iter().find(|s| s.0 == self.key).map(|s| s.2).unwrap_or(1.0)
    }

    /// Raises the verdict to at least `floor` (1 to 3), saying why.
    fn floor(&mut self, floor: u8, why: String) {
        let verdicts = SIGNALS.iter().find(|s| s.0 == self.key).map(|s| s.3).unwrap_or(["", "", ""]);
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
    /// met, partial, missing or untestable.
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
        .map(|(key, title, _, _)| {
            let entry = &risk[*key];
            // A bare string is the verdict alone.
            let verdict = text(&entry["verdict"]).or_else(|| text(entry)).map(|v| v.to_lowercase());
            Signal { key: *key, title: *title, verdict, reason: text(&entry["reason"]), raised: None }
        })
        .collect();
    let gaps = risk["gaps"].as_array().map(|a| a.iter().filter_map(text).collect()).unwrap_or_default();
    Some(Risk { signals, gaps, criteria, sensitive: Vec::new() })
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

    /// Weighted mean of the known signals: low under 1.5, high from 2.25.
    /// None until at least verification and impact are known.
    pub fn level(&self) -> Option<Level> {
        let known: Vec<(f32, f32)> = self.signals.iter().filter_map(|s| s.score().map(|score| (score as f32, s.weight()))).collect();
        let has = |key: &str| self.signals.iter().any(|s| s.key == key && s.score().is_some());
        if !has("impact") || !has("verification") {
            return None;
        }
        let total: f32 = known.iter().map(|(_, w)| w).sum();
        let mean = known.iter().map(|(s, w)| s * w).sum::<f32>() / total;
        Some(if mean < 1.5 {
            Level::Low
        } else if mean < 2.25 {
            Level::Medium
        } else {
            Level::High
        })
    }

    /// The one thing to look at before merging: the signal adding most to
    /// the risk.
    pub fn next_step(&self) -> String {
        match self.level() {
            None => "Not enough to grade it.".into(),
            Some(Level::Low) => "Safe to merge once the findings are dealt with.".into(),
            Some(_) => {
                let worst = self.signals.iter().filter(|s| s.score().is_some_and(|s| s > 1)).max_by(|a, b| {
                    let weigh = |s: &Signal| s.score().unwrap_or(0) as f32 * s.weight();
                    weigh(a).partial_cmp(&weigh(b)).unwrap_or(std::cmp::Ordering::Equal)
                });
                match worst {
                    Some(s) => format!("Look at {} before merging.", s.title.to_lowercase()),
                    None => "Look it over before merging.".into(),
                }
            }
        }
    }
}

impl Risk {
    /// The merge risk as it goes in the posted review's body: the grade and
    /// what to look at, each signal graded with why, the acceptance
    /// criteria not met, the sensitive paths touched, and what would bring
    /// it down. None when there's nothing graded to say.
    pub fn markdown(&self) -> Option<String> {
        let graded: Vec<&Signal> = self.signals.iter().filter(|s| s.verdict.as_deref().is_some_and(|v| v != "n/a")).collect();
        if graded.is_empty() && self.criteria.is_empty() {
            return None;
        }
        let mut out = vec![match self.level() {
            Some(level) => format!("{} **Merge risk: {}.** {}", level.emoji(), level.title(), self.next_step()),
            None => "**Merge risk:** not enough to grade it.".to_string(),
        }];
        if !graded.is_empty() {
            out.push(String::new());
            for s in graded {
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
        if !self.gaps.is_empty() {
            out.push(String::new());
            out.push("**To bring it down**".into());
            out.extend(self.gaps.iter().map(|g| format!("- {g}")));
        }
        // A GitHub alert, so it's marked off from the review beneath: its
        // colour follows the grade.
        let kind = match self.level() {
            Some(Level::Low) => "TIP",
            Some(Level::Medium) => "WARNING",
            Some(Level::High) => "CAUTION",
            None => "NOTE",
        };
        let mut alert = vec![format!("> [!{kind}]")];
        alert.extend(out.iter().map(|line| if line.is_empty() { ">".to_string() } else { format!("> {line}") }));
        Some(alert.join("\n"))
    }
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

/// The sensitive paths as the review prompt names them; empty when none.
pub fn prompt_part(sensitive: &[Sensitive]) -> String {
    if sensitive.is_empty() {
        return String::new();
    }
    let lines: Vec<String> = sensitive
        .iter()
        .map(|s| match &s.why {
            Some(why) => format!("- `{}`: {why}", s.path),
            None => format!("- `{}`", s.path),
        })
        .collect();
    format!("\n\nThe team marks these paths as sensitive. A change touching one is at least medium impact, whatever its size:\n{}", lines.join("\n"))
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
    fn grades() {
        let value = serde_json::json!({ "risk": {
            "alignment": { "verdict": "good" }, "impact": { "verdict": "small" },
            "verification": { "verdict": "poor" }, "rollback": { "verdict": "low" }, "detection": "decent"
        }});
        let risk = parse(&value).unwrap();
        // (1 + 2 + 6 + 1.5 + 2) / 7.5 = 1.67
        assert_eq!(risk.level(), Some(Level::Medium));
        let raised = risk.assessed(&["db/migrations/1.sql".into()], &[Sensitive { path: "db/migrations/".into(), why: None }]);
        assert_eq!(raised.signals[1].verdict.as_deref(), Some("medium"));
    }
}
