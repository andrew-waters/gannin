import AppKit
import SwiftUI

/// Settings › General › Sandbox (andrew-waters/gannin#8): turning sandboxed
/// sessions on, which first gets this Mac ready (`SandboxSetup`), the Claude
/// credential, the signing key, and the caps each sandbox gets.
struct SandboxSettingsSection: View {
    @AppStorage(SandboxCredentials.enabledKey) private var enabled = false
    @AppStorage(SandboxCredentials.claudeKindKey) private var claudeKind: SandboxCredentials.ClaudeKind = .signIn
    @AppStorage(SandboxCredentials.cpusKey) private var cpus = SandboxCredentials.defaultCPUs
    @AppStorage(SandboxCredentials.memoryKey) private var memory = SandboxCredentials.defaultMemoryGB
    @State private var setup = SandboxSetup(box: .local)
    /// Bumped after a keychain change, which nothing observes, to redraw.
    @State private var revision = 0
    @State private var credential = ""
    @State private var credentialError: String?
    @State private var signingOut = false
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
            Toggle("Run Work on This sessions in a sandbox", isOn: Binding(get: { enabled }, set: { turn($0) }))
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
            Text("New sessions start on this Mac. Sessions already in a sandbox stay in one, since their conversation is there: opening one starts its sandbox again, building the base image again if it was removed. Removing deletes every container and image Gannin made on this Mac, a running session's sandbox included, and nothing else.")
        }

        Section {
            Picker("Claude signs in with", selection: $claudeKind) {
                ForEach(SandboxCredentials.ClaudeKind.allCases) { Text($0.name).tag($0) }
            }
            .onChange(of: claudeKind) { credential = ""; credentialError = nil }
            switch claudeKind {
            case .signIn:
                Text("The first sandbox asks you to sign in to Claude, in its terminal, through Anthropic's own sign-in: open the link it shows, sign in, and paste the code back. Claude keeps that login in a folder your sandboxes share, so the rest are signed in too. Gannin never sees or stores it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Sign Out of Claude in Sandboxes") { signingOut = true }
                    .help("Removes the login your sandboxes share, so the next one asks again")
            case .apiKey:
                if SandboxCredentials.apiKey != nil {
                    LabeledContent("API key") {
                        HStack {
                            Text("Saved in the keychain").foregroundStyle(.secondary)
                            Button("Remove") {
                                SandboxCredentials.setAPIKey(nil)
                                if enabled { enabled = false }
                                revision += 1
                            }
                        }
                    }
                } else {
                    HStack {
                        SecureField("API key", text: $credential, prompt: Text(SandboxCredentials.apiKeyPrefix))
                        Button("Save", action: saveCredential)
                            .disabled(credential.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let credentialError {
                        Text(credentialError).font(.caption).foregroundStyle(.red)
                    }
                }
                Text("An Anthropic API key from the Claude Console, billed to the API. Kept in the keychain and passed to each sandbox as ANTHROPIC_API_KEY.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Claude in a sandbox")
        } footer: {
            Text("Each person signs in with their own Claude account or key; never share one. A subscription's sessions all draw on its usage limits, and Pro and Max are for personal use: for a team's work, use Team or Enterprise seats or an API key. Your own Claude login on this Mac never goes in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Sign out of Claude in your sandboxes?", isPresented: $signingOut) {
            Button("Sign Out", role: .destructive) {
                try? FileManager.default.removeItem(at: SandboxCredentials.claudeFolder.appending(path: ".credentials.json"))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next sandbox asks you to sign in again. Sandboxes running now stay signed in until they stop.")
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
        guard value.hasPrefix(SandboxCredentials.apiKeyPrefix) else {
            credentialError = "That doesn't look like an API key, which starts \(SandboxCredentials.apiKeyPrefix)."
            return
        }
        SandboxCredentials.setAPIKey(value)
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

/// A terminal's view, hosted in SwiftUI.
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

/// Settings › General › Remote machines (R19): the Mac sessions reach with
/// Connect with, as Apple container finds it there, with Set Up (start its
/// service, set a kernel, build the base image) and Install or Update in a
/// terminal over `ssh -t`, where its owner types its password.
struct RemoteMachinesSection: View {
    @Environment(SessionStore.self) private var sessions
    @AppStorage(SessionStore.connectKey) private var connect = ""
    @State private var setup: SandboxSetup?
    @State private var confirmingInstall = false
    @State private var installing = false
    @State private var showingOutput = false

    var body: some View {
        let connect = connect.trimmingCharacters(in: .whitespaces)
        if !connect.isEmpty {
            Section {
                if let setup, setup.box == .remote(connect: connect) {
                    rows(setup, connect: connect)
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                Text("Remote machines")
            } footer: {
                Text("Sandboxed sessions on a server run in Apple container there, which needs a Mac with Apple Silicon on macOS 26 or later. Gannin checks it over ssh; installing or updating it asks for that Mac's password in a terminal, which Gannin never sees.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task(id: connect) {
                let setup = SandboxSetup(box: .remote(connect: connect))
                self.setup = setup
                await setup.check()
            }
            .sheet(isPresented: $installing) {
                CommandTerminalSheet(
                    title: "Install Apple container \(SandboxSupport.tested.description)",
                    explanation: "On \(SandboxRuntime.name(.remote(connect: connect))), Gannin downloads Apple's signed installer, checks it, and installs it with sudo. Type that Mac's password when it asks.",
                    command: SessionScript.connecting(SandboxRuntime.withTerminal(connect), to: SandboxRuntime.remoteBash(SandboxRuntime.remoteInstallScript))
                ) {
                    Task { await setup?.check() }
                }
            }
            .sheet(isPresented: $showingOutput) {
                GitOutputSheet(title: setup?.problem ?? "Apple container said", output: setup?.output ?? "")
            }
            .confirmationDialog(installTitle, isPresented: $confirmingInstall) {
                Button(setup?.host?.isInstalled == true ? "Update" : "Install") { installing = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(installMessage(connect: connect))
            }
        }
    }

    @ViewBuilder private func rows(_ setup: SandboxSetup, connect: String) -> some View {
        LabeledContent(SandboxRuntime.name(.remote(connect: connect))) {
            if let host = setup.host {
                Text([host.architecture, host.macOS.isEmpty ? "" : "macOS \(host.macOS)"].filter { !$0.isEmpty }.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            } else if setup.isRunning {
                ProgressView().controlSize(.small)
            }
        }
        if let host = setup.host, host.isSupportedMac {
            LabeledContent("Apple container") {
                Text(host.version.map { "\($0.description)\(host.isRunning ? ", running" : ", stopped")" } ?? "Not installed")
                    .foregroundStyle(.secondary)
            }
            if let note = host.versionNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        if setup.isRunning, setup.steps.count > 1 {
            ForEach(setup.steps) { step in
                LabeledContent(step.kind.title) {
                    switch step.state {
                    case .running: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    case .waiting, .skipped: EmptyView()
                    }
                }
            }
        }
        if let problem = setup.problem, !setup.isRunning {
            Text(problem).font(.caption).foregroundStyle(.orange)
        } else if setup.isReady {
            Text("Ready for sandboxed sessions.").font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            if let host = setup.host, host.isSupportedMac, host.verdict.offersInstall {
                Button(host.isInstalled ? "Update to \(SandboxSupport.tested.description)" : "Install Apple container") { confirmingInstall = true }
            }
            if let host = setup.host, host.isSupportedMac, host.verdict.canSandbox, !setup.isReady {
                Button("Set Up") { Task { await setup.setUp(installing: false) } }
                    .help("Starts Apple container's service there, sets a Linux kernel if none is set, and builds Gannin's base image")
            }
            Button("Check Again") { Task { await setup.check() } }
            if !setup.output.isEmpty {
                Button("Show Output") { showingOutput = true }
            }
        }
        .disabled(setup.isRunning)
    }

    private var installTitle: String {
        setup?.host?.isInstalled == true ? "Update Apple container to \(SandboxSupport.tested.description)?" : "Install Apple container \(SandboxSupport.tested.description)?"
    }

    /// Updating stops the service there, and every sandbox with it.
    private func installMessage(connect: String) -> String {
        let stopping = sessions.running.filter { $0.isSandboxed && $0.connect == connect }
        var message = "A terminal opens on the server, where sudo asks for its password."
        if setup?.host?.isInstalled == true {
            message += " Updating stops Apple container's service there, which stops every container on it"
            message += stopping.isEmpty ? "." : ", these sessions' sandboxes among them: " + stopping.map { "#\($0.issue.number) \($0.issue.title)" }.joined(separator: ", ") + "."
        }
        return message
    }
}

/// A command in a terminal, for something its user has to type into (a
/// password), with Done once it's finished.
struct CommandTerminalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let explanation: String
    let command: String
    let onExit: () -> Void
    @State private var terminal: SessionTerminal?
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(explanation).font(.callout).foregroundStyle(.secondary)
            if let terminal {
                TokenTerminal(view: terminal.container)
                    .frame(minWidth: 640, minHeight: 320)
            }
            HStack {
                if finished { Text("Finished.").foregroundStyle(.secondary) }
                Spacer()
                Button(finished ? "Done" : "Stop") {
                    terminal?.terminate()
                    onExit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear(perform: start)
    }

    private func start() {
        guard terminal == nil else { return }
        let terminal = SessionTerminal { finished = true } onSignal: { _ in }
        self.terminal = terminal
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        terminal.launch(executable: shell, args: ["-l", "-i", "-c", command], environment: environment.map { "\($0.key)=\($0.value)" }, directory: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}
