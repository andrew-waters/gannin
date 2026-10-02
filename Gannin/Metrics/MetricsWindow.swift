import SwiftUI

/// The span the stats cover: the last 7, 14, 30 or 90 days, or a calendar
/// month, quarter or year (this one so far, or the last whole one), each
/// with the period before to compare with. Kept in scene storage as a
/// number: days when positive, a calendar period when negative.
struct MetricsWindow: Hashable {
    enum Period {
        case month, quarter, year

        var noun: String {
            switch self {
            case .month: "month"
            case .quarter: "quarter"
            case .year: "year"
            }
        }
    }

    enum Kind: Hashable {
        case days(Int)
        /// `current` is this one so far; else the last whole one.
        case calendar(Period, current: Bool)
    }

    let code: Int

    static let rolling = [7, 14, 30, 90]
    static let calendarCodes = [-1, -2, -3, -4, -5, -6]

    init(code: Int) {
        self.code = code
    }

    var kind: Kind {
        switch code {
        case -1: .calendar(.month, current: true)
        case -2: .calendar(.month, current: false)
        case -3: .calendar(.quarter, current: true)
        case -4: .calendar(.quarter, current: false)
        case -5: .calendar(.year, current: true)
        case -6: .calendar(.year, current: false)
        default: .days(max(code, 1))
        }
    }

    /// For the picker: "Last 30 days", "This quarter".
    var title: String {
        switch kind {
        case .days(let days): "Last \(days) days"
        case .calendar(let period, let current): "\(current ? "This" : "Last") \(period.noun)"
        }
    }

    /// For a heading: "last 30 days", "this quarter".
    var phrase: String { title.lowercased() }

    /// For a sentence: "the last 30 days", "this quarter".
    var span: String {
        if case .days = kind { return "the " + phrase }
        return phrase
    }

    /// What it's compared with: "the 30 days before", "last month to the
    /// same day", "the quarter before".
    var previousPhrase: String {
        switch kind {
        case .days(let days): "the \(days) days before"
        case .calendar(let period, true): "last \(period.noun) to the same day"
        case .calendar(let period, false): "the \(period.noun) before"
        }
    }

    private static var calendar: Calendar { Calendar.metrics }

    /// The span itself. "This" periods run to now; "last" ones are whole.
    func interval(now: Date = .now) -> DateInterval {
        let calendar = Self.calendar
        switch kind {
        case .days(let days):
            let start = calendar.date(byAdding: .day, value: -days, to: now) ?? now
            return DateInterval(start: start, end: now)
        case .calendar(let period, let current):
            let thisStart = Self.start(of: period, containing: now)
            if current { return DateInterval(start: thisStart, end: max(now, thisStart)) }
            let lastStart = Self.start(of: period, containing: thisStart.addingTimeInterval(-1))
            return DateInterval(start: lastStart, end: thisStart)
        }
    }

    /// The period before, to compare with: as many days before; last month
    /// up to the same point for this month so far (a whole month against a
    /// part one would mislead); the whole period before a whole one.
    func previous(now: Date = .now) -> DateInterval {
        let calendar = Self.calendar
        let current = interval(now: now)
        switch kind {
        case .days(let days):
            let start = calendar.date(byAdding: .day, value: -days, to: current.start) ?? current.start
            return DateInterval(start: start, end: current.start)
        case .calendar(let period, true):
            let start = Self.start(of: period, containing: current.start.addingTimeInterval(-1))
            let elapsed = calendar.dateComponents([.second], from: current.start, to: now).second ?? 0
            let end = min(calendar.date(byAdding: .second, value: elapsed, to: start) ?? current.start, current.start)
            return DateInterval(start: start, end: end)
        case .calendar(let period, false):
            let start = Self.start(of: period, containing: current.start.addingTimeInterval(-1))
            return DateInterval(start: start, end: current.start)
        }
    }

    /// Days of history the stores fetch back from now to show it and the
    /// period before.
    func syncDays(now: Date = .now) -> Int {
        Int((now.timeIntervalSince(previous(now: now).start) / 86_400).rounded(.up)) + 1
    }

    /// Days from the span's start to now, for stores that fetch the period
    /// before themselves.
    func daysToNow(now: Date = .now) -> Int {
        Int((now.timeIntervalSince(interval(now: now).start) / 86_400).rounded(.up))
    }

    /// The span's length in days, for rates per week.
    func lengthInDays(now: Date = .now) -> Double {
        max(interval(now: now).duration / 86_400, 1)
    }

    static func start(of period: Period, containing date: Date) -> Date {
        let calendar = Self.calendar
        var components = calendar.dateComponents([.year, .month], from: date)
        switch period {
        case .month: break
        case .quarter: components.month = ((components.month ?? 1) - 1) / 3 * 3 + 1
        case .year: components.month = 1
        }
        components.day = 1
        return calendar.date(from: components) ?? date
    }
}

/// The window picker: rolling days, then calendar periods.
struct MetricsWindowPicker: View {
    @Binding var code: Int

    var body: some View {
        Picker("Window", selection: $code) {
            Section("Rolling") {
                ForEach(MetricsWindow.rolling, id: \.self) { Text(MetricsWindow(code: $0).title).tag($0) }
            }
            Section("Calendar") {
                ForEach(MetricsWindow.calendarCodes, id: \.self) { Text(MetricsWindow(code: $0).title).tag($0) }
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("What the stats cover, compared with the period before")
    }
}
