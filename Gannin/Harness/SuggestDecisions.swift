import SwiftUI

/// Suggest Decisions: Claude reads a harness's plans, an area at a time
/// and a batch at a time, skipping those a decision already cites, and
/// proposes the decisions worth keeping as ADRs, each naming the plan it
/// came from. Nothing's written until the ticked ones are committed, one
/// file each, in one commit.
enum DecisionSuggestions {
    /// Plans a batch, so one `claude -p` reads a handful rather than all.
    static let batchSize = 5
    /// Of each plan, at most, so a long one can't crowd out the rest.
    static let planLimit = 30_000

    /// A plan's areas, as the Onboarding map has them, so the area picked
    /// here is the one it's listed under there.
    static func areas(of document: HarnessDocument) -> [String] {
        OnboardingMap.areas(of: document)
    }

    static let other = OnboardingMap.other

    /// Every area the standard plans fall under, by name, Other last.
    static func areas(_ index: HarnessIndex) -> [String] {
        let names = Set(index.documents(.plans).filter(\.followsStandard).flatMap(areas(of:)))
        return names.sorted { ($0 == other ? 1 : 0, $0) < ($1 == other ? 1 : 0, $1) }
    }

    /// The area's standard plans (every area's for nil) that no decision
    /// cites in its `plans`, newest first.
    static func uncitedPlans(_ index: HarnessIndex, area: String?) -> [HarnessDocument] {
        let cited = Set(index.documents(.decisions).flatMap { decision in decision.citedPlans.map { index.resolve($0, from: decision) } })
        return index.documents(.plans)
            .filter { $0.followsStandard && !cited.contains($0.path) }
            .filter { area == nil || areas(of: $0).contains(area!) }
            .sorted { ($0.date ?? .distantPast, $0.path) > ($1.date ?? .distantPast, $1.path) }
    }

    static func batches(_ plans: [HarnessDocument]) -> [[HarnessDocument]] {
        stride(from: 0, to: plans.count, by: batchSize).map { Array(plans[$0..<min($0 + batchSize, plans.count)]) }
    }

    /// The plans, as files beside the prompt at their own paths.
    static func files(_ batch: [HarnessDocument]) -> [String: Data] {
        Dictionary(batch.map { ($0.path, Data(String($0.text.prefix(planLimit)).utf8)) }, uniquingKeysWith: { first, _ in first })
    }

