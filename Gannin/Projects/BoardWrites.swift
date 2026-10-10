import SwiftUI

// Making and linking project boards, as a repo's Projects tab on GitHub
// does: each a write, made only from a sheet or a confirmation.

extension GitHubAPI {
    /// The org's (or account's) node ID, which owns new boards.
    func ownerID(org: String) async throws -> String {
        struct Response: Decodable {
            struct Owner: Decodable { let id: String }
            let organization: Owner?
        }
        let response: Response = try await query("""
            query($login: String!) { \(GitHubAccounts.ownerField(org)) { id } }
            """, variables: ["login": org])
        guard let id = response.organization?.id else { throw APIError.graphQL(["Couldn't find \(org)"]) }
        return id
    }

    func repositoryID(_ repo: String) async throws -> String {
        struct Response: Decodable {
            struct Repo: Decodable { let id: String }
            let repository: Repo?
        }
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw APIError.graphQL(["\(repo) isn't owner/name"]) }
        let response: Response = try await query("""
            query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id } }
            """, variables: ["owner": parts[0], "name": parts[1]])
        guard let id = response.repository?.id else { throw APIError.graphQL(["Couldn't find \(repo)"]) }
        return id
    }

    /// A new, empty board. A write.
    func createBoard(ownerID: String, title: String) async throws -> OrgProject {
        struct Response: Decodable {
            struct Payload: Decodable { let projectV2: Board }
            let createProjectV2: Payload
        }
        let response: Response = try await mutate("""
            mutation($owner: ID!, $title: String!) {
              createProjectV2(input: { ownerId: $owner, title: $title }) { projectV2 { id number title } }
            }
            """, variables: ["owner": ownerID, "title": title])
        return response.createProjectV2.projectV2.board
    }

    /// A copy of a board's fields and views (and, if asked, its draft
    /// items), as GitHub's templates are. A write.
    func copyBoard(_ projectID: String, ownerID: String, title: String, includeDrafts: Bool) async throws -> OrgProject {
        struct Response: Decodable {
            struct Payload: Decodable { let projectV2: Board }
            let copyProjectV2: Payload
        }
        let response: Response = try await mutate("""
            mutation($project: ID!, $owner: ID!, $title: String!, $drafts: Boolean!) {
              copyProjectV2(input: { projectId: $project, ownerId: $owner, title: $title, includeDraftIssues: $drafts }) { projectV2 { id number title } }
            }
            """, variables: ["project": projectID, "owner": ownerID, "title": title, "drafts": includeDrafts])
        return response.copyProjectV2.projectV2.board
    }

    /// Shows a board on a repo's Projects tab. A write.
    func linkBoard(_ projectID: String, repositoryID: String) async throws {
        // linkProjectV2ToRepository is nullable: an empty Response would
        // decode past a refusal (no write access) rather than surfacing it.
        struct Response: Decodable {
            struct Payload: Decodable { struct Repository: Decodable { let id: String }; let repository: Repository }
            let linkProjectV2ToRepository: Payload
        }
        let _: Response = try await mutate("""
            mutation($project: ID!, $repo: ID!) {
              linkProjectV2ToRepository(input: { projectId: $project, repositoryId: $repo }) { repository { id } }
            }
            """, variables: ["project": projectID, "repo": repositoryID])
    }

    /// Takes a board off a repo's Projects tab; the board is untouched. A write.
    func unlinkBoard(_ projectID: String, repositoryID: String) async throws {
        // Nullable, as linkProjectV2ToRepository is.
        struct Response: Decodable {
            struct Payload: Decodable { struct Repository: Decodable { let id: String }; let repository: Repository }
            let unlinkProjectV2FromRepository: Payload
        }
        let _: Response = try await mutate("""
            mutation($project: ID!, $repo: ID!) {
              unlinkProjectV2FromRepository(input: { projectId: $project, repositoryId: $repo }) { repository { id } }
            }
            """, variables: ["project": projectID, "repo": repositoryID])
    }

    /// Closes or reopens a board. A write.
    func setBoardClosed(_ projectID: String, closed: Bool) async throws {
        // Nullable, as the other board mutations are.
        struct Response: Decodable {
            struct Payload: Decodable { struct Board: Decodable { let id: String }; let projectV2: Board }
            let updateProjectV2: Payload
        }
        let _: Response = try await mutate("""
            mutation($project: ID!, $closed: Boolean!) {
              updateProjectV2(input: { projectId: $project, closed: $closed }) { projectV2 { id } }
            }
            """, variables: ["project": projectID, "closed": closed])
    }

    private struct Board: Decodable {
        let id: String
        let number: Int
        let title: String

        var board: OrgProject { OrgProject(id: id, number: number, title: title) }
    }
}

