import Foundation
import Observation
import SwiftUI

/// Items the user has chosen to hide, kept locally. Keys are GraphQL node
/// IDs for issues and PRs, and `person:<login>` for people.
@Observable
final class HiddenStore {
    private(set) var keys: Set<String>
    @ObservationIgnored private let database: UserDatabase

    /// In memory, written through to the synced `UserDatabase`.
    init(database: UserDatabase) {
        self.database = database
        keys = database.loadHidden()
        database.onRemoteChange { [weak self] in
            guard let self else { return }
            let loaded = database.loadHidden()
            if loaded != keys { keys = loaded }
        }
    }

    static func personKey(_ login: String) -> String { "person:\(login)" }

    func isHidden(_ key: String) -> Bool { keys.contains(key) }

    func toggle(_ key: String) {
        let hide = !keys.contains(key)
        if hide { keys.insert(key) } else { keys.remove(key) }
        database.setHidden(key, hide)
    }

    func clear() {
        keys = []
        database.deleteAllHidden()
    }
}

/// Adds Open in New Tab and Window, Hide/Unhide and Open on GitHub to a
/// row's context menu, and dims the row when it is hidden (only visible
/// while "Show hidden" is on).
struct HideableRow: ViewModifier {
    @Environment(HiddenStore.self) private var hidden
    @Environment(\.openURL) private var openURL
    let key: String
    let url: URL?
    /// The page the row opens, for Open in New Tab and Window.
    var opens: DetailSelection?
    /// More context menu items, between Hide and Open on GitHub.
    var extra: AnyView?

    func body(content: Content) -> some View {
        let isHidden = hidden.isHidden(key)
        content
            .opacity(isHidden ? 0.45 : 1)
            .overlay(alignment: .topTrailing) {
                if isHidden {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Hidden")
                }
            }
            .contextMenu {
                if let opens { OpenElsewhereItems(opens) }
                Button(isHidden ? "Unhide" : "Hide") { hidden.toggle(key) }
                if let extra { extra }
                if let url {
                    Button("Open on GitHub") { openURL(url) }
                }
            }
    }
}

extension View {
    func hideable(_ key: String, url: URL? = nil, opens: DetailSelection? = nil) -> some View {
        modifier(HideableRow(key: key, url: url, opens: opens))
    }

    func hideable<Menu: View>(_ key: String, url: URL? = nil, opens: DetailSelection? = nil, @ViewBuilder menu: () -> Menu) -> some View {
        modifier(HideableRow(key: key, url: url, opens: opens, extra: AnyView(menu())))
    }
}
