import Foundation
import Testing
@testable import Gannin

/// Session rules: the hook Gannin writes into a session's settings, run in
/// bash as Claude Code runs it, with a tool call on standard input.
struct SessionRulesTests {
    private let branch = "129-session-rules"

    private func everything(limit: Int? = nil, custom: [SessionRules.Custom] = []) -> SessionRules {
        var rules = SessionRules()
        rules.noForcePush = true
        rules.pushOnlyToBranch = true
        rules.noDeletes = true
        rules.noReleaseWrites = true
        rules.commentLimit = limit
        rules.custom = custom
        return rules
    }

    /// What the hook decides for `input`: "deny: <rule>", "ask: <rule>", or
    /// nil when it lets the call through.
    private func decide(_ rules: SessionRules, _ input: String, folder: URL? = nil) throws -> String? {
        let folder = folder ?? FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let command = try #require(rules.hookCommand(directory: SessionScript.quoted(folder.path), branch: branch))
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        guard !data.isEmpty,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["hookSpecificOutput"] as? [String: Any],
              let decision = output["permissionDecision"] as? String,
              let reason = output["permissionDecisionReason"] as? String else { return nil }
        let rule = SessionRules.blockedRule(in: reason) ?? reason.components(separatedBy: "“").dropFirst().first?.components(separatedBy: "”").first ?? reason
        return "\(decision): \(rule)"
    }

    private func bash(_ command: String) -> String {
        let object: [String: Any] = ["session_id": "x", "tool_name": "Bash", "tool_input": ["command": command, "description": "d"]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }

    @Test func noRulesMeansNoHook() {
        #expect(SessionRules().isEmpty)
        #expect(SessionRules().hookCommand(directory: "/tmp/s", branch: branch) == nil)
        let json = SessionScript.settings(directory: "/tmp/s", isRemote: true)
        #expect(!json.contains("base64 -d"))
        var blank = SessionRules()
        blank.custom = [.init(name: "Nothing", pattern: "  ")]
        #expect(blank.isEmpty)
    }

    @Test func settingsCheckRulesFirst() throws {
        let hook = try #require(everything().hookCommand(directory: "/tmp/s", branch: branch))
        let json = SessionScript.settings(directory: "/tmp/s", isRemote: true, rules: hook)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let pre = try #require((object["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 3)
        #expect(pre.first?["matcher"] as? String == SessionRules.matcher)
    }

    @Test func forcePushIsBlocked() throws {
        let rules = everything()
        for command in ["git push --force origin \(branch)", "git push -f", "git push origin +\(branch)", "git push --force-with-lease", "git status && git push -uf origin HEAD", "/usr/bin/git push -f", "git push -fu origin \(branch)", "git push \"-f\" origin \(branch)", "\"git\" push -f", "git\tpush\t-f"] {
            #expect(try decide(rules, bash(command)) == "deny: No force push", "\(command)")
        }
        #expect(try decide(rules, bash("git commit -m \"don't git push --force\"")) == nil)
    }

    @Test func pushesOnlyToTheSessionsBranch() throws {
        let rules = everything()
        for command in ["git push origin HEAD:\(branch)", "git push -u origin \(branch)", "git push origin HEAD:refs/heads/\(branch)", "git push --follow-tags origin HEAD:\(branch)"] {
            #expect(try decide(rules, bash(command)) == nil, "\(command)")
        }
        // A bare push or HEAD pushes whatever is checked out when it runs.
        for command in ["git push origin main", "cd x && git push origin HEAD:main", "git -c user.name=x push origin main", "git push --tags", "git push --all origin", "git push", "git push origin", "git push origin HEAD", "git switch main && git push"] {
            #expect(try decide(rules, bash(command)) == "deny: \(SessionRules.Name.branch)", "\(command)")
        }
    }

    @Test func deletesAreBlocked() throws {
        let rules = everything()
        for command in ["git branch -D old", "git branch -d old", "git tag -d v1", "git push origin --delete old", "gh api -X DELETE repos/a/b/git/refs/heads/old", "gh api --method delete repos/a/b/git/refs/heads/old", "git branch -dr origin/x", "git tag -dx v1", "git branch -Dq x", "git update-ref -d refs/heads/x", "git push --prune origin \(branch)"] {
            #expect(try decide(rules, bash(command)) == "deny: \(SessionRules.Name.deletes)", "\(command)")
        }
        #expect(try decide(rules, bash("git branch new-thing")) == nil)
        #expect(try decide(rules, bash("git tag v1")) == nil)
        #expect(try decide(rules, bash("git branch -m a b")) == nil)
    }

    @Test func configThatChangesPushIsBlocked() throws {
        let rules = everything()
        for command in ["git -c remote.origin.push=HEAD:main push origin \(branch)", "git -c alias.p=x p", "git config push.default matching", "git config alias.p 'push --force'"] {
            #expect(try decide(rules, bash(command)) == "deny: \(SessionRules.Name.guardRule)", "\(command)")
        }
        #expect(try decide(rules, bash("git config user.name x")) == nil)
        #expect(try decide(rules, bash("git config --get alias.p")) == nil)
    }

    @Test func releaseWritesAreBlocked() throws {
        let rules = everything()
        #expect(try decide(rules, bash("gh release create v1")) == "deny: \(SessionRules.Name.releases)")
        #expect(try decide(rules, bash("gh api repos/a/b/releases -f tag_name=v1")) == "deny: \(SessionRules.Name.releases)")
        #expect(try decide(rules, bash("gh release -R o/r create v1")) == "deny: \(SessionRules.Name.releases)")
        #expect(try decide(rules, bash("gh release view v1")) == nil)
        #expect(try decide(rules, bash("gh api repos/a/b/releases")) == nil)
        #expect(try decide(rules, bash("gh api -X GET repos/a/b/releases")) == nil)
    }

    @Test func commentLimitAllowsUpToItThenBlocks() throws {
        let rules = everything(limit: 2)
        let folder = FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString)")
        #expect(try decide(rules, bash("gh pr comment 1 -b hi"), folder: folder) == nil)
        #expect(try decide(rules, bash("gh pr view 1"), folder: folder) == nil)
        #expect(try decide(rules, bash("gh pr --repo o/r review 1 --comment -b again"), folder: folder) == nil)
        #expect(try decide(rules, bash("gh api repos/a/b/issues/1/comments -f body=x"), folder: folder) == "deny: \(SessionRules.Name.comments(2))")
        let mcp = #"{"tool_name":"mcp__github__add_issue_comment","tool_input":{"body":"x"}}"#
        #expect(try decide(rules, mcp, folder: folder) == "deny: \(SessionRules.Name.comments(2))")
        #expect(try decide(rules, #"{"tool_name":"mcp__github__get_me","tool_input":{}}"#, folder: folder) == nil)
        // Reads and other servers' comments don't count.
        #expect(try decide(rules, #"{"tool_name":"mcp__notion__notion-get-comments","tool_input":{}}"#, folder: folder) == nil)
        #expect(try decide(rules, #"{"tool_name":"mcp__github__request_copilot_review","tool_input":{}}"#, folder: folder) == nil)
    }

