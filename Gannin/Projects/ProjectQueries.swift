import Foundation

extension GitHubAPI {
    /// A board's fields and saved views.
    func board(org: String, number: Int) async throws -> Board? {
        struct Response: Decodable {
            struct Org: Decodable { let projectV2: RawBoard? }
            let organization: Org?
        }
        let response: Response = try await query("""
            query($login: String!) {
              \(GitHubAccounts.ownerField(org)) {
                projectV2(number: \(number)) {
                  id number title url
                  fields(first: 50) {
                    nodes {
                      ... on ProjectV2FieldCommon { id name dataType }
                      ... on ProjectV2SingleSelectField { options { id name color description } }
                      ... on ProjectV2MultiSelectField { multiSelectOptions { id name color description } }
                      ... on ProjectV2IterationField {
                        configuration {
                          duration
                          iterations { id title startDate duration }
                          completedIterations { id title startDate duration }
                        }
                      }
                    }
                  }
                  views(first: 30) {
                    nodes {
                      id number name layout filter
                      groupByFields(first: 3) { nodes { ... on ProjectV2FieldCommon { name } } }
                      verticalGroupByFields(first: 3) { nodes { ... on ProjectV2FieldCommon { name } } }
                      sortByFields(first: 5) { nodes { direction field { ... on ProjectV2FieldCommon { name } } } }
                      fields(first: 40) { nodes { ... on ProjectV2FieldCommon { name } } }
                    }
                  }
                }
              }
            }
            """, variables: ["login": org])
        return response.organization?.projectV2?.model
    }

    /// A board's items matching a filter in GitHub's own syntax, as its
    /// views use (`-status:Done label:bug`); empty for everything.
    func boardItems(org: String, number: Int, filter: String, onPage: (_ fetched: Int, _ total: Int?) -> Void = { _, _ in }) async throws -> [BoardItem] {
        struct Response: Decodable {
            struct Project: Decodable { let items: PagedConnection<Lossy<RawBoardItem>> }
            struct Org: Decodable { let projectV2: Project? }
            let organization: Org?
        }
        let items: [Lossy<RawBoardItem>] = try await paginate(limit: 5000, onPage: onPage) { cursor in
            // Variables go as strings, which an Int! won't accept, so the
            // (always integer) number goes in as a literal.
            var variables = ["login": org, "query": filter]
            if let cursor { variables["cursor"] = cursor }
            let response: Response = try await query("""
                query($login: String!, $query: String, $cursor: String) {
                  \(GitHubAccounts.ownerField(org)) {
                    projectV2(number: \(number)) {
                      items(first: 50, after: $cursor, query: $query) {
                        totalCount
                        pageInfo { hasNextPage endCursor }
                        nodes { \(RawBoardItem.fields) }
                      }
                    }
                  }
                }
                """, variables: variables)
            return response.organization?.projectV2?.items
        }
        return items.compactMap { $0.value?.model }
    }
}

// MARK: - Raw shapes

private struct RawBoard: Decodable {
    struct Field: Decodable {
        struct Option: Decodable { let id: String; let name: String; let color: String?; let description: String? }
        struct Iterations: Decodable {
            struct Iteration: Decodable { let id: String; let title: String; let startDate: String; let duration: Int? }
            let duration: Int?
            let iterations: [Iteration]
            let completedIterations: [Iteration]?
        }
        let id: String?
        let name: String?
        let dataType: String?
        let options: [Option]?
        let multiSelectOptions: [Option]?
        let configuration: Iterations?
    }
    struct Named: Decodable { let name: String? }
    struct SortBy: Decodable {
        let direction: String
        let field: Named?
    }
    struct View: Decodable {
        let id: String
        let number: Int
        let name: String
        let layout: String
        let filter: String?
        let groupByFields: Connection<Named>?
        let verticalGroupByFields: Connection<Named>?
        let sortByFields: Connection<SortBy>?
        let fields: Connection<Named>?
    }

    let id: String
    let number: Int
    let title: String
    let url: URL
    let fields: Connection<Lossy<Field>>
    let views: Connection<Lossy<View>>

    static func layout(_ raw: String) -> BoardView.Layout {
        switch raw {
        case "BOARD_LAYOUT": .board
        case "ROADMAP_LAYOUT": .roadmap
        default: .table
        }
    }

    var model: Board {
        Board(
            id: id,
            number: number,
            title: title,
            url: url,
            fields: fields.nodes.compactMap(\.value).compactMap { field in
                guard let id = field.id, let name = field.name, let dataType = field.dataType else { return nil }
                let iterations = (field.configuration?.iterations ?? []) + (field.configuration?.completedIterations ?? [])
                let options = (field.options ?? field.multiSelectOptions ?? []).map {
                    BoardOption(id: $0.id, name: $0.name, color: $0.color, start: nil, description: ($0.description ?? "").isEmpty ? nil : $0.description)
                }
                    + iterations
                        .sorted { $0.startDate < $1.startDate }
                        .map { BoardOption(id: $0.id, name: $0.title, color: nil, start: try? Date($0.startDate, strategy: .iso8601.year().month().day()), duration: $0.duration) }
                return BoardField(id: id, name: name, dataType: dataType, options: options, iterationDuration: field.configuration?.duration)
            },
            views: views.nodes.compactMap(\.value).map { view in
                BoardView(
                    id: view.id,
                    number: view.number,
                    name: view.name,
                    layout: Self.layout(view.layout),
                    filter: (view.filter ?? "").trimmingCharacters(in: .whitespaces),
                    groupBy: (view.groupByFields?.nodes ?? []).compactMap(\.name),
                    columnBy: (view.verticalGroupByFields?.nodes ?? []).compactMap(\.name),
                    sortBy: (view.sortByFields?.nodes ?? []).compactMap { sort in
                        sort.field?.name.map { BoardView.Sort(field: $0, descending: sort.direction == "DESC") }
                    },
                    visibleFields: (view.fields?.nodes ?? []).compactMap(\.name)
                )
            }
            .sorted { $0.number < $1.number }
        )
    }
}

