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
