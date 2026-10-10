import AppKit
import SwiftUI

/// A Design and Refine session: the team steps through a running web page
/// together, captures what to improve, and ends with issues and a record in
/// the harness (`refines/<date>-<slug>/`). It runs in the project's harness
/// on this Mac, in its own folder (`.worktrees/refine-<date>-<slug>/`,
/// outside git), with claude as co-reviewer reading the picked repos'
/// clones in `projects/` (andrew-waters/gannin#134,
/// `plans/2026-10-10-design-and-refine.md`).
struct RefineInfo: Codable, Hashable {
    /// Someone in the meeting: one of the org's people by login, or a name
    /// typed for anyone outside it.
    struct Attendee: Codable, Hashable, Identifiable {
        let name: String
        var login: String? = nil

        var id: String { login ?? "name:\(name)" }
    }

    /// Something the room noted, with the page as it was then.
    struct Finding: Codable, Hashable, Identifiable {
        var id = UUID()
        var note: String
        let url: String
        let pageTitle: String?
        let at: Date
        /// Screenshots attached to it, by `Screenshot.id`.
        var screenshots: [UUID] = []
    }

    /// A screenshot of the page, its file in the session's `screenshots/`.
    struct Screenshot: Codable, Hashable, Identifiable {
        var id = UUID()
        let file: String
        let url: String
        let at: Date
    }

    /// As its tab and lists name it: what's being looked at.
    var name: String
    /// The day it started and the name (`2026-10-10-sign-up-page`), for its
    /// folder and its record in the harness.
    let slug: String
    /// The page it opened on, and the one last shown, to reopen on.
    let url: String
    var lastURL: String? = nil
    /// The repos the page's code is in, the project's first by default.
    var repos: [String]
    var attendees: [Attendee]
    var findings: [Finding] = []
    var screenshots: [Screenshot] = []
    /// The meeting transcript's file name in the session's folder, once one
    /// was pasted or dropped. Never committed.
    var transcript: String? = nil
    /// When the room agreed it and its record was written.
    var agreed: Date? = nil
}

extension CodeSession {
    var isRefine: Bool { refine != nil }
}

extension SessionStore {
    /// Starts a Design and Refine session in a project's harness. It always
    /// runs on this Mac, even with Connect with set, since the page opens in
    /// a web view here.
    @discardableResult
    func startRefine(org: String, name: String, url: URL, repos: [String], attendees: [RefineInfo.Attendee], harness setup: HarnessConfig) -> CodeSession {
        let harnessPath = Self.localHarnessPath(org: org, repo: setup.repo)
        let title = Self.refineTitle(name: name, url: url)
        let id = UUID()
        let slug = Self.refineSlug(title: title, day: Date.now.formatted(.iso8601.year().month().day()),
                                   taken: Set(sessions.values.compactMap { $0.refine?.slug }))
        let info = RefineInfo(name: title, slug: slug, url: url.absoluteString, repos: repos, attendees: attendees)
        var session = CodeSession(
            id: id, issue: IssueReference(org: org, id: "refine-\(id.uuidString)", number: 0, title: title, repo: setup.repo,
                                          url: URL(string: "https://github.com/\(setup.repo)")!),
            repo: setup.repo, branch: Self.refineFolder(slug: slug), createdAt: .now,
            connect: nil, harnessRepo: setup.repo, harnessPath: harnessPath
        )
        session.refine = info
        session.prompt = Self.refinePrompt(session)
        let directory = Self.directory(for: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(Self.refineBrief(session).utf8).write(to: directory.appending(path: "brief.md"))
        add(session)
        reveal(session.id)
        return session
    }

    /// The name typed, else the page's host and path (`staging.acme.com/signup`).
    static func refineTitle(name: String, url: URL) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty else { return name }
        let path = url.path(percentEncoded: false)
        let page = (url.host(percentEncoded: false) ?? "") + (path == "/" ? "" : path)
        return page.isEmpty ? "Design and Refine" : page
    }

    /// `2026-10-10-sign-up-page`: the day and the title's first words, with
    /// a number added when another session already has it.
    static func refineSlug(title: String, day: String, taken: Set<String>) -> String {
        let words = String(title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " }).split(separator: " ")
        var name = ""
        for word in words {
            let next = name.isEmpty ? String(word) : "\(name)-\(word)"
            if next.count > 40 { break }
            name = next
        }
        let base = "\(day)-\(name.isEmpty ? "page" : name)"
        var slug = base
        var count = 2
        while taken.contains(slug) {
            slug = "\(base)-\(count)"
            count += 1
        }
        return slug
    }

    /// Its branch, which names its folder: `.worktrees/refine-<slug>/`.
    static func refineFolder(slug: String) -> String { "refine-\(slug)" }

    /// A URL as typed, `https://` added when there's no scheme (`localhost:3000`
    /// gets `http://`); nil for anything but a web page.
    static func refineURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let local = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1")
        let full = text.contains("://") ? text : "\(local ? "http" : "https")://\(text)"
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return url
    }

