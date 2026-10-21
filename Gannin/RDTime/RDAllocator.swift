import Foundation

/// Something time went to: an issue, or a PR that closes none (so its time
/// is still accounted for, though only issues can count as R&D).
struct RDWorkItem: Hashable, Identifiable {
    enum Kind: Hashable {
        case issue
        case pullRequest
    }

    let id: String
    let kind: Kind
    let number: Int
    let repo: String
    let title: String
    let url: URL

    var reference: String { "\(repo)#\(number)" }

    init(_ issue: LinkedItem) {
        self.init(id: issue.id, kind: .issue, number: issue.number, repo: issue.repo, title: issue.title, url: issue.url)
    }

    init(_ issue: WorkLogIssue) {
        self.init(id: issue.id, kind: .issue, number: issue.number, repo: issue.repo, title: issue.title, url: issue.url)
    }

    init(pullRequest: WorkLogPullRequest) {
        self.init(id: pullRequest.id, kind: .pullRequest, number: pullRequest.number, repo: pullRequest.repo, title: pullRequest.title, url: pullRequest.url)
    }

    init(id: String, kind: Kind, number: Int, repo: String, title: String, url: URL) {
        self.id = id
        self.kind = kind
        self.number = number
        self.repo = repo
        self.title = title
        self.url = url
    }
}

/// Hours of one person's day given to one piece of work.
struct RDAllocation: Hashable {
    let login: String
    /// Midnight in the person's time zone.
    let day: Date
    /// The day as `2026-10-03`, in their time zone.
    let dayKey: String
    let item: RDWorkItem
    let hours: Double
    let source: RDTimeSource
    /// Commits, reviews and comments behind it that day (a PR closing two
    /// issues counts a half for each); zero for a quiet day given to the
    /// person's open PRs.
    let events: Double

    var basis: String {
        events > 0 ? "\(events.formatted(.number.precision(.fractionLength(0...1)))) events that day" : "Open pull request, no activity that day"
    }
}

/// Working hours no source could place.
struct RDGap: Hashable {
    let login: String
    let day: Date
    let hours: Double
}

/// What the sources found over a range.
struct RDAllocations {
    var allocations: [RDAllocation] = []
    var gaps: [RDGap] = []
    /// Each person's working hours in the range, less leave.
    var available: [String: Double] = [:]
    /// The PRs behind each piece of work's time, by item ID, as evidence.
    var pullRequests: [String: Set<URL>] = [:]
}

/// Time from activity: each working day's hours (the person's own week or
/// the org's, less bank holidays and leave) split across the work they
/// touched that day. Only working days count: activity at a weekend adds
/// no hours, since a claim is of working time.
enum RDActivityAllocator {
    struct Input {
        var people: Set<String>
        var range: DateInterval
        var pullRequests: [WorkLogPullRequest]
        var issues: [WorkLogIssue]
        var calendars: [String: WorkingCalendar]
        var dates: [String: PersonDates]
        var orgCalendar: WorkingCalendar
        var options: RDActivityOptions
        /// Days after today aren't counted.
        var now: Date = .now
    }

    static func allocate(_ input: Input) -> RDAllocations {
        var result = RDAllocations()
        let options = input.options

        // Weights per person, per day (by their calendar's key), per item.
        var touched: [String: [String: [String: Double]]] = [:]
        var items: [String: RDWorkItem] = [:]
        var calendars: [String: Calendar] = [:]
        func calendar(for login: String) -> Calendar {
            if let cached = calendars[login] { return cached }
            var calendar = Calendar.current
            if let zone = input.calendars[login]?.timeZone { calendar.timeZone = zone }
            calendars[login] = calendar
            return calendar
        }
        func credit(_ login: String, at date: Date, to targets: [RDWorkItem], pullRequest: URL?) {
            guard input.people.contains(login), input.range.contains(date), !targets.isEmpty else { return }
            let key = WorkingCalendar.key(date, calendar: calendar(for: login))
            for target in targets {
                items[target.id] = target
                touched[login, default: [:]][key, default: [:]][target.id, default: 0] += 1 / Double(targets.count)
                if let pullRequest { result.pullRequests[target.id, default: []].insert(pullRequest) }
            }
        }

        for pr in input.pullRequests {
            let prTargets = targets(of: pr)
            for event in pr.events {
                switch event.kind {
                case .commit, .opened: break
                case .review: guard options.reviews else { continue }
                case .merged, .issueOpened, .comment: continue
                }
                credit(event.login, at: event.at, to: prTargets, pullRequest: pr.url)
            }
        }
        if options.comments {
            for issue in input.issues {
                for event in issue.events {
                    credit(event.login, at: event.at, to: [RDWorkItem(issue)], pullRequest: nil)
                }
            }
        }

        let authored = Dictionary(grouping: input.pullRequests.filter { $0.author != nil }) { $0.author ?? "" }
        let today = Calendar.current.startOfDay(for: input.now)
        for login in input.people.sorted() {
            let local = calendar(for: login)
            let working = input.calendars[login] ?? input.orgCalendar
            let dates = input.dates[login]
            var day = local.startOfDay(for: input.range.start)
            while day < input.range.end, day <= today {
                guard let next = local.date(byAdding: .day, value: 1, to: day) else { break }
                defer { day = next }
                let dayHours = hours(on: day, working: working, dates: dates, calendar: local)
                guard dayHours > 0 else { continue }
                result.available[login, default: 0] += dayHours
                let key = WorkingCalendar.key(day, calendar: local)
                if let weights = touched[login]?[key], !weights.isEmpty {
                    let shares = weights.mapValues { options.splitBy == .even ? 1 : $0 }
                    let total = shares.values.reduce(0, +)
                    for (id, share) in shares.sorted(by: { $0.key < $1.key }) {
                        guard let item = items[id] else { continue }
                        result.allocations.append(RDAllocation(login: login, day: day, dayKey: key, item: item, hours: dayHours * share / total, source: .activity, events: weights[id] ?? 0))
                    }
                    continue
                }
                let open = options.quiet == .openWork
                    ? (authored[login] ?? []).filter { $0.createdAt < next && ($0.closedAt ?? .distantFuture) > day }
                    : []
                var shares: [RDWorkItem: Double] = [:]
                for pr in open {
                    let prTargets = targets(of: pr)
                    for target in prTargets {
                        shares[target, default: 0] += 1 / Double(prTargets.count)
                        result.pullRequests[target.id, default: []].insert(pr.url)
                    }
                }
                guard !shares.isEmpty else {
                    result.gaps.append(RDGap(login: login, day: day, hours: dayHours))
                    continue
                }
                let total = shares.values.reduce(0, +)
                for (item, share) in shares.sorted(by: { $0.key.id < $1.key.id }) {
                    result.allocations.append(RDAllocation(login: login, day: day, dayKey: key, item: item, hours: dayHours * share / total, source: .activity, events: 0))
                }
            }
        }
        return result
    }

