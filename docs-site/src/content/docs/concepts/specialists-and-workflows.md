---
title: Specialists, workflows and providers
description: The words for how Gannin runs agent work, and how they fit together.
sidebar:
  order: 6
---

- **Activity**: a kind of agent work Gannin starts: reviewing a pull request, Work on This, Quick Change, Ask, Planning, and Design and Refine.
- **Workflow**: how an activity runs. Each activity has a default, and a project can add its own and route work to them. With none set up, the default is Gannin's own single step, which runs the activity as it always has.
- **Stage**: a column of a workflow. Its steps run at the same time and join before the next stage starts.
- **Step**: one piece of a stage: a specialist (or Gannin's own prompt) on a provider and model, with a focus, and for reviews a number of rounds. An interactive activity's workflow has one step that is the session you type in; the others run once, before or after it.
- **Specialist**: an agent the team writes, with a soul (who it is and what it looks for) and defaults for its provider, model and focus. Kept in the harness as `specialists/<name>.md`.
- **Provider**: what runs a step. Claude Code runs sessions and review steps; one-shot CLIs such as Junie answer once, for review steps, in a throwaway copy of the code. Other providers can join later.
- **Routing rule**: sends a PR or an issue to a workflow when it matches. The first matching rule wins.
- **Run**: one review through a workflow. It posts one review on the pull request, with every finding labelled by the specialist that raised it.

Specialists, workflows and routing rules belong to a [project](/docs/concepts/projects-and-harnesses/): a PR or issue uses the harness of the project that covers its repo. Building them is covered in [Specialists and workflows](/docs/agents/workflows/).