    /// Claude's first prompt: it's the room's co-reviewer, and until
    /// findings come it gets to know where the page's code lives.
    static func refinePrompt(_ session: CodeSession) -> String {
        let folder = ".worktrees/\(session.branch)"
        let repos = session.refine?.repos ?? []
        return """
            You're the co-reviewer in a Design and Refine session in the team's harness: the room is stepping through \
            \(session.refine?.url ?? "a web page") together and noting what to improve. Read \(folder)/.gannin/brief.md first. \
            For now, look through \(repos.isEmpty ? "the code" : repos.map { "`projects/\($0.split(separator: "/").last ?? "")`" }.joined(separator: ", ")) \
            to learn where that page's code lives, say in a few lines what you found, and wait for the room. Don't change any code.
            """
    }

    /// The session's brief: what it is, who's here and what not to do.
    static func refineBrief(_ session: CodeSession) -> String {
        let folder = ".worktrees/\(session.branch)"
        let info = session.refine
        let attendees = (info?.attendees ?? []).map { attendee in attendee.login.map { "- \(attendee.name) (@\($0))" } ?? "- \(attendee.name)" }
        let repos = (info?.repos ?? []).map { "- \($0), cloned at `projects/\($0.split(separator: "/").last ?? "")` if it's there" }
        return """
            # Design and Refine: \(session.title)

            A live session run from Gannin on the room's shared screen. The team is stepping through a web page together, \
            noting rough edges and what to improve. What the room agrees becomes GitHub issues, and the session is recorded \
            in the harness under `refines/`. Gannin makes both; you don't.

            ## The page

            \(info?.url ?? "")

            ## Its code

            \(repos.isEmpty ? "No repos were picked." : repos.joined(separator: "\n"))

            ## In the room

            \(attendees.isEmpty ? "Nobody listed yet." : attendees.joined(separator: "\n"))

            ## Working here

            - You're in the team's harness, \(session.harnessRepo ?? session.repo), checked out at `\(session.harnessPath ?? "")`. The code repos are shared clones under `projects/<name>`, to read; don't change them, and don't make worktrees.
            - You're the co-reviewer: read the code to say where things live. Don't edit code, open pull requests, or create issues.
            - `\(folder)/` is this session's folder, outside the harness's git. Never commit anything from it.
            - `\(folder)/.gannin/` is Gannin's (this brief and the session's hooks).

            """
    }

    /// Who's in the meeting, changed during the session.
    func setAttendees(_ attendees: [RefineInfo.Attendee], for id: UUID) {
        update(id) { $0.refine?.attendees = attendees }
    }

    /// Design and Refine sessions, newest first.
    func refineSessions(for org: String) -> [CodeSession] {
        sessions(for: org).filter(\.isRefine).sorted { $0.createdAt > $1.createdAt }
    }

    /// Opens a New Design and Refine tab in the Claude Code window.
    func showNewRefine(org: String, harnessRepo: String?, with openWindow: OpenWindowAction) {
        openDraft(PlanningDraft(org: org, harnessRepo: harnessRepo, isRefine: true))
        openWindow(id: Self.windowID)
    }
}

// MARK: - Starting

