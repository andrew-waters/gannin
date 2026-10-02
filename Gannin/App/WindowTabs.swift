import SwiftUI
import AppKit

/// File > New Tab: opens another main window as a tab of the current one.
/// SwiftUI can open a window but not tab it, so the new window's
/// `WindowAccessor` finds the window it was asked from and joins it.
enum TabRequest {
    /// The window New Tab was chosen in, until the new window claims it.
    @MainActor static var parent: NSWindow?
}

struct NewTabCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Tab") {
            TabRequest.parent = NSApp.keyWindow
            openWindow(id: "main")
        }
        .keyboardShortcut("t")
    }
}


/// Asks the focused main window to rename itself. Compared by window, so
/// focus changes (not every redraw) update the menu.
struct RenameTabAction: Equatable {
    let window: UUID
    let perform: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.window == rhs.window }
}

extension FocusedValues {
    @Entry var renameTab: RenameTabAction?
}

/// File > Rename Tab: a custom title for the focused window or tab.
struct RenameTabCommand: View {
    @FocusedValue(\.renameTab) private var renameTab

    var body: some View {
        Button("Rename Tab") { renameTab?.perform() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(renameTab == nil)
    }
}

/// Hands the hosting `NSWindow` to `onAttach` once the view is in one.
struct WindowAccessor: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onAttach(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Joins this window to the one New Tab was chosen in, if any.
    func joinsRequestedTab() -> some View {
        background(WindowAccessor { window in
            guard let parent = TabRequest.parent, parent !== window else { return }
            TabRequest.parent = nil
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        })
    }
}

// MARK: - Tab context menu

/// Adds Rename Tab to the menu you get by right-clicking a window tab.
/// AppKit offers no API for that menu, so when any menu starts tracking this
/// looks for the tab menu (it has Move Tab to New Window) and inserts the
/// item, aimed at the window whose tab was clicked. If AppKit ever changes
/// that menu, the item just doesn't appear.
@MainActor
final class TabMenuRename: NSObject {
    static let shared = TabMenuRename()
    private static let tag = 0x7A6E
    /// Rename actions by window, registered by each main window.
    private var actions: [ObjectIdentifier: () -> Void] = [:]
    private var isInstalled = false

    func register(_ window: NSWindow, action: @escaping () -> Void) {
        actions[ObjectIdentifier(window)] = action
    }

    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        // Menus track on the main thread, so the main-actor handler is safe.
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidBeginTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    @objc private func menuDidBeginTracking(_ note: Notification) {
        if let menu = note.object as? NSMenu { extend(menu) }
    }

    private func extend(_ menu: NSMenu) {
        guard let moveIndex = menu.items.firstIndex(where: { $0.action == #selector(NSWindow.moveTabToNewWindow(_:)) }),
              !menu.items.contains(where: { $0.tag == Self.tag }) else { return }
        let window = (menu.items[moveIndex].target as? NSWindow) ?? NSApp.keyWindow
        guard let window, actions[ObjectIdentifier(window)] != nil else { return }
        let item = NSMenuItem(title: "Rename Tab", action: #selector(rename(_:)), keyEquivalent: "")
        item.target = self
        item.tag = Self.tag
        item.representedObject = window
        menu.insertItem(item, at: moveIndex + 1)
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow else { return }
        window.makeKeyAndOrderFront(nil)
        actions[ObjectIdentifier(window)]?()
    }
}
