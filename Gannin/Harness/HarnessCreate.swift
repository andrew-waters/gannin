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
                - `learnings/<repo>/`: rules and reasons people gave in review, scoped to the code they're
                  about, which reviews follow (`learnings/README.md`).
                - `refines/`: a record of each Design and Refine session, its screenshots beside it
                  (`refines/README.md`).
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
                | `type` | all | `requirement`, `plan`, `finding`, `skill`, `learning` or `refine` |
                | `status` | all but skills | One value from the list below, never a sentence |
                | `summary` | all | A sentence or two for deciding whether to open it, as a `>` block |
                | `domains` | all | The product areas it belongs to, from the list below, the main one first |
                | `issues` | when there is one | The issues it's about, as `owner/repo#123` |
                | `touches` | plans, findings | The code it changes, as `owner/repo` or `owner/repo:path` |
                | `owner` | optional | The GitHub login driving it |
                | `repo`, `paths`, `commit`, `source`, `author` | learnings | See `learnings/README.md` |

                Statuses:

                - Requirements: `draft`, `in-progress`, `done`
                - Plans: `draft`, `agreed`, `in-progress`, `blocked`, `done`, `abandoned`
                - Findings: `open`, `investigating`, `fixing`, `fixed`, `wont-fix`, with a `severity` of
                  `low`, `medium`, `high` or `critical`
                - Learnings: `active`, `retired`
                - Refines: `agreed`

                ## Where documents go

                ```
                requirements/<module>/<feature>.md
                plans/YYYY-MM-DD-<slug>.md
                findings/YYYY-MM-DD-<slug>.md
                skills/<name>.md
                prompts/<name>.md
                learnings/<repo>/YYYY-MM-DD-<slug>.md
                refines/YYYY-MM-DD-<slug>/README.md
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
            "learnings/README.md": """
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

                """,
            "learnings/_template.md": """
                ---
                type: learning
                status: active
                summary: >
                  {The rule, in a sentence.}
                repo: \(org)/{repo}
                paths: [{folder/}, {file}, {file#L10-L24}]
                commit: {the commit the line numbers are at}
                source: {the comment's URL}
                author: {who gave it}
                ---

                # {Short title}

                ## Rule

                {What reviews should do, or leave alone, here.}

                ## Reason

                {Why, as the person put it.}

                ## Source

                > {What they said.}

                """,
            "refines/README.md": """
                # Refines

                A record of each Design and Refine session, where the team stepped through a page together
                and agreed what to improve. One folder per session, `refines/YYYY-MM-DD-<slug>/`, with its
                `README.md` (from `_template.md`) and the annotated screenshots beside it. Gannin commits
                both when the room agrees the session, and each issue it made links to its screenshots here.

                | Field | What it holds |
                | ----- | ------------- |
                | `type` | `refine` |
                | `status` | `agreed` |
                | `summary` | What was reviewed and what came of it, in a sentence |
                | `url` | The page the session opened on |
                | `attendees` | Who was in the room |
                | `issues` | The issues it made, as `owner/repo#123` |
                | `touches` | The repos whose code the page comes from |

                Screenshots are whatever was on screen: check them for sensitive data before they're
                committed, as Gannin asks you to.

                """,
            "refines/_template.md": """
                ---
                type: refine
                status: agreed
                summary: >
                  {What was reviewed and what came of it, in a sentence.}
                url: {the page the session opened on}
                attendees: [{login}, {name}]
                issues: [\(org)/{repo}#{number}]
                touches: [\(org)/{repo}]
                ---

                # {What was reviewed}

                ## Findings

                - {The finding}: \(org)/{repo}#{number} ([screenshot](./{screenshot}.png))

                """,
            "sessions/README.md": """
                # Sessions

                Gannin records each Claude Code session here when you Work on an issue:
                `sessions/<repo>-<number>/brief.md` is what the session started from, and `session.json` who
                started it, where, on which branch, and its pull requests.

                """,
            ".gannin/README.md": HarnessTour.readme,
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

/// Creates a project's harness, as onboarding: what a project is, what's in
/// its harness, then the project's name, the harness repo's and the code
/// repos it's for. The repo is private, its layout (`HarnessSkeleton`) and
/// `.gannin/project.json` one commit, and it's a project from then on
/// (home, if it's the first).
struct CreateHarnessSheet: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(OrgStore.self) private var orgs
    @Environment(MetricsStore.self) private var metrics
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let org: String
    @State private var step: HarnessOnboardingStep?
    @State private var projectName = ""
    @State private var name = ""
    /// The code repos it's for; none for every repo.
    @State private var picked: Set<String> = []
    @State private var isCreating = false
    @State private var status: String?
    @State private var error: String?

    /// No project yet: the tour comes first.
    private var isFirst: Bool { configs.harnesses(for: org).isEmpty }

    var body: some View {
        let current = step ?? (isFirst ? .intro : .create)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Group {
                    switch current {
                    case .intro: HarnessIntroView(org: org, isFirst: isFirst)
                    case .layout: HarnessLayoutView()
                    case .create: form
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            footer(current)
                .padding(16)
        }
        .frame(width: 640, height: 600)
        .interactiveDismissDisabled(isCreating)
        .task { await harness.loadRepositories(org: org) }
    }

    private func footer(_ current: HarnessOnboardingStep) -> some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(HarnessOnboardingStep.allCases, id: \.self) { item in
                    Button {
                        step = item
                    } label: {
                        Circle()
                            .fill(item == current ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                    .disabled(isCreating)
                }
            }
            if isCreating {
                ProgressView().controlSize(.small).padding(.leading, 8)
                Text(status ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)
            if current != .intro {
                Button("Back") { step = HarnessOnboardingStep(rawValue: current.rawValue - 1) }
                    .disabled(isCreating)
            }
            if current == .create {
                Button("Create Project") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || isTaken || !Self.isValid(repoName) || trimmedProjectName.isEmpty)
            } else {
                Button("Continue") { step = HarnessOnboardingStep(rawValue: current.rawValue + 1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: The form

    private var trimmedProjectName: String { projectName.trimmingCharacters(in: .whitespaces) }

    /// The repo's name: as typed, else from the project's.
    private var repoName: String {
        if !name.isEmpty { return name }
        let slug = trimmedProjectName.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "harness" : "\(slug)-harness"
    }

    private var isTaken: Bool {
        (harness.repositories[org] ?? []).contains { $0.lowercased() == "\(org)/\(repoName)".lowercased() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isFirst ? "Name your first project" : "New project")
                .font(.title2.weight(.semibold))
            if !isFirst {
                Button("What's in a harness?") { step = .layout }
                    .linkButton()
            }
            Form {
                TextField("Project", text: $projectName, prompt: Text("Platform, Mobile app"))
                TextField("Harness repo", text: $name, prompt: Text(repoName))
                if isTaken {
                    Text("\(org) already has a repo called \(repoName). Add it under Settings › Projects instead.")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Gannin creates \(org)/\(repoName) as a private repo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    let choices = repoChoices
                    if choices.isEmpty {
                        Text("No repos with recent pull requests yet. Add them later under Settings › Projects.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(choices, id: \.self) { repo in
                        Toggle(repo, isOn: Binding(
                            get: { picked.contains(repo) },
                            set: { if $0 { picked.insert(repo) } else { picked.remove(repo) } }
                        ))
                        .checkboxToggle()
                    }
                } header: {
                    Text("Code repos")
                } footer: {
                    Text(picked.isEmpty ? "None picked: the project covers every repo. A window on it shows only its repos." : "A window on the project shows only these. CLAUDE.md lists them for Claude Code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The org's code repos with PRs, busiest first.
    private var repoChoices: [String] {
        let config = configs.baseConfig(for: org)
        return OrgSettingsView.repositories(snapshot: orgs.snapshot(for: org), history: metrics.history(for: org))
            .filter { $0.openPullRequests + $0.merged > 0 && !config.excludedRepos.contains($0.name) }
            .sorted { $0.openPullRequests + $0.merged > $1.openPullRequests + $1.merged }
            .prefix(20)
            .map(\.name)
    }

    private static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    private func create() async {
        guard let api = auth.api else { return }
        isCreating = true
        error = nil
        defer { isCreating = false }
        let name = repoName
        let repos = repoChoices.filter(picked.contains)
        do {
            status = "Creating \(org)/\(name)"
            let created = try await api.createRepository(org: org, name: name, description: "Plans, requirements, findings and skills beside the code, kept with Gannin.")
            let setup = HarnessConfig(repo: created.nameWithOwner)
            // It's a project from here, even if the layout fails.
            configs.updateHarnesses(org) { $0.addHarness(setup) }
            status = "Committing the layout"
            var files = HarnessSkeleton.files(org: org, repo: created.nameWithOwner, projects: repos.isEmpty ? Array(repoChoices.prefix(12)) : repos)
            files[TeamFile.project] = TeamCoding.encode(ProjectFile(name: trimmedProjectName, repos: repos))
            // The first commit GitHub makes can take a moment to show.
            var attempt = 0
            while true {
                do {
                    try await harness.commit(org: org, setup: setup) { _ in
                        HarnessChange(message: "Harness layout for \(trimmedProjectName), from Gannin", files: files)
                    }
                    break
                } catch where attempt < 3 {
                    attempt += 1
                    try await Task.sleep(for: .seconds(attempt * 2))
                }
            }
            dismiss()
        } catch {
            self.error = !configs.harnesses(for: org).contains { $0.repo == "\(org)/\(name)" }
                ? error.localizedDescription
                : "Created \(org)/\(name), but couldn't commit its layout: \(error.localizedDescription)"
        }
    }
}
