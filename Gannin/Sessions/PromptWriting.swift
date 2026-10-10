import SwiftUI

/// Writing one of Settings' prompts by talking it through with Claude
/// (andrew-waters/gannin#145): house rules for sandboxes, saved prompts and
/// the org's drafting guidance. Claude asks what it needs, drafts the whole
/// text and refines it; nothing reaches the setting until Use This Draft.
/// One `claude -p` conversation per sheet (`ClaudeRunner`, `--resume`), run
/// as you with no tools, forgotten when the sheet closes.
enum PromptWriting {
    /// What's being written, for Claude and for the sheet.
    struct Purpose {
        /// "house rules for Claude in sandboxes", after "write".
        let name: String
        /// What it is and where it goes.
        let about: String
        /// What makes a good one.
        let guidance: String
        /// The first message's placeholder.
        let placeholder: String
        /// Text Claude can compare against, such as Gannin's default.
        var reference: String?
        /// It has a name as well, which Claude may suggest.
        var titled = false

        static let houseRules = Purpose(
            name: "house rules for Claude in sandboxes",
            about: "They're my own rules for Claude Code in every sandboxed session (a Linux VM per issue), written to a file each sandbox's shared CLAUDE.md imports, as I'd keep them in ~/.claude/CLAUDE.md on my Mac: how to write commits and pull requests, attribution, style, anything every session should follow whatever the repo.",
            guidance: "Keep them short and specific: rules Claude can follow, in Markdown, under a few headings if there are many. Leave out @ imports (a sandbox can't read files on my Mac), secrets and tokens, and anything about one repo, which that repo's own CLAUDE.md is for.",
            placeholder: "Conventional commits, British English, no emoji in pull requests"
        )

        static let savedPrompt = Purpose(
            name: "a saved prompt",
            about: "Saved prompts are sent as they are to a Claude Code session already working on an issue, from the menu under its terminal or with ⌃1 to ⌃9, such as \"Run the tests for what you've changed, and fix anything that fails.\" Any session can be sent one, on any repo.",
            guidance: "Write it as a direct instruction to the agent, usually a sentence or two: what to do and what done looks like. Don't name an issue, repo or file, since it's reused everywhere. Give it a short name too, for the menu.",
            placeholder: "Look at the failing checks and fix them",
            titled: true
        )

        /// The org's guidance for drafting a kind of harness document, or a
        /// planning session's first prompt (Settings › Harness).
        static func authoring(_ kind: HarnessKind) -> Purpose {
            let placeholders = HarnessAuthoring.placeholders(kind).joined(separator: ", ")
            let about = kind == .plans
                ? "It's a planning session's first prompt, which Gannin sends to Claude Code when a team starts Plan with Claude in its harness. Prompts picked from the team's library are added after it."
                : "It's what Claude is told when it drafts a new \(kind.singular) for the team's harness. Gannin adds what was asked for, what's written so far, the harness's CLAUDE.md, STANDARDS.md and the folder's README and template, the \(kind.rawValue.lowercased()) already there, and the JSON reply it reads."
            return Purpose(
                name: kind == .plans ? "a planning session's first prompt" : "the guidance Claude follows when it drafts a \(kind.singular)",
                about: about,
                guidance: "Write it as instructions to Claude, in the second person, as Gannin's default does. \(placeholders) are filled in; use them where they help.\(kind == .plans ? "" : " Don't ask for a reply format: Gannin adds that.")",
                placeholder: kind == .plans ? "Start from the customer's problem, and keep the first plan small" : "Always say how to check the result",
                reference: HarnessAuthoring.defaultGuidance(kind)
            )
        }
    }

    /// Claude's reply: what it says, and the whole draft when it wrote one.
    struct Reply: Decodable, Equatable {
        var message: String?
        var draft: String?
        var title: String?
    }

