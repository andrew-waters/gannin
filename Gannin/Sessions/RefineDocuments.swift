import Foundation

/// What Agree writes for a Design and Refine session: each finding's issue
/// body, and the record in the harness (`refines/<slug>/README.md`) with
/// front matter as the harness's STANDARDS.md has it.
enum RefineDocuments {
    /// The record's folder in the harness.
    static func folder(_ info: RefineInfo) -> String { "refines/\(info.slug)" }

    static func readmePath(_ info: RefineInfo) -> String { "\(folder(info))/README.md" }

    /// A committed screenshot's page in the harness, which shows the image
    /// to anyone who can read the harness.
    static func screenshotURL(_ screenshot: RefineInfo.Screenshot, info: RefineInfo, harnessRepo: String) -> URL? {
        URL(string: "https://github.com/\(harnessRepo)/blob/HEAD/\(folder(info))/\(screenshot.file)")
    }

    /// A finding's first line, cut at a word to fit an issue title.
    static func title(_ note: String) -> String {
        let line = note.split(whereSeparator: \.isNewline).first.map(String.init) ?? note
        guard line.count > 80 else { return line }
        var title = ""
        for word in line.split(separator: " ") {
            let next = title.isEmpty ? String(word) : "\(title) \(word)"
            if next.count > 77 { break }
            title = next
        }
        return (title.isEmpty ? String(line.prefix(77)) : title) + "..."
    }

    /// The repo a finding most likely belongs to: the first of the picked
    /// repos Claude's scouting names, else the first picked.
    static func repo(for finding: RefineInfo.Finding, info: RefineInfo) -> String? {
        let files = info.state?.scouting(for: finding.id)?.files ?? []
        let named = files.compactMap { file in file.split(separator: ":", maxSplits: 1).first.map(String.init) }
        return named.first { info.repos.contains($0) } ?? info.repos.first
    }

    /// An issue's body: its description, then its links.
    static func issueBody(_ finding: RefineInfo.Finding, info: RefineInfo, screenshots: [RefineInfo.Screenshot], harnessRepo: String) -> String {
        issueDescription(finding, info: info) + issueLinks(screenshots: screenshots, info: info, harnessRepo: harnessRepo)
    }

    /// What the room edits at Agree: the note, the page it was on, and
    /// where Claude thinks it lives.
    static func issueDescription(_ finding: RefineInfo.Finding, info: RefineInfo) -> String {
        var parts = [finding.note]
        parts.append("Seen on [\(finding.pageTitle ?? finding.url)](\(finding.url)).")
        if let scouting = info.state?.scouting(for: finding.id), !scouting.files.isEmpty || !scouting.components.isEmpty {
            var lines = ["**Where it likely lives:**", ""]
            lines += scouting.files.map { "- `\($0)`" }
            if !scouting.components.isEmpty { lines.append("- Components: \(scouting.components.joined(separator: ", "))") }
            if let why = scouting.why, !why.isEmpty { lines += ["", why] }
            parts.append(lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Added when the issue is made: its ticked screenshots in the harness,
    /// then the record.
    static func issueLinks(screenshots: [RefineInfo.Screenshot], info: RefineInfo, harnessRepo: String) -> String {
        var parts: [String] = []
        let images = screenshots.compactMap { shot in
            screenshotURL(shot, info: info, harnessRepo: harnessRepo).map { "![\(shot.file)](\($0.absoluteString)?raw=true)" }
        }
        if !images.isEmpty {
            parts.append("**Screenshots** (in \(harnessRepo), for those who can read it):\n\n" + images.joined(separator: "\n"))
        }
        parts.append("From the Design and Refine session [\(info.name)](https://github.com/\(harnessRepo)/blob/HEAD/\(readmePath(info))).")
        return parts.map { "\n\n" + $0 }.joined()
    }

    /// The record: who was here, the page, and each finding with its issue
    /// and its ticked screenshots, which sit beside it.
    static func readme(_ info: RefineInfo, made: [String: RefineInfo.MadeIssue], ticked: Set<UUID>, day: String) -> String {
        let issues = info.findings.compactMap { made[$0.id.uuidString]?.reference }
        let attendees = info.attendees.map { ($0.login ?? $0.name).replacingOccurrences(of: ",", with: "") }
        var front = [
            "type: refine",
            "status: agreed",
            "summary: \(yaml("Stepped through \(info.name) and raised \(issues.count) \(issues.count == 1 ? "issue" : "issues")."))",
            "url: \(info.url)",
            "attendees: [\(attendees.joined(separator: ", "))]",
            "issues: [\(issues.joined(separator: ", "))]",
        ]
        if !info.repos.isEmpty { front.append("touches: [\(info.repos.joined(separator: ", "))]") }
        front.append("agreed_at: \(day)")

        var body = ["# \(info.name)", "Stepped through [\(info.url)](\(info.url)) on \(day)."]
        if !info.attendees.isEmpty {
            body.append("## Who was here\n\n" + info.attendees.map { attendee in
                attendee.login.map { "- \(attendee.name) (@\($0))" } ?? "- \(attendee.name)"
            }.joined(separator: "\n"))
        }
        let screenshots = Dictionary(uniqueKeysWithValues: info.screenshots.map { ($0.id, $0) })
        var findings: [String] = []
        for finding in info.findings {
            var line = "- \(finding.note.replacingOccurrences(of: "\n", with: " "))"
            if finding.suggestion != nil { line += " (Claude's suggestion)" }
            if let issue = made[finding.id.uuidString] {
                line += ": [\(issue.reference)](\(issue.url.absoluteString))"
            } else {
                line += " (not raised)"
            }
            let shots = finding.screenshots.filter(ticked.contains).compactMap { screenshots[$0] }
            if !shots.isEmpty {
                line += " " + shots.map { "([\(($0.file as NSString).deletingPathExtension)](./\($0.file)))" }.joined(separator: " ")
            }
            line += "\n  On [\(finding.pageTitle ?? finding.url)](\(finding.url))."
            findings.append(line)
        }
        body.append("## Findings\n\n" + (findings.isEmpty ? "None." : findings.joined(separator: "\n")))
        return "---\n" + front.joined(separator: "\n") + "\n---\n\n" + body.joined(separator: "\n\n") + "\n"
    }

    /// Ticked screenshots in commits of at most `limit` bytes of images
    /// each, so one request stays well inside what GitHub takes.
    static func batches(_ files: [(path: String, data: Data)], limit: Int = 4 * 1024 * 1024) -> [[(path: String, data: Data)]] {
        var batches: [[(path: String, data: Data)]] = []
        var current: [(path: String, data: Data)] = []
        var size = 0
        for file in files {
            if !current.isEmpty && size + file.data.count > limit {
                batches.append(current)
                current = []
                size = 0
            }
            current.append(file)
            size += file.data.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// A double-quoted YAML string.
    private static func yaml(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}
