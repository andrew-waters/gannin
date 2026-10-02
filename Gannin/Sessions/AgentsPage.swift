#if os(macOS)
import SwiftUI

/// Claude Code › Agents in the main window: what the org's agents want from
/// you, without their terminals. Each one waiting shows its issue, what
/// claude said leading up to it, what it's been doing, and the question
/// with its answers, or a box to reply when it's your turn. Those working
/// are listed beneath, with what they're on.
struct AgentsPage: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    let org: String
    @State private var planning = false

    var body: some View {
        let all = sessions.sessions(for: org)
        let waiting = all.filter { isWaiting($0) }
            .sorted { (sessions.attention[$0.id] ?? .distantFuture) < (sessions.attention[$1.id] ?? .distantFuture) }
        let working = all.filter { !isWaiting($0) && sessions.isRunning($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ReviewRequestsSection(org: org)
                if waiting.isEmpty {
                    ContentUnavailableView(
                        "Nothing waiting on you",
                        systemImage: "checkmark.bubble",
                        description: Text(working.isEmpty
                                          ? "When an agent asks something or finishes its turn, it shows here with what led up to it."
                                          : "\(working.count == 1 ? "One agent is" : "\(working.count) agents are") working. When one asks something or finishes its turn, it shows here.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(waiting) { session in
                        WaitingAgent(session: session)
                    }
                }
                if !working.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Working")
                            .font(.headline)
                        ForEach(working) { session in
                            WorkingAgentRow(session: session)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    planning = true
                } label: {
                    Label("New Planning Session", systemImage: "list.bullet.clipboard")
                }
                .help("Plan something with Claude in the harness, sharing documents as you go")
            }
        }
        .sheet(isPresented: $planning) { NewPlanningSheet(org: org) }
    }

    private func isWaiting(_ session: CodeSession) -> Bool {
        guard sessions.isRunning(session.id) else { return false }
        return SessionQuestionCard.isAsking(session, in: sessions) || sessions.attention[session.id] != nil
    }
}

/// One agent waiting on you, with the context to answer it here.
private struct WaitingAgent: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    let session: CodeSession
    @State private var reply = ""
    @State private var showsActivity = false

    var body: some View {
        let transcript = sessions.transcripts[session.id]
        let asking = SessionQuestionCard.isAsking(session, in: sessions)
        VStack(alignment: .leading, spacing: 12) {
            header(transcript)
            if let said = context(transcript) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude said")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        MarkdownText(source: said)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
            }
            if let transcript, !recentTools(transcript).isEmpty {
                DisclosureGroup(isExpanded: $showsActivity) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(recentTools(transcript)) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if case .tool(let name) = event.kind {
                                    Text(name).font(.caption.weight(.medium))
                                }
                                Text(event.text)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(event.failed == true ? ChartPalette.critical : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("What it's been doing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if asking {
                SessionQuestionCard(session: session)
            } else {
                replyBox
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(Color.separatorLine)
        }
    }

    private func header(_ transcript: SessionTranscript?) -> some View {
        let state = sessions.state(session.id)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(state.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(String(session.issue.number)) \(session.title)")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(state.label)
                    if let since = sessions.attention[session.id] {
                        Text("waiting \(since.formatted(.relative(presentation: .named)))")
                    }
                    if let transcript, !transcript.filesEdited.isEmpty {
                        Text("\(transcript.filesEdited.count) files edited")
                    }
                    ForEach(sessions.pullRequestInfo[session.parentID ?? session.id] ?? []) { pr in
                        let failing = pr.state == "OPEN" && !pr.failed.isEmpty
                        Text("\(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo)#\(pr.number)\(failing ? " failing" : "")")
                            .foregroundStyle(failing ? ChartPalette.critical : .secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Session") { sessions.show(session.id, with: openWindow) }
        }
    }

    /// When it's your turn: say something back, or send a saved prompt.
    private var replyBox: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                ForEach(PromptSnippet.saved) { snippet in
                    Button(snippet.title) { sessions.submit(snippet.prompt, to: session.id) }
                }
            } label: {
                Image(systemName: "text.badge.plus")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Send a saved prompt")
            TextField("Reply to claude", text: $reply, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .onSubmit(send)
            Button("Send", action: send)
                .buttonStyle(.borderedProminent)
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, sessions.submit(text, to: session.id) else { return }
        reply = ""
    }

    /// Claude's last words before it stopped or asked.
    private func context(_ transcript: SessionTranscript?) -> String? {
        guard let reply = transcript?.events.last(where: { $0.kind == .reply })?.text, !reply.isEmpty else { return nil }
        return reply
    }

    /// The last few tools it ran this turn.
    private func recentTools(_ transcript: SessionTranscript) -> [SessionTranscript.Event] {
        let sinceYou = transcript.events.lastIndex { $0.kind == .prompt }.map { transcript.events.index(after: $0) } ?? transcript.events.startIndex
        return Array(transcript.events[sinceYou...].filter { if case .tool = $0.kind { return true } else { return false } }.suffix(8))
    }
}

/// An agent at work: what it's on now.
private struct WorkingAgentRow: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    let session: CodeSession

    var body: some View {
        let transcript = sessions.transcripts[session.id]
        let state = sessions.state(session.id)
        Button {
            sessions.show(session.id, with: openWindow)
        } label: {
            HStack(spacing: 8) {
                Circle().fill(state.color).frame(width: 8, height: 8)
                Text("#\(String(session.issue.number)) \(session.title)")
                    .lineLimit(1)
                Spacer()
                if let last = transcript?.events.last {
                    Text(last.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 360, alignment: .trailing)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
