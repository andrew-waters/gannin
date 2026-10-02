#if os(macOS)
import Foundation

/// What a session's claude has done, read from Claude Code's transcript
/// (`~/.claude/projects/<folder>/<session id>.jsonl`, on the box it runs
/// on) as it grows: the activity, what it costs, how full its context is,
/// the question it's asking, the plans it wrote and its last words.
nonisolated struct SessionTranscript: Sendable, Equatable {
    nonisolated struct Event: Identifiable, Sendable, Equatable {
        nonisolated enum Kind: Sendable, Equatable {
            /// Your prompt, or one Gannin pasted.
            case prompt
            case reply
            /// A tool claude ran: `name`, then what on (a command, a path).
            case tool(name: String)
        }

        let id: String
        let kind: Kind
        let at: Date?
        let text: String
        /// For a tool: whether its result was an error; nil until it has one.
        var failed: Bool?
    }

    /// A test, build or lint command claude ran, and how it went.
    nonisolated struct Check: Sendable, Equatable {
        let command: String
        let passed: Bool
        let at: Date?
    }

    /// The question claude is asking with AskUserQuestion, unanswered.
    nonisolated struct Question: Sendable, Equatable {
        nonisolated struct Option: Sendable, Equatable {
            let label: String
            let description: String
        }

        nonisolated struct Item: Sendable, Equatable {
            let header: String
            let question: String
            let options: [Option]
            let multiSelect: Bool
        }

        let id: String
        let items: [Item]
    }

    /// A review's finding, from the fenced JSON a reviewer ends with.
    nonisolated struct Finding: Sendable, Hashable, Codable {
        let path: String
        let line: Int?
        let comment: String
        /// `blocker`, `major`, `minor` or `nit`, from a PR review.
        var severity: String? = nil
        /// What the line should be instead, for a GitHub suggestion.
        var suggestion: String? = nil
    }

    /// A PR review's result: its summary, verdict and findings.
    nonisolated struct ReviewResult: Sendable, Hashable, Codable {
        let summary: String
        /// `approve`, `comment` or `request_changes`.
        let verdict: String?
        let findings: [Finding]
    }

    /// The newest events, oldest first.
    var events: [Event] = []
    var model: String?
    /// Cost so far, over every run (each resume starts its own count).
    var costUSD: Double = 0
    /// Tokens in the context at the last reply, and how many fit.
    var contextTokens: Int?
    var contextLimit = 200_000
    var workingSeconds: TimeInterval = 0
    var waitingSeconds: TimeInterval = 0
    var lastCheck: Check?
    var question: Question?
    /// Plans claude wrote or edited, as it named them (paths on its box).
    var plans: [String] = []
    var filesEdited: Set<String> = []
    var lastReply: String?
    var lastActivity: Date?

    /// The tool claude ran last that has no result yet: what a permission
    /// prompt is asking to run.
    var pendingTool: Event? {
        guard let last = events.last(where: { if case .tool = $0.kind { return true } else { return false } }), last.failed == nil else { return nil }
        return last
    }

    var contextShare: Double? {
        contextTokens.map { Double($0) / Double(contextLimit) }
    }

    /// Findings in the last reply's fenced JSON (a list of `path`, `line`,
    /// `comment`), as an agent review is asked to end.
    var findings: [Finding] {
        if let review { return review.findings }
        guard let json = lastJSON else { return [] }
        return (try? JSONDecoder().decode([Finding].self, from: Data(json.utf8))) ?? []
    }

    /// A PR review's result, from the JSON object its last reply ends with.
    var review: ReviewResult? {
        lastJSON.flatMap { try? JSONDecoder().decode(ReviewResult.self, from: Data($0.utf8)) }
    }

    /// The last fenced JSON block of the last reply.
    private var lastJSON: String? {
        guard let reply = lastReply, let start = reply.range(of: "```json", options: .backwards) else { return nil }
        let rest = reply[start.upperBound...]
        guard let end = rest.range(of: "```") else { return nil }
        return String(rest[..<end.lowerBound])
    }
}

