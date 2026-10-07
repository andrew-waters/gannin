# Learnings

Rules and reasons people gave in review ("we do x because of y"), kept so that later reviews,
people's and Claude's, follow them rather than asking the same question again or suggesting what
they rule out. One file each, in a folder for the repo it's about:
`learnings/<repo>/YYYY-MM-DD-<slug>.md`, from `_template.md`.

| Field | What it holds |
| ----- | ------------- |
| `type` | `learning` |
| `status` | `active`, or `retired` once it no longer holds (kept, so the history shows why) |
| `summary` | The rule, in a sentence |
| `repo` | The repo it applies to, as `owner/name` |
| `paths` | Where in it: folders ending in `/`, files, or lines as `path#L10-L24`; none for the whole repo |
| `commit` | The commit line numbers were given at, since code moves |
| `source` | The comment it came from |
| `author` | The GitHub login of whoever gave it |
| `issues` | Optional: the PR or issue it came up in |

The body has `## Rule`, `## Reason` (why, as the person put it) and `## Source` (their words, quoted).

How Gannin uses them:

- Review with Claude gives the reviewer the active learnings for the PR's repo. It follows those
  whose scope covers the diff, lists the ones it applied and any doubts about them, and suggests
  new ones from what people explained in the PR. The review tab shows them on the diff, where each
  can be challenged (the reviewer looks again) or edited.
- Work on This lists those for the issue's repos in the session's brief.
- Save as Learning on a PR comment, a review thread or a reviewer's suggestion opens the editor.
  Nothing is committed until you say so.

Line numbers drift: reviewers check the code is still what the learning was about, and say when one
looks stale. Retire a learning rather than deleting it.
