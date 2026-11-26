//! What Agree writes from a planning session's state: the plan, following
//! the harness's STANDARDS.md (front matter, then the outcome first), the
//! requirement, and each issue's body. Pure, so the shapes are tested.
//!
//! The plan's Breakdown is a `- [ ]` checklist of the issues, so its
//! progress ring in Plans works as for any plan the team writes.

use crate::planning::{Comment, Made, State, Task};

/// Where things are and who agreed, for the documents.
pub struct Context<'a> {
    pub slug: &'a str,
    pub branch: &'a str,
    pub owner: &'a str,
    pub agreed_by: &'a [String],
    pub agreed_at: &'a str,
    /// The issue it was planned from, as "owner/repo#n".
    pub started_from: Option<&'a str>,
    pub parent: Option<&'a Made>,
    /// Each task's issue, by its title (an issue merged into the parent
    /// has the parent's).
    pub issues: &'a [(String, Made)],
    pub requirement_path: Option<&'a str>,
    /// Documents committed with it, by file name.
    pub assets: &'a [String],
    pub comments: &'a [Comment],
}

pub fn plan_path(date: &str, slug: &str) -> String {
    format!("plans/{date}-{slug}.md")
}

pub fn requirement_path(slug: &str) -> String {
    format!("requirements/{slug}.md")
}

pub fn assets_dir(slug: &str) -> String {
    format!("plans/assets/{slug}")
}

/// A link to a file in the harness, on its default branch.
pub fn harness_url(harness: &str, path: &str) -> String {
    format!("https://github.com/{harness}/blob/HEAD/{path}")
}

fn yaml(text: &str) -> String {
    let flat = text.replace('\n', " ");
    let special = flat.contains(": ") || flat.contains(" #") || flat.ends_with(':') || flat.contains(['"', '[', ']', '{', '}', ',']);
    if flat.is_empty() || special || flat.starts_with(['-', '?', ' ', '#', '\'', '&', '*', '!', '|', '>', '%', '@', '`']) {
        format!("\"{}\"", flat.replace('\\', "\\\\").replace('"', "\\\""))
    } else {
        flat
    }
}

fn yaml_list(items: &[String]) -> String {
    format!("[{}]", items.iter().map(|i| yaml(i)).collect::<Vec<_>>().join(", "))
}

fn bullets(out: &mut Vec<String>, items: &[String]) {
    out.extend(items.iter().map(|i| format!("- {i}")));
}

fn section(out: &mut Vec<String>, heading: &str) {
    if out.last().is_some_and(|l| !l.is_empty()) {
        out.push(String::new());
    }
    out.push(heading.to_string());
    out.push(String::new());
}

fn issue_of<'a>(ctx: &'a Context, task: &Task) -> Option<&'a Made> {
    ctx.issues.iter().find(|(title, _)| title.eq_ignore_ascii_case(task.title.trim())).map(|(_, m)| m)
}

