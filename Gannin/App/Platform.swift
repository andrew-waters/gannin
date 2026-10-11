import AppKit
import SwiftUI

// Names for the few SwiftUI styles and modifiers the app uses throughout.

extension View {
    /// A checkbox.
    func checkboxToggle() -> some View {
        toggleStyle(.checkbox)
    }

    /// A text link.
    func linkButton() -> some View {
        buttonStyle(.link)
    }

    /// Esc, the exit command.
    func onEscape(_ action: @escaping () -> Void) -> some View {
        onExitCommand(perform: action)
    }

    /// The window's subtitle.
    func windowSubtitle(_ subtitle: String) -> some View {
        navigationSubtitle(subtitle)
    }
}

extension Color {
    /// The system separator line colour.
    static var separatorLine: Color {
        Color(nsColor: .separatorColor)
    }

    /// The window's background.
    static var windowBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}

extension View {
    /// Text alone in a toolbar item: the Mac gives it a capsule of its own
    /// with no inset, so it needs room.
    func toolbarTextPadding() -> some View {
        padding(.horizontal, 10)
    }
}

/// Runs `refresh` now, then after each `interval` while Gannin is the active
/// app. A tick that falls while it's in the background waits for it to become
/// active again and refreshes then. Throws when the calling task is cancelled.
func refreshWhileActive(every interval: Duration, _ refresh: () async -> Void) async throws {
    await refresh()
    while true {
        try await Task.sleep(for: interval)
        if !NSApp.isActive {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) { break }
            try Task.checkCancellation()
        }
        await refresh()
    }
}
