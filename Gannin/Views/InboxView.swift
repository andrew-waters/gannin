import SwiftUI

/// What's waiting on you in the org, as Mail's inbox is: PRs you've been
/// asked to review (longest waiting first), your own open PRs and where
/// each stands, the issues assigned to you (in progress first, with how
/// long they've sat and anything that doesn't add up), and on the Mac the
/// Claude Code sessions waiting on you.
struct InboxView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.navigate) private var navigate
    #if os(macOS)
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    #endif
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays

    let org: String
    let workload: Workload

    var body: some View {
        if let login = auth.viewer?.login {
            let inbox = Inbox(login: login, workload: workload, history: issueStore.history(for: org), workflow: configs.config(for: org).workflow)
            List {
                #if os(macOS)
                let waiting = sessions.sessions(for: org).filter { [.needsYou, .idle].contains(sessions.state($0.id)) }
                if !waiting.isEmpty {
                    Section(header: SectionHeader(title: "Claude Code", count: waiting.count)) {
                        ForEach(waiting) { session in
                            let state = sessions.state(session.id)
                            Button {
                                openWindow(value: SessionWindowID(id: session.id))
                            } label: {
                                row(title: session.issue.title, detail: "\(session.repo) · \(state.label)", tint: state.color) {
                                    Text(state.label).foregroundStyle(state == .needsYou ? .orange : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                #endif
                Section(header: SectionHeader(title: "Needs your review", count: inbox.reviews.count)) {
                    if inbox.reviews.isEmpty { empty("No one's waiting on you.") }
                    ForEach(inbox.reviews, id: \.pr.id) { item in
                        pullRequestRow(item.pr) {
                            HStack(spacing: 6) {
                                if let author = item.pr.author { Avatar(url: author.avatarUrl, size: 16) }
                                if let asked = item.askedAt {
                                    Text("asked")
                                    RelativeDate(date: asked)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                Section(header: SectionHeader(title: "Your pull requests", count: inbox.pullRequests.count)) {
                    if inbox.pullRequests.isEmpty { empty("Nothing open.") }
                    ForEach(inbox.pullRequests) { pr in
                        pullRequestRow(pr) {
                            let standing = Inbox.standing(pr)
                            Text(standing.text).foregroundStyle(standing.color)
                        }
                    }
                }
                Section(header: SectionHeader(title: "Your issues", count: inbox.issues.count)) {
                    if inbox.issues.isEmpty { empty("Nothing assigned to you.") }
                    ForEach(inbox.issues, id: \.record.id) { item in
                        Button {
                            navigate?(.issueReference(IssueReference(org: org, record: item.record)))
                        } label: {
                            row(
                                title: item.record.title,
                                detail: "\(item.record.repo.split(separator: "/").last.map(String.init) ?? item.record.repo)#\(String(item.record.number))",
                                tint: item.inProgress ? ChartPalette.blue : .secondary.opacity(0.4)
                            ) {
                                HStack(spacing: 6) {
                                    FlagBadge(flags: item.signals.flags)
                                    if let status = item.signals.status {
                                        Text(item.signals.timeInStatus.map { "\(status), \($0.compactDuration)" } ?? status)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .opensElsewhere(.issueReference(IssueReference(org: org, record: item.record)))
                    }
                }
            }
            .task(id: org) { await issueStore.sync(org, windowDays: windowDays) }
        } else {
            ContentUnavailableView("Not signed in", systemImage: "tray")
        }
    }

    private func pullRequestRow(_ pr: PullRequest, @ViewBuilder trailing: () -> some View) -> some View {
        Button {
            navigate?(.pullRequest(pr.id))
        } label: {
            row(
                title: pr.title,
                detail: "\(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo)#\(String(pr.number)) · +\(pr.additions) -\(pr.deletions)" + (pr.isDraft ? " · draft" : ""),
                tint: Inbox.standing(pr).color,
                trailing: trailing
            )
        }
        .buttonStyle(.plain)
        .opensElsewhere(.pullRequest(pr.id))
    }

    private func row(title: String, detail: String, tint: Color, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing()
                .font(.callout)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }
}

/// The signed-in person's share of the workload.
struct Inbox {
    struct Review {
        let pr: PullRequest
        let askedAt: Date?
    }

    struct AssignedIssue {
        let record: IssueRecord
        let signals: IssueSignals
        let inProgress: Bool
    }

    let reviews: [Review]
    let pullRequests: [PullRequest]
    let issues: [AssignedIssue]

    init(login: String, workload: Workload, history: IssueHistory?, workflow: IssueWorkflow) {
        let open = workload.openPullRequests
        reviews = open
            .filter { $0.requestedReviewers.contains { $0.login == login } }
            .map { Review(pr: $0, askedAt: $0.reviewRequestedAt[login]) }
            .sorted { ($0.askedAt ?? $0.pr.createdAt) < ($1.askedAt ?? $1.pr.createdAt) }
        pullRequests = open
            .filter { $0.workers.contains(login) }
            // What needs you first: changes asked for, then the rest by
            // how long since anything happened.
            .sorted { a, b in
                let (x, y) = (a.reviewDecision == .changesRequested, b.reviewDecision == .changesRequested)
                return x != y ? x : a.updatedAt < b.updatedAt
            }
        let context = FieldContext(board: workflow.projectNumber, workflow: workflow, history: history)
        issues = (history.map { Array($0.issues.values) } ?? [])
            .filter { $0.isOpen && $0.assignees.contains(login) }
            .map { record in
                let signals = context.signals(record)
                return AssignedIssue(record: record, signals: signals, inProgress: signals.status.map(workflow.isInProgress) ?? false)
            }
            .sorted { a, b in
                a.inProgress != b.inProgress ? a.inProgress : (a.signals.timeInStatus ?? 0) > (b.signals.timeInStatus ?? 0)
            }
    }

    /// Reviews waiting on you, and your PRs with changes asked for.
    var count: Int {
        reviews.count + pullRequests.filter { $0.reviewDecision == .changesRequested }.count
    }

    /// Where a PR of yours stands, in words and a colour.
    static func standing(_ pr: PullRequest) -> (text: String, color: Color) {
        if pr.isDraft { return ("Draft", .secondary) }
        switch pr.reviewDecision {
        case .changesRequested: return ("Changes requested", ChartPalette.critical)
        case .approved: return ("Approved", ChartPalette.good)
        default:
            if Workload.isStale(pr) { return ("Stale", .orange) }
            let waiting = pr.requestedReviewers.map(\.displayName)
            return (waiting.isEmpty ? "No reviewer" : "Waiting on \(waiting.joined(separator: ", "))", waiting.isEmpty ? .orange : ChartPalette.blue)
        }
    }
}
