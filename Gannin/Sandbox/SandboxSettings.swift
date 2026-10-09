import AppKit
import SwiftUI

/// Settings › General › Sandbox (andrew-waters/gannin#8): turning sandboxed
/// sessions on, which first gets this Mac ready (`SandboxSetup`), the Claude
/// credential, the signing key, and the caps each sandbox gets.
struct SandboxSettingsSection: View {
    @AppStorage(SandboxCredentials.enabledKey) private var enabled = false
    @AppStorage(SandboxCredentials.claudeKindKey) private var claudeKind: SandboxCredentials.ClaudeKind = .subscription
    @AppStorage(SandboxCredentials.cpusKey) private var cpus = SandboxCredentials.defaultCPUs
    @AppStorage(SandboxCredentials.memoryKey) private var memory = SandboxCredentials.defaultMemoryGB
    @State private var setup = SandboxSetup(box: .local)
    /// Bumped after a keychain change, which nothing observes, to redraw.
    @State private var revision = 0
    @State private var credential = ""
    @State private var credentialError: String?
    @State private var gettingToken = false
    @State private var pastingKey = false
    @State private var keyText = ""
    @State private var keyError: String?
    @State private var makingKey = false
    @State private var confirmingInstall = false
    @State private var confirmingOff = false
    @State private var showingOutput = false

