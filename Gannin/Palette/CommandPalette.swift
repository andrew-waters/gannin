import SwiftUI
import AppKit
import SwiftTerm

// The command palette (View › Command Palette, ⌘K): a panel over any
// window that finds anything Gannin has cached, across every org, and runs
// actions. A main window opens results itself; the issue, PR and Claude Code
// windows hand them to the main window used last (`PaletteRouter`).

// MARK: - Opening it

/// Opens the palette in the focused window. Compared by window, so focus
/// changes (not every redraw) update the menu.
struct CommandPaletteAction: Equatable {
    let window: UUID
    let perform: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.window == rhs.window }
}

extension FocusedValues {
    @Entry var commandPalette: CommandPaletteAction?
}

/// View › Command Palette. In the Claude Code window a focused terminal
/// keeps ⌘K: the key goes on to it, as it would with no menu item.
struct CommandPaletteCommand: View {
    @FocusedValue(\.commandPalette) private var palette

    var body: some View {
        Button("Command Palette") {
            if let event = NSApp.currentEvent, event.type == .keyDown,
               let terminal = NSApp.keyWindow?.firstResponder as? TerminalView {
                terminal.keyDown(with: event)
                return
            }
            palette?.perform()
        }
        .keyboardShortcut("k")
        .disabled(palette == nil)
    }
}

// MARK: - Main windows

/// Every main window, so the palette in another window can open results
/// in the one used last, as Mail's viewer windows are.
enum PaletteRouter {
    struct MainWindow {
        let org: () -> String?
        let open: (PaletteDestination, PalettePlacement) -> Void
        weak var window: NSWindow?
    }

    @MainActor private static var windows: [UUID: MainWindow] = [:]
    /// Most recently key first.
    @MainActor private static var order: [UUID] = []

    @MainActor static func register(_ id: UUID, _ window: MainWindow) {
        windows[id] = window
        if !order.contains(id) { order.append(id) }
    }

    @MainActor static func unregister(_ id: UUID) {
        windows[id] = nil
        order.removeAll { $0 == id }
    }

    @MainActor static func activate(_ id: UUID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// The main window used last that's still open.
    @MainActor static var mostRecent: MainWindow? {
        order.lazy.compactMap { windows[$0] }.first { $0.window != nil }
    }
}

// MARK: - Hosting it

extension View {
    /// The palette over this window, opened with ⌘K. `homeOrg` is the org
    /// results are opened in without asking, read as it opens; `open` opens
    /// a result.
    func commandPalette(homeOrg: @escaping () -> String?, open: @escaping (PaletteDestination, PalettePlacement) -> Void) -> some View {
        modifier(CommandPaletteHost(homeOrg: homeOrg, open: open))
    }

    /// The palette in a window that isn't a main window: results go to the
    /// main window used last, brought to the front, else a new one.
    func commandPaletteOpeningInMainWindow() -> some View {
        modifier(RoutedCommandPalette())
    }
}

private struct RoutedCommandPalette: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.commandPalette(homeOrg: { PaletteRouter.mostRecent?.org() }) { destination, placement in
            if let main = PaletteRouter.mostRecent {
                main.window?.makeKeyAndOrderFront(nil)
                main.open(destination, placement)
            } else {
                let request = NavigationRequest(org: destination.org, sidebar: destination.target.rootSidebar, path: [], palette: destination)
                WindowRequest.open(request, placement: .window, openWindow: openWindow)
            }
        }
    }
}

/// Weakly holds what had focus before the palette opened, to give it back.
private final class ResponderBox {
    weak var responder: NSResponder?
}

private struct CommandPaletteHost: ViewModifier {
    let homeOrg: () -> String?
    let open: (PaletteDestination, PalettePlacement) -> Void

    @State private var isPresented = false
    @State private var id = UUID()
    @State private var previous = ResponderBox()

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.08)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: close)
                            .accessibilityHidden(true)
                        CommandPalette(homeOrg: homeOrg(), open: open, dismiss: close)
                            .padding(.top, 72)
                            .padding(.horizontal, 16)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.15), value: isPresented)
            .focusedSceneValue(\.commandPalette, CommandPaletteAction(window: id) {
                if isPresented {
                    close()
                } else {
                    previous.responder = NSApp.keyWindow?.firstResponder
                    isPresented = true
                }
            })
    }

    /// Closes it, focus going back where it was.
    private func close() {
        isPresented = false
        let responder = previous.responder
        DispatchQueue.main.async {
            if let responder, let window = (responder as? NSView)?.window ?? NSApp.keyWindow {
                window.makeFirstResponder(responder)
            }
        }
    }
}

