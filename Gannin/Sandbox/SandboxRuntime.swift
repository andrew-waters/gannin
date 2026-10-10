import Foundation

/// Where sandboxes run: this Mac, or the Mac the Connect with command
/// reaches over ssh.
nonisolated enum SandboxBox: Sendable, Hashable {
    case local
    case remote(connect: String)

    /// How to run a script there; nil for a Connect with command that
    /// isn't ssh.
    var runner: Shell.Runner? {
        switch self {
        case .local: .local
        case .remote(let connect): Shell.sshArguments(connect).map(Shell.Runner.ssh)
        }
    }

    var isLocal: Bool { self == .local }
}

/// What a box says about itself and its container, read in one script
/// (`SandboxRuntime.inspect`).
nonisolated struct SandboxHost: Sendable, Equatable {
    var architecture = ""
    /// `sw_vers -productVersion`, such as `27.0`.
    var macOS = ""
    /// The container binary found, empty when there's none.
    var binary = ""
    var version: ContainerVersion?
    /// `container system status`'s own word: `running`, `unregistered`
    /// and so on, empty when it couldn't be asked.
    var status = ""
    /// Whether a default kernel is set for the box's architecture.
    var hasKernel = false
    /// Whether Gannin's base image, as this build of Gannin makes it, is there.
    var hasBaseImage = false
    /// Features whose flag the help didn't list.
    var missing: [SandboxSupport.Feature] = []

    var isAppleSilicon: Bool { architecture == "arm64" }
    var macOSMajor: Int? { macOS.split(separator: ".").first.flatMap { Int($0) } }
    /// Apple container needs Apple Silicon on macOS 26 or later.
    var isSupportedMac: Bool { isAppleSilicon && (macOSMajor ?? 0) >= 26 }
    var isInstalled: Bool { !binary.isEmpty }
    var isRunning: Bool { status == "running" }

    var verdict: SandboxSupport.Verdict {
        SandboxSupport.verdict(version: version, installed: isInstalled, missing: missing)
    }

    /// Why this box can't sandbox sessions, in plain words, or nil when it can
    /// (once the service is running).
    var problem: String? {
        if !isAppleSilicon { return "Apple container needs a Mac with Apple Silicon; this one is \(architecture.isEmpty ? "unknown" : architecture)." }
        if !isSupportedMac { return "Apple container needs macOS 26 or later; this Mac has \(macOS.isEmpty ? "an unknown version" : macOS)." }
        switch verdict {
        case .missing:
            return "Apple container isn't installed."
        case .unsupported(let version, let missing):
            if let version, version < SandboxSupport.minimum {
                return "Apple container \(version) is older than \(SandboxSupport.minimum), the oldest Gannin works with."
            }
            let uses = missing.map { "\($0.use) (`container \($0.command) \($0.flag)`)" }.joined(separator: ", ")
            return "This version of Apple container\(version.map { " (\($0))" } ?? "") lacks what Gannin uses for \(uses)."
        case .older, .tested, .newer:
            return nil
        }
    }

    /// A word on a version that works but isn't the tested one.
    var versionNote: String? {
        switch verdict {
        case .older(let version): "Apple container \(version) works, but Gannin is tested with \(SandboxSupport.tested)."
        case .newer(let version): "Apple container \(version) is newer than \(SandboxSupport.tested), the version Gannin is tested with."
        default: nil
        }
    }

    /// Reads the probe script's `key=value` lines.
    init(probe output: String) {
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals]
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "arch": architecture = value
            case "macos": macOS = value
            case "binary": binary = value
            case "version": version = ContainerVersion(value)
            case "status": status = Self.status(fromJSON: value)
            case "kernel": hasKernel = value == "yes"
            case "base": hasBaseImage = value == "yes"
            case "lacks":
                if let feature = SandboxSupport.features.first(where: { "\($0.command) \($0.flag)" == value }) {
                    missing.append(feature)
                }
            default: break
            }
        }
    }

    init() {}

    /// `status` from `container system status --format json`.
    static func status(fromJSON text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else { return "" }
        return status
    }
}

