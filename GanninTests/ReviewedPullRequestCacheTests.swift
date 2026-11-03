import Foundation
import Testing
@testable import Gannin

/// Reopening a review shows its last fetch, and keeps it when a fresh one matches.
struct ReviewedPullRequestCacheTests {
    private func pullRequest(sha: String = "abc", title: String = "Title", comments: [ReviewedPullRequest.ExistingComment] = []) -> ReviewedPullRequest {
        ReviewedPullRequest(title: title, body: "", author: nil, headSHA: sha, additions: 0, deletions: 0, state: "open", files: [], existingComments: comments)
    }

    private func comment(_ id: Int) -> ReviewedPullRequest.ExistingComment {
        ReviewedPullRequest.ExistingComment(id: id, path: "A.swift", line: 1, isOld: false, body: "x", author: "a", avatarURL: nil, createdAt: .distantPast, url: nil)
    }

    @Test func storesByIDAndReplacesAnEarlierFetch() {
        var cache = ReviewedPullRequestCache()
        cache.store(pullRequest(sha: "one"), for: "r#1")
        cache.store(pullRequest(sha: "two"), for: "r#1")
        #expect(cache["r#1"]?.headSHA == "two")
        #expect(cache["r#2"] == nil)
    }

    @Test func keepsOnlyTheMostRecentlyStored() {
        var cache = ReviewedPullRequestCache()
        for number in 0...ReviewedPullRequestCache.capacity {
            cache.store(pullRequest(), for: "r#\(number)")
        }
        #expect(cache["r#0"] == nil)
        #expect(cache["r#\(ReviewedPullRequestCache.capacity)"] != nil)
        // Storing again makes it the newest, so the next one pushes out another.
        cache.store(pullRequest(), for: "r#1")
        cache.store(pullRequest(), for: "r#new")
        #expect(cache["r#1"] != nil)
        #expect(cache["r#2"] == nil)
    }

    @Test func sameContentIgnoresNothingThatChangesWhatShows() {
        let base = pullRequest()
        #expect(base.hasSameContent(as: pullRequest()))
        #expect(!base.hasSameContent(as: pullRequest(sha: "def")))
        #expect(!base.hasSameContent(as: pullRequest(title: "Other")))
        #expect(!base.hasSameContent(as: pullRequest(comments: [comment(1)])))
        #expect(pullRequest(comments: [comment(1)]).hasSameContent(as: pullRequest(comments: [comment(1)])))
    }
}
