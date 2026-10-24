import Foundation

/// What's waiting for triage, worked out once for Prioritisation and
/// Standup so their lists can't drift apart.
enum TriageQueue {
    /// Issues the workload counts: excluded repos and hidden issues left
    /// out, and with a team picked, those assigned to it or to nobody.
    static func counted(_ issues: [IssueRecord], config: OrgConfig, hidden: Set<String>, team: Team?) -> [IssueRecord] {
        let excluded = config.repoExclusion
        let members = team.map { Set($0.members) }
        return issues
            .filter { !excluded.contains($0.repo) && !hidden.contains($0.id) }
            .filter { issue in members.map { team in issue.assignees.contains(where: team.contains) || issue.assignees.isEmpty } ?? true }
    }

    /// Open issues with no Status on the board, or not on it: newest first.
    static func untriaged(_ issues: [IssueRecord], board: Int) -> [IssueRecord] {
        issues
            .filter { issue in
                guard issue.isOpen else { return false }
                guard let fields = issue.fields(onProject: board) else { return true }
                return fields.values["Status"] == nil
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
