import SwiftUI

/// The top of Prioritisation, for sharing on screen in the meeting: the
/// numbers that matter to CS (shipped since the last working day, in
/// progress, waiting for triage, committed work due or overdue, open bugs,
/// and open points from the field), then what's been completed since the
/// start of the last working day, that day and this morning side by side,
/// each with its investment category and who did it. Larger when
/// presenting.
struct PrioritisationOverview: View {
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(FieldNotesStore.self) private var fieldNotes
    @Environment(HiddenStore.self) private var hidden
    let org: String
    let workload: Workload
    let board: Int
    let dateField: String
    let presenting: Bool
    @Binding var selection: DetailSelection?

    private struct Shipped: Identifiable {
        let record: IssueRecord
        let category: InvestmentCategory?
        var id: String { record.id }
    }

    var body: some View {
        let config = configs.config(for: org)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let lastDay = StandupPage.workingDay(before: today, week: config.week)
        let issues = (issueStore.history(for: org).map { Array($0.issues.values) } ?? [])
            .filter { !config.repoExclusion.contains($0.repo) && !hidden.keys.contains($0.id) }
        let completed = issues.filter { $0.isCompleted && ($0.closedAt ?? .distantPast) >= lastDay }
            .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
        let earlier = completed.filter { ($0.closedAt ?? .distantPast) < today }.map { shipped($0, issues: issues, config: config) }
        let thisMorning = completed.filter { ($0.closedAt ?? .distantPast) >= today }.map { shipped($0, issues: issues, config: config) }
        let lastDayName = calendar.isDateInYesterday(lastDay) ? "Yesterday" : lastDay.formatted(.dateTime.weekday(.wide))

        VStack(alignment: .leading, spacing: presenting ? 28 : 18) {
            stats(issues: issues, shipped: completed.count, lastDayName: lastDayName, config: config)
            HStack(alignment: .top, spacing: 16) {
                column("\(lastDayName)", subtitle: lastDay.formatted(.dateTime.day().month(.wide)), items: earlier)
                column(calendar.component(.hour, from: .now) < 12 ? "This morning" : "Today so far", subtitle: "Since midnight", items: thisMorning)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: Numbers

    private func stats(issues: [IssueRecord], shipped: Int, lastDayName: String, config: OrgConfig) -> some View {
        let open = issues.filter(\.isOpen)
        let workflow = config.workflow
        let inProgress = open.filter { issue in
            (issue.fields(onProject: board)?.values["Status"]?.display).map(workflow.isInProgress) ?? false
        }.count
        let triage = open.filter { issue in
            guard let fields = issue.fields(onProject: board) else { return true }
            return fields.values["Status"] == nil
        }.count
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekOut = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        let dates = open.compactMap { issue -> Date? in
            if case .date(let date) = issue.fields(onProject: board)?.values[dateField] { return date }
            return nil
        }
        let overdue = dates.filter { $0 < today }.count
        let dueSoon = dates.filter { $0 >= today && $0 < weekOut }.count
        let bugs = open.filter { ($0.issueType ?? "").localizedCaseInsensitiveContains("bug") || $0.labels.contains { $0.localizedCaseInsensitiveContains("bug") } }.count
        let notes = fieldNotes.notes(for: org).filter { $0.doneAt == nil }
        let urgent = notes.filter { $0.urgency == .urgent }.count
        // Six across, sharing the width.
        return HStack(alignment: .top, spacing: 12) {
            tile("Shipped", "\(shipped)", detail: "Since \(lastDayName.lowercased() == "yesterday" ? "yesterday" : lastDayName)", tint: ChartPalette.good)
            tile("In progress", "\(inProgress)", detail: "On the board", tint: ChartPalette.blue)
            tile("Waiting for triage", "\(triage)", detail: "No status yet", tint: triage > 0 ? .orange : .secondary)
            tile("Committed", "\(overdue)", detail: "overdue · \(dueSoon) due this week", tint: overdue > 0 ? ChartPalette.critical : .secondary)
            tile("Open bugs", "\(bugs)", detail: "Type or label", tint: .secondary)
            tile("From the field", "\(notes.count)", detail: urgent > 0 ? "\(urgent) urgent" : "Open points", tint: urgent > 0 ? ChartPalette.critical : .secondary)
        }
    }

    private func tile(_ title: String, _ value: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(presenting ? .headline : .callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: presenting ? 44 : 30, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint == .secondary ? Color.primary : tint)
            Text(detail)
                .font(presenting ? .callout : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(presenting ? 16 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Shipped

    private func shipped(_ record: IssueRecord, issues: [IssueRecord], config: OrgConfig) -> Shipped {
        let parent = record.parentID.flatMap { id in issues.first { $0.id == id } }
        return Shipped(record: record, category: config.investmentConfig.categorise(record, parent: parent)?.category)
    }

    private func column(_ title: String, subtitle: String, items: [Shipped]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(ChartPalette.good)
                Text(title).font(presenting ? .title2.weight(.semibold) : .headline)
                Text("\(items.count) shipped").foregroundStyle(.secondary)
                Spacer()
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text("Nothing completed yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            ForEach(items) { item in
                Button {
                    selection = .issueReference(IssueReference(org: org, record: item.record))
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        // The category's colour, the item's full height.
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.category.map { ChartPalette.slot($0.slot) } ?? Color.secondary.opacity(0.4))
                            .frame(width: 4)
                            .frame(maxHeight: .infinity)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.record.title)
                                .font(presenting ? .title3 : .body)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                Text("\(item.record.repo.split(separator: "/").last ?? "")#\(String(item.record.number))")
                                if let category = item.category { Text("· \(category.name)") }
                                if let closed = item.record.closedAt { Text("· \(closed.formatted(date: .omitted, time: .shortened))") }
                            }
                            .font(presenting ? .callout : .caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        AvatarStack(people: item.record.assignees.map { workload.person(login: $0) }, size: presenting ? 24 : 18)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(presenting ? 18 : 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}
