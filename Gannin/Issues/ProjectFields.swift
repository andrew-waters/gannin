import Foundation

/// An issue's place on one project board, with the fields it can edit.
struct ProjectItem: Identifiable {
    let id: String
    let projectID: String
    let projectNumber: Int
    let projectTitle: String
    var fields: [ProjectField]
}

/// A project board in the org, for Add to Project.
struct OrgProject: Codable, Identifiable, Hashable {
    let id: String
    let number: Int
    let title: String
    var closed = false
}

extension OrgProject {
    /// Tolerates lists cached before `closed` was kept.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        closed = try container.decodeIfPresent(Bool.self, forKey: .closed) ?? false
    }
}

struct ProjectField: Identifiable {
    struct Option: Hashable, Identifiable {
        let id: String
        let name: String
        /// Iteration start.
        var start: Date?
    }

    enum Kind {
        case text
        case number
        case date
        case singleSelect([Option])
        case iteration([Option])
    }

    enum Value: Equatable {
        case text(String)
        case number(Double)
        /// A calendar day, held as midnight UTC.
        case date(Date)
        /// A single-select option or iteration, by ID.
        case option(String)
    }

    let id: String
    let name: String
    let kind: Kind
    var value: Value?
}

extension GitHubAPI {
    /// The issue's project items and their editable fields (text, number,
    /// date, single select and iteration; built-ins like Title are left out).
    func projectItems(issueID: String) async throws -> [ProjectItem] {
        struct Response: Decodable {
            struct Node: Decodable { let projectItems: Connection<RawProjectItem>? }
            let node: Node?
        }
        let response: Response = try await query("""
            query($id: ID!) {
              node(id: $id) {
                ... on Issue {
                  projectItems(first: 10) {
                    nodes {
                      id
                      project {
                        id number title
                        fields(first: 50) {
                          nodes {
                            __typename
                            ... on ProjectV2FieldCommon { id name dataType }
                            ... on ProjectV2SingleSelectField { options { id name } }
                            ... on ProjectV2IterationField {
                              configuration {
                                iterations { id title startDate }
                                completedIterations { id title startDate }
                              }
                            }
                          }
                        }
                      }
                      fieldValues(first: 50) {
                        nodes {
                          __typename
                          ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { id } } }
                          ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { id } } }
                          ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { id } } }
                          ... on ProjectV2ItemFieldSingleSelectValue { optionId field { ... on ProjectV2FieldCommon { id } } }
                          ... on ProjectV2ItemFieldIterationValue { iterationId field { ... on ProjectV2FieldCommon { id } } }
                        }
                      }
                    }
                  }
                }
              }
            }
            """, variables: ["id": issueID])
        return (response.node?.projectItems?.nodes ?? []).map(\.model)
    }

    /// The org's open project boards, by title.
    func orgProjects(org: String) async throws -> [OrgProject] {
        struct Response: Decodable {
            struct Project: Decodable { let id: String; let number: Int; let title: String; let closed: Bool }
            struct Org: Decodable { let projectsV2: Connection<Project> }
            let organization: Org?
        }
        let response: Response = try await query("""
            query($login: String!) {
              \(GitHubAccounts.ownerField(org)) {
                projectsV2(first: 100, orderBy: { field: TITLE, direction: ASC }) { nodes { id number title closed } }
              }
            }
            """, variables: ["login": org])
        return (response.organization?.projectsV2.nodes ?? []).map { OrgProject(id: $0.id, number: $0.number, title: $0.title, closed: $0.closed) }
    }

