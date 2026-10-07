import SwiftUI

/// The bar under a session's terminal: a box to tell it something (sent as a prompt, queued if it's
/// busy); saved prompts (⌃1 to ⌃9); Esc to stop it; how full its context
/// is, with /compact; and how its last test or build went.
struct SessionComposer: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    /// The side panel's toggle, when the tab has one.
    var panelShown: Binding<Bool>?
    @State private var text = ""
    @State private var snippets = PromptSnippet.saved
    @FocusState private var focused: Bool

    var body: some View {
        let running = sessions.isRunning(session.id)
        let transcript = sessions.transcripts[session.id]
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                snippetMenu(enabled: running)
                TextField("Tell claude something", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(!running)
                Button("Send", action: send)
                    .disabled(!running || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send it as a prompt. If claude is working, it reads it when it's done.")
                Button {
                    sessions.interrupt(session.id)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .disabled(!running || sessions.state(session.id) != .working)
                .help("Stop claude mid-turn (Esc), to say something else")
                if let transcript {
                    if let check = transcript.lastCheck { checkBadge(check) }
                    contextGauge(transcript, running: running)
                }
                if let panelShown {
                    Button {
                        panelShown.wrappedValue.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(panelShown.wrappedValue ? Color.accentColor : .secondary)
                    .help(panelShown.wrappedValue ? "Hide the side panel" : "Show the side panel")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(.bar)
        .onAppear { snippets = PromptSnippet.saved }
    }

    private func send() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, sessions.submit(prompt, to: session.id) else { return }
        text = ""
    }

    private func snippetMenu(enabled: Bool) -> some View {
        Menu {
            ForEach(Array(snippets.enumerated()), id: \.element.id) { index, snippet in
                let button = Button(snippet.title) { sessions.submit(snippet.prompt, to: session.id) }
                if index < 9 {
                    button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                } else {
                    button
                }
            }
            let library = session.harnessRepo.map { sessions.promptLibrary(org: session.org, setup: HarnessConfig(repo: $0)) }
            if let library, !library.offered(for: .session).isEmpty {
                Section("The team's prompts") {
                    ForEach(library.offered(for: .session)) { prompt in
                        Button(prompt.title) { sessions.submit(library.message(for: prompt, values: sessions.promptValues(for: session)), to: session.id) }
                    }
                }
            }
            Divider()
            SettingsLink { Text("Edit Prompts") }
        } label: {
            Image(systemName: "text.badge.plus")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!enabled)
        .help("Send a saved prompt (⌃1 to ⌃9). Edit them in Settings.")
    }

    private func checkBadge(_ check: SessionTranscript.Check) -> some View {
        Label(check.passed ? "Passed" : "Failed", systemImage: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(check.passed ? ChartPalette.good : ChartPalette.critical)
            .help("Last test or build claude ran\(check.at.map { ", \($0.formatted(.relative(presentation: .named)))" } ?? ""):\n\(check.command)")
    }

    private func contextGauge(_ transcript: SessionTranscript, running: Bool) -> some View {
        let share = transcript.contextShare ?? 0
        let color: Color = share > 0.85 ? ChartPalette.critical : share > 0.7 ? .orange : .secondary
        return Menu {
            Text("\(transcript.contextTokens ?? 0) of \(transcript.contextLimit) tokens")
            Button("Compact Now") { sessions.submit("/compact", to: session.id) }
                .disabled(!running)
        } label: {
            HStack(spacing: 4) {
                Gauge(value: min(share, 1)) { EmptyView() }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .scaleEffect(0.42)
                    .frame(width: 18, height: 18)
                    .tint(color)
                Text("\(Int((share * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(color)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("How full claude's context is. /compact summarises the conversation to make room.")
    }
}

/// What claude is waiting on you for, big enough to notice: its question
/// (each of several in turn, then Submit), its options as buttons with
/// their number key and description, the recommended one marked; or a
/// permission prompt, with what it wants to run. Answers are sent as the
/// keys that pick them in the terminal.
struct SessionQuestionCard: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    /// Floating over the terminal: a shadow, and a way to put it away.
    var onHide: (() -> Void)? = nil

    /// Whether there's anything to ask: a question, or a permission prompt.
    /// A permission prompt just approved hides at once, before the hook
    /// that would otherwise confirm it (`SessionStore.confirmApproval`).
    static func isAsking(_ session: CodeSession, in sessions: SessionStore) -> Bool {
        guard sessions.isRunning(session.id) else { return false }
        if sessions.transcripts[session.id]?.question != nil { return true }
        guard sessions.state(session.id) == .needsYou else { return false }
        if let tool = sessions.transcripts[session.id]?.pendingTool, sessions.optimisticApprovals[session.id] == tool.id { return false }
        return true
    }
    /// The options picked for each question, by its index.
    @State private var picked: [Int: Set<Int>] = [:]
    /// Answers of your own, by question.
    @State private var other: [Int: String] = [:]
    /// The permission or plan prompt's own choices, read off the terminal
    /// once it's drawn.
    @State private var choices: [PermissionChoice] = []

    var body: some View {
        let transcript = sessions.transcripts[session.id]
        VStack(alignment: .leading, spacing: 12) {
            if let question = transcript?.question {
                questionContent(question)
            } else {
                permissionContent(transcript?.pendingTool)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.7), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(onHide == nil ? 0 : 0.25), radius: 16, y: 4)
        .onChange(of: transcript?.question?.id, initial: true) {
            picked = [:]
            other = [:]
        }
    }

    // MARK: A question

    /// Every question at once, each with its options as tiles to pick (or
    /// your own words), then Send Answers: claude's dialog is closed and
    /// the answers go as one message pairing each question with its answer.
    /// Its menu isn't driven key by key, which is easy to get wrong. A lone
    /// question with one choice is sent as soon as an option's picked.
    @ViewBuilder
    private func questionContent(_ question: SessionTranscript.Question) -> some View {
        let items = question.items
        let instant = items.count == 1 && items.first?.multiSelect == false
        header(title: items.count == 1 ? "Claude is asking" : "Claude has \(items.count) questions", symbol: "questionmark.bubble.fill") { EmptyView() }
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !item.header.isEmpty {
                        Text(item.header)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                    }
                    Text(item.question)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if item.multiSelect {
                        Text("Pick any")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { option, choice in
                        optionTile(choice, isPicked: picked[index]?.contains(option) == true) {
                            if item.multiSelect {
                                picked[index, default: []].formSymmetricDifference([option])
                            } else {
                                picked[index] = [option]
                                other[index] = nil
                                if instant { send(question) }
                            }
                        }
                    }
                }
                TextField("Or say something else", text: Binding(
                    get: { other[index] ?? "" },
                    set: { text in
                        other[index] = text
                        if !text.isEmpty, !item.multiSelect { picked[index] = nil }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { if instant, !(other[index] ?? "").isEmpty { send(question) } }
            }
            if index < items.count - 1 { Divider() }
        }
        HStack {
            let answered = items.indices.filter { answer(items[$0], at: $0) != nil }.count
            Text(answered == items.count ? "Ready to send." : "\(answered) of \(items.count) answered. Any left go as \"your call\".")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Dismiss") { sessions.sendKeys("\u{1B}", to: session.id) }
                .help("Close the questions without answering (Esc), to say something else")
            if !instant || !(other[0] ?? "").isEmpty {
                Button("Send Answers") { send(question) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(answered == 0)
            }
        }
    }

    /// What's been picked or written for a question, as words.
    private func answer(_ item: SessionTranscript.Question.Item, at index: Int) -> String? {
        if let text = other[index]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        let labels = (picked[index] ?? []).sorted().compactMap { item.options.indices.contains($0) ? item.options[$0].label : nil }
            .map { $0.replacingOccurrences(of: " (Recommended)", with: "") }
        return labels.isEmpty ? nil : labels.joined(separator: "; ")
    }

    private func send(_ question: SessionTranscript.Question) {
        let answers = question.items.enumerated().map { index, item in
            (item.question, answer(item, at: index) ?? "No preference: your call.")
        }
        sessions.answer(answers, to: session.id)
        picked = [:]
        other = [:]
    }

    private func optionTile(_ option: SessionTranscript.Question.Option, isPicked: Bool, action: @escaping () -> Void) -> some View {
        let recommended = option.label.localizedCaseInsensitiveContains("(recommended)")
        let label = option.label.replacingOccurrences(of: " (Recommended)", with: "")
        return Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isPicked ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(label).fontWeight(.semibold)
                        if recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isPicked ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isPicked ? Color.accentColor : recommended ? Color.accentColor.opacity(0.5) : Color.separatorLine, lineWidth: isPicked ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: A permission prompt

    @ViewBuilder
    private func permissionContent(_ tool: SessionTranscript.Event?) -> some View {
        let name: String? = if case .tool(let name) = tool?.kind { name } else { nil }
        header(title: permissionTitle(name), symbol: "hand.raised.fill") { EmptyView() }
        if let tool, !tool.text.isEmpty {
            Text(tool.text)
                .font(.callout.monospaced())
                .lineLimit(8)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        } else {
            Text("Look at the terminal for what it wants to do.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        HStack {
            Spacer()
            Button("Deny") { sessions.sendKeys("\u{1B}", to: session.id) }
                .help("Esc: say no, then tell claude what to do instead")
            // Whatever the terminal's own prompt offers besides its first
            // and last choice: usually one way not to ask again, but
            // exiting plan mode offers something else entirely, and not
            // every prompt has a middle choice at all.
            ForEach(choices.dropFirst().dropLast()) { choice in
                Button(choice.label) { sessions.approvePermission(choice.number, for: session.id) }
                    .lineLimit(1)
                    .help("The prompt's choice \(choice.number)")
            }
            Button(choices.first?.label ?? "Allow") { sessions.approvePermission(choices.first?.number ?? 1, for: session.id) }
                .buttonStyle(.borderedProminent)
                .lineLimit(1)
                .help("Return, on the prompt's first choice")
        }
        .controlSize(.large)
        .task(id: tool?.id) {
            choices = []
            // The prompt can take a moment to draw after the hook that
            // flags it; a few short tries catch it without a fixed delay.
            for _ in 0..<6 {
                let found = sessions.permissionChoices(for: session.id)
                if !found.isEmpty {
                    choices = found
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func permissionTitle(_ tool: String?) -> String {
        switch tool {
        case "Bash": "Claude wants to run a command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "Claude wants to change a file"
        case "WebFetch", "WebSearch": "Claude wants to go online"
        case "ExitPlanMode": "Claude wants to leave planning and start making changes"
        case let tool?: "Claude wants to use \(tool)"
        case nil: "Claude needs your permission"
        }
    }

    // MARK: Parts

    private func header(title: String, symbol: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.orange)
            Text(title)
                .font(.headline)
            Spacer()
            trailing()
            if let onHide {
                Button(action: onHide) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Put this away and answer in the terminal")
            }
        }
    }
}
