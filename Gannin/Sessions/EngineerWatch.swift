#if os(macOS)
import AppKit
import Observation
import SwiftUI
import UserNotifications

/// What you, as an engineer, need to act on, checked every few minutes
/// (Settings › General › Agent): PRs your review is requested on (yours or
/// a team's), your open PRs with their checks and review, and issues
/// assigned to you. A new review request notifies with Review with Claude,
/// which starts nothing until you choose it; your PR notifies when its
/// checks start failing, changes are asked for, or it's approved. The first
/// check after launch only learns what's there. Shown in the menu bar and
/// on Agents.
@Observable
final class EngineerWatch {
    static let shared = EngineerWatch()

    /// Minutes between checks; 0 turns them off.
    static let intervalKey = "reviewCheckMinutes"
    static let menuBarKey = "showsMenuBarExtra"

    struct PullRequestItem: Identifiable, Hashable {
        let id: String
        let repo: String
        let number: Int
        let title: String
        let url: URL
        let author: String?
        let isDraft: Bool
        let createdAt: Date
        let updatedAt: Date
        /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`.
        let review: String?
        /// The head commit's checks: `SUCCESS`, `FAILURE`, `ERROR`, `PENDING`.
        let checks: String?
        let mergeable: String?

        var org: String { repo.split(separator: "/").first.map(String.init) ?? repo }

        var reference: PullRequestReference {
            PullRequestReference(org: org, id: id, number: number, title: title, repo: repo, url: url)
        }

        var isFailing: Bool { checks == "FAILURE" || checks == "ERROR" }

        /// What it needs from you, if anything, as its author.
        var needs: String? {
            if isFailing { return "Checks failing" }
            if review == "CHANGES_REQUESTED" { return "Changes requested" }
            if mergeable == "CONFLICTING" { return "Conflicts" }
            if review == "APPROVED", checks != "PENDING", !isDraft { return "Ready to merge" }
            return nil
        }
    }

    struct IssueItem: Identifiable, Hashable {
        let id: String
        let repo: String
        let number: Int
        let title: String
        let url: URL
        let updatedAt: Date
    }

    private(set) var reviewRequests: [PullRequestItem] = []
    private(set) var myPullRequests: [PullRequestItem] = []
    private(set) var myIssues: [IssueItem] = []
    private(set) var checkedAt: Date?
    private(set) var checking = false
    private(set) var error: String?
    /// Review requests put away from the menu, by PR ID.
    private(set) var dismissed: Set<String>

    @ObservationIgnored var api: () -> GitHubAPI? = { nil }
    /// Starts Claude's review of a PR, as Review with Claude does.
    @ObservationIgnored var startReview: (PullRequestReference) -> Void = { NSWorkspace.shared.open($0.url) }
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var known: Set<String>?
    @ObservationIgnored private var lastNeeds: [String: String] = [:]

    private init() {
        dismissed = Set(UserDefaults.standard.stringArray(forKey: "dismissedReviewRequests") ?? [])
    }

    static var interval: Int {
        UserDefaults.standard.object(forKey: intervalKey) as? Int ?? 5
    }

    var waitingReviews: [PullRequestItem] { reviewRequests.filter { !dismissed.contains($0.id) } }

    /// Things that want you: reviews waiting, and your PRs needing action
    /// (not ready-to-merge ones).
    var count: Int {
        waitingReviews.count + myPullRequests.filter { $0.needs != nil && $0.needs != "Ready to merge" }.count
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let minutes = Self.interval
                if minutes > 0 { await self.check() }
                try? await Task.sleep(for: .seconds(max(minutes, 1) * 60))
            }
        }
    }

    func dismiss(_ id: String) {
        dismissed.insert(id)
        UserDefaults.standard.set(Array(dismissed), forKey: "dismissedReviewRequests")
    }

    /// Asks GitHub now.
    func check() async {
        guard let api = api(), !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let found = try await api.engineerWork()
            error = nil
            checkedAt = .now
            notice(found.reviews, mine: found.mine)
            reviewRequests = found.reviews
            myPullRequests = found.mine
            myIssues = found.issues
            // Forget dismissals of requests that are gone.
            let ids = Set(found.reviews.map(\.id))
            if dismissed.contains(where: { !ids.contains($0) }) {
                dismissed = dismissed.filter(ids.contains)
                UserDefaults.standard.set(Array(dismissed), forKey: "dismissedReviewRequests")
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Notifying

    private static let reviewCategory = "reviewRequest"
    private static let pullRequestCategory = "myPullRequest"

    private func notice(_ reviews: [PullRequestItem], mine: [PullRequestItem]) {
        let notifies = UserDefaults.standard.object(forKey: SessionStore.notifiesKey) as? Bool ?? true
        defer {
            known = Set(reviews.map(\.id))
            lastNeeds = Dictionary(uniqueKeysWithValues: mine.map { ($0.id, $0.needs ?? "") })
        }
        // The first check learns what's there.
        guard let known, notifies else { return }
        registerCategories()
        for pr in reviews where !known.contains(pr.id) && !dismissed.contains(pr.id) {
            post(id: "review-\(pr.id)", title: "Review requested", subtitle: "\(pr.repo.split(separator: "/").last ?? "")#\(pr.number) \(pr.title)",
                 body: pr.author.map { "From \($0)" } ?? "", category: Self.reviewCategory, info: ["review": pr.id])
        }
        for pr in mine {
            let needs = pr.needs ?? ""
            guard let before = lastNeeds[pr.id], before != needs, !needs.isEmpty else { continue }
            post(id: "mine-\(pr.id)", title: needs, subtitle: "\(pr.repo.split(separator: "/").last ?? "")#\(pr.number) \(pr.title)",
                 body: needs == "Ready to merge" ? "Approved, and its checks have passed." : "Your pull request needs you.",
                 category: Self.pullRequestCategory, info: ["mine": pr.id])
        }
    }

    private func post(id: String, title: String, subtitle: String, body: String, category: String, info: [String: String]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private var registered = false

    private func registerCategories() {
        guard !registered else { return }
        registered = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        let review = UNNotificationCategory(identifier: Self.reviewCategory, actions: [
            UNNotificationAction(identifier: "review:claude", title: "Review with Claude"),
            UNNotificationAction(identifier: "review:open", title: "Open on GitHub"),
        ], intentIdentifiers: [])
        let mine = UNNotificationCategory(identifier: Self.pullRequestCategory, actions: [
            UNNotificationAction(identifier: "review:open", title: "Open on GitHub"),
        ], intentIdentifiers: [])
        // Categories are app-wide: keep the sessions' quick replies.
        Task {
            let center = UNUserNotificationCenter.current()
            var all = await center.notificationCategories().filter { $0.identifier != Self.reviewCategory && $0.identifier != Self.pullRequestCategory }
            all.insert(review)
            all.insert(mine)
            center.setNotificationCategories(all)
        }
    }

    /// A notification of ours was answered.
    func handle(action: String, info: [AnyHashable: Any]) {
        let id = (info["review"] ?? info["mine"]) as? String
        guard let id, let pr = (reviewRequests + myPullRequests).first(where: { $0.id == id }) else { return }
        switch action {
        case "review:claude": startReview(pr.reference)
        default: NSWorkspace.shared.open(pr.url)
        }
    }
}

extension GitHubAPI {
    /// One query: open PRs your review is requested on, your open PRs, and
    /// your open issues, each recently updated first.
    func engineerWork() async throws -> (reviews: [EngineerWatch.PullRequestItem], mine: [EngineerWatch.PullRequestItem], issues: [EngineerWatch.IssueItem]) {
        struct Login: Decodable { let login: String }
        struct Repository: Decodable { let nameWithOwner: String }
        struct Rollup: Decodable { let state: String? }
        struct Commit: Decodable { let statusCheckRollup: Rollup? }
        struct CommitNode: Decodable { let commit: Commit }
        struct Node: Decodable {
            let __typename: String?
            let id: String?
            let number: Int?
            let title: String?
            let url: URL?
            let isDraft: Bool?
            let createdAt: Date?
            let updatedAt: Date?
            let reviewDecision: String?
            let mergeable: String?
            let author: Login?
            let repository: Repository?
            let commits: Connection<CommitNode>?
        }
        struct Search: Decodable { let nodes: [Node] }
        struct Response: Decodable {
            let reviews: Search
            let mine: Search
            let issues: Search
        }
        let fields = "id number title url isDraft createdAt updatedAt reviewDecision mergeable author { login } repository { nameWithOwner } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }"
        let response: Response = try await query("""
            query {
              reviews: search(type: ISSUE, query: "is:open is:pr review-requested:@me archived:false sort:updated-desc", first: 40) { nodes { __typename ... on PullRequest { \(fields) } } }
              mine: search(type: ISSUE, query: "is:open is:pr author:@me archived:false sort:updated-desc", first: 40) { nodes { __typename ... on PullRequest { \(fields) } } }
              issues: search(type: ISSUE, query: "is:open is:issue assignee:@me archived:false sort:updated-desc", first: 25) { nodes { __typename ... on Issue { id number title url updatedAt repository { nameWithOwner } } } }
            }
            """)
        func pr(_ node: Node) -> EngineerWatch.PullRequestItem? {
            guard let id = node.id, let number = node.number, let title = node.title, let url = node.url, let repo = node.repository?.nameWithOwner else { return nil }
            return .init(
                id: id, repo: repo, number: number, title: title, url: url, author: node.author?.login,
                isDraft: node.isDraft ?? false, createdAt: node.createdAt ?? .now, updatedAt: node.updatedAt ?? .now,
                review: node.reviewDecision, checks: node.commits?.nodes.last?.commit.statusCheckRollup?.state, mergeable: node.mergeable
            )
        }
        let issues = response.issues.nodes.compactMap { node -> EngineerWatch.IssueItem? in
            guard let id = node.id, let number = node.number, let title = node.title, let url = node.url, let repo = node.repository?.nameWithOwner else { return nil }
            return .init(id: id, repo: repo, number: number, title: title, url: url, updatedAt: node.updatedAt ?? .now)
        }
        return (response.reviews.nodes.compactMap(pr), response.mine.nodes.compactMap(pr), issues)
    }
}

// MARK: - The menu bar

/// The menu bar's window: agents waiting on you, reviews asked of you (with
/// Review with Claude), your PRs and what they need, and your issues. A
/// click opens the session, the PR or the issue. Sized to what's in it, up
/// to a height, then it scrolls.
struct EngineerMenu: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    private let watch = EngineerWatch.shared
    @State private var contentHeight: CGFloat = 0

    private static let maxHeight: CGFloat = 560

    var body: some View {
        let waiting = sessions.sessions.values.filter { sessions.attention[$0.id] != nil }
            .sorted { (sessions.attention[$0.id] ?? .now) < (sessions.attention[$1.id] ?? .now) }
        let needing = watch.myPullRequests.filter { $0.needs != nil }
        let others = watch.myPullRequests.filter { $0.needs == nil }
        VStack(spacing: 0) {
            header(count: waiting.count + watch.count)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if waiting.isEmpty && watch.waitingReviews.isEmpty && needing.isEmpty {
                        allClear
                    }
                    if !waiting.isEmpty {
                        section("Agents waiting on you", symbol: "sparkle", count: waiting.count, tint: .orange) {
                            ForEach(waiting) { session in
                                MenuRow(
                                    symbol: sessions.state(session.id) == .needsYou ? "questionmark.bubble.fill" : "text.bubble.fill",
                                    tint: sessions.state(session.id).color,
                                    title: session.title,
                                    detail: "\(sessions.state(session.id).label)\(sessions.attention[session.id].map { " · \($0.formatted(.relative(presentation: .named)))" } ?? "")"
                                ) {
                                    sessions.show(session.id, with: openWindow)
                                    NSApp.activate()
                                }
                            }
                        }
                    }
                    if !watch.waitingReviews.isEmpty {
                        section("Reviews asked of you", symbol: "eye", count: watch.waitingReviews.count, tint: .accentColor) {
                            ForEach(watch.waitingReviews) { pr in
                                reviewRow(pr)
                            }
                        }
                    }
                    if !needing.isEmpty {
                        section("Your PRs needing you", symbol: "arrow.triangle.pull", count: needing.count, tint: ChartPalette.critical) {
                            ForEach(needing) { pr in pullRequestRow(pr) }
                        }
                    }
                    if !others.isEmpty {
                        section("Your other PRs", symbol: "arrow.triangle.pull", count: others.count, tint: .secondary) {
                            ForEach(others) { pr in pullRequestRow(pr) }
                        }
                    }
                    if !watch.myIssues.isEmpty {
                        section("Assigned to you", symbol: "smallcircle.filled.circle", count: watch.myIssues.count, tint: .green) {
                            ForEach(watch.myIssues.prefix(8)) { issue in
                                MenuRow(symbol: "smallcircle.filled.circle", tint: .green, title: issue.title,
                                        detail: "\(Self.short(issue.repo))#\(issue.number) · updated \(issue.updatedAt.formatted(.relative(presentation: .named)))") {
                                    NSWorkspace.shared.open(issue.url)
                                }
                            }
                        }
                    }
                    if let error = watch.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // A scroll view has no height of its own in a menu bar window.
            .frame(height: min(max(contentHeight, 80), Self.maxHeight))
            Divider()
            footer
        }
        .frame(width: 400)
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your work").font(.headline)
                Group {
                    if watch.checking {
                        Text("Checking GitHub")
                    } else if let checkedAt = watch.checkedAt {
                        Text("\(count == 0 ? "Nothing" : "\(count) thing\(count == 1 ? "" : "s")") waiting · checked \(checkedAt.formatted(.relative(presentation: .named)))")
                    } else if EngineerWatch.interval == 0 {
                        Text("Checks are off in Settings")
                    } else {
                        Text("Not checked yet")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await watch.check() }
            } label: {
                if watch.checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 20)
            .help("Check now")
            .disabled(watch.checking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var allClear: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title)
                .foregroundStyle(ChartPalette.good)
            Text("All clear").font(.headline)
            Text("No reviews waiting, nothing failing, no agent waiting on you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(title: "Open Gannin", symbol: "macwindow") {
                openWindow(id: "main")
                NSApp.activate()
            }
            if !sessions.sessions.isEmpty {
                FooterButton(title: "Sessions", symbol: "terminal") {
                    openWindow(id: SessionStore.windowID)
                    NSApp.activate()
                }
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func section<Content: View>(_ title: String, symbol: String, count: Int, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(tint.opacity(0.18), in: Capsule())
                    .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            }
            .padding(.horizontal, 6)
            content()
        }
    }

    private func pullRequestRow(_ pr: EngineerWatch.PullRequestItem) -> some View {
        let (symbol, tint): (String, Color) = switch pr.needs {
        case "Checks failing": ("xmark.circle.fill", ChartPalette.critical)
        case "Changes requested": ("arrow.uturn.backward.circle.fill", .orange)
        case "Conflicts": ("exclamationmark.triangle.fill", .orange)
        case "Ready to merge": ("checkmark.circle.fill", ChartPalette.good)
        default: (pr.isDraft ? "pencil.circle" : "circle.dotted", .secondary)
        }
        return MenuRow(symbol: symbol, tint: tint, title: pr.title,
                       detail: "\(Self.short(pr.repo))#\(pr.number) · \(pr.needs ?? (pr.isDraft ? "Draft" : pr.checks == "PENDING" ? "Checks running" : "In review"))") {
            NSWorkspace.shared.open(pr.url)
        }
    }

    private func reviewRow(_ pr: EngineerWatch.PullRequestItem) -> some View {
        MenuRow(symbol: "eye.circle.fill", tint: .accentColor, title: pr.title,
                detail: "\(Self.short(pr.repo))#\(pr.number)\(pr.author.map { " · \($0)" } ?? "") · \(pr.updatedAt.formatted(.relative(presentation: .named)))",
                action: { NSWorkspace.shared.open(pr.url) }) {
            HStack(spacing: 4) {
                if let review = sessions.review(of: pr.id) {
                    Button("Open Review") {
                        sessions.show(review.id, with: openWindow)
                        NSApp.activate()
                    }
                } else {
                    Button("Review") {
                        watch.startReview(pr.reference)
                        NSApp.activate()
                    }
                    .help("Review with Claude")
                }
                Button {
                    watch.dismiss(pr.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss: it comes back if you're asked again")
            }
            .controlSize(.small)
        }
    }

    static func short(_ repo: String) -> String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }
}

/// A row in the menu: an icon, the title and a line beneath, highlighted
/// under the pointer, with room for buttons on the right.
private struct MenuRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let action: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            accessory()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
}

extension MenuRow where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String, action: @escaping () -> Void) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail, action: action) { EmptyView() }
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The menu bar's icon, with how many things want you.
struct MenuBarLabel: View {
    let sessions: SessionStore
    private let watch = EngineerWatch.shared

    var body: some View {
        let count = watch.count + sessions.attention.keys.filter { sessions.sessions[$0] != nil }.count
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "checklist.unchecked" : "checklist")
            if count > 0 { Text("\(count)") }
        }
    }
}

/// On Agents: the reviews asked of you in this org, each with Review with
/// Claude.
struct ReviewRequestsSection: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    let org: String
    private let watch = EngineerWatch.shared

    var body: some View {
        let requests = watch.waitingReviews.filter { $0.org == org }
        if !requests.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reviews asked of you").font(.headline)
                ForEach(requests) { pr in
                    HStack(spacing: 10) {
                        Image(systemName: "eye").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Link(pr.title, destination: pr.url).lineLimit(1)
                            Text("\(pr.repo)#\(pr.number)\(pr.author.map { " · \($0)" } ?? "") · updated \(pr.updatedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let review = sessions.review(of: pr.id) {
                            Button("Open Review") { sessions.show(review.id, with: openWindow) }
                        } else {
                            Button("Review with Claude") { watch.startReview(pr.reference) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Dismiss") { watch.dismiss(pr.id) }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
#endif