/// Apple container driven through its CLI (andrew-waters/gannin#8): found,
/// judged against `SandboxSupport`, installed, started and given a kernel,
/// here or over ssh. Orchard's `SystemService` and `CommandRunner` were the
/// reference; nothing here depends on Orchard or the container Swift API.
nonisolated enum SandboxRuntime {
    /// A step that failed, with what the CLI said in full.
    nonisolated struct Failure: LocalizedError, Sendable {
        let message: String
        let output: String
        var errorDescription: String? { message }
    }

    /// Where the binary is looked for, before `PATH`: the installer's
    /// folder, then Homebrew's.
    static let binaryPaths = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]

    /// The bash that finds container and reports on the box, one `key=value`
    /// a line (`SandboxHost.init(probe:)`).
    static var probeScript: String {
        let lookups = binaryPaths.map { #"[ -z "$c" ] && [ -x \#($0) ] && c=\#($0)"# }.joined(separator: "\n")
        let commands = Dictionary(grouping: SandboxSupport.features, by: \.command)
        let checks = commands.keys.sorted().map { command in
            let flags = commands[command, default: []].map { feature in
                #"printf '%s\n' "$h" | grep -qE -- '\#(feature.flag)([^a-z-]|$)' || echo 'lacks=\#(command) \#(feature.flag)'"#
            }.joined(separator: "\n  ")
            return #"h=$("$c" \#(command) --help 2>&1)"# + "\n  " + flags
        }.joined(separator: "\n  ")
        return """
            c=""
            \(lookups)
            [ -z "$c" ] && c=$(command -v container 2>/dev/null)
            echo "arch=$(uname -m)"
            echo "macos=$(sw_vers -productVersion 2>/dev/null)"
            echo "binary=$c"
            if [ -n "$c" ]; then
              echo "version=$("$c" --version 2>/dev/null | head -n1)"
              echo "status=$("$c" system status --format json 2>/dev/null | tr -d '\\n')"
              [ -e "$HOME/Library/Application Support/com.apple.container/kernels/default.kernel-$(uname -m)" ] && echo kernel=yes || echo kernel=no
              "$c" image inspect \(SandboxImages.baseTag) >/dev/null 2>&1 && echo base=yes || echo base=no
              \(checks)
            fi
            """
    }

    /// Reads the box. Nil runner (a Connect with command that isn't ssh) or
    /// a failed connection throw.
    static func inspect(_ box: SandboxBox) async throws -> SandboxHost {
        let result = try await run(probeScript, on: box, failing: "Couldn't ask \(name(box)) about Apple container.")
        return SandboxHost(probe: result.output)
    }

    /// Starts container's service, never prompting for a kernel (that's
    /// `setKernel`), and waits for it to say it's running.
    static func start(_ host: SandboxHost, on box: SandboxBox) async throws {
        let binary = quoted(host.binary)
        try await run("\(binary) system start --disable-kernel-install --timeout 60", on: box, failing: "Apple container's service didn't start on \(name(box)).")
        for _ in 0..<20 {
            let status = try await run("\(binary) system status --format json", on: box, failing: "Couldn't read Apple container's status on \(name(box)).")
            if SandboxHost.status(fromJSON: status.output) == "running" { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw Failure(message: "Apple container's service on \(name(box)) started but never said it was running.", output: "")
    }

    /// Sets the recommended kernel. Only called when none is set, so a Mac
    /// already running containers keeps its own.
    static func setKernel(_ host: SandboxHost, on box: SandboxBox) async throws {
        try await run("\(quoted(host.binary)) system kernel set --recommended", on: box, failing: "Couldn't set Apple container's kernel on \(name(box)).")
    }

    /// Installs (or updates to) `SandboxSupport.tested` on this Mac: the
    /// installer is downloaded and its hash checked as you, then checked
    /// again and installed in one admin prompt, so what's installed is
    /// what was checked. A running service is stopped first, which stops
    /// every container on this Mac; callers say so before calling.
    static func install(stopping host: SandboxHost?) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gannin-container-\(SandboxSupport.tested)", directoryHint: .isDirectory)
        let package = folder.appending(path: SandboxSupport.installer.lastPathComponent).path
        try await run("""
            set -e
            mkdir -p \(quoted(folder.path))
            curl -fsSL --retry 2 -o \(quoted(package)) \(quoted(SandboxSupport.installer.absoluteString))
            \(checksum(package))
            """, on: .local, failing: "Couldn't download Apple container \(SandboxSupport.tested).")
        if let host, host.isRunning {
            try await run("\(quoted(host.binary)) system stop", on: .local, failing: "Couldn't stop Apple container's service to update it.")
        }
        let command = "\(checksum(package)) && /usr/sbin/installer -pkg \(quoted(package)) -target /"
        try await run("/usr/bin/osascript -e \(quoted(adminScript(command)))", on: .local, failing: "Apple container \(SandboxSupport.tested) wasn't installed.")
        try? FileManager.default.removeItem(at: folder)
    }

    /// The bash a terminal runs over `ssh -t` to install or update container
    /// on a remote Mac, where its owner types the admin password for
    /// `sudo` (R19). Gannin never holds it.
    static var remoteInstallScript: String {
        let package = #""${TMPDIR:-/tmp}/"# + SandboxSupport.installer.lastPathComponent + #"""#
        return """
            set -e
            echo "Downloading Apple container \(SandboxSupport.tested)"
            curl -fSL --retry 2 -o \(package) \(quoted(SandboxSupport.installer.absoluteString))
            \(checksum(package))
            # ssh's shell here isn't a login one, so PATH may lack the installer's folder.
            c=$(command -v container 2>/dev/null || true)
            [ -n "$c" ] || c=/usr/local/bin/container
            if [ -x "$c" ]; then "$c" system stop || true; fi
            echo "Installing. sudo asks for this Mac's password."
            sudo /usr/sbin/installer -pkg \(package) -target /
            rm -f \(package)
            /usr/local/bin/container system start --disable-kernel-install --timeout 60
            echo "Apple container \(SandboxSupport.tested) is installed and running."
            """
    }

    /// The command a terminal runs on a server, after the Connect with
    /// command: the script carried as base64, so no quoting can break it.
    static func remoteBash(_ script: String) -> String {
        #"bash -c "$(printf %s "# + Data(script.utf8).base64EncodedString() + #" | base64 -d)""#
    }

    /// The Connect with command with a terminal asked for, which sudo needs
    /// to prompt.
    static func withTerminal(_ connect: String) -> String {
        let words = connect.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = words.first, first == "ssh" || first.hasSuffix("/ssh"), !words.contains(where: { $0 == "-t" || $0 == "-tt" }) else { return connect }
        return ([String(first), "-t"] + words.dropFirst().map(String.init)).joined(separator: " ")
    }

    /// Fails unless the file at `path` (a shell word) is the tested
    /// installer.
    static func checksum(_ path: String) -> String {
        #"[ "$(/usr/bin/shasum -a 256 \#(path) | cut -d' ' -f1)" = \#(SandboxSupport.installerSHA256) ] || { echo 'The download is not the installer Gannin expects.' >&2; exit 1; }"#
    }

    /// AppleScript that runs `command` with administrator privileges, the
    /// command escaped for AppleScript's string literal (as Orchard's
    /// `adminScript`).
    static func adminScript(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    /// Single-quoted for the shell, as `SessionScript.quoted` (which is
    /// main-actor).
    static func quoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func name(_ box: SandboxBox) -> String {
        switch box {
        case .local: "this Mac"
        case .remote(let connect): Shell.sshArguments(connect)?.last ?? connect
        }
    }

    /// Runs `script` on the box off the main actor, throwing `Failure` with
    /// what it said when it fails.
    @discardableResult
    private static func run(_ script: String, on box: SandboxBox, failing message: String) async throws -> Shell.Result {
        guard let runner = box.runner else {
            throw Failure(message: "The Connect with command isn't ssh, so Gannin can't check \(name(box)) for Apple container.", output: "")
        }
        let result = await Task.detached { Shell.run(script, runner) }.value
        guard result.ok else { throw Failure(message: message, output: result.failure) }
        return result
    }
}
