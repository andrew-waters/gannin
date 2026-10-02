#if os(macOS)
import SwiftUI

/// What Ask hands Claude: Gannin's view of the org as JSON files it reads
/// with its read-only tools. Written when a conversation starts; follow-ups
/// in it read the same files.
enum OrgContext {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private struct PR: Encodable {
        let repo: String; let number: Int; let title: String; let url: URL
        let author: String?; let draft: Bool; let review: String?; let reviewers: [String]
        let created: Date; let updated: Date; let additions: Int; let deletions: Int
    }

    private struct Person: Encodable {
        let login: String; let name: String?
        let openPRs: [PR]; let reviewsWaiting: [PR]
        let assignedIssues: [String]; let mergedRecently: Int
    }

    private struct IssueRow: Encodable {
        let repo: String; let number: Int; let title: String; let url: URL
        let open: Bool; let closed: Date?; let reason: String?
        let author: String?; let assignees: [String]; let labels: [String]; let type: String?
        let status: String?; let statusSince: Date?; let parent: Int?; let created: Date
        let pullRequests: [String]; let investment: String?
    }

    private struct Document: Encodable {
        let path: String; let kind: String; let title: String; let status: String?
        let summary: String?; let owner: String?; let domains: [String]?; let issues: [String]
        let tasks: Int; let tasksDone: Int
    }

    private struct Delivery: Encodable {
        struct Span: Encodable {
            let from: Date; let to: Date; let merged: Int
            let cycleTimeHours: Double?; let firstReviewHours: Double?
            let stageMedianHours: [String: Double]
            let byRepo: [String: Int]; let byAuthor: [String: Int]
        }
        let window: Span
        let previous: Span?
        let mergedWithoutReview: [String]
        let largestPRs: [String]
    }

    private struct TimeOff: Encodable {
        let login: String; let kind: String; let from: Date; let to: Date; let note: String
    }

