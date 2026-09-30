import SwiftUI

/// A new harness's first commit: where plans, requirements, findings and
/// skills go, a starter CLAUDE.md in the spirit of Ctrl Hub's, and the
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
                3. **Plan.** Write the plan in `requirements/<module>/plans/`, with the issue in its header
                   table (`| GitHub | owner/repo#123 |`), and present it for review.
                4. **Agree.** Nothing is implemented until the plan is agreed.
                5. **Implement.** Work through the plan, ticking `- [ ]` to `- [x]` as each task lands, so an
                   interrupted session can pick up where it left off.
                6. **PR.** Open a PR per repo with `Closes owner/repo#123` in its body.

                ## Folders

                - `requirements/<module>/`: what a feature must do (`_template.md`), and its `plans/`.
                - `findings/`: investigations and what they found, dated (`YYYY-MM-DD-topic.md`).
                - `skills/`: reusable workflows for Claude Code (`skills/README.md`).
                - `sessions/`: Gannin's record of each Claude Code session, with the brief it started from.
                - `.gannin/`: the team's settings and people's dates, kept by Gannin. Don't edit by hand.

                ## Principles

                - Read before writing, and follow each repo's established patterns.
                - Do what the requirement asks; don't refactor beside it.
                - One concern per commit and PR, each tracing back to an issue.

                """,
            "requirements/README.md": """
                # Requirements

                One folder per module, each requirement a Markdown file from `_template.md`. Plans for
                implementing them go in the module's `plans/` folder.

                Put the issue in the header table's GitHub row (`owner/repo#123`) so Gannin links the
                document to it: the issue's page lists its plans, and a session's brief includes them.

                """,
            "requirements/_template.md": """
                # {Feature name}

                | Field       | Value                         |
                | ----------- | ----------------------------- |
                | Module      | {Module}                      |
                | GitHub      | {owner/repo#123}              |
                | Status      | {Draft, Agreed, In progress, Done} |
                | Description | {One line on what it's for}   |

                ---

                ## Requirements

                ### {Requirement}

                {What it must do, and why.}

                #### Acceptance criteria

                - [ ] {A check that shows it's done}

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
                name: skill-name
                description: What it does, in a line
                repos: all
                ---

                {The instructions}
                ```

                Name files in lowercase kebab case, matching `name`.

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
        let response: Response = try await restWrite("POST", "orgs/\(org)/repos", body: [
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
                Text("README.md, a starter CLAUDE.md\(projects.isEmpty ? "" : " listing \(projects.count) of the org's repos"), requirements with its template, findings, skills, sessions, .gannin, and a .gitignore keeping out projects/ and .worktrees/.")
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
            .filter { $0.openPullRequests + $0.merged > 0 && !config.excludedRepos.contains($0.name) }
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
            // It's the org's harness from here, even if the layout fails.
            configs.update(org) { $0.harness = setup }
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
            self.error = configs.config(for: org).harness == nil
                ? error.localizedDescription
                : "Created \(org)/\(name), but couldn't commit its layout: \(error.localizedDescription)"
        }
    }
}
