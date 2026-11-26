import Foundation
import Testing
@testable import Gannin

/// The PostToolUse hook that records a session's PR, run in sh as Claude Code
/// runs it. Each call is run with `jq` (the JSON is parsed) and without it
/// (`sed` and `grep` on the raw text, in Claude Code's key order), and both
/// must record the same.
struct SessionPullRequestHookTests {
    /// The URLs the script recorded for each input, in the order written.
    private func run(_ inputs: [String], withoutJQ: Bool) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pr-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: ClaudeCodeProvider.pullRequestHookFile)
        try Data(ClaudeCodeProvider.pullRequestHookScript.utf8).write(to: script)
        // A PATH of only what the script uses, so whether jq is there is
        // decided by `withoutJQ`, not by the machine running the tests.
        var environment = ProcessInfo.processInfo.environment
        let bin = folder.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["sed", "grep", "cat", "dirname"] + (withoutJQ ? [] : ["jq"]) {
            let real = Self.find(tool) ?? "/usr/bin/\(tool)"
            try FileManager.default.createSymbolicLink(at: bin.appending(path: tool), withDestinationURL: URL(filePath: real))
        }
        environment["PATH"] = bin.path
        for input in inputs {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = [script.path]
            process.environment = environment
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        let text = (try? String(contentsOf: folder.appending(path: "pr"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// Where a tool is on this Mac, nil if it isn't installed.
    private nonisolated static func find(_ tool: String) -> String? {
        ["/usr/bin/\(tool)", "/bin/\(tool)", "/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    fileprivate nonisolated static let hasJQ = find("jq") != nil

    /// What the hook records with `jq`, checked against what it records
    /// without. Without jq on the machine, only the fallback runs.
    private func recorded(_ inputs: String...) throws -> [String] {
        let fallback = try run(inputs, withoutJQ: true)
        if Self.hasJQ { #expect(try run(inputs, withoutJQ: false) == fallback) }
        return fallback
    }

    private func call(_ tool: String, input: String, response: String) -> String {
        #"{"session_id":"x","cwd":"/w","hook_event_name":"PostToolUse","tool_name":"\#(tool)","tool_input":\#(input),"tool_response":\#(response),"tool_use_id":"t"}"#
    }

    private func bash(_ command: String, stdout: String) -> String {
        call("Bash", input: #"{"command":"\#(command)"}"#, response: #"{"stdout":"\#(stdout)","stderr":""}"#)
    }

    private let other = "https://github.com/ctrl-hub/mono/pull/783"
    private let mine = "https://github.com/andrew-waters/gannin/pull/401"

    @Test func viewingAPullRequestRecordsNothing() throws {
        #expect(try recorded(bash("gh pr view \(other)", stdout: other)) == [])
        #expect(try recorded(bash("gh pr list --search x", stdout: "\(other)\\n\(mine)")) == [])
    }

    @Test func readingAFileThatNamesOneRecordsNothing() throws {
        let read = call("Read", input: #"{"file_path":"notes.md"}"#, response: #"{"content":"run gh pr create, see \#(other)"}"#)
        #expect(try recorded(read) == [])
    }

    @Test func aCommandOnlyMentioningCreateRecordsNothing() throws {
        #expect(try recorded(bash("echo gh pr create", stdout: other)) == [])
    }

    @Test func createRecordsTheCreatedURLNotOneInItsBody() throws {
        let create = bash("gh pr create --title t --body 'Follows \(other)'", stdout: mine)
        #expect(try recorded(create) == [mine])
    }

    @Test func createAfterOtherCommandsIsRecorded() throws {
        #expect(try recorded(bash("git push -u origin HEAD && gh pr create --fill", stdout: mine)) == [mine])
        #expect(try recorded(bash("git push\\ngh pr create --fill", stdout: mine)) == [mine])
    }

    /// What `gh api` prints for a created PR: the whole object as JSON, which
    /// is escaped inside the hook's own JSON, with a body linking `other`.
    private var pullObject: String {
        #"{\"body\":\"Follows \#(other)\",\"html_url\":\"\#(mine)\",\"user\":{\"html_url\":\"https://github.com/andrew-waters\"}}"#
    }

    private let path = "repos/andrew-waters/gannin/pulls"

    @Test func ghApiPostToPullsIsRecordedFromItsHTMLURLOnly() throws {
        #expect(try recorded(bash("gh api \(path) -f title=t", stdout: pullObject)) == [mine])
        #expect(try recorded(bash("gh api \(path) -f title=t -f head=b -f base=main", stdout: pullObject)) == [mine])
        #expect(try recorded(bash("gh api \(path) -F draft=true", stdout: pullObject)) == [mine])
        #expect(try recorded(bash("gh api \(path) --field title=t", stdout: pullObject)) == [mine])
        #expect(try recorded(bash("gh api \(path) --raw-field title=t", stdout: pullObject)) == [mine])
        #expect(try recorded(bash("gh api \(path) --input body.json", stdout: pullObject)) == [mine])
        #expect(try recorded(bash("gh api -X POST \(path)", stdout: pullObject)) == [mine])
        #expect(try recorded(bash("gh api --method POST \(path)", stdout: pullObject)) == [mine])
    }

    @Test func ghApiReadsOfPullsRecordNothing() throws {
        #expect(try recorded(bash("gh api repos/ctrl-hub/mono/pulls", stdout: other)) == [])
        #expect(try recorded(bash("gh api repos/ctrl-hub/mono/pulls --paginate", stdout: other)) == [])
        #expect(try recorded(bash("gh api repos/ctrl-hub/mono/pulls?state=all", stdout: other)) == [])
        #expect(try recorded(bash("gh api repos/ctrl-hub/mono/pulls/783", stdout: other)) == [])
        #expect(try recorded(bash("gh api -X POST repos/ctrl-hub/mono/pulls/783/comments -f body=x", stdout: other)) == [])
    }

    @Test func ghApiGetWithFieldFlagsRecordsNothing() throws {
        let listing = "{\\\"html_url\\\":\\\"\(other)\\\"}"
        #expect(try recorded(bash("gh api repos/o/r/pulls -F head=o:b -F state=all -X GET", stdout: listing)) == [])
        #expect(try recorded(bash("gh api -X GET repos/o/r/pulls -f state=closed -f per_page=100", stdout: listing)) == [])
        #expect(try recorded(bash("gh api repos/o/r/pulls -f state=all -f base=main --method GET", stdout: listing)) == [])
    }

    @Test func flagsOnAnotherCommandInTheCallAreNotThisOnes() throws {
        let listing = "{\\\"html_url\\\":\\\"\(other)\\\"}"
        #expect(try recorded(bash("rm -f out.json && gh api repos/o/r/pulls --paginate", stdout: listing)) == [])
        #expect(try recorded(bash("gh api repos/o/r/pulls --jq .[].number && gh api -X POST repos/o/r/issues/1/comments -f body=x", stdout: listing)) == [])
        #expect(try recorded(bash("gh api repos/o/r/pulls\\ngh api repos/o/r/issues -f title=t", stdout: listing)) == [])
        #expect(try recorded(bash("gh api \(path) -f title=t && gh api -X GET repos/o/r/pulls/1/files", stdout: pullObject)) == [mine])
        #expect(try recorded(bash("gh api \(path) -f title=t\\ngh api -X GET repos/o/r/pulls/1/files", stdout: pullObject)) == [mine])
    }

    @Test func createWithAVariableOrSubshellInFrontIsRecorded() throws {
        #expect(try recorded(bash("url=$(gh pr create --fill)", stdout: mine)) == [mine])
        #expect(try recorded(bash("(cd x && gh pr create --fill)", stdout: mine)) == [mine])
        #expect(try recorded(bash("GH_REPO=o/r gh pr create --fill", stdout: mine)) == [mine])
        #expect(try recorded(bash("A=1 B=2 gh api \(path) -f title=t", stdout: pullObject)) == [mine])
    }

    @Test func formsLeftOutAreNotRecorded() throws {
        #expect(try recorded(bash("./scripts/open-pr.sh", stdout: mine)) == [])
        #expect(try recorded(bash("echo x | xargs gh pr create", stdout: mine)) == [])
        #expect(try recorded(bash("env GH_REPO=o/r gh pr create", stdout: mine)) == [])
    }

    @Test func aPullRequestPerRepoInOneCommandKeepsEach() throws {
        let second = "https://github.com/andrew-waters/harness/pull/5"
        #expect(try recorded(bash("gh pr create --fill; gh pr create --fill", stdout: "\(mine)\\n\(second)")) == [mine, second])
    }

    /// A result with no `stdout`, or the URL on stderr, still holds it.
    @Test func createIsRecordedFromAnyFieldOfItsResult() throws {
        let command = #"{"command":"gh pr create --fill"}"#
        #expect(try recorded(call("Bash", input: command, response: #"{"output":"\#(mine)"}"#)) == [mine])
        #expect(try recorded(call("Bash", input: command, response: #"{"stdout":"","stderr":"\#(mine)"}"#)) == [mine])
        #expect(try recorded(call("Bash", input: command, response: #""\#(mine)""#)) == [mine])
    }

    @Test func aRepeatedURLIsRecordedOnce() throws {
        let create = bash("gh pr create --fill", stdout: mine)
        #expect(try recorded(create, create) == [mine])
    }

    @Test func aPullRequestCreatingToolIsRecorded() throws {
        let created = call("mcp__github__create_pull_request", input: #"{"title":"t","body":"Follows \#(other)"}"#, response: #"{"body":"Follows \#(other)","html_url":"\#(mine)"}"#)
        #expect(try recorded(created) == [mine])
        let short = call("mcp__github__create_pull_request", input: "{}", response: #"{"id":"1","url":"\#(mine)"}"#)
        #expect(try recorded(short) == [mine])
        let wrapped = call("mcp__github__create_pull_request", input: "{}", response: #"[{"type":"text","text":"{\"body\":\"Follows \#(other)\",\"html_url\":\"\#(mine)\"}"}]"#)
        #expect(try recorded(wrapped) == [mine])
    }

    /// What claude.ai's GitHub connector returns: only `html_url` and `id`.
    @Test func theGitHubConnectorsResultIsRecorded() throws {
        let tool = "mcp__claude_ai_Github_MCP__create_pull_request"
        let input = #"{"owner":"ctrl-hub","repo":"mono","body":"Refs ctrl-hub/product#4495"}"#
        let object = call(tool, input: input, response: #"{"html_url":"\#(mine)","id":"5503395085"}"#)
        #expect(try recorded(object) == [mine])
        let text = call(tool, input: input, response: #""{\"html_url\":\"\#(mine)\",\"id\":\"5503395085\"}""#)
        #expect(try recorded(text) == [mine])
        let blocks = call(tool, input: input, response: #"{"content":[{"type":"text","text":"{\"html_url\":\"\#(mine)\",\"id\":\"1\"}"}]}"#)
        #expect(try recorded(blocks) == [mine])
    }

    @Test func aFailedPullRequestToolCallRecordsNothing() throws {
        let failed = call("mcp__claude_ai_Github_MCP__create_pull_request", input: "{}", response: #""failed to create PR, see \#(other)""#)
        #expect(try recorded(failed) == [])
    }

    /// With jq the JSON is parsed, so the order of the keys doesn't matter.
    @Test(.enabled(if: SessionPullRequestHookTests.hasJQ)) func theOrderOfTheKeysDoesNotMatterWithJQ() throws {
        let reordered = #"{"tool_response":{"html_url":"\#(mine)","id":"1"},"tool_use_id":"t","tool_name":"mcp__claude_ai_Github_MCP__create_pull_request","tool_input":{}}"#
        #expect(try run([reordered], withoutJQ: false) == [mine])
    }
}
