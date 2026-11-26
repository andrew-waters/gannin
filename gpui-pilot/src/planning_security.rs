//! A planning session's security review: the shape and the design, read by
//! a second model (Fable unless the room picks another), before the room
//! can approve the design. It runs headless and read only, in the harness
//! (its `projects/` clones and `architecture/` are what it may read), here
//! or on the session's server, and is kept beside the session as
//! `security.json`. Its findings go to the planning session's claude,
//! which answers each in `design.security`: the design can't be approved
//! while a high or medium finding has no answer.

use crate::planning::State;
use serde::{Deserialize, Serialize};
use std::path::Path;

/// The models the room can pick, by Claude Code's model id: the first is
/// the default.
pub const MODELS: [(&str, &str); 3] = [("claude-fable-5-2", "Fable 5.2"), ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5")];

pub fn model_name(id: &str) -> &str {
    MODELS.iter().find(|(m, _)| *m == id).map(|(_, n)| *n).unwrap_or(id)
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Finding {
    /// SEC1, SEC2 and so on.
    pub id: String,
    /// high, medium or low.
    pub severity: String,
    pub title: String,
    pub detail: String,
    /// Where: a flow, a screen, a part of the design or a path in the code.
    #[serde(rename = "where")]
    pub place: String,
    pub recommendation: String,
}

impl Finding {
    /// High and medium findings need an answer before the design's approved.
    pub fn blocking(&self) -> bool {
        matches!(self.severity.to_lowercase().as_str(), "high" | "medium")
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Review {
    pub model: String,
    pub at: Option<chrono::DateTime<chrono::Utc>>,
    /// The shape and design it read, to say when they've changed since.
    pub fingerprint: String,
    pub findings: Vec<Finding>,
    pub error: Option<String>,
}

impl Review {
    pub fn load(dir: &Path) -> Option<Review> {
        serde_json::from_slice(&std::fs::read(dir.join("security.json")).ok()?).ok()
    }

    pub fn save(&self, dir: &Path) {
        if let Ok(bytes) = serde_json::to_vec_pretty(self) {
            let _ = std::fs::write(dir.join("security.json"), bytes);
        }
    }

    /// Ran, and came back with findings (maybe none).
    pub fn done(&self) -> bool {
        self.at.is_some() && self.error.is_none()
    }

    /// The high and medium findings claude hasn't answered.
    pub fn unanswered<'a>(&'a self, state: &State) -> Vec<&'a Finding> {
        self.findings.iter().filter(|f| f.blocking() && !state.security.iter().any(|a| a.id.eq_ignore_ascii_case(&f.id))).collect()
    }
}

/// What the review read: the shape and the design, not claude's answers
/// to it.
pub fn fingerprint(state: &State) -> String {
    use std::hash::{Hash, Hasher};
    let fields = serde_json::to_string(&(&state.shape.flows, &state.shape.screens, &state.approach, &state.architecture)).unwrap_or_default();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    fields.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

/// Why the design can't be approved yet, as far as the review goes.
pub fn unmet(review: Option<&Review>, state: &State) -> Vec<String> {
    match review {
        None => vec!["Run the security review.".to_string()],
        Some(r) if !r.done() => vec!["Run the security review again: it didn't finish.".to_string()],
        Some(r) => r.unanswered(state).iter().map(|f| format!("Claude hasn't answered {} ({}): {}.", f.id, f.severity.to_lowercase(), f.title.trim_end_matches('.'))).collect(),
    }
}

/// The review's prompt: what it's for, then the plan so far as JSON.
pub fn prompt(state: &State) -> String {
    let plan = serde_json::json!({
        "title": state.title,
        "summary": state.summary,
        "outcome": state.outcome,
        "requirement": state.requirement,
        "shape": { "flows": state.shape.flows, "screens": state.shape.screens.iter().map(|s| serde_json::json!({ "id": s.id, "title": s.title, "flow": s.flow, "criteria": s.criteria, "wireframe": s.wireframe })).collect::<Vec<_>>() },
        "design": { "approach": state.approach, "architecture": state.architecture },
        "found_in_the_code": state.scouting,
    });
    format!(
        r#"You're the security reviewer for a plan a team is agreeing before anything is built. Review its shape (the flows and screens) and its design for security and privacy problems, while they're cheap to fix.

You're in the team's harness. The code is in `projects/<name>` and the team's architecture documents are in `architecture/`: read what you need to check the design against what exists. Read only: change nothing.

Look for, where they apply:
- Who can do what: authentication, authorisation, and actions one person can take on another's data.
- Where data comes in from outside (people, webhooks, other services) and how it's validated.
- Trust boundaries the design crosses that it didn't before, and new connections between systems.
- Personal and sensitive data: what's collected, where it's kept, who sees it, how long it's kept, what's logged.
- Secrets and credentials, and how they reach what needs them.
- Abuse: replay, flooding, enumeration, spoofed callbacks.
- What a failure or a partial rollout exposes.

Only raise what's real for this plan, and say where: a flow or screen id, a part of the design, or a path in the code. high: exploitable or exposes data as designed. medium: a gap the design should close before it's built. low: worth doing, not blocking. Recommend the smallest change that fixes it.

Answer with only this JSON, nothing before or after it:
{{"findings": [{{"id": "SEC1", "severity": "high" | "medium" | "low", "title": "a line", "detail": "what's wrong and why it matters", "where": "F1, S2, the design or owner/repo:path", "recommendation": "what to change"}}]}}

An empty list is the right answer when there's nothing real.

The plan:
{}"#,
        serde_json::to_string_pretty(&plan).unwrap_or_default()
    )
}

/// The findings in claude's answer: the JSON object in it, wherever it is.
pub fn parse(text: &str) -> Result<Vec<Finding>, String> {
    let (Some(start), Some(end)) = (text.find('{'), text.rfind('}')) else { return Err(format!("it didn't answer with findings: {}", text.trim())) };
    let value: serde_json::Value = serde_json::from_str(&text[start..=end]).map_err(|e| format!("its answer wasn't JSON: {e}"))?;
    let mut findings: Vec<Finding> = value["findings"].as_array().map(|a| a.iter().filter_map(|f| serde_json::from_value(f.clone()).ok()).collect()).unwrap_or_default();
    for (i, f) in findings.iter_mut().enumerate() {
        if f.id.trim().is_empty() {
            f.id = format!("SEC{}", i + 1);
        }
    }
    Ok(findings)
}

/// Runs the review: claude once, read only, in the harness, here or on
/// the server. Blocks: call off the main thread.
pub fn run(prompt: &str, model: &str, harness: &Path, server: Option<&crate::servers::Server>) -> Result<Vec<Finding>, String> {
    use base64::Engine;
    let args = ["-p", "--model", model, "--tools", "Read,Grep,Glob", "--strict-mcp-config", "--no-session-persistence", "--output-format", "json"];
    let quoted: Vec<String> = args.iter().map(|a| quote(a)).collect();
    let encoded = base64::engine::general_purpose::STANDARD.encode(prompt);
    let script = format!(
        "unset CLAUDECODE\nfor name in $(env | sed -n 's/^\\(CLAUDE_CODE_[A-Za-z0-9_]*\\)=.*/\\1/p'); do unset \"$name\"; done\ncd {} || {{ echo 'The harness is not there.' >&2; exit 1; }}\ncommand -v claude >/dev/null 2>&1 || {{ echo 'Claude Code is not installed here.' >&2; exit 127; }}\nprintf %s '{encoded}' | base64 -d | claude {}\n",
        quote(&harness.to_string_lossy()),
        quoted.join(" ")
    );
    let output = match server {
        Some(server) => crate::servers::script(server, &script)?,
        None => {
            let out = std::process::Command::new(crate::paths::shell()).args(["-l", "-c", &script]).output().map_err(|e| format!("couldn't start claude: {e}"))?;
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            if !out.status.success() && !stdout.contains('{') {
                let err = String::from_utf8_lossy(&out.stderr);
                return Err(err.lines().filter(|l| !l.trim().is_empty()).last().unwrap_or("it gave nothing back").to_string());
            }
            stdout
        }
    };
    // A login shell may print first: the result is the last JSON line.
    let result = output.lines().rev().find_map(|l| serde_json::from_str::<serde_json::Value>(l.trim()).ok().filter(|v| v.is_object())).ok_or_else(|| "it gave nothing back".to_string())?;
    let text = result["result"].as_str().unwrap_or_default();
    if result["is_error"].as_bool() == Some(true) {
        return Err(if text.is_empty() { "it stopped with an error".to_string() } else { text.to_string() });
    }
    parse(text)
}

fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// The message to the planning session's claude with what came back.
pub fn message(review: &Review) -> String {
    let name = model_name(&review.model);
    if review.findings.is_empty() {
        return format!("From the security review ({name}): nothing found in the shape or the design. Record that as a decision.");
    }
    let list: Vec<String> = review
        .findings
        .iter()
        .map(|f| format!("{} ({}): {}. {} Where: {}. Recommends: {}", f.id, f.severity.to_lowercase(), f.title.trim_end_matches('.'), f.detail.trim(), f.place.trim(), f.recommendation.trim()))
        .collect();
    format!(
        "From the security review ({name}), of the shape and the design: {}. Answer each one: change the design where it's right, or say why not, and record each answer in `design.security` as {{\"id\": ..., \"response\": ...}}. The room can't approve the design until every high and medium one has an answer.",
        list.join(" | ")
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::planning::SecurityAnswer;

    #[test]
    fn planning_security_findings_need_answers() {
        let text = "Here you go:\n```json\n{\"findings\": [{\"severity\": \"high\", \"title\": \"Anyone can rerun\", \"where\": \"S2\"}, {\"id\": \"SEC2\", \"severity\": \"low\", \"title\": \"Log less\"}]}\n```";
        let findings = parse(text).unwrap();
        assert_eq!(findings[0].id, "SEC1");
        assert_eq!(findings[0].place, "S2");
        let review = Review { model: MODELS[0].0.into(), at: Some(chrono::Utc::now()), findings, ..Default::default() };
        let mut state = State::default();
        assert_eq!(unmet(Some(&review), &state).len(), 1, "only the high one blocks");
        state.security.push(SecurityAnswer { id: "sec1".into(), response: "Only on call can rerun.".into() });
        assert!(unmet(Some(&review), &state).is_empty());
        assert_eq!(unmet(None, &state), vec!["Run the security review.".to_string()]);
        assert!(message(&review).starts_with("From the security review (Fable 5.2)"));
    }
}
