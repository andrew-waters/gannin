import Foundation
import GanninRemote

/// What a phone's intents need from the Mac's sessions. `SessionStore` is the one
/// implementation; tests use a fake, so the rules in `RemoteIntentHandler` are
/// checked without a terminal.
@MainActor
protocol RemoteSessionControl: AnyObject {
    func remoteExists(_ id: UUID) -> Bool
    /// Claude itself is running, not only the shell it leaves behind.
    func remoteIsRunning(_ id: UUID) -> Bool
    /// What the session is waiting on, as the phone is shown it.
    func remotePrompt(for id: UUID) -> RemotePrompt?
    func remoteCanGoUnattended(_ id: UUID) -> Bool
    func remoteAnswer(_ answers: [(question: String, answer: String)], to id: UUID)
    func remoteChoose(_ number: Int, for id: UUID)
    func remoteDeny(_ id: UUID)
    func remoteSubmit(_ text: String, to id: UUID) -> Bool
    func remoteInterrupt(_ id: UUID)
    /// True once claude is in `mode`.
    func remoteSetMode(_ id: UUID, to mode: ClaudeMode) async -> Bool
}

extension SessionStore: RemoteSessionControl {
    func remoteExists(_ id: UUID) -> Bool { sessions[id] != nil }

    func remoteIsRunning(_ id: UUID) -> Bool { isClaudeRunning(id) }

    func remoteCanGoUnattended(_ id: UUID) -> Bool { !autoUnavailable(id) }

    /// A question names itself. A permission prompt is named by the tool it asks to run;
    /// one with no tool in the transcript (a dialog) is named by when it was flagged,
    /// which is only as exact as that, so its decisions are also checked against the
    /// choices on the terminal's screen.
    func remotePrompt(for id: UUID) -> RemotePrompt? {
        if let question = transcripts[id]?.question {
            let items = question.items.map { item in
                RemoteQuestionItem(
                    header: item.header,
                    question: item.question,
                    options: item.options.map { RemoteOption(label: $0.label, description: $0.description) },
                    multiSelect: item.multiSelect
                )
            }
            return .question(id: question.id, items: items)
        }
        guard state(id) == .needsYou else { return nil }
        let tool = transcripts[id]?.pendingTool
        let promptID = tool?.id ?? "needs-you-\(Int(attention[id]?.timeIntervalSince1970 ?? 0))"
        // Approved from the Mac a moment ago; its card is already hidden.
        if optimisticApprovals[id] == promptID { return nil }
        var name = "Permission"
        var command = ""
        if let tool, case .tool(let toolName) = tool.kind {
            name = toolName
            command = tool.text
        }
        let cut = RemotePrompt.truncated(command)
        let choices = permissionChoices(for: id).map { RemoteChoice(number: $0.number, label: $0.label) }
        return .permission(id: promptID, tool: name, command: cut.text, commandTruncated: cut.wasCut, choices: choices)
    }

    func remoteAnswer(_ answers: [(question: String, answer: String)], to id: UUID) {
        answer(answers, to: id)
    }

    func remoteChoose(_ number: Int, for id: UUID) {
        approvePermission(number, for: id)
    }

    /// Esc, as the notification's Deny sends it, hiding the card as an approval does.
    func remoteDeny(_ id: UUID) {
        if let tool = transcripts[id]?.pendingTool { confirmApproval(of: tool.id, for: id) }
        sendKeys("\u{1B}", to: id)
    }

    func remoteSubmit(_ text: String, to id: UUID) -> Bool {
        submit(text, to: id)
    }

    func remoteInterrupt(_ id: UUID) {
        interrupt(id)
    }

    func remoteSetMode(_ id: UUID, to mode: ClaudeMode) async -> Bool {
        await switchMode(id, to: mode)
    }
}
