import AppKit
import SwiftUI

extension SessionState {
    var color: Color {
        switch self {
        case .starting, .working: ChartPalette.blue
        case .needsYou: .orange
        case .idle: .green
        case .exited, .stopped: .secondary.opacity(0.5)
        }
    }
}

extension SessionStore {
    /// Shows the session as a tab in the sessions window, opening the window
    /// if it isn't.
    func show(_ id: UUID, with openWindow: OpenWindowAction) {
        reveal(id)
        openWindow(id: Self.windowID)
    }
}

/// The sessions window: a tab per issue's session, each its terminal beside
/// the issue or the changes in its worktrees. Closing a tab or the window
/// leaves claude running, though closing a running session's tab asks first
/// whether to wrap it up (`WrapUpSessionSheet`).
struct SessionsWindow: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.controlActiveState) private var activeState
    /// ⌘W asked to wrap up the last tab: the window goes once it has.
    @State private var closesWindow = false

    var body: some View {
        let selected = sessions.selectedTab.flatMap { sessions.sessions[$0] }
        VStack(spacing: 0) {
            Divider()
            SessionTabBar()
            Divider()
            if sessions.showingOverview {
                SessionOverview()
            } else if let draftID = sessions.selectedTab, let draft = sessions.planningDrafts[draftID] {
                if draft.isAsk {
                    NewAskView(draftID: draftID, draft: draft)
                        .id(draftID)
                } else if draft.isQuickChange {
                    NewQuickChangeView(draftID: draftID, draft: draft)
                        .id(draftID)
                } else {
                    NewPlanningView(draftID: draftID, draft: draft)
                        .id(draftID)
                }
            } else if let selected {
                if let beside = sessions.besideTab.flatMap({ sessions.sessions[$0] }), sessions.tabOwner(beside.id) != sessions.tabOwner(selected.id) {
                    HSplitView {
                        withAgents(selected, compact: true)
                        withAgents(beside, compact: true, isBeside: true)
                    }
                } else {
                    withAgents(selected, compact: false)
                }
            } else {
                ContentUnavailableView("No sessions open", systemImage: "terminal", description: Text("Work on This on an issue opens its session here, or + opens one already started."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 480)
        .navigationTitle(sessions.showingOverview ? "Claude Code" : selected.map { $0.isAsk ? "Ask" : $0.hasNoIssue ? "Quick Change" : $0.issue.reference } ?? "Claude Code")
        .windowSubtitle(sessions.showingOverview ? "Every session" : selected?.title ?? sessions.selectedTab.flatMap { sessions.planningDrafts[$0] }.map { $0.isAsk ? "New ask" : $0.isQuickChange ? "New quick change" : "New plan" } ?? "")
        .background { shortcuts }
        .sheet(item: Binding(
            get: { sessions.wrappingUp.map(WrapUpRequest.init) },
            set: { if $0 == nil { sessions.wrappingUp = nil } }
        ), onDismiss: {
            if closesWindow, sessions.tabs.isEmpty { dismissWindow(id: SessionStore.windowID) }
            closesWindow = false
        }) { request in
            WrapUpSessionSheet(id: request.id)
        }
        .onChange(of: activeState, initial: true) { sessions.windowIsKey = activeState == .key }
        .onDisappear { sessions.windowIsKey = false }
    }

    /// The session, under a switcher between it and its helpers when it has
    /// any: an issue's work and its review are one tab. The one beside
    /// switches on its own, so it never takes the selected tab's place.
    @ViewBuilder
    private func withAgents(_ session: CodeSession, compact: Bool, isBeside: Bool = false) -> some View {
        let owner = sessions.sessions[sessions.tabOwner(session.id)] ?? session
        let helpers = sessions.helpers(of: owner.id)
        if helpers.isEmpty {
            content(session, compact: compact)
        } else {
            VStack(spacing: 0) {
                SessionAgentSwitcher(owner: owner, helpers: helpers, shown: session.id) { id in
                    if isBeside { sessions.besideTab = id } else { sessions.selectedTab = id }
                }
                Divider()
                content(session, compact: compact)
            }
        }
    }

    /// A review's or a planning session's own layout, else the session's
    /// terminal and panel.
    @ViewBuilder
    private func content(_ session: CodeSession, compact: Bool) -> some View {
        if session.isPullRequestReview {
            PullRequestReviewView(session: session)
                .id(session.id)
        } else if session.isPlanning {
            PlanningWorkspaceView(session: session)
                .id(session.id)
        } else {
            SessionTab(session: session, compact: compact)
                .id(session.id)
        }
    }

    /// ⌘W closes the tab rather than the window, until it's the last.
    private var shortcuts: some View {
        Group {
            Button("Close Tab") {
                if let id = sessions.selectedTab, !sessions.requestClose(sessions.tabOwner(id)) {
                    closesWindow = true
                    return
                }
                if sessions.tabs.isEmpty { dismissWindow(id: SessionStore.windowID) }
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("Next Tab") { sessions.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { sessions.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// The tab bar's colours: the bar a shade lighter than the window's own
/// bar, and the selected tab the page's colour, darker, so it reads as part
/// of what's beneath it.
enum SessionTabColors {
    static let bar = AnyShapeStyle(Color.primary.opacity(0.09))
    static let selected = Color(nsColor: .textBackgroundColor)
}

private struct SessionTabBar: View {
    @Environment(SessionStore.self) private var sessions

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(sessions.tabs, id: \.self) { id in
                        if let session = sessions.sessions[id] {
                            SessionTabItem(session: session, isSelected: sessions.selectedTab.map(sessions.tabOwner) == id && !sessions.showingOverview)
                            Divider()
                        } else if let draft = sessions.planningDrafts[id] {
                            DraftTabItem(id: id, draft: draft, isSelected: sessions.selectedTab == id && !sessions.showingOverview)
                            Divider()
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            waiting
            Button {
                sessions.showingOverview.toggle()
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(sessions.showingOverview ? Color.accentColor : .secondary)
            .padding(.leading, 8)
            .help(sessions.showingOverview ? "Back to the tab" : "Every session at once")
            addMenu
                .padding(.horizontal, 8)
        }
        .frame(height: 56)
        // Lighter than the window, with the selected tab cut from the page
        // beneath it.
        .background(SessionTabColors.bar)
    }

    /// Jumps to the session waiting on you longest.
    @ViewBuilder
    private var waiting: some View {
        let count = sessions.attention.keys.filter { sessions.sessions[$0] != nil }.count
        if let next = sessions.nextWaiting {
            Button {
                sessions.reveal(next)
            } label: {
                Label(count == 1 ? "1 waiting" : "\(count) waiting", systemImage: "bell.badge")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.orange)
            .padding(.leading, 8)
            .help("Go to the session waiting on you longest (⇧⌘J)")
        }
    }

    /// Sessions already started that have no tab open.
    private var addMenu: some View {
        let closed = sessions.sessions.values
            // Helpers show in their session's tab.
            .filter { !sessions.tabs.contains($0.id) && $0.archivedAt == nil && !$0.isHelper }
            .sorted { $0.createdAt > $1.createdAt }
        let org = sessions.selectedTab.flatMap { sessions.sessions[$0]?.org } ?? sessions.sessions.values.first?.org
        return Menu {
            if let org {
                // In the harness of the session showing, when there is one.
                let harness = sessions.selectedTab.flatMap { sessions.sessions[$0]?.harnessRepo }
                Button("New Ask") {
                    sessions.openDraft(PlanningDraft(org: org, harnessRepo: harness, isAsk: true))
                }
                Button("New Quick Change") {
                    sessions.openDraft(PlanningDraft(org: org, harnessRepo: harness, isQuickChange: true))
                }
                Button("New Plan") {
                    sessions.openDraft(PlanningDraft(org: org, harnessRepo: harness))
                }
                Divider()
            }
            if closed.isEmpty {
                Text("Every session is open")
            }
            ForEach(closed) { session in
                Button("\(session.issue.number > 0 ? "#\(session.issue.number) " : "")\(session.title)\(sessions.isStale(session) ? " (stale)" : "")") { sessions.reveal(session.id) }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open another session in a tab. Work on This on an issue starts a new one.")
    }
}

/// What a tab says it is: a plan, a review or code, with the issue or PR
/// it's about and its title without the kind in front.
private struct TabKind {
    let name: String
    let symbol: String
    let reference: String?
    let title: String

    init(_ session: CodeSession) {
        if let ask = session.ask {
            name = "Ask"
            symbol = "sparkle.magnifyingglass"
            reference = nil
            title = ask.title
        } else if let planning = session.planning {
            name = "Plan"
            symbol = "list.bullet"
            reference = planning.issue?.reference
            title = session.name ?? planning.state?.title ?? planning.topic
        } else if session.isPullRequestReview {
            name = "Review"
            symbol = "arrow.triangle.pull"
            reference = session.issue.reference
            title = session.name ?? session.issue.title
        } else if session.isHelper {
            name = session.role ?? "Helper"
            symbol = session.isReviewer ? "arrow.triangle.pull" : "person.2"
            reference = session.hasNoIssue ? nil : session.issue.reference
            title = session.name ?? session.issue.title
        } else if session.isQuickChange {
            name = "Quick Change"
            symbol = "bolt"
            reference = session.hasNoIssue ? nil : session.issue.reference
            title = session.name ?? session.issue.title
        } else {
            name = "Code"
            symbol = "arrow.triangle.branch"
            reference = session.issue.reference
            title = session.name ?? session.issue.title
        }
    }
}

/// A new plan's tab, until it's started: as a session's tab looks.
private struct DraftTabItem: View {
    @Environment(SessionStore.self) private var sessions
    let id: UUID
    let draft: PlanningDraft
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Image(systemName: draft.isAsk ? "sparkle.magnifyingglass" : draft.isQuickChange ? "bolt" : "list.bullet")
                .font(.system(size: 20))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(draft.isAsk ? "New Ask" : draft.isQuickChange ? "New Quick Change" : "New Plan")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let issue = draft.issue {
                        Text(issue.reference)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Text(draft.topic.isEmpty ? "Not started" : draft.topic)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Button {
                sessions.closeTab(id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .opacity(hovering || isSelected ? 1 : 0)
            .help("Close it; nothing's started")
        }
        .font(.callout)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 250)
        .frame(maxHeight: .infinity)
        .background(isSelected ? SessionTabColors.selected : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            sessions.showingOverview = false
            sessions.selectedTab = id
        }
        .onHover { hovering = $0 }
    }
}

private struct SessionTabItem: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    let session: CodeSession
    let isSelected: Bool
    @State private var hovering = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        let state = sessions.state(session.id)
        let helpers = sessions.helpers(of: session.id)
        // A helper waiting on you marks its session's tab, where it shows.
        let waiting = ([session] + helpers).contains { sessions.attention[$0.id] != nil }
        let kind = TabKind(session)
        HStack(spacing: 8) {
            Circle().fill(state.color).frame(width: 7, height: 7)
                .overlay {
                    if waiting { Circle().stroke(state.color, lineWidth: 1.5).frame(width: 13, height: 13) }
                }
            // What it is, as tall as both lines.
            Image(systemName: kind.symbol)
                .font(.system(size: 20))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // What it is and what it's about, then its title.
                HStack(spacing: 6) {
                    Text(kind.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let reference = kind.reference {
                        Text(reference)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if session.location != .thisMac {
                        Image(systemName: session.location.symbol)
                            .font(.caption)
                            .foregroundStyle(session.location.tint)
                            .help(session.location.name)
                            .accessibilityLabel(session.location.name)
                    }
                    helperStatus(helpers)
                }
                Text(kind.title)
                    .fontWeight(waiting ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Button {
                sessions.requestClose(session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .opacity(hovering || isSelected ? 1 : 0)
            .help(sessions.asksToWrapUp(session.id) ? "Close the tab, wrapping the session up first if you like" : "Close the tab. Claude keeps running.")
        }
        .font(.callout)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 250)
        .frame(maxHeight: .infinity)
        // The tab shown, lighter than the rest.
        .background(isSelected ? SessionTabColors.selected : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRenaming() }
        .onTapGesture {
            sessions.showingOverview = false
            // A helper showing in it stays showing.
            if !isSelected { sessions.selectedTab = session.id }
        }
        .onHover { hovering = $0 }
        .alert("Rename Tab", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { sessions.renameTab(session.id, to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(session.isAsk ? "The Ask's name, wherever it's listed." : "Leave it empty to go back to \(session.issue.title).")
        }
        .help("\(session.hasNoIssue ? "Quick change in \(session.issue.repo)" : session.issue.reference): \(session.issue.title). \(state.label).")
        .draggable(session.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            sessions.moveTab(dragged, to: session.id)
            return true
        }
        .contextMenu {
            Button("Rename Tab") { startRenaming() }
            Divider()
            Button("Close Tab") { sessions.requestClose(session.id) }
            // Leaves them running, as asking about each in turn would wear.
            Button("Close Other Tabs") {
                for id in sessions.tabs where id != session.id { sessions.closeTab(id) }
            }
            .disabled(sessions.tabs.count < 2)
            Divider()
            Button("Show Beside") {
                sessions.showingOverview = false
                sessions.besideTab = session.id
            }
            .disabled(isSelected || sessions.tabs.count < 2)
            if !session.isAsk && !session.isPlanning {
                Button("Open Issue") { openWindow(value: session.issue) }
            }
        }
    }

    private func startRenaming() {
        newName = session.title
        renaming = true
    }

    /// How its review is going, else how many helpers it has: they show in
    /// this tab, not their own.
    @ViewBuilder
    private func helperStatus(_ helpers: [CodeSession]) -> some View {
        if let pairing = session.pairing, pairing.reviewerID.map({ sessions.sessions[$0] != nil }) ?? false {
            Text(pairing.shortStatus)
                .font(.caption.weight(.medium))
                .foregroundStyle(pairing.tint)
                .lineLimit(1)
                .help(pairing.status)
        } else if !helpers.isEmpty {
            Label("\(helpers.count)", systemImage: "person.2")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(helpers.count == 1 ? "1 helper, shown in this tab" : "\(helpers.count) helpers, shown in this tab")
        }
    }
}

/// Above a session that has helpers: its own work, then each helper by its
/// role, with how each is doing, to switch between in the one tab.
private struct SessionAgentSwitcher: View {
    @Environment(SessionStore.self) private var sessions
    let owner: CodeSession
    let helpers: [CodeSession]
    let shown: UUID
    let show: (UUID) -> Void

    var body: some View {
        HStack(spacing: 4) {
            agent(owner, name: "Work", symbol: TabKind(owner).symbol, status: nil)
            ForEach(helpers) { helper in
                let pairing = owner.pairing?.reviewerID == helper.id ? owner.pairing : nil
                agent(helper, name: helper.role ?? "Helper", symbol: helper.isReviewer ? "arrow.triangle.pull" : "person.2", status: pairing)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func agent(_ session: CodeSession, name: String, symbol: String, status: PairReview?) -> some View {
        let state = sessions.state(session.id)
        let isShown = session.id == shown
        let waiting = sessions.attention[session.id] != nil
        return Button {
            show(session.id)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(state.color).frame(width: 7, height: 7)
                    .overlay {
                        if waiting { Circle().stroke(state.color, lineWidth: 1.5).frame(width: 13, height: 13) }
                    }
                Image(systemName: symbol)
                Text(name).fontWeight(isShown || waiting ? .semibold : .regular)
                if let status {
                    Text(status.shortStatus).foregroundStyle(status.tint)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isShown ? AnyShapeStyle(Color.primary.opacity(0.1)) : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(name): \(status?.status ?? state.label)")
        .accessibilityAddTraits(isShown ? .isSelected : [])
    }
}

/// What the side of a session's tab shows.
private enum SessionPane: String {
    case issue, changes, pullRequests, activity
}

/// One session's tab: the terminal claude runs in with a bar beneath for
/// talking to it, and beside it the issue with its plans and requirements,
/// the changes in its worktrees (an Ask session's artifacts and files in
/// its Session pane instead), its PRs, or what claude has been doing. Changes are read again a moment
/// after claude edits a file or runs a command (its hooks say so), and
/// otherwise every so often while the tab shows. Shown beside another, the side panel starts hidden.
struct SessionTab: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    var compact = false
    /// Kept in the store, not local state, so switching tabs away and back
    /// doesn't lose the open file or make it read the diff again.
    private var changes: SessionChanges { sessions.changes(for: session) }
    @State private var panelShown: Bool?
    /// The question put away to answer in the terminal, by its ID (or the
    /// permission prompt's tool).
    @State private var hiddenAsk: String?
    /// Documents dropped on a planning session, being confirmed.
    @State private var sharing: [URL]?
    @AppStorage("sessionsPane") private var pane: SessionPane = .issue
    /// The side panel opens at its widest and is dragged no wider than
    /// this, however wide the window, nor narrower than the least.
    static let panelMaxWidth: Double = 440
    static let panelMinWidth: Double = 300

    /// An Ask's Session pane has its artifacts and files, so it has no
    /// Changes, and PRs only once it has some; a helper's PRs are the
    /// session it helps, so it has none. One remembered pane suits every
    /// kind.
    private var shownPane: Binding<SessionPane> {
        Binding {
            switch pane {
            case .changes where session.isAsk: .issue
            case .pullRequests where !showsPullRequests: .issue
            default: pane
            }
        } set: { pane = $0 }
    }

    private var showsPullRequests: Bool {
        session.isAsk ? hasPullRequests : !session.isHelper
    }

    private var hasPullRequests: Bool {
        !session.pullRequests.isEmpty || !(sessions.pullRequestInfo[session.parentID ?? session.id] ?? []).isEmpty
    }

    var body: some View {
        let shown = panelShown ?? !compact
        Group {
            if shown {
                // The terminal takes the room; the panel opens at its widest
                // and can be dragged narrower.
                FixedSplit(key: "sessionPanelWidth", width: Self.panelMaxWidth, range: Self.panelMinWidth...Self.panelMaxWidth, fixing: .trailing) {
                    terminal(shown: shown)
                } trailing: {
                    panel
                }
            } else {
                terminal(shown: shown)
            }
        }
        // Each change signal starts this again: a short wait lets a burst of
        // edits settle into one read.
        .task(id: sessions.changeCount(session.id)) {
            // An Ask session's folder isn't a worktree: its Files pane
            // reads it instead.
            guard !session.isAsk else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                while true {
                    await changes.refresh(session)
                    // For edits made outside claude, and sessions from
                    // before the hook, slower over ssh.
                    try await Task.sleep(for: .seconds(session.isRemote ? 30 : 10))
                }
            } catch {}
        }
        // At once on opening, and again when claude opens one; the store
        // watches them in the background otherwise.
        .task(id: session.pullRequests) {
            await sessions.refreshPullRequests(session.parentID ?? session.id)
        }
    }

    private func terminal(shown: Bool) -> some View {
        VStack(spacing: 0) {
            if compact {
                SessionTabHeader(session: session, panelShown: Binding(get: { shown }, set: { panelShown = $0 }))
                Divider()
            }
            TerminalHost(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { askOverlay }
                // A planning session takes documents dropped on it,
                // each confirmed before claude sees it.
                .dropDestination(for: URL.self) { urls, _ in
                    guard session.isPlanning, !urls.isEmpty else { return false }
                    sharing = urls.filter(\.isFileURL)
                    return true
                }
                .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
                    ShareDocumentsSheet(session: session, files: sharing ?? [])
                }
            Divider()
            SessionComposer(session: session, panelShown: compact ? nil : Binding(get: { shown }, set: { panelShown = $0 }))
        }
        .frame(minWidth: compact ? 360 : 480, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: shownPane) {
                Text(session.isAsk || session.isHelper ? "Session" : "Issue").tag(SessionPane.issue)
                if !session.isAsk {
                    Text(changes.fileCount > 0 ? "Changes \(changes.fileCount)" : "Changes").tag(SessionPane.changes)
                }
                if showsPullRequests {
                    Text(pullRequestsLabel).tag(SessionPane.pullRequests)
                }
                Text("Activity").tag(SessionPane.activity)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            Group {
                switch shownPane.wrappedValue {
                case .issue: SessionPanel(session: session)
                case .changes: SessionChangesPane(session: session, changes: changes)
                case .pullRequests: SessionPullRequestsPane(session: session)
                case .activity: SessionActivityPane(session: session)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            SessionLocationBadge(session: session, prominent: true)
                .padding(8)
        }
    }

    /// What claude is asking, floating over the terminal; put away, a
    /// small button brings it back.
    @ViewBuilder
    private var askOverlay: some View {
        let transcript = sessions.transcripts[session.id]
        let key = transcript?.question?.id ?? transcript?.pendingTool?.id ?? "permission"
        if SessionQuestionCard.isAsking(session, in: sessions) {
            if hiddenAsk == key {
                Button {
                    hiddenAsk = nil
                } label: {
                    Label("Claude is asking", systemImage: "questionmark.bubble.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                SessionQuestionCard(session: session) { hiddenAsk = key }
                    .frame(maxWidth: 820)
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var pullRequestsLabel: String {
        let pullRequests = sessions.pullRequestInfo[session.parentID ?? session.id] ?? []
        guard !pullRequests.isEmpty else { return "PRs" }
        let failed = pullRequests.filter { $0.state == "OPEN" }.reduce(0) { $0 + $1.failed.count }
        return failed > 0 ? "PRs \(pullRequests.count) ✕\(failed)" : "PRs \(pullRequests.count)"
    }
}

/// A tab's own header when it's one of two side by side.
extension CodeSession {
    var location: SessionLocation { SessionLocation(sandboxed: isSandboxed, connect: connect) }
}

extension SessionLocation {
    var tint: Color {
        switch self {
        case .thisMac: .orange
        case .sandbox, .sandboxOnServer: .green
        case .server: .blue
        }
    }
}

/// Where the session's claude runs, always in view: this Mac, a sandbox,
/// the server or a sandbox there, with the sandbox's state.
private struct SessionLocationBadge: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    /// The panel's full-width banner rather than the compact header's chip.
    let prominent: Bool

    var body: some View {
        let location = session.location
        let status = location.isSandboxed
            ? SandboxStatus(sessions.isRunning(session.id) ? sessions.sandboxStatus[session.id] : "stopped")
            : nil
        HStack(spacing: 6) {
            Image(systemName: location.symbol)
                .foregroundStyle(location.tint)
            Text(location.name)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
            if let status {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.label)
                    .foregroundStyle(.secondary)
            }
            if prominent { Spacer(minLength: 0) }
        }
        .font(prominent ? .callout : .caption)
        .padding(.horizontal, prominent ? 10 : 6)
        .padding(.vertical, prominent ? 6 : 2)
        .background(location.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: prominent ? 6 : 4))
        .help([location.explanation, session.sandbox].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Runs on \(location.name)\(status.map { ", \($0.label.lowercased())" } ?? "")")
    }
}

private struct SessionTabHeader: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    @Binding var panelShown: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(sessions.state(session.id).color).frame(width: 7, height: 7)
            Text(session.shortReference).foregroundStyle(.secondary)
            Text(session.title).lineLimit(1)
            Spacer()
            SessionLocationBadge(session: session, prominent: false)
            Button {
                panelShown.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help(panelShown ? "Hide the side panel" : "Show the side panel")
            if sessions.besideTab == session.id {
                Button {
                    sessions.besideTab = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Stop showing this beside")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }
}

/// The files the session has changed, per worktree, against where its
/// branch left the default branch (committed or not, and new files), and the
/// picked one's diff.
private struct SessionChangesPane: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    @Bindable var changes: SessionChanges
    @State private var discarding: ChangedFile?
    @State private var committing: WorktreeChanges?
    @State private var actionError: String?

    private func worktreeHeader(_ worktree: WorktreeChanges) -> some View {
        HStack(spacing: 8) {
            Text(worktree.name)
            Spacer()
            Group {
                if let unpushed = worktree.unpushed, unpushed > 0 {
                    Text(unpushed == 1 ? "1 not pushed" : "\(unpushed) not pushed").foregroundStyle(.orange)
                } else if worktree.hasUpstream {
                    Text("Pushed")
                } else {
                    Text("Not pushed yet")
                }
            }
            .fontWeight(.regular)
            .help("Commits on this branch that aren't on GitHub yet")
            if changes.mode == .uncommitted {
                if worktree.files.contains(where: \.isStaged) {
                    Button("Commit") { committing = worktree }
                        .controlSize(.mini)
                }
                if (worktree.unpushed ?? 0) > 0 || !worktree.hasUpstream {
                    Button("Push") { Task { actionError = await changes.push(worktree, session: session) } }
                        .controlSize(.mini)
                }
            } else {
                Text("against \(worktree.baseLabel)")
                    .fontWeight(.regular)
            }
        }
    }

    @ViewBuilder
    private func fileMenu(_ file: ChangedFile) -> some View {
        if changes.mode == .uncommitted {
            if file.isStaged {
                Button("Unstage") { Task { actionError = await changes.unstage(file, session: session) } }
            } else {
                Button("Stage") { Task { actionError = await changes.stage(file, session: session) } }
            }
            Button(file.status == .untracked ? "Delete File" : "Discard Changes", role: .destructive) { discarding = file }
            Divider()
        }
        Button("Open in \(CodeEditor.chosen.name)") {
            sessions.openInEditor(session, worktree: file.worktree, path: file.path, line: nil)
        }
        .disabled(session.isRemote && !CodeEditor.chosen.opensRemote)
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.worktree + "/" + file.path, forType: .string)
        }
    }

    /// The comments waiting to go to claude, across files.
    @ViewBuilder
    private var commentsBar: some View {
        let drafts = sessions.drafts[session.id] ?? []
        if !drafts.isEmpty {
            let running = sessions.isRunning(session.id)
            HStack {
                Label(drafts.count == 1 ? "1 comment" : "\(drafts.count) comments", systemImage: "text.bubble")
                Spacer()
                Button("Discard") { sessions.clearDrafts(session.id) }
                Button("Send to Claude") {
                    if sessions.submit(SessionPrompts.diffComments(drafts, in: session), to: session.id) {
                        sessions.clearDrafts(session.id)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!running)
                .help(running ? "Paste the comments into claude's prompt. If it's working, it reads them when it's done." : "Start the session first")
            }
            .padding(8)
            .background(.bar)
            Divider()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Changes", selection: $changes.mode) {
                ForEach(SessionChanges.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .help("Branch: everything since it left the default branch. Uncommitted: what isn't committed yet, to stage, discard and commit.")
            Divider()
            content
        }
        .onChange(of: changes.mode) {
            Task { await changes.refresh(session) }
        }
        .confirmationDialog("Discard the changes to \(discarding.map { ($0.path as NSString).lastPathComponent } ?? "the file")?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }), presenting: discarding) { file in
            Button(file.status == .untracked ? "Delete File" : "Discard Changes", role: .destructive) {
                Task { actionError = await changes.discard(file, session: session) }
            }
        } message: { file in
            Text(file.status == .untracked ? "It's new and not in git, so it's deleted." : "It goes back to its last commit, staged changes included. Claude isn't told.")
        }
        .sheet(item: $committing) { worktree in
            CommitSheet(session: session, changes: changes, worktree: worktree)
        }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = changes.error, changes.worktrees.isEmpty {
            ContentUnavailableView {
                Label("Couldn't read the changes", systemImage: session.isRemote ? "server.rack" : "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await changes.refresh(session) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !changes.loaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if changes.worktrees.isEmpty {
            ContentUnavailableView("No worktrees yet", systemImage: "arrow.triangle.branch", description: Text("Claude adds a worktree for each repo the issue touches, and what it changes shows here as it works."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VSplitView {
                List(selection: $changes.selected) {
                    ForEach(changes.worktrees) { worktree in
                        Section {
                            if worktree.files.isEmpty {
                                Text("No changes")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(worktree.files) { file in
                                ChangedFileRow(file: file, showsStaged: changes.mode == .uncommitted)
                                    .tag(file.id)
                                    .contextMenu { fileMenu(file) }
                            }
                        } header: {
                            worktreeHeader(worktree)
                        }
                    }
                }
                .frame(minHeight: 120, idealHeight: 240)
                DiffPane(session: session, changes: changes)
                    .frame(minHeight: 120, maxHeight: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    commentsBar
                    // Still showing what was read last.
                    if let error = changes.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.bar)
                    }
                }
            }
            .onChange(of: changes.selected) {
                Task { await changes.refresh(session) }
            }
        }
    }
}

private struct ChangedFileRow: View {
    let file: ChangedFile
    var showsStaged = false

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            Text(file.status == .untracked ? "A" : file.status.rawValue)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 12)
            Text(name)
                .lineLimit(1)
            if !folder.isEmpty {
                Text(folder)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if showsStaged, file.isStaged {
                Text("staged")
                    .font(.caption)
                    .foregroundStyle(ChartPalette.good)
            }
            if let added = file.added, let removed = file.removed {
                if added > 0 { Text("+\(added)").foregroundStyle(ChartPalette.good) }
                if removed > 0 { Text("-\(removed)").foregroundStyle(ChartPalette.critical) }
            } else {
                Text("binary").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .help(file.status == .untracked ? "\(file.path), new and not yet added" : file.path)
    }

    private var statusColor: Color {
        switch file.status {
        case .added, .untracked: ChartPalette.good
        case .deleted: ChartPalette.critical
        case .modified: .orange
        }
    }
}

/// The picked file's diff, numbered, with comments: hover a line and click
/// its bubble (or click the number) to leave one for claude.
private struct DiffPane: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let changes: SessionChanges
    @State private var hovered: DiffLine.ID?
    @State private var commenting: DiffLine.ID?

    var body: some View {
        if let file = changes.selectedFile {
            let worktreeName = changes.worktrees.first { $0.path == file.worktree }?.name ?? ""
            let drafts = (sessions.drafts[session.id] ?? []).filter { $0.worktree == file.worktree && $0.path == file.path }
            VStack(spacing: 0) {
                Text(file.path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(changes.diff) { line in
                            DiffPaneRow(session: session, changes: changes, file: file, worktreeName: worktreeName, line: line, hovered: $hovered, commenting: $commenting)
                            ForEach(drafts.filter { $0.matches(file, line) }) { comment in
                                DraftCommentView(comment: comment) {
                                    sessions.removeDraft(comment.id, from: session.id)
                                }
                            }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("No file selected", systemImage: "doc.text.magnifyingglass", description: Text("Pick a file to see its diff."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One line of a file's diff with its comment popover. A dedicated view
/// (not a function on `DiffPane`) with narrow inputs: adding or removing a
/// draft comment on another line invalidates `DiffPane`, but this row only
/// re-renders when its own inputs change, so a comment popover left open
/// doesn't lose the TextEditor's cursor position.
private struct DiffPaneRow: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let changes: SessionChanges
    let file: ChangedFile
    let worktreeName: String
    let line: DiffLine
    @Binding var hovered: DiffLine.ID?
    @Binding var commenting: DiffLine.ID?

    var body: some View {
        let anchor = line.anchor
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ZStack(alignment: .trailing) {
                Text(anchor.map { "\($0.line)" } ?? "")
                    .foregroundStyle(.tertiary)
                    .opacity(hovered == line.id && anchor != nil ? 0 : 1)
                if hovered == line.id, anchor != nil {
                    Image(systemName: "plus.bubble.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
            .onTapGesture { if anchor != nil { commenting = line.id } }
            .help(anchor != nil ? "Comment on this line for claude" : "")
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(DiffStyle.foreground(line.kind))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if line.kind == .hunk, changes.mode == .uncommitted, file.status != .untracked {
                Button("Discard") {
                    Task { _ = await changes.discardHunk(at: line.id, session: session) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Undo this part of the change in the file. Claude isn't told.")
            }
        }
        .font(Font(EditorFontStore.shared.font))
        .padding(.trailing, 6)
        .background(DiffStyle.background(line.kind))
        .onHover { inside in
            if inside { hovered = line.id } else if hovered == line.id { hovered = nil }
        }
        .contextMenu {
            if let anchor, !anchor.isOld {
                Button("Open in \(CodeEditor.chosen.name)") {
                    sessions.openInEditor(session, worktree: file.worktree, path: file.path, line: anchor.line)
                }
            }
            if anchor != nil {
                Button("Comment on This Line") { commenting = line.id }
            }
        }
        .popover(isPresented: Binding(get: { commenting == line.id }, set: { if !$0 { commenting = nil } }), arrowEdge: .leading) {
            if let anchor {
                CommentEditor(location: "\(file.path):\(anchor.line)") { body in
                    sessions.addDraft(DiffComment(
                        worktree: file.worktree, worktreeName: worktreeName, path: file.path,
                        line: anchor.line, isOld: anchor.isOld, code: String(line.text.dropFirst()), body: body
                    ), to: session.id)
                    commenting = nil
                } cancel: {
                    commenting = nil
                }
            }
        }
    }
}

private struct CommentEditor: View {
    let location: String
    let add: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(location)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 320, height: 90)
                .focused($focused)
            HStack {
                Text("Sent with the others when you Send to Claude")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }
}

private struct DraftCommentView: View {
    let comment: DiffComment
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble.fill")
                .foregroundStyle(Color.accentColor)
            Text(comment.body)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: remove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Remove this comment")
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.leading, 40)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
    }
}

/// Commit what's staged in a worktree, with a message of your own or one
/// claude writes.
private struct CommitSheet: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    let session: CodeSession
    let changes: SessionChanges
    let worktree: WorktreeChanges
    @State private var message = ""
    @State private var error: String?

    var body: some View {
        let staged = worktree.files.filter(\.isStaged)
        Form {
            Section {
                TextField("Message", text: $message, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("Commit \(staged.count == 1 ? "1 file" : "\(staged.count) files") in \(worktree.name)")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text(staged.map(\.path).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem {
                Button("Ask Claude to Commit") {
                    sessions.submit("Commit what's staged in \(session.isInHarness ? ".worktrees/\(session.branch)/\(worktree.name)" : "this worktree") with a clear message. Don't add anything else to the commit.", to: session.id)
                    dismiss()
                }
                .disabled(!sessions.isRunning(session.id))
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Commit") {
                    Task {
                        error = await changes.commit(worktree, message: message, session: session)
                        if error == nil { dismiss() }
                    }
                }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// Hosts the store's terminal view, launching it when first shown.
struct TerminalHost: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    @State private var view: NSView?

    var body: some View {
        Group {
            if let view {
                TerminalRepresentable(view: view)
            } else {
                Color.clear
            }
        }
        .onAppear {
            view = sessions.open(session)
            sessions.terminal(session.id)?.focus()
        }
        // Restart swaps the terminal inside the same container, so only the
        // keyboard needs putting back.
        .onChange(of: sessions.state(session.id)) { _, state in
            if state == .starting { sessions.terminal(session.id)?.focus() }
        }
    }
}

private struct TerminalRepresentable: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        // Moved from a window that was closed, or first shown.
        view.removeFromSuperview()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A harness document open over the session.
private struct HarnessReading: Identifiable {
    let path: String
    var id: String { path }
}

/// A helper's (a reviewer's, say) link back to the session it helps,
/// where the issue, its plans and its PRs are.
private struct HelperParentSection: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    let session: CodeSession

    var body: some View {
        let parent = session.parentID.flatMap { sessions.sessions[$0] }
        Section(session.isReviewer ? "Reviewing" : "Helping with") {
            if let parent {
                let state = sessions.state(parent.id)
                Text(parent.title)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Circle().fill(state.color).frame(width: 8, height: 8)
                        Text(state.label)
                    }
                }
            } else {
                Text("The session it helped is gone.")
                    .foregroundStyle(.secondary)
            }
            // A quick change has no issue (number 0).
            if session.issue.number > 0 || parent != nil {
                HStack {
                    if session.issue.number > 0 {
                        Link(session.issue.reference, destination: session.issue.url)
                    }
                    Spacer()
                    if session.issue.number > 0 {
                        Button("Open Issue") { openWindow(value: session.issue) }
                    }
                    if let parent {
                        Button("Show Session") { sessions.reveal(parent.id) }
                            .help("The working session, with the issue, its plans and its PRs")
                    }
                }
            }
        }
    }
}

private struct SessionPanel: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.openWindow) private var openWindow
    let session: CodeSession
    @State private var confirmingRemove = false
    @State private var reading: HarnessReading?
    /// An Ask's file picked for Commit to Harness, and Save a Copy's error.
    @State private var committing: SessionFile?
    @State private var fileError: String?

    var body: some View {
        let state = sessions.state(session.id)
        let worktree = SessionStore.worktree(for: session)
        let worktreePath = SessionStore.worktreePath(for: session)
        Form {
            PlanningSection(session: session)
            if session.isAsk {
                AskArtifactsSection(session: session)
                AskFilesSections(session: session, files: sessions.files(for: session), committing: $committing, error: $fileError)
            }
            if session.isQuickChange {
                QuickChangeSection(session: session)
            }
            if session.isHelper {
                HelperParentSection(session: session)
            } else if !session.isPlanning && !session.isAsk && !session.hasNoIssue {
            Section("Issue") {
                Text(session.issue.title)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link(session.issue.reference, destination: session.issue.url)
                    Spacer()
                    Button("Open Issue") { openWindow(value: session.issue) }
                }
            }
            }
            Section("Claude Code") {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Circle().fill(state.color).frame(width: 8, height: 8)
                        Text(state.label)
                    }
                }
                LabeledContent("Branch") {
                    Text(session.branch)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent(session.isInHarness ? (session.isRemote ? "Folder on the server" : "Folder") : (session.isRemote ? "Worktree on the server" : "Worktree")) {
                    Text(worktreePath)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(worktreePath)
                }
                if session.isSandboxed {
                    let status = SandboxStatus(sessions.isRunning(session.id) ? sessions.sandboxStatus[session.id] : "stopped")
                    if let error = status.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let reason = session.hostReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let folder = session.harnessFolder, let repo = session.harnessRepo,
                   let url = URL(string: "https://github.com/\(repo)/tree/HEAD/\(folder)") {
                    LabeledContent("In the harness") {
                        Link(folder, destination: url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let error = sessions.recordErrors[session.id] {
                    Text("Couldn't commit to the harness: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(session.pullRequests, id: \.self) { pullRequest in
                    let parts = pullRequest.pathComponents
                    LabeledContent("Pull request") {
                        Link(parts.count >= 5 ? "\(parts[2])#\(parts[4])" : "Open", destination: pullRequest)
                    }
                }
                HStack {
                    if let worktree {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([worktree])
                        }
                        .disabled(!FileManager.default.fileExists(atPath: worktree.path))
                    }
                    Spacer()
                    if sessions.isRunning(session.id) {
                        Button("End") { sessions.end(session.id) }
                            .help("End claude and the shell it runs in. The worktree stays, and Restart resumes the conversation.")
                    } else {
                        Button("Restart") { _ = sessions.open(session) }
                            .help("Start the terminal again, resuming claude's conversation")
                    }
                    // An Ask goes with its folder, from its list's Delete.
                    if !session.isAsk {
                        Button("Remove", role: .destructive) { confirmingRemove = true }
                    }
                }
            }
            SessionFinishSection(session: session)
            // A helper's issue, plans and PRs are on the session it helps.
            if !session.isPlanning && !session.isAsk && !session.isHelper && !session.hasNoIssue {
                HarnessIssueSection(reference: session.issue, showsEmpty: true, harnessRepo: session.harnessRepo)
            }
        }
        .formStyle(.grouped)
        .modifier(AskFilesRefresh(session: session, files: sessions.files(for: session), committing: $committing, error: $fileError))
        // Documents open over the session; issues and PRs they name, in
        // windows of their own.
        .environment(\.navigate, NavigateAction { selection in
            switch selection {
            case .harnessDocument(let path): reading = HarnessReading(path: path)
            case .issueReference(let reference): openWindow(value: reference)
            case .pullRequestReference(let reference): openWindow(value: reference)
            default: break
            }
        })
        .sheet(item: $reading) { reading in
            HarnessDocumentPage(org: session.org, path: reading.path) { self.reading = nil }
                .frame(minWidth: 760, idealWidth: 900, minHeight: 560, idealHeight: 760)
        }
        .task {
            // The harness it runs in, as the org reads it.
            let config = configs.config(for: session.org)
            if let setup = session.harnessRepo.flatMap(config.harness(repo:)) ?? config.harness {
                await harness.load(org: session.org, setup: setup)
            }
        }
        .confirmationDialog("Remove this session?", isPresented: $confirmingRemove) {
            Button("Remove Session", role: .destructive) { sessions.remove(session.id) }
        } message: {
            Text("Claude is ended and Gannin forgets the session. \(session.isInHarness ? "Its folder and worktrees stay" : "The worktree stays") at \(worktreePath)\(session.isRemote ? " on the server" : "") for you to remove with git worktree remove.")
        }
    }
}

/// Work on This: make (or open) the issue's session in the org's harness,
/// with a brief written from what Gannin knows about the issue and its plans
/// now. Claude works out which repos it touches.
struct StartSessionButton: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(IssueStore.self) private var issues
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.openWindow) private var openWindow
    let reference: IssueReference
    @State private var request: IssueReference?

    var body: some View {
        if let existing = sessions.session(forIssue: reference.id) {
            Button {
                sessions.show(existing.id, with: openWindow)
            } label: {
                Label("Open Session", systemImage: "terminal")
            }
            .help("Show this issue's Claude Code session, in \(existing.repo)")
        } else {
            let blocked = WorkOnThisLauncher.unavailable(reference, configs: configs, issues: issues)
            Button {
                request = reference
            } label: {
                Label("Work on This", systemImage: "terminal")
            }
            .disabled(blocked != nil)
            .help(blocked ?? "Work on this issue with Claude Code, in \(configs.config(for: reference.org).harness(covering: WorkOnThisLauncher.repos(reference, issues: issues))?.repo ?? "the org's harness")")
            .workOnThis($request)
        }
    }
}

/// Work on This in a context menu: Open Session once the issue has one.
/// It sets `request`, which a `.workOnThis` on the list (not the row,
/// whose menu closes) takes from there.
struct WorkOnThisMenuItem: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(IssueStore.self) private var issues
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.openWindow) private var openWindow
    let reference: IssueReference
    @Binding var request: IssueReference?

    var body: some View {
        if let existing = sessions.session(forIssue: reference.id) {
            Button("Open Session") { sessions.show(existing.id, with: openWindow) }
        } else {
            Button("Work on This") { request = reference }
                .disabled(WorkOnThisLauncher.unavailable(reference, configs: configs, issues: issues) != nil)
        }
    }
}

extension View {
    /// Starts a session on the issue put in `request`, asking first as Work
    /// on This does: the team's prompts and skills when there are any, else
    /// whether to record it in the harness (unless told not to ask again).
    func workOnThis(_ request: Binding<IssueReference?>) -> some View {
        modifier(WorkOnThisLauncher(request: request))
    }
}

/// What Work on This does once asked, wherever it was asked from.
struct WorkOnThisLauncher: ViewModifier {
    @Environment(SessionStore.self) private var sessions
    @Environment(IssueStore.self) private var issues
    @Environment(DetailStore.self) private var details
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    @Environment(AuthStore.self) private var auth
    @Environment(\.openWindow) private var openWindow
    @Binding var request: IssueReference?
    /// While the harness commit is confirmed.
    @State private var confirming: IssueReference?
    /// While the team's prompts and skills are picked.
    @State private var choosing: IssueReference?
    @State private var recording = true
    /// Whether the session runs in a sandbox, as picked in the sheet.
    @State private var sandboxed = true

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, asked in
                guard let asked else { return }
                request = nil
                begin(asked)
            }
            .confirmationDialog("Record this session in the harness?", isPresented: isConfirming, presenting: confirming) { reference in
                let setup = setup(for: reference)
                Button("Commit to Harness") { start(reference, recording: true, choice: nil, setup: setup) }
                Button("Don't Record") {
                    recordWithoutAsking(reference).wrappedValue = false
                    start(reference, recording: false, choice: nil, setup: setup)
                }
                Button("Cancel", role: .cancel) { recordWithoutAsking(reference).wrappedValue = false }
            } message: { reference in
                Text(Self.recordMessage(reference))
            }
            .dialogSuppressionToggle("Don't ask again for \(confirming?.org ?? "this org")", isSuppressed: confirming.map(recordWithoutAsking) ?? .constant(false))
            .sheet(item: $choosing) { reference in
                let config = configs.config(for: reference.org)
                let skipsAsking = recordWithoutAsking(reference).wrappedValue
                if let initial = setup(for: reference) {
                    SessionLaunchSheet(
                        title: "Work on \(reference.reference)", org: reference.org, harnesses: config.harnesses, initial: initial,
                        use: .work, repos: Self.repos(reference, issues: issues), values: Self.values(reference), startTitle: "Work on This"
                    ) { choice, picked in
                        start(reference, recording: skipsAsking || recording, choice: choice, setup: picked)
                    } extra: {
                        if SandboxCredentials.isEnabled {
                            let offered = placement(for: reference)
                            Section {
                                Picker("Run in", selection: $sandboxed) {
                                    Text("A sandbox").tag(true)
                                    Text("This Mac").tag(false)
                                }
                                .pickerStyle(.segmented)
                                .disabled(!offered.isSandboxed)
                                Text(offered.reason ?? (sandboxed
                                    ? "Claude works in a Linux sandbox that sees only this issue's folder, the shared clones' git and the harness, read-only."
                                    : "Claude works on this Mac as you, able to reach everything you can."))
                                    .font(.caption)
                                    .foregroundStyle(offered.isSandboxed ? Color.secondary : Color.orange)
                            }
                        }
                        if !skipsAsking {
                            Section {
                                Toggle("Record the session in the harness", isOn: $recording)
                                Text(Self.recordMessage(reference))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    /// Don't ask again before recording, per org.
    private func recordWithoutAsking(_ reference: IssueReference) -> Binding<Bool> {
        let key = SessionStore.asksBeforeRecordingKey(reference.org)
        return Binding(get: { UserDefaults.standard.bool(forKey: key) }, set: { UserDefaults.standard.set($0, forKey: key) })
    }

    private func setup(for reference: IssueReference) -> HarnessConfig? {
        configs.config(for: reference.org).harness(covering: Self.repos(reference, issues: issues))
    }

    private func begin(_ reference: IssueReference) {
        if let existing = sessions.session(forIssue: reference.id) {
            sessions.show(existing.id, with: openWindow)
            return
        }
        guard Self.unavailable(reference, configs: configs, issues: issues) == nil else { return }
        let config = configs.config(for: reference.org)
        let setup = setup(for: reference)
        // With sandboxing on, always asked, so this one can run on the Mac.
        if let setup, SandboxCredentials.isEnabled || SessionLaunchSheet<EmptyView>.hasChoices(sessions.promptLibrary(org: reference.org, setup: setup), use: .work, harnesses: config.harnesses) {
            recording = true
            sandboxed = placement(for: reference).isSandboxed
            choosing = reference
        } else if recordWithoutAsking(reference).wrappedValue {
            start(reference, recording: true, choice: nil, setup: setup)
        } else {
            confirming = reference
        }
    }

    /// Where the session would run by default (R3, R8).
    private func placement(for reference: IssueReference) -> SandboxPlacement {
        SandboxPlacement.decide(
            enabled: SandboxCredentials.isEnabled, repos: Self.repos(reference, issues: issues),
            reposNeedingMac: configs.config(for: reference.org).reposNeedingMac, org: reference.org,
            hasGitHubToken: SandboxCredentials.gitHubToken(org: reference.org) != nil,
            connectsBySSH: SessionStore.connectCommand.map { Shell.sshArguments($0) != nil } ?? true
        )
    }

    static func recordMessage(_ reference: IssueReference) -> String {
        "Gannin commits \(SessionStore.harnessFolder(for: reference))/brief.md and session.json to the harness it runs in, on its default branch, so the team can see the session and any box can start it. When Claude opens a pull request, it's added to session.json."
    }

    /// The issue's repo and those its linked PRs are in, for repos' own
    /// default prompts.
    static func repos(_ reference: IssueReference, issues: IssueStore) -> [String] {
        let linked = (issues.history(for: reference.org)?.issues[reference.id]?.linkedPullRequests ?? []).compactMap { pr -> String? in
            let parts = pr.url.pathComponents.filter { $0 != "/" }
            return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
        }
        var seen: Set<String> = []
        return ([reference.repo] + linked).filter { seen.insert($0).inserted }
    }

    static func values(_ reference: IssueReference) -> [String: String] {
        HarnessPromptLibrary.values(reference: reference.reference, title: reference.title, url: reference.url, repo: reference.repo, number: reference.number, branch: SessionStore.branchName(reference))
    }

    /// Why a session can't start, if it can't: sessions run in the org's
    /// harness, and on a server only once its checkout there is set.
    static func unavailable(_ reference: IssueReference, configs: OrgConfigStore, issues: IssueStore) -> String? {
        let config = configs.config(for: reference.org)
        // With several harnesses, the sheet says which can't start.
        guard config.harnesses.count < 2 else { return nil }
        return SessionStore.unavailable(org: reference.org, harness: config.harness(covering: repos(reference, issues: issues)))
    }

    private func start(_ reference: IssueReference, recording: Bool, choice: PromptChoice?, setup: HarnessConfig?) {
        let history = issues.history(for: reference.org)
        let record = history?.issues[reference.id]
        let parent = record?.parentID.flatMap { history?.issues[$0] }
        let detail = details.detail(for: reference.id)
        guard let setup, let path = SessionStore.harnessPath(org: reference.org, repo: setup.repo) else { return }
        let index = harness.index(for: reference.org, setup)
        let repos = Self.repos(reference, issues: issues)
        // The project the session runs in, which outside a main window
        // needn't be the one `configs` reads.
        let goals = configs.scoped(setup.repo).config(for: reference.org).measurables
        let instructions = sessions.launchInstructions(org: reference.org, setup: setup, use: .work, repos: repos, choice: choice, values: Self.values(reference))
        let decided = placement(for: reference)
        // Picked in the sheet: the Mac over a sandbox, never the other way.
        let chosen: SandboxPlacement = decided.isSandboxed && !sandboxed ? .host(SandboxPlacement.pickedHost) : decided
        let session = sessions.start(reference, harness: setup, harnessPath: path, instructions: instructions, placement: chosen) { session in
            SessionBrief.make(session: session, record: record, detail: detail, parent: parent, harness: index, goals: goals)
        }
        guard recording else {
            sessions.show(session.id, with: openWindow)
            return
        }
        // Committed before the terminal starts, so its pull brings the brief.
        let login = auth.viewer?.login
        Task {
            await sessions.record(session.id, startedBy: login)
            sessions.show(session.id, with: openWindow)
        }
    }
}

/// The org's sessions, for the sidebar: each opens its tab.
struct SessionSidebarRows: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    let org: String
    @AppStorage("sidebarSessionsIssues") private var issuesExpanded = true
    @AppStorage("sidebarSessionsReviews") private var reviewsExpanded = true
    @AppStorage("sidebarSessionsPlanning") private var planningExpanded = true
    @AppStorage("sidebarSessionsAsk") private var askExpanded = true

    var body: some View {
        let all = sessions.sessions(for: org)
        group("Working on issues", symbol: "terminal", sessions: all.filter { !$0.isPullRequestReview && !$0.isPlanning && !$0.isAsk }, expanded: $issuesExpanded)
        // Active reviews, newest first, then the history.
        let reviews = all.filter(\.isPullRequestReview)
        let active = reviews.filter { $0.archivedAt == nil }
        let finished = reviews.filter { $0.archivedAt != nil }.sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        group("Reviews", symbol: "eye", sessions: active + finished, expanded: $reviewsExpanded)
        group("Planning", symbol: "list.bullet.clipboard", sessions: all.filter(\.isPlanning), expanded: $planningExpanded)
        group("Ask", symbol: "sparkle.magnifyingglass", sessions: sessions.askSessions(for: org), expanded: $askExpanded)
    }

    /// A kind of session, with how many are waiting on you; empty kinds
    /// aren't shown.
    @ViewBuilder
    private func group(_ title: String, symbol: String, sessions list: [CodeSession], expanded: Binding<Bool>) -> some View {
        if !list.isEmpty {
            let waiting = list.filter { sessions.attention[$0.id] != nil }.count
            DisclosureGroup(isExpanded: expanded) {
                ForEach(list) { session in
                    row(session)
                }
            } label: {
                Label(title, systemImage: symbol)
                    .badge(waiting > 0 ? Text("\(waiting) waiting") : Text("\(list.count)"))
            }
        }
    }

    /// Approved, Changes requested or Commented, as posted.
    private func postedText(_ session: CodeSession) -> String {
        (sessions.reviewDrafts[session.id] ?? session.reviewDraft)?.postedLabel?.text ?? "Posted"
    }

    private func row(_ session: CodeSession) -> some View {
        let state = sessions.state(session.id)
        let finished = session.archivedAt != nil
        let posted = (sessions.reviewDrafts[session.id]?.posted ?? session.reviewDraft?.posted) != nil
        let working = sessions.isRunning(session.id) && (state == .working || state == .starting)
        return Button {
            sessions.show(session.id, with: openWindow)
        } label: {
            Label {
                Text(session.title).lineLimit(1)
                    .foregroundStyle(finished ? .secondary : .primary)
            } icon: {
                Image(systemName: finished ? (posted ? "checkmark.circle.fill" : "archivebox") : "circle.fill")
                    .font(.system(size: finished ? 10 : 8))
                    .foregroundStyle(finished ? (posted ? ChartPalette.good : .secondary) : state.color)
            }
        }
        .buttonStyle(.plain)
        .badge(Text(finished ? (posted ? postedText(session) : "Done") : posted && !working ? postedText(session) : state.label))
        .contextMenu {
            if finished {
                Button("Resume Review") {
                    sessions.resumeReview(session.id)
                    sessions.show(session.id, with: openWindow)
                }
                Button("Remove from History", role: .destructive) { sessions.remove(session.id) }
            }
            if let url = session.reviewOf?.url {
                Link("Open on GitHub", destination: url)
            }
        }
        .help("\(session.issue.number > 0 ? session.issue.reference + ": " : "")\(state.label)")
    }
}

/// Settings > General: where Gannin clones a harness, and the server
/// sessions run on.
struct SessionSettingsSection: View {
    @AppStorage(SessionStore.workspaceKey) private var workspace = SessionStore.defaultWorkspace
    @AppStorage(SessionStore.connectKey) private var connect = ""
    @AppStorage(SessionStore.providerKey) private var provider: AIProvider = .anthropic
    @AppStorage(SessionStore.modelKey) private var model = ""
    @AppStorage(SessionStore.notifiesKey) private var notifies = true
    @AppStorage(SessionStore.sendsFeedbackKey) private var sendsFeedback = false
    @AppStorage(SessionStore.pairReviewKey) private var pairReview = true
    @AppStorage(SessionStore.wrapUpKey) private var wrapsUp = true
    @AppStorage(EngineerWatch.menuBarKey) private var showsMenuBar = true
    @AppStorage(AutoReview.enabledKey) private var autoReview = false
    @AppStorage(AutoReview.watchKey) private var watchesReviews = true
    @AppStorage(AutoReview.postKey) private var postsReviews = false
    @AppStorage(SessionStore.recordReviewsKey) private var recordsReviews = true
    /// Typing a model ID of your own, rather than picking one.
    @State private var customModel = false

    private static let custom = "\u{0}custom"

    var body: some View {
        Section {
            Picker("Provider", selection: $provider) {
                ForEach(AIProvider.allCases) { Text($0.name).tag($0) }
            }
            let known = provider.models.contains { $0.id == model }
            Picker("Model", selection: Binding(
                get: { customModel || (!model.isEmpty && !known) ? Self.custom : model },
                set: { picked in
                    customModel = picked == Self.custom
                    if !customModel { model = picked }
                }
            )) {
                Text("Claude Code's default").tag("")
                Divider()
                ForEach(provider.models) { Text($0.name).tag($0.id) }
                Divider()
                Text("Other").tag(Self.custom)
            }
            if customModel || (!model.isEmpty && !known) {
                TextField("Model ID", text: $model, prompt: Text("claude-opus-5-5"))
            }
            Text("Sessions run Claude Code with this model (--model), from their next start or Restart. Its default is what Claude Code's own settings say; /model in a session changes it there.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Gannin looks for PRs your review is asked on, your own PRs' checks and reviews, and reviewed PRs you're watching, as often as Settings › Sync says. A new request notifies, with Review with Claude to start a review when you choose.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Review requests automatically", isOn: $autoReview)
            Text("A new review request starts Claude's review in the background, in the PR's harness, two at a time. Each org can say otherwise in its Settings, under Harness.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Watch reviewed pull requests", isOn: $watchesReviews)
            Text("Once a review finishes, new commits or comments on its PR start another, after a couple of quiet minutes, until it's merged or closed. Each review can turn it off. The Inbox lists what happened while you were away.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Post automatic reviews to GitHub", isOn: $postsReviews)
            Text("Reviews Gannin starts by itself are posted as comments. They never approve or request changes. Off, they wait for you to Post Review.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Record reviews in the harness", isOn: $recordsReviews)
            Text("A review's findings, what you made of them and whether their threads were resolved, committed to its harness when it's posted, finished, or its PR merges or closes. Agents › Metrics reads them, for everyone in the team.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Send new PR feedback to Claude", isOn: $sendsFeedback)
            Text("When checks fail or a reviewer says something new on a session's PR, it's pasted into the session for Claude to address: now if it's waiting for you, else when it finishes its turn. Each session can say otherwise in its PRs pane.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Review a session's work with a second agent", isOn: $pairReview)
            Text("When a session's claude says its change is ready, another agent that can't edit reviews it and its findings go back to claude, round after round, until there's nothing more, \(PairReview.maxRounds) rounds have gone, or you stop it. Each session can say otherwise in its Activity pane.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Ask to wrap up when closing a session's tab", isOn: $wrapsUp)
            Text("Closing the tab of an issue's session while claude runs shows its pull requests, what isn't pushed and its plans and requirements to tick off, then leaves it running, ends it or, once every PR is merged, finishes it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show in the menu bar", isOn: $showsMenuBar)
            Toggle("Notify when a session needs you", isOn: $notifies)
            Text("When claude asks something or finishes its turn and you aren't looking at its tab. Its tab is marked and the Dock icon counts them either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Agent")
        } footer: {
            Text("Claude runs through the claude CLI installed and signed in here (or on the server below), as you, on your own seat, and only when you ask. Gannin never handles your Claude login. Use a work seat for work data, and don't share a login between people.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Workspace") {
                HStack {
                    Text(workspace)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose", action: choose)
                }
            }
            Text("Sessions run in the org's harness, with each issue's code in a git worktree under its .worktrees folder. When the harness isn't checked out on this Mac, Work on This clones it here. Clones use gh if it's installed, else git with your credentials, and claude runs signed in as you.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Connect with", text: $connect, prompt: Text("ssh -t devbox"))
            Text("To run sessions on a server, the command that reaches it, with {command} where the rest goes (else it goes at the end). Empty runs them on this Mac. Set where each org's harness is checked out there in the org's Settings. Sessions stay where they were made.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Claude Code")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = SessionStore.workspaceRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace = SessionStore.tildePath(url)
    }
}

/// The org's Settings › Harness, on the Mac: where its harness is checked out
/// here and on the server, for sessions to run in.
struct HarnessCheckoutSection: View {
    @AppStorage(SessionStore.connectKey) private var connect = ""
    @AppStorage private var localPath: String
    @AppStorage private var remotePath: String
    @AppStorage private var recordWithoutAsking: Bool
    /// `on`, `off`, or empty for Settings > General's.
    @AppStorage private var autoReview: String
    let org: String
    let repo: String
    /// Says which harness, when there are several.
    var showsName = false
    /// Recording is the org's, so it's asked once, with the primary.
    var showsRecording = true

    init(org: String, repo: String, showsName: Bool = false, showsRecording: Bool = true) {
        self.org = org
        self.repo = repo
        self.showsName = showsName
        self.showsRecording = showsRecording
        _localPath = AppStorage(wrappedValue: "", SessionStore.harnessPathKey(org, repo: repo))
        _remotePath = AppStorage(wrappedValue: "", SessionStore.remoteHarnessPathKey(org, repo: repo))
        _recordWithoutAsking = AppStorage(wrappedValue: false, SessionStore.asksBeforeRecordingKey(org))
        _autoReview = AppStorage(wrappedValue: "", AutoReview.orgKey(org))
    }

    var body: some View {
        let found = SessionStore.existingCheckout(of: repo)
        let local = localPath.isEmpty ? SessionStore.localHarnessPath(org: org, repo: repo) : localPath
        let exists = FileManager.default.fileExists(atPath: SessionStore.expanded(local).appending(path: ".git").path)
        Section {
            LabeledContent("On this Mac") {
                HStack {
                    Text(local)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(local)
                    Button("Choose", action: choose)
                    if !localPath.isEmpty {
                        Button("Default") { localPath = "" }
                            .help(found.map { "Use the checkout found at \($0)" } ?? "Clone it into the workspace, set in Settings")
                    }
                }
            }
            Text(exists
                 ? "Claude Code sessions for this org run here: each issue's code is a git worktree under .worktrees, beside the shared clones in projects."
                 : "Not checked out here yet. The first session clones \(repo) here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !connect.trimmingCharacters(in: .whitespaces).isEmpty {
                TextField("On the server", text: $remotePath, prompt: Text("~/\(org)-harness"))
                Text("Sessions run on the server Settings connects to (\(connect)). Where the harness is checked out there, as a path on that box; the first session clones it if it isn't there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showsRecording {
                Toggle("Ask before recording a session", isOn: Binding(get: { !recordWithoutAsking }, set: { recordWithoutAsking = !$0 }))
                Text("Work on This commits the session's brief and a session.json to its harness's sessions folder, and adds its pull request later. Off, it does so without asking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Review requests automatically", selection: $autoReview) {
                    Text("As in Settings (\(AutoReview.isOnByDefault ? "on" : "off"))").tag("")
                    Text("On").tag("on")
                    Text("Off").tag("off")
                }
                Text("Your own choice for this org, on this Mac: whether a review request here starts Claude's review by itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(showsName ? "Claude Code in \(repo.split(separator: "/").last ?? "")" : "Claude Code")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose \(repo)'s checkout, or the folder to clone it into"
        panel.directoryURL = SessionStore.expanded(SessionStore.localHarnessPath(org: org, repo: repo)).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        localPath = SessionStore.tildePath(url)
    }
}