    static func prompt(_ batch: [HarnessDocument], existing: [HarnessDocument]) -> String {
        var parts = [
            """
            These are plans from our team's harness repo: \(batch.map { "`\($0.path)`" }.joined(separator: ", ")). They're in this folder at the same paths. Read each one.

            Find the decisions in them worth keeping as decision records (ADRs): a real choice between alternatives, with reasons, that someone new to the code would want to understand and that will still matter after the work ships. Leave out task lists, details of how something was built, and choices with no alternatives or reasons. A plan may hold none, one or a few. Use the plans' own reasons and the alternatives they name; don't invent any. Where the plan doesn't say why, leave it out rather than guess.
            """,
        ]
        if !existing.isEmpty {
            let list = existing.prefix(80).map { "- \($0.title) (`\($0.path)`)\($0.summary.map { ": \($0)" } ?? "")" }
            parts.append("Decisions already in the harness, not to repeat:\n\n\(list.joined(separator: "\n"))")
        }
        parts.append(#"""
            Reply with only JSON, no preamble: {"decisions": [{"title": "the decision as a short statement", "summary": "the decision in a sentence or two", "plan": "the path of the plan it came from", "domains": ["..."], "context": "Markdown", "decision": "Markdown", "alternatives": "Markdown, a bullet per alternative and why it lost", "consequences": "Markdown"}]}. An empty list is fine.
            """#)
        return parts.joined(separator: "\n\n")
    }

    struct Reply: Decodable {
        struct Item: Decodable {
            let title: String
            let summary: String?
            let plan: String?
            let domains: [String]?
            let context: String?
            let decision: String?
            let alternatives: String?
            let consequences: String?
        }
        let decisions: [Item]
    }

    /// A suggestion as it's edited, then written.
    struct Draft: Identifiable {
        let id = UUID()
        var include = true
        var title: String
        var summary: String
        /// The plan it came from, by path; empty when Claude named none of
        /// the batch's, for the person to pick or commit it uncited.
        var plan: String
        /// The batch's plans, which it can be said to come from.
        let choices: [String]
        var domains: String
        var body: String

        init(_ item: Reply.Item, batch: [HarnessDocument]) {
            let source = item.plan.flatMap { DecisionSuggestions.plan(named: $0, in: batch) }
            choices = batch.map(\.path)
            title = item.title
            summary = item.summary ?? ""
            plan = source?.path ?? ""
            domains = (item.domains ?? source?.domains ?? []).joined(separator: ", ")
            body = [
                ("Context", item.context), ("Decision", item.decision), ("Alternatives considered", item.alternatives), ("Consequences", item.consequences),
            ]
            .map { "## \($0.0)\n\n\(($0.1 ?? "").trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
        }

        var document: HarnessDocumentDraft {
            var draft = HarnessDocumentDraft(kind: .decisions)
            draft.title = title.trimmingCharacters(in: .whitespaces)
            draft.status = "proposed"
            draft.summary = summary
            draft.domains = domains.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            draft.plans = plan.isEmpty ? [] : [plan]
            draft.body = body
            return draft
        }
    }

    /// The batch's plan Claude named: by its path (from the harness root,
    /// with or without `./` or `/`), else by its file name when only one
    /// has it. Nil for none, rather than guessing: a decision citing the
    /// wrong plan would hide that plan from every later suggestion.
    static func plan(named name: String, in batch: [HarnessDocument]) -> HarnessDocument? {
        var path = name.trimmingCharacters(in: .whitespaces)
        while path.hasPrefix("./") || path.hasPrefix("/") { path.removeFirst(path.hasPrefix("./") ? 2 : 1) }
        if let exact = batch.first(where: { $0.path == path }) { return exact }
        let file = path.split(separator: "/").last.map(String.init) ?? path
        let named = batch.filter { $0.fileName == file }
        return named.count == 1 ? named[0] : nil
    }

    /// The ticked drafts as files, `decisions/<today>-<slug>.md`, each name
    /// unused in the harness and among themselves.
    static func files(for drafts: [Draft], index: HarnessIndex?, today: String = HarnessAuthoring.today) -> [String: String?] {
        var files: [String: String?] = [:]
        for draft in drafts where draft.include && !draft.title.trimmingCharacters(in: .whitespaces).isEmpty {
            let stem = "decisions/\(today)-\(HarnessDocumentDraft.slug(draft.title))"
            var path = "\(stem).md"
            var number = 2
            while files[path] != nil || index?.document(at: path) != nil {
                path = "\(stem)-\(number).md"
                number += 1
            }
            files[path] = draft.document.fileText
        }
        return files
    }
}

/// The sheet: pick an area (or All), Claude reads its uncited plans a
/// batch at a time, and each decision it proposes is yours to edit, untick
/// or keep; Commit writes the ticked ones to the harness in one commit,
/// confirmed first.
struct SuggestDecisionsSheet: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(\.dismiss) private var dismiss
    let org: String
    let setup: HarnessConfig

    /// Nil for every area.
    @State private var area: String?
    @State private var drafts: [DecisionSuggestions.Draft] = []
    @State private var running: Task<Void, Never>?
    /// Stop was pressed: Claude can't be interrupted mid-batch, so it ends
    /// once the batch it's reading is done.
    @State private var stopping = false
    @State private var progress: (done: Int, of: Int)?
    @State private var status: String?
    @State private var confirming = false
    @State private var saving = false
    @State private var error: String?

    private var index: HarnessIndex? { harness.index(for: org, setup) }
    private var ticked: Int { drafts.filter { $0.include && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }.count }

    var body: some View {
        let plans = index.map { DecisionSuggestions.uncitedPlans($0, area: area) } ?? []
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Suggest Decisions").font(.headline)
                Spacer()
                Picker("Area", selection: $area) {
                    Text("All").tag(String?.none)
                    Divider()
                    ForEach(index.map { DecisionSuggestions.areas($0) } ?? [], id: \.self) { Text(HarnessView.prettify($0)).tag(Optional($0)) }
                }
                .fixedSize()
                .disabled(running != nil)
                if running != nil {
                    if let progress { Text("Batch \(min(progress.done + 1, progress.of)) of \(progress.of)").foregroundStyle(.secondary).monospacedDigit() }
                    ProgressView().controlSize(.small)
                    if stopping {
                        Text("Stopping after this batch").foregroundStyle(.secondary)
                    }
                    Button("Stop") {
                        stopping = true
                        running?.cancel()
                    }
                    .disabled(stopping)
                    .help("Stop once the batch Claude is reading is done")
                } else {
                    Button(drafts.isEmpty ? "Read \(plans.count) Plans" : "Read Again") { start(plans) }
                        .disabled(plans.isEmpty)
                        .help("Claude reads the plans no decision cites yet, \(DecisionSuggestions.batchSize) at a time")
                }
            }
            .padding(12)
            Divider()
            Form {
                if drafts.isEmpty {
                    Section {
                        Text(running != nil ? "Claude is reading the plans. Decisions show here as each batch is read."
                             : plans.isEmpty ? "Every plan here is already cited by a decision, or there are none in this area."
                             : "Pick an area, or All, and Claude reads its \(plans.count) plans not cited by a decision, proposing the decisions worth keeping. You review each one; nothing's committed until you say so.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("\(ticked) of \(drafts.count) decisions") {
                        ForEach($drafts) { $draft in editor($draft) }
                    }
                }
                if let status {
                    Text(status).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") {
                    running?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(saving ? "Committing" : "Commit \(ticked) Decisions") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || running != nil || ticked == 0)
            }
            .padding(12)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 600, idealHeight: 760)
        .onDisappear { running?.cancel() }
        .confirmationDialog("Commit \(ticked) decisions to \(setup.repo)?", isPresented: $confirming) {
            Button("Commit to Harness") { commit() }
        } message: {
            Text("Each is its own file under decisions/, marked proposed, in one commit.")
        }
    }

    private func editor(_ draft: Binding<DecisionSuggestions.Draft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: draft.include).labelsHidden().checkboxToggle()
                TextField("Title", text: draft.title).fontWeight(.medium)
            }
            TextField("Summary", text: draft.summary, axis: .vertical)
                .lineLimit(1...3)
            TextField("Decision", text: draft.body, axis: .vertical)
                .lineLimit(3...12)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            HStack {
                TextField("Domains", text: draft.domains).font(.caption)
                Picker("From", selection: draft.plan) {
                    Text("Plan not named").tag("")
                    ForEach(draft.wrappedValue.choices, id: \.self) { path in
                        Text(index?.document(at: path)?.title ?? path).tag(path)
                    }
                }
                .font(.caption)
                .fixedSize()
                .foregroundStyle(draft.wrappedValue.plan.isEmpty ? .orange : .secondary)
                .help(draft.wrappedValue.plan.isEmpty ? "Claude didn't name one of the plans it read: pick it, or leave it to commit the decision citing none" : draft.wrappedValue.plan)
            }
        }
        .opacity(draft.wrappedValue.include ? 1 : 0.5)
    }

    private func start(_ plans: [HarnessDocument]) {
        guard let index else { return }
        let batches = DecisionSuggestions.batches(plans)
        let existing = index.documents(.decisions).filter(\.followsStandard)
        drafts = []
        status = nil
        error = nil
        progress = (0, batches.count)
        stopping = false
        running = Task {
            var failed = 0
            for (number, batch) in batches.enumerated() {
                if Task.isCancelled { break }
                progress = (number, batches.count)
                do {
                    let reply = try await AgentProviders.asking.ask(
                        DecisionSuggestions.prompt(batch, existing: existing), org: org,
                        files: DecisionSuggestions.files(batch), tools: ["Read", "Glob", "Grep"]
                    )
                    if let parsed = ScriptRunner.json(DecisionSuggestions.Reply.self, in: reply) {
                        drafts += parsed.decisions.map { DecisionSuggestions.Draft($0, batch: batch) }
                    } else {
                        failed += 1
                    }
                } catch {
                    if Task.isCancelled { break }
                    failed += 1
                }
            }
            let read = Task.isCancelled ? "Stopped. " : ""
            status = read + (drafts.isEmpty ? "No decisions worth keeping were found." : "Proposed \(drafts.count). Untick any not worth keeping, and edit the rest.")
                + (failed > 0 ? " \(failed) of \(batches.count) batches couldn't be read." : "")
            progress = nil
            stopping = false
            running = nil
        }
    }

    private func commit() {
        let files = DecisionSuggestions.files(for: drafts, index: index)
        guard !files.isEmpty else { return }
        let change = HarnessChange(message: "Gannin: add \(files.count == 1 ? "a decision" : "\(files.count) decisions") suggested from plans", files: files)
        HarnessCommitting.commit(harness, org: org, setup: setup, change, saving: $saving, error: $error, dismiss: dismiss)
    }
}
