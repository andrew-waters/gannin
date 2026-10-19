import Foundation
import Testing
@testable import GanninRemote

private let permission = RemotePrompt.permission(
    id: "tool-1", tool: "Bash", command: "git push origin HEAD", commandTruncated: false,
    choices: [RemoteChoice(number: 1, label: "Yes"), RemoteChoice(number: 2, label: "No")]
)

private let session = RemoteSession(
    id: "A", reference: "acme/app#12", title: "Fix login", kind: "Code", state: .needsYou,
    mode: .attended, modeLabel: "Attended", canGoUnattended: true, prompt: permission, lastMessage: "Pushing"
)

private func roundTrip<M: Codable & Equatable>(_ message: M) throws -> M {
    var decoder = FrameDecoder()
    decoder.append(try FrameCodec.encode(message))
    let payload = try #require(try decoder.next())
    return try FrameCodec.decode(payload, as: M.self)
}

@Test func clientMessagesRoundTrip() throws {
    let messages: [ClientMessage] = [
        .hello(name: "Alex's iPhone"),
        .subscribe,
        .intent(id: "1", session: "A", promptID: "tool-1", intent: .choose(number: 2)),
        .intent(id: "2", session: "A", promptID: "q-1", intent: .answer(answers: [RemoteAnswer(question: "Which?", answer: "Option A")])),
        .intent(id: "3", session: "A", promptID: "tool-1", intent: .deny),
        .intent(id: "4", session: "A", promptID: nil, intent: .prompt(text: "run the tests")),
        .intent(id: "5", session: "A", promptID: nil, intent: .interrupt),
        .intent(id: "6", session: "A", promptID: nil, intent: .setMode(mode: .unattended)),
    ]
    for message in messages { #expect(try roundTrip(message) == message) }
}

@Test func serverMessagesRoundTrip() throws {
    let question = RemotePrompt.question(
        id: "q-1",
        items: [RemoteQuestionItem(header: "Plan", question: "Which?", options: [RemoteOption(label: "A", description: "first")], multiSelect: false)]
    )
    var asking = session
    asking.prompt = question
    let messages: [ServerMessage] = [
        .hello(macName: "Studio"),
        .snapshot(sessions: [session, asking]),
        .sessionChanged(session: session),
        .sessionRemoved(id: "A"),
        .result(id: "1", result: .ok),
        .result(id: "2", result: .refused(reason: .promptGone)),
        .heartbeat,
    ]
    for message in messages { #expect(try roundTrip(message) == message) }
}

@Test func framesSplitAcrossReadsAreReassembled() throws {
    let data = try FrameCodec.encode(ServerMessage.heartbeat) + FrameCodec.encode(ServerMessage.hello(macName: "Studio"))
    var decoder = FrameDecoder()
    var payloads: [Data] = []
    for byte in data {
        decoder.append(Data([byte]))
        while let payload = try decoder.next() { payloads.append(payload) }
    }
    #expect(payloads.count == 2)
    #expect(try FrameCodec.decode(payloads[1], as: ServerMessage.self) == .hello(macName: "Studio"))
}

@Test func twoFramesInOneReadAreBothReturned() throws {
    var decoder = FrameDecoder()
    decoder.append(try FrameCodec.encode(ClientMessage.subscribe) + FrameCodec.encode(ClientMessage.hello(name: "x")))
    #expect(try decoder.next() != nil)
    #expect(try decoder.next() != nil)
    #expect(try decoder.next() == nil)
}

@Test func hostileLengthIsRefusedBeforeBuffering() {
    var decoder = FrameDecoder()
    decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))
    #expect(throws: FrameError.self) { try decoder.next() }
}

@Test func oversizeMessageIsRefusedOnEncode() {
    var big = session
    big.lastMessage = String(repeating: "x", count: RemoteProtocol.maxFrameBytes)
    #expect(throws: FrameError.self) { try FrameCodec.encode(ServerMessage.sessionChanged(session: big)) }
}

@Test func snapshotsFitTheEncodedBudgetWithLongCommandsAndEscapedUnicode() throws {
    let sessions = (0..<60).map { index in
        var item = session
        item.id = String(index)
        item.title = String(repeating: "😀", count: 200)
        item.lastMessage = String(repeating: "\"\n", count: 140)
        item.prompt = .permission(id: "tool-\(index)", tool: "Bash", command: String(repeating: "x", count: 4096), commandTruncated: false, choices: [RemoteChoice(number: 1, label: "Yes")])
        return item
    }
    #expect(throws: FrameError.self) { try FrameCodec.encode(ServerMessage.snapshot(sessions: sessions)) }
    let fitted = RemoteSnapshot.fitting(sessions)
    #expect(!fitted.isEmpty)
    #expect(fitted.count < sessions.count)
    #expect(fitted == Array(sessions.prefix(fitted.count)))
    #expect(try FrameCodec.encode(ServerMessage.snapshot(sessions: fitted)).count <= RemoteProtocol.maxFrameBytes + 4)
    #expect(throws: FrameError.self) { try FrameCodec.encode(ServerMessage.snapshot(sessions: fitted + [sessions[fitted.count]])) }
}

