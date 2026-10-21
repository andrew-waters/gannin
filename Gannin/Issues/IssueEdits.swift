import Foundation

/// How a change written to GitHub from the app reaches what's stored: the
/// issue in the shared issue store, through `IssueStore`, and the item on
/// each cached board, through `ProjectStore`. Every such write goes through
/// here, so one never changes without the other.
enum IssueEdits {
    /// A board field saved on an issue (nil clears it). `itemID` is the
    /// issue's item on that board.
    static func setField(
        org: String, issueID: String, itemID: String, projectNumber: Int, projectTitle: String,
        field: String, value: IssueFieldValue?, issues: IssueStore, projects: ProjectStore
    ) {
        issues.recordFieldValue(org: org, issueID: issueID, projectNumber: projectNumber, projectTitle: projectTitle, field: field, value: value)
        projects.recordFieldValue(org: org, number: projectNumber, itemID: itemID, field: field, value: value)
    }

    /// An issue's labels after a change.
    static func setLabels(org: String, issueID: String, labels: [String], issues: IssueStore, projects: ProjectStore) {
        issues.recordLabels(org: org, issueID: issueID, labels: labels)
        projects.recordLabels(org: org, contentID: issueID, labels: labels)
    }

    /// An issue's assignees after a change.
    static func setAssignees(org: String, issueID: String, assignees: [Person], issues: IssueStore, projects: ProjectStore) {
        issues.recordAssignees(org: org, issueID: issueID, assignees: assignees)
        projects.recordAssignees(org: org, contentID: issueID, assignees: assignees)
    }
}
