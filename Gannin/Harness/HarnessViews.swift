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
    @Environment(OrgStore.self) private var orgs
    @Environment(\.openURL) private var openURL
    /// Picked under Harness in the sidebar, which writes the same key.
    @SceneStorage("harnessKind") private var kind: HarnessKind = .plans
    @State private var unlinkedOnly = false
    @State private var search = ""
    /// Front matter values picked, by field; any of a field's values matches.
    @State private var picked: [String: Set<String>] = [:]
    /// Nil is newest first.
    @State private var sort: StatsSort?
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
        .loadsHarness(org: org)
    }

    @ViewBuilder
    private func content(_ setup: HarnessConfig) -> some View {
        let repo = setup.repo
        if let index = harness.index(for: org, setup) {
            let lookup = IssueLookup(history: issueStore.history(for: org))
            let linkable = kind == .plans || kind == .requirements
            let pool = index.documents(kind)
                .filter { !(linkable && unlinkedOnly) || $0.subjects.isEmpty }
                .filter { matches($0) }
            let ofKind = pool.filter { matchesPicked($0) }
            let documents = ofKind.filter { showsOlder || $0.followsStandard }
            let older = ofKind.count(where: { !$0.followsStandard })
            VStack(spacing: 0) {
                bar(linkable: linkable, pool: pool)
                Divider()
                list(documents: documents, older: older, index: index, lookup: lookup, linkable: linkable, setup: setup)
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

    /// Search, a menu for each front matter field the documents share
    /// values in, and Not Linked for plans and requirements.
    private func bar(linkable: Bool, pool: [HarnessDocument]) -> some View {
        HStack(spacing: 8) {
            FilterSearchField(text: $search, prompt: "Title, summary, path or issue")
            ForEach(Self.filterFields(pool), id: \.self) { field in
                fieldMenu(field, pool: pool)
            }
            if linkable {
                Toggle("Not Linked", isOn: $unlinkedOnly)
                    .toggleStyle(.button)
                    .help("Only the \(kind.rawValue.lowercased()) that name no issue")
            }
            Spacer(minLength: 0)
            if !search.isEmpty || picked.values.contains(where: { !$0.isEmpty }) || unlinkedOnly {
                Button("Clear All") {
                    search = ""
                    picked = [:]
                    unlinkedOnly = false
                }
                .linkButton()
            }
        }
        .onChange(of: kind) { picked = [:] }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Fields that differ for every document, or are prose or links, make
    /// no filter.
    private static let unfilterable: Set<String> = [
        "type", "summary", "description", "title", "name", "branch", "issues", "prs", "depends-on", "requirement", "notion", "github", "issue",
    ]

    /// Known fields first, in the standard's order, then the rest by name.
    private static let fieldOrder = ["status", "domains", "owner", "touches", "severity", "repos"]

    /// Front matter fields with a value that two or more documents share.
    static func filterFields(_ documents: [HarnessDocument]) -> [String] {
        var counts: [String: [String: Int]] = [:]
        for document in documents {
            for (field, values) in document.frontMatter ?? [:] where !unfilterable.contains(field) {
                for value in Set(values.map { filterValue($0, field: field) }) where !value.isEmpty {
                    counts[field, default: [:]][value, default: 0] += 1
                }
            }
        }
        return counts.filter { $0.value.values.contains { $0 > 1 } }.keys.sorted { a, b in
            let (i, j) = (fieldOrder.firstIndex(of: a) ?? Int.max, fieldOrder.firstIndex(of: b) ?? Int.max)
            return i != j ? i < j : a < b
        }
    }

    /// A value as it's filtered by: a repo for `owner/repo:path`, the rest as written.
    private static func filterValue(_ value: String, field: String) -> String {
        field == "touches" ? String(value.split(separator: ":").first ?? "") : value.lowercased()
    }

    private func values(_ document: HarnessDocument, field: String) -> Set<String> {
        Set((document.frontMatter?[field] ?? []).map { Self.filterValue($0, field: field) })
    }

    private func matchesPicked(_ document: HarnessDocument, except field: String? = nil) -> Bool {
        picked.allSatisfy { key, chosen in
            key == field || chosen.isEmpty || !values(document, field: key).isDisjoint(with: chosen)
        }
    }

    /// A field's values across the documents (as they'd be without this
    /// field's filter), with counts.
    private func fieldMenu(_ field: String, pool: [HarnessDocument]) -> some View {
        var counts: [String: Int] = [:]
        for document in pool where matchesPicked(document, except: field) {
            for value in values(document, field: field) where !value.isEmpty { counts[value, default: 0] += 1 }
        }
        let options = counts.keys.map { value in
            FilterOption(value: value, title: title(value, field: field), count: counts[value] ?? 0)
        }
        // Statuses in the standard's order; the rest by name.
        let ordered = field == "status"
            ? options.sorted { (Self.statusOrder.firstIndex(of: $0.value) ?? 99, $0.title) < (Self.statusOrder.firstIndex(of: $1.value) ?? 99, $1.title) }
            : options.sorted(byCount: field == "owner")
        return FilterMenu(
            title: field.replacingOccurrences(of: "-", with: " ").capitalized,
            options: ordered,
            picked: Binding(get: { picked[field] ?? [] }, set: { picked[field] = $0 })
        )
    }

    private static let statusOrder = ["draft", "agreed", "open", "investigating", "in-progress", "fixing", "blocked", "done", "fixed", "abandoned", "wont-fix"]

    private func title(_ value: String, field: String) -> String {
        switch field {
        case "owner": orgs.snapshot(for: org)?.members.first { $0.login.lowercased() == value }?.displayName ?? value
        case "touches": value.split(separator: "/").last.map(String.init) ?? value
        case "domains": Self.prettify(value)
        default:
            value.prefix(1).uppercased() + value.dropFirst().replacingOccurrences(of: "-", with: " ")
        }
    }

    /// Every word typed in its title, summary, path or an issue it names.
    private func matches(_ document: HarnessDocument) -> Bool {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let fields = [document.title, document.summary ?? "", document.path] + (document.domains ?? [])
            + document.references.map { "\($0.repo ?? "")#\($0.number)" }
        return words.allSatisfy { word in fields.contains { $0.localizedCaseInsensitiveContains(word) } }
    }

    private func list(documents: [HarnessDocument], older: Int, index: HarnessIndex, lookup: IssueLookup, linkable: Bool, setup: HarnessConfig) -> some View {
        let repo = setup.repo
        let newestFirst = documents.sorted { a, b in
            if a.date != b.date { return (a.date ?? .distantPast) > (b.date ?? .distantPast) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = harness.errors[org] {
                    Banner(message: "Refresh failed: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                        Task { await harness.load(org: org, setup: setup, force: true) }
                    }
                    .padding(.horizontal, 14)
                }
                if documents.isEmpty {
                    Text(!search.isEmpty || picked.values.contains(where: { !$0.isEmpty }) ? "Nothing matches." : unlinkedOnly ? "Every one names an issue." : older > 0 ? "No \(kind.rawValue.lowercased()) follow the standard yet." : "No \(kind.rawValue.lowercased()) in \(repo).")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                } else {
                    StatsTable(
                        rows: newestFirst,
                        columns: columns(index: index, lookup: lookup, linkable: linkable),
                        sort: $sort,
                        selectedID: nil,
                        onSelect: { selection = .harnessDocument($0.path) },
                        contextMenu: { document in
                            AnyView(Group {
                                if let url = index.url(for: document) {
                                    Button("Open on GitHub") { openURL(url) }
                                }
                            })
                        },
                        destination: { .harnessDocument($0.path) }
                    )
                }
                if older > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(showsOlder
                                 ? "Showing \(older) older \(older == 1 ? kind.singular : kind.rawValue.lowercased()) without front matter."
                                 : "\(older) older \(older == 1 ? kind.singular : kind.rawValue.lowercased()) without front matter \(older == 1 ? "isn't" : "aren't") shown.")
                                .foregroundStyle(.secondary)
                            Button(showsOlder ? "Hide Them" : "Show Them") { showsOlder.toggle() }
                                .linkButton()
                        }
                        Text("Documents written to the harness's STANDARDS.md (front matter with a summary) are listed; older ones appear once they're converted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 14)
                }
            }
            .padding(.vertical, 12)
        }
    }

    /// Title with its summary, status, domain, issues, tasks, owner and date.
    private func columns(index: HarnessIndex, lookup: IssueLookup, linkable: Bool) -> [StatsColumn<HarnessDocument>] {
        var columns: [StatsColumn<HarnessDocument>] = [
            StatsColumn(id: "title", title: kind.singular.capitalized, help: "Its title, with its summary", width: nil, minWidth: 320,
                        sortKey: { .text($0.title.lowercased()) },
                        cell: { document in
                            AnyView(VStack(alignment: .leading, spacing: 2) {
                                Text(document.title).lineLimit(1)
                                if let summary = document.summary {
                                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                            .help(document.path))
                        }),
            StatsColumn(id: "status", title: "Status", help: "Its front matter status", width: 110,
                        sortKey: { .text(($0.statusLabel ?? "").lowercased()) },
                        cell: { document in
                            AnyView(Group {
                                if let status = document.shortStatus {
                                    Pill(text: status, color: .secondary)
                                        .lineLimit(1)
                                        .help(document.status ?? status)
                                }
                            })
                        }),
            StatsColumn(id: "domain", title: "Domain", help: "Its main domain, else its folder", width: 120,
                        sortKey: { .text(($0.area ?? "").lowercased()) },
                        cell: { AnyView(Text($0.area.map(Self.prettify) ?? "").lineLimit(1).help(($0.domains ?? []).joined(separator: ", "))) }),
        ]
        if linkable || kind == .findings {
            columns.append(StatsColumn(id: "issues", title: "Issues", help: "The issues it's about", width: 200,
                                       sortKey: { .number(Double($0.subjects.first?.number ?? 0)) },
                                       cell: { document in
                                           AnyView(Group {
                                               if document.subjects.isEmpty {
                                                   Text(linkable ? "Not linked" : "").font(.caption).foregroundStyle(.orange)
                                               } else {
                                                   issueLine(document.subjects, index: index, lookup: lookup)
                                               }
                                           })
                                       }))
        }
        if kind == .plans {
            columns.append(StatsColumn(id: "tasks", title: "Tasks", help: "Checkboxes ticked of those in it", width: 80,
                                       sortKey: { .number($0.tasks == 0 ? -1 : Double($0.tasksDone) / Double($0.tasks)) },
                                       cell: { document in
                                           AnyView(Group {
                                               if document.tasks > 0 { TaskCount(done: document.tasksDone, total: document.tasks) }
                                           })
                                       }))
        }
        columns.append(StatsColumn(id: "owner", title: "Owner", help: "Who's driving it", width: 130,
                                   sortKey: { .text(($0.owner ?? "").lowercased()) },
                                   cell: { document in
                                       AnyView(Text(document.owner.map { login in orgs.snapshot(for: org)?.members.first { $0.login == login }?.displayName ?? login } ?? "")
                                           .lineLimit(1))
                                   }))
        columns.append(StatsColumn(id: "date", title: "Date", help: "From its file name", width: 100,
                                   sortKey: { .number($0.date?.timeIntervalSince1970 ?? 0) },
                                   cell: { document in
                                       AnyView(Text(document.date?.formatted(date: .abbreviated, time: .omitted) ?? "")
                                           .foregroundStyle(.secondary)
                                           .monospacedDigit())
                                   }))
        return columns
    }

    /// `data-capture` as "Data capture"; short names like `cdm` in capitals.
    static func prettify(_ name: String) -> String {
        if name.count <= 3 { return name.uppercased() }
        let words = name.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
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
                                VStack(spacing: 0) {
                                    readingBar(sections, proxy: proxy)
                                    Form { textSections(document, sections: sections) }
                                        .formStyle(.grouped)
                                }
                                .frame(minWidth: 480, maxWidth: .infinity)
                                Divider()
                                Form { detailSections(document, index: index, lookup: lookup) }
                                    .formStyle(.grouped)
                                    .frame(width: 340)
                            }
                        } else {
                            readingBar(sections, proxy: proxy)
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

    /// Over the text: Contents, and the text size.
    private func readingBar(_ sections: [HarnessDocumentSection], proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            contents(sections, proxy: proxy)
            Spacer(minLength: 0)
            textSize
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.top, 12)
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
