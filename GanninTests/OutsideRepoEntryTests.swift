import Foundation
import Testing
@testable import Gannin

/// Typing owner/name in the add-a-repo popover, for a repo the account
/// doesn't own (andrew-waters/gannin#172, R1).
struct OutsideRepoEntryTests {
    @Test func parsesOwnerSlashName() {
        #expect(OutsideRepoEntry.parse("octocat/hello-world", account: "acme", taken: []) == "octocat/hello-world")
    }

    @Test func trimsWhitespace() {
        #expect(OutsideRepoEntry.parse("  octocat/hello-world  ", account: "acme", taken: []) == "octocat/hello-world")
    }

    @Test func rejectsTextWithoutASlash() {
        #expect(OutsideRepoEntry.parse("hello-world", account: "acme", taken: []) == nil)
    }

    @Test func rejectsMoreThanOneSlash() {
        #expect(OutsideRepoEntry.parse("octocat/hello/world", account: "acme", taken: []) == nil)
    }

    @Test func rejectsAnEmptyOwnerOrName() {
        #expect(OutsideRepoEntry.parse("/hello-world", account: "acme", taken: []) == nil)
        #expect(OutsideRepoEntry.parse("octocat/", account: "acme", taken: []) == nil)
    }

    @Test func rejectsTheAccountsOwnRepoCaseAside() {
        #expect(OutsideRepoEntry.parse("Acme/api", account: "acme", taken: []) == nil)
    }

    @Test func rejectsARepoAlreadyInTheProject() {
        #expect(OutsideRepoEntry.parse("octocat/hello-world", account: "acme", taken: ["octocat/hello-world"]) == nil)
    }
}