    @Test func aCallACustomRuleBlocksIsntCounted() throws {
        let rules = everything(limit: 1, custom: [.init(name: "No pastebin", pattern: "pastebin")])
        let folder = FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString)")
        #expect(try decide(rules, bash("gh pr comment 1 -b https://pastebin.com/x"), folder: folder) == "deny: No pastebin")
        #expect(try decide(rules, bash("gh pr comment 1 -b hi"), folder: folder) == nil)
    }

    @Test func anInvalidPatternBlocksEverything() throws {
        var rules = SessionRules()
        rules.custom = [.init(name: "Broken", pattern: "make (")]
        #expect(!rules.custom[0].isValid)
        #expect(try decide(rules, bash("ls")) == "deny: Broken")
    }

    @Test func aBrokenHookBlocks() {
        let hook = everything().hookCommand(directory: "/tmp/s", branch: branch) ?? ""
        #expect(hook.hasSuffix("exit 2; }"))
    }

    @Test func customRulesBlockOrAsk() throws {
        let rules = everything(custom: [
            .init(name: "No pastebin", pattern: "curl .*pastebin"),
            .init(name: "Ask before \"publishing\"", pattern: "npm publish", asks: true),
        ])
        #expect(try decide(rules, bash("curl https://pastebin.com/x")) == "deny: No pastebin")
        #expect(try decide(rules, bash("npm publish --tag next")) == "ask: Ask before publishing")
        #expect(try decide(rules, bash("npm test")) == nil)
    }

    @Test func rulesCantBeChangedFromTheSession() throws {
        let rules = everything()
        for command in ["defaults write dev.andon.gannin sessionRules x", "echo {} > .gannin/settings.json", "rm \"$HOME/Library/Application Support/dev.andon.gannin/Sessions/x/rule-comments\"", "echo '{\"disableAllHooks\":true}' > x", "cat x | tee .gannin/settings.json"] {
            #expect(try decide(rules, bash(command)) == "deny: \(SessionRules.Name.guardRule)", "\(command)")
        }
        let edit = #"{"tool_name":"Edit","tool_input":{"file_path":"/Users/me/.claude/settings.json","old_string":"a","new_string":"b"}}"#
        #expect(try decide(rules, edit) == "deny: \(SessionRules.Name.guardRule)")
        let fine = #"{"tool_name":"Write","tool_input":{"file_path":"/w/Gannin/App.swift","content":"dev.andon.gannin"}}"#
        #expect(try decide(rules, fine) == nil)
        #expect(try decide(rules, bash("grep -rn dev.andon.gannin Gannin")) == nil)
        #expect(try decide(rules, bash("cat .claude/settings.json")) == nil)
        #expect(try decide(rules, bash("git commit -m \"update .claude/settings.json docs\"")) == nil)
        #expect(try decide(rules, bash("sed -i s/a/b/ .claude/settings.json")) == "deny: \(SessionRules.Name.guardRule)")
    }

    @Test func activityNamesTheRule() {
        let text = "\(SessionRules.blockedPrefix)No force push”. The person running this session set it."
        #expect(SessionRules.blockedRule(in: text) == "No force push")
        #expect(SessionRules.blockedRule(in: "Exit code 1") == nil)
    }

    @Test func oldOrPartialSettingsStillRead() throws {
        let rules = try JSONDecoder().decode(SessionRules.self, from: Data(#"{"noForcePush":true}"#.utf8))
        #expect(rules.noForcePush)
        #expect(rules.custom.isEmpty)
    }
}
