import SwiftUI

/// A new harness's first commit: where plans, requirements, findings and
/// skills go, a starter CLAUDE.md, and the
/// folders Gannin keeps (sessions, team data), with the clones and worktrees
/// sessions make left out of git.
enum HarnessSkeleton {
    static func files(org: String, repo: String, projects: [String]) -> [String: String?] {
        let projectRows = projects.isEmpty
            ? "| {name} | `projects/{name}` | `projects/{name}/CLAUDE.md` |"
            : projects.map { name in
                let short = name.split(separator: "/").last.map(String.init) ?? name
                return "| \(short) | `projects/\(short)` | `projects/\(short)/CLAUDE.md` |"
            }.joined(separator: "\n")
        let cloneLines = projects.isEmpty
            ? "git clone https://github.com/\(org)/{name}"
            : projects.map { "git clone https://github.com/\($0)" }.joined(separator: "\n")
        return [
            "README.md": """
                # \(repo)

                \(org)'s harness: the plans, requirements, findings and skills that sit beside the code, and
                the place Claude Code sessions start from.

                Clone the code repos into `projects/` (they're ignored here):

                ```bash
                cd projects
                \(cloneLines)
                ```

                Gannin does this for you when you Work on an issue, and gives each issue a git worktree under
                `.worktrees/<branch>/<repo>`.

                """,
            "CLAUDE.md": """
                # Harness

                The orchestration repo for \(org)'s work across repos with Claude Code. Plans and
                requirements live here; the code lives in the repos under `projects/`.

                ## Projects

                | Project | Path | Guide |
                | ------- | ---- | ----- |
                \(projectRows)

                Read a project's own guide (`CLAUDE.md`, and `AGENTS.md` where it has one) before changing
                anything in it. Those hold its architecture and conventions; don't repeat them here.

                ## Where work happens

                - `projects/<repo>` is the shared clone of each repo, kept on its default branch.
                - Each issue gets a worktree per repo it touches: `.worktrees/<branch>/<repo>`, the branch
                  named `<issue number>-<short title>`. Work there, never in `projects/`.
                - Work spanning repos puts each repo's worktree side by side under the same
                  `.worktrees/<branch>/`, and each repo gets its own commit and PR, referencing the same issue.

                ## Workflow

                1. **Understand.** Read the issue, its discussion and any requirement or plan for it here.
                2. **Scout.** Explore the affected repos and read their guides.
                3. **Plan.** Write the plan in `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md`, with
                   the issue in its front matter, and present it for review.
                4. **Agree.** Nothing is implemented until the plan is agreed.
                5. **Implement.** Work through the plan, ticking `- [ ]` to `- [x]` as each task lands, so an
                   interrupted session can pick up where it left off.
                6. **PR.** Open a PR per repo with `Closes owner/repo#123` in its body.

                ## Documents

                Every requirement, plan, finding and skill starts with YAML front matter (`type`, `status`,
                `summary`, `domains`, `issues`, and for plans `touches`), as `STANDARDS.md` sets out. Scout
                by front matter first: read the summaries, and open a document only when one says it
                matters.

                ## Folders

                - `requirements/<module>/`: what a feature must do (`_template.md`).
                - `plans/`: every plan, dated (`YYYY-MM-DD-slug.md`), from `_template.md`.
                - `findings/`: investigations and what they found, dated (`YYYY-MM-DD-topic.md`).
                - `skills/`: reusable workflows for Claude Code (`skills/README.md`).
                - `prompts/`: the team's prompts for Claude Code sessions, offered by Gannin when work, a
                  review or planning starts (`prompts/README.md`).
                - `sessions/`: Gannin's record of each Claude Code session, with the brief it started from.
                - `.gannin/`: the team's settings and people's dates, kept by Gannin. Don't edit by hand.

                ## Principles

                - Read before writing, and follow each repo's established patterns.
                - Do what the requirement asks; don't refactor beside it.
                - One concern per commit and PR, each tracing back to an issue.

                """,
            "STANDARDS.md": """
                # Document standards

                Every requirement, plan, finding and skill starts with YAML front matter: the facts about
                it that people, scouts and tools (Gannin) read without opening the whole document. GitHub
                shows it as a table at the top of the file.

                ```yaml
                ---
                type: plan
                status: in-progress
                summary: >
                  One or two sentences: what it changes or found, and why.
                domains: [billing]
                issues: [\(org)/{repo}#123]
                touches: [\(org)/{repo}]
                ---
                ```

                | Field | For | What it holds |
                | ----- | --- | ------------- |
                | `type` | all | `requirement`, `plan`, `finding` or `skill` |
                | `status` | all but skills | One value from the list below, never a sentence |
                | `summary` | all | A sentence or two for deciding whether to open it, as a `>` block |
                | `domains` | all | The product areas it belongs to, from the list below, the main one first |
                | `issues` | when there is one | The issues it's about, as `owner/repo#123` |
                | `touches` | plans, findings | The code it changes, as `owner/repo` or `owner/repo:path` |
                | `owner` | optional | The GitHub login driving it |

                Statuses:

                - Requirements: `draft`, `in-progress`, `done`
                - Plans: `draft`, `agreed`, `in-progress`, `blocked`, `done`, `abandoned`
                - Findings: `open`, `investigating`, `fixing`, `fixed`, `wont-fix`, with a `severity` of
                  `low`, `medium`, `high` or `critical`

                ## Where documents go

                ```
                requirements/<module>/<feature>.md
                plans/YYYY-MM-DD-<slug>.md
                findings/YYYY-MM-DD-<slug>.md
                skills/<name>.md
                prompts/<name>.md
                ```

                ## Domains

                List the product's domains here, in lower case with hyphens, so everyone uses the same
                names.

                """,
            "requirements/README.md": """
                # Requirements

                One folder per module, each requirement a Markdown file from `_template.md`, with the front
                matter `STANDARDS.md` sets out. Plans for implementing them go in `plans/`, pointing back
                with `requirement:`.

                """,
            "requirements/_template.md": """
                ---
                type: requirement
                status: draft
                summary: >
                  {One or two sentences: what the feature lets people do, and why.}
                domains: [{domain}]
                issues: [\(org)/{repo}#{number}]
                ---

                # {Feature name}

                {What it's for.}

                ## Requirements

                ### {Requirement}

                {What it must do, and why.}

                #### Acceptance criteria

                - [ ] {A check that shows it's done}

                """,
            "plans/_template.md": """
                ---
                type: plan
                status: draft
                summary: >
                  {One or two sentences: what this changes, and why.}
                domains: [{domain}]
                issues: [\(org)/{repo}#{number}]
                touches: [\(org)/{repo}]
                requirement: requirements/{module}/{feature}.md
                branch: {number}-{short-title}
                ---

                # {Plan title}

                ## Context

                {What prompted it, and what's already there.}

                ## Approach

                {The change, repo by repo, and the decisions made along the way.}

                ## Tasks

                Tick each off as it lands, so an interrupted session can pick up where it left off.

                - [ ] {Task}

                """,
            "findings/_template.md": """
                ---
                type: finding
                status: open
                severity: low
                summary: >
                  {One or two sentences: what behaves unexpectedly, and the mechanism behind it.}
                domains: [{domain}]
                issues: [\(org)/{repo}#{number}]
                touches: [\(org)/{repo}]
                ---

                # {What was seen, as a sentence}

                ## Summary

                ## Mechanism

                ## Blast radius

                """,
            "findings/README.md": """
                # Findings

                Investigations and what they found, one file each, named `YYYY-MM-DD-topic.md`. Name the
                issue it's for (`owner/repo#123`) so Gannin links it.

                """,
            "skills/README.md": """
                # Skills

                Reusable workflows for Claude Code, shared across the projects. Each is a Markdown file with
                front matter:

                ```markdown
                ---
                type: skill
                name: skill-name
                description: What it does, in a line
                repos: all
                ---

                {The instructions}
                ```

                Name files in lowercase kebab case, matching `name`.

                """,
            "prompts/README.md": """
                # Prompts

                The team's prompts for Claude Code sessions. Gannin offers them when a session starts (Work
                on This, Review with Claude, planning) with the defaults ticked, adds what's picked to the
                session's first prompt, and lists those for use in a session in the menu under its terminal.
                Edit them in Gannin (the org's Settings, under Harness) or here, one file each:

                ```markdown
                ---
                type: prompt
                summary: >
                  What it's for, in a line.
                use: [work, review, planning, session]  # where it's offered; all when left out
                default: true                          # ticked when a session starts
                repos: [api]                           # only the default for these repos
                skills: [triage]                       # skills it brings, by name
                ---

                # Title

                What Claude is told. {{issue}}, {{title}}, {{url}}, {{repo}}, {{number}} and {{branch}}
                are filled in.
                ```

                A default for a repo (the issue's, its PRs' or the PR reviewed) takes the place of the
                general defaults there, so a repo can have reviews of its own.

                """,
            "prompts/_template.md": """
                ---
                type: prompt
                summary: >
                  What it's for, in a line.
                use: [review]
                ---

                # Title

                What Claude is told.

                """,
            "sessions/README.md": """
                # Sessions

                Gannin records each Claude Code session here when you Work on an issue:
                `sessions/<repo>-<number>/brief.md` is what the session started from, and `session.json` who
                started it, where, on which branch, and its pull requests.

                """,
            ".gannin/README.md": """
                # Gannin

                The team's settings and people's dates, kept by Gannin as JSON, one concern to a file. Gannin
                commits every change here through the GitHub API, after asking. Edit them in Gannin rather
                than by hand.

                """,
            ".gitignore": """
                # Code repos and the worktrees sessions make, each their own git repo.
                /projects/*
                !/projects/.gitkeep
                /.worktrees/
                .DS_Store

                """,
            "projects/.gitkeep": "",
        ]
    }
}

