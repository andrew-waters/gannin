import AppKit
import Foundation
import Observation
import SwiftTerm
import UserNotifications

/// A Claude Code session on one issue, with claude running in a terminal
/// inside Gannin: in the org's harness checkout, the issue having its own
/// folder there (`.worktrees/<branch>/`) for a worktree of each repo it
/// touches, on a branch of its own.
struct CodeSession: Codable, Identifiable, Hashable {
    let id: UUID
    let issue: IssueReference
    /// `owner/name` of the repo the code is in, which needn't be the
    /// issue's: an org can keep its issues in a repo of their own. For a
    /// session in the harness, the harness itself, and claude works out the
    /// code repos.
    let repo: String
    /// A var so a name from an older build, with no worktree made yet, can
    /// be worked out again.
    var branch: String
    let createdAt: Date
    /// The PRs claude opened, spotted in its `gh pr create`: one per repo
    /// the issue touches. GitHub is also searched for the branch's.
    var pullRequests: [URL] = []
    /// The command that reaches the server it runs on (`ssh -t devbox`);
    /// nil for this Mac. Kept from when it was made, since that's where its
    /// worktree is.
    var connect: String? = nil
    /// The server's workspace, as a path there (`~/Gannin`), for sessions
    /// made before they ran in the harness.
    var remoteWorkspace: String? = nil
    /// The harness it runs in: `owner/name`, and its checkout on the box the
    /// session runs on (`~` allowed). Nil for sessions made before, which
    /// have one repo's worktree beside its clone in the workspace.
    var harnessRepo: String? = nil
    var harnessPath: String? = nil
    /// Its folder in the harness (`sessions/product-123`), once its brief
    /// and `session.json` are committed there; nil when they weren't.
    var harnessFolder: String? = nil
    /// A helper on another's issue (writing tests, reviewing): the session
    /// it helps, in the same folder and branch with its own conversation.
    var parentID: UUID? = nil
    /// What the helper is for, as its tab says ("Tests", "Review").
    var role: String? = nil
    /// The helper's first prompt, in place of the issue's.
    var prompt: String? = nil
    /// What the first prompt adds from the team's prompts and skills in
    /// the harness, picked when it started.
    var instructions: String? = nil
    /// A reviewer reads and reports but can't edit files.
    var isReviewer = false
    /// When its claude last did something, for spotting stale sessions.
    var lastActiveAt: Date? = nil
    /// The PR a review session reviews; `issue` then names the PR, so tabs
    /// and rows read the same.
    var reviewOf: PullRequestReference? = nil
    /// A planning session's topic and shared documents.
    var planning: PlanningInfo? = nil
    /// An Ask session's title and first message.
    var ask: AskInfo? = nil
    /// A quick change's note and screenshots, with or without an issue.
    var quickChange: QuickChangeInfo? = nil
    /// The name its tab was given, in place of the issue's or PR's title.
    var name: String? = nil
    /// A review's result, kept from its transcript so it can be read again
    /// without starting claude; and what you made of it.
    var reviewResult: SessionTranscript.ReviewResult? = nil
    var reviewDraft: ReviewDraft? = nil
    /// The review config it was started with (the harness's and the repo's,
    /// `ReviewConfig.Layers.resolved`), for its checks and skipped files.
    var reviewConfig: ReviewConfig? = nil
    /// Finished: in the history, its claude ended and worktrees gone.
    var archivedAt: Date? = nil
    /// A review's PR, watched for new commits and comments to review
    /// again; nil until its first review finishes.
    var watch: ReviewWatch? = nil
    /// What's been seen on its PRs (failed checks, and threads and reviews
    /// at their latest comment), kept so a relaunch only flags what came
    /// since; nil until the first look.
    var pullRequestsSeen: Set<String>? = nil
    /// Whether new failures and feedback on its PRs go to claude by
    /// themselves; nil for the user's default (`sendsFeedbackKey`).
    var sendsFeedback: Bool? = nil
    /// Whether a second agent reviews its change when it says it's ready
    /// (`PairReview.swift`); nil for the user's default (`pairReviewKey`).
    var pairsReview: Bool? = nil
    /// That review's loop, once it has been asked for.
    var pairing: PairReview? = nil
    /// The last `review-request` token taken from its hook folder, so one
    /// read again after a relaunch isn't asked twice.
    var reviewRequest: String? = nil
    /// The Apple container it runs in (`SandboxPlacement.containerName`,
    /// its issue's, shared with helpers); nil on the Mac or server itself.
    var sandbox: String? = nil
    /// Why it runs on the Mac although sandboxing was on when it started:
    /// a repo that needs the Mac, no GitHub token, or the user's choice.
    var hostReason: String? = nil

    var isRemote: Bool { connect != nil }
    var isSandboxed: Bool { sandbox != nil }
    var isHelper: Bool { parentID != nil }
    var isPullRequestReview: Bool { reviewOf != nil }
    /// As a tab or row names it.
    var title: String { name ?? ask?.title ?? role.map { "\($0): \(issue.title)" } ?? issue.title }
    var isInHarness: Bool { harnessPath != nil && harnessRepo != nil }

    var org: String { issue.org }
    /// Claude Code wants its session IDs in lower case.
    var claudeID: String { id.uuidString.lowercased() }
    /// How the PR should refer to the issue: with its repo when that's
    /// another one, so GitHub still links them.
    var closingReference: String { repo == issue.repo ? "#\(issue.number)" : issue.reference }
}

extension CodeSession {
    private enum LegacyKeys: String, CodingKey { case pullRequest }

    /// Sessions saved before `repo` worked in the issue's repo.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        issue = try container.decode(IssueReference.self, forKey: .issue)
        repo = try container.decodeIfPresent(String.self, forKey: .repo) ?? issue.repo
        branch = try container.decode(String.self, forKey: .branch)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // Sessions saved when there was one PR at most.
        pullRequests = try container.decodeIfPresent([URL].self, forKey: .pullRequests)
            ?? (try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(URL.self, forKey: .pullRequest)).map { [$0] }
            ?? []
        connect = try container.decodeIfPresent(String.self, forKey: .connect)
        remoteWorkspace = try container.decodeIfPresent(String.self, forKey: .remoteWorkspace)
        harnessRepo = try container.decodeIfPresent(String.self, forKey: .harnessRepo)
        harnessPath = try container.decodeIfPresent(String.self, forKey: .harnessPath)
        harnessFolder = try container.decodeIfPresent(String.self, forKey: .harnessFolder)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
        isReviewer = try container.decodeIfPresent(Bool.self, forKey: .isReviewer) ?? false
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt)
        reviewOf = try container.decodeIfPresent(PullRequestReference.self, forKey: .reviewOf)
        planning = try container.decodeIfPresent(PlanningInfo.self, forKey: .planning)
        ask = try container.decodeIfPresent(AskInfo.self, forKey: .ask)
        quickChange = try? container.decodeIfPresent(QuickChangeInfo.self, forKey: .quickChange)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        reviewResult = try container.decodeIfPresent(SessionTranscript.ReviewResult.self, forKey: .reviewResult)
        reviewDraft = try container.decodeIfPresent(ReviewDraft.self, forKey: .reviewDraft)
        reviewConfig = try? container.decodeIfPresent(ReviewConfig.self, forKey: .reviewConfig)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        watch = try container.decodeIfPresent(ReviewWatch.self, forKey: .watch)
        pullRequestsSeen = try container.decodeIfPresent(Set<String>.self, forKey: .pullRequestsSeen)
        sendsFeedback = try container.decodeIfPresent(Bool.self, forKey: .sendsFeedback)
        pairsReview = try container.decodeIfPresent(Bool.self, forKey: .pairsReview)
        pairing = try? container.decodeIfPresent(PairReview.self, forKey: .pairing)
        reviewRequest = try container.decodeIfPresent(String.self, forKey: .reviewRequest)
        sandbox = try container.decodeIfPresent(String.self, forKey: .sandbox)
        hostReason = try container.decodeIfPresent(String.self, forKey: .hostReason)
    }
}

extension IssueReference {
    /// `owner/name#123`, as a plain string so the number isn't grouped.
    var reference: String { "\(repo)#\(number)" }
}

