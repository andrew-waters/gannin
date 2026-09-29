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
    @SceneStorage("harnessKind") private var kind: HarnessKind = .plans
    @State private var unlinkedOnly = false
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
                    systemImage: "books.vertical",
                    description: Text("Name the repo the org keeps its plans and requirements in, in Settings.")
                )
            }
        }
        .toolbar {
            if let setup {
                ToolbarItem {
                    Picker("Kind", selection: $kind) {
                        ForEach(HarnessKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
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
            let documents = index.documents(kind).filter { !(linkable && unlinkedOnly) || $0.subjects.isEmpty }
            List {
                if let error = harness.errors[org] {
                    Banner(message: "Refresh failed: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                        Task { await harness.load(org: org, setup: setup, force: true) }
                    }
                }
                if documents.isEmpty {
                    Text(unlinkedOnly ? "Every one names an issue." : "No \(kind.rawValue.lowercased()) in \(repo).")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups(documents), id: \.title) { group in
                    Section(header: SectionHeader(title: group.title, count: group.documents.count)) {
                        ForEach(group.documents) { document in
                            row(document, index: index, lookup: lookup, linkable: linkable)
                        }
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
                Label("Not indexed yet", systemImage: "books.vertical")
            } actions: {
                Button("Index Now") { Task { await harness.load(org: org, setup: setup, force: true) } }
            }
        }
    }

    /// Plans and requirements by module, skills by folder, findings newest
    /// first; the newest first within each.
    private func groups(_ documents: [HarnessDocument]) -> [(title: String, documents: [HarnessDocument])] {
        let newestFirst: (HarnessDocument, HarnessDocument) -> Bool = { a, b in
            if a.date != b.date { return (a.date ?? .distantPast) > (b.date ?? .distantPast) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        let grouped = Dictionary(grouping: documents) { document -> String in
            switch document.kind {
            case .plans, .requirements: return document.module.map(Self.prettify) ?? "Other"
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
                if let status = document.status {
                    Pill(text: status, color: .secondary)
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
struct HarnessDocumentPage: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var issueStore
    let org: String
    let path: String

    var body: some View {
        let setup = configs.config(for: org).harness
        Group {
            if let setup, let index = harness.index(for: org, setup), let document = index.document(at: path) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(document, index: index)
                        if !document.references.isEmpty {
                            HarnessIssueList(org: org, index: index, references: document.references, lookup: IssueLookup(history: issueStore.history(for: org)))
                        }
                        Divider()
                        MarkdownText(source: document.body)
                    }
                    .padding(20)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Not in the harness", systemImage: "doc.questionmark", description: Text("\(path) isn't in the harness as last fetched."))
            }
        }
        .loadsHarness(org: org)
    }

    private func header(_ document: HarnessDocument, index: HarnessIndex) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(document.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Label(document.kind.singular.capitalized, systemImage: document.kind.systemImage)
                    .foregroundStyle(.secondary)
                if let status = document.status { Pill(text: status, color: .secondary) }
                if let date = document.date {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                }
                if document.tasks > 0 {
                    ProgressView(value: Double(document.tasksDone), total: Double(document.tasks))
                        .frame(width: 80)
                    Text(verbatim: "\(document.tasksDone) of \(document.tasks) tasks")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if let url = index.url(for: document) {
                    Link(destination: url) {
                        Label("Open on GitHub", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .font(.callout)
            Text(document.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// The issues a document is about, then those it mentions; each opens its
/// page where Gannin has it, else GitHub.
private struct HarnessIssueList: View {
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    let org: String
    let index: HarnessIndex
    let references: [HarnessReference]
    let lookup: IssueLookup

    var body: some View {
        let subjects = references.filter(\.isSubject)
        let mentions = references.filter { !$0.isSubject }
        VStack(alignment: .leading, spacing: 10) {
            if !subjects.isEmpty { group("About", subjects) }
            if !mentions.isEmpty { group("Mentions", mentions) }
        }
    }

    private func group(_ title: String, _ references: [HarnessReference]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(references, id: \.self) { reference in
                let repo = index.repo(of: reference)
                let record = lookup.record(repo: repo, number: reference.number)
                Button {
                    open(record: record, repo: repo, number: reference.number)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(record.map(IssueStateDot.color) ?? .secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text(verbatim: repo == index.issuesRepo ? "#\(reference.number)" : "\(repo ?? "")#\(reference.number)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(record?.title ?? "Not in Gannin's issue history")
                            .foregroundStyle(record == nil ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

/// Settings: the org's harness repo and branch, picked from GitHub's, and
/// what was found there.
struct HarnessSettingsSection: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    let org: String

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
                status(saved)
            }
            Text("Plans are Markdown under requirements/<module>/plans/, requirements the rest of requirements/, then findings/ and skills/. A document is about an issue named in its file name (prd-123) or its header table's GitHub row (owner/name#123); others it names are mentions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Harness")
        }
        .task { await harness.loadRepositories(org: org) }
        .loadsHarness(org: org)
    }

    @ViewBuilder
    private func status(_ setup: HarnessConfig) -> some View {
        if let index = harness.index(for: org, setup) {
            let linked = index.documents.filter { ($0.kind == .plans || $0.kind == .requirements) && !$0.subjects.isEmpty }.count
            let linkable = index.documents.filter { $0.kind == .plans || $0.kind == .requirements }.count
            Text("\(index.documents(.plans).count) plans, \(index.documents(.requirements).count) requirements, \(index.documents(.findings).count) findings and \(index.documents(.skills).count) skills on \(index.branch). \(linked) of \(linkable) plans and requirements name an issue.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let error = harness.errors[org] {
            Text(error).font(.caption).foregroundStyle(.red)
        } else if harness.loading.contains(org) {
            Text("Indexing \(setup.repo)").font(.caption).foregroundStyle(.secondary)
        }
    }
}
