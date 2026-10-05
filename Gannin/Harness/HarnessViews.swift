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
        let harnesses = configs.config(for: org).harnesses
        content.task(id: harnesses) {
            await harness.loadAll(org: org, harnesses)
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
    /// New on the page, and Edit on a skill or prompt.
    @State private var creatingIn: HarnessChoice?
    @State private var editingSkill: HarnessEdit<HarnessDocument>?
    @State private var editingPrompt: HarnessEdit<HarnessPrompt>?
    /// Only one harness's documents, by repo; nil for every harness.
    @State private var harnessFilter: String?
    let org: String
    @Binding var selection: DetailSelection?

    /// A harness to write a new document in.
    struct HarnessChoice: Identifiable {
        let setup: HarnessConfig
        var id: String { setup.repo }
    }

    /// A document to edit, in the harness it's in, by its own path.
    struct HarnessEdit<Item>: Identifiable {
        let setup: HarnessConfig
        let item: Item
        let id: String
    }

    var body: some View {
        let harnesses = configs.config(for: org).harnesses
        let setup = harnesses.first
        Group {
            if let setup {
                content(setup, harnesses: harnesses)
            } else {
                ContentUnavailableView(
                    "No harness",
                    systemImage: "text.book.closed",
                    description: Text("Pick the repo the org keeps its plans and requirements in, or create one, in Settings.")
                )
            }
        }
        .loadsHarness(org: org)
        .toolbar {
            if let setup {
                ToolbarItem {
                    if harnesses.count > 1 {
                        // Which harness it goes in.
                        Menu {
                            ForEach(harnesses, id: \.repo) { choice in
                                Button(choice.repo) { creatingIn = HarnessChoice(setup: choice) }
                                    .disabled(harness.index(for: org, choice) == nil)
                            }
                        } label: {
                            Label(HarnessNewDocumentSheet.title(kind), systemImage: "plus")
                        }
                        .help("Write a new \(kind.singular) in one of the harnesses")
                    } else {
                        Button {
                            creatingIn = HarnessChoice(setup: setup)
                        } label: {
                            Label(HarnessNewDocumentSheet.title(kind), systemImage: "plus")
                        }
                        .disabled(harness.index(for: org, setup) == nil)
                        .help("Write a new \(kind.singular) and commit it to \(setup.repo)")
                    }
                }
            }
        }
        .sheet(item: $creatingIn) { choice in
            HarnessNewDocumentSheet(kind: kind, org: org, setup: choice.setup)
        }
        .sheet(item: $editingSkill) { edit in
            HarnessSkillEditor(org: org, setup: edit.setup, document: edit.item)
        }
        .sheet(item: $editingPrompt) { edit in
            HarnessPromptEditor(org: org, setup: edit.setup, library: HarnessPromptLibrary(index: harness.index(for: org, edit.setup)), prompt: edit.item)
        }
    }

    /// The harness a document in the combined index is in, and the
    /// document as that harness has it.
    private func source(of document: HarnessDocument) -> (HarnessConfig, HarnessDocument)? {
        let config = configs.config(for: org)
        let (repo, path) = HarnessIndex.split(document.path)
        guard let setup = repo.flatMap(config.harness(repo:)) ?? config.harnesses.first,
              let own = harness.index(for: org, setup)?.document(at: path) else { return nil }
        return (setup, own)
    }

    @ViewBuilder
    private func content(_ setup: HarnessConfig, harnesses: [HarnessConfig]) -> some View {
        let repo = setup.repo
        if let index = harness.combined(org: org, harnesses) {
            let lookup = IssueLookup(history: issueStore.history(for: org))
            let linkable = kind == .plans || kind == .requirements
            let pool = index.documents(kind).filter(\.followsStandard)
                .filter { !(linkable && unlinkedOnly) || $0.subjects.isEmpty }
                .filter { harnessFilter == nil || ($0.harnessRepo ?? setup.repo) == harnessFilter }
                .filter { matches($0) }
            // Only what follows the standard; older documents aren't listed.
            let documents = pool.filter { $0.followsStandard && matchesPicked($0) }
            VStack(spacing: 0) {
                bar(linkable: linkable, pool: pool, harnesses: harnesses)
                Divider()
                list(documents: documents, index: index, lookup: lookup, linkable: linkable, setup: setup, showsHarness: harnesses.count > 1 && harnessFilter == nil)
            }
        } else if let error = harness.error(org, setup) {
            ContentUnavailableView {
                Label("Couldn't read \(repo)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await harness.load(org: org, setup: setup, force: true) } }
            }
        } else if harness.isLoading(org, setup) {
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
    private func bar(linkable: Bool, pool: [HarnessDocument], harnesses: [HarnessConfig]) -> some View {
        HStack(spacing: 8) {
            FilterSearchField(text: $search, prompt: "Title, summary, path or issue")
            if harnesses.count > 1 {
                Picker("Harness", selection: $harnessFilter) {
                    Text("Every harness").tag(String?.none)
                    Divider()
                    ForEach(harnesses, id: \.repo) { Text($0.name).tag(Optional($0.repo)) }
                }
                .fixedSize()
                .help("Only one harness's \(kind.rawValue.lowercased())")
            }
            ForEach(Self.filterFields(pool), id: \.self) { field in
                fieldMenu(field, pool: pool)
            }
            if linkable {
                Toggle("Not Linked", isOn: $unlinkedOnly)
                    .toggleStyle(.button)
                    .help("Only the \(kind.rawValue.lowercased()) that name no issue")
            }
            Spacer(minLength: 0)
            if !search.isEmpty || picked.values.contains(where: { !$0.isEmpty }) || unlinkedOnly || harnessFilter != nil {
                Button("Clear All") {
                    search = ""
                    picked = [:]
                    unlinkedOnly = false
                    harnessFilter = nil
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

    private func list(documents: [HarnessDocument], index: HarnessIndex, lookup: IssueLookup, linkable: Bool, setup: HarnessConfig, showsHarness: Bool) -> some View {
        let repo = setup.repo
        let newestFirst = documents.sorted { a, b in
            if a.date != b.date { return (a.date ?? .distantPast) > (b.date ?? .distantPast) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = harness.error(org, setup) {
                    Banner(message: "Refresh failed: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                        Task { await harness.load(org: org, setup: setup, force: true) }
                    }
                    .padding(.horizontal, 14)
                }
                if documents.isEmpty {
                    Text(!search.isEmpty || picked.values.contains(where: { !$0.isEmpty }) ? "Nothing matches." : unlinkedOnly ? "Every one names an issue." : "No \(kind.rawValue.lowercased()) in \(repo).")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                } else {
                    StatsTable(
                        rows: newestFirst,
                        columns: columns(index: index, lookup: lookup, linkable: linkable, showsHarness: showsHarness, primary: setup.repo),
                        sort: $sort,
                        selectedID: nil,
                        onSelect: { selection = .harnessDocument($0.path) },
                        contextMenu: { document in
                            AnyView(Group {
                                if document.kind == .skills, let (setup, own) = source(of: document) {
                                    Button("Edit Skill") { editingSkill = HarnessEdit(setup: setup, item: own, id: document.path) }
                                }
                                if document.kind == .prompts, let (setup, own) = source(of: document), let prompt = HarnessPrompt(document: own) {
                                    Button("Edit Prompt") { editingPrompt = HarnessEdit(setup: setup, item: prompt, id: document.path) }
                                }
                                if let url = index.url(for: document) {
                                    Button("Open on GitHub") { openURL(url) }
                                }
                            })
                        },
                        destination: { .harnessDocument($0.path) }
                    )
                }
            }
            .padding(.vertical, 12)
        }
    }

    /// Title with its summary, status, domain, issues, tasks, owner and date.
    private func columns(index: HarnessIndex, lookup: IssueLookup, linkable: Bool, showsHarness: Bool, primary: String) -> [StatsColumn<HarnessDocument>] {
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
        if showsHarness {
            columns.append(StatsColumn(id: "harness", title: "Harness", help: "The harness it's in", width: 120,
                                       sortKey: { .text(($0.harnessRepo ?? primary).lowercased()) },
                                       cell: { document in
                                           AnyView(Text((document.harnessRepo ?? primary).split(separator: "/").last.map(String.init) ?? "")
                                               .foregroundStyle(.secondary)
                                               .lineLimit(1))
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
    @Environment(AuthStore.self) private var auth
    @Environment(\.navigate) private var navigate
    @Environment(\.openAsPage) private var openAsPage
    @Environment(\.openElsewhere) private var openElsewhere
    @Environment(\.openURL) private var openURL
    let org: String
    let path: String
    var onClose: (() -> Void)? = nil

    @State private var width: CGFloat = 1000
    @State private var draftingIssues = false
    @State private var planning = false
    @State private var editingDetails = false
    /// Folded sections, by index.
    @State private var folded: Set<Int> = []
    @AppStorage("harnessReadingSize") private var size: Double = 14

    private static let sizes: ClosedRange<Double> = 11...20

    var body: some View {
        Group {
            if let index = harness.combined(org: org, configs.config(for: org).harnesses), let document = index.document(at: path) {
                let lookup = IssueLookup(history: issueStore.history(for: org))
                let sections = HarnessDocumentSection.split(document.linkedBody(issuesRepo: index.issuesRepo))
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        header(document, index: index, sections: sections, proxy: proxy)
                            .sheet(isPresented: $draftingIssues) {
                                DraftIssuesSheet(org: org, document: document, index: index)
                            }
                            .sheet(isPresented: $planning) {
                                NewPlanningSheet(org: org, documentPath: document.path, topic: document.title)
                            }
                            .sheet(isPresented: $editingDetails) {
                                if let (setup, own) = source(of: document) {
                                    HarnessDetailsEditor(org: org, setup: setup, document: document, path: own)
                                }
                            }
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
                                overview(document)
                                textSections(document, sections: sections)
                                detailSections(document, index: index, lookup: lookup, includesOverview: false)
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

    /// The title and what can be done with it; its facts are atop the
    /// details column.
    private func header(_ document: HarnessDocument, index: HarnessIndex, sections: [HarnessDocumentSection], proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(document.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if document.kind == .plans || document.kind == .requirements {
                Button("Draft Issues") { draftingIssues = true }
                    .help("Claude breaks it into issues for you to edit, then makes them on GitHub")
            }
            Button("Plan with Claude") { planning = true }
                .help("Start a planning session in the harness from this document")
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
            if let onClose {
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
            }
        }
        .padding(20)
    }

    /// The harness a document in the combined index is in, and its path
    /// there.
    private func source(of document: HarnessDocument) -> (HarnessConfig, String)? {
        let config = configs.config(for: org)
        let (repo, path) = HarnessIndex.split(document.path)
        return (repo.flatMap(config.harness(repo:)) ?? config.harnesses.first).map { ($0, path) }
    }

    /// Status, kind, tasks, owner, branch and domains, a row each, and
    /// Edit Details for the ones in its front matter.
    @ViewBuilder
    private func overview(_ document: HarnessDocument) -> some View {
        Section {
            LabeledContent("Status") {
                Pill(text: document.statusLabel ?? "No status", color: .secondary)
                    .help(document.status ?? "No status")
            }
            LabeledContent("Kind") {
                Label(document.kind.singular.capitalized, systemImage: document.kind.systemImage)
            }
            if document.tasks > 0 {
                LabeledContent("Tasks") {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(document.tasksDone), total: Double(document.tasks))
                            .frame(width: 70)
                        Text(verbatim: "\(document.tasksDone) of \(document.tasks)").monospacedDigit()
                    }
                }
            }
            if let owner = document.owner {
                let person = orgs.snapshot(for: org)?.members.first { $0.login == owner }
                    ?? Person(login: owner, name: nil, avatarUrl: URL(string: "https://github.com/\(owner).png?size=64"))
                LabeledContent("Owner") {
                    HStack(spacing: 6) {
                        Avatar(url: person.avatarUrl, size: 18)
                        Text(person.displayName).lineLimit(1)
                    }
                    .help(owner)
                }
            }
            if let branch = document.branch {
                LabeledContent("Branch") {
                    Text(branch).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            if let domains = document.domains, !domains.isEmpty {
                LabeledContent(domains.count == 1 ? "Domain" : "Domains", value: domains.map(HarnessView.prettify).joined(separator: ", "))
            }
            Button("Edit Details") { editingDetails = true }
                .help("Change its status, owner and domains, committed to the harness")
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

    /// Its facts, what it's about and depends on, the code it touches, what
    /// it mentions, and the file.
    @ViewBuilder
    private func detailSections(_ document: HarnessDocument, index: HarnessIndex, lookup: IssueLookup, includesOverview: Bool = true) -> some View {
        if includesOverview { overview(document) }
        let subjects = document.references.filter(\.isSubject)
        let mentions = document.references.filter { !$0.isSubject }
        Section(header: SectionHeader(title: "Issues", count: subjects.count)) {
            if subjects.isEmpty {
                Text(document.kind == .plans || document.kind == .requirements ? "Not linked to an issue" : "None")
                    .foregroundStyle(document.kind == .plans || document.kind == .requirements ? .orange : .secondary)
            }
            HarnessIssueList(org: org, index: index, references: subjects, lookup: lookup)
        }
        if let requirement = document.requirement {
            Section("Requirement") { documentRow(requirement, index: index) }
        }
        if let dependsOn = document.dependsOn, !dependsOn.isEmpty {
            Section(header: SectionHeader(title: "Depends on", count: dependsOn.count)) {
                ForEach(dependsOn, id: \.self) { item in
                    if item.hasSuffix(".md") {
                        documentRow(item, index: index)
                    } else {
                        HarnessIssueList(org: org, index: index, references: HarnessDocument.references(in: item, isSubject: false), lookup: lookup)
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
    private func documentRow(_ path: String, index: HarnessIndex) -> some View {
        if let target = index.document(at: path) {
            HarnessDocumentRow(document: target)
        } else {
            Text(path).font(.callout.monospaced()).foregroundStyle(.secondary)
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
            } else {
                Task { await HarnessReferences.shared.open(repo: repo, number: number, org: org, auth: auth, navigate: navigate, openURL: openURL) }
            }
            return .handled
        }
        if url.scheme == nil, url.path().hasSuffix(".md"), let navigate {
            // Within the document's own harness, which another's in a
            // combined index names before its path.
            let (harnessRepo, own) = HarnessIndex.split(document.path)
            let base = URL(filePath: "/" + own).deletingLastPathComponent()
            let resolved = String(URL(filePath: url.path(), relativeTo: base).standardizedFileURL.path().dropFirst())
            let path = harnessRepo.map { "\($0):\(resolved)" } ?? resolved
            if index.document(at: path) != nil {
                navigate(.harnessDocument(path))
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
    @Environment(AuthStore.self) private var auth
    let org: String
    let index: HarnessIndex
    let references: [HarnessReference]
    let lookup: IssueLookup

    /// A row each, for a Form section.
    var body: some View {
        ForEach(references, id: \.self) { reference in
            if let repo = index.repo(of: reference) {
                HarnessReferenceRow(org: org, repo: repo, number: reference.number, record: lookup.record(repo: repo, number: reference.number))
            }
        }
    }
}

/// An issue or PR as the document's details list it: its state's dot, its
/// number and its title, opening in a drawer. One the issue history hasn't
/// got is looked up by number for its title and state.
private struct HarnessReferenceRow: View {
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    @Environment(AuthStore.self) private var auth
    let org: String
    let repo: String
    let number: Int
    let record: IssueRecord?

    var body: some View {
        let looked = HarnessReferences.shared.item(repo: repo, number: number)
        Button {
            if let record, let navigate {
                navigate(.issueReference(IssueReference(org: org, record: record)))
            } else {
                Task { await HarnessReferences.shared.open(repo: repo, number: number, org: org, auth: auth, navigate: navigate, openURL: openURL) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(record.map(IssueStateDot.color) ?? looked?.color ?? .secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                // The number then the title, wrapping the full width, with
                // the repo as a caption beneath.
                VStack(alignment: .leading, spacing: 2) {
                    (Text(verbatim: "#\(number)").foregroundStyle(.secondary).monospacedDigit()
                        + Text(verbatim: "  ")
                        + Text(record?.title ?? looked?.title ?? ""))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(looked?.isPullRequest == true ? "\(repo) · pull request" : repo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(record?.title ?? looked?.title ?? "\(repo)#\(number)")
        .task(id: "\(repo)#\(number)") {
            if record == nil { await HarnessReferences.shared.resolve(repo: repo, number: number, auth: auth) }
        }
    }
}

/// Another harness document as the details list it: its kind's icon and
/// title, opening in a drawer.
private struct HarnessDocumentRow: View {
    @Environment(\.navigate) private var navigate
    let document: HarnessDocument

    var body: some View {
        Button {
            navigate?(.harnessDocument(document.path))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: document.kind.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(document.title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let status = document.shortStatus {
                    Pill(text: status, color: .secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(document.path)
    }
}

/// Issues and PRs a document names that the issue history hasn't got,
/// looked up by number for their title, state and ID, so they show and open
/// as any other. Kept for the launch.
@Observable
final class HarnessReferences {
    static let shared = HarnessReferences()

    struct Item {
        let id: String
        let title: String
        let url: URL
        let isPullRequest: Bool
        /// `OPEN`, `CLOSED` or `MERGED`.
        let state: String
        let notPlanned: Bool

        /// As the issue history's dots: open green, done purple, the rest grey.
        var color: Color {
            switch state {
            case "OPEN": .green
            case "MERGED": .purple
            default: isPullRequest || notPlanned ? .secondary : .purple
            }
        }
    }

    private(set) var items: [String: Item] = [:]
    @ObservationIgnored private var asked: Set<String> = []

    func item(repo: String, number: Int) -> Item? { items["\(repo)#\(number)"] }

    /// Looks it up once a launch.
    func resolve(repo: String, number: Int, auth: AuthStore) async {
        let key = "\(repo)#\(number)"
        guard !asked.contains(key), let api = auth.api else { return }
        asked.insert(key)
        if let item = try? await api.issueOrPullRequest(repo: repo, number: number) {
            items[key] = item
        }
    }

    /// In a drawer once looked up; GitHub if it can't be.
    func open(repo: String, number: Int, org: String, auth: AuthStore, navigate: NavigateAction?, openURL: OpenURLAction) async {
        await resolve(repo: repo, number: number, auth: auth)
        if let item = item(repo: repo, number: number), let navigate {
            navigate(item.isPullRequest
                ? .pullRequestReference(PullRequestReference(org: org, id: item.id, number: number, title: item.title, repo: repo, url: item.url))
                : .issueReference(IssueReference(org: org, id: item.id, number: number, title: item.title, repo: repo, url: item.url)))
        } else if let url = URL(string: "https://github.com/\(repo)/issues/\(number)") {
            openURL(url)
        }
    }
}

extension GitHubAPI {
    /// The issue or PR with this number in the repo: its node ID, title and URL.
    func issueOrPullRequest(repo: String, number: Int) async throws -> HarnessReferences.Item? {
        struct Item: Decodable {
            let __typename: String
            let id: String
            let title: String
            let url: URL
            let state: String
            let stateReason: String?
        }
        struct Response: Decodable {
            struct Repository: Decodable { let issueOrPullRequest: Item? }
            let repository: Repository?
        }
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let response: Response = try await query("""
            query($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                issueOrPullRequest(number: $number) {
                  __typename
                  ... on Issue { id title url state stateReason }
                  ... on PullRequest { id title url state }
                }
              }
            }
            """, values: ["owner": parts[0], "name": parts[1], "number": number])
        return response.repository?.issueOrPullRequest.map {
            HarnessReferences.Item(id: $0.id, title: $0.title, url: $0.url, isPullRequest: $0.__typename == "PullRequest", state: $0.state, notPlanned: $0.stateReason == "NOT_PLANNED")
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
    /// Shows the section with nothing in it yet, saying so, as a session
    /// does while claude writes the plan.
    var showsEmpty = false

    var body: some View {
        if let index = harness.combined(org: reference.org, configs.config(for: reference.org).harnesses) {
            // As the Harness page lists them: only those that follow the standard.
            let matches = index.matches(repo: reference.repo, number: reference.number).filter(\.document.followsStandard)
            if !matches.isEmpty || showsEmpty {
                Section(header: SectionHeader(title: "Plans and requirements", count: matches.count)) {
                    ForEach(matches) { match in
                        row(match, index: index)
                    }
                    if matches.isEmpty {
                        Text("None in \(index.repo) yet. A plan claude commits there shows here once the harness is fetched again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
        .contextMenu {
            if let url = index.url(for: document) {
                Link("Open on GitHub", destination: url)
            }
        }
    }
}

// MARK: - Settings

/// Settings › Harness: the org's harness (projects' are under Projects)
/// with its branch, the team data, its prompts and drafting, then where
/// every harness, projects' too, is checked out on this Mac.
struct HarnessSettingsSection: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    let org: String

    var body: some View {
        let config = configs.config(for: org)
        // Any left from before projects show until they're moved.
        let harnesses = (config.harness.map { [$0] } ?? []) + config.otherHarnesses
        // What's saved stays listed even before GitHub's lists load.
        let repos = Set(harness.repositories[org] ?? []).union(harnesses.map(\.repo))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        HarnessesSection(org: org, harnesses: harnesses, repos: repos)
            .task { await harness.loadRepositories(org: org) }
            .loadsHarness(org: org)
        if let teamHarness = harnesses.first {
            HarnessTeamSections(org: org, teamHarness: teamHarness, harnesses: harnesses)
            }
        }
        let checkouts = config.allHarnesses
        ForEach(checkouts, id: \.repo) { setup in
            HarnessCheckoutSection(org: org, repo: setup.repo, showsName: checkouts.count > 1, showsRecording: setup.repo == checkouts.first?.repo)
    }
}

/// The team's data, prompts and drafting settings.
struct HarnessTeamSections: View {
    let org: String
    let teamHarness: HarnessConfig
    let harnesses: [HarnessConfig]

    var body: some View {
        TeamDataSection(org: org, setup: teamHarness)
        ForEach(harnesses, id: \.repo) { setup in
            HarnessPromptsSection(org: org, setup: setup, showsName: harnesses.count > 1)
        }
        ForEach([org], id: \.self) { org in
            HarnessAuthoringSection(org: org)
        }
    }
}

/// The org's harness and its branch, or Add and Create while there's none.
/// Harnesses beside it from before projects list the repos they're for
/// and can keep the team's data, until they're moved into projects.
struct HarnessesSection: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessTeamStore.self) private var team
    let org: String
    let harnesses: [HarnessConfig]
    /// Every repo in the org, for picking from.
    let repos: [String]
    @State private var isCreating = false
    @State private var moving: HarnessConfig?
    @State private var isMoving = false
    @State private var moveError: String?

    var body: some View {
        Section {
            if harnesses.isEmpty {
                Text("A harness is a repo of plans, requirements, findings, skills and prompts beside the code, where Claude Code sessions run. Add one \(org) has, or create one.")
                    .foregroundStyle(.secondary)
            }
            ForEach(harnesses, id: \.repo) { setup in
                row(setup, keepsTeamData: setup.repo == harnesses.first?.repo)
            }
            if harnesses.isEmpty {
                HStack {
                    Menu("Add Harness") {
                        ForEach(repos.filter { repo in !harnesses.contains { $0.repo == repo } }, id: \.self) { repo in
                            Button(repo) {
                                configs.update(org) { $0.harness = HarnessConfig(repo: repo) }
                            }
                        }
                    }
                    .fixedSize()
                    Button("Create Harness") { isCreating = true }
                }
            }
            if let moveError {
                Text(moveError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text(harnesses.count > 1 ? "Harnesses" : "Harness")
        } footer: {
            Text("Work on an issue or PR runs in its project's harness, with that harness's prompts and skills, when a project with one names its repo; anything else runs here. A project gets its own harness in Projects.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $isCreating) { CreateHarnessSheet(org: org) }
        .confirmationDialog("Keep the team's data in \(moving?.repo ?? "")?", isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
            if let target = moving {
                if team.keepsData(org) {
                    Button("Copy and Keep It There") { move(to: target) }
                } else {
                    Button("Keep It There") { configs.update(org) { $0.keepTeamData(in: target.repo) } }
                }
            }
        } message: {
            Text(team.keepsData(org)
                 ? "Gannin commits a copy of .gannin/ from \(harnesses.first?.repo ?? "") to \(moving?.repo ?? "") and reads it from there. The old copy stays where it is until you remove it."
                 : "Moving the team's settings into a harness (below) puts them there from then on.")
        }
    }

    private func row(_ setup: HarnessConfig, keepsTeamData: Bool) -> some View {
        let covered = setup.repos ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(setup.repo, systemImage: "text.book.closed").fontWeight(.medium)
                if keepsTeamData && harnesses.count > 1 {
                    Text("Team data")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                        .help("The team's settings and people's dates are read from and committed to this harness")
                }
                Spacer()
                if harness.isLoading(org, setup) { ProgressView().controlSize(.small) }
                Menu {
                    if !keepsTeamData {
                        Button("Keep Team Data Here") { moving = setup }
                    }
                    Button("Remove Harness", role: .destructive) {
                        configs.update(org) { $0.removeHarness(setup.repo) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isMoving)
                .help("Remove it (nothing in it changes), or keep the team's data in it")
            }
            if let error = harness.error(org, setup) {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            branchPicker(setup)
            if harnesses.count > 1 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("For").foregroundStyle(.secondary)
                    if covered.isEmpty {
                        Text(harnesses.count > 1 ? "any repo the others don't name" : "every repo").foregroundStyle(.secondary)
                    }
                    ForEach(covered, id: \.self) { repo in
                        HStack(spacing: 2) {
                            Text(repo.split(separator: "/").last.map(String.init) ?? repo)
                            Button {
                                update(setup.repo) { $0.repos = covered.filter { $0 != repo } }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .help(repo)
                    }
                    Menu {
                        let projects = configs.baseConfig(for: org).repoProjects
                        if !projects.isEmpty {
                            Section("Projects") {
                                ForEach(projects) { project in
                                    Button(project.name) { update(setup.repo) { $0.repos = Array(Set(covered + project.repos)).sorted() } }
                                }
                            }
                        }
                        Section("Repositories") {
                            ForEach(repos.filter { !covered.contains($0) && !harnesses.map(\.repo).contains($0) }, id: \.self) { repo in
                                Button(repo) { update(setup.repo) { $0.repos = covered + [repo] } }
                            }
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Keep this harness for a repo")
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 2)
    }

    private func branchPicker(_ setup: HarnessConfig) -> some View {
        let branches = harness.branches[setup.repo]
        // The default is Default's, so it isn't listed again.
        let listed = Set(branches?.all ?? []).union(setup.branch.map { [$0] } ?? [])
            .subtracting(branches?.defaultBranch.map { [$0] } ?? [])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return LabeledContent("Branch") {
            SearchablePicker(
                choices: [SearchableChoice(value: nil, title: branches?.defaultBranch.map { "Default (\($0))" } ?? "Default")]
                    + listed.map { SearchableChoice(value: $0, title: $0) },
                selection: setup.branch,
                prompt: "Search branches",
                isLoading: branches == nil
            ) { branch in
                update(setup.repo) { $0.branch = branch }
            }
        }
        .task(id: setup.repo) { await harness.loadBranches(repo: setup.repo) }
    }

    private func update(_ repo: String, _ change: (inout HarnessConfig) -> Void) {
        configs.update(org) { $0.updateHarness(repo, change) }
    }

    private func move(to target: HarnessConfig) {
        isMoving = true
        moveError = nil
        Task {
            do {
                try await team.moveData(org: org, to: target)
                configs.update(org) { $0.keepTeamData(in: target.repo) }
            } catch {
                moveError = "Couldn't copy the team's data: \(error.localizedDescription)"
            }
            isMoving = false
        }
    }
}