    /// The issues a PR closes, else the PR itself.
    static func targets(of pr: WorkLogPullRequest) -> [RDWorkItem] {
        pr.closingIssues.isEmpty ? [RDWorkItem(pullRequest: pr)] : pr.closingIssues.map(RDWorkItem.init)
    }

    /// A day's working hours for someone: none on a day off, a bank holiday,
    /// a day of leave or outside their start and end dates, half on a half
    /// day of leave.
    static func hours(on day: Date, working: WorkingCalendar, dates: PersonDates?, calendar: Calendar) -> Double {
        guard working.isWorkingDay(day, calendar: calendar) else { return 0 }
        let span = working.week.hours(on: calendar.component(.weekday, from: day))
        let hours = Double(max(0, span.end - span.start))
        switch dates?.status(on: day, calendar: calendar) {
        case .notStarted, .left: return 0
        case .absent(_, let half): return half == nil ? 0 : hours / 2
        case nil: return hours
        }
    }
}

/// The report: time by piece of work and by person, with what counts as
/// R&D and why.
struct RDReport {
    struct WorkRow: Identifiable {
        let item: RDWorkItem
        /// Nil when it doesn't count.
        let status: RDStatus?
        var hours: Double = 0
        var people: [String: Double] = [:]
        var pullRequests: [URL] = []
        var first: Date = .distantFuture
        var last: Date = .distantPast

        var id: String { item.id }
        var rdHours: Double { hours * (status?.share ?? 0) }
    }

    struct PersonRow: Identifiable {
        let login: String
        var available: Double = 0
        var allocated: Double = 0
        var rdHours: Double = 0
        var unallocated: Double = 0

        var id: String { login }
        /// R&D's share of their working hours.
        var rdShare: Double { available > 0 ? rdHours / available : 0 }
    }

    struct Line: Identifiable {
        let allocation: RDAllocation
        let rdHours: Double
        var id: String { "\(allocation.login) \(allocation.day.timeIntervalSince1970) \(allocation.item.id)" }
    }

    let work: [WorkRow]
    let people: [PersonRow]
    let lines: [Line]

    var hours: Double { work.reduce(0) { $0 + $1.hours } }
    var rdHours: Double { work.reduce(0) { $0 + $1.rdHours } }
    var available: Double { people.reduce(0) { $0 + $1.available } }
    var unallocated: Double { people.reduce(0) { $0 + $1.unallocated } }
    var rdWork: [WorkRow] { work.filter { $0.status != nil } }

    init(_ found: RDAllocations, status: (RDWorkItem) -> RDStatus?) {
        var work: [String: WorkRow] = [:]
        var people: [String: PersonRow] = [:]
        var lines: [Line] = []
        for (login, hours) in found.available { people[login] = PersonRow(login: login, available: hours) }
        for allocation in found.allocations {
            let item = allocation.item
            var row = work[item.id] ?? WorkRow(item: item, status: item.kind == .issue ? status(item) : nil)
            row.hours += allocation.hours
            row.people[allocation.login, default: 0] += allocation.hours
            row.first = min(row.first, allocation.day)
            row.last = max(row.last, allocation.day)
            work[item.id] = row
            let rdHours = allocation.hours * (row.status?.share ?? 0)
            people[allocation.login, default: PersonRow(login: allocation.login)].allocated += allocation.hours
            people[allocation.login, default: PersonRow(login: allocation.login)].rdHours += rdHours
            lines.append(Line(allocation: allocation, rdHours: rdHours))
        }
        for gap in found.gaps { people[gap.login, default: PersonRow(login: gap.login)].unallocated += gap.hours }
        for (id, urls) in found.pullRequests where work[id] != nil {
            work[id]?.pullRequests = urls.sorted { $0.absoluteString < $1.absoluteString }
        }
        self.work = work.values.sorted { $0.rdHours != $1.rdHours ? $0.rdHours > $1.rdHours : $0.hours > $1.hours }
        self.people = people.values.sorted { $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending }
        self.lines = lines.sorted { ($0.allocation.day, $0.allocation.login, $0.allocation.item.id) < ($1.allocation.day, $1.allocation.login, $1.allocation.item.id) }
    }
}
