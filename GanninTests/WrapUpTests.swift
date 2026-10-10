import Foundation
import Testing
@testable import Gannin

/// Wrapping a session up as its tab closes: which sessions ask, and ticking
/// off a plan's items.
struct WrapUpTests {
    private let plan = """
    ---
    type: plan
    summary: A plan.
    notes:
      - [ ] not an item, in front matter
    ---

    # The plan

    - [ ] Parse the checklist
    - [x] Tick by words
      - [ ] Nested one
    * [X] Starred and upper case

    ```markdown
    - [ ] Not an item, in code
    ```

    - [ ] Same words
    - [ ] Same words
    - [ ]
    """

    @Test func readsItemsOutsideFrontMatterAndCode() {
        let items = HarnessChecklist.items(in: plan)
        #expect(items.map(\.text) == ["Parse the checklist", "Tick by words", "Nested one", "Starred and upper case", "Same words", "Same words"])
        #expect(items.map(\.isDone) == [false, true, false, true, false, false])
        #expect(items[2].indent == 2)
        #expect(items[4].id != items[5].id)
    }

    @Test func ticksByWordsAndLeavesTheRest() {
        let items = HarnessChecklist.items(in: plan)
        let changed = HarnessChecklist.setting([items[0].id: true, items[1].id: false, items[5].id: true], in: plan)
        let after = HarnessChecklist.items(in: changed)
        #expect(after.map(\.isDone) == [true, false, false, true, false, true])
        #expect(changed.contains("- [ ] not an item, in front matter"))
        #expect(changed.contains("- [ ] Not an item, in code"))
        #expect(changed.components(separatedBy: "\n").count == plan.components(separatedBy: "\n").count)
    }

    @Test func ticksLandWhereTheItemHasMoved() {
        let items = HarnessChecklist.items(in: plan)
        // Someone added a line above it since it was read.
        let moved = plan.replacingOccurrences(of: "# The plan\n", with: "# The plan\n\n- [ ] Added since\n")
        let changed = HarnessChecklist.setting([items[0].id: true], in: moved)
        #expect(changed.contains("- [x] Parse the checklist"))
        #expect(changed.contains("- [ ] Added since"))
    }

    @Test func unchangedWhenNothingDiffers() {
        let items = HarnessChecklist.items(in: plan)
        #expect(HarnessChecklist.setting([items[1].id: true, "0:Gone": true], in: plan) == plan)
    }

    @Test func onlyAnIssuesOwnSessionAsks() {
        let issue = IssueReference(org: "acme", id: "I_12", number: 12, title: "Wrap up", repo: "acme/app",
                                   url: URL(string: "https://github.com/acme/app/issues/12")!)
        var session = CodeSession(
            id: UUID(), issue: issue, repo: "acme/harness", branch: "12-wrap-up", createdAt: .now,
            harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness"
        )
        #expect(SessionStore.offersWrapUp(session))
        var helper = session
        helper.parentID = UUID()
        #expect(!SessionStore.offersWrapUp(helper))
        session.ask = AskInfo(title: "Anything", slug: "2026-10-10-3f9a2c1d", message: "Hello")
        #expect(!SessionStore.offersWrapUp(session))
    }

    @Test func tickOffPromptNamesTheDocuments() {
        let prompt = SessionStore.tickOffPrompt(["plans/2026-10-10-a.md", "requirements/a.md"])
        #expect(prompt.contains("- plans/2026-10-10-a.md"))
        #expect(prompt.contains("- requirements/a.md"))
        #expect(prompt.contains("- [x]"))
    }
}
