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

    /// A text field in a grouped Form with its label beside it and the text starting right
    /// after the label. A labelled field's text is otherwise right-aligned, and right-aligned
    /// text lets a typed trailing space hang past the edge, so it doesn't show; no alignment
    /// modifier changes that in a Form. The field's own title stays as its VoiceOver label.
    func leadingTextBox(_ title: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .accessibilityHidden(true)
            labelsHidden()
                .multilineTextAlignment(.leading)
        }
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
