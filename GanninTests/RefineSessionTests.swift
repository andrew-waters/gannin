import Foundation
import Testing
@testable import Gannin

/// Design and Refine sessions: their name, folder and the page they open.
struct RefineSessionTests {
    @Test func slugIsTheDayAndTheTitle() {
        #expect(SessionStore.refineSlug(title: "Sign-up page!", day: "2026-10-10", taken: []) == "2026-10-10-sign-up-page")
        #expect(SessionStore.refineSlug(title: "✨", day: "2026-10-10", taken: []) == "2026-10-10-page")
        let long = SessionStore.refineSlug(title: String(repeating: "word ", count: 20), day: "2026-10-10", taken: [])
        #expect(long.count <= "2026-10-10-".count + 40)
    }

    @Test func slugTakenTheSameDayGetsANumber() {
        let taken: Set = ["2026-10-10-sign-up-page", "2026-10-10-sign-up-page-2"]
        #expect(SessionStore.refineSlug(title: "Sign-up page", day: "2026-10-10", taken: taken) == "2026-10-10-sign-up-page-3")
        #expect(SessionStore.refineSlug(title: "Sign-up page", day: "2026-10-11", taken: taken) == "2026-10-11-sign-up-page")
    }

    @Test func folderIsUnderWorktrees() {
        #expect(SessionStore.refineFolder(slug: "2026-10-10-sign-up-page") == "refine-2026-10-10-sign-up-page")
    }

    @Test func titleFallsBackToThePage() throws {
        let url = try #require(URL(string: "https://staging.acme.com/signup"))
        #expect(SessionStore.refineTitle(name: "  Sign-up  ", url: url) == "Sign-up")
        #expect(SessionStore.refineTitle(name: "", url: url) == "staging.acme.com/signup")
        let root = try #require(URL(string: "https://acme.com/"))
        #expect(SessionStore.refineTitle(name: "", url: root) == "acme.com")
    }

    @Test func addressesAsTyped() {
        #expect(SessionStore.refineURL("staging.acme.com/signup")?.absoluteString == "https://staging.acme.com/signup")
        #expect(SessionStore.refineURL("localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(SessionStore.refineURL("http://127.0.0.1:8080/a")?.absoluteString == "http://127.0.0.1:8080/a")
        #expect(SessionStore.refineURL("") == nil)
        #expect(SessionStore.refineURL("not a page") == nil)
        #expect(SessionStore.refineURL("file:///etc/hosts") == nil)
        #expect(SessionStore.refineURL("ftp://acme.com") == nil)
    }

    @Test func infoAndAttendeesSurviveSaving() throws {
        let id = UUID()
        var session = CodeSession(
            id: id, issue: IssueReference(org: "acme", id: "refine-\(id.uuidString)", number: 0, title: "Sign-up", repo: "acme/harness",
                                          url: URL(string: "https://github.com/acme/harness")!),
            repo: "acme/harness", branch: "refine-2026-10-10-sign-up", createdAt: .now,
            harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness"
        )
        session.refine = RefineInfo(name: "Sign-up", slug: "2026-10-10-sign-up", url: "https://staging.acme.com/signup", repos: ["acme/app"],
                                    attendees: [.init(name: "Octo Cat", login: "octocat"), .init(name: "Sam from Design")])
        let decoded = try JSONDecoder().decode(CodeSession.self, from: JSONEncoder().encode(session))
        #expect(decoded.isRefine)
        #expect(decoded.refine == session.refine)
        #expect(decoded.refine?.attendees.map(\.id) == ["octocat", "name:Sam from Design"])
        #expect(!decoded.canPairReview)
    }

    @Test func briefNamesThePageCodeAndRoom() {
        let id = UUID()
        var session = CodeSession(
            id: id, issue: IssueReference(org: "acme", id: "refine-\(id.uuidString)", number: 0, title: "Sign-up", repo: "acme/harness",
                                          url: URL(string: "https://github.com/acme/harness")!),
            repo: "acme/harness", branch: "refine-2026-10-10-sign-up", createdAt: .now,
            harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness"
        )
        session.refine = RefineInfo(name: "Sign-up", slug: "2026-10-10-sign-up", url: "https://staging.acme.com/signup", repos: ["acme/app"],
                                    attendees: [.init(name: "Octo Cat", login: "octocat"), .init(name: "Sam from Design")])
        let brief = SessionStore.refineBrief(session)
        #expect(brief.hasPrefix("# Design and Refine: Sign-up"))
        #expect(brief.contains("https://staging.acme.com/signup"))
        #expect(brief.contains("- acme/app, cloned at `projects/app`"))
        #expect(brief.contains("- Octo Cat (@octocat)\n- Sam from Design"))
        #expect(SessionStore.refinePrompt(session).contains("`projects/app`"))
    }
}
