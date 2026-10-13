import Foundation
import GanninRemote
import Testing
@testable import Gannin

@MainActor
final class FakeControl: RemoteSessionControl {
    var exists = true
    var running = true
    var prompt: RemotePrompt?
    var canGoUnattended = true
    var submitWorks = true
    var modeLands = true
    private(set) var calls: [String] = []

    func remoteExists(_ id: UUID) -> Bool { exists }
    func remoteIsRunning(_ id: UUID) -> Bool { running }
    func remotePrompt(for id: UUID) -> RemotePrompt? { prompt }
    func remoteCanGoUnattended(_ id: UUID) -> Bool { canGoUnattended }
    func remoteAnswer(_ answers: [(question: String, answer: String)], to id: UUID) { calls.append("answer:" + answers.map(\.answer).joined(separator: "|")) }
    func remoteChoose(_ number: Int, for id: UUID) { calls.append("choose:\(number)") }
    func remoteDeny(_ id: UUID) { calls.append("deny") }
    func remoteSubmit(_ text: String, to id: UUID) -> Bool {
        calls.append("submit:\(text)")
        return submitWorks
    }
    func remoteInterrupt(_ id: UUID) { calls.append("interrupt") }
    func remoteSetMode(_ id: UUID, to mode: ClaudeMode) async -> Bool {
        calls.append("mode:\(mode.rawValue)")
        return modeLands
    }
}

private let sessionID = UUID().uuidString

private let permission = RemotePrompt.permission(
    id: "tool-1", tool: "Bash", command: "git push", commandTruncated: false,
    choices: [RemoteChoice(number: 1, label: "Yes"), RemoteChoice(number: 2, label: "Yes, and don't ask again"), RemoteChoice(number: 3, label: "No")]
)

private let question = RemotePrompt.question(
    id: "q-1",
    items: [RemoteQuestionItem(header: "Plan", question: "Which?", options: [RemoteOption(label: "A", description: "")], multiSelect: false)]
)

@MainActor
private func run(_ control: FakeControl, _ intent: RemoteIntent, promptID: String? = nil, session: String = sessionID) async -> RemoteResult {
    await RemoteIntentHandler(control: control).handle(session: session, promptID: promptID, intent: intent)
}

@Test @MainActor func choosingNamesThePromptAndSendsTheChoice() async {
    let control = FakeControl()
    control.prompt = permission
    #expect(await run(control, .choose(number: 2), promptID: "tool-1") == .ok)
    #expect(control.calls == ["choose:2"])
}

@Test @MainActor func aDecisionForAPromptThatHasGoneSendsNothing() async {
    let control = FakeControl()
    control.prompt = permission
    #expect(await run(control, .choose(number: 1), promptID: "tool-OLD") == .refused(reason: .promptGone))
    #expect(await run(control, .deny, promptID: nil) == .refused(reason: .promptGone))
    control.prompt = nil
    #expect(await run(control, .choose(number: 1), promptID: "tool-1") == .refused(reason: .promptGone))
    #expect(control.calls.isEmpty)
}

@Test @MainActor func aChoiceNotOnTheScreenIsRefused() async {
    let control = FakeControl()
    control.prompt = permission
    #expect(await run(control, .choose(number: 9), promptID: "tool-1") == .refused(reason: .invalid))
    control.prompt = .permission(id: "tool-1", tool: "Bash", command: "", commandTruncated: false, choices: [])
    #expect(await run(control, .choose(number: 1), promptID: "tool-1") == .refused(reason: .invalid))
    #expect(control.calls.isEmpty)
}

@Test @MainActor func denyNeedsAPermissionPrompt() async {
    let control = FakeControl()
    control.prompt = permission
    #expect(await run(control, .deny, promptID: "tool-1") == .ok)
    control.prompt = question
    #expect(await run(control, .deny, promptID: "q-1") == .refused(reason: .invalid))
    #expect(control.calls == ["deny"])
}

@Test @MainActor func answersMustMatchTheQuestionsAsked() async {
    let control = FakeControl()
    control.prompt = question
    #expect(await run(control, .answer(answers: [RemoteAnswer(question: "Which?", answer: "A")]), promptID: "q-1") == .ok)
    #expect(await run(control, .answer(answers: [RemoteAnswer(question: "Other?", answer: "A")]), promptID: "q-1") == .refused(reason: .invalid))
    #expect(await run(control, .answer(answers: [RemoteAnswer(question: "Which?", answer: "  ")]), promptID: "q-1") == .refused(reason: .invalid))
    #expect(await run(control, .answer(answers: []), promptID: "q-1") == .refused(reason: .invalid))
    #expect(control.calls == ["answer:A"])
}

@Test @MainActor func aPermissionPromptIsNotAnsweredWithAnAnswer() async {
    let control = FakeControl()
    control.prompt = permission
    #expect(await run(control, .answer(answers: [RemoteAnswer(question: "Which?", answer: "A")]), promptID: "tool-1") == .refused(reason: .invalid))
    #expect(control.calls.isEmpty)
}

@Test @MainActor func unknownAndStoppedSessionsAreRefused() async {
    let control = FakeControl()
    #expect(await run(control, .interrupt, session: "not-a-uuid") == .refused(reason: .unknownSession))
    control.exists = false
    #expect(await run(control, .interrupt) == .refused(reason: .unknownSession))
    control.exists = true
    control.running = false
    #expect(await run(control, .interrupt) == .refused(reason: .notRunning))
    #expect(control.calls.isEmpty)
}

@Test @MainActor func promptsAndInterruptsGoThrough() async {
    let control = FakeControl()
    #expect(await run(control, .prompt(text: "run the tests")) == .ok)
    #expect(await run(control, .interrupt) == .ok)
    control.submitWorks = false
    #expect(await run(control, .prompt(text: "again")) == .refused(reason: .notRunning))
    #expect(control.calls == ["submit:run the tests", "interrupt", "submit:again"])
}

@Test @MainActor func invalidIntentsNeverReachTheStore() async {
    let control = FakeControl()
    #expect(await run(control, .prompt(text: " ")) == .refused(reason: .invalid))
    #expect(await run(control, .prompt(text: String(repeating: "a", count: RemoteProtocol.maxPromptBytes + 1))) == .refused(reason: .tooLarge))
    #expect(control.calls.isEmpty)
}

@Test @MainActor func modeSwitchesUseAutoAndDefault() async {
    let control = FakeControl()
    #expect(await run(control, .setMode(mode: .unattended)) == .ok)
    #expect(await run(control, .setMode(mode: .attended)) == .ok)
    #expect(control.calls == ["mode:auto", "mode:default"])
}

@Test @MainActor func modeSwitchesFollowTheMacsRefusals() async {
    let control = FakeControl()
    control.prompt = permission
    #expect(await run(control, .setMode(mode: .unattended)) == .refused(reason: .busy))
    control.prompt = nil
    control.canGoUnattended = false
    #expect(await run(control, .setMode(mode: .unattended)) == .refused(reason: .autoUnavailable))
    #expect(await run(control, .setMode(mode: .attended)) == .ok)
    control.modeLands = false
    #expect(await run(control, .setMode(mode: .attended)) == .refused(reason: .modeNotChanged))
}