    /// The first message: what it's for, what's there, what I want and the
    /// reply.
    static func firstPrompt(_ purpose: Purpose, ask: String, current: String, title: String? = nil) -> String {
        var parts = [
            "You're helping me write \(purpose.name) for Gannin, a Mac app that runs Claude Code sessions. \(purpose.about)",
            purpose.guidance,
            "This is a conversation. If something that matters is unclear, ask me first (a few short questions at most) in `message`, and leave `draft` out until I've answered. Once you can, write the whole text in `draft` and say briefly in `message` what you did and anything I should check. Later messages from me are answers or changes: work from the draft I send, since I may have edited it. You don't need any tools; everything is here.",
        ]
        if let reference = purpose.reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty,
           reference != current.trimmingCharacters(in: .whitespacesAndNewlines) {
            parts.append("Gannin's default, for reference:\n\n\(reference)")
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(trimmed.isEmpty ? "Nothing's written yet." : "What's there now, to improve on rather than start over:\n\n\(trimmed)")
        if purpose.titled, let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            parts.append("Its name now: \(title)")
        }
        parts.append("What I want:\n\n\(ask.trimmingCharacters(in: .whitespacesAndNewlines))")
        parts.append("Reply with only JSON, no preamble: \(replyShape(purpose)).")
        return parts.joined(separator: "\n\n")
    }

    /// A later message, with the draft as it stands.
    static func followUp(_ text: String, current: String, title: String? = nil) -> String {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        parts.append(trimmed.isEmpty ? "The draft is empty now." : "The draft as it stands (I may have edited it):\n\n\(trimmed)")
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { parts.append("Its name: \(title)") }
        parts.append("Reply with only the JSON, as before.")
        return parts.joined(separator: "\n\n")
    }

    private static func replyShape(_ purpose: Purpose) -> String {
        purpose.titled
            ? #"{"message": "what you say to me", "draft": "the whole text, only when you've written or changed it", "title": "a short name, only when you've a better one"}"#
            : #"{"message": "what you say to me", "draft": "the whole text, only when you've written or changed it"}"#
    }

    /// The reply's JSON, or, when it's only talking, all of it as said.
    static func reply(in text: String) -> Reply {
        if let parsed = ClaudeRunner.json(Reply.self, in: text), parsed.message != nil || parsed.draft != nil || parsed.title != nil {
            return parsed
        }
        return Reply(message: text)
    }
}

/// The button beside a prompt in Settings, opening `PromptWritingSheet`
/// over the Settings window (never the Claude Code window).
struct WriteWithClaudeButton: View {
    let purpose: PromptWriting.Purpose
    /// What's there now, which the draft starts from.
    let text: String
    var title: String?
    /// An icon alone, for a row in a list.
    var compact = false
    /// Called only on Use This Draft: the draft, and a name when it's titled.
    let apply: (String, String?) -> Void
    @State private var showing = false

    var body: some View {
        Group {
            if compact {
                Button {
                    showing = true
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.borderless)
            } else {
                Button("Write with Claude…") { showing = true }
            }
        }
        .help("Write \(purpose.name) by talking it through with Claude; nothing changes until you use the draft")
        .sheet(isPresented: $showing) {
            PromptWritingSheet(purpose: purpose, initial: text, initialTitle: title, apply: apply)
        }
    }
}