// MARK: - The palette

struct CommandPalette: View {
    @Environment(OrgStore.self) private var orgs
    @Environment(IssueStore.self) private var issues
    @Environment(ProjectStore.self) private var projects
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(SessionStore.self) private var sessions
    @Environment(MetricsStore.self) private var metricsStore
    @Environment(WorkLogStore.self) private var workLog
    @Environment(ActionsStore.self) private var actions
    @Environment(\.openWindow) private var openWindow
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays

    let homeOrg: String?
    let open: (PaletteDestination, PalettePlacement) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var items: [PaletteItem] = []
    @State private var byID: [String: PaletteItem] = [:]
    @State private var unloaded: [Organisation] = []
    @State private var isLoading = true
    @State private var descriptionHits: [PaletteItem] = []
    @State private var highlighted: PaletteRowID?
    /// A result in another org, waiting for how to open it.
    @State private var confirming: PaletteItem?
    @State private var choice = 0
    @FocusState private var isFocused: Bool

    private static let perGroup = 6

    var body: some View {
        let sections = sections
        let rows = sections.flatMap { section in section.items.map { PaletteRowID(group: section.group, id: $0.id) } }
        VStack(spacing: 0) {
            field(sections: sections, rows: rows)
            Divider()
            if let confirming, case .go(let destination) = confirming.action {
                prompt(confirming, destination)
            } else {
                results(sections)
            }
            footer
        }
        .frame(maxWidth: 640)
        .frame(maxHeight: 460, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.separatorLine))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
        .accessibilityAddTraits(.isModal)
        .background { shortcuts(rows: rows, sections: sections) }
        .onExitCommand(perform: escape)
        .task { await load() }
        .onAppear { isFocused = true }
        .onChange(of: query) {
            confirming = nil
            highlighted = nil
        }
        .task(id: query) { await searchDescriptions() }
        .onChange(of: rows.count) { announce(rows.count) }
    }

    // MARK: Field

    private func field(sections: [PaletteSection], rows: [PaletteRowID]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search Gannin or run an action", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isFocused)
                .accessibilityLabel("Search Gannin")
                .onSubmit { pick(rows: rows, sections: sections, placement: nil) }
                .onKeyPress(.downArrow) { move(1, rows: rows) }
                .onKeyPress(.upArrow) { move(-1, rows: rows) }
                .onKeyPress(.escape) {
                    escape()
                    return .handled
                }
            if isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// ⌘↩ and ⌥↩: a new tab or window, without asking.
    private func shortcuts(rows: [PaletteRowID], sections: [PaletteSection]) -> some View {
        Group {
            Button("Open in New Tab") { pick(rows: rows, sections: sections, placement: .newTab) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Open in New Window") { pick(rows: rows, sections: sections, placement: .newWindow) }
                .keyboardShortcut(.return, modifiers: .option)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Results

    private func results(_ sections: [PaletteSection]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        Text(section.group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.items) { item in
                            let rowID = PaletteRowID(group: section.group, id: item.id)
                            row(item, isHighlighted: rowID == (highlighted ?? firstRow(sections)))
                                .id(rowID)
                                .onTapGesture { perform(item, placement: nil) }
                                .onHover { if $0 { highlighted = rowID } }
                        }
                    }
                    if sections.isEmpty && !isLoading {
                        empty
                    }
                }
                .padding(.bottom, 6)
            }
            .onChange(of: highlighted) { _, row in
                if let row { proxy.scrollTo(row) }
            }
        }
    }

    private func row(_ item: PaletteItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .frame(width: 18)
                .foregroundStyle(isHighlighted ? Color.white : item.isOpen ? Color.accentColor : Color.secondary)
            Text(item.title)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = item.detail {
                Text(detail)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer(minLength: 8)
            Text(label(for: item))
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .background(isHighlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: item))
        .accessibilityAddTraits(isHighlighted ? AccessibilityTraits([.isButton, .isSelected]) : AccessibilityTraits.isButton)
        .accessibilityAction { perform(item, placement: nil) }
    }

    /// What it is, and its org when there's more than one.
    private func label(for item: PaletteItem) -> String {
        guard let org = item.org, orgs.orgs.count > 1 else { return item.noun }
        return "\(item.noun) · \(orgName(org))"
    }

    private func accessibilityLabel(for item: PaletteItem) -> String {
        var parts = [item.noun, item.title]
        if let detail = item.detail { parts.append(detail) }
        if let org = item.org, orgs.orgs.count > 1 { parts.append("in \(orgName(org))") }
        if !item.isOpen { parts.append("closed") }
        return parts.joined(separator: ", ")
    }

    private var empty: some View {
        VStack(spacing: 4) {
            Text("No results for “\(query.trimmingCharacters(in: .whitespaces))”")
                .font(.headline)
            Text("Try fewer words, a number like #123, or an action such as New Issue.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }

    /// Orgs with nothing cached aren't searched; the palette never fetches.
    @ViewBuilder
    private var footer: some View {
        if !unloaded.isEmpty {
            Divider()
            Text("Nothing loaded yet for \(unloaded.map(\.displayName).formatted()). Open \(unloaded.count == 1 ? "it" : "them") to search \(unloaded.count == 1 ? "it" : "them") here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    // MARK: Another org

    private static let promptChoices: [(title: String, placement: PalettePlacement)] = [
        ("Switch This Window", .thisWindow),
        ("Open in New Tab", .newTab),
        ("Open in New Window", .newWindow),
    ]

    /// How to open a result from another org, asked each time: arrows move,
    /// Return picks, Esc goes back to the results.
    private func prompt(_ item: PaletteItem, _ destination: PaletteDestination) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("“\(item.title)” is in \(orgName(destination.org)). Open it:")
                .font(.callout)
                .lineLimit(2)
            ForEach(Array(Self.promptChoices.enumerated()), id: \.offset) { index, entry in
                let title = index == 0 ? "Switch This Window to \(orgName(destination.org))" : entry.title
                Text(title)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(index == choice ? Color.white : Color.primary)
                    .background(index == choice ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { finish(item, destination, placement: entry.placement) }
                    .onHover { if $0 { choice = index } }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(index == choice ? AccessibilityTraits([.isButton, .isSelected]) : AccessibilityTraits.isButton)
                    .accessibilityAction { finish(item, destination, placement: entry.placement) }
            }
            Text("Esc to go back")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    // MARK: Keys

    private func move(_ step: Int, rows: [PaletteRowID]) -> KeyPress.Result {
        if confirming != nil {
            choice = min(max(choice + step, 0), Self.promptChoices.count - 1)
            return .handled
        }
        guard !rows.isEmpty else { return .handled }
        let current = rows.firstIndex(of: highlighted ?? rows[0]) ?? 0
        highlighted = rows[min(max(current + step, 0), rows.count - 1)]
        return .handled
    }

    private func escape() {
        if confirming != nil {
            confirming = nil
        } else {
            dismiss()
        }
    }

    /// Return on the prompt or the highlighted row; with a placement, ⌘↩ or ⌥↩.
    private func pick(rows: [PaletteRowID], sections: [PaletteSection], placement: PalettePlacement?) {
        if let confirming, case .go(let destination) = confirming.action {
            finish(confirming, destination, placement: placement ?? Self.promptChoices[choice].placement)
            return
        }
        guard let row = highlighted ?? rows.first,
              let item = sections.first(where: { $0.group == row.group })?.items.first(where: { $0.id == row.id }) else { return }
        perform(item, placement: placement)
    }

    // MARK: Acting

    /// Runs an action or opens a result: here when it's in the window's
    /// org (or has none), else as `placement` says, else asking how.
    private func perform(_ item: PaletteItem, placement: PalettePlacement?) {
        switch item.action {
        case .run(let command):
            PaletteRecents.add(item.id)
            dismiss()
            run(command)
        case .go(let destination):
            if let placement {
                finish(item, destination, placement: placement)
            } else if let homeOrg, destination.org != homeOrg, !isAction(item) {
                choice = 0
                confirming = item
                announce("\(item.title) is in \(orgName(destination.org)). Switch this window, open in a new tab, or open in a new window.")
            } else {
                finish(item, destination, placement: .thisWindow)
            }
        }
    }

    /// Actions in another org (New Issue, a project) switch the window to it.
    private func isAction(_ item: PaletteItem) -> Bool { item.group == .actions || item.id.hasPrefix("action:") }

    private func finish(_ item: PaletteItem, _ destination: PaletteDestination, placement: PalettePlacement) {
        PaletteRecents.add(item.id)
        dismiss()
        open(destination, placement)
    }

    private func run(_ command: PaletteCommand) {
        switch command {
        case .refresh(let org, let full):
            OrgRefresh(
                orgs: orgs, metricsStore: metricsStore, workLog: workLog, issueStore: issues,
                actions: actions, projects: projects, configs: configs.root, harness: harness, windowDays: windowDays
            )(org, mode: full ? .full : .manual)
        case .newWindow:
            openWindow(id: "main")
        case .newTab:
            TabRequest.parent = PaletteRouter.mostRecent?.window ?? NSApp.keyWindow
            openWindow(id: "main")
        case .openClaudeCode:
            openWindow(id: SessionStore.windowID)
        case .nextSessionWaiting:
            if let next = sessions.nextWaiting { sessions.show(next, with: openWindow) }
        case .toggle(let key):
            UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        case .session(let id):
            sessions.show(id, with: openWindow)
        }
    }

    // MARK: Results

    /// Typed: every group's best matches, up to six each, then those found
    /// in descriptions. Empty: recent results, then suggested actions.
    private var sections: [PaletteSection] {
        let query = PaletteQuery(query)
        if query.isEmpty {
            var result: [PaletteSection] = []
            let recent = PaletteRecents.items(from: byID, homeOrg: homeOrg)
            if !recent.isEmpty { result.append(PaletteSection(group: .recent, items: recent)) }
            if !suggested.isEmpty { result.append(PaletteSection(group: .actions, items: suggested)) }
            return result
        }
        let ranked = items.ranked(query, homeOrg: homeOrg)
        var result = PaletteGroup.allCases.compactMap { group -> PaletteSection? in
            let found = ranked.filter { $0.group == group }.prefix(Self.perGroup)
            return found.isEmpty ? nil : PaletteSection(group: group, items: Array(found))
        }
        if !descriptionHits.isEmpty {
            result.append(PaletteSection(group: .descriptions, items: Array(descriptionHits.prefix(Self.perGroup))))
        }
        return result
    }

    /// Before anything's typed: New Issue and Refresh for the window's org,
    /// then the session waiting longest and Claude Code.
    private var suggested: [PaletteItem] {
        var ids = ["action:next-waiting", "action:claude-code", "action:new-tab"]
        if let homeOrg { ids = ["action:\(homeOrg):new-issue", "action:\(homeOrg):refresh"] + ids }
        return ids.compactMap { byID[$0] }
    }

    private func firstRow(_ sections: [PaletteSection]) -> PaletteRowID? {
        sections.first.flatMap { section in section.items.first.map { PaletteRowID(group: section.group, id: $0.id) } }
    }

    // MARK: Loading

    private var sources: PaletteSources {
        PaletteSources(orgs: orgs, issues: issues, projects: projects, harness: harness, configs: configs.root, sessions: sessions)
    }

    /// Every org's caches from disk, after the panel's first frame, then
    /// the items from them.
    private func load() async {
        await Task.yield()
        let sources = sources
        sources.loadCaches()
        let built = sources.items()
        items = built
        byID = Dictionary(built.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        unloaded = sources.unloadedOrgs
        isLoading = false
    }

    /// Matches inside descriptions and comments, a moment after typing stops.
    private func searchDescriptions() async {
        descriptionHits = []
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3 else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let listed = Set(items.ranked(PaletteQuery(text), homeOrg: homeOrg).filter { $0.group == .issues }.prefix(Self.perGroup).map(\.id))
        // The window's org first.
        let logins = orgs.orgs.map(\.login)
        let orgLogins = logins.filter { $0 == homeOrg } + logins.filter { $0 != homeOrg }
        let hits = await PaletteSources.descriptionItems(text, orgs: orgLogins, issues: issues, excluding: listed)
        guard !Task.isCancelled else { return }
        descriptionHits = hits
    }

    // MARK: Accessibility

    @State private var announcement: Task<Void, Never>?

    /// The number of results, once typing settles.
    private func announce(_ count: Int) {
        guard !query.isEmpty else { return }
        announce(count == 0 ? "No results" : count == 1 ? "1 result" : "\(count) results", delay: .milliseconds(600))
    }

    private func announce(_ message: String, delay: Duration = .zero) {
        announcement?.cancel()
        announcement = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private func orgName(_ login: String) -> String {
        orgs.org(login: login)?.displayName ?? login
    }
}

/// A group of results under its heading.
private struct PaletteSection: Identifiable {
    let group: PaletteGroup
    let items: [PaletteItem]

    var id: PaletteGroup { group }
}

/// A row, by its group as well, since a recent item is also listed below.
private struct PaletteRowID: Hashable {
    let group: PaletteGroup
    let id: String
}
