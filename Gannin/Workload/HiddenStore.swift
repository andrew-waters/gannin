import Foundation
import Observation
import SwiftUI

/// Items the user has chosen to hide, kept locally. Keys are GraphQL node
/// IDs for issues and PRs, and `person:<login>` for people.
@Observable
final class HiddenStore {
    private static let key = "hiddenItems"

    private(set) var keys: Set<String>

    init() {
        keys = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    static func personKey(_ login: String) -> String { "person:\(login)" }

    func isHidden(_ key: String) -> Bool { keys.contains(key) }

    func toggle(_ key: String) {
        if keys.contains(key) {
            keys.remove(key)
        } else {
            keys.insert(key)
        }
        UserDefaults.standard.set(keys.sorted(), forKey: Self.key)
    }

    func clear() {
        keys = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

/// Adds Hide/Unhide and Open on GitHub to a row's context menu, and dims the
/// row when it is hidden (only visible while "Show hidden" is on).
struct HideableRow: ViewModifier {
    @Environment(HiddenStore.self) private var hidden
    @Environment(\.openURL) private var openURL
    let key: String
    let url: URL?
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
                Button(isHidden ? "Unhide" : "Hide") { hidden.toggle(key) }
                if let extra { extra }
                if let url {
                    Button("Open on GitHub") { openURL(url) }
                }
            }
    }
}

extension View {
    func hideable(_ key: String, url: URL? = nil) -> some View {
        modifier(HideableRow(key: key, url: url))
    }

    func hideable<Menu: View>(_ key: String, url: URL? = nil, @ViewBuilder menu: () -> Menu) -> some View {
        modifier(HideableRow(key: key, url: url, extra: AnyView(menu())))
    }
}