/// A session as the harness keeps it, in `sessions/<repo>-<number>/session.json`
/// beside its brief, so the team can see who's working on what, where.
struct SessionRecord: Codable {
    /// `owner/name#123`; nil for a quick change with no issue.
    var issue: String?
    var title: String
    var url: URL
    /// The code repos it has worktrees for.
    var repos: [String]
    var branch: String
    var startedBy: String?
    var startedAt: Date
    /// Where it runs: this Mac's name, or the Connect with command.
    var box: String
    var pullRequests: [URL]
    /// Set when Gannin finished it: its PRs merged and its worktrees gone.
    var finishedAt: Date?

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    var json: String { String(decoding: (try? Self.encoder.encode(self)) ?? Data(), as: UTF8.self) + "\n" }
}

/// What a session's claude is doing, as its hooks last said.
enum SessionState: String {
    /// Cloning, making the worktree, or starting claude.
    case starting
    case working
    /// A permission prompt or a question: claude is waiting on you.
    case needsYou = "needs-you"
    /// Claude finished its turn.
    case idle
    /// Claude has exited; the shell is still open in the worktree.
    case exited
    /// Nothing is running: the terminal ended, or Gannin was quit.
    case stopped

    var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .idle: "Your turn"
        case .exited: "Claude exited"
        case .stopped: "Stopped"
        }
    }
}

/// Every Claude Code session, kept across launches so a session can be
/// resumed (`claude --resume`) in its worktree. The terminals live here, not
/// in the windows, so closing a session's window leaves claude running.
///
/// Each session has a folder holding its brief, the hooks claude reports
/// through (they write its state to a file, read here every second while
/// anything runs) and the script its terminal runs: clone or pull the
/// harness, clone the repo into its `projects/` if it isn't yet (unless the
/// harness is the code repo itself), add the worktree under `.worktrees/`,
/// copy the brief in, then start or resume claude.
@Observable
final class SessionStore {
    /// Where Gannin clones a harness that isn't checked out on this Mac yet,
    /// as a path (`~` allowed).
    static let workspaceKey = "sessionsWorkspace"
    static let defaultWorkspace = "~/Gannin"
    /// Run sessions on a server: the command that gets there, such as
    /// `ssh -t devbox`, with `{command}` where the rest goes (else at the
    /// end). Empty runs them on this Mac.
    static let connectKey = "sessionsConnect"

    static var connectCommand: String? {
        let command = (UserDefaults.standard.string(forKey: connectKey) ?? "").trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? nil : command
    }

    /// A harness's checkout on this Mac, as set in the org's Settings.
    static func harnessPathKey(_ org: String, repo: String) -> String { "sessionsHarnessPath.\(org).\(repo)" }
    /// And on the server, which has no default: only you know that box.
    static func remoteHarnessPathKey(_ org: String, repo: String) -> String { "sessionsRemoteHarnessPath.\(org).\(repo)" }

    /// Checkouts set when an org had one harness become that harness's.
    static func migrateHarnessPaths(org: String, primary repo: String) {
        let defaults = UserDefaults.standard
        for (old, new) in [("sessionsHarnessPath.\(org)", harnessPathKey(org, repo: repo)), ("sessionsRemoteHarnessPath.\(org)", remoteHarnessPathKey(org, repo: repo))] {
            if let value = defaults.string(forKey: old), !value.isEmpty, (defaults.string(forKey: new) ?? "").isEmpty {
                defaults.set(value, forKey: new)
            }
            defaults.removeObject(forKey: old)
        }
    }

    /// The harness checkout on this Mac: the one set, else a checkout you
    /// already have, else `<workspace>/<name>` for Gannin to clone
    /// (`<org>-harness` for one called harness).
    static func localHarnessPath(org: String, repo: String) -> String {
        let saved = (UserDefaults.standard.string(forKey: harnessPathKey(org, repo: repo)) ?? "").trimmingCharacters(in: .whitespaces)
        if !saved.isEmpty { return saved }
        return existingCheckout(of: repo) ?? defaultHarnessPath(org: org, repo: repo)
    }

