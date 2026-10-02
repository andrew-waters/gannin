import SwiftUI

/// How often the team recaps: periods of `days`, back and forward from a
/// day one started on, so "every other Monday" lands on the right Mondays.
struct RecapCadence: Codable, Hashable {
    var days = 14
    /// A day a period started on, at local midnight.
    var anchor = RecapCadence.defaultAnchor

    /// Monday 5 January 2026.
    static var defaultAnchor: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5)) ?? Calendar.current.startOfDay(for: .now)
    }

    /// The period holding the date, `offset` periods along.
    func period(containing date: Date, offset: Int = 0) -> DateInterval {
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: anchor)
        let length = max(1, days)
        let elapsed = calendar.dateComponents([.day], from: anchor, to: calendar.startOfDay(for: date)).day ?? 0
        let index = Int((Double(elapsed) / Double(length)).rounded(.down)) + offset
        let start = calendar.date(byAdding: .day, value: index * length, to: anchor) ?? anchor
        let end = calendar.date(byAdding: .day, value: length, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// "Every 2 weeks", "Every 10 days".
    var label: String {
        if days % 7 == 0 { return days == 7 ? "Every week" : "Every \(days / 7) weeks" }
        return "Every \(days) days"
    }
}

/// How the closed issues are grouped.
enum ClosedIssueGrouping: String, CaseIterable, Identifiable {
    case category = "Category"
    case person = "Person"
    case repository = "Repository"
    case epic = "Epic"

    var id: Self { self }
}

/// Issues closed in a range from the issue history, completed ones grouped
/// (by investment category, with its colour, by assignee, repo or parent
/// issue), then those closed as not planned. The Standup's Changelog shows
/// one day of it, Recap a period.
struct ClosedIssuesList: View {
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    let org: String
    let range: DateInterval
    let history: IssueHistory
    let config: OrgConfig
    let members: [Person]
    var grouping: ClosedIssueGrouping = .category
    /// Only issues assigned to these logins (`IssueFilters.unassigned` for
    /// none); everyone when empty.
    var people: Set<String> = []
    /// The day each closed rather than the time, over more than a day.
    var showsDay = false

    struct Group: Identifiable {
        let name: String
        /// Palette slot; nil for none.
        let slot: Int?
        var issues: [IssueRecord]

        var id: String { name }
    }

    var body: some View {
        let closed = Self.closed(in: range, history: history, config: config, people: people)
        let completed = closed.filter(\.isCompleted)
        let notPlanned = closed.filter { !$0.isCompleted }
        VStack(alignment: .leading, spacing: 22) {
            if closed.isEmpty {
                Text(people.isEmpty ? (showsDay ? "No issues closed in this period." : "No issues closed on this day.") : "None closed by the people picked.").foregroundStyle(.secondary)
            }
            ForEach(Self.groups(completed, by: grouping, history: history, config: config, members: members, people: people)) { group in
                section(group.name, count: group.issues.count, color: grouping == .category ? ChartPalette.slot(group.slot) : nil) {
                    ForEach(group.issues) { row($0) }
                }
            }
            if !notPlanned.isEmpty {
                section("Closed as not planned", count: notPlanned.count, color: nil) {
                    ForEach(notPlanned) { row($0) }
                }
            }
        }
    }

