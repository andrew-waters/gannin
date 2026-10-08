import SwiftUI

/// Above the sync row in the sidebar: the team's changes waiting to be
/// committed to the harness, and Review to commit them.
struct HarnessPendingRow: View {
    @Environment(HarnessTeamStore.self) private var team
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    @State private var isReviewing = false

    var body: some View {
        let pending = team.changes(org: org)
        if !pending.isEmpty {
            let notes = pending.flatMap { HarnessTeamStore.notes($0.changes) }
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
        let pending = team.changes(org: org)
        let repos = pending.map(\.setup.repo)
        let repo = repos.count == 1 ? repos[0] : "\(repos.count) harnesses"
        let committing = team.committing.contains(org)
        VStack(alignment: .leading, spacing: 14) {
            Text("Commit to \(repo)").font(.title3.weight(.semibold))
            Text("The team's settings and people's dates are kept in the projects' harnesses, so everyone sees these once they're committed. Gannin commits each harness's together, on top of any changes made there since.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(pending, id: \.setup.repo) { harness in
                    let notes = HarnessTeamStore.notes(harness.changes)
                    Section {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            Text(note.prefix(1).uppercased() + note.dropFirst())
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(harness.setup.repo)
                            Text(HarnessTeamStore.message(notes).components(separatedBy: "\n").first ?? "")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(minHeight: 100, maxHeight: 280)
            if let error = team.errors[org] {
                Text("Couldn't commit: \(error)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Discard Changes", role: .destructive) { confirmingDiscard = true }
                    .disabled(committing || pending.isEmpty)
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
                .disabled(committing || pending.isEmpty)
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
            Text("Everything goes back to what \(repos.count == 1 ? repo : "the harnesses have").")
        }
    }
}

/// Settings > Harness: where the team's data is kept.
struct TeamDataSection: View {
    let org: String
    /// The window's.
    let project: RepoProject
    let home: RepoProject

    var body: some View {
        Section {
            LabeledContent(project.name) {
                Text(project.harness.repo)
            }
            Text("The project's name and repos, investment categories, issue workflow, goals, scorecard, recap cadence, committed date field and notes from the field are read from .gannin in its harness.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if home.id != project.id {
                LabeledContent("Home (\(home.name))") {
                    Text(home.harness.repo)
                }
            }
            Text("\(home.id == project.id ? "It's home, so it also keeps" : "Home keeps") what's the org's: views, the working week, leave policy, repos and people left out, drafting prompts, and people's dates and time off. Everyone in \(org) works from the same copies, and changes wait in the sidebar until you review and commit them. Projects are added and home picked under Projects.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Team data")
        }
    }
}