private struct RawBoardItem: Decodable {
    struct Actor: Decodable { let login: String; let avatarUrl: URL? }
    struct Label: Decodable { let name: String; let color: String }
    struct Repository: Decodable { let nameWithOwner: String }
    struct Titled: Decodable { let title: String }
    struct Parent: Decodable { let title: String; let number: Int }
    struct SubIssues: Decodable { let total: Int; let percentCompleted: Int }
    struct Count: Decodable { let totalCount: Int }
    struct Content: Decodable {
        let id: String?
        let number: Int?
        let title: String?
        let url: URL?
        let state: String?
        let updatedAt: Date?
        let repository: Repository?
        let assignees: Connection<Actor>?
        let labels: Connection<Label>?
        let milestone: Titled?
        let parent: Parent?
        let subIssuesSummary: SubIssues?
        let closedByPullRequestsReferences: Count?
    }
    struct FieldValue: Decodable {
        struct Field: Decodable {
            struct Option: Decodable { let id: String }
            let name: String?
            let dataType: String?
            let options: [Option]?
        }
        let text: String?
        let number: Double?
        let date: String?
        let name: String?
        let optionId: String?
        let title: String?
        let startDate: String?
        /// A multi-select value's options.
        let options: [Named]?
        let field: Field?
    }
    struct Named: Decodable { let name: String }

    let id: String
    let type: String
    let updatedAt: Date?
    let content: Content?
    let fieldValues: Connection<Lossy<FieldValue>>

    static let fields = """
        id type updatedAt
        content {
          ... on Issue {
            id number title url state updatedAt
            repository { nameWithOwner }
            assignees(first: 5) { nodes { login avatarUrl } }
            labels(first: 10) { nodes { name color } }
            milestone { title }
            parent { title number }
            subIssuesSummary { total percentCompleted }
            closedByPullRequestsReferences(first: 1) { totalCount }
          }
          ... on PullRequest {
            id number title url state updatedAt
            repository { nameWithOwner }
            assignees(first: 5) { nodes { login avatarUrl } }
            labels(first: 10) { nodes { name color } }
            milestone { title }
          }
          ... on DraftIssue { title updatedAt assignees(first: 5) { nodes { login avatarUrl } } }
        }
        fieldValues(first: 30) {
          nodes {
            ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name dataType } } }
            ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { name dataType } } }
            ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name dataType } } }
            ... on ProjectV2ItemFieldSingleSelectValue { name optionId field { ... on ProjectV2FieldCommon { name dataType } ... on ProjectV2SingleSelectField { options { id } } } }
            ... on ProjectV2ItemFieldIterationValue { title startDate field { ... on ProjectV2FieldCommon { name dataType } } }
            ... on ProjectV2ItemFieldMultiSelectValue { options { name } field { ... on ProjectV2FieldCommon { name dataType } } }
          }
        }
        """

    var model: BoardItem {
        var values: [String: IssueFieldValue] = [:]
        for value in fieldValues.nodes.compactMap(\.value) {
            guard let field = value.field, let name = field.name else { continue }
            switch field.dataType {
            case "TEXT": if let text = value.text { values[name] = .text(text) }
            case "NUMBER": if let number = value.number { values[name] = .number(number) }
            case "DATE":
                if let date = value.date, let day = try? Date(date, strategy: .iso8601.year().month().day()) { values[name] = .date(day) }
            case "SINGLE_SELECT":
                if let option = value.name {
                    values[name] = .option(name: option, position: field.options?.firstIndex { $0.id == value.optionId } ?? Int.max)
                }
            case "ITERATION":
                if let title = value.title, let start = value.startDate.flatMap({ try? Date($0, strategy: .iso8601.year().month().day()) }) {
                    values[name] = .iteration(title: title, start: start)
                }
            case "MULTI_SELECT":
                if let options = value.options, !options.isEmpty { values[name] = .options(options.map(\.name)) }
            default: break
            }
        }
        let summary = content?.subIssuesSummary
        return BoardItem(
            id: id,
            kind: BoardItem.Kind(rawValue: type) ?? .redacted,
            contentID: content?.id,
            title: content?.title ?? "Untitled",
            number: content?.number,
            url: content?.url,
            repo: content?.repository?.nameWithOwner,
            state: content?.state,
            assignees: (content?.assignees?.nodes ?? []).map { Person(login: $0.login, name: nil, avatarUrl: $0.avatarUrl) },
            labels: (content?.labels?.nodes ?? []).map { IssueLabel(name: $0.name, color: $0.color) },
            milestone: content?.milestone?.title,
            parent: content?.parent.map { "#\($0.number) \($0.title)" },
            subIssuesProgress: summary.flatMap { $0.total > 0 ? Double($0.percentCompleted) : nil },
            linkedPullRequests: content?.closedByPullRequestsReferences?.totalCount ?? 0,
            updatedAt: content?.updatedAt ?? updatedAt,
            values: values
        )
    }
}
