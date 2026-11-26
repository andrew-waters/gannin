//! A planning session to try without Claude Code or GitHub: a made-up plan
//! ("Tell ops when a scheduled job fails") that moves on as the room
//! approves it, as claude would. "Claude Answers" fills in the stage it's
//! on. Agree writes nothing: it shows the issues it would file and the plan
//! it would commit. Run with `--planning-preview`, in its own window and
//! process, beside a running Gannin; what it keeps goes in a temporary
//! folder, cleared each time.

use crate::planning::{Stage, State};
use serde_json::{json, Value};

pub const TOPIC: &str = "Tell ops when a scheduled job fails";

/// Where the preview keeps its approvals and what Agree "made".
pub fn dir() -> std::path::PathBuf {
    std::env::temp_dir().join("gannin-planning-preview")
}

/// A stand-in launch: nothing runs, and nothing is read from it but names.
pub fn launch() -> crate::launch::Launch {
    crate::launch::Launch::new(crate::launch::Flow::Plan, format!("Plan: {TOPIC}"), "acme", "acme/harness", "plan-tell-ops-when-a-scheduled-job-fails".into(), None)
}

/// The org's issue types, as GitHub would list them.
pub fn types() -> Vec<(String, String)> {
    ["Initiative", "Epic", "Task", "Bug", "Feature"].iter().map(|t| (format!("IT_{}", t.to_lowercase()), t.to_string())).collect()
}

