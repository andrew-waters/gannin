# Decisions

Decision records (ADRs): one decision the team made, and why, so someone new can understand it
without asking. One file each, `YYYY-MM-DD-<slug>.md`, from `_template.md`, with the front matter
`STANDARDS.md` sets out. Gannin's Harness › Onboarding puts accepted decisions first in each
area, and folds superseded and rejected ones away.

| Field | What it holds |
| ----- | ------------- |
| `type` | `decision` |
| `status` | `proposed`, `accepted`, `rejected` or `superseded` |
| `summary` | The decision, in a sentence or two |
| `domains` | The areas it belongs to, the main one first |
| `superseded_by` | For a superseded decision, the path of the one that replaced it |
| `plans` | The plans it came from, by path |
| `key` | `true` to put it at the top of its area on the Onboarding map |
| `issues` | The issues it's about, as `owner/repo#123` |

Don't rewrite an accepted decision when things change: write a new one, and mark the old one
`superseded` with `superseded_by` pointing at it.
