import Foundation
import Testing
@testable import Gannin

/// Projects naming repos the account doesn't own: a client's repo an
/// outside collaborator is on, or an open-source repo someone contributes
/// to (andrew-waters/gannin#170, R3, R7, R12).
struct OutsideRepoTests {
    private func project(_ harnessRepo: String, repos: [String]) -> RepoProject {
        RepoProject(harness: HarnessConfig(repo: harnessRepo), name: harnessRepo, repos: repos, boardsRepo: nil)
    }

    @Test func outsideReposForAnOrg() {
        let projects = [project("acme/harness", repos: ["acme/api", "client/app"])]
        #expect(OrgConfig.outsideRepos("acme", in: projects) == ["client/app"])
    }

    @Test func outsideReposForAPersonalAccountIgnoresCase() {
        let projects = [project("alex/harness", repos: ["alex/site", "octocat/hello-world"])]
        #expect(OrgConfig.outsideRepos("Alex", in: projects) == ["octocat/hello-world"])
    }

    @Test func noOutsideReposGivesAnEmptySet() {
        let projects = [project("acme/harness", repos: ["acme/api", "acme/web"])]
        #expect(OrgConfig.outsideRepos("acme", in: projects).isEmpty)
    }

    @Test func aProjectNamingTheOutsideRepoShowsIt() {
        let exclusion = RepoExclusion(excluded: [], focus: ["client/app"], outside: ["client/app"])
        #expect(!exclusion.contains("client/app"))
    }

    @Test func aProjectNamingNoneHidesAnotherProjectsOutsideRepo() {
        // repos: [] means "every repo" (focus nil), but that's the account's
        // own repos, not a different project's outside one.
        let exclusion = RepoExclusion(excluded: [], focus: nil, outside: ["client/app"])
        #expect(exclusion.contains("client/app"))
        #expect(!exclusion.contains("acme/api"))
    }

    @Test func noProjectHidesTheOutsideRepoToo() {
        let exclusion = RepoExclusion(excluded: [], focus: nil, outside: ["client/app"])
        #expect(exclusion.contains("client/app"))
    }

    @Test func anAccountWithNoOutsideReposExcludesAsToday() {
        let before = RepoExclusion(excluded: ["acme/old"], focus: nil)
        let after = RepoExclusion(excluded: ["acme/old"], focus: nil, outside: [])
        #expect(before == after)
        #expect(after.contains("acme/old"))
        #expect(!after.contains("acme/api"))
    }

    // MARK: projectOutsideRepos (andrew-waters/gannin#175, R9)

    @Test func projectOutsideReposIsEmptyWithNoProject() {
        var config = OrgConfig()
        config.outsideRepos = ["client/app"]
        #expect(config.projectOutsideRepos.isEmpty)
    }

    @Test func projectOutsideReposIsEmptyWhenTheProjectNamesNone() {
        var config = OrgConfig()
        config.outsideRepos = ["client/app"]
        config.scope = project("acme/harness", repos: [])
        #expect(config.projectOutsideRepos.isEmpty)
    }

    @Test func projectOutsideReposIsTheIntersectionWithTheProjectsRepos() {
        var config = OrgConfig()
        config.outsideRepos = ["client/app", "other/thing"]
        config.scope = project("acme/harness", repos: ["acme/api", "client/app"])
        #expect(config.projectOutsideRepos == ["client/app"])
    }
}
