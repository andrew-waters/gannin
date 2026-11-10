import Foundation

/// Bash scripts run on a box: this Mac, or a server reached with ssh, read
/// on standard input so nothing is too big for a command line. A provider's
/// one-off questions (`AskingProvider.ask`) and a session's own scripts both
/// go through it.
enum ScriptRunner {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Where it runs.
    nonisolated enum Place: Sendable { case local, remote([String]) }

    /// A bash script on a session's box: this Mac, or its server.
    @MainActor
    static func runScript(_ script: String, for session: CodeSession) async -> (status: Int32, output: String, error: String) {
        let place: Place
        if let connect = session.connect {
            guard let arguments = Shell.sshArguments(connect) else { return (-1, "", "The session's server isn't reached with ssh.") }
            place = .remote(arguments)
        } else {
            place = .local
        }
        return await Task.detached { run(script, place: place) }.value
    }

    /// Runs the script on standard input, by bash in your login shell, here
    /// or over ssh, reading its reply line by line when `onLine` is given
    /// (so a provider's streamed output can be parsed as it arrives)
    /// rather than waiting for it to finish.
    nonisolated static func run(_ script: String, place: Place, onLine: ((String) -> Void)? = nil) -> (status: Int32, output: String, error: String) {
        if NetworkGate.isSealed { return (-1, "", NetworkGate.Sealed.process) }
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
        var data = Data()
        if let onLine {
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    if let line = String(data: buffer[..<newline], encoding: .utf8) { onLine(line) }
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { onLine(line) }
        } else {
            data = output.fileHandleForReading.readDataToEndOfFile()
        }
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
    /// the whole reply. A last block left unclosed (Junie's final summary
    /// can end without the closing fence) runs to the end of the reply.
    static func json<T: Decodable>(_ type: T.Type, in reply: String) -> T? {
        var candidates: [String] = []
        if let start = reply.range(of: "```json", options: .backwards) {
            let rest = reply[start.upperBound...]
            candidates.append(String(rest[..<(rest.range(of: "```")?.lowerBound ?? rest.endIndex)]))
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
