import Foundation

/// Claude Code's permission mode, as its transcript's `permissionMode`
/// names it. Gannin offers two: Attended (claude's default mode, asking
/// before edits and commands) and Unattended (auto mode, no prompts, with
/// Claude Code's safety check still blocking risky actions). The others are
/// only shown, by claude's own names, when a session is in one.
nonisolated enum ClaudeMode: String, Sendable, CaseIterable {
    case `default`
    case auto
    case acceptEdits
    case plan
    case bypassPermissions

    var isUnattended: Bool { self == .auto }

    /// What Gannin calls it.
    var label: String {
        switch self {
        case .default: "Attended"
        case .auto: "Unattended"
        case .acceptEdits: "Accept Edits"
        case .plan: "Plan Mode"
        case .bypassPermissions: "Bypass Permissions"
        }
    }

    /// What Claude Code calls it, for help text.
    var claudeName: String {
        switch self {
        case .default: "default mode"
        case .auto: "auto mode"
        case .acceptEdits: "accept edits"
        case .plan: "plan mode"
        case .bypassPermissions: "bypass permissions"
        }
    }

    /// What claude's footer says in each mode but the default, which says
    /// nothing. Its wording is claude's own and may change between
    /// versions; the transcript is the fallback.
    private static let footerPhrases: [(String, ClaudeMode)] = [
        ("auto mode on", .auto),
        ("accept edits on", .acceptEdits),
        ("plan mode on", .plan),
        ("bypass permissions on", .bypassPermissions),
    ]

    /// The mode claude's footer shows, read off the terminal's last rows:
    /// the lines under its input box (a rule, the `❯` prompt, a rule). The
    /// box in sight with no mode named under it is the default mode; no box
    /// (a permission prompt or menu drawn in its place, or a screen that
    /// hasn't drawn) is nil, as the mode can't be seen.
    static func fromFooter(_ lines: [String]) -> ClaudeMode? {
        let rules = lines.indices.filter { isRule(lines[$0]) }
        guard rules.count >= 2, let bottom = rules.last else { return nil }
        let top = rules[rules.count - 2]
        let inside = lines[(top + 1)..<bottom]
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│┃").union(.whitespaces)) }
            .first { !$0.isEmpty }
        guard let inside, inside.hasPrefix("❯") || inside.hasPrefix(">") else { return nil }
        let footer = lines[(bottom + 1)...].joined(separator: " ").lowercased()
        return footerPhrases.first { footer.contains($0.0) }?.1 ?? .default
    }

    /// A row of box drawing, as claude draws its input box's edges.
    private static func isRule(_ line: String) -> Bool {
        let scalars = line.trimmingCharacters(in: .whitespaces).unicodeScalars
        return scalars.count >= 10 && scalars.allSatisfy { (0x2500...0x257F).contains($0.value) }
    }
}

/// One switch between modes by Shift+Tab, which cycles claude's modes in
/// an order that depends on which it has: press, read the mode back, and
/// stop on the one wanted. Back where it started means a whole cycle went
/// by without it, so the session is as it was.
nonisolated struct ModeCycle: Sendable {
    nonisolated enum Outcome: Sendable, Equatable {
        /// The mode wanted is showing.
        case landed
        /// Somewhere else on the way: press again.
        case pressAgain
        /// A whole cycle without auto mode: this claude hasn't got it.
        case unavailable
        /// A whole cycle without the mode wanted, or too many presses.
        case failed
    }

    /// More than claude has modes, so a cycle always comes round first.
    static let maxPresses = 6

    let start: ClaudeMode
    let target: ClaudeMode
    private(set) var seen: [ClaudeMode] = []

    init(from start: ClaudeMode, to target: ClaudeMode) {
        self.start = start
        self.target = target
    }

    /// What to do on seeing `mode` after a press.
    mutating func observe(_ mode: ClaudeMode) -> Outcome {
        if mode == target { return .landed }
        if mode == start { return target == .auto ? .unavailable : .failed }
        seen.append(mode)
        return seen.count >= Self.maxPresses ? .failed : .pressAgain
    }
}

/// Keys as a terminal sends them for a key press.
nonisolated enum TerminalKeys {
    static let escape = "\u{1B}"
    /// Shift+Tab as Gannin names it, which `encode` turns into what the
    /// terminal's keyboard mode expects.
    static let shiftTab = "\u{1B}[Z"

    /// Under the kitty keyboard protocol, which Claude Code turns on, Esc is
    /// `CSI 27 u` (a bare Esc reads as the start of a sequence and is
    /// dropped), Shift+Tab is `CSI 9;2 u`, and when every key is reported,
    /// Return and the rest are too. Without it, keys go as typed.
    static func encode(_ keys: String, kitty: Bool, reportAllKeys: Bool) -> String {
        guard kitty else { return keys }
        if keys == escape { return "\u{1B}[27u" }
        if keys == shiftTab { return "\u{1B}[9;2u" }
        if reportAllKeys, keys.unicodeScalars.count == 1, let scalar = keys.unicodeScalars.first, scalar.value != 0x1B {
            return "\u{1B}[\(scalar.value)u"
        }
        return keys
    }
}

