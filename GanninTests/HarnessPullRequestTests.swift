import Foundation
import Testing
@testable import Gannin

struct HarnessPullRequestTests {
    @Test func slugStopsBeforeCuttingAWord() {
        #expect(Slug.make("Plan: Time off for alex", limit: 40) == "plan-time-off-for-alex")
        #expect(Slug.make("one two three", limit: 7) == "one-two")
        #expect(Slug.make("one two three", limit: 3) == "one")
        #expect(Slug.make("abcdef", limit: 3) == "")
    }

    @Test func slugDropsNonASCIIAndEmpty() {
        #expect(Slug.make("", limit: 10) == "")
        #expect(Slug.make("日本語", limit: 10) == "")
        #expect(Slug.make("café au lait", limit: 20) == "caf-au-lait")
    }

    @Test func branchNameHasSlugAndEightHexSuffix() {
        let name = HarnessStore.pullRequestBranchName(title: "Plan: Ship it")
        #expect(name.hasPrefix("gannin-plan-ship-it-"))
        let suffix = name.dropFirst("gannin-plan-ship-it-".count)
        #expect(suffix.count == 8)
        #expect(suffix.allSatisfy { $0.isHexDigit })
        #expect(HarnessStore.pullRequestBranchName(title: "Plan: Ship it") != name)
    }

    @Test func branchNameWithNoSlugIsJustTheSuffix() {
        let name = HarnessStore.pullRequestBranchName(title: "日本語")
        #expect(name.hasPrefix("gannin-"))
        #expect(name.count == "gannin-".count + 8)
    }

    @Test func mergeRefusalsSayWhy() {
        #expect(HarnessStore.mergeFailureNote(APIError.http(status: 405, body: #"{"message":"Required status check is expected."}"#)).contains("reviews or checks"))
        #expect(HarnessStore.mergeFailureNote(APIError.http(status: 422, body: #"{"message":"Pull Request is not mergeable"}"#)).contains("reviews or checks"))
        #expect(HarnessStore.mergeFailureNote(APIError.http(status: 405, body: #"{"message":"Merge conflict"}"#)).contains("conflict"))
        #expect(HarnessStore.mergeFailureNote(APIError.http(status: 405, body: #"{"message":"Merge commits are not allowed on this repository."}"#)).contains("merge method"))
    }

    @Test func otherMergeFailuresAreUnknown() {
        let errors: [Error] = [APIError.http(status: 500, body: ""), APIError.network("offline"), APIError.unauthorized]
        for error in errors {
            #expect(HarnessStore.mergeFailureNote(error).contains("couldn't tell"))
        }
    }

    @Test func commitRefusedForNeedingAPullRequest() {
        #expect(APIError.graphQL(["Changes must be made through a pull request."]).requiresPullRequest)
        #expect(APIError.graphQL(["Repository rule violations found for refs/heads/main."]).requiresPullRequest)
        #expect(!APIError.graphQL(["Expected branch to point to abc"]).requiresPullRequest)
        #expect(!APIError.graphQL(["Could not resolve to a Repository."]).requiresPullRequest)
        #expect(APIError.graphQL(["Expected branch to point to abc", "Changes must be made through a pull request."]).requiresPullRequest)
        #expect(APIError.graphQL(["Something else", "Repository rule violations found."]).requiresPullRequest)
        #expect(!APIError.http(status: 403, body: "").requiresPullRequest)
    }

    @Test func onlyANamedPullRequestIsCertain() {
        #expect(APIError.graphQL(["Changes must be made through a pull request."]).namesPullRequest)
        #expect(!APIError.graphQL(["Repository rule violations found for refs/heads/main."]).namesPullRequest)
        #expect(!APIError.graphQL(["Could not resolve to a Repository."]).namesPullRequest)
    }

    @Test func madeIssueRestoredOnlyForTheSameTask() {
        var issue = PlanningMadeIssue(id: "I_1", reference: "o/r#1", url: URL(string: "https://github.com/o/r/issues/1")!, title: "Add login", linked: false)
        #expect(issue.restore(forTitle: "Add login") == .linkPending)
        #expect(issue.restore(forTitle: "Add logout") == .ignore)
        issue.linked = true
        #expect(issue.restore(forTitle: "Add login") == .done)
        issue.title = nil
        #expect(issue.restore(forTitle: "Add login") == .ignore)
    }
}
