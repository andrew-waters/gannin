import SwiftUI

/// What's in a harness, for the onboarding sheet's tree and the new
/// harness's `.gannin/README.md`: its folders, then the team's files.
enum HarnessTour {
    struct Entry: Identifiable {
        let name: String
        var depth = 0
        var isFolder = false
        /// Made by sessions on the box they run on; never committed.
        var isLocal = false
        let text: String

        var id: String { "\(depth)/\(name)" }
    }

    static let layout: [Entry] = [
        Entry(name: "README.md", text: "What the harness is for, and how to clone the code beside it."),
        Entry(name: "CLAUDE.md", text: "What Claude Code reads first in every session here: the repos, where things go, how to work."),
        Entry(name: "STANDARDS.md", text: "The front matter every document carries (type, status, summary, issues), so Gannin can list and link them."),
        Entry(name: "requirements/", isFolder: true, text: "What to build and why, by module, each naming the issues it's about."),
        Entry(name: "plans/", isFolder: true, text: "How to build it: a plan per piece of work, with tasks Gannin counts off."),
        Entry(name: "findings/", isFolder: true, text: "What was learned looking into something: investigations, incidents, audits."),
        Entry(name: "skills/", isFolder: true, text: "Reusable workflows for Claude Code, a Markdown file each."),
        Entry(name: "prompts/", isFolder: true, text: "The team's prompts for starting work, reviews and planning, offered when a session starts."),
        Entry(name: "learnings/", isFolder: true, text: "Rules people gave in review, by repo, that later reviews apply."),
        Entry(name: "refines/", isFolder: true, text: "A record of each Design and Refine session: who was there, the issues it made, its screenshots."),
        Entry(name: "sessions/", isFolder: true, text: "A record of each Claude Code session: its brief, who started it, its pull requests."),
        Entry(name: "projects/", isFolder: true, isLocal: true, text: "The code repos, cloned here for sessions to work from. Kept out of git."),
        Entry(name: ".worktrees/", isFolder: true, isLocal: true, text: "A worktree per issue, where a session makes its changes. Kept out of git."),
        Entry(name: ".gannin/", isFolder: true, text: "The team's settings as JSON, committed by Gannin once you've reviewed them."),
    ]

    /// Every project's own, in its harness.
    static let projectFiles: [Entry] = [
        Entry(name: "project.json", depth: 1, text: "The project's name, its code repos and the repo whose boards it lists."),
        Entry(name: "scorecard.json", depth: 1, text: "Scorecard goals, with the numbers entered by hand."),
        Entry(name: "goals.json", depth: 1, text: "Delivery targets: PRs merged, cycle time, first review."),
        Entry(name: "workflow.json", depth: 1, text: "The board, and the statuses that count as in progress."),
        Entry(name: "investments.json", depth: 1, text: "Investment categories and the rules that place issues in them."),
        Entry(name: "recap.json", depth: 1, text: "How often the team looks back on what it closed."),
        Entry(name: "prioritisation.json", depth: 1, text: "The board's date field that says an issue is committed to."),
        Entry(name: "field-notes.json", depth: 1, text: "Points raised in prioritisation, until they're dealt with."),
    ]

    /// The org's, in the home project's harness only.
    static let orgFiles: [Entry] = [
        Entry(name: "people/", depth: 1, isFolder: true, text: "A file per person: start and end dates, time off, working pattern."),
        Entry(name: "working-week.json", depth: 1, text: "Working days and hours, and whose bank holidays."),
        Entry(name: "leave.json", depth: 1, text: "The holiday allowance and when the leave year starts."),
        Entry(name: "exclusions.json", depth: 1, text: "Repos and people left out, and repos that don't need review."),
        Entry(name: "views.json", depth: 1, text: "Saved views of the board."),
        Entry(name: "authoring.json", depth: 1, text: "What Claude is asked when drafting harness documents."),
    ]

    /// `.gannin/README.md`, from the same descriptions.
    static var readme: String {
        func lines(_ entries: [Entry]) -> String {
            entries.map { "- `\($0.name)`: \($0.text)" }.joined(separator: "\n")
        }
        return """
            # Gannin

            The team's settings and people's dates, kept by Gannin as JSON, one concern to a file. Gannin
            commits every change here through the GitHub API, after asking. Edit them in Gannin rather
            than by hand; a file that isn't here is the default.

            Every project's harness has its own:

            \(lines(projectFiles))

            The home project's harness also keeps the org's:

            \(lines(orgFiles))

            """
    }
}

/// A harness's layout as an annotated tree.
struct HarnessTreeView: View {
    let entries: [HarnessTour.Entry]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
            ForEach(entries) { entry in
                GridRow {
                    HStack(spacing: 5) {
                        Image(systemName: entry.isFolder ? "folder" : "doc.text")
                            .foregroundStyle(entry.isFolder ? Color.accentColor : .secondary)
                            .frame(width: 16)
                        Text(entry.name)
                            .font(.callout.monospaced())
                            .foregroundStyle(entry.isLocal ? .secondary : .primary)
                    }
                    .padding(.leading, CGFloat(entry.depth) * 20)
                    .gridColumnAlignment(.leading)
                    Text(entry.text + (entry.isLocal ? " Made by sessions." : ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The steps of creating a project's harness: what a project is, what's in
/// its harness, then its name and repos. Someone with no project yet starts
/// at the beginning; anyone else at the name, with the tour a click away.
enum HarnessOnboardingStep: Int, CaseIterable {
    case intro, layout, create

    var title: String {
        switch self {
        case .intro: "Projects"
        case .layout: "The harness"
        case .create: "Create"
        }
    }
}

/// The first step: what a project and its harness are.
struct HarnessIntroView: View {
    let org: String
    let isFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isFirst ? "Set up your first project" : "What's a project?")
                .font(.title2.weight(.semibold))
            Text("Gannin works in projects. A project is a product or a team's patch of \(org): the code repos it's made of, and a harness beside them.")
                .fixedSize(horizontal: false, vertical: true)
            point("text.book.closed", "A harness is a repo of its own", "Plans, requirements, findings, skills and prompts live there as Markdown, beside the code rather than in it. It's private to \(org), and Gannin reads it straight from GitHub.")
            point("terminal", "Claude Code works from it", "Work on an issue and a session starts in the harness, with the issue's plans, the team's prompts and skills, and a worktree for each repo it touches.")
            point("person.3", "The team's settings are kept in it", "The project's scorecard, goals, workflow and investments are JSON under .gannin, so everyone who adds the project works from the same copy. Gannin commits a change only once you've reviewed it.")
            point("house", "One project is home", isFirst
                ? "This first one is home, so it also keeps what's the org's: people's dates and time off, leave, the working week and the repos and people left out. Add more projects later under Settings › Projects."
                : "Home also keeps what's the org's: people's dates and time off, leave, the working week and the repos and people left out. You can pick which project is home under Settings › Projects.")
        }
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The second step: the harness's folders and the team's files.
struct HarnessLayoutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What's in a harness")
                .font(.title2.weight(.semibold))
            Text("Gannin commits this layout to start with, each folder with a README and a template to copy.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HarnessTreeView(entries: HarnessTour.layout)
            Divider()
            Text("In .gannin, every project's own").font(.headline)
            HarnessTreeView(entries: HarnessTour.projectFiles)
            Text("And in home's, the org's").font(.headline)
            HarnessTreeView(entries: HarnessTour.orgFiles)
            Text("A file appears once something's set; until then it's the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
