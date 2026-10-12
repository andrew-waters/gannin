import SwiftUI
import WebKit

/// Beside the page: who's here, a box to note a finding (⌘↩), which takes
/// the page's address and title as they are then, and the findings so far,
/// to edit, delete or drag into order. Each is kept with the session as
/// it's made.
struct RefineFindingsPanel: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let page: WebPage
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var annotating: RefineAnnotating?
    @State private var capturing = false
    @State private var error: String?

    private var findings: [RefineInfo.Finding] { session.refine?.findings ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            RefineAttendees(session: session)
            Divider()
            capture
            Divider()
            List {
                Section(header: SectionHeader(title: "Findings", count: findings.count)) {
                    if findings.isEmpty {
                        Text("Nothing noted yet. What the room spots goes above, with the page it was on.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(findings) { finding in
                        RefineFindingRow(session: session, finding: finding) { annotating = $0 }
                    }
                    .onMove { sessions.moveFindings(from: $0, to: $1, in: session.id) }
                }
                let suggestions = session.refine?.openSuggestions ?? []
                if !suggestions.isEmpty {
                    Section(header: SectionHeader(title: "Claude suggests", count: suggestions.count)) {
                        ForEach(suggestions) { suggestion in
                            RefineSuggestionRow(session: session, suggestion: suggestion)
                        }
                    }
                }
            }
            if [.starting, .working].contains(sessions.state(session.id)) {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Claude is looking at the code").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .onAppear { focused = true }
        .sheet(item: $annotating) { annotating in
            RefineAnnotateSheet(session: session, annotating: annotating)
        }
        .alert("Couldn't take a screenshot", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var capture: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("What did the room spot?", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(2...6)
                .focused($focused)
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Text(page.title.isEmpty ? (page.url?.absoluteString ?? "") : page.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Noted against the page shown now")
                Spacer(minLength: 0)
                Button {
                    screenshot()
                } label: {
                    Label("Screenshot", systemImage: "camera.viewfinder")
                }
                .disabled(capturing || page.url == nil)
                .help("Take a screenshot of the page as it's shown, to mark up and attach to a finding")
                Button("Add Finding", action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Note it with the page's address and title and the time (⌘↩)")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func screenshot() {
        capturing = true
        let url = page.url?.absoluteString ?? ""
        let title = page.title
        Task {
            defer { capturing = false }
            do {
                let image = try await RefineScreenshots.capture(page)
                annotating = RefineAnnotating(image: image, url: url, pageTitle: title.isEmpty ? nil : title)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func add() {
        let url = page.url?.absoluteString ?? session.refine?.lastURL ?? session.refine?.url ?? ""
        guard sessions.addFinding(text, url: url, pageTitle: page.title, to: session.id) != nil else { return }
        text = ""
        focused = true
    }
}

/// A finding: its note, edited in place, and the page and time it was
/// noted on.
struct RefineFindingRow: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let finding: RefineInfo.Finding
    /// Opens a screenshot to change its marks.
    let annotate: (RefineAnnotating) -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if editing {
                    TextField("Finding", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...8)
                        .focused($focused)
                        .onSubmit(save)
                        .onEscape { editing = false }
                } else {
                    Text(finding.note)
                        .textSelection(.enabled)
                        .onTapGesture(count: 2, perform: edit)
                }
                HStack(spacing: 4) {
                    if let url = URL(string: finding.url) {
                        Link(finding.pageTitle ?? finding.url, destination: url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(finding.url)
                    }
                    Text("· \(finding.at.formatted(date: .omitted, time: .shortened))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !shots.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(shots) { shot in thumbnail(shot) }
                    }
                }
                if finding.suggestion != nil {
                    Label("Claude's suggestion, kept", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
                if let scouting = session.refine?.state?.scouting(for: finding.id) {
                    RefineScoutingView(scouting: scouting)
                }
            }
            Spacer(minLength: 0)
            if editing {
                Button("Save", action: save)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Edit", action: edit)
            Button("Delete", role: .destructive) { sessions.removeFinding(finding.id, from: session.id) }
        }
    }

    private var shots: [RefineInfo.Screenshot] {
        let all = session.refine?.screenshots ?? []
        return finding.screenshots.compactMap { id in all.first { $0.id == id } }
    }

    private func thumbnail(_ shot: RefineInfo.Screenshot) -> some View {
        let file = RefineScreenshots.url(shot, in: session)
        return Button {
            open(shot)
        } label: {
            Group {
                if let file, let image = NSImage(contentsOf: file) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.separatorLine))
        }
        .buttonStyle(.plain)
        .help("\(shot.file): click to change its marks")
        .contextMenu {
            Button("Change Marks…") { open(shot) }
            if let file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            Button("Delete Screenshot", role: .destructive) { sessions.removeScreenshot(shot, from: session.id) }
        }
    }

    /// The page as it was, without its marks, to draw them again.
    private func open(_ shot: RefineInfo.Screenshot) {
        let source = RefineScreenshots.original(shot, in: session).flatMap(NSImage.init(contentsOf:))
        guard let image = source ?? RefineScreenshots.url(shot, in: session).flatMap(NSImage.init(contentsOf:)) else { return }
        annotate(RefineAnnotating(image: image, url: shot.url, pageTitle: shot.pageTitle, existing: shot))
    }

    private func edit() {
        draft = finding.note
        editing = true
        focused = true
    }

    private func save() {
        sessions.setFindingNote(draft, finding: finding.id, in: session.id)
        editing = false
    }
}

/// Who's in the meeting, at the top of the findings: taken off with ×,
/// added by name as the session goes.
struct RefineAttendees: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    @State private var guest = ""
    @AppStorage("refineAttendeesExpanded") private var expanded = true

    private var attendees: [RefineInfo.Attendee] { session.refine?.attendees ?? [] }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                FlowRow(spacing: 6, alignment: .center) {
                    ForEach(attendees) { attendee in
                        HStack(spacing: 4) {
                            Text(attendee.name)
                            Button {
                                sessions.setAttendees(attendees.filter { $0.id != attendee.id }, for: session.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Not here")
                            .accessibilityLabel("Remove \(attendee.name)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .help(attendee.login.map { "@\($0)" } ?? attendee.name)
                    }
                }
                HStack {
                    TextField("Add someone", text: $guest)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(guest.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
            .padding(.top, 6)
        } label: {
            SectionHeader(title: "Who's here", count: attendees.count)
                .font(.headline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func add() {
        let name = guest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let attendee = RefineInfo.Attendee(name: name)
        if !attendees.contains(attendee) {
            sessions.setAttendees(attendees + [attendee], for: session.id)
        }
        guest = ""
    }
}

/// Where Claude thinks a finding lives: its files and components, and why.
struct RefineScoutingView: View {
    let scouting: RefineState.Scouting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Where it lives", systemImage: "sparkle.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(scouting.files, id: \.self) { file in
                Text(file)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if !scouting.components.isEmpty {
                Text(scouting.components.joined(separator: ", "))
                    .font(.caption)
            }
            if let why = scouting.why, !why.isEmpty {
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A finding Claude suggests, marked as Claude's, to keep or dismiss.
struct RefineSuggestionRow: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let suggestion: RefineState.Suggestion

    private var source: String {
        switch suggestion.source {
        case .screenshot:
            let shot = session.refine?.screenshots.first { $0.id.uuidString.caseInsensitiveCompare(suggestion.screenshot ?? "") == .orderedSame }
            return shot.map { "From \(($0.file as NSString).deletingPathExtension)" } ?? "From a screenshot"
        case .transcript: return "From the transcript"
        case nil: return "Claude's"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(source, systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.purple)
            Text(suggestion.note)
                .textSelection(.enabled)
            if let why = suggestion.why, !why.isEmpty {
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Dismiss") { sessions.dismissSuggestion(suggestion, in: session.id) }
                Button("Keep") { sessions.keepSuggestion(suggestion, in: session.id) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
