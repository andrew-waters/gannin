import AppKit
import UniformTypeIdentifiers

/// The report as files an accountant or adviser can work from: CSV per
/// table, or one Markdown document. Hours only; every line links back to
/// its issue and the PRs behind it.
enum RDExport: String, CaseIterable, Identifiable {
    case work = "Issues (CSV)"
    case people = "People (CSV)"
    case lines = "Daily lines (CSV)"
    case markdown = "Report (Markdown)"

    var id: Self { self }

    var fileExtension: String { self == .markdown ? "md" : "csv" }

    var contentType: UTType { self == .markdown ? UTType(filenameExtension: "md") ?? .plainText : .commaSeparatedText }

    func fileName(name: String, range: DateInterval) -> String {
        let part: String = switch self {
        case .work: "issues"
        case .people: "people"
        case .lines: "daily"
        case .markdown: "report"
        }
        let slug = name.lowercased().replacingOccurrences(of: "&", with: "and").filter { $0.isLetter || $0.isNumber }
        return "\(slug.isEmpty ? "rd" : slug)-time-\(part)-\(RDExport.day(range.start))-to-\(RDExport.day(Self.lastDay(range))).\(fileExtension)"
    }

    func text(_ report: RDReport, name: String, range: DateInterval, method: String, names: [String: String]) -> String {
        switch self {
        case .work: Self.workCSV(report, name: name)
        case .people: Self.peopleCSV(report, name: name, names: names)
        case .lines: Self.linesCSV(report, name: name)
        case .markdown: Self.markdown(report, name: name, range: range, method: method, names: names)
        }
    }

    /// Asks where to save, then writes.
    @MainActor
    func save(_ report: RDReport, name: String, range: DateInterval, method: String, names: [String: String]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(name: name, range: range)
        panel.allowedContentTypes = [contentType]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text(report, name: name, range: range, method: method, names: names).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: CSV

    static func workCSV(_ report: RDReport, name: String) -> String {
        var rows = [["Reference", "Title", "URL", "Kind", "Counts as \(name)", "\(name) share", "Basis", "Rationale", "Hours", "\(name) hours", "People", "First day", "Last day", "Pull requests"]]
        for row in report.work {
            rows.append([
                row.item.reference, row.item.title, row.item.url.absoluteString, row.item.kind == .issue ? "Issue" : "Pull request",
                row.status == nil ? "No" : "Yes", row.status.map { percent($0.share) } ?? "", row.status?.basis.rawValue ?? "", row.status?.rationale ?? "",
                hours(row.hours), hours(row.rdHours),
                row.people.sorted { $0.key < $1.key }.map { "\($0.key) \(hours($0.value))" }.joined(separator: "; "),
                day(row.first), day(row.last), row.pullRequests.map(\.absoluteString).joined(separator: " "),
            ])
        }
        return csv(rows)
    }

    static func peopleCSV(_ report: RDReport, name: String, names: [String: String]) -> String {
        var rows = [["Login", "Name", "Working hours", "Allocated hours", "Unallocated hours", "\(name) hours", "\(name) share of working hours"]]
        for person in report.people {
            rows.append([person.login, names[person.login] ?? "", hours(person.available), hours(person.allocated), hours(person.unallocated), hours(person.rdHours), percent(person.rdShare)])
        }
        return csv(rows)
    }

    static func linesCSV(_ report: RDReport, name: String) -> String {
        var rows = [["Date", "Login", "Reference", "Title", "URL", "Hours", "\(name) hours", "Source", "Basis"]]
        for line in report.lines {
            let allocation = line.allocation
            rows.append([allocation.dayKey, allocation.login, allocation.item.reference, allocation.item.title, allocation.item.url.absoluteString, hours(allocation.hours), hours(line.rdHours), allocation.source.name, allocation.basis])
        }
        return csv(rows)
    }

    static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Quoted when it holds a comma, quote or line break; a leading `=`,
    /// `+`, `-` or `@` is prefixed with a quote mark so spreadsheets don't
    /// run it as a formula.
    static func field(_ value: String) -> String {
        var value = value
        if let first = value.first, "=+-@".contains(first), Double(value) == nil { value = "'" + value }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Markdown

    static func markdown(_ report: RDReport, name: String, range: DateInterval, method: String, names: [String: String]) -> String {
        var text = "# \(name) time, \(day(range.start)) to \(day(lastDay(range)))\n\n"
        text += "- \(name) hours: \(hours(report.rdHours)) of \(hours(report.available)) working hours (\(percent(report.available > 0 ? report.rdHours / report.available : 0)))\n"
        text += "- Allocated: \(hours(report.hours)) hours; unallocated: \(hours(report.unallocated)) hours\n"
        text += "- \(method)\n\n"
        text += "Hours only: no salaries, rates or costs are recorded. Which work qualifies under a given scheme is for the claimant and their adviser to decide.\n\n"

        text += "## \(name) issues\n\n"
        text += "| Issue | Title | \(name) hours | Share | Basis | People | Rationale |\n| --- | --- | ---: | ---: | --- | --- | --- |\n"
        for row in report.rdWork {
            let people = row.people.sorted { $0.key < $1.key }.map { "\($0.key) \(hours($0.value))" }.joined(separator: ", ")
            text += "| [\(row.item.reference)](\(row.item.url.absoluteString)) | \(cell(row.item.title)) | \(hours(row.rdHours)) | \(percent(row.status?.share ?? 0)) | \(row.status?.basis.rawValue ?? "") | \(people) | \(cell(row.status?.rationale ?? "")) |\n"
        }
        if report.rdWork.isEmpty { text += "| | Nothing counted in this range | | | | | |\n" }

        text += "\n## People\n\n"
        text += "| Person | Working hours | Allocated | Unallocated | \(name) hours | \(name) share |\n| --- | ---: | ---: | ---: | ---: | ---: |\n"
        for person in report.people {
            let label = names[person.login].map { "\(cell($0)) (\(person.login))" } ?? person.login
            text += "| \(label) | \(hours(person.available)) | \(hours(person.allocated)) | \(hours(person.unallocated)) | \(hours(person.rdHours)) | \(percent(person.rdShare)) |\n"
        }
        return text
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Formats

    static func hours(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func day(_ date: Date) -> String {
        guard date != .distantFuture, date != .distantPast else { return "" }
        return WorkingCalendar.key(date)
    }

    /// The range's last day, its end being the midnight after it.
    static func lastDay(_ range: DateInterval) -> Date {
        range.end.addingTimeInterval(-1)
    }
}
