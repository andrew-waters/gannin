# Workflows for Work on This: design

Builds on Gannin's workflows (`.gannin/agent-workflows.json` and `specialists/<name>.md` in the harness,
plus each person's own on this Mac), so the Swift app and this one share them. What's new is that a
workflow follows the whole life of a piece of work, and replaces pair review with a local review gate
that any workflow can set up.

## Stages, in order

1. **Prepare.** Read-only steps that run once before the session starts (a scout that maps the code, a
   planner). What they write goes into the session's brief.
2. **Session.** The implementer: the Claude Code session you can talk to. Exactly one step.
3. **Local review (a gate).** Steps that check the work in the worktree before it leaves this Mac:
   - Reviewers (Claude Code specialists, or a one-shot CLI such as Junie), read only. Their findings go
     to the session; it fixes what it agrees with and answers the rest, then the reviewers look again.
   - Commands (`npm test`, `cargo clippy -- -D warnings`), which must pass.
   - A hook holds `git push` and `gh pr create` until the gate is clear for the current commit. Push
     Anyway overrides it, from the session's panel.
   - What holds the gate: blockers and majors must be fixed or answered; minors and nits go to the
     session once, as suggestions, without another round. The rounds have a cap (and time and cost caps).
4. **On the PR.** Steps on the pull request once it's open: reviewers (as Gannin's steps after the session
   run today), and dealing with the bots' comments (CodeRabbit and the like) in the session.
5. **Done.** The PR is open, its checks pass, and the bots' comments are dealt with. A scheduler sequence
   waits for this before starting its next item.

## The session knows the gate

The session's brief lists what the local review will hold it to before it runs: each command, exactly
as it will run, and that reviewers will look at the change before it's pushed. So it runs the commands
itself as it works, and isn't surprised by them at the end.

## In the app

- **The work session** shows its workflow as a strip across the top: each stage with how it's going
  (Prepare done, Session working, Local review round 2 with 1 blocker, and so on). A stage opens its
  detail in the side panel: what Prepare found, each local round's findings and what the session did with
  each (fixed, with its commit, or answered, with its reason), each command's last result, and the PR's
  reviewers and bot comments.
- **Picking one:** Work on This, starting several, and scheduled issue starts and sequences each take a
  workflow, defaulting to the one routing gives the issue.
- **The editor** lays a workflow out as its five stages, each a column of step cards. A step is set in an
  inspector: its specialist (or Gannin's own prompt), its provider (Claude Code, a one-shot CLI, or a
  command), model and focus, rounds, and for a gate what holds it. Routing rules and the most passes it
  can make sit beneath, as in Gannin's editor.

## Storage

- Team workflows and specialists stay in the harness, in the same file and folder. A stage gets a
  `"when"` (`prepare`, `session`, `local`, `pr`), and a step can be a `"command"`. Steps without a
  `"when"` keep their meaning today: before the session step they prepare, after it they're on the PR.
- The Swift app ignores the new keys, so it treats a local review step as one on the PR, and skips
  command steps. That's the cost of sharing the file until it learns them.

## Mock first

Previews gets a Workflows page (the editor, with a few made-up workflows), and the Work Preview gets the
workflow strip and its stage detail, in states including a gate holding the push and a failing command.
