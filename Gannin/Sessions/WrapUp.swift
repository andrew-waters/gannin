import Foundation
import SwiftUI

/// The `- [ ]` items of a plan or requirement, read and ticked by their
/// words rather than their line, so a tick lands on the file as it is at
/// the head even when lines have moved since it was read.
nonisolated enum HarnessChecklist {
    struct Item: Identifiable, Hashable, Sendable {
        /// The words after the box.
        let text: String
        /// How many items before it read the same, so each of two alike is
        /// still itself.
        let occurrence: Int
        let isDone: Bool
        /// Leading spaces, for nested items.
        let indent: Int

        var id: String { "\(occurrence):\(text)" }
    }

    private static let box = try! NSRegularExpression(pattern: #"^(\s*[-*+]\s+\[)([ xX])\](.*)$"#, options: .dotMatchesLineSeparators)

    static func items(in text: String) -> [Item] {
        boxes(in: text.components(separatedBy: "\n")).map(\.item)
    }

    /// The text with the items named (by `Item.id`) ticked or not. Items it
    /// doesn't find are left alone, as is everything else.
    static func setting(_ done: [String: Bool], in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for (index, item) in boxes(in: lines) {
            guard let tick = done[item.id], tick != item.isDone else { continue }
            let line = lines[index] as NSString
            guard let match = box.firstMatch(in: lines[index], range: NSRange(location: 0, length: line.length)) else { continue }
            lines[index] = line.replacingCharacters(in: match.range(at: 2), with: tick ? "x" : " ")
        }
        return lines.joined(separator: "\n")
    }

    /// Each item and its line, outside front matter and fenced code.
    private static func boxes(in lines: [String]) -> [(line: Int, item: Item)] {
        var found: [(line: Int, item: Item)] = []
        var seen: [String: Int] = [:]
        var inFrontMatter = lines.first == "---"
        var inFence = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inFrontMatter {
                if index > 0, trimmed == "---" { inFrontMatter = false }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            let text = line as NSString
            guard let match = box.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else { continue }
            let words = text.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { continue }
            let occurrence = seen[words, default: 0]
            seen[words] = occurrence + 1
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            found.append((line: index, item: Item(text: words, occurrence: occurrence, isDone: text.substring(with: match.range(at: 2)) != " ", indent: indent)))
        }
        return found
    }
}

extension SessionStore {
    /// Settings > General > Agent: ask to wrap a session up when its tab is
    /// closed.
    static let wrapUpKey = "sessionsWrapUpOnClose"

    static var wrapsUpOnClose: Bool {
        UserDefaults.standard.object(forKey: wrapUpKey) as? Bool ?? true
    }

    /// The sessions whose tab asks first: an issue's own, or a quick
    /// change's. Reviews, plans and Asks have their own ways to finish.
    static func offersWrapUp(_ session: CodeSession) -> Bool { session.canPairReview }

    /// Claude, or one of its helpers, is still running.
    func isRunningWithHelpers(_ id: UUID) -> Bool {
        isRunning(id) || helpers(of: id).contains { isRunning($0.id) }
    }

    func asksToWrapUp(_ id: UUID) -> Bool {
        guard Self.wrapsUpOnClose, let session = sessions[id], Self.offersWrapUp(session) else { return false }
        return isRunningWithHelpers(id)
    }

    /// Closes the tab, or asks first whether to wrap the session up. True
    /// when it's closed now.
    @discardableResult
    func requestClose(_ id: UUID) -> Bool {
        guard asksToWrapUp(id) else {
            closeTab(id)
            return true
        }
        wrappingUp = id
        return false
    }

    /// Ends claude and its helpers and closes the tab. The worktrees stay,
    /// and opening the session again resumes it.
    func endAndClose(_ id: UUID) {
        for helper in helpers(of: id) { end(helper.id) }
        end(id)
        closeTab(id)
    }

    /// Asks claude to tick off what its work met in the session's plans and
    /// requirements, and commit them.
    static func tickOffPrompt(_ paths: [String]) -> String {
        var lines = ["Before this session is wrapped up: go through its plans and requirements in the harness and tick off (`- [x]`) each item your work has met. Leave anything not done, or only partly done, unticked."]
        if !paths.isEmpty {
            lines += [""] + paths.map { "- \($0)" }
        }
        lines += ["", "Commit and push those changes in the harness, then say which items you ticked and which are still open."]
        return lines.joined(separator: "\n")
    }
}

/// The session `SessionStore.wrappingUp` names, for the window's sheet.
struct WrapUpRequest: Identifiable {
    let id: UUID
}

/// What closing a running session's tab asks first: its pull requests and
/// what isn't pushed, its plans and requirements with their items to tick
/// off, then whether to leave it running, end it or finish it.
struct WrapUpSessionSheet: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @AppStorage(SessionStore.wrapUpKey) private var asks = true
    let id: UUID

    /// Ticks changed here and not committed, by path and item.
    @State private var ticks: [String: [String: Bool]] = [:]
    /// Committed, until the index catches up.
    @State private var committed: [String: [String: Bool]] = [:]
    @State private var committing = false
    @State private var error: String?
    @State private var askedClaude = false
    @State private var confirmingFinish = false
    @State private var finishing = false

    var body: some View {
        if let session = sessions.sessions[id] {
            content(session)
        }
    }

    private func content(_ session: CodeSession) -> some View {
        let documents = documents(session)
        let changes = sessions.changes(for: session)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wrap up \(session.longReference)?")
                    .font(.headline)
                Text("\(session.title). Closing the tab leaves claude running; this is the moment to end it, finish it, and bring its plans up to date.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                sessionSection(session, changes: changes)
                if !session.hasNoIssue {
                    plansSection(session, documents: documents)
                }
            }
            .formStyle(.grouped)

            Divider()
            footer(session)
                .padding(16)
        }
        .frame(width: 560)
        .frame(minHeight: 420, maxHeight: 720)
        .task { await changes.refresh(session) }
        .confirmationDialog("Finish this session?", isPresented: $confirmingFinish) {
            Button("Finish and Remove Worktrees", role: .destructive) { finish(session) }
        } message: {
            Text("Claude and any helpers are ended, the worktrees in \(SessionStore.worktreePath(for: session))\(session.isRemote ? " on the server" : "") are removed with anything not pushed in them, \(session.harnessFolder != nil ? "its session.json in the harness is marked finished, " : "")and Gannin forgets the session.")
        }
    }

    // MARK: Session

    private func sessionSection(_ session: CodeSession, changes: SessionChanges) -> some View {
        let running = sessions.helpers(of: id).filter { sessions.isRunning($0.id) }
        return Section("Session") {
            LabeledContent("Claude") {
                Text(sessions.state(id).label)
            }
            if !running.isEmpty {
                LabeledContent("Helpers running") {
                    let roles = running.compactMap(\.role)
                    Text(roles.isEmpty ? "\(running.count)" : roles.joined(separator: ", "))
                }
            }
            let pullRequests = sessions.pullRequestInfo[id] ?? []
            if pullRequests.isEmpty {
                LabeledContent("Pull requests") {
                    Text("None yet").foregroundStyle(.secondary)
                }
            } else {
                ForEach(pullRequests) { pr in
                    LabeledContent {
                        Text(pr.stateLabel)
                    } label: {
                        Link("\(pr.repo)#\(pr.number) \(pr.title)", destination: pr.url)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            ForEach(changes.worktrees.filter { worktree in worktree.unpushed.map { $0 > 0 } ?? !worktree.files.isEmpty }) { worktree in
                LabeledContent(worktree.name) {
                    Text(worktree.unpushed.map { $0 == 1 ? "1 commit not pushed" : "\($0) commits not pushed" } ?? "Never pushed")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Plans and requirements

    private func setup(_ session: CodeSession) -> HarnessConfig? {
        guard let repo = session.harnessRepo else { return nil }
        return configs.config(for: session.issue.org).harness(repo: repo) ?? HarnessConfig(repo: repo)
    }

    /// As the session's panel lists them: those that follow the standard,
    /// in the harness it runs in.
    private func documents(_ session: CodeSession) -> [HarnessDocument] {
        guard !session.hasNoIssue, let setup = setup(session),
              let index = harness.index(for: session.issue.org, setup) ?? harness.anyIndex(org: session.issue.org, repo: setup.repo) else { return [] }
        return index.matches(repo: session.issue.repo, number: session.issue.number)
            .map(\.document)
            .filter(\.followsStandard)
    }

    @ViewBuilder
    private func plansSection(_ session: CodeSession, documents: [HarnessDocument]) -> some View {
        Section {
            if documents.isEmpty {
                Text("None in the harness for \(session.issue.reference).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(documents, id: \.path) { document in
                let items = HarnessChecklist.items(in: document.text)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: document.kind.systemImage)
                            .foregroundStyle(.secondary)
                        Text(document.title).fontWeight(.medium)
                        Spacer()
                        if !items.isEmpty {
                            let done = items.filter { isDone($0, in: document) }.count
                            TaskCount(done: done, total: items.count)
                        }
                    }
                    if items.isEmpty {
                        Text("No items to tick off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        Toggle(isOn: tick(item, in: document)) {
                            Text(item.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                        .padding(.leading, CGFloat(min(item.indent, 8)) * 6)
                        .disabled(committing)
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                Button("Ask Claude to Tick Them Off") {
                    askedClaude = sessions.submit(SessionStore.tickOffPrompt(documents.map(\.path)), to: id)
                }
                .disabled(!sessions.isRunning(id) || askedClaude)
                .help("Pastes a prompt asking claude to tick off what its work met and commit it to the harness")
                Spacer()
                if committing { ProgressView().controlSize(.small) }
                if let setup = setup(session) {
                    let count = pendingCount
                    Button(count == 0 ? "Commit to Harness" : "Commit \(count) \(count == 1 ? "Change" : "Changes") to \(setup.repo)") {
                        commit(session, setup: setup)
                    }
                    .disabled(count == 0 || committing)
                }
            }
            if askedClaude {
                Text("Sent. Leave it running for claude to tick them off; they show here once the harness is fetched again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if pendingCount > 0 {
                Text("Ticks not committed are dropped when the tab closes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Plans and requirements")
        }
    }

    private var pendingCount: Int { ticks.values.reduce(0) { $0 + $1.count } }

    private func isDone(_ item: HarnessChecklist.Item, in document: HarnessDocument) -> Bool {
        ticks[document.path]?[item.id] ?? committed[document.path]?[item.id] ?? item.isDone
    }

    private func tick(_ item: HarnessChecklist.Item, in document: HarnessDocument) -> Binding<Bool> {
        Binding {
            isDone(item, in: document)
        } set: { done in
            let saved = committed[document.path]?[item.id] ?? item.isDone
            ticks[document.path, default: [:]][item.id] = done == saved ? nil : done
            if ticks[document.path]?.isEmpty == true { ticks[document.path] = nil }
        }
    }

    private func commit(_ session: CodeSession, setup: HarnessConfig) {
        let changes = ticks
        let count = pendingCount
        let message = "Gannin: \(count == 1 ? "1 item" : "\(count) items") ticked for \(session.longReference)"
        committing = true
        error = nil
        Task {
            do {
                // Against each file at the head, so changes since survive.
                try await harness.commit(org: session.issue.org, setup: setup) { head in
                    let texts = try await harness.files(setup: setup, at: head, paths: Array(changes.keys))
                    var files: [String: String?] = [:]
                    for (path, done) in changes {
                        guard case let text?? = texts[path] else { throw HarnessDetailsError.missing(path) }
                        let changed = HarnessChecklist.setting(done, in: text)
                        if changed != text { files[path] = changed }
                    }
                    return files.isEmpty ? nil : HarnessChange(message: message, files: files)
                }
                for (path, done) in changes {
                    committed[path, default: [:]].merge(done) { $1 }
                }
                ticks = [:]
            } catch let failure {
                error = failure.localizedDescription
            }
            committing = false
        }
    }

    // MARK: Closing

    private func footer(_ session: CodeSession) -> some View {
        HStack(spacing: 8) {
            Toggle("Don't ask again", isOn: Binding { !asks } set: { asks = !$0 })
                .toggleStyle(.checkbox)
                .help("Settings › General › Agent turns it back on")
            Spacer()
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            if finishing { ProgressView().controlSize(.small) }
            Button("Cancel") { sessions.wrappingUp = nil }
                .keyboardShortcut(.cancelAction)
            if sessions.isFinished(id) {
                Button("Finish Session…") { confirmingFinish = true }
                    .help("Every pull request is merged: end it, remove its worktrees and mark it finished in the harness")
            }
            Button("End Session") {
                sessions.wrappingUp = nil
                sessions.endAndClose(id)
            }
            .help("Ends claude and its helpers and closes the tab. The worktrees stay; opening it again resumes the conversation.")
            Button("Leave Running") {
                sessions.wrappingUp = nil
                sessions.closeTab(id)
            }
            .help("Closes the tab with claude still running, as closing always has")
        }
        .disabled(finishing || committing)
    }

    private func finish(_ session: CodeSession) {
        finishing = true
        Task {
            do {
                try await sessions.finish(session.id)
                sessions.wrappingUp = nil
            } catch {
                self.error = error.localizedDescription
            }
            finishing = false
        }
    }
}
