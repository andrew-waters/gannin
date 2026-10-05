import SwiftUI

/// The PR drawer's reviewer picker, as GitHub's sidebar has it: GitHub's
/// suggestions, then the org's members, ticked for those asked. Changes
/// are confirmed when the popover closes, then written together.
struct ReviewerPickerButton: View {
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    let pr: PullRequest
    let org: String
    let members: [Person]

    @State private var isOpen = false
    @State private var picked: Set<String> = []
    @State private var suggested: [Person] = []
    @State private var confirming = false
    @State private var isWriting = false
    @State private var failure: String?

    private var requested: Set<String> { Set(pr.requestedReviewers.map(\.login)) }
    private var adding: [String] { picked.subtracting(requested).sorted() }
    private var removing: [String] { requested.subtracting(picked).sorted() }

    var body: some View {
        Button {
            picked = requested
            isOpen = true
        } label: {
            Image(systemName: isWriting ? "ellipsis" : "gearshape")
        }
        .buttonStyle(.borderless)
        .disabled(isWriting || auth.api == nil)
        .help("Choose reviewers")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ReviewerPickerList(
                picked: $picked,
                suggested: suggested,
                members: members,
                reviewed: Set(pr.reviewers.map(\.login)),
                author: pr.author?.login
            )
            .task { await loadSuggestions() }
        }
        .onChange(of: isOpen) { _, open in
            if !open, !adding.isEmpty || !removing.isEmpty { confirming = true }
        }
        .confirmationDialog(confirmationTitle, isPresented: $confirming) {
            Button("Update Reviewers") { Task { await write() } }
            Button("Discard", role: .cancel) {}
        } message: {
            Text("\(pr.repo)#\(pr.number) on GitHub.")
        }
        .alert("Couldn't update reviewers", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var confirmationTitle: String {
        var parts: [String] = []
        if !adding.isEmpty { parts.append("request a review from \(adding.formatted(.list(type: .and)))") }
        if !removing.isEmpty { parts.append("remove the request for \(removing.formatted(.list(type: .and)))") }
        let sentence = parts.joined(separator: " and ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "?"
    }

    private func loadSuggestions() async {
        guard suggested.isEmpty, let api = auth.api else { return }
        suggested = (try? await api.suggestedReviewers(pullRequestID: pr.id)) ?? []
    }

    private func write() async {
        guard let api = auth.api else { return }
        let adding = adding, removing = removing
        let everyone = Dictionary((suggested + members).map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first })
        isWriting = true
        defer { isWriting = false }
        do {
            try await api.requestReviewers(repo: pr.repo, number: pr.number, adding: adding, removing: removing)
            let now = Date()
            orgs.updatePullRequest(pr.id, org: org) { pr in
                pr.requestedReviewers.removeAll { removing.contains($0.login) }
                for login in adding {
                    pr.requestedReviewers.append(everyone[login] ?? Person(login: login, name: nil, avatarUrl: nil))
                    pr.reviewRequestedAt[login] = now
                }
                for login in removing { pr.reviewRequestedAt[login] = nil }
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct ReviewerPickerList: View {
    @Binding var picked: Set<String>
    let suggested: [Person]
    let members: [Person]
    /// Who has reviewed already, ticked to ask again.
    let reviewed: Set<String>
    let author: String?
    @State private var search = ""

    var body: some View {
        let suggestions = filtered(suggested)
        let suggestedLogins = Set(suggestions.map(\.login))
        let others = filtered(members).filter { !suggestedLogins.contains($0.login) }
            .sorted { $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending }
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search people", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            List {
                if !suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggestions) { row($0) }
                    }
                }
                Section("Members") {
                    ForEach(others) { row($0) }
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 300, height: 360)
    }

    private func filtered(_ people: [Person]) -> [Person] {
        people.filter { person in
            person.login != author
                && (search.isEmpty || person.login.localizedCaseInsensitiveContains(search)
                    || (person.name?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    private func row(_ person: Person) -> some View {
        Toggle(isOn: Binding(
            get: { picked.contains(person.login) },
            set: { if $0 { picked.insert(person.login) } else { picked.remove(person.login) } }
        )) {
            HStack(spacing: 6) {
                Avatar(url: person.avatarUrl, size: 18)
                Text(person.login)
                if let name = person.name, !name.isEmpty, name != person.login {
                    Text(name).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if reviewed.contains(person.login) {
                    Text("Reviewed").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}
