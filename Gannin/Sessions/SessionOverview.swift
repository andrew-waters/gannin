#if os(macOS)
import SwiftUI

/// Every session at once: what each is doing, what it last said, the
/// files it's touched, its PRs' checks and what it's cost. Waiting ones
/// first; clicking one opens its tab.
struct SessionOverview: View {
    @Environment(SessionStore.self) private var sessions

    var body: some View {
        let all = sessions.sessions.values.filter { $0.archivedAt == nil }.sorted { order($0) < order($1) }
        ScrollView {
            if all.isEmpty {
                ContentUnavailableView("No sessions", systemImage: "terminal", description: Text("Work on This on an issue starts one."))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                ForEach(all) { session in
                    SessionCard(session: session)
                }
            }
            .padding(16)
        }
    }

    /// Waiting on you, then running, then the rest; newest first within.
    private func order(_ session: CodeSession) -> (Int, TimeInterval) {
        let rank = sessions.attention[session.id] != nil ? 0 : sessions.isRunning(session.id) ? 1 : sessions.isStale(session) ? 3 : 2
        return (rank, -session.createdAt.timeIntervalSince1970)
    }
}

private struct SessionCard: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession

    var body: some View {
        let state = sessions.state(session.id)
        let transcript = sessions.transcripts[session.id]
        let pullRequests = sessions.pullRequestInfo[session.id] ?? []
        let waiting = sessions.attention[session.id] != nil
        Button {
            sessions.showingOverview = false
            sessions.reveal(session.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(state.color).frame(width: 8, height: 8)
                    Text(state.label).font(.caption).foregroundStyle(.secondary)
                    if sessions.isStale(session) {
                        Text("Stale").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    if let transcript, transcript.costUSD > 0 {
                        Text(transcript.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("#\(String(session.issue.number)) \(session.title)")
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let question = transcript?.question?.items.first?.question, state == .needsYou {
                    Label(question, systemImage: "questionmark.bubble")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                } else if let reply = transcript?.lastReply {
                    Text(reply)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else {
                    Text(sessions.isRunning(session.id) ? "Starting." : "Not running. Open it to resume.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if let transcript, !transcript.filesEdited.isEmpty {
                        Label("\(transcript.filesEdited.count)", systemImage: "pencil")
                            .help("Files edited")
                    }
                    if let check = transcript?.lastCheck {
                        Label(check.passed ? "Tests" : "Tests", systemImage: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.passed ? ChartPalette.good : ChartPalette.critical)
                            .help(check.command)
                    }
                    ForEach(pullRequests) { pr in
                        let failing = pr.state == "OPEN" && !pr.failed.isEmpty
                        Label("#\(String(pr.number))", systemImage: failing ? "xmark.circle.fill" : pr.state == "MERGED" ? "arrow.triangle.merge" : "arrow.triangle.pull")
                            .foregroundStyle(failing ? ChartPalette.critical : pr.stateColor)
                            .help("\(pr.repo)#\(pr.number): \(pr.stateLabel)\(failing ? ", checks failing" : "")")
                    }
                    Spacer()
                    if let share = transcript?.contextShare {
                        Text("\(Int((share * 100).rounded()))% context")
                            .foregroundStyle(share > 0.8 ? .orange : .secondary)
                    }
                }
                .font(.caption)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(waiting ? state.color : Color.separatorLine, lineWidth: waiting ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// In the Issue panel: once every PR is merged, or when the session's gone
/// quiet, finishing it removes its worktrees, ends it and marks it done in
/// the harness.
struct SessionFinishSection: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    @State private var confirming = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let finished = sessions.isFinished(session.id)
        let stale = sessions.isStale(session)
        if !session.isHelper, finished || stale {
            Section {
                Text(finished
                     ? "Every pull request from this session is merged."
                     : "Nothing's happened in this session for over three days.")
                    .font(.callout)
                HStack {
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                    }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Finish Session") { confirming = true }
                        .disabled(working)
                }
            } header: {
                Text(finished ? "Done" : "Stale")
            }
            .confirmationDialog("Finish this session?", isPresented: $confirming) {
                Button("Finish and Remove Worktrees", role: .destructive) {
                    working = true
                    Task {
                        do {
                            try await sessions.finish(session.id)
                        } catch {
                            self.error = error.localizedDescription
                        }
                        working = false
                    }
                }
            } message: {
                Text("Claude and any helpers are ended, the worktrees in \(SessionStore.worktreePath(for: session))\(session.isRemote ? " on the server" : "") are removed with anything not pushed in them, \(session.harnessFolder != nil ? "its session.json in the harness is marked finished, " : "")and Gannin forgets the session.")
            }
        }
    }
}

/// Settings > General: the editor files open in, and the saved prompts.
struct SessionPromptSettingsSection: View {
    @AppStorage(CodeEditor.key) private var editor: CodeEditor = .vscode
    @State private var snippets = PromptSnippet.saved

    var body: some View {
        Section {
            Picker("Open files in", selection: $editor) {
                ForEach(CodeEditor.allCases) { Text($0.name).tag($0) }
            }
            Text(editor.opensRemote ? "Files of a session on a server open there through \(editor.name)'s SSH remote." : "Xcode only opens files on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach($snippets) { $snippet in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Name", text: $snippet.title)
                            .fontWeight(.medium)
                        Button {
                            snippets.removeAll { $0.id == snippet.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this prompt")
                    }
                    TextField("Prompt", text: $snippet.prompt, axis: .vertical)
                        .lineLimit(1...4)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Add Prompt") { snippets.append(PromptSnippet(title: "New prompt", prompt: "")) }
                Spacer()
                Button("Restore Defaults") { snippets = PromptSnippet.defaults }
            }
        } header: {
            Text("Prompts")
        } footer: {
            Text("Sent from the menu under a session's terminal, the first nine with ⌃1 to ⌃9.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: snippets) { PromptSnippet.saved = snippets }
    }
}
#endif
