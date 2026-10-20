import Foundation
import Testing
@testable import Gannin

/// Which runs of a check a session's pull request shows once some were re-run.
struct SessionCheckRollupTests {
    private func run(_ name: String, workflow: String, conclusion: String?, startedAt: String?) -> String {
        let status = conclusion == nil ? "QUEUED" : "COMPLETED"
        let conclusionJSON = conclusion.map { "\"\($0)\"" } ?? "null"
        let startedJSON = startedAt.map { "\"\($0)\"" } ?? "null"
        return """
        {"__typename": "CheckRun", "name": "\(name)", "status": "\(status)", "conclusion": \(conclusionJSON),
         "detailsUrl": "https://github.com/acme/app/actions/runs/1", "startedAt": \(startedJSON),
         "checkSuite": {"workflowRun": {"databaseId": 1, "workflow": {"name": "\(workflow)"}}}}
        """
    }

    private func checks(_ contexts: [String]) throws -> [SessionPullRequest.Check] {
        let json = """
        {"id": "PR_1", "number": 7, "title": "T", "url": "https://github.com/acme/app/pull/7", "state": "OPEN",
         "repository": {"nameWithOwner": "acme/app"},
         "commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {"nodes": [\(contexts.joined(separator: ","))]}}}}]}}
        """
        let raw = try JSONDecoder().decode(SessionRawPullRequest.self, from: Data(json.utf8))
        return try #require(raw.model).checks
    }

    @Test func aFailedRunReplacedByANewerPassingOneIsNotListed() throws {
        let result = try checks([
            run("build", workflow: "CI", conclusion: "FAILURE", startedAt: "2026-10-20T09:00:00Z"),
            run("build", workflow: "CI", conclusion: "SUCCESS", startedAt: "2026-10-20T09:30:00Z"),
        ])
        #expect(result.map(\.state) == [.passed])
    }

    @Test func theNewestRunWinsWhateverOrderGitHubListsThem() throws {
        let result = try checks([
            run("build", workflow: "CI", conclusion: "SUCCESS", startedAt: "2026-10-20T09:30:00Z"),
            run("build", workflow: "CI", conclusion: "FAILURE", startedAt: "2026-10-20T09:00:00Z"),
        ])
        #expect(result.map(\.state) == [.passed])
    }

    @Test func aQueuedReRunWithoutAStartTimeReplacesTheFailureItRetries() throws {
        let result = try checks([
            run("build", workflow: "CI", conclusion: "FAILURE", startedAt: "2026-10-20T09:00:00Z"),
            run("build", workflow: "CI", conclusion: nil, startedAt: nil),
        ])
        #expect(result.map(\.state) == [.pending])
    }

    @Test func sameNamedChecksInDifferentWorkflowsAreBothKept() throws {
        let result = try checks([
            run("test", workflow: "CI", conclusion: "FAILURE", startedAt: "2026-10-20T09:00:00Z"),
            run("test", workflow: "Nightly", conclusion: "SUCCESS", startedAt: "2026-10-20T09:30:00Z"),
        ])
        #expect(result.map(\.state) == [.failed, .passed])
    }

    @Test func aStatusAndACheckRunWithTheSameNameAreBothKept() throws {
        let status = #"{"__typename": "StatusContext", "context": "build", "state": "FAILURE", "targetUrl": "https://ci.example/1", "createdAt": "2026-10-20T09:00:00Z"}"#
        let result = try checks([status, run("build", workflow: "CI", conclusion: "SUCCESS", startedAt: "2026-10-20T09:30:00Z")])
        #expect(result.map(\.state) == [.failed, .passed])
    }
}
