# andrew-waters/gannin#401: Drag and Drop files to code sessions

https://github.com/andrew-waters/gannin/issues/401

- State: open
- Opened by: @andrew-waters, 17 Oct 2026

## Description

## Problem

When a session coding window is open, the agent may be running in a sandbox or on a remote machine. Dragging a file such as a screenshot into the terminal doesn't work there, because the file is on my machine and the agent can't read it. So I have no quick way to give the agent a screenshot or other file while I'm working in a session.

## Proposal

Add an attachments area to the session window's right pane, either as its own tab or as a section of an existing one, where:

- I can drop files (screenshots first, other files too) and they become available to the agent's environment, whether that is a sandbox or a remote machine.
- Each dropped item appears in a list. Clicking an item adds it to the current prompt.
- The list shows which items have already been sent to the agent, so I don't send the same thing twice.
- Ideally I can drop a file anywhere on the pane, without first opening a tab or finding a drop zone. The pane would show a drop target while I'm dragging.

## Where

Not yet known. I couldn't search the code while drafting this, so this issue doesn't name the component that renders the session window or its right pane. It also doesn't say how files currently reach a session's sandbox or remote host. Whoever picks this up should fill this section in first.

## Acceptance criteria

- [ ] Dropping one or more files onto the session window's right pane adds them to an attachments list, and no tab or drop area has to be opened first.
- [ ] Dropped files are uploaded to a place the agent can read in that session's environment, for both sandboxed and remote sessions.
- [ ] Clicking an attachment inserts a reference to it into the current prompt.
- [ ] Each attachment shows whether it has been sent, and this state updates once a prompt that includes it is submitted.
- [ ] Screenshots (PNG, JPEG) can be dropped and the agent can view them.
- [ ] Existing terminal behaviour doesn't change, including drag into the terminal where that already works locally.
- [ ] Existing right pane tabs work as they do today.

## Open questions

- Which component or app renders the session window and its right pane?
- How do files get into the session environment: an upload API in mono, a shared volume, or something else? Is there an existing mechanism to reuse?
- What does "add to prompt" insert: a file path in the agent's environment, an inline image, or some other reference?
- Should "sent" mean included in a submitted prompt, or just inserted into the prompt box?
- Do attachments last for the life of the session only, or longer? Is there a size or type limit?
- Should pasting from the clipboard (for example a screenshot copied with Cmd+Ctrl+Shift+4) also add to the tray?
- Should it be a dedicated tab or a section that is always visible in the pane?

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/401-drag-and-drop-files-to-code-sessions/`: give each repo it touches a worktree there, on the branch `401-drag-and-drop-files-to-code-sessions`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/401-drag-and-drop-files-to-code-sessions/<name>" -b 401-drag-and-drop-files-to-code-sessions origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/401-drag-and-drop-files-to-code-sessions/gannin" -b 401-drag-and-drop-files-to-code-sessions origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/401-drag-and-drop-files-to-code-sessions/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#401" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#401]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/401-drag-and-drop-files-to-code-sessions/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