/// The plan, `plans/<date>-<slug>.md`.
pub fn plan(state: &State, ctx: &Context) -> String {
    let mut touches: Vec<String> = state.tasks.iter().map(|t| t.repo.clone()).chain(state.scouting.iter().map(|f| f.repo.clone())).filter(|r| !r.is_empty()).collect();
    touches.sort();
    touches.dedup();
    let mut issues: Vec<String> = ctx.parent.map(|p| p.reference()).into_iter().collect();
    for (_, made) in ctx.issues {
        let r = made.reference();
        if !issues.contains(&r) {
            issues.push(r);
        }
    }
    let title = if state.title.is_empty() { "Plan" } else { state.title.as_str() };
    let mut out = vec![
        "---".to_string(),
        "type: plan".to_string(),
        "status: agreed".to_string(),
        format!("summary: {}", yaml(&state.summary)),
        format!("issues: {}", yaml_list(&issues)),
        format!("touches: {}", yaml_list(&touches)),
        format!("owner: {}", yaml(ctx.owner)),
        format!("agreed_by: {}", yaml_list(ctx.agreed_by)),
        format!("agreed_at: {}", ctx.agreed_at),
    ];
    if let Some(path) = ctx.requirement_path {
        out.push(format!("requirement: {path}"));
    }
    let architecture: Vec<String> = state.architecture.iter().filter(|a| a.valid()).map(|a| a.path.trim().to_string()).collect();
    if !architecture.is_empty() {
        out.push(format!("architecture: {}", yaml_list(&architecture)));
    }
    out.push(format!("branch: {}", ctx.branch));
    out.push("---".to_string());
    out.push(String::new());
    out.push(format!("# {title}"));
    if !state.summary.is_empty() {
        out.push(String::new());
        out.push(state.summary.clone());
    }
    if let Some(from) = ctx.started_from {
        out.push(String::new());
        out.push(format!("Started from {from}."));
    }

    let o = &state.outcome;
    section(&mut out, "## Outcome");
    if !o.change.is_empty() {
        out.push(o.change.clone());
    }
    if !o.measures.is_empty() {
        out.push(String::new());
        out.push("**How we'll know**".into());
        out.push(String::new());
        for m in &o.measures {
            out.push(format!("- {}: {}{}", m.id, m.text, if m.target.is_empty() { String::new() } else { format!(" (target: {})", m.target) }));
        }
    }
    for (label, text) in [("If we don't", &o.if_not), ("The smallest version that proves it", &o.smallest)] {
        if !text.is_empty() {
            out.push(String::new());
            out.push(format!("**{label}:** {text}"));
        }
    }
    if !o.premortem.is_empty() {
        out.push(String::new());
        out.push("**If it fails, it'll be because**".into());
        out.push(String::new());
        bullets(&mut out, &o.premortem);
    }

    if !ctx.assets.is_empty() {
        section(&mut out, "## Context");
        for name in ctx.assets {
            out.push(format!("- [{name}](assets/{}/{})", ctx.slug, name.replace(' ', "%20")));
        }
    }

    let r = &state.requirement;
    section(&mut out, "## Requirement");
    for (label, text) in [("Problem", &r.problem), ("Goal", &r.goal), ("Who it's for", &r.users)] {
        if !text.is_empty() {
            out.push(format!("**{label}:** {text}"));
            out.push(String::new());
        }
    }
    if !r.scope.is_empty() {
        out.push("**In scope**".into());
        out.push(String::new());
        bullets(&mut out, &r.scope);
        out.push(String::new());
    }
    if !r.non_goals.is_empty() {
        out.push("**Out of scope**".into());
        out.push(String::new());
        bullets(&mut out, &r.non_goals);
        out.push(String::new());
    }
    if !r.acceptance.is_empty() {
        out.push("**Acceptance criteria**".into());
        out.push(String::new());
        for c in &r.acceptance {
            out.push(format!("- **{}** {}", c.id, c.text));
        }
    }
    if out.last().is_some_and(|l| l.is_empty()) {
        out.pop();
    }

    section(&mut out, "## Design");
    out.push(if state.approach.is_empty() { "No approach written.".to_string() } else { state.approach.clone() });
    for (kind, heading) in [("area", "Areas it touches"), ("pattern", "Patterns to follow"), ("risk", "Risks")] {
        let found: Vec<String> = state
            .scouting
            .iter()
            .filter(|f| f.kind.eq_ignore_ascii_case(kind))
            .map(|f| match f.url() {
                Some(url) => format!("[{}:{}]({url}): {}", f.repo, f.path, f.note),
                None => f.note.clone(),
            })
            .collect();
        if !found.is_empty() {
            out.push(String::new());
            out.push(format!("**{heading}**"));
            out.push(String::new());
            bullets(&mut out, &found);
        }
    }

    let changes: Vec<String> = state.architecture.iter().filter(|a| a.valid()).map(|a| format!("[{0}](../{0}){1}{2}", a.path.trim(), if a.new { " (new)" } else { "" }, if a.note.is_empty() { String::new() } else { format!(": {}", a.note) })).collect();
    if !changes.is_empty() {
        out.push(String::new());
        out.push("**Architecture it changes** (marked planned until the work ships)".to_string());
        out.push(String::new());
        bullets(&mut out, &changes);
    }

    section(&mut out, "## Breakdown");
    if !state.size_reason.is_empty() {
        out.push(format!("{} {}", if state.size.is_empty() { String::new() } else { format!("As {} {}:", article(&state.size), state.size) }, state.size_reason).trim().to_string());
        out.push(String::new());
    }
    let line = |t: &Task, indent: &str| {
        let made = issue_of(ctx, t).map(|m| format!("[{}]({}) ", m.reference(), m.url)).unwrap_or_default();
        let satisfies = if t.satisfies.is_empty() { String::new() } else { format!(" (satisfies {})", t.satisfies.join(", ")) };
        format!("{indent}- [ ] {made}{}{satisfies}", t.title)
    };
    for epic in state.epics() {
        out.push(line(epic, ""));
        for t in state.issues().filter(|t| t.parent.trim().eq_ignore_ascii_case(epic.title.trim())) {
            out.push(line(t, "  "));
        }
    }
    for t in state.issues().filter(|t| !state.epics().any(|e| e.title.trim().eq_ignore_ascii_case(t.parent.trim()))) {
        out.push(line(t, ""));
    }

    if !state.decisions.is_empty() {
        section(&mut out, "## Decisions");
        for d in &state.decisions {
            out.push(format!("- {}: {}{}", d.question, d.answer, if d.stage.is_empty() { String::new() } else { format!(" ({})", d.stage) }));
        }
    }
    if !ctx.comments.is_empty() {
        section(&mut out, "## From the room");
        for c in ctx.comments {
            out.push(format!("- On {}: {}", c.stage, c.text));
        }
    }
    if !r.open_questions.is_empty() {
        section(&mut out, "## Open questions");
        bullets(&mut out, &r.open_questions);
    }
    out.push(String::new());
    out.join("\n")
}

