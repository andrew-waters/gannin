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
                        RefineFindingRow(session: session, finding: finding)
                    }
                    .onMove { sessions.moveFindings(from: $0, to: $1, in: session.id) }
                }
            }
        }
        .onAppear { focused = true }
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