    /// The boards linked to a repo that the org (or account) owns, open or closed,
    /// by title. Boards owned elsewhere are left out: everything else
    /// finds a board by its number within the org.
    func repoProjects(org: String, repo: String) async throws -> [OrgProject] {
        struct Response: Decodable {
            struct Owner: Decodable { let login: String? }
            struct Project: Decodable { let id: String; let number: Int; let title: String; let closed: Bool; let owner: Owner }
            struct Repo: Decodable { let projectsV2: Connection<Project> }
            let repository: Repo?
        }
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw APIError.graphQL(["\(repo) isn't owner/name"]) }
        let response: Response = try await query("""
            query($owner: String!, $name: String!) {
              repository(owner: $owner, name: $name) {
                projectsV2(first: 50, orderBy: { field: TITLE, direction: ASC }) {
                  nodes { id number title closed owner { ... on Organization { login } ... on User { login } } }
                }
              }
            }
            """, variables: ["owner": parts[0], "name": parts[1]])
        return (response.repository?.projectsV2.nodes ?? [])
            .filter { $0.owner.login?.lowercased() == org.lowercased() }
            .map { OrgProject(id: $0.id, number: $0.number, title: $0.title, closed: $0.closed) }
    }

    /// Adds an issue (by node ID) to a project board. A write.
    func addToProject(projectID: String, contentID: String) async throws {
        // addProjectV2ItemById is nullable: an empty Response would decode
        // past a refusal (no write access to the board) rather than
        // surfacing it.
        struct Response: Decodable {
            struct Payload: Decodable { struct Item: Decodable { let id: String }; let item: Item }
            let addProjectV2ItemById: Payload
        }
        let _: Response = try await query("""
            mutation($project: ID!, $content: ID!) {
              addProjectV2ItemById(input: { projectId: $project, contentId: $content }) { item { id } }
            }
            """, variables: ["project": projectID, "content": contentID])
    }

    /// Takes an item off a project board; the issue itself is untouched. A write.
    func removeFromProject(projectID: String, itemID: String) async throws {
        // Nullable, as addProjectV2ItemById is.
        struct Response: Decodable {
            struct Payload: Decodable { let deletedItemId: String? }
            let deleteProjectV2Item: Payload
        }
        let _: Response = try await query("""
            mutation($project: ID!, $item: ID!) {
              deleteProjectV2Item(input: { projectId: $project, itemId: $item }) { deletedItemId }
            }
            """, variables: ["project": projectID, "item": itemID])
    }

    /// Sets one field on a project item, or clears it with a nil value. A write.
    func setProjectField(projectID: String, itemID: String, field: ProjectField, value: ProjectField.Value?) async throws {
        var variables = ["project": projectID, "item": itemID, "field": field.id]
        guard let value else {
            // Nullable, as the other project item mutations are.
            struct Response: Decodable {
                struct Payload: Decodable { let clientMutationId: String? }
                let clearProjectV2ItemFieldValue: Payload
            }
            let _: Response = try await query("""
                mutation($project: ID!, $item: ID!, $field: ID!) {
                  clearProjectV2ItemFieldValue(input: { projectId: $project, itemId: $item, fieldId: $field }) { clientMutationId }
                }
                """, variables: variables)
            return
        }
        let literal: String
        switch (value, field.kind) {
        case (.text(let text), _):
            variables["value"] = text
            literal = "{ text: $value }"
        case (.number(let number), _):
            // Variables here are strings, so the number goes in as a literal.
            literal = "{ number: \(number.isFinite ? number : 0) }"
        case (.date(let date), _):
            variables["value"] = date.formatted(.iso8601.year().month().day())
            literal = "{ date: $value }"
        case (.option(let id), .iteration):
            variables["value"] = id
            literal = "{ iterationId: $value }"
        case (.option(let id), _):
            variables["value"] = id
            literal = "{ singleSelectOptionId: $value }"
        }
        let declaration = literal.contains("$value") ? ", $value: \(literal.contains("date") ? "Date" : "String")!" : ""
        struct Response: Decodable {
            struct Payload: Decodable { let clientMutationId: String? }
            let updateProjectV2ItemFieldValue: Payload
        }
        let _: Response = try await query("""
            mutation($project: ID!, $item: ID!, $field: ID!\(declaration)) {
              updateProjectV2ItemFieldValue(input: { projectId: $project, itemId: $item, fieldId: $field, value: \(literal) }) { clientMutationId }
            }
            """, variables: variables)
    }
}

private struct RawProjectItem: Decodable {
    struct Option: Decodable { let id: String; let name: String }
    struct Iterations: Decodable {
        struct Iteration: Decodable { let id: String; let title: String; let startDate: String? }
        let iterations: [Iteration]
        let completedIterations: [Iteration]?
    }
    struct Field: Decodable {
        let __typename: String
        let id: String?
        let name: String?
        let dataType: String?
        let options: [Option]?
        let configuration: Iterations?
    }
    struct FieldRef: Decodable { let id: String? }
    struct Value: Decodable {
        let __typename: String
        let text: String?
        let number: Double?
        let date: String?
        let optionId: String?
        let iterationId: String?
        let field: FieldRef?
    }
    struct Project: Decodable {
        let id: String
        let number: Int
        let title: String
        let fields: Connection<Lossy<Field>>
    }

    let id: String
    let project: Project
    let fieldValues: Connection<Lossy<Value>>

    var model: ProjectItem {
        var values: [String: ProjectField.Value] = [:]
        for value in fieldValues.nodes.compactMap(\.value) {
            guard let fieldID = value.field?.id else { continue }
            if let text = value.text { values[fieldID] = .text(text) }
            if let number = value.number { values[fieldID] = .number(number) }
            if let date = value.date, let day = try? Date(date, strategy: .iso8601.year().month().day()) { values[fieldID] = .date(day) }
            if let option = value.optionId ?? value.iterationId { values[fieldID] = .option(option) }
        }
        let fields: [ProjectField] = project.fields.nodes.compactMap(\.value).compactMap { field in
            guard let id = field.id, let name = field.name else { return nil }
            let kind: ProjectField.Kind
            switch field.dataType {
            case "TEXT": kind = .text
            case "NUMBER": kind = .number
            case "DATE": kind = .date
            case "SINGLE_SELECT": kind = .singleSelect((field.options ?? []).map { .init(id: $0.id, name: $0.name) })
            case "ITERATION":
                let iterations = (field.configuration?.iterations ?? []) + (field.configuration?.completedIterations ?? [])
                kind = .iteration(iterations.map {
                    .init(id: $0.id, name: $0.title, start: $0.startDate.flatMap { try? Date($0, strategy: .iso8601.year().month().day()) })
                })
            default: return nil
            }
            return ProjectField(id: id, name: name, kind: kind, value: values[id])
        }
        return ProjectItem(id: id, projectID: project.id, projectNumber: project.number, projectTitle: project.title, fields: fields)
    }
}