    static func defaultHarnessPath(org: String, repo: String) -> String {
        let workspace = UserDefaults.standard.string(forKey: workspaceKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultWorkspace
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        return workspace + "/" + (name == "harness" ? "\(org)-harness" : "\(org)-\(name)")
    }

    static func remoteHarnessPath(org: String, repo: String) -> String? {
        let path = (UserDefaults.standard.string(forKey: remoteHarnessPathKey(org, repo: repo)) ?? "").trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    /// Where new sessions in a harness run it: on the server when there's
    /// a Connect with command, else on this Mac. Nil when that's the
    /// server and its checkout hasn't been set.
    static func harnessPath(org: String, repo: String) -> String? {
        connectCommand == nil ? localHarnessPath(org: org, repo: repo) : remoteHarnessPath(org: org, repo: repo)
    }

    /// Why sessions can't start in the harness, if they can't.
    static func unavailable(org: String, harness: HarnessConfig?, what: String = "Sessions") -> String? {
        guard let harness else {
            return "\(what) run in the org's harness. Pick or create it in the org's Settings, under Harness."
        }
        if connectCommand != nil, remoteHarnessPath(org: org, repo: harness.repo) == nil {
            return "Sessions run on your server. Set where \(harness.repo) is checked out there in the org's Settings, under Harness."
        }
        return nil
    }

    /// A checkout of the repo in one of the usual places, found by its
    /// origin: `~/Code/<owner>/<name>`, and
    /// the like.
    static func existingCheckout(of repo: String) -> String? {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let (owner, name) = (parts[0], parts[1])
        let candidates = ["Code", "Developer", "Projects", "src", "code", "dev"]
            .flatMap { ["~/\($0)/\(owner)/\(name)", "~/\($0)/\(name)"] }
            + ["~/\(owner)/\(name)", "~/\(name)", defaultWorkspace + "/\(owner)/\(name)"]
        return candidates.first { LocalClones.isCheckout($0, of: repo) }
    }

    /// Whether Work on This asks before committing a session's brief and
    /// record to the org's harness; off once "Don't ask again" is ticked.
    static func asksBeforeRecordingKey(_ org: String) -> String { "sessionsRecordWithoutAsking.\(org)" }

    /// The one window sessions open in, each a tab.
    static let windowID = "sessions"
    /// The open tabs, in order, kept across launches.
    static let tabsKey = "sessionsTabs"

    private(set) var sessions: [UUID: CodeSession] = [:]
    /// The sessions window's tabs, in order, and the one showing.
    private(set) var tabs: [UUID] = []
    var selectedTab: UUID? {
        didSet { if selectedTab != oldValue { looked() } }
    }
    /// Whether the sessions window is key, as it says, so the tab you're
    /// looking at isn't flagged.
    var windowIsKey = false {
        didSet { if windowIsKey != oldValue { looked() } }
    }
    /// Sessions that finished a turn or want an answer since you last looked
    /// at them, and since when: tabs marked, the Dock badge, a notification.
    private(set) var attention: [UUID: Date] = [:]
    /// Comments on a session's diff, not yet sent to claude.
    private(set) var drafts: [UUID: [DiffComment]] = [:]
    /// Review comments and checks already sent to a session's claude, by
    /// their URL, so they aren't offered again. For this launch only.
    private(set) var sent: [UUID: Set<String>] = [:]
    /// What you've made of a review's findings, and comments of your own;
    /// kept with the session.
    var reviewDrafts: [UUID: ReviewDraft] = [:] {
        didSet {
            var changed = false
            for (id, draft) in reviewDrafts where sessions[id] != nil && sessions[id]?.reviewDraft != draft {
                sessions[id]?.reviewDraft = draft
                changed = true
            }
            if changed { save() }
        }
    }
    private(set) var states: [UUID: SessionState] = [:]
    /// A permission prompt's approval, sent but not yet confirmed: the
    /// tool's id just approved, so its card hides at once rather than
    /// waiting on the hook, and comes back if the state never leaves
    /// `needsYou` (`confirmApproval`).
    var optimisticApprovals: [UUID: String] = [:]
    /// claude's permission mode in each session, as its terminal's footer
    /// (else its transcript) last showed it (`SessionMode.swift`).
    var modes: [UUID: ClaudeMode] = [:]
    /// Why a session's last switch between Attended and Unattended didn't
    /// land, shown by its control until the next one does.
    var modeNotes: [UUID: String] = [:]
    /// Sessions being switched between modes now.
    var switchingMode: Set<UUID> = []
    /// Boxes (`modeBox`) whose claude had no auto mode in its cycle, until
    /// claude next starts there.
    var autoUnavailableBoxes: Set<String> = []
    /// Bumped each time a session's hooks say claude edited a file or ran
    /// a command, so its Changes pane reads them again.
    private(set) var changeCounts: [UUID: Int] = [:]
    /// Why a session's last commit to the harness failed, to show on it.
    private(set) var recordErrors: [UUID: String] = [:]
    @ObservationIgnored var terminals: [UUID: SessionTerminal] = [:]
    /// Each session's Changes pane: which file is open and what's been read,
    /// kept here so switching tabs away and back doesn't lose either.
    @ObservationIgnored var changesPanes: [UUID: SessionChanges] = [:]
    /// Each Ask session's Files pane, kept for the same reason.
    @ObservationIgnored var filesPanes: [UUID: SessionFiles] = [:]
    @ObservationIgnored private var polling: Task<Void, Never>?
    /// The last `changed` value each session's hook wrote.
    @ObservationIgnored private var lastChanged: [UUID: String] = [:]
    /// Each session's real context limit, from its statusLine: kept apart
    /// from `transcripts` so `store` can lay it back over `reader.summary`
    /// (whose own guess is a 200K default) whenever an async transcript
    /// read lands after the statusLine was read.
    @ObservationIgnored private var contextWindows: [UUID: Int] = [:]
    /// Server sessions whose hook files are being read over ssh now.
    @ObservationIgnored private var readingRemote: Set<UUID> = []
    @ObservationIgnored private var pollTick = 0
    /// A review being started for a PR, by its ID, so concurrent starts for
    /// the same PR (`startReview`) share one instead of making two.
    @ObservationIgnored var startingReviews: [String: Task<CodeSession, Never>] = [:]
    /// What each session's transcript says, read while its terminal runs.
    var transcripts: [UUID: SessionTranscript] = [:]
    @ObservationIgnored var readers: [UUID: TranscriptReader] = [:]
    @ObservationIgnored var transcriptFiles: [UUID: URL] = [:]
    @ObservationIgnored var readingTranscript: Set<UUID> = []
    /// Each session's PRs, watched in the background so failing checks and
    /// new reviews flag it like a question would.
    var pullRequestInfo: [UUID: [SessionPullRequest]] = [:]
    var pullRequestErrors: [UUID: String] = [:]
    /// The URLs of each session's PRs its branch search found last time,
    /// which needn't be looked up by URL as well.
    @ObservationIgnored var foundBySearch: [UUID: Set<URL>] = [:]
    @ObservationIgnored var watchingPullRequests: Task<Void, Never>?
    /// GitHub, once signed in; set by the app.
    @ObservationIgnored var api: () -> GitHubAPI? = { nil }
    /// The signed-in login, so a session's own feedback on a PR it isn't
    /// the author of (reviewing someone else's) doesn't notify; set by the app.
    @ObservationIgnored var viewerLogin: () -> String? = { nil }
    /// The budget is low or GitHub has refused: background PR checks wait.
    @ObservationIgnored var holdsOff: () -> Bool = { false }
    /// Gannin's view of an org as files (`OrgContext`), for an Ask session
    /// in a harness; set by the app, which has the stores.
    @ObservationIgnored var orgContext: (_ org: String, _ harness: String) -> [String: Data] = { _, _ in [:] }
    /// Reviews Gannin started or asked to look again by itself, until
    /// their result arrives (`AutoReview.swift`).
    @ObservationIgnored var automaticRuns: Set<UUID> = []
    /// What to tell claude once it has started (a review asked to look
    /// again while it wasn't running).
    @ObservationIgnored var pendingPrompts: [UUID: String] = [:]
    /// New PR feedback waiting for claude's turn to end, with the keys to
    /// mark sent once it's pasted. Dropped if claude exits first.
    @ObservationIgnored var pendingFeedback: [UUID: (prompt: String, keys: [String])] = [:]
    /// What happened on reviewed PRs, for the Inbox's catch-up.
    let activity = ReviewActivity()
    /// Every session at once instead of a tab.
    var showingOverview = false
    /// New plans being set up, by their tab's ID: a tab of their own until
    /// Start Planning makes the session in its place. Not kept across
    /// launches.
    var planningDrafts: [UUID: PlanningDraft] = [:]
    /// A second tab shown beside the selected one.
    var besideTab: UUID?
    /// The session whose tab is closing, asked first whether to wrap it up
    /// (`WrapUp.swift`).
    var wrappingUp: UUID?
    /// Each server's home folder, for paths an editor opens there.
    @ObservationIgnored var remoteHomes: [String: String] = [:]
    @ObservationIgnored var notificationCategories: [String: UNNotificationCategory] = [:]
    @ObservationIgnored private let harness: HarnessStore

    var harnessStore: HarnessStore { harness }

    init(harness: HarnessStore) {
        self.harness = harness
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([CodeSession].self, from: data) {
            sessions = Dictionary(uniqueKeysWithValues: saved.map { session in
                var session = session
                if !session.isRemote, !session.hasNoIssue, let worktree = Self.worktree(for: session), !FileManager.default.fileExists(atPath: worktree.path) {
                    session.branch = Self.branchName(session.issue)
                }
                return (session.id, session)
            })
        }
        for session in sessions.values { Self.noteFolder(of: session) }
        SandboxCredentials.removeStoredSubscriptionToken()
        noteSandboxedHarnesses()
        reviewDrafts = sessions.compactMapValues(\.reviewDraft)
        // A helper's tab, saved before helpers were shown in their
        // session's, is its session's.
        var saved: [UUID] = []
        for id in (UserDefaults.standard.stringArray(forKey: Self.tabsKey) ?? []).compactMap(UUID.init(uuidString:)) {
            guard sessions[id] != nil else { continue }
            let tab = tabOwner(id)
            if !saved.contains(tab) { saved.append(tab) }
        }
        tabs = saved
        selectedTab = tabs.first
    }

    // MARK: Tabs

    /// The tab a session shows in: a helper's is the session it helps, so
    /// the work and its review are one tab.
    func tabOwner(_ id: UUID) -> UUID {
        guard let parent = sessions[id]?.parentID, sessions[parent] != nil else { return id }
        return parent
    }

    /// Shows the session, adding its tab after the one showing if it isn't
    /// open. A helper shows in its session's tab.
    func reveal(_ id: UUID) {
        guard sessions[id] != nil else { return }
        let tab = tabOwner(id)
        if !tabs.contains(tab) {
            let index = selectedTab.flatMap { tabs.firstIndex(of: tabOwner($0)) }.map { $0 + 1 } ?? tabs.endIndex
            tabs.insert(tab, at: index)
            saveTabs()
        }
        selectedTab = id
    }

    /// Adds the session's tab after `neighbour`'s (else at the end) without
    /// showing it: a helper started in the background, whose tab is its
    /// session's.
    func addTab(_ id: UUID, after neighbour: UUID?) {
        guard sessions[id] != nil else { return }
        let tab = tabOwner(id)
        guard !tabs.contains(tab) else { return }
        let index = neighbour.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabs.endIndex
        tabs.insert(tab, at: index)
        saveTabs()
    }

    /// Closes the tab; claude keeps running, as when a window closed.
    /// A new plan's tab, after the one showing, selected.
    @discardableResult
    func openDraft(_ draft: PlanningDraft) -> UUID {
        let id = UUID()
        planningDrafts[id] = draft
        let index = selectedTab.flatMap { tabs.firstIndex(of: tabOwner($0)) }.map { $0 + 1 } ?? tabs.endIndex
        tabs.insert(id, at: index)
        showingOverview = false
        selectedTab = id
        return id
    }

    /// The session started from a draft, in the draft's tab.
    func replaceDraft(_ draftID: UUID, with id: UUID) {
        planningDrafts[draftID] = nil
        tabs.removeAll { $0 == id }
        if let index = tabs.firstIndex(of: draftID) {
            tabs[index] = id
        } else {
            tabs.append(id)
        }
        selectedTab = id
        saveTabs()
    }

    func closeTab(_ id: UUID) {
        planningDrafts[id] = nil
        guard let index = tabs.firstIndex(of: id) else {
            // A helper showing in its session's tab: back to the work.
            if selectedTab == id, let parent = sessions[id]?.parentID { selectedTab = parent }
            return
        }
        tabs.remove(at: index)
        if let selectedTab, tabOwner(selectedTab) == id {
            self.selectedTab = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
        }
        saveTabs()
    }

    /// Names a session's tab, as it's listed everywhere; empty goes back
    /// to its own title. An Ask's name is its title.
    func renameTab(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if sessions[id]?.isAsk == true {
            renameAsk(id, to: name)
        } else {
            update(id) { $0.name = name.isEmpty ? nil : name }
        }
    }

    func moveTab(_ id: UUID, to target: UUID) {
        guard id != target, let from = tabs.firstIndex(of: id), let to = tabs.firstIndex(of: target) else { return }
        tabs.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        saveTabs()
    }

    /// The tab `offset` along from the one showing, wrapping round.
    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let index = selectedTab.flatMap { tabs.firstIndex(of: tabOwner($0)) } ?? 0
        selectedTab = tabs[((index + offset) % tabs.count + tabs.count) % tabs.count]
    }

    private func saveTabs() {
        // Drafts aren't kept: they're gone at the next launch.
        UserDefaults.standard.set(tabs.filter { planningDrafts[$0] == nil }.map(\.uuidString), forKey: Self.tabsKey)
    }

    func sessions(for org: String) -> [CodeSession] {
        sessions.values.filter { $0.org == org }.sorted { $0.createdAt > $1.createdAt }
    }

    /// The issue's own session, not a helper's or a review's.
    func session(forIssue id: String) -> CodeSession? {
        sessions.values.first { $0.issue.id == id && !$0.isHelper && !$0.isPullRequestReview && $0.planning == nil }
    }

    /// The review of a PR, by its node ID.
    func review(of pullRequestID: String) -> CodeSession? {
        sessions.values.first { $0.reviewOf?.id == pullRequestID }
    }

    /// Changes a session as kept, and saves.
    func update(_ id: UUID, _ change: (inout CodeSession) -> Void) {
        guard var session = sessions[id] else { return }
        change(&session)
        sessions[id] = session
        save()
    }

    /// Adds a session made elsewhere (a helper), and saves.
    func add(_ session: CodeSession) {
        Self.noteFolder(of: session)
        sessions[session.id] = session
        noteSandboxedHarnesses()
        save()
    }

    func helpers(of id: UUID) -> [CodeSession] {
        sessions.values.filter { $0.parentID == id }.sorted { $0.createdAt < $1.createdAt }
    }

    func state(_ id: UUID) -> SessionState { states[id] ?? .stopped }

    /// The issue's session, made in the harness checkout at `harnessPath` if
    /// it has none, with its brief written afresh from what Gannin knows now.
    func start(_ issue: IssueReference, harness: HarnessConfig, harnessPath: String, instructions: String? = nil, placement: SandboxPlacement = .host(nil), brief: (CodeSession) -> String) -> CodeSession {
        let session = session(forIssue: issue.id) ?? {
            let id = UUID()
            return CodeSession(
                id: id, issue: issue, repo: harness.repo, branch: Self.branchName(issue), createdAt: .now,
                connect: Self.connectCommand, harnessRepo: harness.repo, harnessPath: harnessPath, instructions: instructions,
                sandbox: placement.isSandboxed ? SandboxPlacement.containerName(for: id) : nil, hostReason: placement.reason
            )
        }()
        sessions[session.id] = session
        noteSandboxedHarnesses()
        save()
        let directory = Self.directory(for: session.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(brief(session).utf8).write(to: directory.appending(path: "brief.md"))
        return session
    }

    // MARK: In the harness

    /// `sessions/<repo>-<number>`, by the issue's repo, whose number it is.
    static func harnessFolder(for issue: IssueReference) -> String {
        let name = issue.repo.split(separator: "/").last.map(String.init) ?? issue.repo
        return "sessions/\(name)-\(issue.number)"
    }

    /// The session's folder there: its issue's, or for a quick change with
    /// none, `sessions/quick-<slug>`.
    static func harnessFolder(for session: CodeSession) -> String {
        session.hasNoIssue ? "sessions/\(session.branch)" : harnessFolder(for: session.issue)
    }

    /// Commits the session's brief and `session.json` to the harness's
    /// default branch, so its checkout on any box has them. Confirmed by the
    /// caller. The session keeps where they went, so its PR is added later
    /// and a server session reads its brief from the harness.
    func record(_ id: UUID, startedBy: String?) async {
        guard let session = sessions[id], let repo = session.harnessRepo else { return }
        let folder = Self.harnessFolder(for: session)
        let brief = (try? String(contentsOf: Self.directory(for: id).appending(path: "brief.md"), encoding: .utf8)) ?? ""
        let record = SessionRecord(
            issue: session.hasNoIssue ? nil : session.issue.reference, title: session.issue.title, url: session.issue.url,
            repos: session.hasNoIssue ? [session.issue.repo] : session.isInHarness ? [] : [session.repo], branch: session.branch, startedBy: startedBy, startedAt: session.createdAt,
            box: session.connect ?? (Host.current().localizedName ?? "Mac"), pullRequests: session.pullRequests
        )
        do {
            try await harness.commit(org: session.org, setup: HarnessConfig(repo: repo), refreshing: false) { _ in
                HarnessChange(
                    message: session.hasNoIssue
                        ? "Gannin: quick change in \(session.issue.repo)\n\n\(session.issue.title), on \(session.branch)."
                        : "Gannin: session on \(session.issue.reference)\n\n\(session.issue.title), on \(session.branch).",
                    files: ["\(folder)/brief.md": brief, "\(folder)/session.json": record.json]
                )
            }
            sessions[id]?.harnessFolder = folder
            recordErrors[id] = nil
            save()
        } catch {
            recordErrors[id] = error.localizedDescription
        }
    }

    /// Adds the PR claude opened to the session's `session.json`, on top of
    /// whatever the harness has now.
    private func recordPullRequest(_ url: URL, for id: UUID) {
        guard let session = sessions[id], let repo = session.harnessRepo, let folder = session.harnessFolder else { return }
        let setup = HarnessConfig(repo: repo)
        let path = "\(folder)/session.json"
        Task {
            do {
                try await harness.commit(org: session.org, setup: setup, refreshing: false) { head in
                    let text = try await self.harness.files(setup: setup, at: head, paths: [path])[path] ?? nil
                    guard let text, var record = try? SessionRecord.decoder.decode(SessionRecord.self, from: Data(text.utf8)) else { return nil }
                    guard !record.pullRequests.contains(url) else { return nil }
                    record.pullRequests.append(url)
                    return HarnessChange(message: "Gannin: \(session.longReference) has a pull request\n\n\(url.absoluteString)", files: [path: record.json])
                }
                recordErrors[id] = nil
            } catch {
                recordErrors[id] = error.localizedDescription
            }
        }
    }

    // MARK: Terminals

    /// The view the session's terminal draws in, launching it if nothing is
    /// running. Call from an event or `onAppear`, not from a view's body.
    func open(_ session: CodeSession) -> NSView {
        let terminal = terminals[session.id] ?? SessionTerminal { [weak self] in
            self?.terminated(session.id)
        } onSignal: { [weak self] signal in
            self?.received(signal, for: session.id)
        }
        terminals[session.id] = terminal
        // Not while one is on its way (a sandbox's stop or secrets first).
        if !terminal.isRunning, !launching.contains(session.id) { launch(session, in: terminal) }
        return terminal.container
    }

    /// The session's terminal, if it has been opened since launch.
    func terminal(_ id: UUID) -> SessionTerminal? { terminals[id] }

    /// A font picked after some terminals were already running (Settings >
    /// General): pushed onto each so it takes hold without relaunching.
    func applyEditorFont(_ font: NSFont) {
        for terminal in terminals.values { terminal.applyFont(font) }
    }

    /// The session's Changes pane, created the first time it's shown. Call
    /// from an event or `onAppear`, not from a view's body.
    func changes(for session: CodeSession) -> SessionChanges {
        if let existing = changesPanes[session.id] { return existing }
        let changes = SessionChanges()
        changesPanes[session.id] = changes
        return changes
    }

    /// An Ask session's Files pane, created the first time it's shown.
    func files(for session: CodeSession) -> SessionFiles {
        if let existing = filesPanes[session.id] { return existing }
        let files = SessionFiles()
        filesPanes[session.id] = files
        return files
    }

    func isRunning(_ id: UUID) -> Bool { terminals[id]?.isRunning == true }

    /// Sessions with a terminal running, which quitting would end.
    var running: [CodeSession] {
        terminals.filter(\.value.isRunning).compactMap { sessions[$0.key] }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Ends claude and the shell it runs in. The worktree stays.
    func end(_ id: UUID) {
        terminals[id]?.terminate()
    }

    /// Ends the session and forgets it. The clone and worktree stay on disk.
    func remove(_ id: UUID) {
        // Helpers work in its folder, so they go with it.
        for helper in helpers(of: id) { remove(helper.id) }
        // A helper showing in its session's tab goes back to the work.
        if let parent = sessions[id]?.parentID {
            if selectedTab == id { selectedTab = parent }
            if besideTab == id { besideTab = parent }
        }
        if let session = sessions[id] { deleteSandbox(of: session) }
        terminals[id]?.terminate()
        terminals[id] = nil
        changesPanes[id] = nil
        filesPanes[id] = nil
        unflag(id)
        sessions[id] = nil
        noteSandboxedHarnesses()
        states[id] = nil
        drafts[id] = nil
        sandboxStatus[id] = nil
        transcripts[id] = nil
        readers[id] = nil
        contextWindows[id] = nil
        transcriptFiles[id] = nil
        pullRequestInfo[id] = nil
        if besideTab == id { besideTab = nil }
        closeTab(id)
        save()
        try? FileManager.default.removeItem(at: Self.directory(for: id))
    }

    func launch(_ session: CodeSession, in terminal: SessionTerminal) {
        let directory = Self.directory(for: session.id)
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(SessionState.starting.rawValue.utf8).write(to: directory.appending(path: "state"))
        setState(.starting, for: session.id)
        // An issue's session from before sandboxing was on says why it isn't in one.
        if SandboxCredentials.isEnabled, !session.isSandboxed, session.hostReason == nil, !session.isHelper,
           !session.isPullRequestReview, session.planning == nil, session.ask == nil, session.isInHarness {
            update(session.id) { $0.hostReason = SandboxPlacement.startedBefore }
        }
        // A new claude there may have auto mode after all.
        autoUnavailableBoxes.remove(modeBox(session.id))
        askToNotify()
        // Fresh org data on every start and resume, which the script copies
        // into its folder.
        if session.isAsk { writeAskContext(session) }

        // What the login shell runs: the script here, or the Connect with
        // command carrying it to the server.
        let command: String
        /// A sandbox on a server gets its credentials over ssh before the
        /// terminal starts: nil there removes any left from before.
        var remoteSecrets: (runner: Shell.Runner, directory: String, text: String?)?
        /// A quick change's screenshots, sent to a server the same way.
        var remoteAttachments: (runner: Shell.Runner, directory: String, files: [URL])?
        if let connect = session.connect {
            let remoteDirectory = Self.remoteDirectory(for: session)
            // A brief in the harness comes with its pull; only one that
            // isn't travels in the command.
            let brief = session.harnessFolder == nil ? (try? String(contentsOf: directory.appending(path: "brief.md"), encoding: .utf8)) ?? "" : nil
            let remote = SessionScript.remoteCommand(
                directory: remoteDirectory,
                script: SessionScript.start(session, root: SessionScript.shellPath(session.harnessPath ?? session.remoteWorkspace ?? Self.defaultWorkspace), directory: remoteDirectory),
                brief: brief,
                settings: SessionScript.settings(directory: remoteDirectory, isRemote: true, allowing: Self.allowedCommands(session)),
                files: session.isSandboxed ? ["inner.sh": SandboxLaunch.innerScript(session)] : [:]
            )
            command = SessionScript.connecting(connect, to: remote)
            if let names = session.quickChange?.attachments, !names.isEmpty, let arguments = Shell.sshArguments(connect) {
                let folder = directory.appending(path: Self.attachmentsFolder, directoryHint: .isDirectory)
                remoteAttachments = (.ssh(arguments), remoteDirectory, names.map { folder.appending(path: $0) })
            }
            if session.isSandboxed, let arguments = Shell.sshArguments(connect) {
                let text = try? SandboxLaunch.credentials(org: session.org).get()
                remoteSecrets = (.ssh(arguments), remoteDirectory, text.map(SandboxLaunch.secretsFile))
            }
        } else {
            let root = session.harnessPath.map(Self.expanded) ?? Self.workspaceRoot
            // The harness is cloned into it, when it isn't there yet.
            try? fm.createDirectory(at: session.harnessPath == nil ? root : root.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A sandbox mounts the folder at its real path, which the hooks
            // write to from inside.
            let real = session.isSandboxed ? URL(filePath: SandboxGitGuard.realPath(directory.path), directoryHint: .isDirectory) : directory
            let local = SessionScript.quoted(real.path)
            if session.isSandboxed { prepareSandbox(session, directory: real) }
            // A sandbox's statusLine can't run the user's own command, which is on the Mac.
            try? Data(SessionScript.settings(directory: local, isRemote: session.isSandboxed, allowing: Self.allowedCommands(session)).utf8).write(to: directory.appending(path: "settings.json"))
            let script = directory.appending(path: "start.sh")
            try? Data(SessionScript.start(session, root: SessionScript.quoted(root.path), directory: local).utf8).write(to: script)
            command = "bash \(SessionScript.quoted(script.path))"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        // Gannin started from inside a Claude Code session (a build and run,
        // say) inherits its markers, and claude then won't save transcripts,
        // so there'd be nothing to resume.
        for key in environment.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") {
            environment[key] = nil
        }
        // Your login, interactive shell, so the PATH, ssh config and tools
        // are yours.
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let id = session.id
        let start = { [weak self] in
            self?.launching.remove(id)
            terminal.launch(
                executable: shell,
                args: ["-l", "-i", "-c", command],
                environment: environment.map { "\($0.key)=\($0.value)" },
                directory: session.isRemote || session.harnessPath != nil ? FileManager.default.homeDirectoryForCurrentUser.path : Self.workspaceRoot.path
            )
            self?.startPolling()
        }
        // A stop of its sandbox still on its way would land after the start
        // script found it running: wait for it, so the script starts afresh.
        let stopping = session.sandbox.flatMap { stoppingSandboxes[$0] }
        guard remoteSecrets != nil || remoteAttachments != nil || stopping != nil else { return start() }
        launching.insert(id)
        Task {
            await stopping?.value
            if let remoteSecrets {
                // Over the shared connection, on standard input, so no secret
                // is on a command line on either box. The start script says
                // if they didn't arrive.
                let script = SandboxLaunch.remoteSecretsScript(directory: remoteSecrets.directory, writing: remoteSecrets.text != nil)
                let input = remoteSecrets.text.map { Data($0.utf8) }
                _ = await Task.detached { Shell.run(script, remoteSecrets.runner, input: input) }.value
            }
            if let remoteAttachments {
                // Those not there yet, one file a call, on standard input.
                // The start script warns about any that didn't arrive.
                let listing = Self.remoteAttachmentListScript(directory: remoteAttachments.directory)
                let present = await Task.detached { Shell.run(listing, remoteAttachments.runner) }.value
                let there = Set(present.output.split(separator: "\n").map(String.init))
                for file in remoteAttachments.files where !there.contains(file.lastPathComponent) {
                    guard let data = try? Data(contentsOf: file) else { continue }
                    let script = Self.remoteAttachmentScript(directory: remoteAttachments.directory, name: file.lastPathComponent)
                    _ = await Task.detached { Shell.run(script, remoteAttachments.runner, input: data) }.value
                }
            }
            start()
        }
    }

    /// Lists a quick change's screenshots already in its session's folder on
    /// a server, one name a line.
    static func remoteAttachmentListScript(directory: String) -> String {
        "d=\(directory)\nls -1 \"$d/\(attachmentsFolder)\" 2>/dev/null || true"
    }

    /// Writes one of a quick change's screenshots, from standard input, into
    /// its session's folder on a server: to a part file first, so one cut
    /// short isn't taken as there next time.
    static func remoteAttachmentScript(directory: String, name: String) -> String {
        let file = "\"$d/\(attachmentsFolder)\"/" + SessionScript.quoted(name)
        let part = "\"$d/\(attachmentsFolder)\"/" + SessionScript.quoted(".\(name).part")
        return "d=\(directory)\nmkdir -p \"$d/\(attachmentsFolder)\" && cat > \(part) && mv \(part) \(file)"
    }

    /// Sessions whose terminal is about to start, once a stop or their
    /// secrets are done: not launched again meanwhile.
    private var launching: Set<UUID> = []

    /// Sandboxes being stopped, by name, for a start to wait on.
    private var stoppingSandboxes: [String: Task<Void, Never>] = [:]

    /// What a sandboxed session on this Mac needs beside its start script:
    /// the script run inside, and its credentials for that start (removed
    /// inside once read; without them the start script says what's
    /// missing).
    private func prepareSandbox(_ session: CodeSession, directory: URL) {
        try? Data(SandboxLaunch.innerScript(session).utf8).write(to: directory.appending(path: "inner.sh"))
        let secrets = directory.appending(path: "secrets.env")
        if let credentials = try? SandboxLaunch.credentials(org: session.org).get() {
            try? SandboxLaunch.writeSecrets(SandboxLaunch.secretsFile(credentials), to: secrets)
        } else {
            try? FileManager.default.removeItem(at: secrets)
        }
    }

    /// What a session's claude runs without asking: the pair review's script.
    private static func allowedCommands(_ session: CodeSession) -> [String] {
        session.canPairReview ? [session.readyForReviewScript, "./" + session.readyForReviewScript] : []
    }

    func changeCount(_ id: UUID) -> Int { changeCounts[id] ?? 0 }

    // MARK: Attention

    /// Notify when a session needs you or has finished its turn.
    static let notifiesKey = "sessionsNotify"

    /// The session waiting on you longest.
    var nextWaiting: UUID? {
        attention.filter { sessions[$0.key] != nil }.min { $0.value < $1.value }?.key
    }

    private func setState(_ state: SessionState, for id: UUID) {
        let old = states[id]
        guard old != state else { return }
        states[id] = state
        // Feedback queued for a claude that's gone may be dealt with by the
        // time it's back; the PRs pane still offers it.
        if state == .exited || state == .stopped { pendingFeedback[id] = nil }
        if [.needsYou, .idle, .exited].contains(state), sessions[id] != nil {
            sessions[id]?.lastActiveAt = .now
            save()
        }
        switch state {
        case .needsYou:
            let asking = transcripts[id]?.question != nil
            flag(id, title: "Claude needs you", body: asking ? (transcripts[id]?.question?.items.first?.question ?? "") : "It's asking for permission to go on.", replies: true)
        case .idle where pendingPrompts[id] != nil || pendingFeedback[id] != nil:
            sendPendingPrompt(id)
            sendPendingFeedback(id)
        case .idle where old == .working:
            if let pr = sessions[id]?.reviewOf, readyForApproval(pr.id, whileBusy: true) != nil {
                noticeApproval(id)
            } else if !isQuietForPairReview(id) {
                flag(id, title: "Your turn", body: transcripts[id]?.lastReply.map { String($0.prefix(180)) } ?? "Claude has finished what it was doing.", replies: false)
            }
        case .working, .starting, .stopped:
            unflag(id)
        default:
            break
        }
    }

    /// Marks the session as waiting on you and, unless you're looking at
    /// it, notifies: with quick replies when claude is asking something.
    func flag(_ id: UUID, title: String, body: String, replies: Bool) {
        // Already in front of you.
        if windowIsKey, selectedTab == id, NSApp.isActive { return }
        attention[id] = attention[id] ?? .now
        updateBadge()
        guard UserDefaults.standard.object(forKey: Self.notifiesKey) as? Bool ?? true, let session = sessions[id] else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = "\(session.shortReference) \(session.title)"
        content.body = body
        content.sound = .default
        content.threadIdentifier = id.uuidString
        content.userInfo = ["session": id.uuidString]
        if replies {
            content.categoryIdentifier = registerReplies(for: id)
        }
        // One per session: a newer one replaces it.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
    }

    /// The quick replies a notification offers, as keys to send: the
    /// options of the question claude is asking, else a permission
    /// prompt's own choices and Deny. Categories are app-wide, so one per
    /// session; registered once the prompt's choices are there to read
    /// off the terminal (up to a second, as the card itself waits), so
    /// the notification doesn't offer a plain Allow when the real prompt
    /// has more useful choices.
    private func registerReplies(for id: UUID) -> String {
        let identifier = "session.\(id.uuidString)"
        Task {
            var tries = 0
            while transcripts[id]?.question == nil, permissionChoices(for: id).isEmpty, state(id) == .needsYou, tries < 6 {
                tries += 1
                try? await Task.sleep(for: .milliseconds(150))
            }
            let actions: [UNNotificationAction] = quickReplies(for: id).prefix(Self.maxQuickReplies).map { reply in
                UNNotificationAction(identifier: "keys:" + reply.keys, title: reply.title, options: reply.isDestructive ? [.destructive] : [])
            }
            notificationCategories[identifier] = UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [])
            // Categories are app-wide: keep the review watch's.
            let ours = Set(notificationCategories.values)
            let center = UNUserNotificationCenter.current()
            let others = await center.notificationCategories().filter { !$0.identifier.hasPrefix("session.") }
            center.setNotificationCategories(others.union(ours))
        }
        return identifier
    }

    private func unflag(_ id: UUID) {
        guard attention[id] != nil else { return }
        attention[id] = nil
        updateBadge()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    /// The tab showing in the key window has been seen.
    private func looked() {
        if windowIsKey, let selectedTab {
            unflag(selectedTab)
            activity.markSeen(session: selectedTab)
        }
    }

    private func updateBadge() {
        let count = attention.keys.filter { sessions[$0] != nil }.count
        NSApp.dockTile.badgeLabel = count == 0 ? nil : "\(count)"
    }

    private static var askedToNotify = false

    private func askToNotify() {
        guard !Self.askedToNotify else { return }
        Self.askedToNotify = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    // MARK: Talking to claude

    /// Types the text into claude's prompt as a paste and submits it. Claude
    /// queues it if it's in the middle of something. False when the
    /// terminal isn't running.
    @discardableResult
    func submit(_ text: String, to id: UUID) -> Bool {
        guard let terminal = terminals[id], terminal.isRunning else { return false }
        terminal.submit(text)
        return true
    }

    func addDraft(_ comment: DiffComment, to id: UUID) {
        drafts[id, default: []].append(comment)
    }

    func removeDraft(_ comment: DiffComment.ID, from id: UUID) {
        drafts[id]?.removeAll { $0.id == comment }
    }

    func clearDrafts(_ id: UUID) {
        drafts[id] = nil
    }

    func markSent(_ keys: some Sequence<String>, for id: UUID) {
        sent[id, default: []].formUnion(keys)
    }

    /// What a hook sent through the terminal: `state:working`, `pr:<url>`,
    /// `changed`.
    private func received(_ signal: String, for id: UUID) {
        if signal == "changed" {
            changeCounts[id, default: 0] += 1
        } else if signal.hasPrefix("state:"), let state = SessionState(rawValue: String(signal.dropFirst(6))) {
            setState(state, for: id)
        } else if signal.hasPrefix("pr:"),
                  let url = URL(string: String(signal.dropFirst(3))), url.scheme == "https" {
            opened(url, for: id)
        }
    }

    /// Claude's `gh pr create`, spotted by a hook.
    private func opened(_ url: URL, for id: UUID) {
        guard sessions[id]?.pullRequests.contains(url) == false else { return }
        sessions[id]?.pullRequests.append(url)
        save()
        recordPullRequest(url, for: id)
    }

    private func terminated(_ id: UUID) {
        setState(.stopped, for: id)
        stopSandboxIfIdle(id)
    }

    // MARK: Sandboxes

    /// What each sandboxed session's start script last said of its sandbox
    /// (`starting`, `running`, `failed: <why>`), or `stopped` once Gannin
    /// stopped it (R14).
    private(set) var sandboxStatus: [UUID: String] = [:]

    /// Stops the session's sandbox once no session using it is running: the
    /// issue's own and its helpers share one (R12). Its folders stay, and
    /// opening the session again starts it afresh.
    private func stopSandboxIfIdle(_ id: UUID) {
        guard let session = sessions[id], let name = session.sandbox, let runner = Self.sandboxRunner(session) else { return }
        let sharing = sessions.values.filter { $0.sandbox == name }
        guard !sharing.contains(where: { isRunning($0.id) }) else { return }
        for other in sharing { sandboxStatus[other.id] = "stopped" }
        let script = SandboxLaunch.stopScript([name])
        stoppingSandboxes[name] = Task { [weak self] in
            _ = await Task.detached { Shell.run(script, runner) }.value
            self?.stoppingSandboxes[name] = nil
        }
    }

    /// Where a session's sandbox is: this Mac, or its server over ssh.
    private static func sandboxRunner(_ session: CodeSession) -> Shell.Runner? {
        guard let connect = session.connect else { return .local }
        return Shell.sshArguments(connect).map(Shell.Runner.ssh)
    }

    /// Every sandbox on this Mac with a session's terminal running, stopped
    /// as Gannin quits (R12). Waits, so they're down before it goes.
    func stopSandboxesForQuit() {
        // By box: this Mac, and each server over its shared connection.
        let running = sessions.values.filter { $0.isSandboxed && isRunning($0.id) }
        for group in Dictionary(grouping: running, by: { $0.connect ?? "" }).values {
            guard let first = group.first, let runner = Self.sandboxRunner(first) else { continue }
            _ = Shell.run(SandboxLaunch.stopScript(Set(group.compactMap(\.sandbox)).sorted()), runner)
        }
    }

    /// Deletes the issue's sandbox once the issue's session is forgotten
    /// (finished or removed); its folders are the Mac's and stay or go
    /// with the session.
    private func deleteSandbox(of session: CodeSession) {
        guard let name = session.sandbox, !session.isHelper, let runner = Self.sandboxRunner(session) else { return }
        let script = SandboxLaunch.deleteScript(name)
        Task.detached { _ = Shell.run(script, runner) }
    }

    // MARK: Hook state

    /// What a session's hooks last wrote, as read from its folder.
    private func apply(state: String?, pullRequest: String?, changed: String?, contextWindow: String?, reviewRequest: String? = nil, for id: UUID) {
        if let state = state.flatMap(SessionState.init(rawValue:)) {
            setState(state, for: id)
        }
        for token in (pullRequest ?? "").split(whereSeparator: \.isWhitespace) {
            if let url = URL(string: String(token)), url.scheme == "https" {
                opened(url, for: id)
            }
        }
        if let changed, !changed.isEmpty, lastChanged[id] != changed {
            // The first read only learns where it was.
            if lastChanged[id] != nil { changeCounts[id, default: 0] += 1 }
            lastChanged[id] = changed
        }
        if let reviewRequest, !reviewRequest.isEmpty {
            reviewRequestRead(reviewRequest, for: id)
        }
        if let contextWindow, let limit = SessionTranscript.contextLimit(from: contextWindow) {
            contextWindows[id] = limit
            if var summary = transcripts[id], summary.contextLimit != limit {
                summary.contextLimit = limit
                transcripts[id] = summary
            }
        }
    }

    /// The server session's state, PR, last change, statusline and review
    /// request, one line each, then
    /// its transcript's size and whatever's been added to it since the last
    /// read: one call over the shared connection.
    private func readRemote(_ session: CodeSession) {
        guard !readingRemote.contains(session.id), let connect = session.connect,
              let arguments = Shell.sshArguments(connect) else { return }
        readingRemote.insert(session.id)
        let reader = readers[session.id] ?? TranscriptReader()
        // A sandbox's claude keeps its transcripts in its issue's claude-home there.
        let homes = (session.isSandboxed ? Self.remoteIssueDirectory(for: session) + "/claude-home/projects/*/" + session.claudeID + ".jsonl " : "")
            + #""$HOME"/.claude/projects/*/"# + session.claudeID + ".jsonl"
        let script = "d=" + Self.remoteDirectory(for: session) + "\n"
            + #"printf '%s\n' "$(cat "$d/state" 2>/dev/null)" "$(tr '\n' ' ' < "$d/pr" 2>/dev/null)" "$(cat "$d/changed" 2>/dev/null)" "$(cat "$d/statusline" 2>/dev/null)" "$(head -n 1 "$d/review-request" 2>/dev/null)" "$(cat "$d/sandbox" 2>/dev/null)""# + "\n"
            + "f=$(ls " + homes + #" 2>/dev/null | head -n 1)"# + "\n"
            + #"if [ -n "$f" ]; then s=$(wc -c < "$f" | tr -d ' '); echo "$s"; [ "$s" -gt "# + "\(reader.offset)"
            + #" ] && tail -c +"# + "\(reader.offset + 1)" + #" "$f" | head -c 4000000; else echo -1; fi; exit 0"#
        let id = session.id
        Task {
            let result = await Task.detached { () -> (Shell.Result, TranscriptReader?) in
                let result = Shell.run(script, .ssh(arguments))
                // After seven lines (state, PR, change, statusline, review
                // request, sandbox, size), the new bytes.
                var newlines = 0
                var index = result.data.startIndex
                while newlines < 7, let next = result.data[index...].firstIndex(of: 10) {
                    newlines += 1
                    index = result.data.index(after: next)
                }
                guard newlines == 7, result.data.count > index else { return (result, nil) }
                var reader = reader
                reader.consume(result.data[index...])
                return (result, reader)
            }.value
            readingRemote.remove(id)
            // Ended while it was read: the terminal's end is the truth.
            guard result.0.ok, terminals[id]?.isRunning == true, sessions[id] != nil else { return }
            if let reader = result.1 { store(reader, for: id) }
            let lines = result.0.data.prefix(8192).split(separator: 10, maxSplits: 7, omittingEmptySubsequences: false)
                .prefix(6).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespaces) }
            func line(_ index: Int) -> String? { index < lines.count && !lines[index].isEmpty ? lines[index] : nil }
            if let sandbox = line(5), sessions[id]?.isSandboxed == true, sandboxStatus[id] != sandbox { sandboxStatus[id] = sandbox }
            apply(state: line(0), pullRequest: line(1), changed: line(2), contextWindow: line(3), reviewRequest: line(4), for: id)
        }
    }

    /// Reads what's been added to a local session's transcript, off the
    /// main thread.
    private func readLocalTranscript(_ id: UUID, then done: (() -> Void)? = nil) {
        guard !readingTranscript.contains(id), let session = sessions[id] else { return }
        if transcriptFiles[id] == nil {
            // A sandbox's claude keeps its transcripts in the session's claude-home.
            // Helpers share their issue's.
            let home = session.isSandboxed ? Self.directory(for: session.parentID ?? id).appending(path: "claude-home/projects", directoryHint: .isDirectory) : nil
            transcriptFiles[id] = Self.findTranscript(session.claudeID, in: home)
        }
        guard let file = transcriptFiles[id] else {
            done?()
            return
        }
        readingTranscript.insert(id)
        let reader = readers[id] ?? TranscriptReader()
        Task {
            let updated = await Task.detached { () -> TranscriptReader? in
                guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
                defer { try? handle.close() }
                try? handle.seek(toOffset: UInt64(reader.offset))
                guard let data = try? handle.read(upToCount: 4_000_000), !data.isEmpty else { return nil }
                var reader = reader
                reader.consume(data)
                return reader
            }.value
            readingTranscript.remove(id)
            if let updated, sessions[id] != nil { store(updated, for: id) }
            done?()
        }
    }

    private func store(_ reader: TranscriptReader, for id: UUID) {
        readers[id] = reader
        var summary = reader.summary
        if let limit = contextWindows[id] { summary.contextLimit = limit }
        if transcripts[id] != summary { transcripts[id] = summary }
        // A review's result is kept with it, for the history.
        if sessions[id]?.isPullRequestReview == true, let review = reader.summary.review, sessions[id]?.reviewResult != review {
            sessions[id]?.reviewResult = review
            save()
            reviewFinished(id)
        }
        pairRoundRead(id)
    }

    /// `~/.claude/projects/<folder>/<id>.jsonl`, whichever folder claude
    /// filed it under.
    private static func findTranscript(_ claudeID: String, in home: URL? = nil) -> URL? {
        let projects = home ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appending(path: "\(claudeID).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.poll() else { break }
                try? await Task.sleep(for: .seconds(1))
            }
            self?.polling = nil
        }
    }

    /// Reads what the running sessions' hooks wrote: here every second, on
    /// a server every two over the shared ssh connection. False once
    /// nothing runs.
    private func poll() -> Bool {
        var anyRunning = false
        pollTick += 1
        for (id, terminal) in terminals where terminal.isRunning {
            anyRunning = true
            guard let session = sessions[id] else { continue }
            refreshMode(id)
            if session.isRemote {
                if pollTick % 2 == 0 { readRemote(session) }
                continue
            }
            let directory = Self.directory(for: id)
            func read(_ name: String) -> String? {
                (try? String(contentsOf: directory.appending(path: name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let state = read("state"), pullRequest = read("pr"), changed = read("changed"), statusLine = read("statusline")
            if session.isSandboxed, let sandbox = read("sandbox"), sandboxStatus[id] != sandbox { sandboxStatus[id] = sandbox }
            let reviewRequest = read("review-request")
            if state == SessionState.needsYou.rawValue, states[id] != .needsYou {
                // What it's asking is in the transcript: read it first, so
                // the notification can offer the answers.
                readLocalTranscript(id) { [weak self] in
                    self?.apply(state: state, pullRequest: pullRequest, changed: changed, contextWindow: statusLine, reviewRequest: reviewRequest, for: id)
                }
                continue
            }
            if pollTick % 2 == 0 { readLocalTranscript(id) }
            apply(state: state, pullRequest: pullRequest, changed: changed, contextWindow: statusLine, reviewRequest: reviewRequest, for: id)
        }
        return anyRunning
    }

    // MARK: Places

    static var workspaceRoot: URL {
        expanded(UserDefaults.standard.string(forKey: workspaceKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultWorkspace)
    }

    /// A folder as a path to keep: under your home as `~/Code/x`.
    static func tildePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    static func expanded(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    /// Where the session's work is on its box, as a path there: in the
    /// harness, the issue's folder `<harness>/.worktrees/<branch>`, holding a
    /// worktree per repo; before that, one repo's worktree beside its clone,
    /// `<workspace>/<owner>/<name>.worktrees/<branch>`.
    static func worktreePath(for session: CodeSession) -> String {
        if let harness = session.harnessPath {
            return "\(harness)/.worktrees/\(session.branch)"
        }
        let workspace = session.remoteWorkspace ?? (UserDefaults.standard.string(forKey: workspaceKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultWorkspace)
        return "\(workspace)/\(session.repo).worktrees/\(session.branch)"
    }

    /// The worktree on this Mac; nil for a session on a server.
    static func worktree(for session: CodeSession) -> URL? {
        session.isRemote ? nil : expanded(worktreePath(for: session))
    }

    /// `123-short-title`, from the issue's number and title.
    static func branchName(_ issue: IssueReference) -> String {
        let words = String(issue.title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " })
            .split(separator: " ")
        var slug = ""
        for word in words {
            let next = slug.isEmpty ? String(word) : "\(slug)-\(word)"
            if next.count > 40 { break }
            slug = next
        }
        return slug.isEmpty ? "issue-\(issue.number)" : "\(issue.number)-\(slug)"
    }

    /// Gannin's own folder, so the unsandboxed app doesn't write loose into
    /// the shared Application Support.
    private static var baseDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "dev.andon.gannin", directoryHint: .isDirectory)
            .appending(path: "Sessions", directoryHint: .isDirectory)
    }

    static func directory(for id: UUID) -> URL {
        if let parent = sandboxHelperParents[id] {
            return directory(for: parent).appending(path: "helpers/\(id.uuidString)", directoryHint: .isDirectory)
        }
        return baseDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// Helpers sharing an issue's sandbox, by their issue's session: their
    /// folders are inside its folder, which the sandbox mounts.
    private(set) static var sandboxHelperParents: [UUID: UUID] = [:]

    /// The session's folder on its server, as a shell expression: a
    /// sandboxed helper's inside its issue's, as on this Mac.
    static func remoteDirectory(for session: CodeSession) -> String {
        let base = #""$HOME"/.gannin/sessions/"#
        if session.isSandboxed, let parent = session.parentID { return base + parent.uuidString + "/helpers/" + session.id.uuidString }
        return base + session.id.uuidString
    }

    /// The issue's own session folder on its server, which its sandbox mounts.
    static func remoteIssueDirectory(for session: CodeSession) -> String {
        #""$HOME"/.gannin/sessions/"# + (session.parentID ?? session.id).uuidString
    }

    /// Notes where a sandboxed helper's folder is, before it's first used.
    static func noteFolder(of session: CodeSession) {
        if session.isSandboxed, let parent = session.parentID { sandboxHelperParents[session.id] = parent }
    }

    /// Tells the git guard which harnesses here have sandboxed sessions.
    private func noteSandboxedHarnesses() {
        SandboxGitGuard.setRoots(sessions.values.filter { $0.isSandboxed && !$0.isRemote }.compactMap(\.harnessPath))
    }

    private static var fileURL: URL { baseDirectory.appending(path: "Sessions.json") }

    func save() {
        try? FileManager.default.createDirectory(at: Self.baseDirectory, withIntermediateDirectories: true)
        let ordered = sessions.values.sorted { $0.createdAt < $1.createdAt }
        if let data = try? JSONEncoder().encode(ordered) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

/// One session's terminal: a container that stays put while the terminal
/// view inside it is replaced on each launch.
final class SessionTerminal: NSObject, LocalProcessTerminalViewDelegate {
    let container = NSView()
    private(set) var view: LocalProcessTerminalView?
    private(set) var isRunning = false
    private let onTerminate: () -> Void
    private let onSignal: (String) -> Void

    init(onTerminate: @escaping () -> Void, onSignal: @escaping (String) -> Void) {
        self.onTerminate = onTerminate
        self.onSignal = onSignal
    }

    func launch(executable: String, args: [String], environment: [String], directory: String) {
        view?.removeFromSuperview()
        // Launched with no tab showing it (an automatic review): a usual
        // size, so claude doesn't lay out for a terminal of no columns.
        if container.bounds.isEmpty { container.frame = NSRect(x: 0, y: 0, width: 960, height: 640) }
        let view = LocalProcessTerminalView(frame: container.bounds)
        view.autoresizingMask = [.width, .height]
        view.font = EditorFontStore.shared.font
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        view.processDelegate = self
        // The hooks' state, sent as an escape code so it reaches here from
        // a server too. SwiftTerm parses on the main queue.
        let onSignal = onSignal
        view.terminal.registerOscHandler(code: SessionScript.signalCode) { data in
            let text = String(decoding: data, as: UTF8.self)
            MainActor.assumeIsolated { onSignal(text) }
        }
        container.addSubview(view)
        self.view = view
        isRunning = true
        view.startProcess(executable: executable, args: args, environment: environment, execName: "zsh", currentDirectory: directory)
        focus()
    }

    func terminate() {
        guard isRunning else { return }
        view?.terminate()
    }

    /// A font picked after this terminal was launched (Settings > General).
    func applyFont(_ font: NSFont) {
        view?.font = font
    }

    /// The screen's own last rows as plain text, bottom row last: for
    /// reading claude's own rendered permission or plan prompt, which
    /// hooks can't see since they run with no terminal attached.
    func screenLines(last count: Int) -> [String] {
        guard let view, let terminal = view.terminal else { return [] }
        return (max(0, terminal.rows - count)..<terminal.rows).map {
            terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? ""
        }
    }

    /// Pastes the text at claude's prompt and presses Return: bracketed, so
    /// its lines stay one prompt, then Return a moment later, once the
    /// paste has landed.
    func submit(_ text: String) {
        guard let view else { return }
        let clean = text.replacingOccurrences(of: "\u{1B}", with: "")
        if view.terminal.bracketedPasteMode {
            view.send(txt: "\u{1B}[200~" + clean + "\u{1B}[201~")
        } else {
            view.send(txt: clean.replacingOccurrences(of: "\n", with: " "))
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.press("\r")
        }
        focus()
    }

    /// Keys as a key press would send them, encoded for the kitty keyboard
    /// protocol when Claude Code has turned it on (`TerminalKeys.encode`).
    func press(_ keys: String) {
        guard let view else { return }
        let flags = view.terminal.keyboardEnhancementFlags
        view.send(txt: TerminalKeys.encode(keys, kitty: !flags.isEmpty, reportAllKeys: flags.contains(.reportAllKeys)))
    }

    /// Puts the keyboard in the terminal.
    func focus() {
        guard let view else { return }
        Task { @MainActor in view.window?.makeFirstResponder(view) }
    }

    // SwiftTerm calls these on the main queue.

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let ended = ObjectIdentifier(source)
        MainActor.assumeIsolated {
            // Only the current launch's end counts.
            guard view.map(ObjectIdentifier.init) == ended else { return }
            isRunning = false
            onTerminate()
        }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
