import Foundation
import Testing
@testable import Gannin

/// Git on the Mac doesn't trust what a sandbox could have written in a
/// repo's .git (andrew-waters/gannin#8, R5).
struct SandboxGitGuardTests {
    /// A clone with a worktree in an issue's folder, as a session lays them out.
    private func layout() throws -> (root: String, clone: String, worktree: String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "gannin-guard-\(UUID().uuidString)").path
        let clone = root + "/projects/api", worktree = root + "/.worktrees/1-x/api"
        let made = Shell.run("""
            export GIT_CONFIG_GLOBAL=/dev/null
            git init -q \(SessionScript.quoted(clone)) && cd \(SessionScript.quoted(clone)) || exit 1
            git -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
            git remote add origin https://github.com/acme/api.git
            git worktree add -q -b 1-x \(SessionScript.quoted(worktree))
            git config branch.1-x.remote origin
            """, .local)
        #expect(made.ok, "\(made.failure)")
        return (root, clone, worktree)
    }

    private func check(_ folder: String) -> Shell.Result {
        Shell.run(SandboxGitGuard.functions + "\nwhy=$(gannin_check \(SessionScript.quoted(folder))) || { echo \"$why\"; exit 1; }\necho trusted", .local)
    }

    @Test func anOrdinaryCloneAndWorktreeAreTrusted() throws {
        let (root, clone, worktree) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(check(clone).output.contains("trusted"))
        #expect(check(worktree).output.contains("trusted"))
        // A folder with no git at all is nothing to check.
        #expect(check(root).ok)
    }

    @Test func aRepoTheSandboxMadeIsCheckedForConfigThatRunsThings() throws {
        let (root, _, _) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // A sandbox can't write the clones' config, but a repo it makes in its folder is all its own.
        let made = root + "/.worktrees/1-x/made"
        _ = Shell.run("export GIT_CONFIG_GLOBAL=/dev/null; git init -q \(SessionScript.quoted(made)) && git -C \(SessionScript.quoted(made)) config filter.x.clean evil && git -C \(SessionScript.quoted(made)) config include.path /tmp/x", .local)
        let result = check(made)
        #expect(!result.ok)
        #expect(result.output.contains("filter.x.clean"))
        #expect(result.output.contains("include.path"))
    }

    @Test func aClonesOwnSettingsAreItsUsers() throws {
        let (root, clone, worktree) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // The clones are read-only to sandboxes, so what's in their config is the user's.
        _ = Shell.run("for kv in commit.gpgsign=true core.sshCommand=ssh-x submodule.a.url=x remote.origin.pushurl=y; do git -C \(SessionScript.quoted(clone)) config \"${kv%%=*}\" \"${kv#*=}\"; done", .local)
        #expect(check(clone).ok)
        #expect(check(worktree).ok)
    }

    @Test func hooksAndFsmonitorAreOverriddenNotRefused() throws {
        let (root, clone, _) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = Shell.run("git -C \(SessionScript.quoted(clone)) config core.hooksPath .husky; git -C \(SessionScript.quoted(clone)) config core.fsmonitor 'touch \(root)/ran'", .local)
        #expect(check(clone).ok)
        // And under the guard's settings, git doesn't run either.
        _ = Shell.run(SandboxGitGuard.functions + "\ncd \(SessionScript.quoted(clone)) && git status >/dev/null 2>&1", .local)
        #expect(!FileManager.default.fileExists(atPath: root + "/ran"))
    }

    @Test func aRepoNestedInAWorktreeIsntLookedInto() throws {
        let (root, _, worktree) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // A sandbox nests a repo with a config of its own and records it as a submodule.
        let nested = worktree + "/vendor"
        let made = Shell.run("""
            export GIT_CONFIG_GLOBAL=/dev/null
            git init -q \(SessionScript.quoted(nested)) && cd \(SessionScript.quoted(nested)) || exit 1
            echo a > a && git add a && git -c user.email=a@b -c user.name=a commit -qm a
            git config core.fsmonitor 'touch \(root)/ran'
            cd \(SessionScript.quoted(worktree)) && git add vendor && echo b >> vendor/a
            """, .local)
        #expect(made.ok, "\(made.failure)")
        _ = Shell.run(SandboxGitGuard.functions + "\ncd \(SessionScript.quoted(worktree)) && git status --porcelain >/dev/null 2>&1; git diff >/dev/null 2>&1", .local)
        #expect(!FileManager.default.fileExists(atPath: root + "/ran"))
    }

    @Test func onlySandboxedHarnessesAreGuarded() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gannin-roots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "projects/api"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); SandboxGitGuard.setRoots([]) }
        SandboxGitGuard.setRoots([root.path])
        #expect(SandboxGitGuard.applies(to: root.appending(path: "projects/api").path))
        #expect(SandboxGitGuard.applies(to: root.path))
        #expect(!SandboxGitGuard.applies(to: root.path + "-other/projects/api"))
        #expect(!SandboxGitGuard.applies(to: "/Users/someone/projects/app"))
        SandboxGitGuard.setRoots([])
        #expect(!SandboxGitGuard.applies(to: root.appending(path: "projects/api").path))
    }

    @Test func aWorktreePointingElsewhereIsRefused() throws {
        let (root, _, worktree) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // A git dir of its own, beside the worktree, with its own config.
        _ = Shell.run("mkdir -p \(SessionScript.quoted(root))/evil && printf 'gitdir: %s\\n' \(SessionScript.quoted(root))/evil > \(SessionScript.quoted(worktree))/.git", .local)
        let result = check(worktree)
        #expect(!result.ok)
        #expect(result.output.contains("isn't a worktree's"))
    }

    @Test func aMovedCommonDirIsRefused() throws {
        let (root, clone, worktree) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = Shell.run("printf '%s\\n' \(SessionScript.quoted(root))/evil > \(SessionScript.quoted(clone))/.git/worktrees/api/commondir", .local)
        #expect(!check(worktree).ok)
    }

    @Test func aFolderStopsAtTheFirstUntrustedWorktree() throws {
        let (root, _, _) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let made = root + "/.worktrees/1-x/made"
        _ = Shell.run("export GIT_CONFIG_GLOBAL=/dev/null; git init -q \(SessionScript.quoted(made)) && git -C \(SessionScript.quoted(made)) config core.sshCommand evil", .local)
        let result = Shell.run(SandboxGitGuard.folder(SessionScript.quoted(root + "/.worktrees/1-x")) + "\necho ran-git", .local)
        #expect(!result.ok)
        #expect(!result.output.contains("ran-git"))
        // git names keys in lower case.
        #expect(result.errors.contains("core.sshcommand"))
    }
}
