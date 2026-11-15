//! Whether a review window's review may approve by itself: the window's
//! rules, checked against the pull request as GitHub has it when the review
//! posts and against the review itself. An approve verdict that fails any
//! of them posts as a comment, with the reasons given.

use crate::review::{ReviewResult, Snapshot};
use serde::{Deserialize, Serialize};

/// A window's rules for approving. Off by default; each condition left
/// unset doesn't restrict.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ApproveRules {
    #[serde(default)]
    pub enabled: bool,
    /// Logins whose pull requests may be approved; empty is anyone.
    #[serde(default)]
    pub authors: Vec<String>,
    #[serde(default = "yes")]
    pub allow_bots: bool,
    /// Lines added plus removed.
    #[serde(default)]
    pub max_lines: Option<u32>,
    #[serde(default)]
    pub max_files: Option<u32>,
    /// Claude's effort, 1 to 5.
    #[serde(default)]
    pub max_effort: Option<i64>,
    /// No finding at or above this severity: blocker, major, minor or nit.
    #[serde(default)]
    pub block_severity: Option<String>,
    /// low or medium.
    #[serde(default)]
    pub max_risk: Option<String>,
}

fn yes() -> bool {
    true
}

impl Default for ApproveRules {
    fn default() -> Self {
        Self { enabled: false, authors: Vec::new(), allow_bots: true, max_lines: None, max_files: None, max_effort: None, block_severity: None, max_risk: None }
    }
}

/// What the rules are checked against about the pull request.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Facts {
    pub author: String,
    pub author_is_bot: bool,
    /// Lines added plus removed, when known.
    pub lines: Option<i64>,
    pub files: Option<i64>,
}

impl Facts {
    pub fn of(snapshot: &Snapshot) -> Self {
        Self {
            author: snapshot.author.clone(),
            author_is_bot: snapshot.author_is_bot,
            lines: snapshot.additions.zip(snapshot.deletions).map(|(a, d)| a + d),
            files: snapshot.changed_files,
        }
    }
}

/// blocker 0, major 1, minor 2, nit 3.
pub fn severity_rank(severity: &str) -> Option<u8> {
    match severity {
        "blocker" => Some(0),
        "major" => Some(1),
        "minor" => Some(2),
        "nit" => Some(3),
        _ => None,
    }
}

