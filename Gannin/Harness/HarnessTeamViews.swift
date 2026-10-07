import SwiftUI

/// Above the sync row in the sidebar: the team's changes waiting to be
/// committed to the harness, and Review to commit them.
struct HarnessPendingRow: View {
    @Environment(HarnessTeamStore.self) private var team
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    @State private var isReviewing = false

    var body: some View {
        if let changes = team.pending[org], !changes.isEmpty {
            let notes = HarnessTeamStore.notes(changes)
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: team.errors[org] == nil ? "arrow.up.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(team.errors[org] == nil ? Color.accentColor : .orange)
                    Text(notes.count == 1 ? "1 change to commit" : "\(notes.count) changes to commit")
                        .lineLimit(1)
                    Spacer()
                    if team.committing.contains(org) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Review") { isReviewing = true }
                            .linkButton()
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .help(notes.joined(separator: "\n"))
            }
            .sheet(isPresented: $isReviewing) { HarnessCommitSheet(org: org) }
        }
    }
}

/// The team's pending changes, confirmed before they're committed to the
/// harness in one commit, or discarded.
struct HarnessCommitSheet: View {
    @Environment(HarnessTeamStore.self) private var team
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.dismiss) private var dismiss
    let org: String
    @State private var confirmingDiscard = false

    var body: some View {
        let changes = team.pending[org] ?? [:]
        let notes = HarnessTeamStore.notes(changes)
        let repo = configs.harness(for: org)?.repo ?? "the harness"
        let committing = team.committing.contains(org)
        VStack(alignment: .leading, spacing: 14) {
            Text("Commit to \(repo)").font(.title3.weight(.semibold))
            Text("The team's settings and people's dates are kept in the harness, so everyone sees these once they're committed. Gannin commits them together, on top of any changes made there since.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(Array(notes.enumerated()), id: \.offset) { _, note in
                Text(note.prefix(1).uppercased() + note.dropFirst())
            }
            .frame(minHeight: 100, maxHeight: 280)
            Text(HarnessTeamStore.message(notes).components(separatedBy: "\n").first ?? "")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let error = team.errors[org] {
                Text("Couldn't commit: \(error)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Discard Changes", role: .destructive) { confirmingDiscard = true }
                    .disabled(committing || changes.isEmpty)
                Spacer()
                if committing { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(committing)
                Button("Commit") {
                    Task {
                        await team.commit(org: org)
                        if team.errors[org] == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(committing || changes.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(committing)
        .confirmationDialog("Discard these changes?", isPresented: $confirmingDiscard) {
            Button("Discard Changes", role: .destructive) {
                team.discard(org: org)
                dismiss()
            }
        } message: {
            Text("Everything goes back to what \(repo) has.")
        }
    }
}

/// Settings > Harness: where the team's data is kept.
struct TeamDataSection: View {
    let org: String
    let setup: HarnessConfig

    var body: some View {
        Section {
            LabeledContent("Team data") {
                Text("In \(setup.repo)")
            }
            Text("Views, investment categories, the issue workflow, working week, leave policy, repos and people left out, goals, the scorecard, recap cadence, projects, drafting prompts, the committed date field, notes from the field, and people's dates and time off are read from .gannin in the harness, so everyone in \(org) works from the same copy. Changes wait in the sidebar until you review and commit them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
