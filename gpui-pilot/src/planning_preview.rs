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
        for stage in [Stage::Outcome, Stage::Requirements, Stage::Design, Stage::Breakdown] {
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