fn risk_rank(risk: &str) -> Option<u8> {
    match risk {
        "low" => Some(0),
        "medium" => Some(1),
        "high" => Some(2),
        _ => None,
    }
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

/// Ok when an approval may post as one; else why not, one reason per
/// condition that fails.
pub fn decide(rules: &ApproveRules, facts: &Facts, result: &ReviewResult) -> Result<(), Vec<String>> {
    if !rules.enabled {
        return Err(vec!["this window doesn't approve by itself".into()]);
    }
    let mut why = Vec::new();
    if facts.author_is_bot && !rules.allow_bots {
        why.push(format!("{} is a bot", facts.author));
    } else if !rules.authors.is_empty() && !rules.authors.iter().any(|a| a.eq_ignore_ascii_case(&facts.author)) {
        why.push(format!("{} isn't on the window's authors", facts.author));
    }
    if let Some(max) = rules.max_lines {
        match facts.lines {
            Some(n) if n > max as i64 => why.push(format!("{} changed, limit {max}", plural(n as usize, "line", "lines"))),
            Some(_) => {}
            None => why.push("lines changed unknown".into()),
        }
    }
    if let Some(max) = rules.max_files {
        match facts.files {
            Some(n) if n > max as i64 => why.push(format!("{} changed, limit {max}", plural(n as usize, "file", "files"))),
            Some(_) => {}
            None => why.push("files changed unknown".into()),
        }
    }
    if let Some(max) = rules.max_effort {
        match result.effort {
            Some(e) if e > max => why.push(format!("effort {e}, limit {max}")),
            Some(_) => {}
            None => why.push("the review gave no effort".into()),
        }
    }
    if let Some(at) = rules.block_severity.as_deref().and_then(severity_rank) {
        let mut hits: Vec<(u8, &str)> = result.findings.iter().filter_map(|f| f.severity.as_deref().and_then(|s| Some((severity_rank(s)?, s)))).filter(|(r, _)| *r <= at).collect();
        hits.sort();
        if let Some((_, worst)) = hits.first() {
            let n = hits.len();
            why.push(if n == 1 { format!("a {worst} finding") } else { format!("{n} findings, the worst {worst}") });
        }
    }
    if let Some(max) = rules.max_risk.as_deref() {
        match (result.risk.as_deref().and_then(risk_rank), risk_rank(max)) {
            (Some(r), Some(m)) if r > m => why.push(format!("{} risk, limit {max}", result.risk.as_deref().unwrap_or_default())),
            (Some(_), _) => {}
            (None, _) => why.push("the review gave no risk".into()),
        }
    }
    if why.is_empty() { Ok(()) } else { Err(why) }
}

/// The note for a window review that would have approved but commented.
pub fn commented_note(why: &[String]) -> String {
    format!("Commented, not approved: {}", why.join("; "))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::review::Finding;

    fn on() -> ApproveRules {
        ApproveRules { enabled: true, ..Default::default() }
    }

    fn facts() -> Facts {
        Facts { author: "alice".into(), author_is_bot: false, lines: Some(120), files: Some(4) }
    }

    fn result() -> ReviewResult {
        ReviewResult { verdict: Some("approve".into()), effort: Some(2), risk: Some("low".into()), ..Default::default() }
    }

    fn finding(severity: &str) -> Finding {
        Finding { path: "a.rs".into(), line: Some(1), comment: "x".into(), severity: Some(severity.into()), category: None, suggestion: None }
    }

    #[test]
    fn off_comments() {
        assert!(decide(&ApproveRules::default(), &facts(), &result()).is_err());
    }

    #[test]
    fn on_with_no_conditions_approves() {
        let bare = ReviewResult { verdict: Some("approve".into()), ..Default::default() };
        assert_eq!(decide(&on(), &Facts { lines: None, files: None, ..facts() }, &bare), Ok(()));
    }

    #[test]
    fn author_outside_the_list_comments() {
        let rules = ApproveRules { authors: vec!["Bob".into()], ..on() };
        assert_eq!(decide(&rules, &facts(), &result()), Err(vec!["alice isn't on the window's authors".into()]));
        let rules = ApproveRules { authors: vec!["ALICE".into()], ..on() };
        assert_eq!(decide(&rules, &facts(), &result()), Ok(()));
    }

    #[test]
    fn bots() {
        let bot = Facts { author: "dependabot[bot]".into(), author_is_bot: true, ..facts() };
        assert_eq!(decide(&on(), &bot, &result()), Ok(()));
        let rules = ApproveRules { allow_bots: false, ..on() };
        assert_eq!(decide(&rules, &bot, &result()), Err(vec!["dependabot[bot] is a bot".into()]));
    }

    #[test]
    fn lines_over_or_unknown_comment() {
        let rules = ApproveRules { max_lines: Some(100), ..on() };
        assert_eq!(decide(&rules, &facts(), &result()), Err(vec!["120 lines changed, limit 100".into()]));
        assert_eq!(decide(&rules, &Facts { lines: Some(100), ..facts() }, &result()), Ok(()));
        assert_eq!(decide(&rules, &Facts { lines: None, ..facts() }, &result()), Err(vec!["lines changed unknown".into()]));
    }

    #[test]
    fn files_over_or_unknown_comment() {
        let rules = ApproveRules { max_files: Some(3), ..on() };
        assert_eq!(decide(&rules, &facts(), &result()), Err(vec!["4 files changed, limit 3".into()]));
        assert_eq!(decide(&rules, &Facts { files: None, ..facts() }, &result()), Err(vec!["files changed unknown".into()]));
    }

    #[test]
    fn effort_over_or_missing_comments() {
        let rules = ApproveRules { max_effort: Some(1), ..on() };
        assert_eq!(decide(&rules, &facts(), &result()), Err(vec!["effort 2, limit 1".into()]));
        assert_eq!(decide(&rules, &facts(), &ReviewResult { effort: None, ..result() }), Err(vec!["the review gave no effort".into()]));
        assert_eq!(decide(&ApproveRules { max_effort: Some(2), ..on() }, &facts(), &result()), Ok(()));
    }

    #[test]
    fn findings_at_or_above_the_severity_comment() {
        let rules = ApproveRules { block_severity: Some("major".into()), ..on() };
        let minor = ReviewResult { findings: vec![finding("minor"), finding("nit")], ..result() };
        assert_eq!(decide(&rules, &facts(), &minor), Ok(()));
        let major = ReviewResult { findings: vec![finding("major")], ..result() };
        assert_eq!(decide(&rules, &facts(), &major), Err(vec!["a major finding".into()]));
        let both = ReviewResult { findings: vec![finding("major"), finding("blocker")], ..result() };
        assert_eq!(decide(&rules, &facts(), &both), Err(vec!["2 findings, the worst blocker".into()]));
        let any = ApproveRules { block_severity: Some("nit".into()), ..on() };
        assert!(decide(&any, &facts(), &minor).is_err());
    }

    #[test]
    fn risk_over_or_missing_comments() {
        let rules = ApproveRules { max_risk: Some("low".into()), ..on() };
        assert_eq!(decide(&rules, &facts(), &result()), Ok(()));
        let medium = ReviewResult { risk: Some("medium".into()), ..result() };
        assert_eq!(decide(&rules, &facts(), &medium), Err(vec!["medium risk, limit low".into()]));
        assert_eq!(decide(&ApproveRules { max_risk: Some("medium".into()), ..on() }, &facts(), &medium), Ok(()));
        assert_eq!(decide(&rules, &facts(), &ReviewResult { risk: None, ..result() }), Err(vec!["the review gave no risk".into()]));
    }

    #[test]
    fn every_failing_condition_is_given() {
        let rules = ApproveRules { max_lines: Some(10), max_effort: Some(1), ..on() };
        assert_eq!(decide(&rules, &facts(), &result()).unwrap_err().len(), 2);
    }

    #[test]
    fn a_window_saved_before_rules_loads_off() {
        let w: crate::schedule::ReviewWindow = serde_json::from_str(r#"{"id":"w","name":"Mornings","weekdays":[0],"start":540,"length":120}"#).unwrap();
        assert_eq!(w.approve, ApproveRules::default());
        assert!(w.approve.allow_bots);
    }

    #[test]
    fn the_global_setting_carries_over() {
        let mut s: crate::schedule::Schedule = serde_json::from_str(
            r#"{"settings":{"gap_minutes":30,"paused_all":false,"approve_by_itself":true,"reviews_at_once":2},"windows":[{"id":"w","name":"Mornings","weekdays":[0],"start":540,"length":120}]}"#,
        )
        .unwrap();
        s.migrate();
        assert!(s.windows[0].approve.enabled);
        assert!(!serde_json::to_string(&s).unwrap().contains("approve_by_itself"));
    }
}