/// New Board: a title, blank or a copy of another board, and a repo to
/// link it to. Made when Create is pressed, then opened.
struct NewBoardSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(ProjectStore.self) private var projects
    @Environment(HarnessStore.self) private var harness
    @Environment(\.dismiss) private var dismiss
    let org: String
    /// The repo it's linked to at first; nil for none.
    let repo: String?
    let created: (OrgProject) -> Void

    @State private var title = ""
    /// The board to copy, by ID; nil for a blank one.
    @State private var template: String?
    @State private var includeDrafts = false
    @State private var linkTo: String?
    @State private var working: String?
    @State private var error: String?

    var body: some View {
        let boards = projects.allBoards(org: org, repo: nil)
        Form {
            Section {
                TextField("Title", text: $title, prompt: Text("Roadmap"))
                Picker("Start from", selection: $template) {
                    Text("A blank board").tag(String?.none)
                    if !boards.isEmpty {
                        Divider()
                        ForEach(boards) { Text("A copy of \($0.title)").tag(Optional($0.id)) }
                    }
                }
                if template != nil {
                    Toggle("Copy its draft items too", isOn: $includeDrafts)
                }
            } footer: {
                Text(template == nil
                     ? "A board with GitHub's default Status field and a table view."
                     : "Its fields, options and views are copied. Issues on it aren't.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Link to") {
                    SearchablePicker(
                        choices: [SearchableChoice(value: nil, title: "No repo")]
                            + (harness.repositories[org] ?? []).map { SearchableChoice(value: $0, title: $0) },
                        selection: linkTo,
                        prompt: "Search repositories",
                        isLoading: harness.repositories[org] == nil
                    ) { linkTo = $0 }
                }
            } footer: {
                Text("Linked, it shows on the repo's Projects tab on GitHub and under a project that takes its boards from the repo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(working).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .navigationTitle("New Board")
        .task { await harness.loadRepositories(org: org) }
        .onAppear { linkTo = repo }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create Board") { create() }
                    .disabled(working != nil || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Creates the board in \(org) on GitHub")
            }
        }
    }

    private func create() {
        guard let api = auth.api else { return }
        let title = title.trimmingCharacters(in: .whitespaces)
        error = nil
        Task {
            do {
                working = "Creating \(title)"
                let owner = try await api.ownerID(org: org)
                let board: OrgProject
                if let template {
                    board = try await api.copyBoard(template, ownerID: owner, title: title, includeDrafts: includeDrafts)
                } else {
                    board = try await api.createBoard(ownerID: owner, title: title)
                }
                if let linkTo {
                    working = "Linking it to \(linkTo)"
                    do {
                        try await api.linkBoard(board.id, repositoryID: try await api.repositoryID(linkTo))
                    } catch {
                        // It's made either way; say so rather than leave it unseen.
                        self.error = "Created \(title), but couldn't link it to \(linkTo): \(error.localizedDescription)"
                    }
                }
                await projects.loadBoards(org: org, force: true)
                if let linkTo { await projects.loadRepoBoards(org: org, repo: linkTo, force: true) }
                working = nil
                if self.error == nil {
                    dismiss()
                    created(board)
                }
            } catch {
                working = nil
                self.error = error.localizedDescription
            }
        }
    }
}
