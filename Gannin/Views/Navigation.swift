import SwiftUI
import AppKit

// Navigation in a main window is a stack: the sidebar picks the root page,
// and each drill-down pushes a page onto `MainView.path`, shown full width
// with breadcrumbs and Back. Any page can instead be opened in a new tab
// or window, carrying the trail that led to it.

/// Pushes a page from the level it's used at. A page already in the trail
/// is gone back to rather than pushed again.
struct NavigateAction {
    let perform: (DetailSelection) -> Void

    func callAsFunction(_ destination: DetailSelection) { perform(destination) }
}

/// Where Open Elsewhere puts a page.
enum OpenPlacement {
    case tab
    case window
}

/// Opens a page, or a sidebar item, in a new tab or window.
struct OpenElsewhereAction {
    let open: (DetailSelection, OpenPlacement) -> Void
    let openSidebar: (SidebarItem, OpenPlacement) -> Void
}

/// Picks a sidebar row in this window, as clicking it does: a page linking
/// to another section (the dashboard to Investments, say).
struct ShowSidebarAction {
    let perform: (SidebarItem) -> Void

    func callAsFunction(_ item: SidebarItem) { perform(item) }
}

extension EnvironmentValues {
    @Entry var showSidebarItem: ShowSidebarAction?
    /// Set on every page of a main window; nil in the PR and issue windows,
    /// which open items in windows of their own instead.
    @Entry var navigate: NavigateAction?
    /// Pushes a page even for a PR or issue, which `navigate` opens in the
    /// drawer: the drawer's own Open as Page.
    @Entry var openAsPage: NavigateAction?
    @Entry var openElsewhere: OpenElsewhereAction?
}

/// What a new main window or tab opens on.
struct NavigationRequest {
    let org: String
    let sidebar: SidebarItem
    let path: [DetailSelection]
    /// The project the window's narrowed to; nil for All.
    var workspace: UUID? = nil
}

/// Hands a request to the main window opened for it. SwiftUI can open a
/// window but not pass it state, so it's claimed on the new window's first
/// appearance (as New Tab's parent is, in `WindowTabs.swift`).
enum WindowRequest {
    @MainActor static var pending: NavigationRequest?

    /// Opens a main window on `request`, as a tab of this one on the Mac
    /// when asked.
    @MainActor static func open(_ request: NavigationRequest, placement: OpenPlacement, openWindow: OpenWindowAction) {
        pending = request
        if placement == .tab { TabRequest.parent = NSApp.keyWindow }
        openWindow(id: "main")
    }
}

/// Open in New Tab and Open in New Window, for a row's context menu. Shows
/// nothing where there's nowhere else to open (outside a main window).
struct OpenElsewhereItems: View {
    @Environment(\.openElsewhere) private var openElsewhere
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    private let open: (OpenElsewhereAction, OpenPlacement) -> Void
    private var destination: DetailSelection?

    init(_ destination: DetailSelection) {
        open = { action, placement in action.open(destination, placement) }
        self.destination = destination
    }

    init(sidebar item: SidebarItem) {
        open = { action, placement in action.openSidebar(item, placement) }
    }

    var body: some View {
        if let openElsewhere, supportsMultipleWindows {
            Button("Open in New Tab") { open(openElsewhere, .tab) }
            Button("Open in New Window") { open(openElsewhere, .window) }
            Divider()
        }
        if let destination {
            ReviewMenuItem(destination: destination)
        }
    }
}

/// Review with Claude (or Open Review) in a PR's right-click menu, wherever
/// the PR is listed.
private struct ReviewMenuItem: View {
    @Environment(OrgStore.self) private var orgs
    let destination: DetailSelection

    var body: some View {
        if let reference {
            ReviewWithClaudeButton(reference: reference)
        }
    }

    /// The PR the row is, from the reference or the open PRs synced.
    private var reference: PullRequestReference? {
        switch destination {
        case .pullRequestReference(let reference):
            return reference
        case .pullRequest(let id):
            for (org, snapshot) in orgs.snapshots {
                if let pr = snapshot.openPullRequests.first(where: { $0.id == id }) ?? snapshot.mergedPullRequests.first(where: { $0.id == id }) {
                    return PullRequestReference(org: org, id: pr.id, number: pr.number, title: pr.title, repo: pr.repo, url: pr.url)
                }
            }
            return nil
        default:
            return nil
        }
    }
}

extension View {
    /// Adds Open in New Tab and Open in New Window as the row's context menu.
    func opensElsewhere(_ destination: DetailSelection) -> some View {
        contextMenu { OpenElsewhereItems(destination) }
    }
}

extension View {
    /// A PR or issue window's title and subtitle; nil leaves the title to
    /// the main window the page is shown in.
    @ViewBuilder
    func ownWindowTitle(_ title: String?, subtitle: String) -> some View {
        if let title {
            navigationTitle(title).windowSubtitle(subtitle)
        } else {
            self
        }
    }
}

/// The investment prompt, for a window of its own; a main window has one.
struct OwnInvestmentPrompt: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.investmentPrompt()
        } else {
            content
        }
    }
}