    /// Closed in the range, outside excluded repos, oldest first, and
    /// assigned to one of `people` when any are picked.
    static func closed(in range: DateInterval, history: IssueHistory, config: OrgConfig, people: Set<String> = []) -> [IssueRecord] {
        history.issues.values
            .filter { record in record.closedAt.map { $0 >= range.start && $0 < range.end } == true && !config.repoExclusion.contains(record.repo) }
            .filter { people.isEmpty || isAssigned($0, to: people) }
            .sorted { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
    }

    static func isAssigned(_ record: IssueRecord, to people: Set<String>) -> Bool {
        record.assignees.isEmpty ? people.contains(IssueFilters.unassigned) : record.assignees.contains(where: people.contains)
    }

    /// With people picked, grouping by person shows only theirs.
    static func groups(_ issues: [IssueRecord], by grouping: ClosedIssueGrouping, history: IssueHistory, config: OrgConfig, members: [Person], people: Set<String> = []) -> [Group] {
        switch grouping {
        case .category:
            // In the categories' order, the uncategorised last.
            let investments = config.investmentConfig
            var byCategory: [UUID: [IssueRecord]] = [:]
            var uncategorised: [IssueRecord] = []
            for record in issues {
                let parent = record.parentID.flatMap { history.issues[$0] }
                if let (category, _) = investments.categorise(record, parent: parent) {
                    byCategory[category.id, default: []].append(record)
                } else {
                    uncategorised.append(record)
                }
            }
            var groups = investments.categories.compactMap { category in
                byCategory[category.id].map { Group(name: category.name, slot: category.slot, issues: $0) }
            }
            if !uncategorised.isEmpty { groups.append(Group(name: "Uncategorised", slot: nil, issues: uncategorised)) }
            return groups
        case .person:
            // Under each assignee; most closed first, the unassigned last.
            var byPerson: [String: [IssueRecord]] = [:]
            var nobody: [IssueRecord] = []
            for record in issues {
                if record.assignees.isEmpty { nobody.append(record) }
                for login in record.assignees where people.isEmpty || people.contains(login) { byPerson[login, default: []].append(record) }
            }
            var groups = byPerson.map { login, issues in
                Group(name: members.first { $0.login == login }?.displayName ?? login, slot: nil, issues: issues)
            }
            .sorted { ($0.issues.count, $1.name) > ($1.issues.count, $0.name) }
            if !nobody.isEmpty, people.isEmpty || people.contains(IssueFilters.unassigned) { groups.append(Group(name: "Unassigned", slot: nil, issues: nobody)) }
            return groups
        case .repository:
            return Dictionary(grouping: issues, by: \.repo)
                .map { Group(name: $0.key.split(separator: "/").last.map(String.init) ?? $0.key, slot: nil, issues: $0.value) }
                .sorted { ($0.issues.count, $1.name) > ($1.issues.count, $0.name) }
        case .epic:
            // By parent issue; those with none last.
            var groups = Dictionary(grouping: issues.filter { $0.parentID != nil }, by: { $0.parentID! })
                .map { id, issues in
                    let parent = history.issues[id]
                    return Group(name: parent.map { "\($0.title) (\(StandupRow.number($0.repo, $0.number)))" } ?? "A parent not in the history", slot: nil, issues: issues)
                }
                .sorted { ($0.issues.count, $1.name) > ($1.issues.count, $0.name) }
            let loose = issues.filter { $0.parentID == nil }
            if !loose.isEmpty { groups.append(Group(name: "No parent", slot: nil, issues: loose)) }
            return groups
        }
    }

    private func section<Content: View>(_ title: String, count: Int, color: Color?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let color {
                    RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
                }
                Text(title).font(.headline)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
        }
    }

