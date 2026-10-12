import SwiftUI
import WebKit

/// Each project's own cookies and logins for the pages its Design and
/// Refine sessions open, so a staging login lasts between sessions and
/// stays out of other projects' sessions. The store's identifier is kept
/// on this Mac per harness repo.
enum RefineWebStore {
    private static let key = "refineWebStores"

    private static var identifiers: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The project's store, made the first time it's asked for.
    static func store(for harnessRepo: String) -> WKWebsiteDataStore {
        if let id = identifiers[harnessRepo].flatMap(UUID.init(uuidString:)) {
            return WKWebsiteDataStore(forIdentifier: id)
        }
        let id = UUID()
        identifiers[harnessRepo] = id.uuidString
        return WKWebsiteDataStore(forIdentifier: id)
    }

    /// The projects that have a store.
    static var projects: [String] { identifiers.keys.sorted() }

    /// Signs out of every page the project's sessions opened: its cookies,
    /// storage and cache go, the store stays for the next login.
    static func signOut(_ harnessRepo: String) async {
        guard let id = identifiers[harnessRepo].flatMap(UUID.init(uuidString:)) else { return }
        await clear(WKWebsiteDataStore(forIdentifier: id))
    }

    /// Settings › Storage: signs out of every project's pages.
    static func signOutAll() async {
        for repo in projects { await signOut(repo) }
    }

    private static func clear(_ store: WKWebsiteDataStore) async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

/// The open sessions' pages, kept while the app runs so switching tabs
/// doesn't lose a page's history or reload it.
enum RefinePages {
    private static var pages: [UUID: WebPage] = [:]

    static func page(for session: CodeSession) -> WebPage {
        if let page = pages[session.id] { return page }
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = RefineWebStore.store(for: session.harnessRepo ?? session.repo)
        let page = WebPage(configuration: configuration)
        if let url = (session.refine?.lastURL ?? session.refine?.url).flatMap(URL.init(string:)) {
            page.load(url)
        }
        pages[session.id] = page
        return page
    }

    /// The session was deleted: its page goes with it.
    static func forget(_ id: UUID) {
        pages[id] = nil
    }
}

/// A Design and Refine session's tab: the page in a web view, with back,
/// forward, reload and its address above, beside the findings, and the
/// terminal in a drawer below as planning has it.
struct RefineWorkspaceView: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    @State private var page: WebPage
    @State private var address: String
    @State private var badAddress = false
    @State private var signingOut = false
    @AppStorage("refineShowsTerminal") private var showsTerminal = false
    @FocusState private var editingAddress: Bool

    init(session: CodeSession) {
        self.session = session
        _page = State(initialValue: RefinePages.page(for: session))
        _address = State(initialValue: session.refine?.lastURL ?? session.refine?.url ?? "")
    }

    private var project: String { session.harnessRepo ?? session.repo }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            VSplitView {
                FixedSplit(key: "refineFindingsWidth", width: 400, range: 300...640, fixing: .trailing) {
                    WebView(page)
                } trailing: {
                    RefineFindingsPanel(session: session, page: page)
                }
                .frame(minHeight: 320, maxHeight: .infinity)
                if showsTerminal {
                    VStack(spacing: 0) {
                        TerminalHost(session: session)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        SessionComposer(session: session)
                    }
                    .frame(minHeight: 160, idealHeight: 240, maxHeight: .infinity)
                }
            }
        }
        // Starts claude with the terminal put away, as opening the tab did.
        .onAppear { _ = sessions.open(session) }
        // The page shown is the one to reopen on.
        .onChange(of: page.url) { _, url in
            guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            if !editingAddress { address = url.absoluteString }
            if session.refine?.lastURL != url.absoluteString {
                sessions.update(session.id) { $0.refine?.lastURL = url.absoluteString }
            }
        }
        .confirmationDialog("Sign out of pages?", isPresented: $signingOut) {
            Button("Sign Out of Pages", role: .destructive) {
                Task {
                    await RefineWebStore.signOut(project)
                    page.reload()
                }
            }
        } message: {
            Text("Forgets the logins, cookies and storage of every page this project's sessions opened. Other projects stay signed in.")
        }
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button {
                    if let item = page.backForwardList.backList.last { page.load(item) }
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(page.backForwardList.backList.isEmpty)
                .help("Back")
                Button {
                    if let item = page.backForwardList.forwardList.first { page.load(item) }
                } label: {
                    Label("Forward", systemImage: "chevron.forward")
                }
                .disabled(page.backForwardList.forwardList.isEmpty)
                .help("Forward")
            }
            .fixedSize()
            Button {
                if page.isLoading { page.stopLoading() } else { page.reload() }
            } label: {
                Label(page.isLoading ? "Stop" : "Reload", systemImage: page.isLoading ? "xmark" : "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help(page.isLoading ? "Stop loading" : "Reload the page")
            TextField("Address", text: $address, prompt: Text("https://staging.example.com/signup"))
                .textFieldStyle(.roundedBorder)
                .focused($editingAddress)
                .onSubmit(go)
                .onChange(of: address) { badAddress = false }
                .overlay(alignment: .trailing) {
                    if badAddress {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .padding(.trailing, 6)
                            .help("That doesn't look like a web page's address")
                    }
                }
            Menu {
                if let url = page.url {
                    Link("Open Page in Browser", destination: url)
                }
                Divider()
                Button("Sign Out of Pages…") { signingOut = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open the page in your browser, or sign out of this project's pages")
            Toggle(isOn: $showsTerminal.animation()) {
                Label("Terminal", systemImage: "terminal")
            }
            .toggleStyle(.button)
            .help(showsTerminal ? "Put the terminal away" : "Show the terminal and its composer")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func go() {
        guard let url = SessionStore.refineURL(address) else {
            badAddress = true
            return
        }
        editingAddress = false
        page.load(url)
    }
}
