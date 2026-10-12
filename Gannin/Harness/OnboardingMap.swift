import SwiftUI

/// Harness › Onboarding: the window's project's decisions, requirements and
/// plans that follow the standard, mapped by area, so someone new starts
/// with the part they'll work on and reads why it is the way it is.
struct OnboardingMap {
    struct Area: Identifiable {
        let name: String
        /// In reading order: key ones, decisions in force, requirements,
        /// then plans, each newest first.
        let documents: [HarnessDocument]
        /// Superseded and rejected decisions, folded away.
        let older: [HarnessDocument]

        var id: String { name }
        var all: [HarnessDocument] { documents + older }
    }

    static let kinds: [HarnessKind] = [.decisions, .requirements, .plans]
    static let other = "Other"

    let areas: [Area]

    init(_ index: HarnessIndex) {
        let documents = index.documents.filter { Self.kinds.contains($0.kind) && $0.followsStandard }
        var byArea: [String: [HarnessDocument]] = [:]
        // Under every domain it names, so reading it once ticks it everywhere.
        for document in documents {
            for area in Self.areas(of: document) { byArea[area, default: []].append(document) }
        }
        areas = byArea
            .map { name, documents in
                Area(
                    name: name,
                    documents: documents.filter { !$0.isRetiredDecision }.sorted(by: Self.readingOrder),
                    older: documents.filter(\.isRetiredDecision).sorted(by: Self.newestFirst)
                )
            }
            .sorted { ($0.name == Self.other ? 1 : 0, $0.name.lowercased()) < ($1.name == Self.other ? 1 : 0, $1.name.lowercased()) }
    }

    /// Its domains, else its module folder, else Other.
    static func areas(of document: HarnessDocument) -> [String] {
        var domains: [String] = []
        for domain in document.domains ?? [] {
            let name = domain.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !domains.contains(name) { domains.append(name) }
        }
        if !domains.isEmpty { return domains }
        return [document.module ?? other]
    }

    /// Key first, then decisions, requirements and plans.
    static func rank(_ document: HarnessDocument) -> Int {
        if document.isKey { return 0 }
        switch document.kind {
        case .decisions: return 1
        case .requirements: return 2
        default: return 3
        }
    }

    static func readingOrder(_ a: HarnessDocument, _ b: HarnessDocument) -> Bool {
        let (left, right) = (rank(a), rank(b))
        return left != right ? left < right : newestFirst(a, b)
    }

    /// By the date in its file name, undated last, then by title.
    static func newestFirst(_ a: HarnessDocument, _ b: HarnessDocument) -> Bool {
        if a.date != b.date { return (a.date ?? .distantPast) > (b.date ?? .distantPast) }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    /// The areas whose name, or a document's title or summary, has every
    /// word typed; a matching area keeps all its documents.
    func filtered(_ search: String) -> [Area] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return areas }
        func has(_ text: String) -> Bool { words.allSatisfy { text.localizedCaseInsensitiveContains($0) } }
        return areas.compactMap { area in
            if has(area.name) || has(HarnessView.prettify(area.name)) { return area }
            let keep: (HarnessDocument) -> Bool = { has("\($0.title) \($0.summary ?? "")") }
            let documents = area.documents.filter(keep), older = area.older.filter(keep)
            return documents.isEmpty && older.isEmpty ? nil : Area(name: area.name, documents: documents, older: older)
        }
    }
}

