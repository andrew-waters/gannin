import Testing
@testable import Gannin

/// What a watched review says has changed since it ran.
struct ReviewWatchTests {
    @Test func nothingChangedIsNil() {
        #expect(ReviewWatch().changes == nil)
    }

    @Test func newCommitsAreNamed() {
        var watch = ReviewWatch()
        watch.hasNewCommits = true
        #expect(watch.changes == "new commits")
    }

    @Test func commentsAreCountedAndPluralised() {
        var watch = ReviewWatch()
        watch.newComments = 1
        #expect(watch.changes == "1 new comment")
        watch.newComments = 3
        #expect(watch.changes == "3 new comments")
    }

    @Test func commitsAndCommentsAreListedTogether() {
        var watch = ReviewWatch()
        watch.hasNewCommits = true
        watch.newComments = 2
        #expect(watch.changes == "new commits, 2 new comments")
    }
}
