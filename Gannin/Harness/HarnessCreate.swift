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

                Every requirement, plan, decision, finding and skill starts with YAML front matter (`type`, `status`,
                `summary`, `domains`, `issues`, and for plans `touches`), as `STANDARDS.md` sets out. Scout
                by front matter first: read the summaries, and open a document only when one says it
                matters.

                ## Folders

                - `requirements/<module>/`: what a feature must do (`_template.md`).
                - `plans/`: every plan, dated (`YYYY-MM-DD-slug.md`), from `_template.md`.
                - `decisions/`: decision records (ADRs), what was decided and why, dated
                  (`decisions/README.md`).
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

                Every requirement, plan, decision, finding and skill starts with YAML front matter: the facts about
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
                | `type` | all | `requirement`, `plan`, `decision`, `finding`, `skill`, `learning` or `refine` |
                | `status` | all but skills | One value from the list below, never a sentence |
                | `summary` | all | A sentence or two for deciding whether to open it, as a `>` block |
                | `domains` | all | The product areas it belongs to, from the list below, the main one first |
                | `issues` | when there is one | The issues it's about, as `owner/repo#123` |
                | `touches` | plans, findings, refines | The code it changes, as `owner/repo` or `owner/repo:path` |
                | `owner` | optional | The GitHub login driving it |
                | `repo`, `paths`, `commit`, `source`, `author` | learnings | See `learnings/README.md` |
                | `url`, `attendees` | refines | See `refines/README.md` |
                | `superseded_by`, `plans` | decisions | See `decisions/README.md` |
                | `key` | optional | `true` puts it first in its area on Gannin's Onboarding map |

                Statuses:

                - Requirements: `draft`, `in-progress`, `done`
                - Plans: `draft`, `agreed`, `in-progress`, `blocked`, `done`, `abandoned`
                - Decisions: `proposed`, `accepted`, `rejected`, `superseded`
                - Findings: `open`, `investigating`, `fixing`, `fixed`, `wont-fix`, with a `severity` of
                  `low`, `medium`, `high` or `critical`
                - Learnings: `active`, `retired`
                - Refines: `agreed`

                ## Where documents go

                ```
                requirements/<module>/<feature>.md
                plans/YYYY-MM-DD-<slug>.md
                decisions/YYYY-MM-DD-<slug>.md
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
            "decisions/README.md": """
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

                """,
            "decisions/_template.md": """
                ---
                type: decision
                status: proposed
                summary: >
                  {The decision, in a sentence or two.}
                domains: [{domain}]
                plans: [plans/{date}-{slug}.md]
                ---

                # {The decision, as a short statement}

                ## Context

                {What forced a choice: the problem, the constraints, what mattered.}

                ## Decision

                {What was decided, in a sentence or two.}

                ## Alternatives considered

                - **{An alternative}**: {why it wasn't chosen.}

                ## Consequences

                {What follows from it, good and bad, and what it rules out.}

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

/// Sets up a project's harness, as onboarding: what a project is, what's in
/// its harness, then either a new one (the project's name, the harness
/// repo's and the code repos it's for) or one the user already has, and
/// last what's left: starter files a harness lacks, and where it's checked
/// out on this Mac. A new repo is private, its layout (`HarnessSkeleton`)
/// and `.gannin/project.json` one commit. Either way it's a project from
/// then on (home, if it's the first).
struct SetUpHarnessSheet: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(OrgStore.self) private var orgs
    @Environment(MetricsStore.self) private var metrics
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let org: String
    /// The repo, once it's a project.
    var onLinked: (String) -> Void = { _ in }

    enum Choice: Hashable { case create, link }

    @State private var step: HarnessOnboardingStep?
    @State private var choice: Choice = .create
    @State private var projectName = ""
    @State private var name = ""
    /// The code repos it's for; none for every repo.
    @State private var picked: Set<String> = []
    /// The repo to link, as picked.
    @State private var linking: String?
    @State private var isWorking = false
    @State private var status: String?
    @State private var error: String?
    /// The harness set up here, once it's a project.
    @State private var linked: String?
    /// The code repos the starter CLAUDE.md lists.
    @State private var starterRepos: [String] = []
    /// Starter files the harness lacks; nil until checked.
    @State private var missing: [String]?
    @State private var isConfirmingMissing = false

    /// No project when the sheet opened: the tour comes first.
    @State private var isFirst: Bool?

    var body: some View {
        let isFirst = isFirst ?? configs.harnesses(for: org).isEmpty
        let current = step ?? (isFirst ? .intro : .setUp)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Group {
                    switch current {
                    case .intro: HarnessIntroView(org: org, isFirst: isFirst)
                    case .layout: HarnessLayoutView()
                    case .setUp: setUp(isFirst: isFirst)
                    case .finish: finish
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            footer(current, isFirst: isFirst)
                .padding(16)
        }
        .frame(width: 640, height: 600)
        .interactiveDismissDisabled(isWorking)
        .task {
            if self.isFirst == nil { self.isFirst = configs.harnesses(for: org).isEmpty }
            await harness.loadRepositories(org: org)
        }
        .confirmationDialog("Add \(missing?.count ?? 0) starter files to \(linked ?? "")?", isPresented: $isConfirmingMissing) {
            Button("Add Missing Files") { Task { await addMissing() } }
        } message: {
            Text("One commit, of files the harness doesn't have. Nothing already there is changed.")
        }
    }

    private func footer(_ current: HarnessOnboardingStep, isFirst: Bool) -> some View {
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
                    // Finish once there's a harness, and nothing before it after.
                    .disabled(isWorking || (item == .finish) == (linked == nil))
                }
            }
            if isWorking {
                ProgressView().controlSize(.small).padding(.leading, 8)
                Text(status ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if current == .finish {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            } else {
                // Not Now puts off its opening by itself; it's in the Gannin menu after.
                Button(isFirst ? "Not Now" : "Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                if current != .intro {
                    Button("Back") { step = HarnessOnboardingStep(rawValue: current.rawValue - 1) }
                        .disabled(isWorking)
                }
                if current == .setUp {
                    switch choice {
                    case .create:
                        Button("Create Harness") { Task { await create() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(isWorking || isTaken || !Self.isValid(repoName) || trimmedProjectName.isEmpty)
                    case .link:
                        Button("Link Harness") { Task { await link() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(isWorking || linking == nil)
                    }
                } else {
                    Button("Continue") { step = HarnessOnboardingStep(rawValue: current.rawValue + 1) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    // MARK: Create or link

    private func setUp(isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isFirst ? "Set up your first project" : "New project")
                .font(.title2.weight(.semibold))
            if !isFirst {
                Button("What's in a harness?") { step = .layout }
                    .linkButton()
            }
            Picker("Harness", selection: $choice) {
                Text("Create a new harness").tag(Choice.create)
                Text("Link one you have").tag(Choice.link)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isWorking)
            switch choice {
            case .create: form
            case .link: linkForm
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

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
        Form {
            TextField("Project", text: $projectName, prompt: Text("Platform, Mobile app"))
            TextField("Harness repo", text: $name, prompt: Text(repoName))
            if isTaken {
                Text("\(org) already has a repo called \(repoName). Link it instead.")
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
        .disabled(isWorking)
    }

    /// A repo of the org's, or any `owner/name` the token can push to.
    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick the repo the team keeps its harness in. Gannin reads it from GitHub, and offers any starter files it doesn't have on the next step.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let taken = Set(configs.harnesses(for: org).map(\.repo))
            SearchableList(
                choices: Set(harness.repositories[org] ?? []).subtracting(taken)
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                    .map { SearchableChoice(value: $0, title: $0) },
                selection: linking,
                prompt: "Search repositories, or type owner/name",
                isLoading: harness.repositories[org] == nil,
                typedChoice: { query in
                    HarnessRepoEntry.parse(query, taken: taken)
                        .map { SearchableChoice(value: $0, title: "Link \($0)", section: "Not listed") }
                }
            ) { repo in
                linking = repo
                error = nil
            }
            .frame(height: 300)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.separatorLine))
            .disabled(isWorking)
            if let linking {
                Text("Links \(linking).").font(.caption).foregroundStyle(.secondary)
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
        isWorking = true
        error = nil
        defer { isWorking = false }
        let name = repoName
        let repos = repoChoices.filter(picked.contains)
        starterRepos = repos.isEmpty ? Array(repoChoices.prefix(12)) : repos
        do {
            status = "Creating \(org)/\(name)"
            let created = try await api.createRepository(org: org, name: name, description: "Plans, requirements, findings and skills beside the code, kept with Gannin.")
            let setup = HarnessConfig(repo: created.nameWithOwner)
            // It's a project from here, even if the layout fails.
            configs.updateHarnesses(org) { $0.addHarness(setup) }
            status = "Committing the layout"
            var files = HarnessSkeleton.files(org: org, repo: created.nameWithOwner, projects: starterRepos)
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
                } catch {
                    // The repo's there: finish offers what's missing.
                    self.error = "Created \(created.nameWithOwner), but couldn't commit its layout: \(error.localizedDescription)"
                    break
                }
            }
            finish(created.nameWithOwner)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func link() async {
        guard let repo = linking, let api = auth.api else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        status = "Checking \(repo)"
        do {
            let found = try await api.writableHarnessRepo(repo)
            configs.updateHarnesses(org) { $0.addHarness(HarnessConfig(repo: found)) }
            starterRepos = []
            finish(found)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finish(_ repo: String) {
        linked = repo
        step = .finish
        onLinked(repo)
        Task { await checkMissing() }
    }

    // MARK: Finish

    private var setup: HarnessConfig? {
        linked.map { repo in configs.harnesses(for: org).first { $0.repo == repo } ?? HarnessConfig(repo: repo) }
    }

    @ViewBuilder
    private var finish: some View {
        if let linked {
            let isHome = configs.harnesses(for: org).first?.repo == linked
            VStack(alignment: .leading, spacing: 14) {
                Text("\(linked) is set up")
                    .font(.title2.weight(.semibold))
                Text(isHome
                    ? "It's home, the project windows open on, and keeps what's the org's as well as the project's."
                    : "It's a project now: pick it from the project menu at the foot of the sidebar.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Form {
                    starterFiles
                    HarnessCheckoutSection(org: org, repo: linked, showsReviewRequests: isHome)
                }
                .formStyle(.grouped)
                Text("Claude Code sessions run in the checkout on this Mac; Gannin clones it there when the first one starts, or choose one you have. Boards, code repos and the rest are under Settings › Projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var starterFiles: some View {
        Section {
            if let missing {
                if missing.isEmpty {
                    Label("Has every starter file", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not in the harness yet: \(missing.joined(separator: ", ")).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Add Missing Files") { isConfirmingMissing = true }
                        .disabled(isWorking)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking the harness").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Starter files")
        } footer: {
            Text("What Gannin starts a harness with: a README, CLAUDE.md, STANDARDS.md and a folder for each kind of document. Skip them if the harness is laid out its own way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func checkMissing() async {
        guard let setup, let api = auth.api else { return }
        missing = nil
        let parts = setup.repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return }
        do {
            let head = try await api.harnessHead(owner: parts[0], name: parts[1], branch: setup.branch)
            missing = try await api.missingStarterFiles(repo: setup.repo, commit: head.commit)
        } catch {
            missing = []
            self.error = "Couldn't check \(setup.repo) for starter files: \(error.localizedDescription)"
        }
    }

    /// Commits only the starter files the head lacks, checked again at the
    /// head it commits onto, so nothing there is overwritten.
    private func addMissing() async {
        guard let setup, let api = auth.api else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        status = "Adding starter files"
        let files = HarnessSkeleton.files(org: org, repo: setup.repo, projects: starterRepos)
        do {
            try await harness.commit(org: org, setup: setup) { head in
                let missing = try await api.missingStarterFiles(repo: setup.repo, commit: head)
                guard !missing.isEmpty else { return nil }
                return HarnessChange(message: "Harness starter files, from Gannin", files: files.filter { missing.contains($0.key) })
            }
        } catch {
            self.error = error.localizedDescription
        }
        await checkMissing()
    }
}