@Test func oversizedQuestionsAndOptionsDoNotPreventOtherSessionsFromBeingSent() throws {
    for oversizedOptions in [false, true] {
        var asking = session
        let huge = String(repeating: "😀\"\n", count: RemoteProtocol.maxFrameBytes)
        asking.prompt = .question(id: "question", items: [RemoteQuestionItem(
            header: "Pick", question: oversizedOptions ? "Which?" : huge,
            options: [RemoteOption(label: "A", description: oversizedOptions ? huge : "first")], multiSelect: false
        )])
        let fitted = RemoteSnapshot.fitting([asking, session])
        #expect(fitted == [session])
        #expect(try roundTrip(ServerMessage.snapshot(sessions: fitted)) == .snapshot(sessions: [session]))
    }
}

@Test func otherVersionIsReportedAsSuch() throws {
    let payload = Data(#"{"v":99,"m":{"somethingNew":{}}}"#.utf8)
    #expect(throws: FrameError.unsupportedVersion(99)) { try FrameCodec.decode(payload, as: ServerMessage.self) }
}

@Test func unknownMessageInThisVersionIsMalformed() {
    let payload = Data(#"{"v":\#(RemoteProtocol.version),"m":{"somethingNew":{}}}"#.utf8)
    #expect(throws: FrameError.malformed) { try FrameCodec.decode(payload, as: ServerMessage.self) }
}

@Test func garbageIsMalformed() {
    #expect(throws: FrameError.malformed) { try FrameCodec.decode(Data("nope".utf8), as: ServerMessage.self) }
}

@Test func intentsAreValidatedWhateverTheSession() {
    #expect(RemoteIntent.prompt(text: "go").invalidReason == nil)
    #expect(RemoteIntent.prompt(text: "  \n").invalidReason == .invalid)
    #expect(RemoteIntent.prompt(text: String(repeating: "a", count: RemoteProtocol.maxPromptBytes + 1)).invalidReason == .tooLarge)
    #expect(RemoteIntent.answer(answers: []).invalidReason == .invalid)
    #expect(RemoteIntent.choose(number: 0).invalidReason == .invalid)
    #expect(RemoteIntent.setMode(mode: .other).invalidReason == .invalid)
    #expect(RemoteIntent.deny.invalidReason == nil)
}

@Test func onlyDecisionsNeedAPromptID() {
    #expect(RemoteIntent.deny.answersPrompt)
    #expect(RemoteIntent.choose(number: 1).answersPrompt)
    #expect(RemoteIntent.answer(answers: [RemoteAnswer(question: "q", answer: "a")]).answersPrompt)
    #expect(!RemoteIntent.interrupt.answersPrompt)
    #expect(!RemoteIntent.prompt(text: "x").answersPrompt)
    #expect(!RemoteIntent.setMode(mode: .attended).answersPrompt)
}

@Test func commandsAreCutAtACharacterBoundary() {
    #expect(RemotePrompt.truncated("ls") == ("ls", false))
    // Each "é" is two bytes, so an odd limit would split one if cut by bytes.
    let long = String(repeating: "é", count: RemoteProtocol.maxCommandBytes)
    let cut = RemotePrompt.truncated(long)
    #expect(cut.wasCut)
    #expect(cut.text.utf8.count <= RemoteProtocol.maxCommandBytes)
    #expect(cut.text.allSatisfy { $0 == "é" })
}

@Test func promptIDIsTheCaseID() {
    #expect(permission.id == "tool-1")
    #expect(RemotePrompt.question(id: "q", items: []).id == "q")
}

@Test func diffNamesChangedAndRemovedSessions() {
    var changed = session
    changed.state = .working
    changed.prompt = nil
    var other = session
    other.id = "B"
    let diff = RemoteSessionDiff.between(old: [session, other], new: [changed])
    #expect(diff.changed == [changed])
    #expect(diff.removed == ["B"])
    #expect(RemoteSessionDiff.between(old: [session], new: [session]).changed.isEmpty)
}

@Test func newSessionsAreChanged() {
    #expect(RemoteSessionDiff.between(old: [], new: [session]).changed == [session])
}

@Test func rateLimiterAllowsALimitPerWindow() {
    var limiter = IntentRateLimiter(limit: 2, window: 10)
    let start = Date(timeIntervalSince1970: 1_000)
    // #expect can't call a mutating method as its whole expression, so each result is bound first.
    let first = limiter.allow(at: start)
    let second = limiter.allow(at: start.addingTimeInterval(1))
    let third = limiter.allow(at: start.addingTimeInterval(2))
    let afterWindow = limiter.allow(at: start.addingTimeInterval(10.5))
    #expect(first)
    #expect(second)
    #expect(!third)
    #expect(afterWindow)
}

@Test func refusalsRoundTrip() throws {
    for reason in [RemoteRefusal.busy, .modeNotChanged, .promptGone] {
        #expect(try roundTrip(RemoteResult.refused(reason: reason)) == .refused(reason: reason))
    }
}
