import Foundation

/// What the Mac and the phone agree on before they say anything else.
public enum RemoteProtocol {
    /// Bumped when a message changes in a way an older side can't read.
    public static let version = 1
    /// The Bonjour service the Mac advertises.
    public static let serviceType = "_gannin._tcp"
    /// The largest frame either side accepts, length prefix excluded.
    public static let maxFrameBytes = 256 * 1024
    /// The longest prompt a phone may send a session.
    public static let maxPromptBytes = 8 * 1024
    /// The longest command a permission prompt carries to the phone.
    public static let maxCommandBytes = 4 * 1024
}

/// What a session's claude is doing, as the Mac's `SessionState` says it.
public enum RemoteSessionState: String, Codable, Sendable, Equatable {
    case starting
    case working
    case needsYou = "needs-you"
    case idle
    case exited
    case stopped
}

/// A session's mode. Only Attended and Unattended can be set from the phone;
/// any other mode claude is in is shown by its name in `RemoteSession.modeLabel`.
public enum RemoteMode: String, Codable, Sendable, Equatable {
    case attended
    case unattended
    case other
}

public struct RemoteOption: Codable, Sendable, Equatable {
    public var label: String
    public var description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

/// One question of an AskUserQuestion.
public struct RemoteQuestionItem: Codable, Sendable, Equatable {
    public var header: String
    public var question: String
    public var options: [RemoteOption]
    public var multiSelect: Bool

    public init(header: String, question: String, options: [RemoteOption], multiSelect: Bool) {
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// One of a permission prompt's own numbered choices.
public struct RemoteChoice: Codable, Sendable, Equatable {
    public var number: Int
    public var label: String

    public init(number: Int, label: String) {
        self.number = number
        self.label = label
    }
}

/// What claude is waiting on. `id` names the prompt, so a decision can say which one it answers.
public enum RemotePrompt: Codable, Sendable, Equatable {
    case question(id: String, items: [RemoteQuestionItem])
    /// `choices` is empty until the Mac has read them off the terminal; the phone shows
    /// "Waiting for the prompt" rather than offering a bare Allow.
    case permission(id: String, tool: String, command: String, commandTruncated: Bool, choices: [RemoteChoice])

    public var id: String {
        switch self {
        case .question(let id, _): id
        case .permission(let id, _, _, _, _): id
        }
    }

    /// Cuts `command` to `maxCommandBytes` of UTF-8 at a character boundary.
    public static func truncated(_ command: String) -> (text: String, wasCut: Bool) {
        guard command.utf8.count > RemoteProtocol.maxCommandBytes else { return (command, false) }
        var text = ""
        var bytes = 0
        for character in command {
            let size = character.utf8.count
            if bytes + size > RemoteProtocol.maxCommandBytes { break }
            text.append(character)
            bytes += size
        }
        return (text, true)
    }
}

/// A session as the phone sees it.
public struct RemoteSession: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// `owner/repo#123` or the like, as the Mac's tabs show it.
    public var reference: String
    public var title: String
    /// Plan, Review, Code, Ask and so on.
    public var kind: String
    public var state: RemoteSessionState
    public var mode: RemoteMode
    public var modeLabel: String
    /// False once the Mac has found auto mode unavailable on this session's box.
    public var canGoUnattended: Bool
    public var prompt: RemotePrompt?
    public var lastMessage: String?

    public init(
        id: String,
        reference: String,
        title: String,
        kind: String,
        state: RemoteSessionState,
        mode: RemoteMode,
        modeLabel: String,
        canGoUnattended: Bool,
        prompt: RemotePrompt? = nil,
        lastMessage: String? = nil
    ) {
        self.id = id
        self.reference = reference
        self.title = title
        self.kind = kind
        self.state = state
        self.mode = mode
        self.modeLabel = modeLabel
        self.canGoUnattended = canGoUnattended
        self.prompt = prompt
        self.lastMessage = lastMessage
    }
}

public struct RemoteAnswer: Codable, Sendable, Equatable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// What the phone asks of a session. Never terminal keys: the Mac decides how each reaches claude.
public enum RemoteIntent: Codable, Sendable, Equatable {
    case answer(answers: [RemoteAnswer])
    case choose(number: Int)
    case deny
    case prompt(text: String)
    case interrupt
    case setMode(mode: RemoteMode)

    /// The reason the Mac would refuse this intent whatever the session's state, if any.
    public var invalidReason: RemoteRefusal? {
        switch self {
        case .prompt(let text):
            if text.utf8.count > RemoteProtocol.maxPromptBytes { return .tooLarge }
            return text.allSatisfy(\.isWhitespace) ? .invalid : nil
        case .answer(let answers):
            return answers.isEmpty ? .invalid : nil
        case .choose(let number):
            return number < 1 ? .invalid : nil
        case .setMode(let mode):
            return mode == .other ? .invalid : nil
        case .deny, .interrupt:
            return nil
        }
    }

    /// Whether the intent answers the session's pending prompt, and so must name it.
    public var answersPrompt: Bool {
        switch self {
        case .answer, .choose, .deny: true
        case .prompt, .interrupt, .setMode: false
        }
    }
}

public enum RemoteRefusal: String, Codable, Sendable, Equatable {
    /// The prompt the decision named is no longer the session's.
    case promptGone
    case notRunning
    case autoUnavailable
    case unknownSession
    case tooLarge
    case invalid
    case rateLimited
    /// The session is waiting on a prompt, so its mode can't be switched now.
    case busy
    /// claude didn't land in the mode asked for.
    case modeNotChanged
}

public enum RemoteResult: Codable, Sendable, Equatable {
    case ok
    case refused(reason: RemoteRefusal)
}

public enum ClientMessage: Codable, Sendable, Equatable {
    case hello(name: String)
    case subscribe
    /// `promptID` is required when `intent.answersPrompt`.
    case intent(id: String, session: String, promptID: String?, intent: RemoteIntent)
}

public enum ServerMessage: Codable, Sendable, Equatable {
    case hello(macName: String)
    case snapshot(sessions: [RemoteSession])
    case sessionChanged(session: RemoteSession)
    case sessionRemoved(id: String)
    case result(id: String, result: RemoteResult)
    case heartbeat
}