/// The plan as it stands on `stage`: everything before it settled, and
/// `stage` itself only begun, or answered when `answered`.
pub fn state(stage: Stage, answered: bool) -> State {
    let at = stage.index();
    let done = |s: Stage| s.index() < at || (s.index() == at && answered);
    let mut v = json!({
        "title": "Failed job alerts",
        "summary": "When a scheduled job fails, the people on call hear about it within a minute, with what failed and a way to rerun it.",
        "phase": stage.key(),
        "outcome": {
            "change": "Ops on call find out about a failed scheduled job within a minute, from Slack, instead of from a customer the next morning."
        },
        "requirement": {},
        "design": {},
        "scouting": [],
        "tasks": [],
        "decisions": [],
        "done": stage == Stage::Agree
    });
    if done(Stage::Outcome) {
        v["outcome"] = json!({
            "change": "Ops on call find out about a failed scheduled job within a minute, from Slack, instead of from a customer the next morning.",
            "measures": [
                { "id": "M1", "text": "Time from a job failing to someone acknowledging it", "target": "under 5 minutes, from 9 hours today" },
                { "id": "M2", "text": "Failures first reported by customers", "target": "none in a month" }
            ],
            "if_not": "Billing exports keep failing overnight unnoticed; last quarter that was 4 late invoice runs.",
            "smallest": "One Slack message per failure, for the billing jobs only, with a link to the run.",
            "premortem": ["Alerts are so noisy for flaky jobs that people mute the channel.", "Nobody owns the channel out of hours."]
        });
        v["decisions"].as_array_mut().unwrap().push(json!({ "question": "Who's it for?", "answer": "Whoever's on call, not the job's author.", "stage": "outcome" }));
    }
    if stage.index() >= Stage::Requirements.index() {
        v["requirement"] = json!({ "problem": "Scheduled jobs fail silently: the scheduler logs it and nobody reads the log." });
    }
    if done(Stage::Requirements) {
        v["requirement"] = json!({
            "problem": "Scheduled jobs fail silently: the scheduler logs it and nobody reads the log.",
            "goal": "Every failure reaches the person on call, once, with enough to act on.",
            "users": "Ops on call; job owners as a second line.",
            "scope": ["Alert on any scheduled job's failure", "Group repeated failures of one job", "Rerun from the alert"],
            "non_goals": ["Alerting on slow jobs", "Paging (PagerDuty) in this version"],
            "acceptance": [
                { "id": "R1", "text": "When a scheduled job fails, the system shall post to the on-call Slack channel within 60 seconds." },
                { "id": "R2", "text": "When the same job fails again within an hour, the system shall add to the first message, not post a new one." },
                { "id": "R3", "text": "When someone presses Rerun in the message, the system shall start the job again and say who did." },
                { "id": "R4", "text": "When a job is marked quiet, the system shall not alert for it." }
            ],
            "open_questions": ["Does the billing team want its own channel?"]
        });
    }
    if stage.index() >= Stage::Shape.index() {
        v["shape"] = json!({
            "tools": { "node": true, "browser": false, "note": "No headless browser here, so no screenshots of a running mock: `npx playwright install chromium` adds one." },
            "flows": [{ "id": "F1", "title": "On call hears about a failure", "kind": "journey", "criteria": ["R1", "R2", "R3"],
                "diagram": "flowchart LR\n  fail([A billing job fails]) --> post[Alert in #ops-on-call]\n  post --> again{Fails again within the hour?}\n  again -->|yes| count[The alert counts it]\n  again -->|no| look[On call opens the run]\n  count --> look\n  look --> rerun[Presses Rerun]\n  rerun --> who[The alert says who reran it]" }],
            "screens": [],
            "mock": { "kind": "wireframes" }
        });
    }
    if done(Stage::Shape) {
        v["shape"]["flows"].as_array_mut().unwrap().push(json!({ "id": "F2", "title": "From a failed run to Slack", "kind": "process", "criteria": ["R1", "R2", "R4"],
            "diagram": "sequenceDiagram\n  participant S as Scheduler\n  participant N as Notifier\n  participant R as Redis\n  participant K as Slack\n  S->>N: run.finished (failed)\n  N->>N: Skip if the job is quiet\n  N->>R: First failure this hour?\n  alt first\n    N->>K: Post the alert\n  else repeat\n    N->>K: Update the alert's count\n  end" }));
        v["shape"]["screens"] = json!([
            { "id": "S1", "title": "The alert in Slack", "flow": "F1", "criteria": ["R1", "R2"], "image": "shape/S1.svg" },
            { "id": "S2", "title": "After Rerun", "flow": "F1", "criteria": ["R3"], "image": "shape/S2.svg" },
            { "id": "S3", "title": "The job page's Quiet switch", "flow": "F2", "criteria": ["R4"], "image": "shape/S3.svg" }
        ]);
        v["decisions"].as_array_mut().unwrap().push(json!({ "question": "Wireframes or a running mock?", "answer": "Wireframes: the Slack message is the product, and there's no browser here.", "stage": "shape" }));
    }
    if stage.index() >= Stage::Design.index() {
        v["scouting_now"] = json!({ "why": "How the scheduler reports a run's end", "paths": ["acme/scheduler:src/runner.rs"] });
    }
    if done(Stage::Design) {
        v["scouting_now"] = Value::Null;
        v["design"] = json!({ "approach": "The scheduler already emits a `run.finished` event (see `runner.rs`). Add a **notifier** in `acme/notify` that subscribes to it and posts failures to Slack through the existing Slack client.\n\n- Group by job and hour, keyed in Redis, so a repeat edits the first message.\n- Rerun is a Slack action that calls the scheduler's existing `POST /runs` with the job's id.\n- A `quiet` flag on the job, set from the web app's job page.\n\nRolls out behind the `job_alerts` flag, billing jobs first.",
            "architecture": [{
                "path": "architecture/job-runs.md",
                "note": "A notifier joins: it hears run.finished, posts failures to Slack and takes reruns back to the scheduler.",
                "diagram": "flowchart LR\n  scheduler[Scheduler] -->|run.finished| bus[(Event bus)]\n  bus --> notifier[Notifier]:::planned\n  notifier -->|failure| slack[Slack]:::planned\n  slack -->|Rerun| notifier\n  notifier -->|POST /runs| scheduler\n  notifier --> redis[(Redis: grouping)]:::planned\n  classDef planned stroke-dasharray: 5 5"
            }] });
        v["scouting"] = json!([
            { "kind": "area", "repo": "acme/scheduler", "path": "src/runner.rs#L88-L120", "note": "Where a run ends and `run.finished` is sent." },
            { "kind": "pattern", "repo": "acme/notify", "path": "src/slack/client.rs", "note": "The Slack client the deploy notices use: reuse it, with its retry." },
            { "kind": "risk", "repo": "acme/scheduler", "path": "src/jobs/flaky.rs", "note": "Three jobs fail most nights and retry themselves: they'd flood the channel." }
        ]);
        v["decisions"].as_array_mut().unwrap().push(json!({ "question": "Slack or email?", "answer": "Slack: on call lives there.", "stage": "design" }));
    }
    if stage.index() >= Stage::Breakdown.index() {
        v["size"] = json!("epic");
        v["size_reason"] = json!("Three repos ship toward one outcome, each separately reviewable.");
    }
    if done(Stage::Breakdown) {
        v["tasks"] = json!([
            { "title": "Failed job alerts", "level": "epic", "repo": "acme/notify", "body": "Alerts for failed scheduled jobs, to the on-call channel." },
            { "title": "Post a failed run to Slack, grouped by job", "parent": "Failed job alerts", "repo": "acme/notify", "satisfies": ["R1", "R2"], "estimate": "M",
              "body": "- [ ] Subscribe to `run.finished`\n- [ ] Post failures with the job, the error and a link to the run\n- [ ] Group repeats within an hour in one message",
              "test_plan": "Fail a job twice in staging: one message, updated once." },
            { "title": "Rerun a job from its alert", "parent": "Failed job alerts", "repo": "acme/scheduler", "satisfies": ["R3"], "estimate": "S", "depends_on": ["Post a failed run to Slack, grouped by job"],
              "body": "- [ ] Accept a rerun from the Slack action\n- [ ] Record who asked", "test_plan": "Press Rerun in staging: the job runs and the message names who pressed it." },
            { "title": "Mark a job quiet", "parent": "Failed job alerts", "repo": "acme/web", "satisfies": ["R4"], "estimate": "S",
              "body": "- [ ] A Quiet switch on the job page\n- [ ] Stored on the job", "test_plan": "A quiet job fails in staging: no message." }
        ]);
    } else if stage == Stage::Breakdown {
        v["tasks"] = json!([{ "title": "Failed job alerts", "level": "epic", "repo": "acme/notify" }]);
    }
    State::parse(&v)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_stage_answered_meets_its_criteria() {
        for stage in [Stage::Outcome, Stage::Requirements, Stage::Shape, Stage::Design, Stage::Breakdown] {
            assert!(!state(stage, false).unmet(stage).is_empty(), "{stage:?} begun");
            assert!(state(stage, true).unmet(stage).is_empty(), "{stage:?} answered: {:?}", state(stage, true).unmet(stage));
        }
    }
}

