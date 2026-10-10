import Foundation
import Testing
@testable import Gannin

/// Typing owner/name in Settings' Add Project popover, for a harness repo
/// the token can write to, whether or not the account owns it
/// (andrew-waters/gannin#207).
struct HarnessRepoEntryTests {
    @Test func parsesOwnerSlashName() {
        #expect(HarnessRepoEntry.parse("client/harness", taken: []) == "client/harness")
    }

    @Test func doesntExcludeTheAccountsOwnRepo() {
        // Unlike OutsideRepoEntry: the account's own repos are a valid
        // harness too, just normally offered through harnessChoices
        // instead of typed.
        #expect(HarnessRepoEntry.parse("acme/harness", taken: []) == "acme/harness")
    }

    @Test func trimsWhitespace() {
        #expect(HarnessRepoEntry.parse("  client/harness  ", taken: []) == "client/harness")
    }

    @Test func rejectsTextWithoutASlash() {
        #expect(HarnessRepoEntry.parse("harness", taken: []) == nil)
    }

    @Test func rejectsMoreThanOneSlash() {
        #expect(HarnessRepoEntry.parse("client/team/harness", taken: []) == nil)
    }

    @Test func rejectsAnEmptyOwnerOrName() {
        #expect(HarnessRepoEntry.parse("/harness", taken: []) == nil)
        #expect(HarnessRepoEntry.parse("client/", taken: []) == nil)
    }

    @Test func rejectsARepoAlreadyAProject() {
        #expect(HarnessRepoEntry.parse("client/harness", taken: ["client/harness"]) == nil)
    }
}

/// Whether a repo lookup's viewerPermission lets Gannin commit a harness
/// there (andrew-waters/gannin#207).
struct OutsideRepoLookupWriteAccessTests {
    private func lookup(_ viewerPermission: String?) -> OutsideRepoLookup {
        OutsideRepoLookup(nameWithOwner: "client/harness", isArchived: false, viewerPermission: viewerPermission)
    }

    @Test func adminMaintainAndWriteCanCommit() {
        #expect(lookup("ADMIN").hasWriteAccess)
        #expect(lookup("MAINTAIN").hasWriteAccess)
        #expect(lookup("WRITE").hasWriteAccess)
    }

    @Test func readAndTriageCant() {
        #expect(!lookup("READ").hasWriteAccess)
        #expect(!lookup("TRIAGE").hasWriteAccess)
    }

    @Test func noPermissionCant() {
        #expect(!lookup(nil).hasWriteAccess)
    }

    @Test func isCaseInsensitive() {
        #expect(lookup("write").hasWriteAccess)
        #expect(lookup("Write").hasWriteAccess)
    }
}
