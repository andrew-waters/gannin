import Foundation
import Testing
@testable import Gannin

/// Design and Refine records in the harness: a folder per session, its
/// README the document and its screenshots beside it.
struct HarnessRefinesTests {
    private let readme = """
        ---
        type: refine
        status: agreed
        summary: >
          Stepped through the sign-up page and raised three issues.
        url: https://staging.example.com/signup
        attendees: [octocat, Sam from Design]
        issues: [acme/app#12, acme/app#13]
        touches: [acme/app]
        ---

        # Sign-up page

        ## Findings

        - The Save button sits too low: acme/app#12
        """

    @Test func sessionReadmeIndexesAsARefine() {
        #expect(HarnessKind(path: "refines/2026-10-10-x/README.md") == .refines)
        let document = HarnessDocument(path: "refines/2026-10-10-x/README.md", sha: "abc", kind: .refines, text: readme)
        #expect(document.kind == .refines)
        #expect(document.title == "Sign-up page")
        #expect(document.followsStandard)
        #expect(document.frontMatter?["attendees"] == ["octocat", "Sam from Design"])
    }

    @Test func screenshotsAndGuidesAreNotDocuments() {
        #expect(HarnessKind(path: "refines/2026-10-10-x/screenshot-1.png") == nil)
        #expect(HarnessKind(path: "refines/2026-10-10-x/notes.md") == nil)
        #expect(HarnessKind(path: "refines/README.md") == nil)
        #expect(HarnessKind(path: "refines/_template.md") == nil)
    }

    @Test func frontMatterTypeNamesTheKind() {
        #expect(HarnessKind(type: "refine") == .refines)
        #expect(HarnessKind.refines.isRecord)
        #expect(HarnessKind.research.isRecord)
        #expect(!HarnessKind.plans.isRecord)
    }

    @Test func newHarnessesHaveTheFolder() {
        let files = HarnessSkeleton.files(org: "acme", repo: "acme/harness", projects: ["acme/app"])
        #expect(files["refines/README.md"] != nil)
        let template = files["refines/_template.md"].flatMap { $0 } ?? ""
        #expect(template.contains("type: refine"))
        #expect(HarnessTour.layout.contains { $0.name == "refines/" })
    }
}