fn article(word: &str) -> &'static str {
    if word.starts_with(['a', 'e', 'i', 'o', 'u']) {
        "an"
    } else {
        "a"
    }
}

/// The requirement, `requirements/<slug>.md`.
pub fn requirement(state: &State, plan_path: &str, issues: &[String]) -> String {
    let r = &state.requirement;
    let mut out = vec![
        "---".to_string(),
        "type: requirement".to_string(),
        "status: agreed".to_string(),
        format!("summary: {}", yaml(&state.summary)),
        format!("issues: {}", yaml_list(issues)),
        format!("plans: [{plan_path}]"),
        "---".to_string(),
        String::new(),
        format!("# {}", if state.title.is_empty() { "Requirement" } else { state.title.as_str() }),
    ];
    for (heading, text) in [("## Problem", &r.problem), ("## Goal", &r.goal), ("## Who it's for", &r.users)] {
        if !text.is_empty() {
            section(&mut out, heading);
            out.push(text.clone());
        }
    }
    if !state.outcome.measures.is_empty() {
        section(&mut out, "## How we'll know");
        for m in &state.outcome.measures {
            out.push(format!("- {}: {}{}", m.id, m.text, if m.target.is_empty() { String::new() } else { format!(" (target: {})", m.target) }));
        }
    }
    if !r.scope.is_empty() {
        section(&mut out, "## Requirements");
        bullets(&mut out, &r.scope);
    }
    if !r.non_goals.is_empty() {
        section(&mut out, "## Out of scope");
        bullets(&mut out, &r.non_goals);
    }
    if !r.acceptance.is_empty() {
        section(&mut out, "## Acceptance criteria");
        for c in &r.acceptance {
            out.push(format!("- **{}** {}", c.id, c.text));
        }
    }
    if !r.open_questions.is_empty() {
        section(&mut out, "## Open questions");
        bullets(&mut out, &r.open_questions);
    }
    out.push(String::new());
    out.join("\n")
}

/// An issue's body: the work, what it satisfies, how it'll be checked,
/// what it needs first (as lines the PR dependency view reads), and the
/// plan it came from.
pub fn issue_body(task: &Task, state: &State, depends_on: &[String], plan: (&str, &str)) -> String {
    let mut out = Vec::new();
    if !task.body.trim().is_empty() {
        out.push(task.body.trim().to_string());
    }
    let satisfied: Vec<String> = task
        .satisfies
        .iter()
        .map(|id| match state.requirement.acceptance.iter().find(|c| c.id.eq_ignore_ascii_case(id)) {
            Some(c) => format!("- **{}** {}", c.id, c.text),
            None => format!("- {id}"),
        })
        .collect();
    if !satisfied.is_empty() {
        section(&mut out, "**Satisfies**");
        out.extend(satisfied);
    }
    if !task.test_plan.trim().is_empty() {
        section(&mut out, "**How it'll be checked**");
        out.push(task.test_plan.trim().to_string());
    }
    if !depends_on.is_empty() || !task.estimate.is_empty() {
        out.push(String::new());
        for d in depends_on {
            out.push(format!("Depends on: {d}"));
        }
        if !task.estimate.is_empty() {
            out.push(format!("Size: {}", task.estimate));
        }
    }
    out.push(String::new());
    out.push(format!("From the plan [{}]({}).", plan.0, plan.1));
    out.join("\n")
}

