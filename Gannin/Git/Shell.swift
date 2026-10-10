import Foundation

/// Runs bash scripts, here or over ssh, off the main thread: git for
/// sessions' changes and the Repositories pages, and the reads sessions make
/// on their server.
nonisolated enum Shell {
    nonisolated enum Runner: Sendable {
        case local
        /// ssh's arguments, the remote command still to add.
        case ssh([String])
    }

    /// The Connect with command as ssh's arguments for running a command
    /// with no terminal: `-t` dropped, never prompting, and the connection
    /// shared between reads (`ControlMaster`), so each is a few milliseconds
    /// once the first has connected. Nil when it isn't ssh.
    static func sshArguments(_ connect: String) -> [String]? {
        var words = connect.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, first == "ssh" || first.hasSuffix("/ssh") else { return nil }
        words.removeFirst()
        words.removeAll { $0 == "-t" || $0 == "-tt" }
        let options = [
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            // Short, as a socket's path must be.
            "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/gannin-ssh-%C", "-o", "ControlPersist=120",
        ]
        return [first] + options + words
    }

    nonisolated struct Result: Sendable {
        let ok: Bool
        let data: Data
        /// The last line of standard error.
        let error: String
        /// All of standard error, for a hook's failure.
        var errors: String = ""

        var output: String { String(decoding: data, as: UTF8.self) }

        /// What went wrong, in full but not endless: standard error, else
        /// what was printed (a hook may print its complaint there).
        var failure: String {
            let text = errors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? output : errors
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.suffix(40).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Homebrew's folders first, as a login shell has them: an app opened
    /// from the Dock gets only the system's.
    private static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Runs the script with bash, here or over ssh, where it travels as
    /// base64 so no quoting can break it. Nothing can prompt: there's no
    /// standard input unless `input` is given (a secret the script reads,
    /// kept off every command line), and git is told not to ask for
    /// credentials.
    static func run(_ script: String, _ runner: Runner, input: Data? = nil) -> Result {
        let process = Process()
        switch runner {
        case .local:
            process.executableURL = URL(filePath: "/bin/bash")
            process.arguments = ["-c", script]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            var environment = ProcessInfo.processInfo.environment
            let inherited = environment["PATH"].map { ":" + $0 } ?? ""
            environment["PATH"] = path + inherited
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
        case .ssh(var arguments):
            let ssh = arguments.removeFirst()
            let remote = #"bash -c "$(printf %s "# + Data(script.utf8).base64EncodedString() + #" | base64 -d)""#
            if let index = arguments.firstIndex(of: "{command}") {
                arguments[index] = remote
            } else {
                arguments.append(remote)
            }
            process.executableURL = URL(filePath: ssh.hasPrefix("/") ? ssh : "/usr/bin/ssh")
            process.arguments = arguments
        }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        do { try process.run() } catch { return Result(ok: false, data: Data(), error: error.localizedDescription, errors: error.localizedDescription) }
        if let stdin, let input {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        // Standard error on its own thread, so neither pipe can fill while
        // the other is read and stall git.
        nonisolated final class Box: @unchecked Sendable { var data = Data() }
        let errorBox = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorBox.data = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        let message = String(decoding: errorBox.data, as: UTF8.self)
        let last = message.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return Result(ok: process.terminationStatus == 0, data: data, error: last, errors: message)
    }

    /// Text handed to a command on standard input, safe from quoting:
    /// `printf %s <base64> | base64 -d`.
    static func piped(_ text: String) -> String {
        "printf %s \(Data(text.utf8).base64EncodedString()) | base64 -d"
    }
}
