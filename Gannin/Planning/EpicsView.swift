import SwiftUI

/// Planning › Epics: every issue with sub-issues in the history, with how
/// far along they are, what's in progress, the plans about it, its PRs,
/// and how long since anything moved. Quiet ones (two weeks) are marked.
/// Sub-issues closed before the history's start aren't counted.
struct EpicsView: View {
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    @Environment(\.navigate) private var navigate
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    let org: String
    @State private var search = ""
    @State private var showsClosed = false
    @State private var expanded: Set<String> = []

    static let quietAfter: TimeInterval = 14 * 86_400

    struct Epic: Identifiable {
        let issue: IssueRecord
        let children: [IssueRecord]
        let inProgress: Int
        let lastMoved: Date
        let pullRequests: [IssueLinkedPullRequest]
        let plans: Int

        var id: String { issue.id }
        var done: Int { children.filter { !$0.isOpen }.count }
        var progress: Double { children.isEmpty ? 0 : Double(done) / Double(children.count) }
    }

    var body: some View {
        let epics = epics()
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                FilterSearchField(text: $search, prompt: "Search epics")
                    .frame(maxWidth: 280)
                Toggle("Closed too", isOn: $showsClosed)
                    .checkboxToggle()
                Spacer()
                Text("\(epics.count) epic\(epics.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            if issueStore.history(for: org) == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if epics.isEmpty {
                ContentUnavailableView("No epics", systemImage: "square.stack.3d.up", description: Text("Issues with sub-issues show here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(epics) { epic in
                        epicRow(epic)
                        if expanded.contains(epic.id) {
                            ForEach(epic.children.sorted { ($0.isOpen ? 0 : 1, $0.number) < ($1.isOpen ? 0 : 1, $1.number) }) { child in
                                childRow(child)
                            }
                        }
                    }
                }
            }
        }
        .task(id: org) { await issueStore.sync(org, windowDays: MetricsWindow(code: windowDays).syncDays()) }
    }

    private func epics() -> [Epic] {
        guard let history = issueStore.history(for: org) else { return [] }
        let config = configs.config(for: org)
        let index = config.harness.flatMap { harness.index(for: org, $0) }
        let workflow = config.workflow
        let children = Dictionary(grouping: history.issues.values.filter { $0.parentID != nil }) { $0.parentID! }
        let words = search.lowercased().split(separator: " ")
        return children.compactMap { parentID, kids -> Epic? in
            guard let issue = history.issues[parentID], showsClosed || issue.isOpen,
                  !config.excludedRepos.contains(issue.repo) else { return nil }
            let text = "\(issue.title) \(issue.repo) \(issue.number)".lowercased()
            guard words.allSatisfy({ text.contains($0) }) else { return nil }
            let everything = [issue] + kids
            let moments = everything.flatMap { record in
                record.statusChanges.map(\.at) + [record.closedAt, record.createdAt].compactMap { $0 }
                    + record.linkedPullRequests.flatMap { $0.activityAt + [$0.createdAt] + [$0.mergedAt].compactMap { $0 } }
            }
            let inProgress = kids.filter { kid in
                kid.isOpen && (kid.statusChanges.last.map { workflow.isInProgress($0.status) } ?? false)
            }.count
            let plans = index?.matches(repo: issue.repo, number: issue.number).filter { $0.isSubject && $0.document.followsStandard }.count ?? 0
            return Epic(
                issue: issue, children: kids, inProgress: inProgress,
                lastMoved: moments.max() ?? issue.createdAt,
                pullRequests: kids.flatMap(\.linkedPullRequests), plans: plans
            )
        }
        .sorted { ($0.issue.isOpen ? 0 : 1, -$0.lastMoved.timeIntervalSince1970) < ($1.issue.isOpen ? 0 : 1, -$1.lastMoved.timeIntervalSince1970) }
    }

    private func epicRow(_ epic: Epic) -> some View {
        let quiet = epic.issue.isOpen && Date.now.timeIntervalSince(epic.lastMoved) > Self.quietAfter
        return HStack(spacing: 10) {
            Button {
                if expanded.remove(epic.id) == nil { expanded.insert(epic.id) }
            } label: {
                Image(systemName: expanded.contains(epic.id) ? "chevron.down" : "chevron.right")
                    .frame(width: 12)
            }
            .buttonStyle(.borderless)
            Button {
                navigate?(.issueReference(IssueReference(org: org, record: epic.issue)))
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(epic.issue.title).fontWeight(.medium).lineLimit(1)
                            if !epic.issue.isOpen { Text("Closed").font(.caption).foregroundStyle(.purple) }
                            if quiet {
                                Label("Quiet", systemImage: "moon.zzz")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .help("Nothing has moved for two weeks")
                            }
                        }
                        Text("\(epic.issue.repo.split(separator: "/").last ?? "")#\(String(epic.issue.number)) · moved \(epic.lastMoved.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if epic.plans > 0 {
                        Label("\(epic.plans)", systemImage: "list.bullet.clipboard")
                            .foregroundStyle(.secondary)
                            .help("Plans and requirements about it")
                    }
                    let open = epic.pullRequests.filter { $0.state == "OPEN" }.count
                    let merged = epic.pullRequests.filter { $0.mergedAt != nil }.count
                    if !epic.pullRequests.isEmpty {
                        Text("\(open) open, \(merged) merged PRs")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if epic.inProgress > 0 {
                        Text("\(epic.inProgress) in progress")
                            .font(.callout)
                            .foregroundStyle(ChartPalette.blue)
                    }
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(epic.done) of \(epic.children.count)")
                            .font(.callout.monospacedDigit())
                        ProgressView(value: epic.progress)
                            .frame(width: 120)
                            .tint(epic.progress >= 1 ? ChartPalette.good : .accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }

    private func childRow(_ child: IssueRecord) -> some View {
        Button {
            navigate?(.issueReference(IssueReference(org: org, record: child)))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: child.isOpen ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(child.isOpen ? .green : .purple)
                Text(child.title).lineLimit(1)
                Spacer()
                if let status = child.statusChanges.last?.status {
                    Text(status).foregroundStyle(.secondary)
                }
                Text("#\(String(child.number))").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.leading, 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