/// The work as it goes in the parent's own body when the plan is one
/// issue, between markers so writing it again replaces it.
pub fn merge_into(body: &str, plan_path: &str, work: &str) -> String {
    let start = format!("<!-- gannin-plan: {plan_path} -->");
    let end = "<!-- /gannin-plan -->";
    let block = format!("{start}\n## The plan\n\n{work}\n{end}");
    match (body.find(&start), body.find(end)) {
        (Some(a), Some(b)) if b > a => format!("{}{block}{}", &body[..a], &body[b + end.len()..]),
        _ if body.trim().is_empty() => block,
        _ => format!("{}\n\n{block}", body.trim_end()),
    }
}

/// An architecture document as Agree commits it: its front matter's
/// `planned_by` lists the plan, so the planned parts can be traced to it
/// and made current when its work ships. Added once, however often it's
/// written.
pub fn mark_planned(text: &str, plan_path: &str) -> String {
    let item = format!("  - {plan_path}");
    let Some(rest) = text.strip_prefix("---\n") else {
        return format!("---\ntype: architecture\nplanned_by:\n{item}\n---\n\n{text}");
    };
    let Some(end) = rest.find("\n---") else { return text.to_string() };
    let (front, body) = (&rest[..end], &rest[end..]);
    let mut lines: Vec<String> = front.lines().map(str::to_string).collect();
    match lines.iter().position(|l| l.starts_with("planned_by:")) {
        Some(at) => {
            let value = lines[at]["planned_by:".len()..].trim().to_string();
            let mut items: Vec<String> = match value.strip_prefix('[').and_then(|v| v.strip_suffix(']')) {
                Some(inline) => inline.split(',').map(|p| p.trim().trim_matches('"').to_string()).filter(|p| !p.is_empty()).collect(),
                None if !value.is_empty() => vec![value.trim_matches('"').to_string()],
                None => Vec::new(),
            };
            let mut next = at + 1;
            while next < lines.len() && lines[next].trim_start().starts_with("- ") {
                items.push(lines[next].trim_start()[2..].trim().trim_matches('"').to_string());
                next += 1;
            }
            if !items.iter().any(|p| p == plan_path) {
                items.push(plan_path.to_string());
            }
            let replaced: Vec<String> = std::iter::once("planned_by:".to_string()).chain(items.iter().map(|p| format!("  - {p}"))).collect();
            lines.splice(at..next, replaced);
        }
        None => {
            lines.push("planned_by:".to_string());
            lines.push(item);
        }
    }
    format!("---\n{}{body}", lines.join("\n"))
}