/// The map: an area a section, its documents in reading order, each
/// opening in the drawer.
struct OnboardingView: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.navigate) private var navigate
    let org: String

    private let reads = HarnessReadMarks.shared
    @State private var search = ""
    /// Areas folded, by name.
    @State private var folded: Set<String> = []
    /// Areas with their Older open, by name.
    @State private var olderOpen: Set<String> = []

    var body: some View {
        let harnesses = configs.config(for: org).harnesses
        Group {
            if let setup = harnesses.first {
                if let index = harness.combined(org: org, harnesses) {
                    content(OnboardingMap(index), index: index)
                } else if let error = harness.error(org, setup) {
                    ContentUnavailableView {
                        Label("Couldn't read \(setup.repo)", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await harness.load(org: org, setup: setup, force: true) } }
                    }
                } else {
                    ProgressView("Indexing \(setup.repo)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("No harness", systemImage: "text.book.closed", description: Text("Onboarding maps the project's harness, which it doesn't have yet."))
            }
        }
        .loadsHarness(org: org)
    }

    @ViewBuilder
    private func content(_ map: OnboardingMap, index: HarnessIndex) -> some View {
        let areas = map.filtered(search)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FilterSearchField(text: $search, prompt: "Area, title or summary")
                Spacer(minLength: 0)
                if !map.areas.isEmpty {
                    Button(folded.isEmpty ? "Fold All" : "Open All") {
                        withAnimation(.snappy(duration: 0.2)) { folded = folded.isEmpty ? Set(map.areas.map(\.name)) : [] }
                    }
                    .linkButton()
                }
            }
            .controlSize(.small)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if map.areas.isEmpty {
                ContentUnavailableView(
                    "Nothing to read yet",
                    systemImage: "map",
                    description: Text("Decisions, requirements and plans with front matter and a summary show here, by the domains they name.")
                )
            } else if areas.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(areas) { area in
                            section(area, index: index)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func section(_ area: OnboardingMap.Area, index: HarnessIndex) -> some View {
        let isFolded = folded.contains(area.name)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if isFolded { folded.remove(area.name) } else { folded.insert(area.name) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                    Text(area.name == OnboardingMap.other ? area.name : HarnessView.prettify(area.name))
                        .font(.title3.weight(.semibold))
                    let read = reads.readCount(area.all, primary: index.repo)
                    Text(verbatim: "\(read) of \(area.all.count) read")
                        .foregroundStyle(read == area.all.count ? AnyShapeStyle(ChartPalette.good) : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                        .help("Read on this Mac; marks never leave it")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFolded ? "Open this area" : "Fold this area")
            if !isFolded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(area.documents) { document in
                        row(document, index: index)
                        Divider()
                    }
                    if !area.older.isEmpty {
                        DisclosureGroup(isExpanded: Binding(
                            get: { olderOpen.contains(area.name) },
                            set: { if $0 { olderOpen.insert(area.name) } else { olderOpen.remove(area.name) } }
                        )) {
                            ForEach(area.older) { document in
                                row(document, index: index)
                                Divider()
                            }
                        } label: {
                            Text("Older: \(area.older.count) superseded or rejected")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    /// The document, opening in the drawer, and for a superseded decision
    /// a link to what replaced it.
    private func row(_ document: HarnessDocument, index: HarnessIndex) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            documentButton(document, index: index)
            if let next = document.supersededBy {
                let path = index.resolve(next, from: document)
                Button("Superseded by \(index.document(at: path)?.title ?? next)") {
                    if let successor = index.document(at: path) { reads.markRead(successor, primary: index.repo) }
                    navigate?(.harnessDocument(path))
                }
                .linkButton()
                .font(.caption)
                .padding(.leading, 28)
                .padding(.bottom, 8)
            }
        }
    }

    private func documentButton(_ document: HarnessDocument, index: HarnessIndex) -> some View {
        let state = reads.state(of: document, primary: index.repo)
        return Button {
            reads.markRead(document, primary: index.repo)
            navigate?(.harnessDocument(document.path))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: document.kind.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .help(document.kind.singular.capitalized)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if document.isKey {
                            Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption).help("Key to this area")
                        }
                        Text(document.title).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if let summary = document.summary {
                        Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if state == .updated {
                        Label("Updated since you read it", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: state == .unread ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(state == .unread ? AnyShapeStyle(.tertiary) : AnyShapeStyle(ChartPalette.good))
                    .help(state == .unread ? "Not read yet" : "Read on this Mac")
                    .accessibilityLabel(state == .unread ? "Not read" : state == .read ? "Read" : "Updated since read")
                if let status = document.shortStatus {
                    Pill(text: status, color: .secondary).lineLimit(1)
                }
                Text(document.date?.formatted(date: .abbreviated, time: .omitted) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 90, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(document.path)
    }
}

/// What's been read on the Onboarding map, on this Mac only: per harness
/// repo, each document's path with the blob SHA it had when opened, so a
/// changed one shows as updated rather than going back to unread. Never
/// committed or sent anywhere.
@Observable
final class HarnessReadMarks {
    static let shared = HarnessReadMarks()

    enum State: Equatable {
        case unread
        case read
        /// Read, but its file has changed since.
        case updated
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// By harness repo, then path, the SHA when read; read from defaults
    /// as each repo is first asked about, which mustn't count as a change
    /// while a view is drawing.
    @ObservationIgnored private var marks: [String: [String: String]] = [:]
    /// Bumped on each mark, so views reading any of them redraw.
    private var version = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func key(_ repo: String) -> String { "harnessReadMarks.\(repo)" }

    /// The harness and its own path, for a document in a combined index
    /// whose primary harness is `primary`.
    private func place(_ document: HarnessDocument, primary: String) -> (repo: String, path: String) {
        let (repo, path) = HarnessIndex.split(document.path)
        return (repo ?? primary, path)
    }

    private func marks(for repo: String) -> [String: String] {
        _ = version
        if let loaded = marks[repo] { return loaded }
        let stored = defaults.dictionary(forKey: Self.key(repo)) as? [String: String] ?? [:]
        marks[repo] = stored
        return stored
    }

    func state(of document: HarnessDocument, primary: String) -> State {
        let (repo, path) = place(document, primary: primary)
        guard let sha = marks(for: repo)[path] else { return .unread }
        return sha == document.sha ? .read : .updated
    }

    func markRead(_ document: HarnessDocument, primary: String) {
        let (repo, path) = place(document, primary: primary)
        var repoMarks = marks(for: repo)
        guard repoMarks[path] != document.sha else { return }
        repoMarks[path] = document.sha
        marks[repo] = repoMarks
        defaults.set(repoMarks, forKey: Self.key(repo))
        version += 1
    }

    /// How many of the documents are read, changed since or not.
    func readCount(_ documents: [HarnessDocument], primary: String) -> Int {
        documents.count(where: { state(of: $0, primary: primary) != .unread })
    }
}
