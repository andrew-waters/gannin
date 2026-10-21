import Foundation

// R&D time: how much of each person's working time went to issues that
// count as research and development, for preparing a tax credit claim.
//
// Time only: no salaries, rates or other money, which stay with whoever
// turns time into a claim. Nothing assumes one country's scheme: which work
// counts, and how time is found, are strategies a project picks, kept in
// its harness (`.gannin/rnd.json`).

/// A project's R&D settings. Every field is optional so older files still
/// decode, and a missing one is its default.
struct RDConfig: Codable, Hashable {
    /// What the work is called here, "R&D" unless set.
    var name: String?
    /// Which issues count, before any marked by hand.
    var qualification: RDQualification?
    /// Issues marked by hand, by node ID. Win over the qualification.
    var marks: [String: RDMark]?
    /// Where time comes from, first first. Later sources (entered by hand,
    /// estimates, sessions) fill in what earlier ones don't cover.
    var sources: [RDTimeSource]?
    var activity: RDActivityOptions?
    /// When the accounting year starts, for the report's periods.
    var yearStart: RDYearStart?

    static let defaultName = "R&D"

    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? Self.defaultName : trimmed
    }

    var qualifiedBy: RDQualification { qualification ?? .byHand }
    var timeSources: [RDTimeSource] { sources.flatMap { $0.isEmpty ? nil : $0 } ?? [.activity] }
    var activityOptions: RDActivityOptions { activity ?? RDActivityOptions() }
    var accountingYear: RDYearStart { yearStart ?? RDYearStart() }

    func mark(_ issueID: String) -> RDMark? { marks?[issueID] }

    /// Whether an issue counts, and how much of it: marked by hand, else
    /// matched by the qualification, else as its parent is. Nil for work
    /// that doesn't count, including an issue marked as not counting
    /// (which its parent can't override).
    func status(_ issueID: String, record: IssueRecord?, parent: IssueRecord?, investments: InvestmentConfig) -> RDStatus? {
        if let mark = mark(issueID) {
            return mark.counts ? RDStatus(share: mark.clampedShare, basis: .marked, rationale: mark.note) : nil
        }
        if let record, qualifiedBy.matches(record, investments: investments) {
            return RDStatus(share: 1, basis: .matched, rationale: nil)
        }
        guard let parentID = record?.parentID else { return nil }
        if let mark = mark(parentID) {
            return mark.counts ? RDStatus(share: mark.clampedShare, basis: .parent, rationale: mark.note) : nil
        }
        if let parent, qualifiedBy.matches(parent, investments: investments) {
            return RDStatus(share: 1, basis: .parent, rationale: nil)
        }
        return nil
    }
}

/// How a project says which issues count as R&D. Rule-based marking comes
/// from investment categories, whose rules already match issues.
enum RDQualification: Codable, Hashable {
    /// Only issues marked by hand.
    case byHand
    /// Issues in any of these investment categories.
    case categories([UUID])
    /// Issues with any of these labels.
    case labels([String])
    /// Issues with any of these options of a board's single-select field.
    case projectField(projectNumber: Int, projectTitle: String, field: String, options: [String])

    func matches(_ issue: IssueRecord, investments: InvestmentConfig) -> Bool {
        switch self {
        case .byHand:
            return false
        case .categories(let ids):
            // The issue's own category, not its parent's: parents are
            // followed by `RDConfig.status`, which knows about marks.
            guard let category = investments.categorise(issue, parent: nil)?.category else { return false }
            return ids.contains(category.id)
        case .labels(let labels):
            return issue.labels.contains { label in labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
        case .projectField(let number, _, let field, let options):
            guard let value = issue.fields(onProject: number)?.values.first(where: { $0.key.caseInsensitiveCompare(field) == .orderedSame })?.value.display else { return false }
            return options.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
        }
    }

    var summary: String {
        switch self {
        case .byHand: "Marked by hand"
        case .categories: "Investment categories"
        case .labels: "GitHub labels"
        case .projectField(_, let project, let field, _): "\(field) on \(project)"
        }
    }
}

/// An issue marked by hand: whether it counts, how much of it, and why.
struct RDMark: Codable, Hashable {
    var counts: Bool
    /// The part of it that's R&D, 0 to 1; nil for all of it.
    var share: Double?
    /// Why it counts (or doesn't), kept with the issue for the claim.
    var rationale: String?
    /// "owner/repo#123", so the file reads without looking IDs up.
    var issue: String?

