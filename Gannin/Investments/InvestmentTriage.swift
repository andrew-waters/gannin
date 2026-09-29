import SwiftUI

/// Assign to Categories: a queue of issues, one at a time, each put in a
/// category with a click or its number key (Next and Previous with the arrows).
/// The rules' suggestion is marked. Tracked in Gannin, each choice applies
/// at once; tracked in GitHub, choices collect until Review and Write, which
/// shows every change before making it.
struct InvestmentTriage: View {
    struct Queue: Identifiable {
        let id = UUID()
        let issues: [IssueRecord]
    }

    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var issueStore
    @Environment(DetailStore.self) private var details
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let org: String
    let queue: Queue

    @State private var index = 0
    /// Chosen categories by issue ID, waiting to be written when tracked in
    /// GitHub (applied at once in Gannin, but kept for the count).
    @State private var chosen: [String: UUID] = [:]
    @State private var reviewing: InvestmentPrompt.Pending?
    /// Whether the description is open; stays open from issue to issue.
    @AppStorage("triageShowsDescription") private var showsDescription = false

    var body: some View {
        Group {
            if let reviewing {
                InvestmentConfirmation(pending: reviewing) {
                    self.reviewing = nil
                    dismiss()
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    if queue.issues.indices.contains(index) {
                        card(queue.issues[index])
                    } else {
                        finished
                    }
                    Divider()
                    footer
                }
                .frame(width: 680, height: 640)
            }
        }
    }

    private var config: InvestmentConfig { configs.config(for: org).investmentConfig }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            Text("Assign to Categories").font(.title3.weight(.semibold))
            Spacer()
            Text("\(min(index + 1, queue.issues.count)) of \(queue.issues.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            ProgressView(value: Double(min(index, queue.issues.count)), total: Double(max(queue.issues.count, 1)))
                .frame(width: 120)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { index = max(0, index - 1) } label: { Label("Previous", systemImage: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(index == 0)
            Button { index = min(queue.issues.count, index + 1) } label: { Label("Next", systemImage: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(index >= queue.issues.count)
            Spacer()
            Text(chosenSummary).foregroundStyle(.secondary)
            if config.trackedBy.writesToGitHub {
                Button("Review and Write") { review() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private var chosenSummary: String {
        guard !chosen.isEmpty else { return "" }
        let count = chosen.count == 1 ? "1 issue" : "\(chosen.count) issues"
        return config.trackedBy.writesToGitHub ? "\(count) to write" : "\(count) assigned"
    }

    // MARK: The issue

    private func card(_ issue: IssueRecord) -> some View {
        let parent = issue.parentID.flatMap { issueStore.history(for: org)?.issues[$0] }
        let suggestion = config.suggest(issue) ?? parent.flatMap(config.suggest)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(issue.title)
                        .font(.title3.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        openURL(issue.url)
                    } label: {
                        Label("Open on GitHub", systemImage: "arrow.up.right.square")
                    }
                    .keyboardShortcut("o", modifiers: .command)
                    .help("Open \(issue.repo)#\(issue.number) on GitHub (⌘O)")
                }
                HStack(spacing: 6) {
                    Text("\(issue.repo)#\(String(issue.number))")
                    if let closedAt = issue.closedAt {
                        Text("· completed")
                        RelativeDate(date: closedAt)
                    } else {
                        Text("· open")
                    }
                    if !issue.assignees.isEmpty {
                        Text("· \(issue.assignees.joined(separator: ", "))")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            facts(issue, parent: parent)
            description(issue)
            VStack(alignment: .leading, spacing: 8) {
                Text("Category").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(config.categories.enumerated()), id: \.element.id) { offset, category in
                        categoryButton(category, number: offset + 1, issue: issue, suggested: suggestion?.id == category.id)
                    }
                }
                if let suggestion {
                    Text("Suggested by the rules: \(suggestion.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    /// The issue's body, fetched when first opened and kept with the other
    /// details; scrolls within the card when long.
    private func description(_ issue: IssueRecord) -> some View {
        DisclosureGroup(isExpanded: $showsDescription) {
            Group {
                if let detail = details.detail(for: issue.id) {
                    if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No description.").foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            MarkdownText(source: detail.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 220)
                    }
                } else if let error = details.errors[issue.id] {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 6)
            .task(id: issue.id) { await details.load(issue.id) }
        } label: {
            Text("Description").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    /// Labels, type, milestone and parent: what a category is usually read from.
    private func facts(_ issue: IssueRecord, parent: IssueRecord?) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            if !issue.labels.isEmpty {
                GridRow {
                    Text("Labels").foregroundStyle(.secondary)
                    Text(issue.labels.joined(separator: ", "))
                }
            }
            if let type = issue.issueType {
                GridRow {
                    Text("Type").foregroundStyle(.secondary)
                    Text(type)
                }
            }
            if let milestone = issue.milestone {
                GridRow {
                    Text("Milestone").foregroundStyle(.secondary)
                    Text(milestone)
                }
            }
            if let parent {
                GridRow {
                    Text("Parent").foregroundStyle(.secondary)
                    Text("\(parent.title) (#\(String(parent.number)))").lineLimit(1)
                }
            }
            if issue.labels.isEmpty && issue.issueType == nil && issue.milestone == nil && parent == nil {
                GridRow {
                    Text("No labels, type, milestone or parent.").foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
            }
        }
        .font(.callout)
    }

    private func categoryButton(_ category: InvestmentCategory, number: Int, issue: IssueRecord, suggested: Bool) -> some View {
        let isChosen = chosen[issue.id] == category.id
        let missingValue = config.trackedBy.writesToGitHub && (category.githubValue ?? "").isEmpty
        return Button {
            choose(category, for: issue)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(ChartPalette.slot(category.slot))
                    .frame(width: 12, height: 12)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.name).lineLimit(1)
                    if !category.details.isEmpty {
                        Text(category.details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if number <= 9 {
                    Text("\(number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isChosen ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if suggested { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1.5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(number <= 9 ? KeyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: []) : nil)
        .disabled(missingValue)
        .help(missingValue ? "Set this category's \(config.trackedBy.valueName.lowercased()) in Settings first" : "")
    }

    private var finished: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text("That's the lot.").font(.title3)
            Text(chosen.isEmpty
                 ? "Nothing assigned. Use Previous to pick up any you passed."
                 : config.trackedBy.writesToGitHub ? "Review and Write shows the changes before anything is written to GitHub." : "Your choices are saved.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Choosing

    private func choose(_ category: InvestmentCategory, for issue: IssueRecord) {
        chosen[issue.id] = category.id
        if !config.trackedBy.writesToGitHub {
            configs.setCategory(category.id, for: issue.id, in: org)
        }
        index += 1
    }

    /// Every GitHub change the choices need, for confirming.
    private func review() {
        let config = config
        let changes = queue.issues.compactMap { issue -> InvestmentChange? in
            guard let id = chosen[issue.id], let category = config.category(id: id) else { return nil }
            return InvestmentChange.plan(issue, to: category, config: config)
        }
        guard !changes.isEmpty else {
            dismiss()
            return
        }
        reviewing = InvestmentPrompt.Pending(org: org, tracking: config.trackedBy, changes: changes)
    }
}
