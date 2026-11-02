import Testing
@testable import Gannin

struct PlanningQuestionMenuTests {
    private func menu(_ style: PlanningQuestionStyle, multiSelect: Bool = false, ticked: Bool = false) -> PlanningQuestionMenu {
        PlanningQuestionMenu(
            style: style,
            options: [.init(letter: "A", label: "Yes", ticked: ticked), .init(letter: "B", label: "No", ticked: false)],
            multiSelect: multiSelect, sendTitle: "Send", canSend: ticked, canGoBack: false,
            pick: { _ in }, move: { _ in }, pickHighlighted: {}, send: {}, back: {}, skip: {}
        )
    }

    @Test func oneAtATimeAnswersByNumber() {
        #expect(menu(.focus).items == .init(answers: true))
    }

    @Test func keyboardListMovesTheHighlight() {
        #expect(menu(.list).items == .init(movesHighlight: true))
    }

    @Test func pollAndConversationHaveNoOptionItems() {
        #expect(menu(.poll).items == .init())
        #expect(menu(.thread).items == .init())
    }

    @Test func sendOnlyWhenTheQuestionTakesSeveralAnswers() {
        #expect(menu(.focus, multiSelect: true).items.send)
        #expect(menu(.thread, multiSelect: true).items.send)
        #expect(!menu(.focus).items.send)
        // Poll has its own Send, with its own ⌘↩.
        #expect(!menu(.poll, multiSelect: true).items.send)
    }
}
