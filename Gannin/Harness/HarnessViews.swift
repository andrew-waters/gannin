import SwiftUI

/// Issues from the issue history by `owner/name#123`, to name the ones a
/// document refers to.
struct IssueLookup {
    private let byReference: [String: IssueRecord]

    init(history: IssueHistory?) {
        let records = history.map { Array($0.issues.values) } ?? []
        byReference = Dictionary(records.map { ("\($0.repo)#\($0.number)", $0) }, uniquingKeysWith: { first, _ in first })
    }

    func record(repo: String?, number: Int) -> IssueRecord? {
        repo.flatMap { byReference["\($0)#\(number)"] }
    }
}

extension View {
    /// Loads the org's harness index when stale, if the org has a harness.
    func loadsHarness(org: String) -> some View {
        modifier(HarnessLoader(org: org))
    }
}

private struct HarnessLoader: ViewModifier {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    let org: String

    func body(content: Content) -> some View {
        let setup = configs.config(for: org).harness
        content.task(id: setup) {
            if let setup { await harness.load(org: org, setup: setup) }
        }
    }
}

// MARK: - The Harness page

/// The org's harness: plans, requirements, findings or skills, grouped by
/// module (or folder), each with the issues it's about. Not linked shows
/// the plans and requirements no issue claims, so they can be given one.
struct HarnessView: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var issueStore
    @Environment(\.openURL) private var openURL
    /// Picked under Harness in the sidebar, which writes the same key.
    @SceneStorage("harnessKind") private var kind: HarnessKind = .plans
    @State private var unlinkedOnly = false
    /// Documents from before STANDARDS.md, without front matter.
    @AppStorage("harnessShowsOlder") private var showsOlder = false
    let org: String
    @Binding var selection: DetailSelection?

    var body: some View {
        let setup = configs.config(for: org).harness
        Group {
            if let setup {
                content(setup)
            } else {
                ContentUnavailableView(
                    "No harness",
                    systemImage: "text.book.closed",
                    description: Text("Pick the repo the org keeps its plans and requirements in, or create one, in Settings.")
                )
            }
        }
        .toolbar {
            if let setup {
                if kind == .plans || kind == .requirements {
                    ToolbarItem {
                        Toggle("Not Linked", isOn: $unlinkedOnly)
                            .help("Only the \(kind.rawValue.lowercased()) that name no issue in their file name or header table")
                    }
                }
                ToolbarItem {
                    Button {
                        Task { await harness.load(org: org, setup: setup, force: true) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(harness.loading.contains(org))
                    .help("Fetch \(setup.repo) again")
                }
            }
        }
        .loadsHarness(org: org)
    }

    @ViewBuilder
    private func content(_ setup: HarnessConfig) -> some View {
        let repo = setup.repo
        if let index = harness.index(for: org, setup) {
            let lookup = IssueLookup(history: issueStore.history(for: org))
            let linkable = kind == .plans || kind == .requirements
            let ofKind = index.documents(kind).filter { !(linkable && unlinkedOnly) || $0.subjects.isEmpty }
            let documents = ofKind.filter { showsOlder || $0.followsStandard }
            let older = ofKind.count(where: { !$0.followsStandard })
            List {
                if let error = harness.errors[org] {
                    Banner(message: "Refresh failed: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                        Task { await harness.load(org: org, setup: setup, force: true) }
                    }
                }
                if documents.isEmpty {
                    Text(unlinkedOnly ? "Every one names an issue." : older > 0 ? "No \(kind.rawValue.lowercased()) follow the standard yet." : "No \(kind.rawValue.lowercased()) in \(repo).")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups(documents), id: \.title) { group in
                    Section(header: SectionHeader(title: group.title, count: group.documents.count)) {
                        ForEach(group.documents) { document in
                            row(document, index: index, lookup: lookup, linkable: linkable)
                        }
                    }
                }
                if older > 0 {
                    Section {
                        HStack {
                            Text(showsOlder
                                 ? "Showing \(older) older \(older == 1 ? kind.singular : kind.rawValue.lowercased()) without front matter."
                                 : "\(older) older \(older == 1 ? kind.singular : kind.rawValue.lowercased()) without front matter \(older == 1 ? "isn't" : "aren't") shown.")
                                .foregroundStyle(.secondary)
                            Button(showsOlder ? "Hide Them" : "Show Them") { showsOlder.toggle() }
                                .linkButton()
                        }
                        .font(.callout)
                    } footer: {
                        Text("Documents written to the harness's STANDARDS.md (front matter with a summary) are listed; older ones appear once they're converted.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if let error = harness.errors[org] {
            ContentUnavailableView {
                Label("Couldn't read \(repo)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await harness.load(org: org, setup: setup, force: true) } }
            }
        } else if harness.loading.contains(org) {
            ProgressView("Indexing \(repo)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Not indexed yet", systemImage: "text.book.closed")
            } actions: {
                Button("Index Now") { Task { await harness.load(org: org, setup: setup, force: true) } }
            }
        }
    }

    /// Plans and requirements by domain (from front matter) or module
    /// folder, skills by folder, findings newest
    /// first; the newest first within each.
    private func groups(_ documents: [HarnessDocument]) -> [(title: String, documents: [HarnessDocument])] {
        let newestFirst: (HarnessDocument, HarnessDocument) -> Bool = { a, b in
            if a.date != b.date { return (a.date ?? .distantPast) > (b.date ?? .distantPast) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        let grouped = Dictionary(grouping: documents) { document -> String in
            switch document.kind {
            case .plans, .requirements: return document.area.map(Self.prettify) ?? "Other"
            case .findings: return "Findings"
            case .skills:
                let parts = document.path.split(separator: "/")
                return parts.count > 2 ? Self.prettify(String(parts[1])) : "Skills"
            }
        }
        return grouped.map { ($0.key, $0.value.sorted(by: newestFirst)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// `data-capture` as "Data capture"; short names like `cdm` in capitals.
    static func prettify(_ name: String) -> String {
        if name.count <= 3 { return name.uppercased() }
        let words = name.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private func row(_ document: HarnessDocument, index: HarnessIndex, lookup: IssueLookup, linkable: Bool) -> some View {
        Button {
            selection = .harnessDocument(document.path)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.title)
                        .lineLimit(2)
                    if let summary = document.summary {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(document.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !document.subjects.isEmpty {
                        issueLine(document.subjects, index: index, lookup: lookup)
                    } else if linkable {
                        Text("Not linked to an issue")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 12)
                if let status = document.statusLabel {
                    Pill(text: status, color: .secondary)
                        .help(document.status ?? status)
                }
                if document.tasks > 0 {
                    TaskCount(done: document.tasksDone, total: document.tasks)
                }
                if let date = document.date {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            OpenElsewhereItems(.harnessDocument(document.path))
            if let url = index.url(for: document) {
                Button("Open on GitHub") { openURL(url) }
            }
        }
    }

    /// "#2369 Show equipment certificate history · #2370", in the issue's
    /// state colour.
    private func issueLine(_ references: [HarnessReference], index: HarnessIndex, lookup: IssueLookup) -> some View {
        let parts = references.map { reference -> Text in
            let record = lookup.record(repo: index.repo(of: reference), number: reference.number)
            let number = Text(verbatim: "#\(reference.number)").foregroundStyle(record.map(IssueStateDot.color) ?? .secondary)
            guard let record else { return number }
            return Text("\(number) \(record.title)")
        }
        return parts.dropFirst().reduce(parts[0]) { Text("\($0) · \($1)") }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// "7/12" with a ring, for a plan's checkboxes.
private struct TaskCount: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            Gauge(value: Double(done), in: 0...Double(max(total, 1))) { EmptyView() }
                .gaugeStyle(.accessoryCircularCapacity)
                .scaleEffect(0.35)
                .frame(width: 16, height: 16)
                .tint(done == total ? ChartPalette.good : ChartPalette.blue)
            Text(verbatim: "\(done)/\(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("\(done) of \(total) tasks ticked off")
    }
}

enum IssueStateDot {
    static func color(_ record: IssueRecord) -> Color {
        if record.isOpen { return .green }
        return record.isNotPlanned ? .secondary : .purple
    }
}

// MARK: - A document

/// One harness document: what it's about, then the document itself.
/// A harness document as the issue drawer shows an issue: a header with its
/// title, status and facts, then its text as sections (one per `##`
/// heading, each folding, with Contents to jump between them) beside a
/// column of what it's about and where it lives; one column when narrow.
/// Also the page Open as Page pushes, where `onClose` is nil.
struct HarnessDocumentPage: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgStore.self) private var orgs
    @Environment(\.navigate) private var navigate
    @Environment(\.openAsPage) private var openAsPage
    @Environment(\.openElsewhere) private var openElsewhere
    @Environment(\.openURL) private var openURL
    let org: String
    let path: String
    var onClose: (() -> Void)? = nil

    @State private var width: CGFloat = 1000
    /// Folded sections, by index.
    @State private var folded: Set<Int> = []
    @AppStorage("harnessReadingSize") private var size: Double = 14

    private static let sizes: ClosedRange<Double> = 11...20

    var body: some View {
        let setup = configs.config(for: org).harness
        Group {
            if let setup, let index = harness.index(for: org, setup), let document = index.document(at: path) {
                let lookup = IssueLookup(history: issueStore.history(for: org))
                let sections = HarnessDocumentSection.split(document.linkedBody(issuesRepo: index.issuesRepo))
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        header(document, index: index, sections: sections, proxy: proxy)
                        Divider()
                        if width >= 900 {
                            HStack(spacing: 0) {
                                Form { textSections(document, sections: sections) }
                                    .formStyle(.grouped)
                                    .frame(minWidth: 480, maxWidth: .infinity)
                                Divider()
                                Form { detailSections(document, index: index, lookup: lookup) }
                                    .formStyle(.grouped)
                                    .frame(width: 340)
                            }
                        } else {
                            Form {
                                textSections(document, sections: sections)
                                detailSections(document, index: index, lookup: lookup)
                            }
                            .formStyle(.grouped)
                        }
                    }
                }
                .environment(\.openURL, OpenURLAction { url in open(url, document: document, index: index, lookup: lookup) })
            } else {
                ContentUnavailableView("Not in the harness", systemImage: "doc.questionmark", description: Text("\(path) isn't in the harness as last fetched."))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .loadsHarness(org: org)
    }

    // MARK: Header

    private func header(_ document: HarnessDocument, index: HarnessIndex, sections: [HarnessDocumentSection], proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(document.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if let onClose {
                    Button("Done", action: onClose)
                        .keyboardShortcut(.cancelAction)
                        .help("Close (Esc)")
                }
            }
            HStack(spacing: 10) {
                Pill(text: document.statusLabel ?? "No status", color: .secondary)
                    .help(document.status ?? "No status")
                Label(document.kind.singular.capitalized, systemImage: document.kind.systemImage)
                    .foregroundStyle(.secondary)
                if let url = index.url(for: document) {
                    Link(destination: url) {
                        Text(document.fileName).lineLimit(1).truncationMode(.middle)
                    }
                    .help("\(document.path) on GitHub")
                }
                Spacer()
                contents(sections, proxy: proxy)
                textSize
                if onClose != nil, let openAsPage {
                    Button("Open as Page") {
                        onClose?()
                        openAsPage(.harnessDocument(document.path))
                    }
                }
                if let openElsewhere {
                    Button("Open in Window") {
                        onClose?()
                        openElsewhere.open(.harnessDocument(document.path), .window)
                    }
                }
            }
            facts(document)
        }
        .padding(20)
    }

    private func facts(_ document: HarnessDocument) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 10) {
            if document.tasks > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tasks").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ProgressView(value: Double(document.tasksDone), total: Double(document.tasks))
                            .frame(width: 60)
                        Text(verbatim: "\(document.tasksDone) of \(document.tasks)").monospacedDigit()
                    }
                }
            }
            if let date = document.date { fact("Date", date.formatted(date: .abbreviated, time: .omitted)) }
            if let owner = document.owner {
                let person = orgs.snapshot(for: org)?.members.first { $0.login == owner }
                    ?? Person(login: owner, name: nil, avatarUrl: URL(string: "https://github.com/\(owner).png?size=64"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Owner").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Avatar(url: person.avatarUrl, size: 20)
                        Text(person.displayName).lineLimit(1)
                    }
                    .help(owner)
                }
            }
            if let branch = document.branch { fact("Branch", branch, monospaced: true) }
            if let domains = document.domains, !domains.isEmpty {
                fact(domains.count == 1 ? "Domain" : "Domains", domains.map(HarnessView.prettify).joined(separator: ", "))
            }
        }
    }

    private func fact(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .callout.monospaced() : nil)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    /// Jump to a section (opening it), or fold or open them all.
    @ViewBuilder
    private func contents(_ sections: [HarnessDocumentSection], proxy: ScrollViewProxy) -> some View {
        let titled = sections.filter { $0.title != nil }
        if titled.count > 1 {
            Menu {
                ForEach(titled) { section in
                    Button(section.title ?? "") {
                        folded.remove(section.id)
                        withAnimation { proxy.scrollTo(section.anchor, anchor: .top) }
                    }
                }
                Divider()
                Button("Fold All Sections") { withAnimation(.snappy(duration: 0.2)) { folded = Set(titled.map(\.id)) } }
                Button("Open All Sections") { withAnimation(.snappy(duration: 0.2)) { folded = [] } }
            } label: {
                Label("Contents", systemImage: "list.bullet.indent")
            }
            .fixedSize()
            .help("Go to a section")
        }
    }

    private var textSize: some View {
        ControlGroup {
            Button { size = max(Self.sizes.lowerBound, size - 1) } label: {
                Label("Smaller", systemImage: "textformat.size.smaller")
            }
            .disabled(size <= Self.sizes.lowerBound)
            .help("Make the text smaller")
            Button { size = min(Self.sizes.upperBound, size + 1) } label: {
                Label("Bigger", systemImage: "textformat.size.larger")
            }
            .disabled(size >= Self.sizes.upperBound)
            .help("Make the text bigger")
        }
        .labelStyle(.iconOnly)
        .fixedSize()
    }

    // MARK: Text

    /// The summary, then a section per `##` heading, each folding from its
    /// header.
    @ViewBuilder
    private func textSections(_ document: HarnessDocument, sections: [HarnessDocumentSection]) -> some View {
        if let summary = document.summary {
            Section("Summary") {
                Text(summary)
                    .font(.system(size: size))
                    .lineSpacing(size * 0.3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        ForEach(sections) { section in
            let isFolded = folded.contains(section.id)
            Section {
                if !isFolded {
                    MarkdownText(source: section.body, reflows: true, reading: size)
                        .padding(.vertical, 4)
                }
            } header: {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if isFolded { folded.remove(section.id) } else { folded.insert(section.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isFolded ? 0 : 90))
                        Text(section.title ?? "Overview")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isFolded ? "Open this section" : "Fold this section")
            }
            .id(section.anchor)
        }
    }

    // MARK: Details

    /// What it's about and depends on, the code it touches, what it
    /// mentions, and the file.
    @ViewBuilder
    private func detailSections(_ document: HarnessDocument, index: HarnessIndex, lookup: IssueLookup) -> some View {
        let subjects = document.references.filter(\.isSubject)
        let mentions = document.references.filter { !$0.isSubject }
        Section(header: SectionHeader(title: "Issues", count: subjects.count)) {
            if subjects.isEmpty {
                Text(document.kind == .plans || document.kind == .requirements ? "Not linked to an issue" : "None")
                    .foregroundStyle(document.kind == .plans || document.kind == .requirements ? .orange : .secondary)
            }
            HarnessIssueList(org: org, index: index, references: subjects, lookup: lookup)
        }
        if document.requirement != nil || !(document.dependsOn ?? []).isEmpty {
            Section("Plan") {
                if let requirement = document.requirement {
                    LabeledContent("Requirement") { documentLink(requirement, index: index) }
                }
                ForEach(document.dependsOn ?? [], id: \.self) { item in
                    LabeledContent("Depends on") {
                        if item.hasSuffix(".md") {
                            documentLink(item, index: index)
                        } else if let reference = HarnessDocument.references(in: item, isSubject: false).first {
                            HarnessIssueList(org: org, index: index, references: [reference], lookup: lookup)
                        } else {
                            Text(item)
                        }
                    }
                }
            }
        }
        if let touches = document.touches, !touches.isEmpty {
            Section(header: SectionHeader(title: "Touches", count: touches.count)) {
                ForEach(touches, id: \.self) { item in
                    Text(item)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item)
                }
            }
        }
        if !mentions.isEmpty {
            Section(header: SectionHeader(title: "Mentions", count: mentions.count)) {
                HarnessIssueList(org: org, index: index, references: mentions, lookup: lookup)
            }
        }
        Section("File") {
            Text(document.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let url = index.url(for: document) {
                Link(destination: url) {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
            }
            if !document.followsStandard {
                Text("Written before the harness's STANDARDS.md, so it has no front matter yet.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Another harness document by path, opening in a drawer over this one.
    @ViewBuilder
    private func documentLink(_ path: String, index: HarnessIndex) -> some View {
        if let target = index.document(at: path) {
            Button {
                navigate?(.harnessDocument(target.path))
            } label: {
                Text(target.title)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            .linkButton()
            .help(target.path)
        } else {
            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    /// Issues named in the text open in a drawer when Gannin has them;
    /// links to other harness documents open theirs. Anything else goes to
    /// the browser.
    private func open(_ url: URL, document: HarnessDocument, index: HarnessIndex, lookup: IssueLookup) -> OpenURLAction.Result {
        if url.scheme == "gannin-issue", let owner = url.host() {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 2, let number = Int(parts[1]) else { return .discarded }
            let repo = "\(owner)/\(parts[0])"
            if let record = lookup.record(repo: repo, number: number), let navigate {
                navigate(.issueReference(IssueReference(org: org, record: record)))
            } else if let github = URL(string: "https://github.com/\(repo)/issues/\(number)") {
                openURL(github)
            }
            return .handled
        }
        if url.scheme == nil, url.path().hasSuffix(".md"), let navigate {
            let base = URL(filePath: "/" + document.path).deletingLastPathComponent()
            let resolved = URL(filePath: url.path(), relativeTo: base).standardizedFileURL.path().dropFirst()
            if index.document(at: String(resolved)) != nil {
                navigate(.harnessDocument(String(resolved)))
                return .handled
            }
        }
        return .systemAction
    }
}

/// A document's text cut at its `##` (and `#`) headings, outside code: what
/// comes before the first is untitled.
struct HarnessDocumentSection: Identifiable {
    let id: Int
    let title: String?
    let body: String

    var anchor: String { "harness-section-\(id)" }

    static func split(_ text: String) -> [HarnessDocumentSection] {
        var sections: [HarnessDocumentSection] = []
        var title: String?
        var lines: [String] = []
        var inFence = false
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if title != nil || !body.isEmpty {
                sections.append(HarnessDocumentSection(id: sections.count, title: title.map(plain), body: body))
            }
            lines = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if !inFence, trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") {
                flush()
                title = String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            } else if !inFence, trimmed == "---", lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                // A rule straight under a heading only separates.
                continue
            } else {
                lines.append(line)
            }
        }
        flush()
        return sections
    }

    /// A heading without its Markdown (bold, links, code).
    private static func plain(_ text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)).map { String($0.characters) } ?? text
    }
}

/// Issues a document names; each opens in a drawer where Gannin has it,
/// else on GitHub.
private struct HarnessIssueList: View {
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    let org: String
    let index: HarnessIndex
    let references: [HarnessReference]
    let lookup: IssueLookup

    /// A row each, for a Form section.
    var body: some View {
        Group {
            ForEach(references, id: \.self) { reference in
                let repo = index.repo(of: reference)
                let record = lookup.record(repo: repo, number: reference.number)
                Button {
                    open(record: record, repo: repo, number: reference.number)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(record.map(IssueStateDot.color) ?? .secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text(verbatim: repo == index.issuesRepo ? "#\(reference.number)" : "\(repo ?? "")#\(reference.number)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let record {
                            Text(record.title).lineLimit(2).multilineTextAlignment(.leading)
                        } else {
                            // A PR, or an issue outside the history: GitHub
                            // has it (issue links redirect to PRs).
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(record == nil ? "Open on GitHub" : "Open the issue")
            }
        }
    }

    private func open(record: IssueRecord?, repo: String?, number: Int) {
        if let record, let navigate {
            navigate(.issueReference(IssueReference(org: org, record: record)))
        } else if let url = record?.url ?? repo.flatMap({ URL(string: "https://github.com/\($0)/issues/\(number)") }) {
            openURL(url)
        }
    }
}

// MARK: - On an issue

/// The harness documents about or mentioning an issue, in its page.
struct HarnessIssueSection: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    let reference: IssueReference

    var body: some View {
        if let setup = configs.config(for: reference.org).harness,
           let index = harness.index(for: reference.org, setup) {
            let matches = index.matches(repo: reference.repo, number: reference.number)
            if !matches.isEmpty {
                Section(header: SectionHeader(title: "Plans and requirements", count: matches.count)) {
                    ForEach(matches) { match in
                        row(match, index: index)
                    }
                }
            }
        }
    }

    private func row(_ match: HarnessMatch, index: HarnessIndex) -> some View {
        let document = match.document
        return Button {
            if let navigate {
                navigate(.harnessDocument(document.path))
            } else if let url = index.url(for: document) {
                openURL(url)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: document.kind.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(document.title).lineLimit(1)
                    Text(match.isSubject ? document.path : "\(document.path) · mentions it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if document.tasks > 0 {
                    TaskCount(done: document.tasksDone, total: document.tasks)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings

/// Settings: the org's harness repo and branch, picked from GitHub's.
struct HarnessSettingsSection: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    @State private var isCreating = false

    var body: some View {
        let saved = configs.config(for: org).harness
        // What's saved stays listed even before GitHub's lists load.
        let repos = Set(harness.repositories[org] ?? []).union(saved.map { [$0.repo] } ?? [])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        Section {
            LabeledContent("Repository") {
                SearchablePicker(
                    choices: [SearchableChoice(value: nil, title: "None")] + repos.map { SearchableChoice(value: $0, title: $0) },
                    selection: saved?.repo,
                    prompt: "Search repositories",
                    isLoading: harness.repositories[org] == nil
                ) { repo in
                    // Another repo starts on its default branch.
                    guard repo != saved?.repo else { return }
                    configs.update(org) { $0.harness = repo.map { HarnessConfig(repo: $0) } }
                }
            }
            if let saved {
                let branches = harness.branches[saved.repo]
                // The default is Default's, so it isn't listed again.
                let listed = Set(branches?.all ?? []).union(saved.branch.map { [$0] } ?? [])
                    .subtracting(branches?.defaultBranch.map { [$0] } ?? [])
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                LabeledContent("Branch") {
                    SearchablePicker(
                        choices: [SearchableChoice(value: nil, title: branches?.defaultBranch.map { "Default (\($0))" } ?? "Default")]
                            + listed.map { SearchableChoice(value: $0, title: $0) },
                        selection: saved.branch,
                        prompt: "Search branches",
                        isLoading: branches == nil
                    ) { branch in
                        configs.update(org) { $0.harness?.branch = branch }
                    }
                }
                .task(id: saved.repo) { await harness.loadBranches(repo: saved.repo) }
                // Only a failure to read it; what's found is on the Harness page.
                if let error = harness.errors[org] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } else {
                LabeledContent {
                    Button("Create Harness") { isCreating = true }
                } label: {
                    Text("No harness yet?")
                    Text("Make a private repo in \(org) with the layout Gannin and Claude Code sessions use.")
                }
            }
        } header: {
            Text("Harness")
        }
        .task { await harness.loadRepositories(org: org) }
        .loadsHarness(org: org)
        .sheet(isPresented: $isCreating) { CreateHarnessSheet(org: org) }
        if let saved {
            TeamDataSection(org: org, setup: saved)
        }
        #if os(macOS)
        if let saved {
            HarnessCheckoutSection(org: org, repo: saved.repo)
        }
        #endif
    }
}
