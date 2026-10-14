import GanninRemote
import SwiftUI

/// A permission prompt: the tool and the whole command Claude wants to run, then the
/// prompt's own choices. Deny is last and never the default.
struct PermissionCard: View {
    let tool: String
    let command: String
    let truncated: Bool
    let choices: [RemoteChoice]
    let busy: Bool
    let choose: (Int) -> Void
    let deny: () -> Void

    var body: some View {
        Section("Claude wants to use \(tool)") {
            if !command.isEmpty {
                ScrollView(.horizontal) {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
                if truncated {
                    Label("The command is longer than this. Check it on your Mac before allowing.", systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if choices.isEmpty {
                ProgressView("Waiting for the prompt…")
            }
            ForEach(choices, id: \.number) { choice in
                Button(choice.label) { choose(choice.number) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
            Button("Deny", role: .destructive, action: deny)
                .buttonStyle(.bordered)
                .disabled(busy)
        }
    }
}

/// An AskUserQuestion: each question's options to pick, or an answer of your own.
struct QuestionCard: View {
    let items: [RemoteQuestionItem]
    let busy: Bool
    let send: ([RemoteAnswer]) -> Void
    @State private var picks: [Int: Set<Int>] = [:]
    @State private var other: [Int: String] = [:]

    var body: some View {
        ForEach(items.indices, id: \.self) { index in
            let item = items[index]
            Section(item.header.isEmpty ? "Question" : item.header) {
                Text(item.question).font(.headline)
                ForEach(item.options.indices, id: \.self) { option in
                    Button { toggle(option, in: index, multi: item.multiSelect) } label: {
                        HStack(alignment: .top) {
                            Image(systemName: picks[index, default: []].contains(option) ? (item.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle") : (item.multiSelect ? "square" : "circle"))
                            VStack(alignment: .leading) {
                                Text(item.options[option].label)
                                if !item.options[option].description.isEmpty {
                                    Text(item.options[option].description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                TextField("Other", text: Binding(
                    get: { other[index, default: ""] },
                    set: { text in
                        other[index] = text
                        if !item.multiSelect, !text.isEmpty { picks[index] = [] }
                    }
                ))
            }
        }
        Section {
            Button("Send answer") {
                let answers = items.indices.compactMap { index in
                    answer(for: index).map { RemoteAnswer(question: items[index].question, answer: $0) }
                }
                send(answers)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || items.indices.contains { answer(for: $0) == nil })
        }
    }

    private func toggle(_ option: Int, in index: Int, multi: Bool) {
        if multi {
            if picks[index, default: []].contains(option) { picks[index]?.remove(option) } else { picks[index, default: []].insert(option) }
        } else {
            picks[index] = [option]
            other[index] = ""
        }
    }

    /// The picked options' labels and anything typed, or nil while the question has neither.
    private func answer(for index: Int) -> String? {
        var parts = picks[index, default: []].sorted().map {
            items[index].options[$0].label.replacingOccurrences(of: " (Recommended)", with: "")
        }
        let typed = other[index, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append(typed) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
