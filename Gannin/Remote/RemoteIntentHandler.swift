import Foundation
import GanninRemote

/// Checks a phone's intent against the session as it is now, and only then calls the
/// store. A decision must name the prompt it answers, so one answered on the Mac in the
/// meantime is refused rather than landing on whatever claude asks next.
@MainActor
struct RemoteIntentHandler {
    let control: any RemoteSessionControl

    func handle(session: String, promptID: String?, intent: RemoteIntent) async -> RemoteResult {
        if let reason = intent.invalidReason { return .refused(reason: reason) }
        guard let id = UUID(uuidString: session), control.remoteExists(id) else { return .refused(reason: .unknownSession) }
        guard control.remoteIsRunning(id) else { return .refused(reason: .notRunning) }

        let prompt = control.remotePrompt(for: id)
        if intent.answersPrompt {
            guard let prompt, let promptID, prompt.id == promptID else { return .refused(reason: .promptGone) }
        }

        switch intent {
        case .answer(let answers):
            guard case .question(_, let items) = prompt, answers.count == items.count else { return .refused(reason: .invalid) }
            for (item, answer) in zip(items, answers) {
                guard item.question == answer.question, !answer.answer.allSatisfy(\.isWhitespace) else { return .refused(reason: .invalid) }
            }
            guard answers.reduce(0, { $0 + $1.answer.utf8.count }) <= RemoteProtocol.maxPromptBytes else { return .refused(reason: .tooLarge) }
            control.remoteAnswer(answers.map { (question: $0.question, answer: $0.answer) }, to: id)
        case .choose(let number):
            guard case .permission(_, _, _, _, let choices) = prompt, choices.contains(where: { $0.number == number }) else {
                return .refused(reason: .invalid)
            }
            control.remoteChoose(number, for: id)
        case .deny:
            guard case .permission = prompt else { return .refused(reason: .invalid) }
            control.remoteDeny(id)
        case .prompt(let text):
            guard control.remoteSubmit(text, to: id) else { return .refused(reason: .notRunning) }
        case .interrupt:
            control.remoteInterrupt(id)
        case .setMode(let mode):
            // The Mac doesn't switch modes under a prompt either.
            guard prompt == nil else { return .refused(reason: .busy) }
            if mode == .unattended, !control.remoteCanGoUnattended(id) { return .refused(reason: .autoUnavailable) }
            let landed = await control.remoteSetMode(id, to: mode == .unattended ? .auto : .default)
            guard landed else { return .refused(reason: .modeNotChanged) }
        }
        return .ok
    }
}