    private func row(_ record: IssueRecord) -> some View {
        let reference = IssueReference(org: org, record: record)
        let assignees = record.assignees.map { login in
            members.first { $0.login == login } ?? Person(login: login, name: nil, avatarUrl: URL(string: "https://github.com/\(login).png?size=64"))
        }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: record.isCompleted ? "checkmark.circle.fill" : "slash.circle")
                .foregroundStyle(record.isCompleted ? Color.purple : Color.secondary)
                .frame(width: 18)
            Text(record.closedAt.map { showsDay ? $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) : StandupRow.clock($0) } ?? "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: showsDay ? 84 : 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    navigate?(.issueReference(reference))
                } label: {
                    Text(verbatim: record.title)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opensElsewhere(.issueReference(reference))
                HStack(spacing: 6) {
                    Text(verbatim: StandupRow.number(record.repo, record.number))
                    if let type = record.issueType { Text(verbatim: "· \(type)") }
                    if let author = record.author { Text(verbatim: "· opened by \(author)") }
                    let merged = record.linkedPullRequests.filter { $0.mergedAt != nil }
                    if !merged.isEmpty {
                        Text("· via")
                        ForEach(merged, id: \.url) { pr in
                            Button {
                                openURL(pr.url)
                            } label: {
                                Text(verbatim: "#\(String(pr.number))").foregroundStyle(.link)
                            }
                            .buttonStyle(.plain)
                            .help("Open PR #\(String(pr.number)) on GitHub")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            AvatarStack(people: assignees)
        }
        .font(.callout)
        .padding(.vertical, 6)
    }
}

/// Rituals › Recap: everything closed over the team's period (two weeks
/// by default, set per org), for the meeting that looks back on it. Arrows
/// step through periods; the latest whole one shows first, and the one
/// under way so far is a step on. Notes turn it into Markdown to copy,
/// rewrite with Claude or commit to the harness.
struct RecapView: View {
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(OrgStore.self) private var orgs
    @Environment(AuthStore.self) private var auth
    let org: String
    /// Whose issues, kept per window: logins, `IssueFilters.unassigned`.
    @SceneStorage("recapPeople") private var storedPeople = ""
    /// Periods from the one under way: -1 is the last whole one.
    @State private var offset = -1
    @AppStorage("recapGrouping") private var grouping: ClosedIssueGrouping = .category
    @State private var showsCadence = false
    @State private var showsNotes = false
    @State private var showsSpeech = false

    var body: some View {
        let config = configs.config(for: org)
        let period = config.recapCadence.period(containing: .now, offset: offset)
        let members = orgs.snapshot(for: org)?.members ?? []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    content(period, config: config, members: members)
                        .sectionContent()
                } header: {
                    PinnedHeader { header(period, config: config) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar { toolbar(config, period: period, members: members) }
        .sheet(isPresented: $showsNotes) {
            let date = period.start.formatted(.iso8601.year().month().day())
            NotesSheet(
                title: "Recap, \(Self.label(period))\(peopleTitle(members).map { ", \($0)" } ?? "")",
                org: org, path: "recaps/\(date).md", message: "Gannin: recap from \(date)",
                rewrite: "Rewrite this recap of what the team closed as a short summary for the meeting: the themes and what shipped, in a few bullets per category, then anything dropped.",
                build: {
                    guard let history = issueStore.history(for: org) else { return "The issue history hasn't loaded yet." }
                    return Self.markdown(period, history: history, config: config, members: members, grouping: grouping, people: people)
                }
            )
        }
        .sheet(isPresented: $showsSpeech) {
            speechSheet(period, config: config, members: members)
        }
        .task(id: "\(org) \(period.start.timeIntervalSince1970)") {
            // Back to the period before, for the comparison.
            let before = config.recapCadence.period(containing: period.start, offset: -1)
            let days = max(14, Int(Date.now.timeIntervalSince(before.start) / 86_400) + 2)
            await issueStore.sync(org, windowDays: days)
        }
    }

    private var people: Set<String> {
        get { StoredSet.set(storedPeople) }
        nonmutating set { storedPeople = StoredSet.string(newValue) }
    }

    /// "Sam Lee", or "3 people", for the notes' title.
    private func peopleTitle(_ members: [Person]) -> String? {
        let people = people
        guard !people.isEmpty else { return nil }
        guard people.count == 1, let login = people.first else { return "\(people.count) people" }
        return login == IssueFilters.unassigned ? "unassigned" : members.first { $0.login == login }?.displayName ?? login
    }

    /// Me and Unassigned, then whoever closed something in the period, by
    /// how many, each with their count there.
    private func personMenu(_ period: DateInterval, config: OrgConfig, members: [Person]) -> some View {
        let closed = issueStore.history(for: org).map { ClosedIssuesList.closed(in: period, history: $0, config: config) } ?? []
        var counts: [String: Int] = [:]
        for record in closed {
            if record.assignees.isEmpty { counts[IssueFilters.unassigned, default: 0] += 1 }
            for login in Set(record.assignees) { counts[login, default: 0] += 1 }
        }
        let me = auth.viewer?.login
        var leading: [FilterOption] = []
        if let me { leading.append(FilterOption(value: me, title: "Me", count: counts[me] ?? 0)) }
        leading.append(FilterOption(value: IssueFilters.unassigned, title: "Unassigned", count: counts[IssueFilters.unassigned] ?? 0))
        // Anyone picked stays listed in a period they closed nothing in.
        let logins = Set(counts.keys).union(people).subtracting([IssueFilters.unassigned, me ?? "\u{0}"])
        let options = logins.map { login in
            FilterOption(value: login, title: members.first { $0.login == login }?.displayName ?? login, count: counts[login] ?? 0)
        }
        .sorted(byCount: true)
        return FilterMenu(title: "Person", leading: leading, options: options, picked: Binding(get: { people }, set: { people = $0 }))
    }

    @ViewBuilder
    private func speechSheet(_ period: DateInterval, config: OrgConfig, members: [Person]) -> some View {
        if let history = issueStore.history(for: org) {
            let picked = people
            let previous = ClosedIssuesList.closed(in: config.recapCadence.period(containing: period.start, offset: -1), history: history, config: config, people: picked)
            // One person picked speaks as themselves.
            let speaker = picked.count == 1 ? picked.first.flatMap { login in login == IssueFilters.unassigned ? nil : members.first { $0.login == login }?.displayName ?? login } : nil
            RecapSpeechSheet(
                org: org,
                title: "What to say, \(Self.label(period))\(peopleTitle(members).map { ", \($0)" } ?? "")",
                speaker: speaker,
                notes: Self.markdown(period, history: history, config: config, members: members, grouping: .category, people: picked),
                previousCompleted: offset == 0 ? nil : previous.filter(\.isCompleted).count,
                key: "\(org)|\(period.start.timeIntervalSince1970)|\(StoredSet.string(picked))|\(offset == 0 ? Int(Date.now.timeIntervalSince1970 / 3600) : 0)"
            )
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ config: OrgConfig, period: DateInterval, members: [Person]) -> some ToolbarContent {
        ToolbarItem {
            personMenu(period, config: config, members: members)
                .help("Only the issues assigned to the people picked")
        }
        ToolbarItem {
            Button {
                showsSpeech = true
            } label: {
                Label("Speech", systemImage: "text.bubble")
            }
            .disabled(issueStore.history(for: org) == nil)
            .help("Have Claude write the period up as a casual spoken update, to read out at the meeting")
        }
        ToolbarItem {
            Button {
                showsNotes = true
            } label: {
                Label("Notes", systemImage: "note.text")
            }
            .help("The period as notes, to copy, rewrite with Claude, or commit to the harness")
        }
        ToolbarItem {
            Picker("Group by", selection: $grouping) {
                ForEach(ClosedIssueGrouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            .help("Group what was completed by investment category, person, repository or parent issue")
        }
        ToolbarItem {
            Button {
                showsCadence = true
            } label: {
                Label(config.recapCadence.label, systemImage: "calendar.badge.clock")
            }
            .help("How long a period is, and when one starts, for everyone in \(org)")
            .popover(isPresented: $showsCadence) {
                RecapCadenceEditor(org: org)
            }
        }
        ToolbarItem {
            ControlGroup {
                Button { offset -= 1 } label: {
                    Label("Earlier", systemImage: "chevron.left")
                }
                .help("The period before")
                Button("Last") { offset = -1 }
                    .disabled(offset == -1)
                    .help("The last whole period, which the recap looks back on")
                Button("This") { offset = 0 }
                    .disabled(offset == 0)
                    .help("The period under way, so far")
                Button { offset += 1 } label: {
                    Label("Later", systemImage: "chevron.right")
                }
                .help("The period after, up to the one under way")
                .disabled(offset >= 0)
            }
            .fixedSize()
        }
    }

    private func header(_ period: DateInterval, config: OrgConfig) -> some View {
        let history = issueStore.history(for: org)
        let picked = people
        let closed = history.map { ClosedIssuesList.closed(in: period, history: $0, config: config, people: picked) } ?? []
        let completed = closed.filter(\.isCompleted).count
        let previous = history.map {
            ClosedIssuesList.closed(in: config.recapCadence.period(containing: period.start, offset: -1), history: $0, config: config, people: picked).filter(\.isCompleted).count
        }
        let people = Set(closed.filter(\.isCompleted).flatMap(\.assignees).filter { picked.isEmpty || picked.contains($0) }).count
        return HStack(spacing: 10) {
            Text(Self.label(period))
            if offset == 0 {
                Text("so far").foregroundStyle(.secondary).fontWeight(.regular)
            }
            if history != nil {
                Group {
                    Text(completed == 1 ? "1 completed" : "\(completed) completed")
                    if people > 0 { Text("by \(people == 1 ? "1 person" : "\(people) people")") }
                    if let previous, offset != 0 {
                        Text(Self.change(completed, previous))
                    }
                    let notPlanned = closed.count - completed
                    if notPlanned > 0 { Text("\(notPlanned) not planned") }
                }
                .foregroundStyle(.secondary)
                .fontWeight(.regular)
            }
            if issueStore.syncing.contains(org) {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func content(_ period: DateInterval, config: OrgConfig, members: [Person]) -> some View {
        if let history = issueStore.history(for: org) {
            ClosedIssuesList(org: org, range: period, history: history, config: config, members: members, grouping: grouping, people: people, showsDay: true)
        } else if let error = issueStore.errors[org] {
            Banner(message: "Couldn't load issues: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching the issue history.").foregroundStyle(.secondary)
            }
        }
    }

    /// "15 Sep - 28 Sep 2026": the last day the period includes.
    static func label(_ period: DateInterval) -> String {
        let last = Calendar.current.date(byAdding: .day, value: -1, to: period.end) ?? period.end
        let sameYear = Calendar.current.isDate(period.start, equalTo: last, toGranularity: .year)
        let start = sameYear ? period.start.formatted(.dateTime.day().month(.abbreviated)) : period.start.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(start) - \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    static func change(_ now: Int, _ before: Int) -> String {
        if now == before { return "as many as the period before" }
        return now > before ? "\(now - before) more than the period before" : "\(before - now) fewer than the period before"
    }

    /// The period as notes: what was completed, grouped as on the page,
    /// then what was closed as not planned.
    static func markdown(_ period: DateInterval, history: IssueHistory, config: OrgConfig, members: [Person], grouping: ClosedIssueGrouping, people: Set<String> = []) -> String {
        let closed = ClosedIssuesList.closed(in: period, history: history, config: config, people: people)
        let completed = closed.filter(\.isCompleted)
        let notPlanned = closed.filter { !$0.isCompleted }
        func line(_ record: IssueRecord) -> String {
            let who = record.assignees.isEmpty ? "" : " (\(record.assignees.map { login in members.first { $0.login == login }?.displayName ?? login }.joined(separator: ", ")))"
            return "- [\(StandupRow.number(record.repo, record.number))](\(record.url.absoluteString)) \(record.title)\(who)"
        }
        var lines = ["# Recap, \(label(period))", "", "\(completed.count) completed\(notPlanned.isEmpty ? "" : ", \(notPlanned.count) closed as not planned").", ""]
        for group in ClosedIssuesList.groups(completed, by: grouping, history: history, config: config, members: members, people: people) {
            lines += ["## \(group.name)", ""] + group.issues.map(line) + [""]
        }
        if !notPlanned.isEmpty {
            lines += ["## Closed as not planned", ""] + notPlanned.map(line) + [""]
        }
        return lines.joined(separator: "\n")
    }
}

/// The period's length and a day one started on, for the whole org (kept
/// with the team's settings).
struct RecapCadenceEditor: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String

    var body: some View {
        let cadence = configs.config(for: org).recapCadence
        Form {
            Picker("Every", selection: Binding(get: { cadence.days }, set: { days in update { $0.days = days } })) {
                ForEach([7, 14, 21, 28, 42], id: \.self) { days in
                    Text(days == 7 ? "Week" : "\(days / 7) weeks").tag(days)
                }
                if ![7, 14, 21, 28, 42].contains(cadence.days) {
                    Text("\(cadence.days) days").tag(cadence.days)
                }
            }
            Stepper("\(cadence.days) days", value: Binding(get: { cadence.days }, set: { days in update { $0.days = days } }), in: 1...90)
            DatePicker("A period started on", selection: Binding(get: { cadence.anchor }, set: { day in update { $0.anchor = Calendar.current.startOfDay(for: day) } }), displayedComponents: .date)
            Text("Periods run back and forward from that day, so pick the day the last one began. For everyone in \(org).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .frame(width: 340)
    }

    private func update(_ change: (inout RecapCadence) -> Void) {
        configs.update(org) { config in
            var cadence = config.recapCadence
            change(&cadence)
            config.recap = cadence == RecapCadence() ? nil : cadence
        }
    }
}

/// The period as a casual spoken update, written by Claude to be read out
/// in the room: themes rather than ticket numbers, people credited by first
/// name, and in the first person when it's one person's recap. Kept for the
/// launch per period, people and length, so reopening doesn't ask again.
struct RecapSpeechSheet: View {
    @Environment(\.dismiss) private var dismiss
    let org: String
    let title: String
    /// One person's recap, spoken as them; nil for the team's.
    let speaker: String?
    /// The period's notes, and the period before's count, as Claude's facts.
    let notes: String
    let previousCompleted: Int?
    let key: String

    enum Length: String, CaseIterable, Identifiable {
        case short = "About a minute"
        case normal = "Two or three minutes"

        var id: Self { self }
        var words: String { self == .short ? "120 to 180 words" : "300 to 450 words" }
    }

    @State private var length: Length = .normal
    @State private var context = ""
    @State private var text = ""
    @State private var working = false
    @State private var status: String?

    private static var written: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Picker("Length", selection: $length) {
                    ForEach(Length.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            }
            .padding(12)
            TextField("Anything to work in (a release, someone new, an incident)", text: $context, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            Divider()
            ScrollView {
                Group {
                    if text.isEmpty {
                        HStack(spacing: 8) {
                            if working { ProgressView().controlSize(.small) }
                            Text(working ? "Claude is writing it." : "Nothing written yet.").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(text)
                            .font(.title3)
                            .lineSpacing(6)
                            .textSelection(.enabled)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if let status { Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                if working && !text.isEmpty { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(text.isEmpty ? "Write It" : "Write Again") { write() }
                    .disabled(working)
                    .help("Ask Claude for another take, with the length and anything to work in")
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    status = "Copied"
                }
                .disabled(text.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 640)
        .onAppear {
            if let kept = Self.written[cacheKey] { text = kept } else { write() }
        }
    }

    private var cacheKey: String { "\(key)|\(length.rawValue)" }

    private func write() {
        working = true
        status = nil
        let voice = speaker.map {
            "You're writing it for \($0) to say about their own work, in the first person (\"I\"), crediting anyone who worked with them by first name."
        } ?? "You're writing it for whoever's presenting to say on the team's behalf (\"we\"), crediting people by first name for what they did, so everyone gets a mention where they earned one."
        let extra = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
            Write a short spoken update for our team's in-person recap meeting, about what we closed over the period below. It will be read aloud, so write it the way someone talks: casual, warm and plain, in short sentences and paragraphs, with no headings, bullets, links, issue numbers or Markdown. \(voice)

            Group the work into a few themes (the categories below are a guide, not a script) and lead with what mattered most to users or the business. Name things by what they are, not their ticket titles word for word, and leave out the trivial. Mention briefly anything we decided not to do, if it's worth knowing. \(previousCompleted.map { "We completed \($0) the period before, so mention the pace only if it's notably different." } ?? "") Only say what the notes support: don't invent impact, numbers or reasons. End with a line to wrap up. Aim for \(length.words).\(extra.isEmpty ? "" : "\n\nAlso work this in: \(extra)")

            Reply with the speech only, no preamble.

            \(notes)
            """
        let key = cacheKey
        Task {
            do {
                let reply = try await ClaudeRunner.ask(prompt, org: org)
                text = reply
                Self.written[key] = reply
                status = "Written by Claude from the period's closed issues. Read it through before you say it."
            } catch {
                status = error.localizedDescription
            }
            working = false
        }
    }
}