/// The question claude would be waiting on while a stage is begun.
pub fn question(stage: Stage) -> Option<crate::work_panel::Question> {
    let (header, question, options): (&str, &str, [(&str, &str, bool); 3]) = match stage {
        Stage::Outcome => ("Measure", "How will you know it worked?", [
            ("Time to acknowledge a failure", "From the job failing to someone on call saying they've got it.", true),
            ("Fewer customer reports", "Failures customers tell us about first.", false),
            ("Alerts sent", "Counts activity, not whether anyone noticed: hard to call it working.", false),
        ]),
        Stage::Requirements => ("Repeats", "A flaky job fails five times in an hour. What should on call see?", [
            ("One message, updated", "The first message counts the repeats.", true),
            ("A message each time", "Simple, but noisy for flaky jobs.", false),
            ("Nothing after the first", "Quiet, but hides that it's still failing.", false),
        ]),
        Stage::Shape => ("Screens", "How far should the screens go?", [
            ("Wireframes", "Quick SVGs of each screen: what's on it and in what order.", true),
            ("A running mock", "The real app on a throwaway branch with mocked data. Needs a headless browser, and this machine has none.", false),
            ("Text only", "Describe each screen in words.", false),
        ]),
        Stage::Design => ("Where", "Where should the alerting live?", [
            ("A notifier in acme/notify", "Next to the Slack client the deploy notices already use.", true),
            ("Inside the scheduler", "Fewer moving parts, but the scheduler gains Slack.", false),
            ("A new service", "Clean, but one more thing to run.", false),
        ]),
        Stage::Breakdown => ("Size", "This touches three repos toward one outcome. File it as an epic?", [
            ("An epic with three issues", "One per repo, each reviewable on its own.", true),
            ("One issue", "Simpler to track, but one large PR across repos.", false),
            ("An initiative", "More than this needs.", false),
        ]),
        Stage::Agree => return None,
    };
    Some(crate::work_panel::Question {
        header: header.into(),
        question: question.into(),
        multi: false,
        options: options.iter().map(|(l, d, r)| (l.to_string(), d.to_string(), *r)).collect(),
    })
}

