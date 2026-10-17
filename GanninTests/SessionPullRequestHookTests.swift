import Foundation
import Testing
@testable import Gannin

/// The PostToolUse hook that records a session's PR, run in sh as Claude Code
/// runs it, with a tool call on standard input in Claude Code's key order.
struct SessionPullRequestHookTests {
    /// The URLs the hook recorded for `input`, in the order written.
    private func recorded(_ inputs: String...) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pr-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for input in inputs {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", SessionScript.pullRequestHook(directory: folder.path)]
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

    @Test func ghApiPostToPullsIsRecorded() throws {
        let path = "repos/andrew-waters/gannin/pulls"
        #expect(try recorded(bash("gh api \(path) -f title=t -f head=b -f base=main", stdout: mine)) == [mine])
        #expect(try recorded(bash("gh api -X POST \(path) --input body.json", stdout: mine)) == [mine])
        #expect(try recorded(bash("gh api --method POST \(path)", stdout: mine)) == [mine])
    }

    @Test func ghApiReadsOfPullsRecordNothing() throws {
        #expect(try recorded(bash("gh api repos/ctrl-hub/mono/pulls", stdout: other)) == [])
        #expect(try recorded(bash("gh api repos/ctrl-hub/mono/pulls --paginate", stdout: other)) == [])
        #expect(try recorded(bash("gh api repos/ctrl-hub/mono/pulls/783", stdout: other)) == [])
        #expect(try recorded(bash("gh api -X POST repos/ctrl-hub/mono/pulls/783/comments -f body=x", stdout: other)) == [])
    }

    @Test func aPullRequestPerRepoInOneCommandKeepsEach() throws {
        let second = "https://github.com/andrew-waters/harness/pull/5"
        #expect(try recorded(bash("gh pr create --fill; gh pr create --fill", stdout: "\(mine)\\n\(second)")) == [mine, second])
    }

    @Test func aRepeatedURLIsRecordedOnce() throws {
        let create = bash("gh pr create --fill", stdout: mine)
        #expect(try recorded(create, create) == [mine])
    }

    @Test func aPullRequestCreatingToolIsRecorded() throws {
        let created = call("mcp__github__create_pull_request", input: #"{"title":"t","body":"Follows \#(other)"}"#, response: #"{"html_url":"\#(mine)"}"#)
        #expect(try recorded(created) == [mine])
    }
}
