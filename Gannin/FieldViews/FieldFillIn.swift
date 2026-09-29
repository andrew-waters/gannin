import SwiftUI

/// Fill In: the issues missing a board field, one at a time, each given a
/// value with a click or its number key (Next and Previous with the arrows).
/// Choices collect until Review and Write, which confirms every change
/// before anything is written.
struct FieldFillIn: View {
    struct Request: Identifiable {
        let id = UUID()
        let field: String
        let issues: [IssueRecord]
    }

    @Environment(DetailStore.self) private var details
    @Environment(\.openURL) private var openURL

    let org: String
    let request: Request
    let board: Board?
    let onClose: () -> Void

    @State private var index = 0
    /// Chosen values by issue ID.
    @State private var chosen: [String: String] = [:]
    @State private var reviewing: [FieldChange]?

    var body: some View {
        if let reviewing {
            FieldWriteSheet(org: org, changes: reviewing, board: board, onClose: onClose)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if request.issues.indices.contains(index) {
                    card(request.issues[index])
                } else {
                    finished
                }
                Divider()
                footer
            }
            .frame(width: 680, height: 600)
        }
    }

    private var options: [BoardOption] {
        board?.field(named: request.field)?.options ?? []
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            Text("Fill In \(request.field)").font(.title3.weight(.semibold))
            Spacer()
            Text("\(min(index + 1, request.issues.count)) of \(request.issues.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            ProgressView(value: Double(min(index, request.issues.count)), total: Double(max(request.issues.count, 1)))
                .frame(width: 120)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { index = max(0, index - 1) } label: { Label("Previous", systemImage: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(index == 0)
            Button { index = min(request.issues.count, index + 1) } label: { Label("Next", systemImage: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(index >= request.issues.count)
            Spacer()
            if !chosen.isEmpty {
                Text(chosen.count == 1 ? "1 to write" : "\(chosen.count) to write").foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel, action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("Review and Write") {
                reviewing = request.issues.compactMap { issue in
                    chosen[issue.id].map { FieldChange(issue: issue, field: request.field, value: $0) }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(chosen.isEmpty)
        }
        .padding(16)
    }

    // MARK: The issue

    private func card(_ issue: IssueRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(verbatim: "\(issue.repo)#\(issue.number)").foregroundStyle(.secondary)
                        if let type = issue.issueType { Pill(text: type, color: .secondary) }
                        Spacer()
                        Button("Open on GitHub") { openURL(issue.url) }.linkButton()
                    }
                    .font(.callout)
                }
                otherFields(issue)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { offset, option in
                        optionButton(option, number: offset + 1, issue: issue)
                    }
                }
                if options.isEmpty {
                    Text("The board's options for \(request.field) haven't loaded.").foregroundStyle(.secondary)
                }
                if let body = details.detail(for: issue.id)?.body, !body.isEmpty {
                    Divider()
                    MarkdownText(source: String(body.prefix(4000)))
                        .font(.callout)
                }
            }
            .padding(16)
        }
        .task(id: issue.id) { await details.load(issue.id) }
    }

    /// The issue's other values on the board, for context.
    private func otherFields(_ issue: IssueRecord) -> some View {
        let values = (board.flatMap { issue.fields(onProject: $0.number)?.values } ?? [:])
            .filter { $0.key != request.field }
            .sorted { $0.key < $1.key }
        return HStack(spacing: 12) {
            ForEach(values, id: \.key) { name, value in
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                    Text(value.display).font(.callout).lineLimit(1)
                }
            }
        }
    }

    private func optionButton(_ option: BoardOption, number: Int, issue: IssueRecord) -> some View {
        let isChosen = chosen[issue.id] == option.name
        return Button {
            chosen[issue.id] = option.name
            index += 1
        } label: {
            HStack(spacing: 8) {
                Circle().fill(BoardLayout.color(option.color)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name).lineLimit(1)
                    if let description = option.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if number <= 9 {
                    Text(verbatim: "\(number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isChosen ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(number <= 9 ? KeyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: []) : nil)
    }

    private var finished: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text("That's the lot.").font(.title3)
            Text(chosen.isEmpty ? "Nothing chosen. Use Previous to pick up any you passed." : "Review and Write shows the changes before anything is written to GitHub.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
