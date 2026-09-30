import SwiftUI

/// An issue's story, as the Standup draws a day: opened, assigned, each
/// board move, sub-issues added, reopened and closed, its comments, and its
/// linked PRs' own activity (opened, every commit with its message and
/// lines, reviews, merged), grouped by day with who did each. PRs the work
/// log hasn't got are fetched when the timeline opens.
struct IssueTimelineSection: View {
    @Environment(IssueStore.self) private var issueStore
    @Environment(WorkLogStore.self) private var workLog
    @Environment(DetailStore.self) private var details
    @Environment(OrgStore.self) private var orgs
    let reference: IssueReference

    var body: some View {
        if let record = issueStore.history(for: reference.org)?.issues[reference.id] {
            let days = Self.days(items(record))
            Section(header: SectionHeader(title: "Timeline", count: days.reduce(0) { $0 + $1.items.count })) {
                ForEach(days, id: \.day) { day in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        // Every commit listed, with its message and lines, as
                        // the Standup's Commits toggle shows them.
                        StandupTimelineList(org: reference.org, items: day.items, showAllCommits: true, showAvatars: true)
                    }
                    .padding(.vertical, 2)
                }
            }
            .task(id: record.id) {
                await workLog.loadLinked(org: reference.org, urls: record.linkedPullRequests.map(\.url))
            }
        }
    }

    /// Everything, in time order, with runs of commits folded.
    private func items(_ record: IssueRecord) -> [StandupItem] {
        let issue = StandupItem.Subject.issue(record)
        let owner = person(record.assignees.first ?? record.author)
        var items: [StandupItem] = [
            StandupItem(at: record.createdAt, kind: .issueOpened, subject: issue, person: person(record.author)),
        ]
        // GitHub doesn't say who assigned or moved it, so these are the
        // assignee's, as on the Standup.
        items += record.assignedAt.map { StandupItem(at: $0, kind: .assigned, subject: issue, person: owner) }
        items += record.statusChanges.map { StandupItem(at: $0.at, kind: .moved($0.status), subject: issue, person: owner) }
        items += record.subIssuesAddedAt.map { StandupItem(at: $0, kind: .subIssueAdded, subject: issue, person: owner) }
        items += record.reopenedAt.map { StandupItem(at: $0, kind: .reopened, subject: issue, person: owner) }
        if let closedAt = record.closedAt {
            items.append(StandupItem(at: closedAt, kind: .issueClosed, subject: issue, person: owner))
        }
        for comment in details.detail(for: record.id)?.recentComments ?? [] {
            let firstLine = comment.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? comment.body
            items.append(StandupItem(at: comment.createdAt, kind: .comment(firstLine), subject: issue, person: comment.author ?? person(nil)))
        }
        for linked in record.linkedPullRequests {
            items += pullRequestItems(linked)
        }
        items.sort { ($0.at, StandupItem.rank($0.kind)) < ($1.at, StandupItem.rank($1.kind)) }
        return StandupItem.folded(items)
    }

    /// A linked PR's activity: all of it when the work log has the PR,
    /// else just when it was opened and merged.
    private func pullRequestItems(_ linked: IssueLinkedPullRequest) -> [StandupItem] {
        let stored = workLog.pullRequest(org: reference.org, url: linked.url)
        let pr = stored ?? WorkLogPullRequest(
            id: linked.url.absoluteString,
            number: linked.number,
            title: "Pull request #\(linked.number)",
            url: linked.url,
            repo: linked.url.pathComponents.dropFirst().prefix(2).joined(separator: "/"),
            author: nil,
            createdAt: linked.createdAt,
            mergedAt: linked.mergedAt,
            closedAt: linked.mergedAt,
            mergedBy: nil,
            commits: [],
            reviews: []
        )
        let subject = StandupItem.Subject.pullRequest(pr)
        var items = [StandupItem(at: pr.createdAt, kind: .opened, subject: subject, person: person(pr.author))]
        items += pr.commits.map { StandupItem(at: $0.authoredAt, kind: .commits([$0]), subject: subject, person: person($0.author ?? pr.author)) }
        items += pr.reviews.map { StandupItem(at: $0.submittedAt, kind: .review($0), subject: subject, person: person($0.author)) }
        if let mergedAt = pr.mergedAt {
            items.append(StandupItem(at: mergedAt, kind: .merged, subject: subject, person: person(pr.mergedBy ?? pr.author)))
        } else if let closedAt = pr.closedAt {
            items.append(StandupItem(at: closedAt, kind: .closed, subject: subject, person: person(pr.author)))
        }
        return items
    }

    /// The org member, for their name and avatar, else just the login.
    private func person(_ login: String?) -> Person {
        guard let login else { return Person(login: "", name: "Someone", avatarUrl: nil) }
        if let member = orgs.snapshot(for: reference.org)?.members.first(where: { $0.login == login }) { return member }
        return Person(login: login, name: nil, avatarUrl: URL(string: "https://github.com/\(login).png?size=64"))
    }

    /// Items by calendar day, oldest first.
    private static func days(_ items: [StandupItem]) -> [(day: Date, items: [StandupItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.at) }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }
}
