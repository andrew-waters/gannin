import SwiftUI
import AppKit

/// What the Question menu offers for the planning question that's up. The
/// card publishes it with `focusedSceneValue`, and each action does what the
/// card's own keys and buttons do.
///
/// Compared by what the menu shows, not by its closures: they read the
/// card's live state when called, so focus changes (not every redraw) update
/// the menu.
struct PlanningQuestionMenu: Equatable {
    struct Option: Equatable {
        let letter: String
        let label: String
        let ticked: Bool
    }

    /// ⌘1…⌘9 answer with the first nine options; a bare letter would be a
    /// menu key equivalent, which the menu takes before a focused text field
    /// sees it.
    static let numberedOptions = 9

    let question: String
    let style: PlanningQuestionStyle
    let options: [Option]
    let multiSelect: Bool
    /// "Next" or "Send" for a question that takes several answers.
    let sendTitle: String
    let canSend: Bool
    let canGoBack: Bool

    let pick: (Int) -> Void
    let move: (Int) -> Void
    let pickHighlighted: () -> Void
    let send: () -> Void
    let back: () -> Void
    let skip: () -> Void

    /// What the menu has for each style. Poll the Room and Conversation have
    /// no keys of their own, so they get only what applies to any question.
    struct Items: Equatable {
        var answers = false
        var movesHighlight = false
        var send = false
    }

    var items: Items {
        switch style {
        case .focus: Items(answers: true, send: multiSelect)
        case .list: Items(movesHighlight: true, send: multiSelect)
        case .thread: Items(send: multiSelect)
        case .poll: Items()
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.question == rhs.question && lhs.style == rhs.style && lhs.options == rhs.options
            && lhs.multiSelect == rhs.multiSelect && lhs.sendTitle == rhs.sendTitle
            && lhs.canSend == rhs.canSend && lhs.canGoBack == rhs.canGoBack
    }
}

extension FocusedValues {
    @Entry var planningQuestion: PlanningQuestionMenu?
}

/// The Question menu: the planning question's actions with their shortcuts,
/// disabled when no question is up. It's declared for every window, as
/// commands can't be conditional, and `QuestionMenuVisibility` hides it
/// outside the Claude Code window.
struct PlanningQuestionCommands: Commands {
    static let title = "Question"

    @FocusedValue(\.planningQuestion) private var menu

    var body: some Commands {
        CommandMenu(Self.title) {
            if let menu {
                let items = menu.items
                if items.answers {
                    ForEach(Array(menu.options.prefix(PlanningQuestionMenu.numberedOptions).enumerated()), id: \.offset) { number, option in
                        answer(menu, number: number, option: option)
                    }
                    Divider()
                }
                if items.movesHighlight {
                    Button("Previous Option") { menu.move(-1) }
                    Button("Next Option") { menu.move(1) }
                    Button(menu.multiSelect ? "Tick Highlighted Option" : "Choose Highlighted Option") { menu.pickHighlighted() }
                    Divider()
                }
                if items.send {
                    Button(menu.sendTitle) { menu.send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!menu.canSend)
                }
                Button("Back") { menu.back() }
                    .disabled(!menu.canGoBack)
                Button("Skip Question") { menu.skip() }
            } else {
                Button("Answer") {}.disabled(true)
                Button("Back") {}.disabled(true)
                Button("Skip Question") {}.disabled(true)
            }
        }
    }

    @ViewBuilder
    private func answer(_ menu: PlanningQuestionMenu, number: Int, option: PlanningQuestionMenu.Option) -> some View {
        let key = KeyEquivalent(Character(String(number + 1)))
        if menu.multiSelect {
            Toggle("\(option.letter): \(option.label)", isOn: Binding(get: { option.ticked }, set: { _ in menu.pick(number) }))
                .keyboardShortcut(key, modifiers: .command)
        } else {
            Button("\(option.letter): \(option.label)") { menu.pick(number) }
                .keyboardShortcut(key, modifiers: .command)
        }
    }
}

// MARK: - Only in the Claude Code window

/// Hides the Question menu unless the key window is one that asked for it.
/// SwiftUI declares a menu for the whole app, so this hides the item in the
/// menu bar from AppKit. If it can't find the item the menu just stays,
/// disabled.
@MainActor
final class QuestionMenuVisibility {
    static let shared = QuestionMenuVisibility()
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var observer: NSObjectProtocol?

    func register(_ window: NSWindow) {
        windows.add(window)
        update()
    }

    func install() {
        guard observer == nil else { return }
        // SwiftUI rebuilds menu items as commands change, so look again after
        // each pass of the event loop; setting a flag that's already right is cheap.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.shared.update() }
        }
    }

    private func update() {
        guard let item = NSApp.mainMenu?.items.first(where: { $0.title == PlanningQuestionCommands.title }) else { return }
        let shown = NSApp.keyWindow.map { windows.contains($0) } ?? false
        if item.isHidden == shown { item.isHidden = !shown }
    }
}

extension View {
    /// Shows the Question menu in this window.
    func showsQuestionMenu() -> some View {
        background(WindowAccessor { QuestionMenuVisibility.shared.register($0) })
    }
}
