import Foundation
import Testing
@testable import Gannin

/// Set Up Harness's check for the starter files a linked or half-made
/// harness lacks, which it offers to add without touching what's there
/// (andrew-waters/gannin#463).
struct HarnessSetupTests {
    @Test func emptyHarnessLacksEveryStarterFile() {
        #expect(HarnessSetupCheck.missing(present: []) == HarnessSetupCheck.starterPaths)
    }

    @Test func fullLayoutLacksNothing() {
        #expect(HarnessSetupCheck.missing(present: Set(HarnessSetupCheck.starterPaths)).isEmpty)
    }

    @Test func listsOnlyWhatsAbsent() {
        let present: Set<String> = Set(HarnessSetupCheck.starterPaths).subtracting(["STANDARDS.md", "plans/_template.md"])
        #expect(HarnessSetupCheck.missing(present: present) == ["STANDARDS.md", "plans/_template.md"])
    }

    @Test func ignoresTheHarnessesOwnFiles() {
        let present = Set(HarnessSetupCheck.starterPaths).union(["plans/2026-10-23-a-plan.md", ".gannin/project.json"])
        #expect(HarnessSetupCheck.missing(present: present).isEmpty)
    }
}