extension SessionStore {
    // MARK: Attended and unattended

    /// Which box a session's claude runs on, for what's remembered about
    /// its Claude Code: empty for this Mac, else the Connect with command.
    func modeBox(_ id: UUID) -> String { sessions[id]?.connect ?? "" }

    /// Whether auto mode is known to be missing from the session's claude.
    func autoUnavailable(_ id: UUID) -> Bool { autoUnavailableBoxes.contains(modeBox(id)) }

    /// Whether Leave Unattended is offered on a waiting permission prompt.
    func offersLeaveUnattended(_ id: UUID) -> Bool {
        !autoUnavailable(id) && modes[id] != .auto
    }

    /// The mode the terminal's footer shows, else the transcript's latest.
    func currentMode(_ id: UUID) -> ClaudeMode? {
        footerMode(id) ?? transcripts[id]?.permissionMode.flatMap(ClaudeMode.init(rawValue:))
    }

    private func footerMode(_ id: UUID) -> ClaudeMode? {
        terminals[id].flatMap { ClaudeMode.fromFooter($0.screenLines(last: 24)) }
    }

    /// Reads the session's mode again, each poll, so a Shift+Tab typed in
    /// the terminal shows within a second. Left alone mid-switch.
    func refreshMode(_ id: UUID) {
        guard !switchingMode.contains(id), let mode = currentMode(id) else { return }
        if modes[id] != mode { modes[id] = mode }
        if mode == .auto { autoUnavailableBoxes.remove(modeBox(id)) }
    }

    /// Puts a running session in `target` by Shift+Tab, reading the footer
    /// after each press (`ModeCycle`). It stops after one whole cycle and
    /// says so in `modeNotes`; one that never reached auto mode marks its box
    /// as without it until claude next starts there. True once it lands.
    @discardableResult
    func switchMode(_ id: UUID, to target: ClaudeMode) async -> Bool {
        guard let terminal = terminals[id], terminal.isRunning, !switchingMode.contains(id) else { return false }
        switchingMode.insert(id)
        defer { switchingMode.remove(id) }
        // The prompt box can take a moment to draw again after a prompt.
        var start = footerMode(id)
        for _ in 0..<6 where start == nil {
            try? await Task.sleep(for: .milliseconds(150))
            start = footerMode(id)
        }
        guard let start else {
            modeNotes[id] = "Can't see claude's mode in the terminal. Try again once its prompt is showing."
            return false
        }
        modes[id] = start
        guard start != target else {
            modeNotes[id] = nil
            return true
        }
        var cycle = ModeCycle(from: start, to: target)
        var previous = start
        while true {
            terminal.press(TerminalKeys.shiftTab)
            var mode: ClaudeMode?
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                if let read = footerMode(id), read != previous {
                    mode = read
                    break
                }
            }
            guard let mode else {
                modeNotes[id] = "Claude didn't change mode, so the session stays \(previous.label)."
                return false
            }
            modes[id] = mode
            previous = mode
            switch cycle.observe(mode) {
            case .landed:
                modeNotes[id] = nil
                if mode == .auto { autoUnavailableBoxes.remove(modeBox(id)) }
                return true
            case .pressAgain:
                continue
            case .unavailable:
                autoUnavailableBoxes.insert(modeBox(id))
                modeNotes[id] = "Auto mode isn't available in this Claude Code, so the session stays \(start.label)."
                return false
            case .failed:
                modeNotes[id] = mode == start
                    ? "The switch didn't land after a whole cycle of claude's modes, so the session stays \(start.label)."
                    : "The switch didn't land, and stopped in claude's \(mode.claudeName)."
                return false
            }
        }
    }

    /// Allow this and stop asking: Yes on the waiting permission prompt,
    /// then, once it has closed, the switch to auto mode.
    func leaveUnattended(_ id: UUID) {
        approvePermission(1, for: id)
        Task {
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if state(id) != .needsYou, permissionChoices(for: id).isEmpty { break }
            }
            guard state(id) != .needsYou else {
                modeNotes[id] = "The prompt didn't close, so the session stays Attended."
                return
            }
            await switchMode(id, to: .auto)
        }
    }
}
