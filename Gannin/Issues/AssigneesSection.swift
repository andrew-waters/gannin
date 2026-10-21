import SwiftUI

/// An issue's assignees, chosen from the org's people. Like the board
/// fields, edits stay local until Save sends them to GitHub.
struct AssigneesSection: View {
    let org: String
    let issueID: String

    var body: some View {
        // The drawer swaps one issue for another in place with Previous and
        // Next, so the draft and any save in flight are keyed to the issue.
        AssigneesEditor(org: org, issueID: issueID)
            .id(issueID)
    }
}

private struct AssigneesEditor: View {
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
                Menu {
                    ForEach(candidates(including: saved)) { person in
                        Toggle(Self.title(person), isOn: Binding(get: { chosen.contains(person.login) }, set: { on in
                            var next = chosen
                            if on { next.insert(person.login) } else { next.remove(person.login) }
                            draft = next == saved ? nil : next
                        }))
                        .disabled(!chosen.contains(person.login) && chosen.count >= GitHubAPI.maxAssignees)
                    }
                } label: {
                    Text(chosen.isEmpty ? "Nobody" : chosen.sorted().joined(separator: ", ")).lineLimit(1)
                }
                .fixedSize()
                .disabled(isSaving)
                .help("GitHub allows up to \(GitHubAPI.maxAssignees) assignees")
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
        }
    }

    /// The login goes in brackets only when the name shows something else;
    /// `displayName` is the login for someone with no name.
    private static func title(_ person: Person) -> String {
        person.displayName == person.login ? person.login : "\(person.displayName) (\(person.login))"
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

    /// Records who GitHub says is assigned, as soon as each write lands, so a
    /// failure in the next one doesn't leave the stored issue behind it.
    private func record(_ logins: [String]) {
        IssueEdits.setAssignees(org: org, issueID: issueID, assignees: logins.sorted().map(person), issues: issueStore, projects: projectStore, orgs: orgs)
    }

    private func save(saved: Set<String>, chosen: Set<String>) {
        guard let api = auth.api else { return }
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            do {
                var assigned = saved
                var skipped: [String] = []
                let add = chosen.subtracting(saved).sorted()
                if !add.isEmpty {
                    let result = try await api.addAssignees(issueID: issueID, logins: add)
                    record(result)
                    assigned = Set(result)
                    skipped = add.filter { !assigned.contains($0) }
                }
                // The removals go ahead even when someone was skipped, so
                // they aren't held up behind an add that can't succeed.
                let remove = saved.subtracting(chosen).sorted()
                if !remove.isEmpty {
                    let result = try await api.removeAssignees(issueID: issueID, logins: remove)
                    record(result)
                    assigned = Set(result)
                }
                // Anyone skipped leaves the draft, so Save again doesn't
                // send the same add.
                let wanted = chosen.subtracting(skipped)
                draft = wanted == assigned ? nil : wanted
                if !skipped.isEmpty {
                    saveError = "GitHub didn't assign \(skipped.joined(separator: ", ")); they may not have access to this issue's repo."
                }
            } catch {
                saveError = "Couldn't save assignees: \(error.localizedDescription)"
            }
        }
    }
}
