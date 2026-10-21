import SwiftUI

/// The org's accounting calendar: when its accounting year starts, and any
/// other periods it reports on (a claim period, a short first year). Kept
/// org-wide in the home harness (`.gannin/accounting.json`), since a company
/// has one year whichever project is looking.
struct AccountingCalendar: Codable, Hashable {
    var yearStart: AccountingYearStart?
    var periods: [AccountingPeriod]?

    var year: AccountingYearStart { yearStart ?? AccountingYearStart() }
    var namedPeriods: [AccountingPeriod] { (periods ?? []).sorted { $0.start > $1.start } }

    func period(id: UUID) -> AccountingPeriod? { periods?.first { $0.id == id } }

    var isEmpty: Bool { yearStart == nil && (periods ?? []).isEmpty }
}

/// The first day of the accounting year, which claims usually follow.
struct AccountingYearStart: Codable, Hashable {
    var month = 1
    var day = 1

    /// The accounting year holding `date`.
    func year(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let year = calendar.component(.year, from: date)
        let thisStart = start(in: year, calendar: calendar)
        let start = thisStart <= date ? thisStart : self.start(in: year - 1, calendar: calendar)
        let end = calendar.date(byAdding: .year, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// Its start in a calendar year, a day past the month's end clamped to it.
    func start(in year: Int, calendar: Calendar = .current) -> Date {
        let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? .now
        let days = calendar.range(of: .day, in: .month, for: first)?.count ?? 28
        return calendar.date(from: DateComponents(year: year, month: month, day: min(max(1, day), days))) ?? first
    }

    /// "1 November to 31 October".
    var summary: String {
        let calendar = Calendar.current
        let year = year(containing: .now, calendar: calendar)
        let last = year.end.addingTimeInterval(-1)
        return "\(year.start.formatted(.dateTime.day().month(.wide))) to \(last.formatted(.dateTime.day().month(.wide)))"
    }
}

/// A named stretch of days the org reports on, first and last day included.
struct AccountingPeriod: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var start: Date
    var end: Date

    var interval: DateInterval {
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: min(start, end))
        let last = calendar.startOfDay(for: max(start, end))
        return DateInterval(start: first, end: calendar.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    var dates: String {
        "\(start.formatted(date: .abbreviated, time: .omitted)) to \(end.formatted(date: .abbreviated, time: .omitted))"
    }
}

// MARK: - Settings

/// Settings › Working Time: the accounting year and the org's own periods.
struct AccountingSection: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String

    @State private var editing: AccountingPeriod?

    private var accounting: AccountingCalendar { configs.config(for: org).accountingCalendar }

    var body: some View {
        let accounting = accounting
        let year = accounting.year
        Section {
            Picker("Accounting year starts", selection: Binding { year.month } set: { month in updateYear { $0.month = month } }) {
                ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) }
            }
            Stepper(value: Binding { year.day } set: { day in updateYear { $0.day = day } }, in: 1...31) {
                LabeledContent("On day", value: "\(year.day)")
            }
            LabeledContent("Each year runs", value: year.summary)
            ForEach(accounting.namedPeriods) { period in
                LabeledContent {
                    HStack {
                        Button("Edit") { editing = period }
                        Button("Remove") { update { $0.periods?.removeAll { $0.id == period.id } } }
                    }
                } label: {
                    Text(period.name)
                    Text(period.dates)
                }
            }
            Button("Add Period") {
                let calendar = Calendar.current
                let current = year.year(containing: .now, calendar: calendar)
                editing = AccountingPeriod(name: "", start: current.start, end: calendar.date(byAdding: .day, value: -1, to: current.end) ?? current.end)
            }
        } header: {
            Text("Accounting periods")
        } footer: {
            Text("Reports that follow the company's accounts, such as R&D Time, offer this and last accounting year, their quarters and these periods. Add a period for anything else you report on, such as a claim period or a short first year.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $editing) { period in
            AccountingPeriodEditor(period: period) { saved in
                update { calendar in
                    var periods = calendar.periods ?? []
                    if let index = periods.firstIndex(where: { $0.id == saved.id }) { periods[index] = saved } else { periods.append(saved) }
                    calendar.periods = periods
                }
            }
        }
    }

    private func update(_ change: (inout AccountingCalendar) -> Void) {
        configs.update(org) { config in
            var calendar = config.accountingCalendar
            change(&calendar)
            if calendar.periods?.isEmpty == true { calendar.periods = nil }
            config.accounting = calendar.isEmpty ? nil : calendar
        }
    }

    private func updateYear(_ change: (inout AccountingYearStart) -> Void) {
        update { calendar in
            var year = calendar.year
            change(&year)
            calendar.yearStart = year == AccountingYearStart() ? nil : year
        }
    }
}

private struct AccountingPeriodEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var period: AccountingPeriod
    let onSave: (AccountingPeriod) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $period.name, prompt: Text("Claim period"))
                    .leadingTextBox("Name")
                DatePicker("From", selection: $period.start, displayedComponents: .date)
                DatePicker("To", selection: $period.end, in: period.start..., displayedComponents: .date)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let calendar = Calendar.current
                    var saved = period
                    saved.name = period.name.trimmingCharacters(in: .whitespaces)
                    saved.start = calendar.startOfDay(for: period.start)
                    saved.end = calendar.startOfDay(for: max(period.start, period.end))
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(period.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
    }
}
