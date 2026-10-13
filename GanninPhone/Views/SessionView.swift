import GanninRemote
import SwiftUI

/// One session: what it's waiting on, and the controls to answer it, message it, stop it
/// and switch its mode.
struct SessionView: View {
    let client: RemoteClient
    let sessionID: String
    @State private var message = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var confirmingInterrupt = false

    var body: some View {
        Group {
            if let session = client.state.session(id: sessionID) {
                content(session)
            } else {
                ContentUnavailableView("This session has ended", systemImage: "checkmark.circle")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ session: RemoteSession) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.headline)
                    Text("\(session.kind) · \(session.reference)").font(.caption).foregroundStyle(.secondary)
                    Label(session.state.label, systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(session.state.color)
                }
                if let last = session.lastMessage, session.prompt == nil {
                    Text(last).font(.callout).foregroundStyle(.secondary)
                }
            }

            promptSection(session)

            if let notice {
                Section { Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }

            Section("Send a message") {
                TextField("Message to Claude", text: $message, axis: .vertical)
                    .lineLimit(1...5)
                Button("Send") {
                    let text = message
                    perform(.prompt(text: text)) { message = "" }
                }
                .disabled(busy || message.allSatisfy(\.isWhitespace) || !isRunning(session))
            }

            Section {
                HStack {
                    modeButton("Attended", .attended, session)
                    modeButton("Unattended", .unattended, session)
                }
                if session.mode == .other {
                    Text("Claude is in \(session.modeLabel).").font(.caption).foregroundStyle(.secondary)
                }
                if session.prompt != nil {
                    Text("Answer the prompt before changing the mode.").font(.caption).foregroundStyle(.secondary)
                } else if !session.canGoUnattended {
                    Text("Unattended isn't available in this session's Claude Code.").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Mode")
            }

            Section {
                Button("Interrupt", role: .destructive) { confirmingInterrupt = true }
                    .disabled(busy || !isRunning(session))
            }
        }
        .confirmationDialog("Interrupt this session?", isPresented: $confirmingInterrupt, titleVisibility: .visible) {
            Button("Interrupt", role: .destructive) { perform(.interrupt) }
        } message: {
            Text("Claude stops what it's doing. The conversation stays.")
        }
        .disabled(client.phase != .connected)
        .overlay(alignment: .top) {
            if client.phase != .connected {
                Text("Not connected").font(.caption).padding(6).background(.thinMaterial, in: Capsule()).padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func promptSection(_ session: RemoteSession) -> some View {
        if let prompt = session.prompt {
            switch prompt {
            case .question(let id, let items):
                QuestionCard(items: items, busy: busy) { answers in
                    perform(.answer(answers: answers), promptID: id)
                }
                .id(id)
            case .permission(let id, let tool, let command, let truncated, let choices):
                PermissionCard(tool: tool, command: command, truncated: truncated, choices: choices, busy: busy) { number in
                    perform(.choose(number: number), promptID: id)
                } deny: {
                    perform(.deny, promptID: id)
                }
                .id(id)
            }
        } else if session.state == .needsYou {
            Section { ProgressView("Waiting for the prompt…") }
        }
    }

    private func modeButton(_ title: String, _ mode: RemoteMode, _ session: RemoteSession) -> some View {
        let selected = session.mode == mode
        let allowed = session.prompt == nil && (mode != .unattended || session.canGoUnattended) && isRunning(session)
        return Button(title) { perform(.setMode(mode: mode)) }
            .buttonStyle(.bordered)
            .tint(selected ? .accentColor : .gray)
            .disabled(busy || selected || !allowed)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func isRunning(_ session: RemoteSession) -> Bool {
        session.state != .exited && session.state != .stopped
    }

    private func perform(_ intent: RemoteIntent, promptID: String? = nil, onOK: @escaping () -> Void = {}) {
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                switch try await client.perform(intent, session: sessionID, promptID: promptID) {
                case .ok:
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onOK()
                case .refused(let reason):
                    notice = reason.explanation
                }
            } catch {
                notice = error.localizedDescription
            }
        }
    }
}
