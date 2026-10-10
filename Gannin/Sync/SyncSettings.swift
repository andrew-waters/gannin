import Foundation

/// What Gannin fetches from GitHub, each with its own switch and interval
/// in Settings › Sync, and the sources the usage ledger (`APIUsage`) charges
/// requests to. The last few are for the ledger only: things fetched because
/// you opened or did something.
nonisolated enum SyncSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case workload
    case members
    case fullSearch
    case metrics
    case issues
    case openIssues
    case issueText
    case workLog
    case boards
    case harness
    case actions
    case releases
    case reviewRequests
    case watchedReviews
    case sessionPullRequests
    case sessionChecks
    /// Opening an issue, PR or anything looked up for it.
    case details
    /// Writes you confirmed.
    case writes
    /// Signing in, the org list and settings' pickers.
    case account
    case other

    var id: String { rawValue }

    /// The rows Settings › Sync shows, in order.
    static var settings: [SyncSource] { allCases.filter(\.isSetting) }

    /// The sources the ledger lists, in order: sub-rows that only space out
    /// their parent's fetches are charged to it.
    static var ledger: [SyncSource] { allCases.filter { ![.members, .fullSearch, .openIssues, .sessionChecks].contains($0) } }

    var isSetting: Bool {
        switch self {
        case .details, .writes, .account, .other: false
        default: true
        }
    }

    var title: String {
        switch self {
        case .workload: "Workload"
        case .members: "Members and teams"
        case .fullSearch: "Full search"
        case .metrics: "PR metrics"
        case .issues: "Issue history"
        case .openIssues: "Every open issue"
        case .issueText: "Issue descriptions and comments"
        case .workLog: "Work log"
        case .boards: "Project boards"
        case .harness: "Harness"
        case .actions: "GitHub Actions"
        case .releases: "Milestones and releases"
        case .reviewRequests: "Your reviews and PRs"
        case .watchedReviews: "Watched reviews"
        case .sessionPullRequests: "Session pull requests"
        case .sessionChecks: "While checks run"
        case .details: "Items you open"
        case .writes: "Changes you make"
        case .account: "Account and settings"
        case .other: "Other"
        }
    }

    var detail: String {
        switch self {
        case .workload: "Open PRs and issues, and PRs merged in the lookback: what changed since the last fetch. Fetched when a page needs it."
        case .members: "The org's members and teams. Refresh fetches them too."
        case .fullSearch: "Everything searched again rather than only what changed."
        case .metrics: "Merged PRs for the Dashboard, PR flow and Scorecard."
        case .issues: "Issues closed in the window and open ones, with board moves, for the issue pages, Inbox, Views and meetings."
        case .openIssues: "Every open issue again, as board moves don't count as updates."
        case .issueText: "For searching in descriptions, after each issue sync."
        case .workLog: "Commits, reviews, issues opened and issue comments for Activity and Standup, once one has been opened."
        case .boards: "Board lists, fields and items."
        case .harness: "Plans, requirements, skills and the team's shared settings. It stays on, as your team's settings are kept there."
        case .actions: "Workflow runs for the CI page, once it has been opened. REST, with its own budget."
        case .releases: "Milestones, releases, downloads and stars, once the Releases page has been opened."
        case .reviewRequests: "PRs your review is asked on, your own PRs and your issues, for the menu bar, Agents and notifications."
        case .watchedReviews: "Reviewed PRs Claude watches for new commits and comments."
        case .sessionPullRequests: "Each running session's PRs: checks, reviews and threads. The PRs pane still looks when you open it."
        case .sessionChecks: "How often while a session's PR has checks running."
        case .details: "Issues and PRs opened in a drawer or window, and what's looked up for them."
        case .writes: "Issues created, fields set, reviews posted and commits to the harness."
        case .account: "Your profile, orgs, and pickers in Settings."
        case .other: "Anything not charged to a source above."
        }
    }

    /// A row shown beneath another, which turns it off with it.
    var parent: SyncSource? {
        switch self {
        case .members, .fullSearch: .workload
        case .openIssues, .issueText: .issues
        case .sessionChecks: .sessionPullRequests
        default: nil
        }
    }

    /// Whether it can be turned off. The workload is what everything else
    /// stands on, and the harness holds the team's settings; sub-rows go
    /// with their parent, except the issue text, which has a switch of its own.
    var canTurnOff: Bool {
        switch self {
        case .workload, .members, .fullSearch, .harness, .openIssues, .sessionChecks: false
        default: isSetting
        }
    }

    /// Spent from the REST budget rather than GraphQL's.
    var usesREST: Bool { self == .actions }

    var defaultInterval: TimeInterval {
        switch self {
        case .workload: 5 * 60
        case .members, .openIssues: 60 * 60
        case .fullSearch: 24 * 60 * 60
        case .reviewRequests, .watchedReviews: 5 * 60
        case .sessionPullRequests: 2 * 60
        case .sessionChecks: 60
        default: 10 * 60
        }
    }

    var intervalOptions: [TimeInterval] {
        let minute: TimeInterval = 60, hour: TimeInterval = 60 * 60, day: TimeInterval = 24 * 60 * 60
        switch self {
        case .members, .openIssues: return [30 * minute, hour, 3 * hour, 6 * hour, day]
        case .fullSearch: return [6 * hour, 12 * hour, day, 3 * day, 7 * day]
        case .sessionPullRequests, .sessionChecks: return [30, minute, 2 * minute, 5 * minute, 10 * minute]
        case .reviewRequests, .watchedReviews: return [minute, 2 * minute, 5 * minute, 10 * minute, 15 * minute, 30 * minute, hour]
        case .workload: return [2 * minute, 5 * minute, 10 * minute, 15 * minute, 30 * minute, hour]
        default: return [5 * minute, 10 * minute, 30 * minute, hour, 3 * hour, 6 * hour, day]
        }
    }

    var offKey: String { "sync.\(rawValue).off" }
    var intervalKey: String { "sync.\(rawValue).interval" }

    /// The sync run a query belongs to, when no fetcher named its source.
    @MainActor init(kind: SyncRun.Kind) {
        switch kind {
        case .workload: self = .workload
        case .metrics: self = .metrics
        case .workLog: self = .workLog
        case .issues: self = .issues
        case .issueText: self = .issueText
        case .projects: self = .boards
        case .actions: self = .actions
        case .releases: self = .releases
        }
    }
}