/// A stand-in for an architecture document claude didn't leave in the
/// folder, for the preview's rehearsal only: a real Agree never writes
/// over a document it hasn't read.
pub fn architecture_stub(change: &crate::planning::ArchChange) -> String {
    let name = change.path.trim().trim_start_matches("architecture/").trim_end_matches(".md").replace('-', " ");
    format!("---\ntype: architecture\nstatus: current\nsummary: {}\n---\n\n# {name}\n\n```mermaid\n{}\n```\n", yaml(&change.note), change.diagram.trim())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::planning::{Criterion, Measure};

    fn made(key: &str, n: i64) -> Made {
        Made { key: key.into(), id: format!("I_{n}"), repo: "o/r".into(), number: n, url: format!("https://github.com/o/r/issues/{n}") }
    }

    fn state() -> State {
        let mut s = State { title: "Failure alerts".into(), summary: "Ops see failed jobs: fast".into(), size: "epic".into(), size_reason: "two repos".into(), ..Default::default() };
        s.outcome.change = "Ops see a failed job within a minute".into();
        s.outcome.measures = vec![Measure { id: "M1".into(), text: "Time to notice".into(), target: "under 1m".into() }];
        s.requirement.problem = "Nobody notices".into();
        s.requirement.acceptance = vec![Criterion { id: "R1".into(), text: "When a job fails, the system shall alert".into() }];
        s.approach = "A webhook.".into();
        s.tasks = vec![
            Task { title: "Alerts".into(), level: "epic".into(), repo: "o/r".into(), ..Default::default() },
            Task { title: "Send it".into(), parent: "Alerts".into(), repo: "o/r".into(), satisfies: vec!["R1".into()], test_plan: "A failing job in staging".into(), estimate: "M".into(), body: "- [ ] Hook".into(), ..Default::default() },
        ];
        s
    }

    #[test]
    fn the_plan_follows_the_standard() {
        let s = state();
        let issues = vec![("Alerts".to_string(), made("t:alerts", 10)), ("Send it".to_string(), made("t:send it", 11))];
        let by = vec!["aw".to_string()];
        let ctx = Context {
            slug: "failure-alerts",
            branch: "plan-failure-alerts",
            owner: "aw",
            agreed_by: &by,
            agreed_at: "2026-11-24T10:00:00Z",
            started_from: None,
            parent: None,
            issues: &issues,
            requirement_path: Some("requirements/failure-alerts.md"),
            assets: &["notes.pdf".to_string()],
            comments: &[],
        };
        let md = plan(&s, &ctx);
        assert!(md.starts_with("---\ntype: plan\nstatus: agreed\nsummary: \"Ops see failed jobs: fast\"\nissues: [o/r#10, o/r#11]\ntouches: [o/r]"));
        assert!(md.contains("\n## Outcome\n\nOps see a failed job within a minute\n"));
        assert!(md.contains("- M1: Time to notice (target: under 1m)"));
        assert!(md.contains("- [notes.pdf](assets/failure-alerts/notes.pdf)"));
        // The epic, its issue under it, each a checkbox for the progress ring.
        assert!(md.contains("- [ ] [o/r#10](https://github.com/o/r/issues/10) Alerts\n  - [ ] [o/r#11](https://github.com/o/r/issues/11) Send it (satisfies R1)"));
        assert!(md.contains("As an epic: two repos"));
        let req = requirement(&s, "plans/2026-11-24-failure-alerts.md", &["o/r#10".into()]);
        assert!(req.contains("type: requirement") && req.contains("- **R1** When a job fails"));
    }

    #[test]
    fn architecture_is_marked_planned_once() {
        let doc = "---\ntype: architecture\nsummary: Jobs\n---\n\n# Jobs\n";
        let once = mark_planned(doc, "plans/a.md");
        assert_eq!(once, "---\ntype: architecture\nsummary: Jobs\nplanned_by:\n  - plans/a.md\n---\n\n# Jobs\n");
        assert_eq!(mark_planned(&once, "plans/a.md"), once);
        let two = mark_planned(&once, "plans/b.md");
        assert!(two.contains("planned_by:\n  - plans/a.md\n  - plans/b.md\n---"));
        let inline = mark_planned("---\nplanned_by: [plans/x.md]\ntitle: T\n---\nBody", "plans/a.md");
        assert_eq!(inline, "---\nplanned_by:\n  - plans/x.md\n  - plans/a.md\ntitle: T\n---\nBody");
        assert!(mark_planned("# No front matter", "plans/a.md").starts_with("---\ntype: architecture\nplanned_by:\n  - plans/a.md\n---\n\n# No front matter"));
    }

    #[test]
    fn an_issue_body_and_merging() {
        let s = state();
        let body = issue_body(&s.tasks[1], &s, &["o/api#4".into()], ("Failure alerts", "https://x/plan.md"));
        assert!(body.starts_with("- [ ] Hook\n\n**Satisfies**\n\n- **R1** When a job fails"));
        assert!(body.contains("**How it'll be checked**\n\nA failing job in staging"));
        assert!(body.contains("\nDepends on: o/api#4\nSize: M\n"));
        let once = merge_into("Original.", "plans/p.md", "- [ ] A");
        assert!(once.starts_with("Original.\n\n<!-- gannin-plan: plans/p.md -->"));
        let twice = merge_into(&once, "plans/p.md", "- [ ] B");
        assert!(twice.contains("- [ ] B") && !twice.contains("- [ ] A"));
    }
}
