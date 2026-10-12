import Foundation
import Testing
@testable import Gannin

/// What Agree writes for a Design and Refine session: the record in the
/// harness and each issue's links to its screenshots.
struct RefineDocumentsTests {
    private let ticked = RefineInfo.Screenshot(file: "screenshot-1.png", url: "https://staging.acme.com/signup", at: .now)
    private let unticked = RefineInfo.Screenshot(file: "screenshot-2.jpg", url: "https://staging.acme.com/signup", at: .now)

    private func info() -> RefineInfo {
        var info = RefineInfo(name: "Sign-up page", slug: "2026-10-10-sign-up-page", url: "https://staging.acme.com/signup", repos: ["acme/app", "acme/web"],
                              attendees: [.init(name: "Octo Cat", login: "octocat"), .init(name: "Sam: from [Design], #2")])
        info.screenshots = [ticked, unticked]
        info.findings = [
            .init(note: "The Save button sits below the fold", url: "https://staging.acme.com/signup", pageTitle: "Sign up", at: .now, screenshots: [ticked.id, unticked.id]),
            .init(note: "Error text is low contrast", url: "https://staging.acme.com/signup", pageTitle: nil, at: .now, suggestion: "s1"),
            .init(note: "Left for later", url: "https://staging.acme.com/signup", pageTitle: nil, at: .now),
        ]
        info.state = RefineState(scouting: [.init(finding: info.findings[0].id.uuidString, files: ["acme/web:src/Signup.tsx#L40"], components: ["SignupForm"], why: "Its footer")])
        return info
    }

    @Test func recordIndexesAsARefine() throws {
        let info = info()
        let made: [String: RefineInfo.MadeIssue] = [
            info.findings[0].id.uuidString: .init(id: "I_1", reference: "acme/web#12", url: URL(string: "https://github.com/acme/web/issues/12")!),
            info.findings[1].id.uuidString: .init(id: "I_2", reference: "acme/app#13", url: URL(string: "https://github.com/acme/app/issues/13")!),
        ]
        let readme = RefineDocuments.readme(info, made: made, ticked: [ticked.id], day: "2026-10-10")
        let document = HarnessDocument(path: RefineDocuments.readmePath(info), sha: "abc", kind: .refines, text: readme)
        #expect(RefineDocuments.readmePath(info) == "refines/2026-10-10-sign-up-page/README.md")
        #expect(document.followsStandard)
        #expect(document.title == "Sign-up page")
        #expect(document.frontMatter?["issues"] == ["acme/web#12", "acme/app#13"])
        #expect(document.frontMatter?["attendees"] == ["octocat", "Sam: from [Design], #2"])
        #expect(document.frontMatter?["url"] == ["https://staging.acme.com/signup"])
        #expect(document.frontMatter?["touches"] == ["acme/app", "acme/web"])
        #expect(readme.contains("[acme/web#12](https://github.com/acme/web/issues/12) ([screenshot-1](./screenshot-1.png))"))
        #expect(!readme.contains("screenshot-2"))
        #expect(readme.contains("Error text is low contrast (Claude's suggestion): [acme/app#13]"))
        #expect(readme.contains("Left for later (not raised)"))
        #expect(readme.contains("- Sam: from [Design], #2"))
    }

    @Test func issueLinksOnlyItsTickedScreenshots() {
        let info = info()
        let body = RefineDocuments.issueBody(info.findings[0], info: info, screenshots: [ticked], harnessRepo: "acme/harness")
        #expect(body.hasPrefix("The Save button sits below the fold\n\nSeen on [Sign up](https://staging.acme.com/signup)."))
        #expect(body.contains("- `acme/web:src/Signup.tsx#L40`"))
        #expect(body.contains("![screenshot-1.png](https://github.com/acme/harness/blob/HEAD/refines/2026-10-10-sign-up-page/screenshot-1.png?raw=true)"))
        #expect(!body.contains("screenshot-2"))
        #expect(body.hasSuffix("[Sign-up page](https://github.com/acme/harness/blob/HEAD/refines/2026-10-10-sign-up-page/README.md)."))
        let bare = RefineDocuments.issueBody(info.findings[2], info: info, screenshots: [], harnessRepo: "acme/harness")
        #expect(!bare.contains("Screenshots"))
    }

    @Test func repoComesFromScouting() {
        let info = info()
        #expect(RefineDocuments.repo(for: info.findings[0], info: info) == "acme/web")
        #expect(RefineDocuments.repo(for: info.findings[1], info: info) == "acme/app")
    }

    @Test func titlesFitAndBatchesSplit() {
        #expect(RefineDocuments.title("Short\nand more") == "Short")
        let long = RefineDocuments.title(String(repeating: "word ", count: 30))
        #expect(long.count <= 80)
        #expect(long.hasSuffix("..."))
        let files = (0..<5).map { (path: "f\($0)", data: Data(count: 1_500_000)) }
        let batches = RefineDocuments.batches(files, limit: 4_000_000)
        #expect(batches.map(\.count) == [2, 2, 1])
        #expect(RefineDocuments.batches([]).isEmpty)
    }
}
