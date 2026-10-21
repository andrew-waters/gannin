import SwiftUI

/// An issue's assignees, chosen from the org's people. Like the board
/// fields, edits stay local until Save sends them to GitHub.
struct AssigneesSection: View {
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    @Environment(IssueStore.self) private var issueStore
    @Environment(ProjectStore.self) private var projectStore
    let org: String
    let issueID: String

    /// The logins being edited; nil until the menu changes them.
    @State private var draft: Set<String>?
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        if let record = issueStore.history(for: org)?.issues[issueID] {
            let saved = Set(record.assignees)
            let chosen = draft ?? saved
            Section("Assignees") {
                LabeledContent("Assignees") {
                    Menu {
                        ForEach(candidates(including: saved)) { person in
                            Toggle("\(person.displayName) (\(person.login))", isOn: Binding(get: { chosen.contains(person.login) }, set: { on in
                                var next = chosen
                                if on { next.insert(person.login) } else { next.remove(person.login) }
                                draft = next == saved ? nil : next
                            }))
                        }
                    } label: {
                        Text(chosen.isEmpty ? "Nobody" : chosen.sorted().joined(separator: ", ")).lineLimit(1)
                    }
                    .fixedSize()
                    .disabled(isSaving)
                }
                if draft != nil {
                    HStack(spacing: 8) {
                        Spacer()
                        if isSaving { ProgressView().controlSize(.small) }
                        Button("Revert") {
                            draft = nil
                            saveError = nil
                        }
                        .disabled(isSaving)
                        Button("Save") { save(saved: saved, chosen: chosen) }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSaving || auth.api == nil)
                    }
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .onChange(of: issueID) {
                draft = nil
                saveError = nil
            }
        }
    }

    /// The org's people, and anyone already assigned who isn't one of them
    /// (an outside collaborator), so they can be taken off.
    private func candidates(including assigned: Set<String>) -> [Person] {
        let members = orgs.snapshot(for: org)?.members ?? []
        let outside = assigned.subtracting(members.map(\.login)).map(person)
        return (members + outside).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func person(_ login: String) -> Person {
        orgs.snapshot(for: org)?.members.first { $0.login == login }
            ?? Person(login: login, name: nil, avatarUrl: URL(string: "https://github.com/\(login).png?size=64"))
    }

    private func save(saved: Set<String>, chosen: Set<String>) {
        guard let api = auth.api else { return }
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            do {
                try await api.setAssignees(issueID: issueID, add: chosen.subtracting(saved).sorted(), remove: saved.subtracting(chosen).sorted())
                IssueEdits.setAssignees(org: org, issueID: issueID, assignees: chosen.sorted().map(person), issues: issueStore, projects: projectStore)
                draft = nil
            } catch {
                saveError = "Couldn't save assignees: \(error.localizedDescription)"
            }
        }
    }
}