/// The conversation on the left, the draft (editable) on the right. Use
/// This Draft writes it to the setting; Cancel leaves the setting as it was.
struct PromptWritingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let purpose: PromptWriting.Purpose
    let apply: (String, String?) -> Void

    struct Turn: Identifiable {
        let id = UUID()
        let fromClaude: Bool
        let text: String
    }

    @State private var draft: String
    @State private var title: String
    private let initial: String
    private let initialTitle: String
    @State private var message = ""
    @State private var turns: [Turn] = []
    @State private var working = false
    @State private var conversation = UUID()
    /// Claude has answered once, so there's a conversation to go on with.
    @State private var started = false
    @State private var confirmingCancel = false

    init(purpose: PromptWriting.Purpose, initial: String, initialTitle: String?, apply: @escaping (String, String?) -> Void) {
        self.purpose = purpose
        self.apply = apply
        self.initial = initial
        _draft = State(initialValue: initial)
        self.initialTitle = initialTitle ?? ""
        _title = State(initialValue: initialTitle ?? "")
    }

    private var changed: Bool { draft != initial || title != initialTitle || turns.contains { $0.fromClaude } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                conversationPane
                    .frame(minWidth: 340, idealWidth: 400)
                Divider()
                draftPane
                    .frame(minWidth: 380, idealWidth: 460)
            }
            Divider()
            HStack {
                Text("Runs through your own Claude Code. Nothing changes until you use the draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    if changed { confirmingCancel = true } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Use This Draft") {
                    apply(draft, purpose.titled ? title.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
                    dismiss()
                }
                .disabled(working || (draft == initial && title == initialTitle))
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 520)
        .confirmationDialog("Discard this conversation and draft?", isPresented: $confirmingCancel) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Writing", role: .cancel) {}
        } message: {
            Text("The setting stays as it was.")
        }
    }

    private var conversationPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Write \(purpose.name) with Claude")
                .font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if turns.isEmpty {
                            Text(initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? "Say what you want it to cover. Claude asks what it needs to know, then drafts it on the right."
                                 : "Say what you'd like changed, or ask Claude to look it over. It starts from what's there now.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(turns) { turn in
                            bubble(turn).id(turn.id)
                        }
                        if working {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Claude is thinking").foregroundStyle(.secondary)
                            }
                            .id("working")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: turns.count) {
                    withAnimation { proxy.scrollTo(turns.last?.id, anchor: .bottom) }
                }
                .onChange(of: working) {
                    if working { withAnimation { proxy.scrollTo("working", anchor: .bottom) } }
                }
            }
            TextField("Message", text: $message, prompt: Text(turns.isEmpty ? purpose.placeholder : "Answer, or say what to change"), axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit { send(message) }
            HStack {
                Button(turns.isEmpty ? "Start" : "Send") { send(message) }
                    .disabled(working || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if turns.isEmpty && !initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Look It Over") {
                        send("Look over what's there and suggest how to make it better. Ask me anything you need to know first.")
                    }
                    .disabled(working)
                }
                Spacer()
                if !turns.isEmpty {
                    Button("Start Over") {
                        turns = []
                        conversation = UUID()
                        started = false
                    }
                    .disabled(working)
                    .help("Forget this conversation; the draft stays")
                }
            }
        }
        .padding(16)
    }

    private var draftPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Draft")
                .font(.headline)
            if purpose.titled {
                TextField("Name", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            TextEditor(text: $draft)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.separatorLine))
            HStack {
                Text(draft == initial ? "As it is in Settings" : "Changed; edit it here too")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { draft = initial }
                    .disabled(draft == initial || working)
                    .help("Put back what's in Settings")
            }
        }
        .padding(16)
    }

    private func bubble(_ turn: Turn) -> some View {
        HStack {
            if !turn.fromClaude { Spacer(minLength: 40) }
            Text(turn.text)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(turn.fromClaude ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            if turn.fromClaude { Spacer(minLength: 40) }
        }
    }

    private func send(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !working else { return }
        message = ""
        let isFirst = !started
        turns.append(Turn(fromClaude: false, text: text))
        working = true
        let named = purpose.titled ? title : nil
        let prompt = isFirst
            ? PromptWriting.firstPrompt(purpose, ask: turns.filter { !$0.fromClaude }.map(\.text).joined(separator: "\n\n"), current: draft, title: named)
            : PromptWriting.followUp(text, current: draft, title: named)
        Task {
            defer { working = false }
            do {
                let answer = try await ClaudeRunner.ask(
                    prompt, org: "", folder: "gannin-prompt-\(conversation.uuidString)",
                    session: (conversation.uuidString.lowercased(), !isFirst)
                )
                started = true
                let reply = PromptWriting.reply(in: answer)
                if let value = reply.draft { draft = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                if purpose.titled, let value = reply.title, !value.isEmpty { title = value }
                turns.append(Turn(fromClaude: true, text: reply.message ?? (reply.draft != nil ? "Drafted. Check it over on the right." : "No changes.")))
            } catch {
                turns.append(Turn(fromClaude: true, text: error.localizedDescription))
                // A first message that failed starts afresh next time.
                if isFirst { conversation = UUID() }
            }
        }
    }
}
