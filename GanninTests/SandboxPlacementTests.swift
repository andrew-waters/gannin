import Foundation
import Testing
@testable import Gannin

/// Where Work on This sessions run, and repos that need the Mac
/// (andrew-waters/gannin#8, R3, R8).
struct SandboxPlacementTests {
    private func decide(enabled: Bool = true, repos: [String] = ["acme/api"], needingMac: Set<String> = [], token: Bool = true) -> SandboxPlacement {
        SandboxPlacement.decide(enabled: enabled, repos: repos, reposNeedingMac: needingMac, org: "acme", hasGitHubToken: token)
    }

    @Test func sandboxedByDefaultOnceOn() {
        #expect(decide() == .sandboxed)
        #expect(decide(enabled: false) == .host(nil))
    }

    @Test func aRepoNeedingTheMacSaysSo() {
        let placement = decide(repos: ["acme/api", "acme/mac-app"], needingMac: ["acme/mac-app"])
        #expect(!placement.isSandboxed)
        #expect(placement.reason?.contains("acme/mac-app is marked Needs the Mac") == true)
    }

    @Test func noTokenSaysWhereToAddOne() {
        let placement = decide(token: false)
        #expect(!placement.isSandboxed)
        #expect(placement.reason?.contains("Settings, under Harness") == true)
    }

    @Test func aConnectWithThatIsntSSHSaysSo() {
        let placement = SandboxPlacement.decide(enabled: true, repos: ["acme/api"], reposNeedingMac: [], org: "acme", hasGitHubToken: true, connectsBySSH: false)
        #expect(!placement.isSandboxed)
        #expect(placement.reason?.contains("isn't ssh") == true)
    }

    @Test func containersAreNamedByTheSession() {
        let id = UUID(uuidString: "3F9A2C1D-0000-0000-0000-000000000000")!
        #expect(SandboxPlacement.containerName(for: id) == "gannin-3f9a2c1d-0000-0000-0000-000000000000")
    }

    @Test func needsTheMacTravelsInTheTeamFile() {
        var before = OrgConfig()
        before.reposWithoutReview = ["acme/docs"]
        var after = before
        after.reposNeedingMac = ["acme/mac-app"]
        let files = HarnessTeamData.changedFiles(from: before, to: after)
        let text = try? #require(files[TeamFile.exclusions] ?? nil)
        #expect(text?.contains("reposNeedingMac") == true)
        let read = HarnessTeamData(files: [TeamFile.exclusions: text ?? ""]).appliedOrgWide(to: OrgConfig())
        #expect(read.reposNeedingMac == ["acme/mac-app"])
        #expect(read.reposWithoutReview == ["acme/docs"])
        #expect(read.needsMac("acme/mac-app"))
        #expect(!read.needsMac("acme/api"))
    }

    @Test func olderSettingsAndSessionsStillLoad() throws {
        let config = try JSONDecoder().decode(OrgConfig.self, from: Data(#"{"excludedRepos":[]}"#.utf8))
        #expect(config.reposNeedingMac.isEmpty)

        let session = CodeSession(
            id: UUID(), issue: IssueReference(org: "acme", id: "I_1", number: 1, title: "T", repo: "acme/api", url: URL(string: "https://github.com/acme/api/issues/1")!),
            repo: "acme/harness", branch: "1-t", createdAt: .now
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object["sandbox"] = nil
        object["hostReason"] = nil
        let old = try JSONDecoder().decode(CodeSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!old.isSandboxed)
        #expect(old.hostReason == nil)
    }

    @Test func sessionsSayWhereTheyRun() {
        #expect(SessionLocation(sandboxed: false, connect: nil) == .thisMac)
        #expect(SessionLocation(sandboxed: true, connect: nil) == .sandbox)
        #expect(SessionLocation(sandboxed: false, connect: "ssh -t studio") == .server("studio"))
        #expect(SessionLocation(sandboxed: true, connect: "ssh -t -p 2222 -i ~/.ssh/key me@studio.local") == .sandboxOnServer("studio.local"))
        #expect(SessionLocation.serverName("/usr/bin/ssh -o BatchMode=yes devbox") == "devbox")
        #expect(SessionLocation.serverName("mosh devbox") == "mosh devbox")
    }
}
