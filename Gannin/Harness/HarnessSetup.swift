import SwiftUI

/// Opens Set Up Harness in this window, for its org.
struct SetUpHarnessAction: Equatable {
    let window: UUID
    let perform: () -> Void

    func callAsFunction() { perform() }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.window == rhs.window }
}

extension EnvironmentValues {
    @Entry var setUpHarness: SetUpHarnessAction?
}

extension FocusedValues {
    @Entry var setUpHarness: SetUpHarnessAction?
}

/// Gannin › Set Up Harness, in the focused main window, whether or not its
/// org has a project yet, so the flow can be run again without removing one.
struct SetUpHarnessCommand: View {
    @FocusedValue(\.setUpHarness) private var setUpHarness

    var body: some View {
        Button("Set Up Harness") { setUpHarness?() }
            .disabled(setUpHarness == nil)
    }
}

/// Set Up Harness on a page or in the sidebar while the org has no project.
struct SetUpHarnessButton: View {
    @Environment(\.setUpHarness) private var setUpHarness

    var body: some View {
        if let setUpHarness {
            Button("Set Up Harness") { setUpHarness() }
        }
    }
}

/// When Set Up Harness opens by itself: once per launch for an org with no
/// project, until it's put off with Not Now. Kept on this Mac.
enum HarnessSetupPrompt {
    /// Orgs it's opened for since launch, so a second window doesn't open
    /// it again.
    private static var offered: Set<String> = []

    private static func key(_ org: String) -> String { "harnessSetupDeferred.\(org)" }

    /// Takes the org's turn: true the first time it's asked for an org that
    /// hasn't put it off.
    static func claim(_ org: String) -> Bool {
        guard !offered.contains(org), !UserDefaults.standard.bool(forKey: key(org)) else { return false }
        offered.insert(org)
        return true
    }

    static func putOff(_ org: String) {
        UserDefaults.standard.set(true, forKey: key(org))
    }
}

/// What a harness lacks of the layout Gannin starts one with.
enum HarnessSetupCheck {
    /// Every path in `HarnessSkeleton`.
    static var starterPaths: [String] {
        HarnessSkeleton.files(org: "", repo: "", projects: []).keys.sorted()
    }

    /// The starter files not among `present`, in order.
    static func missing(present: Set<String>) -> [String] {
        starterPaths.filter { !present.contains($0) }
    }
}

struct HarnessSetupError: LocalizedError {
    let errorDescription: String?
}

extension GitHubAPI {
    /// `owner/name` as GitHub spells it, once it's found and the token can
    /// push to it: a harness needs write access, not just read.
    func writableHarnessRepo(_ repo: String) async throws -> String {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw HarnessSetupError(errorDescription: "\(repo) isn't owner/name.") }
        let (found, reason) = try await repository(owner: parts[0], name: parts[1])
        guard let found else {
            throw HarnessSetupError(errorDescription: reason ?? "GitHub couldn't find \(repo), or this token can't read it.")
        }
        guard found.hasWriteAccess else {
            throw HarnessSetupError(errorDescription: "You don't have write access to \(found.nameWithOwner), so Gannin can't commit a harness there.")
        }
        return found.nameWithOwner
    }

    /// The starter files the harness's branch doesn't have at `commit`.
    func missingStarterFiles(repo: String, commit: String) async throws -> [String] {
        let tree = try await harnessTree(repo: repo, commit: commit)
        return HarnessSetupCheck.missing(present: Set(tree.map(\.path)))
    }
}
