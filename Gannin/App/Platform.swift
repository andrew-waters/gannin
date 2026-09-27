import SwiftUI

// The few Mac-only SwiftUI styles and modifiers the app uses, with their
// nearest iPad equivalent, so views read the same on both.

extension View {
    /// A checkbox on the Mac; a toggle button on iPad.
    func checkboxToggle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(.button)
        #endif
    }

    /// A text link on the Mac; a borderless button on iPad.
    func linkButton() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }

    /// Esc: the exit command on the Mac, the key on an iPad keyboard.
    func onEscape(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        onKeyPress(.escape) {
            action()
            return .handled
        }
        #endif
    }

    /// The window's subtitle, which only the Mac has.
    func windowSubtitle(_ subtitle: String) -> some View {
        #if os(macOS)
        navigationSubtitle(subtitle)
        #else
        self
        #endif
    }
}

extension Color {
    /// The system separator line colour.
    static var separatorLine: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }

    /// The window's background.
    static var windowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
