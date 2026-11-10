import SwiftUI

/// Agreeing a Design and Refine session: each finding as an issue draft to
/// edit or untick, and each screenshot with a sensitive-data warning and a
/// box to tick, unticked until someone has looked. Nothing's written until
/// Agree and Write; then the issues are made and added to the workflow
/// board, each linking to its ticked screenshots, then the record and those
/// screenshots are committed to the harness. Unticked screenshots are
/// neither committed nor linked. Trying again makes only what wasn't made.
struct RefineAgreeSheet: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(AuthStore.self) private var auth
    @Environment(OrgConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var projects
    @Environment(HarnessStore.self) private var harness
    @Environment(\.dismiss) private var dismiss
    let session: CodeSession

    struct Draft: Identifiable {
        let finding: RefineInfo.Finding
        var include = true
        var repo: String
        var title: String
        var body: String
        var labels = ""
        var made: RefineInfo.MadeIssue?
        var failed: String?
        /// The issue was made, but couldn't be added to the workflow board.
        var boardWarning: String?

        var id: UUID { finding.id }
    }

    @State private var drafts: [Draft] = []
    /// Screenshots looked at and ticked to commit, by id.
    @State private var ticked: Set<UUID> = []
    @State private var working = false
    @State private var status: String?

    private var org: String { session.org }
    private var info: RefineInfo? { session.refine }
    private var harnessRepo: String { session.harnessRepo ?? session.repo }
    private var projectConfig: OrgConfig { configs.scoped(harnessRepo).config(for: org) }

    /// Screenshots attached to findings being raised.
    private var screenshots: [RefineInfo.Screenshot] {
        let attached = Set(drafts.filter(\.include).flatMap(\.finding.screenshots))
        return (info?.screenshots ?? []).filter { attached.contains($0.id) || linked.contains($0.id) }
    }

    /// Screenshots an issue already made links to: they must be committed.
    private var linked: Set<UUID> {
        Set((info?.made ?? [:]).values.flatMap { $0.screenshots ?? [] }.compactMap(UUID.init(uuidString:)))
    }

    /// What gets committed and listed: ticked screenshots still shown (a
    /// finding unticked takes its screenshots with it), and every one an
    /// issue already links to.
    private var toCommit: Set<UUID> {
        ticked.intersection(screenshots.map(\.id)).union(linked)
    }

    private var repos: [String] {
        let picked = info?.repos ?? []
        return picked.isEmpty ? [harnessRepo] : picked
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agree \(session.title)").font(.headline).lineLimit(1)
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            .padding(12)
            Divider()
            Form {
                Section("\(drafts.filter(\.include).count) of \(drafts.count) issues") {
                    if drafts.isEmpty {
                        Text("No findings: only the record is written.").foregroundStyle(.secondary)
                    }
                    ForEach($drafts) { $draft in
                        editor($draft)
                    }
                }
                screenshotsSection
                Section {
                    LabeledContent("Record", value: info.map(RefineDocuments.readmePath) ?? "")
                    LabeledContent("Who was here", value: (info?.attendees ?? []).map(\.name).joined(separator: ", "))
                } header: {
                    Text("Harness")
                } footer: {
                    Text("Goes to \(harnessRepo) after the issues are made, with the ticked screenshots beside it. The transcript stays on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding([.horizontal, .top], 12)
            }
            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // The default: Return never writes.
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                Button(working ? "Writing" : "Agree and Write") { Task { await agree() } }
                    .disabled(working || info == nil || drafts.contains { $0.include && $0.made == nil && ($0.repo.isEmpty || $0.title.trimmingCharacters(in: .whitespaces).isEmpty) })
                    .help("Make the ticked issues on GitHub and commit the record to \(harnessRepo)")
            }
            .padding(12)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 640, idealHeight: 800)
        .onAppear(perform: fill)
    }

    // MARK: Sections

    private func editor(_ draft: Binding<Draft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: draft.include).labelsHidden().checkboxToggle()
                    .disabled(draft.wrappedValue.made != nil || info?.agreed != nil)
                TextField("Title", text: draft.title, prompt: Text("Title"))
                    .labelsHidden()
                    .fontWeight(.medium)
                Picker("", selection: draft.repo) {
                    ForEach(repos.contains(draft.wrappedValue.repo) ? repos : [draft.wrappedValue.repo] + repos, id: \.self) {
                        Text($0.split(separator: "/").last.map(String.init) ?? $0).tag($0)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if let made = draft.wrappedValue.made {
                    Link(destination: made.url) { Image(systemName: "checkmark.circle.fill").foregroundStyle(ChartPalette.good) }
                        .help(made.reference)
                }
            }
            if draft.wrappedValue.finding.suggestion != nil {
                Label("Claude's suggestion, kept by the room", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
            TextField("Description", text: draft.body, prompt: Text("Description"), axis: .vertical)
                .labelsHidden()
                .lineLimit(3...10)
                .foregroundStyle(.secondary)
            TextField("Labels", text: draft.labels, prompt: Text("Labels, comma separated"))
                .labelsHidden()
                .font(.caption)
            if let failed = draft.wrappedValue.failed {
                Text(failed).font(.caption).foregroundStyle(.red)
            }
            if let boardWarning = draft.wrappedValue.boardWarning {
                Text(boardWarning).font(.caption).foregroundStyle(.orange)
            }
        }
        .opacity(draft.wrappedValue.include ? 1 : 0.5)
        .disabled(draft.wrappedValue.made != nil)
    }

    @ViewBuilder
    private var screenshotsSection: some View {
        let shots = screenshots
        if !shots.isEmpty {
            Section {
                Label {
                    Text("Screenshots show whatever was on screen, which can include customer details or other sensitive data. Everyone who can read \(harnessRepo) will see a committed screenshot, and git keeps it in the history even if it's deleted later. Tick only those you've checked; the rest are neither committed nor linked from the issues.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                ForEach(shots) { shot in
                    screenshotRow(shot)
                }
            } header: {
                Text("\(ticked.intersection(shots.map(\.id)).count) of \(shots.count) screenshots")
            }
        }
    }

    private func screenshotRow(_ shot: RefineInfo.Screenshot) -> some View {
        let file = RefineScreenshots.url(shot, in: session)
        let size = file.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        let tooLarge = size > HarnessChange.maxDataBytes
        let mustCommit = linked.contains(shot.id) && !(info?.committed ?? []).contains(shot.id.uuidString)
        return HStack(alignment: .top, spacing: 12) {
            Group {
                if let file, let image = NSImage(contentsOf: file) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 260, height: 160)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.separatorLine))
            .onTapGesture(count: 2) { if let file { NSWorkspace.shared.open(file) } }
            .help("Double-click to open it in Preview")
            VStack(alignment: .leading, spacing: 6) {
                Text(shot.file).fontWeight(.medium)
                Text(shot.pageTitle ?? shot.url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                if tooLarge {
                    Text("It's over \(ByteCountFormatter.string(fromByteCount: Int64(HarnessChange.maxDataBytes), countStyle: .file)), more than Gannin commits through GitHub's API.")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if (info?.committed ?? []).contains(shot.id.uuidString) {
                    Label("Committed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(ChartPalette.good)
                } else {
                    Toggle("I've checked this screenshot and it belongs in the harness", isOn: Binding(
                        get: { ticked.contains(shot.id) },
                        set: { on in if on { ticked.insert(shot.id) } else { ticked.remove(shot.id) } }
                    ))
                    .checkboxToggle()
                    .disabled(mustCommit)
                    .help(mustCommit ? "An issue already made links to it" : "")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        let count = drafts.filter { $0.include && $0.made == nil }.count
        let shots = ticked.intersection(screenshots.map(\.id)).count
        var parts: [String] = []
        if count > 0 { parts.append(count == 1 ? "1 issue" : "\(count) issues") }
        parts.append("the record")
        if shots > 0 { parts.append(shots == 1 ? "1 screenshot" : "\(shots) screenshots") }
        return "Writes " + parts.joined(separator: ", ")
    }

    private func fill() {
        guard drafts.isEmpty, let info else { return }
        let made = info.made ?? [:]
        drafts = info.findings.map { finding in
            var draft = Draft(finding: finding, repo: RefineDocuments.repo(for: finding, info: info) ?? harnessRepo,
                              title: RefineDocuments.title(finding.note), body: "")
            draft.body = RefineDocuments.issueDescription(finding, info: info)
            draft.made = made[finding.id.uuidString]
            // Once agreed, the findings left out stay out: a second go only
            // retries the board.
            if info.agreed != nil { draft.include = draft.made != nil }
            return draft
        }
        ticked = linked.union((info.committed ?? []).compactMap(UUID.init(uuidString:)))
    }

    // MARK: Writing

    private func agree() async {
        guard let api = auth.api else {
            status = "Your GitHub session has expired. Sign in again."
            return
        }
        guard var info else { return }
        working = true
        defer { working = false }
        status = nil
        let setup = projectConfig.harness(repo: harnessRepo) ?? HarnessConfig(repo: harnessRepo)
        // Issues link into the record's folder, so it must be this
        // session's before anything is made: another session (finished
        // here, or on another Mac) may have the same slug.
        if (info.made ?? [:]).isEmpty && (info.committed ?? []).isEmpty {
            do {
                let slug = try await freeSlug(info, setup: setup)
                if slug != info.slug {
                    sessions.update(session.id) { $0.refine?.slug = slug }
                    info.slug = slug
                }
            } catch {
                status = "Couldn't check the harness for a record with this name: \(error.localizedDescription)"
                return
            }
        }
        let screenshotsByID = Dictionary(uniqueKeysWithValues: info.screenshots.map { ($0.id, $0) })
        let boardNumber = projectConfig.workflow.projectNumber
        let boardID = boardNumber.flatMap { number in projects.boardLists[org]?.first { $0.number == number }?.id }
        var boardProblems: [String] = []
        if boardNumber != nil && boardID == nil {
            boardProblems.append("The workflow board isn't loaded, so the issues weren't added to it. Open the project's board, then Agree and Write again.")
        }

        for index in drafts.indices where info.agreed == nil && drafts[index].include && drafts[index].made == nil {
            let draft = drafts[index]
            drafts[index].failed = nil
            drafts[index].boardWarning = nil
            let shots = draft.finding.screenshots.filter(toCommit.contains).compactMap { screenshotsByID[$0] }
            let body = draft.body + RefineDocuments.issueLinks(screenshots: shots, info: info, harnessRepo: harnessRepo)
            do {
                let created = try await api.createIssue(repo: draft.repo, title: draft.title, body: body, labels: labels(draft.labels))
                let issue = RefineInfo.MadeIssue(id: created.id, reference: "\(draft.repo)#\(created.number)", url: created.url,
                                                 screenshots: shots.map(\.id.uuidString),
                                                 onBoard: boardNumber == nil ? nil : false)
                drafts[index].made = issue
                remember(issue, for: draft.finding.id)
            } catch {
                drafts[index].failed = error.localizedDescription
            }
        }
        // Made issues not on the board yet, this time or an earlier one.
        if let boardID {
            for index in drafts.indices {
                guard var issue = drafts[index].made, issue.onBoard == false else { continue }
                do {
                    try await api.addToProject(projectID: boardID, contentID: issue.id)
                    issue.onBoard = true
                    drafts[index].made = issue
                    drafts[index].boardWarning = nil
                    remember(issue, for: drafts[index].finding.id)
                } catch {
                    drafts[index].boardWarning = "Made, but couldn't add it to the board: \(error.localizedDescription)"
                    boardProblems.append("\(issue.reference) couldn't be added to the board. Agree and Write again to retry.")
                }
            }
        }
        if drafts.contains(where: { $0.include && $0.made == nil }) {
            status = "Some issues weren't made. Agree and Write again to try those, or untick them."
            return
        }
        // Already agreed: this was a second go at the board, nothing more.
        if info.agreed != nil {
            if boardProblems.isEmpty { dismiss() } else { status = boardProblems.joined(separator: " ") }
            return
        }

        // Every screenshot a made issue links to is committed, with any
        // others ticked; the record goes in the last commit.
        let toCommit = info.screenshots.filter { self.toCommit.contains($0.id) && !(info.committed ?? []).contains($0.id.uuidString) }
        var files: [(path: String, data: Data)] = []
        for shot in toCommit {
            guard let url = RefineScreenshots.url(shot, in: session), let data = try? Data(contentsOf: url) else {
                status = "Couldn't read \(shot.file) from the session's folder."
                return
            }
            guard data.count <= HarnessChange.maxDataBytes else {
                status = HarnessWriteError.tooLarge(shot.file).localizedDescription
                return
            }
            files.append(("\(RefineDocuments.folder(info))/\(shot.file)", data))
        }
        let batches = RefineDocuments.batches(files)
        let made = sessions.sessions[session.id]?.refine?.made ?? [:]
        let allTicked = self.toCommit.union((info.committed ?? []).compactMap(UUID.init(uuidString:)))
        let readme = RefineDocuments.readme(sessions.sessions[session.id]?.refine ?? info, made: made, ticked: allTicked, day: HarnessAuthoring.today)
        do {
            for (number, batch) in (batches.isEmpty ? [[]] : batches).enumerated() {
                let last = number == max(batches.count, 1) - 1
                try await harness.commit(org: org, setup: setup) { _ in
                    HarnessChange(
                        message: batches.count > 1 ? "Design and Refine: \(info.name) (\(number + 1) of \(batches.count))" : "Design and Refine: \(info.name)",
                        files: last ? [RefineDocuments.readmePath(info): readme] : [:],
                        data: Dictionary(uniqueKeysWithValues: batch.map { ($0.path, $0.data) })
                    )
                }
                let committed = Set(batch.map(\.path))
                sessions.update(session.id) { session in
                    let ids = toCommit.filter { committed.contains("\(RefineDocuments.folder(info))/\($0.file)") }.map(\.id.uuidString)
                    let before = session.refine?.committed ?? []
                    session.refine?.committed = before + ids
                }
            }
        } catch {
            status = "The issues are made, but the record couldn't be committed: \(error.localizedDescription) Agree and Write again to retry."
            return
        }

        sessions.update(session.id) { $0.refine?.agreed = .now }
        let references = drafts.compactMap(\.made?.reference)
        var message = "The room agreed. Gannin committed \(RefineDocuments.readmePath(info)) to the harness"
        message += references.isEmpty ? "." : " and made \(references.joined(separator: ", "))."
        message += " There's nothing more to write; answer questions about the session if we ask."
        sessions.submit(message, to: session.id)
        if boardProblems.isEmpty {
            dismiss()
        } else {
            // Agreed, but the board needs another go: say so rather than
            // close over it.
            status = boardProblems.joined(separator: " ")
        }
    }

    private func remember(_ issue: RefineInfo.MadeIssue, for finding: UUID) {
        sessions.update(session.id) { session in
            var made = session.refine?.made ?? [:]
            made[finding.uuidString] = issue
            session.refine?.made = made
        }
    }

    /// The session's slug, or the first after it (`-2`, `-3`) with no
    /// record in the harness yet.
    private func freeSlug(_ info: RefineInfo, setup: HarnessConfig) async throws -> String {
        guard let api = auth.api else { throw APIError.unauthorized }
        let parts = setup.repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw HarnessWriteError.invalidRepo(setup.repo) }
        let head = try await api.harnessHead(owner: parts[0], name: parts[1], branch: setup.branch)
        var candidate = info
        for number in 1...20 {
            candidate.slug = number == 1 ? info.slug : "\(info.slug)-\(number)"
            let path = RefineDocuments.readmePath(candidate)
            let existing = try await harness.files(setup: setup, at: head.commit, paths: [path])[path] ?? nil
            if existing == nil { return candidate.slug }
        }
        throw SessionError.message("Every name for this record is taken in the harness.")
    }

    private func labels(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
