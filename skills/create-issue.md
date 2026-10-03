---
type: skill
name: create-issue
description: >
  Draft a GitHub issue the team's way, check it isn't a duplicate, create it with gh once the user has confirmed it, then link it to its parent and the workflow board; use when a session, plan or conversation turns up work that needs its own issue.
repos: all
---

# Create an issue

## Context

Use this when work needs an issue of its own: a follow-up found while working on another issue, a step broken out of a plan or requirement in this harness, a bug spotted in review, or something the user asks you to raise. This skill files the issue and gets it to where the team triages it. It does not start work on it. Starting work is Gannin's Work on This, and opening a PR for finished work is `skills/create-pull-request.md`.

Gannin can also create issues itself (Write Issue from a Prioritisation note, Draft Issues on a plan or requirement). Use this skill when you're in a Claude Code session and the issue comes up there.

Arguments (ask for anything missing that you can't work out):

- **What**: the problem or change, in the user's words or from the plan or finding it comes from.
- **Repo** (optional): `owner/name`. If not given, suggest one: the repo the work touches, the repo of the issue this session is working on, or one a plan's `touches` names.
- **Parent** (optional): an issue it belongs under, as `owner/name#123`. If you're in a session, the session's own issue is a likely parent. Check with the user before using it.
- **Source** (optional): the harness document it comes from (`plans/...`, `requirements/...`, `findings/...`).

## Steps

1. **Pick the repo.** Confirm `owner/name` with the user if you inferred it. The shared clones live in `projects/<name>` in the harness root.

2. **Check for duplicates.** Search open and recently closed issues with the key words from the title:
   ```bash
   gh issue list --repo OWNER/NAME --state all --limit 20 --search "KEY WORDS"
   ```
   Also search the harness for the topic (`grep -ril "KEY WORDS" plans requirements findings`), since a plan may already name an issue for it. If you find a likely match, show it to the user and ask whether to comment on it instead. Stop here if they say so.

3. **Read the repo's issue template, if it has one.** Look in `projects/<name>/.github/ISSUE_TEMPLATE/` (or `gh api repos/OWNER/NAME/contents/.github/ISSUE_TEMPLATE`). If there is a template, follow its sections. Otherwise use this shape:
   ```markdown
   ## Problem
   What's wrong or missing, and who it affects.

   ## Proposal
   What should change. Leave out the how unless it's already decided.

   ## Acceptance
   - [ ] Checkable outcomes

   ## Context
   Links: parent issue, harness document (owner/name:path), PRs, findings.
   ```
   TODO(andrew-waters): confirm the team's preferred issue body if it differs from this.

4. **Draft the title, body and labels.** Make the title short and specific, a statement of the outcome rather than a task list. Refer to issues as `owner/name#123` so Gannin and the harness link them. Only use labels that already exist in the repo (`gh label list --repo OWNER/NAME`). Don't create labels.

5. **Choose the investment category.** TODO(andrew-waters): say how this org tracks investments (Gannin Settings > How we track investments): in Gannin (nothing to write here), GitHub labels (add the category's label in step 4), or a single-select field on a board (set it in step 8). List the categories and their labels or options here.

6. **Show the user the draft and get confirmation.** Show the repo, title, body, labels, parent and board in full. Create nothing until they say yes. Apply their edits and show it again if they changed anything significant.

7. **Create it.** Write the body to a temporary file so quoting can't mangle it:
   ```bash
   gh issue create --repo OWNER/NAME --title "TITLE" --body-file /tmp/issue-body.md --label "LABEL"
   ```
   Note the URL it prints.

8. **Put it on the workflow board.** Add it to the org's workflow board (the board Gannin's Issue workflow setting picks) and **leave Status empty**. Gannin's Prioritisation triage list is open issues with no Status on that board, so the team will see it there.
   ```bash
   gh project item-add BOARD_NUMBER --owner OWNER --url ISSUE_URL
   ```
   The workflow board's owner and number. This needs gh's `project` scope (`gh auth refresh -s project`). If the investment category is a board field, set it now with `gh project item-edit`, after looking up the field and option IDs with `gh project field-list BOARD_NUMBER --owner OWNER --format json`.

9. **Link it to its parent** (if there is one) as a sub-issue:
   ```bash
   PARENT=$(gh issue view PARENT_NUMBER --repo PARENT_OWNER/PARENT_NAME --json id -q .id)
   CHILD=$(gh issue view NEW_NUMBER --repo OWNER/NAME --json id -q .id)
   gh api graphql -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){subIssue{number}}}' -f p="$PARENT" -f c="$CHILD"
   ```

10. **Point the harness at it** (only if it came from a harness document). Offer to add `owner/name#N` to that document's front matter `issues:` list. Do this only if the user agrees, as a separate harness commit, and don't touch anything else in the file.

11. **Report back.** Give the issue URL, its labels, whether it's on the board and under which parent, and anything you skipped.

## Rules

- Every GitHub write (create, board, parent link, labels) is confirmed by the user first, as Gannin does. One confirmation for the whole drafted set in step 6 is enough. Ask again if you change something afterwards.
- One issue per piece of work. If the draft has several independent outcomes, propose splitting it, and use a parent issue only if the user wants one.
- Never create labels, board fields or options. If something you need is missing, say so and leave it off.
- Don't set a Status on the board, assign anyone or set a milestone unless the user asks. Triage decides those.
- Don't paste secrets, customer personal data, tokens or log output with credentials into the body. Summarise, and link to where it lives.
- Don't start work on the new issue from this skill.
- Writing: plain language, no em or en dashes, and issues referenced as `owner/name#123`.