    var body: some View {
        let _ = revision
        let missing = SandboxCredentials.missing
        Section {
            Toggle("Run Work on This sessions in a sandbox", isOn: Binding(get: { enabled }, set: turn))
                .disabled(setup.isRunning || (!enabled && !missing.isEmpty))
            Text(enabledNote(missing: missing))
                .font(.caption)
                .foregroundStyle(.secondary)
            setupRows
        } header: {
            Text("Sandbox")
        } footer: {
            Text("A sandbox is a Linux VM from Apple container, one per issue. It sees the harness read-only, its own issue's folder and the shared clones' git, and nothing else of this Mac: not your home folder, keys or other sessions. Its network is open. Repos that only build on a Mac can be marked Needs the Mac, and their sessions stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await setup.check() }
        .sheet(isPresented: $showingOutput) {
            GitOutputSheet(title: setup.problem ?? "Apple container said", output: setup.output)
        }
        .confirmationDialog("Install Apple container \(SandboxSupport.tested.description)?", isPresented: $confirmingInstall) {
            Button("Install") { Task { await runSetup(installing: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(installMessage)
        }
        .confirmationDialog("Turn off sandboxed sessions?", isPresented: $confirmingOff) {
            Button("Turn Off and Remove", role: .destructive) {
                Task { if await setup.removeAll() { enabled = false } }
            }
            Button("Turn Off, Keep Them") { enabled = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removing deletes every container and image Gannin made on this Mac, a running session's sandbox included, and nothing else. Kept, the base image is ready if you turn it on again. New sessions start on this Mac either way.")
        }

        Section {
            Picker("Claude signs in with", selection: $claudeKind) {
                ForEach(SandboxCredentials.ClaudeKind.allCases) { Text($0.name).tag($0) }
            }
            .onChange(of: claudeKind) { credential = ""; credentialError = nil }
            if SandboxCredentials.claudeCredential(claudeKind) != nil {
                LabeledContent("\(claudeKind.name)") {
                    HStack {
                        Text("Saved in the keychain").foregroundStyle(.secondary)
                        Button("Remove") {
                            SandboxCredentials.setClaudeCredential(nil, claudeKind)
                            if enabled { enabled = false }
                            revision += 1
                        }
                    }
                }
            } else {
                HStack {
                    SecureField(claudeKind.name, text: $credential, prompt: Text(claudeKind.prefix))
                    Button("Save", action: saveCredential)
                        .disabled(credential.trimmingCharacters(in: .whitespaces).isEmpty)
                    if claudeKind == .subscription {
                        Button("Get a Token") { gettingToken = true }
                    }
                }
                if let credentialError {
                    Text(credentialError).font(.caption).foregroundStyle(.red)
                }
            }
            Text(claudeKind == .subscription
                 ? "A long-lived token on your Claude subscription, from claude setup-token. Get a Token runs it here: sign in in the browser it opens, and the token it prints is filled in."
                 : "An Anthropic API key from the Claude Console, billed to the API rather than your subscription.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Claude in a sandbox")
        } footer: {
            Text("Kept in the keychain and passed to each sandbox as \(claudeKind.environmentName). Your own Claude login on this Mac never goes in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $gettingToken) {
            SetupTokenSheet { token in
                SandboxCredentials.setClaudeCredential(token, .subscription)
                revision += 1
            }
        }

        Section {
            signingKeyRows
        } header: {
            Text("Commit signing")
        } footer: {
            Text("Commits made in a sandbox are signed with this key and carry your git name and email. It's a key of its own, kept in the keychain; your SSH keys never go in. Add it to GitHub as a Signing Key so its commits show as Verified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Stepper("CPUs: \(cpus)", value: $cpus, in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount))
            Stepper("Memory: \(memory) GB", value: $memory, in: 2...max(2, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)))
            Text("Each sandbox's share of this Mac, applied when it starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Each sandbox gets")
        }
    }

    // MARK: Setup

    @ViewBuilder private var setupRows: some View {
        if setup.isRunning || setup.steps.count > 1 {
            ForEach(setup.steps) { step in
                LabeledContent(step.kind.title) { stepState(step.state) }
            }
        }
        if let host = setup.host {
            LabeledContent("Apple container") {
                Text(host.version.map { "\($0.description)\(host.isRunning ? ", running" : ", stopped")" } ?? "Not installed")
                    .foregroundStyle(.secondary)
            }
            if let note = host.versionNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        if let problem = setup.problem, !setup.isRunning {
            Text(problem).font(.caption).foregroundStyle(.orange)
        }
        HStack {
            if setup.offersInstall {
                Button(setup.host?.isInstalled == true ? "Update to \(SandboxSupport.tested.description)" : "Install Apple container") { confirmingInstall = true }
            }
            if setup.host?.isSupportedMac == true, !setup.isReady {
                Button("Set Up") { Task { await runSetup(installing: false) } }
            }
            Button("Check Again") { Task { await setup.check() } }
            if !setup.output.isEmpty {
                Button("Show Output") { showingOutput = true }
            }
            if setup.isRunning { ProgressView().controlSize(.small) }
        }
        .disabled(setup.isRunning)
    }

    @ViewBuilder private func stepState(_ state: SandboxSetup.StepState) -> some View {
        switch state {
        case .waiting: Text("Waiting").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Text("Already done").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var installMessage: String {
        let update = setup.host?.isInstalled == true
        return "Gannin downloads Apple's signed installer for \(SandboxSupport.tested), checks it, and macOS asks for your password once to install it."
            + (update ? " Updating stops Apple container's service, which stops every container running on this Mac, Gannin's or not." : "")
    }

    private func enabledNote(missing: [String]) -> String {
        if enabled { return "New Work on This sessions start in a sandbox, and each can be started on this Mac instead." }
        if !missing.isEmpty { return "Needs \(missing.joined(separator: " and ")) first, below." }
        return "Turning it on gets this Mac ready first: Apple container installed, its service running, a Linux kernel set and Gannin's base image built, which takes a few minutes the first time."
    }

    private func turn(_ on: Bool) {
        guard on else {
            confirmingOff = true
            return
        }
        Task { await runSetup(installing: false) }
    }

    /// Gets this Mac ready, then turns sandboxing on if it is: never
    /// silently on when it isn't (R2).
    private func runSetup(installing: Bool) async {
        await setup.setUp(installing: installing)
        if setup.isReady, SandboxCredentials.missing.isEmpty { enabled = true }
    }

    private func saveCredential() {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix(claudeKind.prefix) else {
            credentialError = "That doesn't look like a \(claudeKind.name.lowercased()), which starts \(claudeKind.prefix)."
            return
        }
        SandboxCredentials.setClaudeCredential(value, claudeKind)
        credential = ""
        credentialError = nil
        revision += 1
    }

    // MARK: Signing key

    @ViewBuilder private var signingKeyRows: some View {
        if let publicKey = SandboxCredentials.publicSigningKey, SandboxCredentials.signingKey != nil {
            LabeledContent("Public key") {
                Text(publicKey)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(publicKey)
            }
            HStack {
                Button("Copy") { copy(publicKey) }
                Button("Add to GitHub") {
                    copy(publicKey)
                    NSWorkspace.shared.open(SandboxCredentials.newSigningKeyURL)
                }
                .help("Copies the key and opens GitHub's New SSH key page: paste it there and pick Signing Key as its type.")
                Spacer()
                Button("Remove", role: .destructive) {
                    SandboxCredentials.removeSigningKey()
                    if enabled { enabled = false }
                    revision += 1
                }
            }
            Text("On GitHub, pick Signing Key as the key type when you paste it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if pastingKey {
            TextEditor(text: $keyText)
                .font(.caption.monospaced())
                .frame(minHeight: 80)
            HStack {
                Button("Cancel") { pastingKey = false; keyText = ""; keyError = nil }
                Button("Use This Key") { Task { await importKey() } }
                    .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else {
            HStack {
                Button("Make a Signing Key") { Task { await makeKey() } }
                    .disabled(makingKey)
                Button("Paste a Key") { pastingKey = true }
                if makingKey { ProgressView().controlSize(.small) }
            }
        }
        if let keyError {
            Text(keyError).font(.caption).foregroundStyle(.red)
        }
    }

    private func makeKey() async {
        makingKey = true
        defer { makingKey = false }
        do {
            let key = try await SandboxCredentials.generateSigningKey(comment: "Gannin sandbox on \(Host.current().localizedName ?? "Mac")")
            SandboxCredentials.setSigningKey(private: key.private, public: key.public)
            keyError = nil
            revision += 1
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func importKey() async {
        do {
            let key = try await SandboxCredentials.importSigningKey(keyText)
            SandboxCredentials.setSigningKey(private: key.private, public: key.public)
            keyText = ""
            keyError = nil
            pastingKey = false
            revision += 1
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Runs `claude setup-token` in a terminal, where its sign-in happens, and
/// picks the token out of what it prints.
private struct SetupTokenSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onToken: (String) -> Void
    @State private var terminal: SessionTerminal?
    @State private var token: String?
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Get a Claude Token").font(.headline)
            Text("claude setup-token opens your browser to sign in with your Claude subscription, then prints a token that lasts a year. Gannin keeps it in the keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let terminal {
                TokenTerminal(view: terminal.container)
                    .frame(minWidth: 640, minHeight: 280)
            }
            HStack {
                if token != nil {
                    Label("Token found", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if finished {
                    Text("No token was printed. Try again, or paste one in Settings.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { close() }
                Button("Save Token") {
                    if let token { onToken(token) }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token == nil)
            }
        }
        .padding(16)
        .onAppear(perform: start)
        .task {
            // The token is printed before claude exits; read it as it comes.
            while !Task.isCancelled, token == nil {
                read()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func start() {
        guard terminal == nil else { return }
        let terminal = SessionTerminal {
            finished = true
            read()
        } onSignal: { _ in }
        self.terminal = terminal
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        for key in environment.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") { environment[key] = nil }
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        terminal.launch(
            executable: shell,
            args: ["-l", "-i", "-c", "claude setup-token"],
            environment: environment.map { "\($0.key)=\($0.value)" },
            directory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    private func read() {
        guard token == nil, let terminal else { return }
        token = SandboxCredentials.setupToken(in: terminal.screenLines(last: 200).joined(separator: "\n"))
    }

    private func close() {
        terminal?.terminate()
        dismiss()
    }
}

private struct TokenTerminal: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The org's Settings › Harness: the fine-grained GitHub token its sandboxed
/// sessions push and open pull requests with (R7).
struct SandboxGitHubTokenSection: View {
    let org: String
    @State private var token = ""
    @State private var revision = 0

    var body: some View {
        let _ = revision
        Section {
            if SandboxCredentials.gitHubToken(org: org) != nil {
                LabeledContent("Token") {
                    HStack {
                        Text("Saved in the keychain").foregroundStyle(.secondary)
                        Button("Remove") {
                            SandboxCredentials.setGitHubToken(nil, org: org)
                            revision += 1
                        }
                    }
                }
            } else {
                HStack {
                    SecureField("Token", text: $token, prompt: Text("github_pat_"))
                    Button("Save") {
                        SandboxCredentials.setGitHubToken(token, org: org)
                        token = ""
                        revision += 1
                    }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Link("Create One on GitHub", destination: SandboxCredentials.newGitHubTokenURL(org: org))
            }
            Text("A fine-grained token for \(org), with access to the repos sessions work on and these permissions: "
                 + SandboxCredentials.gitHubPermissions.map { "\($0.name.replacingOccurrences(of: "_", with: " ")) \($0.level) (\($0.why))" }.joined(separator: ", ")
                 + ". Create One fills them in; pick the repos there. Changing workflow files needs Workflows as well.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("GitHub in a sandbox")
        } footer: {
            Text("Passed to this org's sandboxed sessions as GH_TOKEN, for git and gh. Gannin's own sign-in and your gh login never go in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
