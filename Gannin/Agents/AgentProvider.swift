import Foundation

/// Who runs an agent's work. Every activity reaches its agent through a
/// provider (andrew-waters/gannin#466), so what a session's terminal runs,
/// the hooks it reports through, where its transcript is and how a one-off
/// question is asked aren't Claude Code's alone. Claude Code is the one
/// interactive provider; the extra reviewer CLIs (Junie) answer once.
nonisolated enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode = "claude-code"
    case junie

    var id: String { rawValue }

    /// As settings, workflows and the run view name it.
    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .junie: "Junie"
        }
    }

    /// Runs a session in a terminal, as opposed to answering once.
    var isInteractive: Bool { self == .claudeCode }

    /// The extra reviewer CLI it is, for one that only answers once.
    var extraReviewer: ExtraReviewer? {
        switch self {
        case .claudeCode: nil
        case .junie: .junie
        }
    }

    /// Read leniently: an id this build doesn't know (a newer Gannin's
    /// provider) is nil, so a step naming it is skipped rather than lost.
    init?(name: String?) {
        guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
        switch name {
        case "claude", "claude-code", "claude code", "anthropic": self = .claudeCode
        default: self.init(rawValue: name)
        }
    }
}

struct AIModel: Identifiable, Hashable {
    let id: String
    let name: String
}

/// What every provider declares.
protocol AgentProvider {
    var providerID: ProviderID { get }
    /// The models offered, most capable first; any other ID can be typed.
    /// Empty for one that picks its own.
    var models: [AIModel] { get }
    /// Aliases that always mean the newest of a family. Empty for none.
    var latest: [AIModel] { get }
    /// Model IDs it has run with on this Mac, newest first, so a picker
    /// can offer those `models` doesn't list yet. Empty where it leaves
    /// nothing to find them by.
    func detectModels() async -> [String]
}

extension AgentProvider {
    var latest: [AIModel] { [] }
    func detectModels() async -> [String] { [] }
}

/// A provider that runs a session in a terminal: how it starts and
/// resumes, the settings and hooks that write the session's `state`, `pr`,
/// `changed` and `statusline` files (which `HookFileWatcher` reads), its
/// transcript, and optionally its modes and a sandbox.
protocol InteractiveProvider: AgentProvider {
    /// The command it runs, as the start script checks for it on PATH.
    var command: String { get }

    /// Shell lines that start the agent, or resume it once it has had a
    /// prompt (`$session/started`). `settings` is a shell word naming the
    /// settings file; `prompt` the first prompt, nil when Gannin pastes it
    /// later. Needs `$session`, `$id` and the start script's `fail`.
    func launch(_ session: CodeSession, settings: String, prompt: String?) -> String

    /// A shell command that answers the prompt in `promptFile` once, on
    /// this box, printing the reply: a workflow's one-shot step before the
    /// session (`SessionWorkflow.before`). Read-only tools only.
    func oneShotCommand(promptFile: String, model: String?) -> String

    /// The settings file the session is started with: hooks writing its
    /// state into `directory` (a shell expression on its box), the PR it
    /// opens, the statusline, and the session rules' hook when there are
    /// rules. `allowing` are commands it may run without asking.
    func settings(directory: String, isRemote: Bool, allowing: [String], rules: String?, sandboxed: Bool) -> String

    /// The session's transcript on this Mac; `home` is a sandbox's config
    /// folder for it, nil for the user's own.
    func transcript(for session: CodeSession, home: URL?) -> URL?

    /// Shell words that list where the session's transcript may be on its
    /// server: `sandboxDirectory` is the sandbox's issue folder there, if
    /// it runs in one.
    func remoteTranscripts(for session: CodeSession, sandboxDirectory: String?) -> String

    /// A reader for its transcript, from the start.
    func transcriptReader() -> any TranscriptParsing

    /// Reading and switching its permission modes, when it has them.
    var modes: (any ModeControl)? { get }

