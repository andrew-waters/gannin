import SwiftUI

/// Identifies a PR for its own window. Carries enough to draw a header even
/// when no store holds the PR.
struct PullRequestReference: Codable, Hashable {
    let org: String
    let id: String
    let number: Int
    let title: String
    let repo: String
    let url: URL

    init(org: String, id: String, number: Int, title: String, repo: String, url: URL) {
        self.org = org
        self.id = id
        self.number = number
        self.title = title
        self.repo = repo
        self.url = url
    }

    init(org: String, pullRequest pr: WorkLogPullRequest) {
        self.org = org
        id = pr.id
        number = pr.number
        title = pr.title
        repo = pr.repo
        url = pr.url
    }
}

/// A PR in a window of its own: header, who opened and merged it, its
/// activity from the work log, and its description and comments.
struct PullRequestWindow: View {
    @Environment(OrgStore.self) private var orgs
    @Environment(WorkLogStore.self) private var workLog
    @Environment(DetailStore.self) private var details
    let reference: PullRequestReference
    /// Shown as a page in a main window rather than a window of its own, so
    /// it leaves the window's title alone.
    var isEmbedded = false

    var body: some View {
        let open = orgs.snapshot(for: reference.org)?.openPullRequests.first { $0.id == reference.id }
        let logged = workLog.history(for: reference.org)?.pullRequests[reference.id]
        List {
            Section {
                ItemHeader(title: reference.title, reference: "\(reference.repo)#\(reference.number)", url: reference.url, pill: pill(open: open, logged: logged))
            }
            if let logged {
                Section {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        if let author = logged.author {
                            fact("Opened", "\(author), \(logged.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                        if let mergedAt = logged.mergedAt {
                            fact("Merged", "\(logged.mergedBy ?? logged.author ?? "-"), \(mergedAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                        fact("Commits", "\(logged.commits.count), \(logged.commits.map { $0.additions + $0.deletions }.reduce(0, +)) lines changed")
                        fact("Reviews", "\(logged.reviews.count)")
                    }
                    .padding(.vertical, 4)
                }
                Section(header: SectionHeader(title: "Activity", count: logged.events.count)) {
                    ForEach(logged.events.sorted { $0.at > $1.at }) { event in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(ChartPalette.slot(event.kind.slot))
                                .frame(width: 8, height: 8)
                            Text(event.kind.rawValue)
                            Text(event.login).foregroundStyle(.secondary)
                            if event.kind == .commit {
                                Text("\(event.lines) lines").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(event.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            DescriptionSections(id: reference.id, url: reference.url)
        }
        .ownWindowTitle(isEmbedded ? nil : "\(reference.repo)#\(reference.number)", subtitle: reference.title)
        .task(id: reference.id) { await details.load(reference.id, updatedAt: open?.updatedAt) }
    }

    private func pill(open: PullRequest?, logged: WorkLogPullRequest?) -> Pill {
        if let open { return Pill(text: open.statusText, color: open.statusColor) }
        if logged?.mergedAt != nil { return Pill(text: "Merged", color: .purple) }
        return Pill(text: "Pull request", color: .secondary)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
