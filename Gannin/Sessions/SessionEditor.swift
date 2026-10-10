import AppKit

/// The editor a session's files open in, at the line: on this Mac, or for a
/// session on a server, over its ssh connection where the editor can
/// (VS Code and Cursor through Remote SSH, Zed through its own).
enum CodeEditor: String, CaseIterable, Identifiable {
    case vscode, cursor, zed, xcode

    static let key = "sessionsEditor"

    static var chosen: CodeEditor {
        UserDefaults.standard.string(forKey: key).flatMap(CodeEditor.init(rawValue:)) ?? .vscode
    }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .vscode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .zed: "Zed"
        case .xcode: "Xcode"
        }
    }

    var opensRemote: Bool { self != .xcode }

    /// Opens `path` (absolute, on the session's box) at `line`.
    @MainActor
    func open(_ path: String, line: Int?, host: String?) {
        let at = line.map { ":\($0)" } ?? ""
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let address: String?
        switch (self, host) {
        case (.vscode, nil): address = "vscode://file\(encoded)\(at)"
        case (.cursor, nil): address = "cursor://file\(encoded)\(at)"
        case (.zed, nil): address = "zed://file\(encoded)\(at)"
        case (.vscode, let host?): address = "vscode://vscode-remote/ssh-remote+\(host)\(encoded)\(at)"
        case (.cursor, let host?): address = "cursor://vscode-remote/ssh-remote+\(host)\(encoded)\(at)"
        case (.zed, let host?): address = "zed://ssh/\(host)\(encoded)\(at)"
        case (.xcode, _): address = nil
        }
        if let address, let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        } else if self == .xcode, host == nil {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xed")
            process.arguments = (line.map { ["-l", "\($0)"] } ?? []) + [path]
            try? process.run()
        }
    }

    /// The host an ssh command reaches: its first word that isn't an
    /// option or an option's value.
    static func host(of connect: String) -> String? {
        var words = connect.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, first == "ssh" || first.hasSuffix("/ssh") else { return nil }
        words.removeFirst()
        let takesValue: Set<Character> = ["b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m", "O", "o", "p", "Q", "R", "S", "W", "w"]
        var index = 0
        while index < words.count {
            let word = words[index]
            if word == "{command}" { return nil }
            if word.hasPrefix("-") {
                // `-p 22`, but not `-p22`.
                if word.count == 2, let flag = word.last, takesValue.contains(flag) { index += 1 }
                index += 1
                continue
            }
            return word
        }
        return nil
    }
}

extension SessionStore {
    /// Opens the file in the chosen editor, at the line.
    func openInEditor(_ session: CodeSession, worktree: String, path: String, line: Int?) {
        // Editors run git in the folder: a sandbox's worktree is checked first.
        guard session.isSandboxed || SandboxGitGuard.applies(to: worktree) else { return openUnchecked(session, worktree: worktree, path: path, line: line) }
        guard let runner = SessionChanges.runner(for: session) else { return NSSound.beep() }
        let script = SandboxGitGuard.functions + "\nwhy=$(gannin_check \(SessionScript.shellPath(worktree))) || { echo \"$why\"; exit 1; }"
        Task {
            let result = await Task.detached { Shell.run(script, runner) }.value
            guard result.ok else {
                let alert = NSAlert()
                alert.messageText = "Gannin didn't open it"
                alert.informativeText = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                alert.runModal()
                return
            }
            openUnchecked(session, worktree: worktree, path: path, line: line)
        }
    }

    private func openUnchecked(_ session: CodeSession, worktree: String, path: String, line: Int?) {
        let editor = CodeEditor.chosen
        let relative = worktree + "/" + path
        guard let connect = session.connect else {
            editor.open(Self.expanded(relative).path, line: line, host: nil)
            return
        }
        guard editor.opensRemote, let host = CodeEditor.host(of: connect) else {
            NSSound.beep()
            return
        }
        Task {
            var absolute = relative
            if absolute.hasPrefix("~"), let home = await remoteHome(session) {
                absolute = home + absolute.dropFirst()
            }
            editor.open(absolute, line: line, host: host)
        }
    }
}