extension GitHubAPI {
    /// A new private repo in the org, with a first commit so it has a branch
    /// to commit to. A write.
    func createRepository(org: String, name: String, description: String) async throws -> (nameWithOwner: String, defaultBranch: String) {
        struct Response: Decodable {
            let fullName: String
            let defaultBranch: String?
        }
        // A personal account's repos are made as the user's own.
        let path = GitHubAccounts.isUser(org) ? "user/repos" : "orgs/\(org)/repos"
        let response: Response = try await restWrite("POST", path, body: [
            "name": name,
            "description": description,
            "private": true,
            "auto_init": true,
        ])
        return (response.fullName, response.defaultBranch ?? "main")
    }
}

/// Settings > Harness, when there's none: make one. Confirmed first, as every
/// GitHub write is; then it's picked as the org's harness.
struct CreateHarnessSheet: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(OrgStore.self) private var orgs
    @Environment(MetricsStore.self) private var metrics
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let org: String
    /// The project it's for; nil makes it the org's harness.
    var project: UUID? = nil
    @State private var name = "harness"
    @State private var isCreating = false
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        let projects = self.projects
        let taken = (harness.repositories[org] ?? []).contains { $0.lowercased() == "\(org)/\(name)".lowercased() }
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a Harness").font(.title3.weight(.semibold))
            Text("A private repo in \(org) for plans, requirements, findings and skills beside the code, where Claude Code sessions start and the team's settings are kept.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name)
                    .disabled(isCreating)
                if taken {
                    Text("\(org) already has a repo called \(name).")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: taken ? 96 : 70)
            VStack(alignment: .leading, spacing: 4) {
                Text("Gannin creates \(org)/\(name) as a private repo, then commits:")
                Text("README.md, a starter CLAUDE.md\(projects.isEmpty ? "" : " listing \(projects.count) of the org's repos"), STANDARDS.md for documents' front matter, requirements, plans and findings with their templates, skills, prompts, sessions, .gannin, and a .gitignore keeping out projects/ and .worktrees/.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                    Text(status ?? "").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button("Create Harness") { Task { await create(projects: projects) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || taken || !Self.isValid(name))
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(isCreating)
        .task { await harness.loadRepositories(org: org) }
    }

    /// The org's code repos (with PRs), busiest first, for CLAUDE.md's table.
    private var projects: [String] {
        let config = configs.config(for: org)
        return OrgSettingsView.repositories(snapshot: orgs.snapshot(for: org), history: metrics.history(for: org))
            .filter { $0.openPullRequests + $0.merged > 0 && !config.repoExclusion.contains($0.name) }
            .sorted { $0.openPullRequests + $0.merged > $1.openPullRequests + $1.merged }
            .prefix(12)
            .map(\.name)
    }

    private static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    private func create(projects: [String]) async {
        guard let api = auth.api else { return }
        isCreating = true
        error = nil
        defer { isCreating = false }
        do {
            status = "Creating \(org)/\(name)"
            let created = try await api.createRepository(org: org, name: name, description: "Plans, requirements, findings and skills beside the code, kept with Gannin.")
            let setup = HarnessConfig(repo: created.nameWithOwner)
            // It's the harness from here, even if the layout fails.
            if let project {
                configs.updateProject(project, in: org) { $0.harness = setup }
            } else {
                configs.update(org) { $0.harness = setup }
            }
            status = "Committing the layout"
            let files = HarnessSkeleton.files(org: org, repo: created.nameWithOwner, projects: projects)
            // The first commit GitHub makes can take a moment to show.
            var attempt = 0
            while true {
                do {
                    try await harness.commit(org: org, setup: setup) { _ in
                        HarnessChange(message: "Harness layout, from Gannin", files: files)
                    }
                    break
                } catch where attempt < 3 {
                    attempt += 1
                    try await Task.sleep(for: .seconds(attempt * 2))
                }
            }
            dismiss()
        } catch {
            self.error = configs.config(for: org).harness(repo: "\(org)/\(name)") == nil
                ? error.localizedDescription
                : "Created \(org)/\(name), but couldn't commit its layout: \(error.localizedDescription)"
        }
    }
}
