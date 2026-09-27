import Foundation

extension GitHubAPI {
    /// Issues matching `query`, with the history issue metrics need.
    func issueRecords(query: String, onPage: (_ fetched: Int, _ total: Int?) -> Void = { _, _ in }) async throws -> [IssueRecord] {
        let nodes: [Lossy<RawIssueRecord>] = try await search(
            query,
            fields: RawIssueRecord.fields,
            // Timelines, board fields and linked PR activity make for heavy
            // nodes.
            pageSize: 15,
            onPage: onPage
        )
        return nodes.compactMap { $0.value?.model }
    }
}

private struct RawIssueRecord: Decodable {
    struct Actor: Decodable { let login: String }
    struct Repository: Decodable { let nameWithOwner: String }
    struct Label: Decodable { let name: String }
    struct IssueType: Decodable { let name: String }
    struct Project: Decodable {
        let number: Int
        let title: String
    }
    struct Event: Decodable {
        let __typename: String
        let createdAt: Date?
        let status: String?
        let project: Project?
    }
    struct PullRequest: Decodable {
        struct CommitNode: Decodable {
            struct Commit: Decodable { let authoredDate: Date }
            let commit: Commit
        }
        struct Review: Decodable { let submittedAt: Date? }
        let number: Int
        let url: URL
        let createdAt: Date
        let mergedAt: Date?
        let state: String
        let commits: Connection<CommitNode>?
        let reviews: Connection<Review>?
    }

    let id: String
    let number: Int
    let title: String
    let url: URL
    let createdAt: Date
    let closedAt: Date?
    let stateReason: String?
    let repository: Repository
    let assignees: Connection<Actor>
    let labels: Connection<Label>?
    let issueType: IssueType?
    let milestone: Milestone?
    let parent: Parent?
    let timelineItems: Connection<Lossy<Event>>

    struct Milestone: Decodable { let title: String }
    struct Parent: Decodable { let id: String }
    let closedByPullRequestsReferences: Connection<Lossy<PullRequest>>?
    let projectItems: Connection<Lossy<ProjectItem>>?

    struct ProjectItem: Decodable {
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
            let field: Field?
        }
        let project: Project
        let fieldValues: Connection<Lossy<FieldValue>>

        var model: IssueProjectFields {
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
                        let position = field.options?.firstIndex { $0.id == value.optionId } ?? Int.max
                        values[name] = .option(name: option, position: position)
                    }
                case "ITERATION":
                    if let title = value.title, let start = value.startDate.flatMap({ try? Date($0, strategy: .iso8601.year().month().day()) }) {
                        values[name] = .iteration(title: title, start: start)
                    }
                default: break
                }
            }
            return IssueProjectFields(projectNumber: project.number, projectTitle: project.title, values: values)
        }
    }

    static let fields = """
        ... on Issue {
          id number title url createdAt closedAt stateReason
          repository { nameWithOwner }
          assignees(first: 10) { nodes { login } }
          labels(first: 20) { nodes { name } }
          issueType { name }
          milestone { title }
          parent { id }
          timelineItems(itemTypes: [PROJECT_V2_ITEM_STATUS_CHANGED_EVENT, ASSIGNED_EVENT, REOPENED_EVENT, SUB_ISSUE_ADDED_EVENT], first: 100) {
            nodes {
              __typename
              ... on ProjectV2ItemStatusChangedEvent { createdAt status project { number title } }
              ... on AssignedEvent { createdAt }
              ... on ReopenedEvent { createdAt }
              ... on SubIssueAddedEvent { createdAt }
            }
          }
          projectItems(first: 5) {
            nodes {
              project { number title }
              fieldValues(first: 30) {
                nodes {
                  ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name dataType } } }
                  ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { name dataType } } }
                  ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name dataType } } }
                  ... on ProjectV2ItemFieldSingleSelectValue { name optionId field { ... on ProjectV2FieldCommon { name dataType } ... on ProjectV2SingleSelectField { options { id } } } }
                  ... on ProjectV2ItemFieldIterationValue { title startDate field { ... on ProjectV2FieldCommon { name dataType } } }
                }
              }
            }
          }
          closedByPullRequestsReferences(first: 5, includeClosedPrs: true) {
            nodes {
              number url createdAt mergedAt state
              commits(last: 50) { nodes { commit { authoredDate } } }
              reviews(last: 20) { nodes { submittedAt } }
            }
          }
        }
        """

    var model: IssueRecord {
        let events = timelineItems.nodes.compactMap(\.value)
        func dates(_ type: String) -> [Date] {
            events.filter { $0.__typename == type }.compactMap(\.createdAt).sorted()
        }
        return IssueRecord(
            id: id,
            number: number,
            title: title,
            url: url,
            repo: repository.nameWithOwner,
            assignees: assignees.nodes.map(\.login),
            labels: labels?.nodes.map(\.name) ?? [],
            issueType: issueType?.name,
            milestone: milestone?.title,
            parentID: parent?.id,
            createdAt: createdAt,
            closedAt: closedAt,
            stateReason: stateReason,
            statusChanges: events
                .filter { $0.__typename == "ProjectV2ItemStatusChangedEvent" }
                .compactMap { event in
                    guard let at = event.createdAt, let status = event.status, !status.isEmpty else { return nil }
                    return IssueStatusChange(at: at, status: status, projectNumber: event.project?.number, projectTitle: event.project?.title)
                }
                .sorted { $0.at < $1.at },
            assignedAt: dates("AssignedEvent"),
            reopenedAt: dates("ReopenedEvent"),
            subIssuesAddedAt: dates("SubIssueAddedEvent"),
            linkedPullRequests: (closedByPullRequestsReferences?.nodes ?? []).compactMap(\.value).map { pr in
                IssueLinkedPullRequest(
                    number: pr.number,
                    url: pr.url,
                    createdAt: pr.createdAt,
                    mergedAt: pr.mergedAt,
                    state: pr.state,
                    activityAt: ((pr.commits?.nodes ?? []).map(\.commit.authoredDate) + (pr.reviews?.nodes ?? []).compactMap(\.submittedAt)).sorted()
                )
            },
            projectFields: (projectItems?.nodes ?? []).compactMap(\.value).map(\.model)
        )
    }
}