    static func files(
        org: String,
        workload: Workload?,
        metrics: OrgMetrics?,
        issues: IssueHistory?,
        config: OrgConfig,
        harness: HarnessIndex?,
        people: [String: PersonDates]
    ) -> [String: Data] {
        var files: [String: Data] = [:]
        func pr(_ pr: PullRequest) -> PR {
            PR(repo: pr.repo, number: pr.number, title: pr.title, url: pr.url, author: pr.author?.login, draft: pr.isDraft,
               review: pr.reviewDecision?.rawValue, reviewers: pr.requestedReviewers.map(\.login),
               created: pr.createdAt, updated: pr.updatedAt, additions: pr.additions, deletions: pr.deletions)
        }
        if let workload {
            let rows = workload.people.map { load in
                Person(login: load.person.login, name: load.person.name,
                       openPRs: load.pullRequests.map(pr), reviewsWaiting: load.reviewRequests.map(pr),
                       assignedIssues: load.issues.map { "\($0.repo)#\($0.number) \($0.title)" }, mergedRecently: load.merged.count)
            }
            files["workload.json"] = try? encoder.encode(rows)
        }
        if let issues {
            let investments = config.investmentConfig
            let byID = issues.issues
            let rows = byID.values.filter { !config.excludedRepos.contains($0.repo) }.map { record in
                IssueRow(
                    repo: record.repo, number: record.number, title: record.title, url: record.url,
                    open: record.isOpen, closed: record.closedAt, reason: record.stateReason,
                    author: record.author, assignees: record.assignees, labels: record.labels, type: record.issueType,
                    status: record.statusChanges.last?.status, statusSince: record.statusChanges.last?.at,
                    parent: record.parentID.flatMap { byID[$0]?.number }, created: record.createdAt,
                    pullRequests: record.linkedPullRequests.map { "\($0.url.absoluteString) \($0.state.lowercased())" },
                    investment: investments.categorise(record, parent: record.parentID.flatMap { byID[$0] })?.category.name
                )
            }
            .sorted { ($0.repo, $0.number) < ($1.repo, $1.number) }
            files["issues.json"] = try? encoder.encode(rows)
        }
        if let metrics {
            func span(_ from: Date, _ to: Date, _ summary: DeliverySummary) -> Delivery.Span {
                Delivery.Span(
                    from: from, to: to, merged: summary.merged,
                    cycleTimeHours: summary.cycleTime.median.map { $0 / 3600 },
                    firstReviewHours: summary.timeToFirstReview.median.map { $0 / 3600 },
                    stageMedianHours: Dictionary(uniqueKeysWithValues: summary.stages.compactMap { stage, value in value.overall.median.map { (stage.rawValue, $0 / 3600) } }),
                    byRepo: summary.repos.mapValues(\.count), byAuthor: summary.authors.mapValues(\.count)
                )
            }
            let previous = metrics.window.previous()
            let delivery = Delivery(
                window: span(metrics.interval.start, metrics.interval.end, metrics.current),
                previous: metrics.previous.map { span(previous.start, previous.end, $0) },
                mergedWithoutReview: metrics.mergedWithoutReview.map { "\($0.repo)#\($0.number) \($0.title)" },
                largestPRs: metrics.prSize.large.prefix(10).map { "\($0.repo)#\($0.number) \($0.title), \($0.size) lines" }
            )
            files["delivery.json"] = try? encoder.encode(delivery)
        }
        if let harness {
            let documents = harness.documents.filter(\.followsStandard).map { document in
                Document(path: document.path, kind: document.kind.singular, title: document.title, status: document.statusLabel,
                         summary: document.summary, owner: document.owner, domains: document.domains,
                         issues: document.subjects.map { "\($0.repo ?? harness.issuesRepo ?? "")#\($0.number)" },
                         tasks: document.tasks, tasksDone: document.tasksDone)
            }
            files["harness.json"] = try? encoder.encode(documents)
        }
        let soon = Date.now.addingTimeInterval(-7 * 86_400)
        let off = people.flatMap { login, dates in
            dates.absences.filter { $0.end >= soon }.map { TimeOff(login: login, kind: $0.kind.rawValue, from: $0.start, to: $0.end, note: $0.note) }
        }
        files["time-off.json"] = try? encoder.encode(off.sorted { $0.from < $1.from })
        files["README.md"] = Data("""
            # \(org), as Gannin sees it

            - workload.json: each person's open PRs, the reviews waiting on them, their assigned issues
            - issues.json: the issue history (every open issue, and those closed recently), with board status, parent, linked PRs and investment category
            - delivery.json: merged-PR metrics for the stats window and the period before
            - harness.json: plans, requirements and findings in the team's harness, with the issues they're about
            - time-off.json: booked time off from a week ago on

            Written \(Date.now.formatted(.iso8601)).
            """.utf8)
        return files.compactMapValues { $0 }
    }
}

/// Ask's conversations, one per org, for as long as Gannin runs.
@Observable
final class AskConversations {
    static let shared = AskConversations()

    struct Message: Identifiable {
        let id = UUID()
        let fromYou: Bool
        let text: String
    }

    struct Conversation {
        var id = UUID().uuidString.lowercased()
        var messages: [Message] = []
        var working = false
        var error: String?
    }

    var conversations: [String: Conversation] = [:]
}

/// Claude Code › Ask: questions about the org, answered by Claude from
/// what Gannin knows (workload, issues, delivery, the harness, time off),
/// written out as files it reads. Follow-ups go on in the same
/// conversation; New Conversation starts again with the data as it is now.
struct AskOrgPage: View {
    @Environment(IssueStore.self) private var issueStore
    @Environment(MetricsStore.self) private var metricsStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    @Environment(PeopleDatesStore.self) private var peopleDates
    @Environment(OrgStore.self) private var orgs
    @Environment(HiddenStore.self) private var hidden
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    let org: String
    let workload: Workload?
    @State private var question = ""
    @FocusState private var focused: Bool
    private let store = AskConversations.shared

