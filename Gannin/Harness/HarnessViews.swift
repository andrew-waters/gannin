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
struct HarnessDocumentPage: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var issueStore
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    let org: String
    let path: String
    @State private var width: CGFloat = 1000

    var body: some View {
        let setup = configs.config(for: org).harness
        Group {
            if let setup, let index = harness.index(for: org, setup), let document = index.document(at: path) {
                let lookup = IssueLookup(history: issueStore.history(for: org))
                ScrollView {
                    // The details beside the text when there's room, above it when not.
                    if width >= 980 {
                        HStack(alignment: .top, spacing: 32) {
                            text(document, index: index)
                                .frame(maxWidth: 760, alignment: .leading)
                            details(document, index: index, lookup: lookup)
                                .frame(width: 280, alignment: .leading)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            heading(document)
                            details(document, index: index, lookup: lookup)
                            Divider()
                            MarkdownText(source: document.linkedBody(issuesRepo: index.issuesRepo), reflows: true)
                        }
                        .padding(20)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .environment(\.openURL, OpenURLAction { url in open(url, document: document, index: index, lookup: lookup) })
            } else {
                ContentUnavailableView("Not in the harness", systemImage: "doc.questionmark", description: Text("\(path) isn't in the harness as last fetched."))
            }
        }
        .loadsHarness(org: org)
    }

    /// Kind, title and summary, then the document.
    private func text(_ document: HarnessDocument, index: HarnessIndex) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(document)
            Divider()
            MarkdownText(source: document.linkedBody(issuesRepo: index.issuesRepo), reflows: true)
        }
    }

    private func heading(_ document: HarnessDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(document.kind.singular.capitalized, systemImage: document.kind.systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(document.title)
                .font(.title.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let summary = document.summary {
                Text(summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// As GitHub's column beside an issue: status and progress, the issues
    /// it's about and mentions, what it depends on, and where it lives.
    private func details(_ document: HarnessDocument, index: HarnessIndex, lookup: IssueLookup) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            detail("Status") {
                HStack(spacing: 8) {
                    Pill(text: document.statusLabel ?? "No status", color: .secondary)
                        .help(document.status ?? "No status")
                    if let date = document.date {
                        Text(date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                    }
                }
                if document.tasks > 0 {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(document.tasksDone), total: Double(document.tasks))
                        Text(verbatim: "\(document.tasksDone) of \(document.tasks)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            let subjects = document.references.filter(\.isSubject)
            let mentions = document.references.filter { !$0.isSubject }
            if !subjects.isEmpty {
                detail("Issues") { HarnessIssueList(org: org, index: index, references: subjects, lookup: lookup) }
            }
            if let requirement = document.requirement {
                detail("Requirement") { documentLink(requirement, index: index) }
            }
            if let dependsOn = document.dependsOn, !dependsOn.isEmpty {
                detail("Depends on") {
                    ForEach(dependsOn, id: \.self) { item in
                        if item.hasSuffix(".md") {
                            documentLink(item, index: index)
                        } else {
                            HarnessIssueList(org: org, index: index, references: HarnessDocument.references(in: item, isSubject: false), lookup: lookup)
                        }
                    }
                }
            }
            if let branch = document.branch {
                detail("Branch") {
                    Text(branch).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            if let owner = document.owner {
                detail("Owner") { Text("@\(owner)") }
            }
            if let domains = document.domains, !domains.isEmpty {
                detail("Domains") {
                    FlowChips(items: domains.map(HarnessView.prettify))
                }
            }
            if let touches = document.touches, !touches.isEmpty {
                detail("Touches") {
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
                detail("Mentions") { HarnessIssueList(org: org, index: index, references: mentions, lookup: lookup) }
            }
            detail("File") {
                Text(document.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = index.url(for: document) {
                    Link(destination: url) {
                        Label("Open on GitHub", systemImage: "arrow.up.right.square")
                    }
                    .font(.callout)
                }
                if !document.followsStandard {
                    Text("Written before the harness's STANDARDS.md, so it has no front matter yet.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
    }

    private func detail(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Another harness document by path, opening in a drawer over this one.
    @ViewBuilder
    private func documentLink(_ path: String, index: HarnessIndex) -> some View {
        if let target = index.document(at: path) {
            Button {
                navigate?(.harnessDocument(target.path))
            } label: {
                Label(target.title, systemImage: target.kind.systemImage)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
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

/// Short labels wrapped onto as many lines as they need.
private struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.7), in: Capsule())
            }
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