/// The user's choices in Settings › Sync, read by every fetcher. App-wide,
/// not per org: the budget is the token's.
nonisolated enum SyncSettings {
    /// Points (or REST requests) kept for what you do by hand: automatic
    /// fetches wait for the reset once the budget drops under it.
    static let reserveKey = "sync.reserve"
    static let defaultReserve = 500
    static let reserveOptions = [250, 500, 1000, 1500, 2500]

    static func isOn(_ source: SyncSource) -> Bool {
        if let parent = source.parent, !isOn(parent) { return false }
        return !source.canTurnOff || !UserDefaults.standard.bool(forKey: source.offKey)
    }

    /// How old its data may get before it's fetched again.
    static func interval(_ source: SyncSource) -> TimeInterval {
        let stored = UserDefaults.standard.double(forKey: source.intervalKey)
        return stored > 0 ? stored : source.defaultInterval
    }

    /// Whether data fetched at `date` is due again.
    static func isDue(_ source: SyncSource, since date: Date?, now: Date = .now) -> Bool {
        guard let date else { return true }
        return now.timeIntervalSince(date) >= interval(source)
    }

    static func reserve() -> Int {
        let stored = UserDefaults.standard.integer(forKey: reserveKey)
        return stored > 0 ? stored : defaultReserve
    }

    /// The review request check was minutes in Settings › General, 0 for
    /// never; it's a source here now. Once.
    static func migrate() {
        let defaults = UserDefaults.standard
        let old = "reviewCheckMinutes"
        guard let minutes = defaults.object(forKey: old) as? Int else { return }
        if minutes == 0 {
            defaults.set(true, forKey: SyncSource.reviewRequests.offKey)
        } else {
            defaults.set(TimeInterval(minutes * 60), forKey: SyncSource.reviewRequests.intervalKey)
        }
        defaults.removeObject(forKey: old)
    }

    /// "30 seconds", "5 minutes", "1 hour", "3 days".
    static func describe(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        if seconds < 60 { return plural(seconds, "second") }
        if seconds < 3600 { return plural(seconds / 60, "minute") }
        if seconds < 86_400 { return plural(seconds / 3600, "hour") }
        return plural(seconds / 86_400, "day")
    }
}