    /// What a sandbox needs to run it, when it can run in one.
    var sandbox: (any ProviderSandbox)? { get }
}

/// A reviewer that only answers once: run in a throwaway copy of the
/// worktree, it returns its findings as the fenced JSON list a Claude
/// reviewer ends with (`ExtraReviewer`).
protocol OneShotReviewer: AgentProvider {
    func review(folder: URL, prompt: String, tag: String, limit: TimeInterval, run: @escaping ExtraReviewer.Runner) async -> ExtraReviewer.Outcome
    /// Stops the run `tag` names, if it's still going.
    func cancelScript(tag: String) -> String
}

/// One-off questions, answered in one go: rewriting a digest, triage,
/// drafting issues and the rest that ask rather than run a session.
protocol AskingProvider: AgentProvider {
    /// Asks, and returns the reply. `files` are written into the folder it
    /// runs in; `folder` a stable name to resume a conversation in, nil for
    /// a fresh one; `tools` what it may use without asking; `session` a
    /// conversation to start or go on with; `onChunk` the reply as it's
    /// written, the return value still the whole final text.
    @MainActor
    func ask(
        _ prompt: String, org: String, files: [String: Data], folder: String?, tools: [String],
        session: (id: String, resume: Bool)?, model: String?, onChunk: (@MainActor (String) -> Void)?
    ) async throws -> String
}

extension AskingProvider {
    @MainActor
    func ask(
        _ prompt: String, org: String, files: [String: Data] = [:], folder: String? = nil, tools: [String] = [],
        session: (id: String, resume: Bool)? = nil, onChunk: (@MainActor (String) -> Void)? = nil
    ) async throws -> String {
        try await ask(prompt, org: org, files: files, folder: folder, tools: tools, session: session, model: SessionStore.model, onChunk: onChunk)
    }
}

/// A transcript read as it grows, keeping where it got to.
nonisolated protocol TranscriptParsing: Sendable {
    /// Bytes read so far: whole lines only.
    var offset: Int { get }
    var summary: SessionTranscript { get }
    mutating func consume(_ data: Data)
}

/// A provider's permission modes, read off its terminal and switched with
/// a key that cycles them.
protocol ModeControl {
    /// The mode its footer shows, from the terminal's last rows.
    func mode(fromFooter lines: [String]) -> ClaudeMode?
    /// The key that moves to the next mode, as `TerminalKeys` names it.
    var cycleKey: String { get }
}

/// What a sandbox needs to run a provider: where its config lives inside
/// the container, the variable that points it there, and the steps that
/// ready it before it starts. The base image installs it
/// (`SandboxImages.baseContainerfile`).
protocol ProviderSandbox {
    /// Inside the container: its config, transcripts included, mounted
    /// from the session's `homeFolder` on the Mac.
    var configHome: String { get }
    /// The session folder's subfolder holding that config.
    var homeFolder: String { get }
    var configVariable: String { get }
    /// Shell lines run in the sandbox before it starts: seeding its config
    /// and checking it's signed in. Needs `$harness`, `note` and
    /// `activity`.
    var prepare: String { get }
}

/// The providers this build knows.
enum AgentProviders {
    static let claudeCode = ClaudeCodeProvider()

    /// The interactive provider a session runs on: Claude Code for every
    /// session from before providers, and for any this build can't run.
    static func interactive(_ id: ProviderID?) -> any InteractiveProvider {
        claudeCode
    }

    /// Any provider, for what they all declare.
    static func provider(_ id: ProviderID) -> any AgentProvider {
        switch id {
        case .claudeCode: claudeCode
        case .junie: ExtraReviewer.junie
        }
    }

    /// Who answers one-off questions.
    static var asking: any AskingProvider { claudeCode }
}

extension CodeSession {
    /// The provider its terminal runs.
    var agent: any InteractiveProvider { AgentProviders.interactive(provider) }
}