/// A New Design and Refine tab in the Claude Code window, until it's
/// started: the project, its repos the page's code is in (the project's
/// first ticked), the page's URL, an optional name, and who's in the
/// meeting (the org's people to tick, names typed for anyone else).
struct NewRefineView: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgStore.self) private var orgs
    let draftID: UUID
    let draft: PlanningDraft
    @State private var picked: String?
    @State private var address = ""
    @State private var name = ""
    @State private var repos: Set<String> = []
    @State private var choseRepos = false
    @State private var present: Set<String> = []
    @State private var guests: [String] = []
    @State private var guest = ""
    @State private var search = ""

    private var org: String { draft.org }

    var body: some View {
        let config = configs.config(for: org)
        let harnesses = config.repoProjects.isEmpty ? config.harnesses : config.allHarnesses
        let setup = (picked ?? draft.harnessRepo).flatMap(config.harness(repo:)) ?? harnesses.first
        let url = SessionStore.refineURL(address)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Label("New Design and Refine", systemImage: "rectangle.and.pencil.and.ellipsis")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                Form {
                    Section {
                        Picker("Project", selection: Binding(get: { setup?.repo ?? "" }, set: { picked = $0; choseRepos = false })) {
                            ForEach(projectChoices, id: \.repo) { choice in
                                Text(choice.name).tag(choice.repo)
                            }
                        }
                        TextField("Page", text: $address, prompt: Text("https://staging.example.com/signup"))
                        TextField("Name", text: $name, prompt: Text(url.map { SessionStore.refineTitle(name: "", url: $0) } ?? "What's being looked at"))
                    } footer: {
                        Text(setup == nil
                             ? "Design and Refine runs in a project's harness. Add one in the org's Settings, under Projects."
                             : !address.isEmpty && url == nil
                                ? "That doesn't look like a web page's address."
                                : "The page opens inside Gannin for the room to step through. Claude Code runs in \(setup!.repo) on this Mac as co-reviewer, reading the code of the repos ticked below.")
                            .font(.caption)
                            .foregroundStyle(!address.isEmpty && url == nil ? Color.orange : Color.secondary)
                    }
                    Section {
                        let choices = repoChoices(setup: setup)
                        if choices.isEmpty {
                            Text("No repos to pick from.").foregroundStyle(.secondary)
                        }
                        ForEach(choices, id: \.self) { repo in
                            Toggle(repo, isOn: Binding(
                                get: { repos.contains(repo) },
                                set: { on in if on { repos.insert(repo) } else { repos.remove(repo) } }
                            ))
                            .checkboxToggle()
                        }
                    } header: {
                        Text("Its code")
                    } footer: {
                        Text("Where the page's code is, for Claude to look through.").font(.caption).foregroundStyle(.secondary)
                    }
                    attendeesSection
                    Section {
                        HStack {
                            Spacer()
                            Button("Start") { if let setup, let url { start(setup, url: url) } }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.return, modifiers: .command)
                                .disabled(setup == nil || url == nil || repos.isEmpty)
                                .help("Start (⌘↩)")
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .task(id: setup?.repo) {
            if let setup { await harness.load(org: org, setup: setup) }
        }
        .task(id: org) { await harness.loadRepositories(org: org) }
        // The project's first repo ticked, until repos are picked.
        .onChange(of: setup?.repo, initial: true) {
            guard !choseRepos else { return }
            repos = Set(repoChoices(setup: setup).prefix(1))
            choseRepos = true
        }
    }

    private var attendeesSection: some View {
        Section {
            TextField("Search the org", text: $search)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(members) { person in
                    Toggle(person.displayName, isOn: Binding(
                        get: { present.contains(person.login) },
                        set: { on in if on { present.insert(person.login) } else { present.remove(person.login) } }
                    ))
                    .checkboxToggle()
                    .help(person.login)
                }
            }
            ForEach(guests, id: \.self) { name in
                HStack {
                    Text(name)
                    Spacer()
                    Button {
                        guests.removeAll { $0 == name }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(name)")
                }
            }
            HStack {
                TextField("Someone outside the org", text: $guest)
                    .onSubmit(addGuest)
                Button("Add", action: addGuest)
                    .disabled(guest.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Who's here")
        } footer: {
            Text("Kept with the session, changeable as it goes, and listed in its record in the harness.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var members: [Person] {
        let all = (orgs.snapshot(for: org)?.members ?? []).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.login.localizedCaseInsensitiveContains(query) || ($0.name ?? "").localizedCaseInsensitiveContains(query) || present.contains($0.login) }
    }

    private func addGuest() {
        let name = guest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !guests.contains(name) { guests.append(name) }
        guest = ""
    }

    private func start(_ setup: HarnessConfig, url: URL) {
        let people = (orgs.snapshot(for: org)?.members ?? []).filter { present.contains($0.login) }
            .map { RefineInfo.Attendee(name: $0.displayName, login: $0.login) }
        let ordered = repoChoices(setup: setup).filter(repos.contains)
        let session = sessions.startRefine(org: org, name: name, url: url, repos: ordered,
                                           attendees: people + guests.map { RefineInfo.Attendee(name: $0) }, harness: setup)
        sessions.replaceDraft(draftID, with: session.id)
    }

    /// The project's repos, or with none named, the org's.
    private func repoChoices(setup: HarnessConfig?) -> [String] {
        let config = configs.config(for: org)
        if let setup, let project = config.repoProjects.first(where: { $0.harness.repo == setup.repo }), !project.repos.isEmpty {
            return project.repos
        }
        return (harness.repositories[org] ?? []).filter { !config.repoExclusion.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The org's projects by name, or its harnesses by repo with none named.
    private var projectChoices: [(name: String, repo: String)] {
        let config = configs.config(for: org)
        if !config.repoProjects.isEmpty {
            return config.repoProjects.map { ($0.name, $0.harness.repo) }
        }
        return config.harnesses.map { ($0.repo, $0.repo) }
    }
}

/// A Design and Refine session's page, repos and who's here, in its panel;
/// attendees can be added or taken off as the session goes.
struct RefineSection: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    @State private var guest = ""

    var body: some View {
        if let refine = session.refine {
            Section("Design and Refine") {
                if let url = URL(string: refine.lastURL ?? refine.url) {
                    Link(refine.lastURL ?? refine.url, destination: url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Code", value: refine.repos.joined(separator: ", "))
            }
            Section("Who's here") {
                ForEach(refine.attendees) { attendee in
                    HStack {
                        Text(attendee.name)
                        if let login = attendee.login {
                            Text("@\(login)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            sessions.setAttendees(refine.attendees.filter { $0.id != attendee.id }, for: session.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Not here")
                        .accessibilityLabel("Remove \(attendee.name)")
                    }
                }
                HStack {
                    TextField("Add someone", text: $guest)
                        .onSubmit { add(refine) }
                    Button("Add") { add(refine) }
                        .disabled(guest.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func add(_ refine: RefineInfo) {
        let name = guest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let attendee = RefineInfo.Attendee(name: name)
        if !refine.attendees.contains(attendee) {
            sessions.setAttendees(refine.attendees + [attendee], for: session.id)
        }
        guest = ""
    }
}