    private static let suggestions = [
        "What's blocking our open epics?",
        "Who has the most reviews waiting, and which are oldest?",
        "What shipped in the last two weeks, by investment category?",
        "Which open PRs look risky: big, old, or quiet?",
        "Which issues are in progress with no PR, and who has them?",
        "Who's off in the next fortnight, and what do they have in flight?",
    ]

    var body: some View {
        let conversation = store.conversations[org] ?? .init()
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if conversation.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Ask about \(orgs.org(login: org)?.displayName ?? org)").font(.title2.weight(.semibold))
                                Text("Claude answers from what Gannin knows: who has what in flight, the issue history and board, delivery for \(MetricsWindow(code: windowDays).span) and before, the harness's plans and requirements, and time off. It reads them as files and can't change anything.")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                ForEach(Self.suggestions, id: \.self) { suggestion in
                                    Button(suggestion) { ask(suggestion) }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                        ForEach(conversation.messages) { message in
                            bubble(message)
                                .id(message.id)
                        }
                        if conversation.working {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Claude is reading").foregroundStyle(.secondary)
                            }
                            .id("working")
                        }
                        if let error = conversation.error {
                            Text(error).foregroundStyle(.red).font(.callout)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: conversation.messages.count) {
                    withAnimation { proxy.scrollTo(conversation.messages.last?.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(conversation.messages.isEmpty ? "Ask about the org" : "Ask a follow-up", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { ask(question) }
                Button("Ask") { ask(question) }
                    .buttonStyle(.borderedProminent)
                    .disabled(conversation.working || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !conversation.messages.isEmpty {
                    Button("New Conversation") { store.conversations[org] = nil }
                        .disabled(conversation.working)
                }
            }
            .padding(12)
        }
        .onAppear { focused = true }
    }

    private func bubble(_ message: AskConversations.Message) -> some View {
        HStack {
            if message.fromYou { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 4) {
                if message.fromYou {
                    Text(message.text)
                } else {
                    MarkdownText(source: message.text)
                }
            }
            .textSelection(.enabled)
            .padding(12)
            .background(message.fromYou ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            if !message.fromYou { Spacer(minLength: 40) }
        }
    }

    private func ask(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var conversation = store.conversations[org] ?? .init()
        guard !conversation.working else { return }
        let starting = conversation.messages.isEmpty
        conversation.messages.append(.init(fromYou: true, text: text))
        conversation.working = true
        conversation.error = nil
        store.conversations[org] = conversation
        question = ""

        let config = configs.config(for: org)
        let files: [String: Data] = starting ? OrgContext.files(
            org: org, workload: workload, metrics: metrics(config), issues: issueStore.history(for: org), config: config,
            harness: config.harness.flatMap { harness.index(for: org, $0) }, people: peopleDates.all(in: org)
        ) : [:]
        let prompt = starting
            ? "You're answering questions about the engineering org \(org) from the files in this folder (start with README.md). Answer from the data, cite issues and PRs by repo#number with their links, say when the data doesn't cover something, and keep it short. Don't modify anything.\n\nQuestion: \(text)"
            : text
        let id = conversation.id
        Task {
            do {
                let reply = try await ClaudeRunner.ask(
                    prompt, org: org, files: files, folder: "gannin-ask-\(org)-\(id.prefix(8))",
                    tools: ["Read", "Grep", "Glob"], session: (id, !starting)
                )
                store.conversations[org]?.messages.append(.init(fromYou: false, text: reply))
            } catch {
                store.conversations[org]?.error = error.localizedDescription
            }
            store.conversations[org]?.working = false
        }
    }

    private func metrics(_ config: OrgConfig) -> OrgMetrics? {
        guard let history = metricsStore.history(for: org) else { return nil }
        let snapshot = orgs.snapshot(for: org)
        return OrgMetrics(history: history, window: MetricsWindow(code: windowDays), team: nil, members: snapshot?.members ?? [], hidden: hidden.keys, config: config)
    }
}
#endif
