import Foundation

/// One board field set, or cleared, on one issue: a row of the confirm sheet.
struct FieldChange: Identifiable, Hashable {
    let issue: IssueRecord
    let field: String
    /// The option or iteration by name; nil clears the field.
    let value: String?

    var id: String { "\(issue.id)\u{1}\(field)" }

    var summary: String {
        value.map { "\(field) to \($0)" } ?? "Clear \(field)"
    }
}

/// Board field writes, from the field views and the investments board.
enum FieldWriter {
    /// Sets a single-select or iteration field on the issue's item on the
    /// board, adding it to the board first when it isn't on it (unless the
    /// field is only being cleared), and records the value in the issue
    /// history at once. A write.
    static func set(
        _ field: String,
        to value: String?,
        on issue: IssueRecord,
        board number: Int,
        title: String,
        boardID: String?,
        org: String,
        api: GitHubAPI,
        issues: IssueStore
    ) async throws {
        var items = try await api.projectItems(issueID: issue.id)
        if !items.contains(where: { $0.projectNumber == number }) {
            guard value != nil else { return }
            guard let boardID else {
                throw InvestmentWriteError.message("\(title) isn't an open board in \(org)")
            }
            try await api.addToProject(projectID: boardID, contentID: issue.id)
            items = try await api.projectItems(issueID: issue.id)
        }
        guard let item = items.first(where: { $0.projectNumber == number }) else {
            throw InvestmentWriteError.message("Couldn't find the issue on \(title)")
        }
        guard let projectField = item.fields.first(where: { $0.name.caseInsensitiveCompare(field) == .orderedSame }) else {
            throw InvestmentWriteError.message("\(title) has no field called \(field)")
        }
        guard let value else {
            try await api.setProjectField(projectID: item.projectID, itemID: item.id, field: projectField, value: nil)
            issues.recordFieldValue(org: org, issueID: issue.id, projectNumber: number, projectTitle: title, field: projectField.name, value: nil)
            return
        }
        switch projectField.kind {
        case .singleSelect(let options):
            guard let index = options.firstIndex(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame }) else {
                throw InvestmentWriteError.message("\(field) on \(title) has no option \(value)")
            }
            try await api.setProjectField(projectID: item.projectID, itemID: item.id, field: projectField, value: .option(options[index].id))
            issues.recordFieldValue(org: org, issueID: issue.id, projectNumber: number, projectTitle: title, field: projectField.name, value: .option(name: options[index].name, position: index))
        case .iteration(let options):
            guard let option = options.first(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame }) else {
                throw InvestmentWriteError.message("\(field) on \(title) has no iteration \(value)")
            }
            try await api.setProjectField(projectID: item.projectID, itemID: item.id, field: projectField, value: .option(option.id))
            issues.recordFieldValue(org: org, issueID: issue.id, projectNumber: number, projectTitle: title, field: projectField.name, value: .iteration(title: option.name, start: option.start ?? .now))
        case .text, .number, .date:
            throw InvestmentWriteError.message("\(field) on \(title) takes text, a number or a date, not an option")
        }
    }
}
