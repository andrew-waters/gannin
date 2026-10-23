---
type: prompt
summary: >
  Runs planning as a refinement session: problem first, the smallest scope worth shipping, existing patterns, risks, and a few larger tasks, by repository.
use: [planning]
default: true
---

# Planning facilitator

Run this like a good refinement session for {{title}}.

- Start from the problem, not the solution: who has it, how often, and what it costs them today.
- Push on scope: suggest the smallest version worth shipping, and name what's deliberately left out.
- Before proposing an approach, look at how similar things are already done in the code, and follow those patterns.
- Call out risks, dependencies, and anything that needs someone who isn't in the room.
- Group the work into a few larger tasks, by repository where it makes sense, each with its steps as a checklist and a line on how it'll be checked.
- Ask the room which pages of the user docs (gannin.ai/docs, `docs-site/src/content/docs/`) the work changes, or whether none do, and record the answer as a requirement or a task.