/// Reads a transcript line by line as it grows, keeping where it got to.
nonisolated struct TranscriptReader: Sendable {
    private static let eventLimit = 400
    private(set) var summary = SessionTranscript()
    /// Bytes read so far: whole lines only.
    private(set) var offset = 0

    private var runCosts: [String: Double] = [:]
    private var toolIndex: [String: Int] = [:]
    private var checkCommands: [String: String] = [:]
    private var turnStart: Date?
    private var turnEnd: Date?
    private var questionToolID: String?
    private static let checkPattern = try! NSRegularExpression(
        pattern: #"\b(test|tests|pytest|jest|vitest|rspec|phpunit|go (test|vet|build)|cargo (test|build|check|clippy)|swift (test|build)|xcodebuild|tsc|lint|eslint|golangci-lint|make|build)\b"#
    )

    /// Takes the bytes after `offset`; only whole lines count, the rest is
    /// read again next time.
    mutating func consume(_ data: Data) {
        guard let last = data.lastIndex(of: 10) else { return }
        let whole = data[data.startIndex...last]
        offset += whole.count
        for line in whole.split(separator: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            read(object)
        }
        if summary.events.count > Self.eventLimit {
            let dropped = summary.events.count - Self.eventLimit
            summary.events.removeFirst(dropped)
            toolIndex = toolIndex.compactMapValues { $0 >= dropped ? $0 - dropped : nil }
        }
        summary.costUSD = runCosts.values.reduce(0, +)
    }

    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private mutating func read(_ object: [String: Any]) {
        let type = object["type"] as? String
        let at = (object["timestamp"] as? String).flatMap { try? Self.iso.parse($0) }
        switch type {
        case "cost-state":
            if let total = object["totalCostUSD"] as? Double {
                runCosts["\(object["startTime"] ?? "run")"] = total
            }
            if let usage = object["modelUsage"] as? [String: Any], usage.keys.contains(where: { $0.contains("[1m]") }) {
                summary.contextLimit = 1_000_000
            }
        case "user":
            guard (object["isMeta"] as? Bool) != true, (object["isSidechain"] as? Bool) != true,
                  let message = object["message"] as? [String: Any] else { return }
            if let text = message["content"] as? String {
                prompt(text, id: object["uuid"] as? String, at: at)
            } else if let items = message["content"] as? [[String: Any]] {
                for item in items {
                    switch item["type"] as? String {
                    case "tool_result":
                        result(item, at: at)
                    case "text":
                        if let text = item["text"] as? String { prompt(text, id: object["uuid"] as? String, at: at) }
                    default:
                        break
                    }
                }
            }
            if let at { advance(at) }
        case "assistant":
            guard (object["isSidechain"] as? Bool) != true, let message = object["message"] as? [String: Any] else { return }
            if let model = message["model"] as? String, model != "<synthetic>" { summary.model = model }
            if let usage = message["usage"] as? [String: Any] {
                let tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                    .compactMap { usage[$0] as? Int }.reduce(0, +)
                if tokens > 0 { summary.contextTokens = tokens }
            }
            for (index, item) in ((message["content"] as? [[String: Any]]) ?? []).enumerated() {
                let id = (item["id"] as? String) ?? "\(object["uuid"] ?? UUID().uuidString)-\(index)"
                switch item["type"] as? String {
                case "text":
                    let text = ((item["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    summary.events.append(.init(id: id, kind: .reply, at: at, text: text))
                    summary.lastReply = text
                case "tool_use":
                    tool(item, id: id, at: at)
                default:
                    break
                }
            }
            if let at { advance(at) }
        default:
            break
        }
    }

    private mutating func prompt(_ text: String, id: String?, at: Date?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Commands' own output and the like, not something you said.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return }
        summary.events.append(.init(id: id ?? UUID().uuidString, kind: .prompt, at: at, text: trimmed))
        // A new turn: the gap since the last ended was waiting on you.
        if let at {
            if let turnEnd, turnStart != nil { summary.waitingSeconds += max(0, at.timeIntervalSince(turnEnd)) }
            turnStart = at
            turnEnd = at
        }
    }

    private mutating func advance(_ at: Date) {
        if let end = turnEnd, at > end {
            if turnStart != nil { summary.workingSeconds += at.timeIntervalSince(end) }
            turnEnd = at
        } else if turnEnd == nil {
            turnEnd = at
        }
        summary.lastActivity = at
    }

    private mutating func tool(_ item: [String: Any], id: String, at: Date?) {
        let name = (item["name"] as? String) ?? "Tool"
        let input = (item["input"] as? [String: Any]) ?? [:]
        var text = ""
        switch name {
        case "Bash":
            let command = (input["command"] as? String) ?? ""
            text = command
            let range = NSRange(command.startIndex..., in: command)
            if Self.checkPattern.firstMatch(in: command, range: range) != nil { checkCommands[id] = command }
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
            text = path
            if !path.isEmpty {
                summary.filesEdited.insert(path)
                if path.contains("/plans/"), path.hasSuffix(".md"), !summary.plans.contains(path) { summary.plans.append(path) }
            }
        case "Read":
            text = (input["file_path"] as? String) ?? ""
        case "Grep", "Glob":
            text = (input["pattern"] as? String) ?? ""
        case "AskUserQuestion":
            let items = ((input["questions"] as? [[String: Any]]) ?? []).map { question in
                SessionTranscript.Question.Item(
                    header: (question["header"] as? String) ?? "",
                    question: (question["question"] as? String) ?? "",
                    options: ((question["options"] as? [[String: Any]]) ?? []).compactMap { option in
                        (option["label"] as? String).map { .init(label: $0, description: (option["description"] as? String) ?? "") }
                    },
                    multiSelect: (question["multiSelect"] as? Bool) ?? false
                )
            }
            summary.question = .init(id: id, items: items)
            questionToolID = id
            text = items.map(\.question).joined(separator: " ")
        case "Task", "Agent":
            text = (input["description"] as? String) ?? ""
        case "WebFetch":
            text = (input["url"] as? String) ?? ""
        case "WebSearch":
            text = (input["query"] as? String) ?? ""
        default:
            text = (input["description"] as? String) ?? ""
        }
        toolIndex[id] = summary.events.count
        summary.events.append(.init(id: id, kind: .tool(name: name), at: at, text: text))
    }

    private mutating func result(_ item: [String: Any], at: Date?) {
        guard let id = item["tool_use_id"] as? String else { return }
        let failed = (item["is_error"] as? Bool) ?? false
        if let index = toolIndex[id], index < summary.events.count { summary.events[index].failed = failed }
        if let command = checkCommands.removeValue(forKey: id) {
            summary.lastCheck = .init(command: command, passed: !failed, at: at)
        }
        if id == questionToolID {
            summary.question = nil
            questionToolID = nil
        }
    }
}
#endif
