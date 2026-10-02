#if os(macOS)
import Foundation

/// One-off questions to Claude Code (`claude -p`), for the parts of Gannin
/// that ask Claude something rather than run a session: rewriting a
/// digest, triage, drafting issues, Ask the Org. It runs on this Mac when
/// claude is installed here, else on the server Settings connects to.
/// Everything travels on standard input (a script that writes the prompt
/// and any files into a folder, then runs claude there), so nothing is too
/// big for a command line. claude runs signed in as you, with only the
/// tools it's given.
enum ClaudeRunner {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Where it runs, worked out once.
    nonisolated enum Place: Sendable { case local, remote([String]) }
    @MainActor private static var place: Place?

    /// Asks, and returns claude's reply.
    /// - Parameters:
    ///   - files: written into the folder claude runs in, by relative path.
    ///   - folder: a stable folder name (under the temporary folder), so a
    ///     conversation can be resumed there; nil for a fresh one.
    ///   - tools: tools it may use without asking (`Read`, `Grep`).
    ///   - session: a conversation to start (`resume` false) or go on with.
    @MainActor
    static func ask(
        _ prompt: String,
        org: String,
        files: [String: Data] = [:],
        folder: String? = nil,
        tools: [String] = [],
        session: (id: String, resume: Bool)? = nil
    ) async throws -> String {
        let place = try await resolvePlace()
        var options: [String] = ["-p", "--output-format", "text"]
        if let model = SessionStore.model { options += ["--model", model] }
        if !tools.isEmpty { options += ["--allowedTools", tools.joined(separator: ",")] }
        if let session { options += [session.resume ? "--resume" : "--session-id", session.id] }

        var script = ["set -e"]
        if let folder {
            let safe = String(folder.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            script.append(#"d="${TMPDIR:-/tmp}/"# + safe + #"""#)
            script.append(#"mkdir -p "$d""#)
        } else {
            script.append(#"d=$(mktemp -d "${TMPDIR:-/tmp}/gannin-claude.XXXXXX")"#)
            script.append(#"trap 'rm -rf "$d"' EXIT"#)
        }
        script.append(#"cd "$d""#)
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let quoted = SessionScript.quoted(path)
            script.append("mkdir -p \"$(dirname \(quoted))\"")
            script.append("printf %s \(data.base64EncodedString()) | base64 -d > \(quoted)")
        }
        script.append("printf %s \(Data(prompt.utf8).base64EncodedString()) | base64 -d > .gannin-prompt")
        script.append("command -v claude >/dev/null 2>&1 || { echo 'claude is not installed here' >&2; exit 127; }")
        script.append("claude \(options.map(SessionScript.quoted).joined(separator: " ")) < .gannin-prompt")
        let body = script.joined(separator: "\n") + "\n"

        let result = await Task.detached { run(body, place: place) }.value
        guard result.status == 0 else {
            throw Failure(message: result.error.isEmpty ? "Claude didn't answer (exit \(result.status))." : result.error)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Here if `claude` is on this Mac's PATH, else the server.
    @MainActor
    private static func resolvePlace() async throws -> Place {
        if let place { return place }
        let found = await Task.detached { run("command -v claude", place: .local) }.value
        if found.status == 0, !found.output.isEmpty {
            place = .local
        } else if let connect = SessionStore.connectCommand, let arguments = SessionChanges.sshArguments(connect) {
            place = .remote(arguments)
        } else {
            throw Failure(message: "Claude Code isn't installed on this Mac, and Settings doesn't connect to a server that has it.")
        }
        return place!
    }

    /// The script on standard input, run by bash in your login shell, here
    /// or over ssh.
    /// A bash script on a session's box: this Mac, or its server.
    @MainActor
    static func runScript(_ script: String, for session: CodeSession) async -> (status: Int32, output: String, error: String) {
        let place: Place
        if let connect = session.connect {
            guard let arguments = SessionChanges.sshArguments(connect) else { return (-1, "", "The session's server isn't reached with ssh.") }
            place = .remote(arguments)
        } else {
            place = .local
        }
        return await Task.detached { run(script, place: place) }.value
    }

    nonisolated static func run(_ script: String, place: Place) -> (status: Int32, output: String, error: String) {
        let process = Process()
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") {
            environment[key] = nil
        }
        switch place {
        case .local:
            let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            process.executableURL = URL(filePath: shell)
            process.arguments = ["-l", "-i", "-c", "bash -s"]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        case .remote(var arguments):
            let ssh = arguments.removeFirst()
            let remote = #"exec "${SHELL:-bash}" -lc 'bash -s'"#
            if let index = arguments.firstIndex(of: "{command}") { arguments[index] = remote } else { arguments.append(remote) }
            process.executableURL = URL(filePath: ssh.hasPrefix("/") ? ssh : "/usr/bin/ssh")
            process.arguments = arguments
        }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        // Feed the script on its own thread, so a big one can't block
        // reading the reply.
        let writer = Thread {
            input.fileHandleForWriting.write(Data(script.utf8))
            try? input.fileHandleForWriting.close()
        }
        writer.start()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: errorData, as: UTF8.self)
            .split(separator: "\n")
            .filter { !$0.contains("can't change option") && !$0.contains("no job control") }
            .suffix(3)
            .joined(separator: "\n")
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), message)
    }

    /// The JSON object or list in a reply, from its last fenced block or
    /// the whole reply.
    static func json<T: Decodable>(_ type: T.Type, in reply: String) -> T? {
        var candidates: [String] = []
        if let start = reply.range(of: "```json", options: .backwards) {
            let rest = reply[start.upperBound...]
            if let end = rest.range(of: "```") { candidates.append(String(rest[..<end.lowerBound])) }
        }
        candidates.append(reply)
        if let open = reply.firstIndex(where: { $0 == "{" || $0 == "[" }), let close = reply.lastIndex(where: { $0 == "}" || $0 == "]" }), open < close {
            candidates.append(String(reply[open...close]))
        }
        for candidate in candidates {
            if let value = try? JSONDecoder().decode(T.self, from: Data(candidate.utf8)) { return value }
        }
        return nil
    }
}
#endif
