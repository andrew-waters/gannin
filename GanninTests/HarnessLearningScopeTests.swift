import Testing
@testable import Gannin

struct HarnessLearningScopeTests {
    private func learning(_ paths: [String]) -> HarnessLearning? {
        let list = paths.isEmpty ? "" : "paths:\n" + paths.map { "  - \($0.isEmpty ? "\"\"" : $0)" }.joined(separator: "\n") + "\n"
        let text = "---\ntype: learning\nsummary: A rule\nrepo: o/r\n\(list)---\n\n# A rule\n"
        return HarnessLearning(document: HarnessDocument(path: "learnings/r/2026-10-10-a.md", sha: "abc", kind: .learnings, text: text))
    }

    @Test func noPathsIsRepoWide() throws {
        let learning = try #require(learning([]))
        #expect(learning.isRepoWide)
        #expect(learning.covers("any/file.swift"))
    }

    @Test func emptyPathAmongFileScopesIsRepoWide() throws {
        let learning = try #require(learning(["", "a.swift"]))
        #expect(learning.isRepoWide)
        #expect(learning.covers("other.swift"))
    }

    @Test func repoWideLearningIsNotListedAsCoveringAFile() throws {
        #expect(try #require(learning([])).coversForDisplay("any/file.swift") == false)
        #expect(try #require(learning(["", "a.swift"])).coversForDisplay("a.swift") == false)
    }

    @Test func scopedLearningIsListedWhereItCovers() throws {
        let folder = try #require(learning(["Gannin/Sessions/"]))
        #expect(folder.coversForDisplay("Gannin/Sessions/A.swift"))
        #expect(folder.coversForDisplay("Gannin/App/A.swift") == false)
    }

    @Test func scopedLearningIsNotRepoWide() throws {
        #expect(try #require(learning(["Gannin/Sessions/"])).isRepoWide == false)
        #expect(try #require(learning(["a.swift#L1-L2"])).isRepoWide == false)
    }
}