    var clampedShare: Double { min(1, max(0, share ?? 1)) }

    var note: String? {
        let trimmed = rationale?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Whether an issue counts, as worked out by `RDConfig.status`.
struct RDStatus: Hashable {
    enum Basis: String {
        case marked = "Marked by hand"
        case matched = "Matched"
        case parent = "From its parent"
    }

    var share: Double
    var basis: Basis
    var rationale: String?
}

/// Where time allocated to issues comes from. Only activity so far; the
/// list is ordered so later sources can fill gaps or take precedence.
enum RDTimeSource: String, Codable, CaseIterable, Identifiable {
    case activity

    var id: Self { self }

    var name: String {
        switch self {
        case .activity: "From activity"
        }
    }
}

/// How activity becomes time.
struct RDActivityOptions: Codable, Hashable {
    enum Weighting: String, Codable, CaseIterable, Identifiable {
        /// Each issue touched that day gets the same share.
        case even
        /// Shares follow how many commits, reviews and comments each got.
        case events

        var id: Self { self }

        var name: String {
            switch self {
            case .even: "Evenly"
            case .events: "By activity"
            }
        }
    }

    enum QuietDays: String, Codable, CaseIterable, Identifiable {
        /// Working days with no activity go to the issues behind the
        /// person's open PRs.
        case openWork
        /// They stay unallocated.
        case unallocated

        var id: Self { self }

        var name: String {
            switch self {
            case .openWork: "Their open pull requests"
            case .unallocated: "Unallocated"
            }
        }
    }

    var weighting: Weighting?
    var quietDays: QuietDays?
    var countsReviews: Bool?
    var countsComments: Bool?

    var splitBy: Weighting { weighting ?? .even }
    var quiet: QuietDays { quietDays ?? .openWork }
    var reviews: Bool { countsReviews ?? true }
    var comments: Bool { countsComments ?? true }
}

/// The first day of the accounting year, which claims usually follow.
struct RDYearStart: Codable, Hashable {
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
}

/// The ranges the report offers, in accounting years and their quarters.
enum RDRange: String, CaseIterable, Identifiable {
    case thisYear = "This accounting year"
    case lastYear = "Last accounting year"
    case thisQuarter = "This quarter"
    case lastQuarter = "Last quarter"
    case custom = "Custom"

    var id: Self { self }

    func interval(yearStart: RDYearStart, now: Date = .now, customFrom: Date, customTo: Date, calendar: Calendar = .current) -> DateInterval {
        let year = yearStart.year(containing: now, calendar: calendar)
        switch self {
        case .thisYear:
            return year
        case .lastYear:
            let start = calendar.date(byAdding: .year, value: -1, to: year.start) ?? year.start
            return DateInterval(start: start, end: year.start)
        case .thisQuarter, .lastQuarter:
            var start = year.start
            while let next = calendar.date(byAdding: .month, value: 3, to: start), next <= now { start = next }
            if self == .lastQuarter { start = calendar.date(byAdding: .month, value: -3, to: start) ?? start }
            let end = calendar.date(byAdding: .month, value: 3, to: start) ?? start
            return DateInterval(start: start, end: end)
        case .custom:
            let from = calendar.startOfDay(for: min(customFrom, customTo))
            let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(customFrom, customTo))) ?? customTo
            return DateInterval(start: from, end: to)
        }
    }
}