/// The preview's screens, as the wireframes claude would draw: written to
/// `shape/` in the preview's folder, which is returned.
pub fn write_screens(dir: &std::path::Path) -> std::path::PathBuf {
    let shape = dir.join("shape");
    let _ = std::fs::create_dir_all(&shape);
    let frame = |body: &str| {
        format!(
            r##"<svg xmlns="http://www.w3.org/2000/svg" width="480" height="300" viewBox="0 0 480 300" font-family="Helvetica, Arial, sans-serif"><rect width="480" height="300" fill="#ffffff"/>{body}</svg>"##
        )
    };
    let slack = |title: &str, lines: &[&str], buttons: &[&str]| {
        let mut body = String::from(r##"<rect x="0" y="0" width="90" height="300" fill="#3f0e40"/><text x="12" y="28" fill="#ffffff" font-size="12">#ops-on-call</text><rect x="110" y="24" width="34" height="34" rx="6" fill="#d0d4da"/><text x="154" y="36" font-size="12" font-weight="bold" fill="#1d1c1d">Job alerts</text><text x="226" y="36" font-size="10" fill="#8a8a8a">APP  09:14</text>"##);
        body.push_str(&format!(r##"<rect x="154" y="46" width="4" height="{}" fill="#e01e5a"/><text x="166" y="62" font-size="13" font-weight="bold" fill="#1d1c1d">{title}</text>"##, 30 + lines.len() * 18));
        for (i, line) in lines.iter().enumerate() {
            body.push_str(&format!(r##"<text x="166" y="{}" font-size="11" fill="#1d1c1d">{line}</text>"##, 82 + i * 18));
        }
        let y = 96 + lines.len() * 18;
        let mut x = 166;
        for b in buttons {
            let w = 14 + b.len() * 7;
            body.push_str(&format!(r##"<rect x="{x}" y="{y}" width="{w}" height="26" rx="4" fill="#ffffff" stroke="#b8b8b8"/><text x="{}" y="{}" font-size="11" fill="#1d1c1d">{b}</text>"##, x + 7, y + 17));
            x += w + 8;
        }
        frame(&body)
    };
    let screens = [
        ("S1.svg", slack("billing-export failed", &["exit 1: timeout talking to the ledger", "Failed 3 times in the last hour", "Run #4821 on worker-2"], &["Open the Run", "Rerun", "Mark Quiet"])),
        ("S2.svg", slack("billing-export failed", &["exit 1: timeout talking to the ledger", "Failed 3 times in the last hour", "Rerun by Sam at 09:16: running now"], &["Open the Run"])),
        (
            "S3.svg",
            frame(r##"<rect x="0" y="0" width="480" height="40" fill="#f2f3f5"/><text x="16" y="25" font-size="13" font-weight="bold" fill="#1d1c1d">Jobs / billing-export</text><text x="16" y="70" font-size="12" fill="#5a5a5a">Schedule</text><text x="120" y="70" font-size="12" fill="#1d1c1d">Every night at 02:00</text><text x="16" y="100" font-size="12" fill="#5a5a5a">Owner</text><text x="120" y="100" font-size="12" fill="#1d1c1d">Billing</text><text x="16" y="130" font-size="12" fill="#5a5a5a">Alerts</text><rect x="120" y="116" width="40" height="20" rx="10" fill="#d0d4da"/><circle cx="131" cy="126" r="8" fill="#ffffff"/><text x="170" y="131" font-size="12" fill="#1d1c1d">Quiet: no alerts for this job</text><text x="120" y="156" font-size="10" fill="#8a8a8a">For jobs that fail and retry on their own.</text><rect x="16" y="190" width="448" height="1" fill="#e2e2e2"/><text x="16" y="216" font-size="12" fill="#5a5a5a">Last runs</text><text x="120" y="216" font-size="12" fill="#1d1c1d">Failed, failed, succeeded</text>"##),
        ),
    ];
    for (name, svg) in screens {
        let _ = std::fs::write(shape.join(name), svg);
    }
    dir.to_path_buf()
}

/// What the preview's security review finds.
pub fn security_findings() -> Vec<crate::planning_security::Finding> {
    let f = |id: &str, severity: &str, title: &str, detail: &str, place: &str, recommendation: &str| crate::planning_security::Finding {
        id: id.into(),
        severity: severity.into(),
        title: title.into(),
        detail: detail.into(),
        place: place.into(),
        recommendation: recommendation.into(),
    };
    vec![
        f("SEC1", "high", "Anyone in the channel can rerun any job", "Rerun calls the scheduler's POST /runs with the notifier's own token, so whoever can press the button can start billing-export, whether or not they may run it.", "S2, acme/scheduler:src/api/runs.rs", "Map the Slack user to a person and check they may run the job before calling /runs; record who it was."),
        f("SEC2", "medium", "Job errors can carry customer data into Slack", "billing-export's errors include the invoice it failed on, with the customer's email. Posting the raw error puts that in a channel with 40 members and Slack's retention.", "S1, F2", "Post the job, the time and a link to the run; keep the error behind the link."),
        f("SEC3", "low", "Slack action requests should be verified", "The design doesn't say the Rerun callback checks Slack's signature.", "The design", "Verify the signing secret on every action, as the deploy notices already do."),
    ]
}

/// Claude's answers to the preview's findings.
pub fn security_answers() -> Vec<crate::planning::SecurityAnswer> {
    vec![
        crate::planning::SecurityAnswer { id: "SEC1".into(), response: "Rerun now checks the Slack user against who may run the job, and records them. Added to the design.".into() },
        crate::planning::SecurityAnswer { id: "SEC2".into(), response: "The alert carries the job, the time and a link; the error stays behind the link. S1 updated.".into() },
        crate::planning::SecurityAnswer { id: "SEC3".into(), response: "Every action verifies the signing secret, reusing the deploy notices' check.".into() },
    ]
}
