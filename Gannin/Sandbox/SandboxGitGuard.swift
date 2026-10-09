import Foundation

/// What keeps a sandbox from running code on the Mac through git
/// (andrew-waters/gannin#8, R5). A sandbox can write the `.git` of the repos
/// it works on, so it could set `core.fsmonitor`, a filter or diff driver,
/// `core.sshCommand` or an include there, or point a worktree's `.git` at a
/// git dir of its own, and git on the Mac would then run what it says.
/// Before Gannin runs git on the Mac in a repo a sandbox can reach, hooks and
/// fsmonitor are switched off for that run (`GIT_CONFIG_COUNT` outranks the
/// repo's config), each worktree's `.git` must lead back to a real clone, and
/// the clone's config may only hold the keys below; anything else is named
/// and nothing runs until the user has looked.
nonisolated enum SandboxGitGuard {
    /// Keys a repo's own config may have and still be trusted: none of them
    /// runs anything (hooks and fsmonitor are overridden for the run).
    static let allowedKeys = #"^(core\.(repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|precomposeunicode|symlinks|autocrlf|eol|safecrlf|hookspath|fsmonitor|untrackedcache|sparsecheckout|commentchar)|remote\.[^.]+\.(url|fetch|tagopt|prune)|branch\..+\.(remote|merge|rebase|pushremote|description)|extensions\.(objectformat|refstorage)|user\.(name|email)|lfs\.repositoryformatversion|pull\.rebase|push\.default|fetch\.prune|gc\.auto|maintenance\.(auto|strategy))$"#

    /// The shell functions: hooks and fsmonitor off for every git that
    /// follows, `gannin_untrusted <git dir>` printing keys off the list, and
    /// `gannin_check <folder>` printing why git shouldn't run in a worktree
    /// or clone, failing when it shouldn't.
    static let functions = """
        export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false
        gannin_untrusted() {
          git config --file "$1/config" --name-only --list 2>/dev/null | grep -viE '\(allowedKeys)'
        }
        gannin_check() {
          local w=$1 g common bad
          if [ -d "$w/.git" ]; then
            common=$(cd "$w/.git" && pwd -P)
          elif [ -f "$w/.git" ]; then
            g=$(sed -n 's/^gitdir: //p' "$w/.git")
            g=$(cd "$w" 2>/dev/null && cd "$g" 2>/dev/null && pwd -P) || { echo "${w##*/}'s .git points to a folder that isn't there."; return 1; }
            [ "$(cat "$g/commondir" 2>/dev/null)" = ../.. ] || { echo "${w##*/}'s git dir ($g) isn't a worktree's."; return 1; }
            common=$(cd "$g/../.." && pwd -P)
            # Patterns opened with ( as well, so this parses inside $( ).
            case "$g" in ("$common"/worktrees/*) ;; (*) echo "${w##*/}'s .git doesn't lead back to a clone."; return 1 ;; esac
          else
            return 0
          fi
          bad=$(gannin_untrusted "$common" | tr '\\n' ' ')
          [ -z "$bad" ] || { echo "Gannin won't run git in ${w##*/}: $common/config has ${bad}which a sandbox could have set. Look at it, remove them if they aren't yours, then try again."; return 1; }
        }
        """

    /// Checks every worktree in a session's folder (a shell word) and stops
    /// the script, saying why, at the first that fails.
    static func folder(_ folder: String) -> String {
        functions + "\n" + """
            for w in \(folder)/*/; do
              w=${w%/}
              why=$(gannin_check "$w") || { echo "$why" >&2; exit 1; }
            done
            """
    }

    /// Checks the repo the script has `cd`ed into.
    static let here = functions + "\n" + #"why=$(gannin_check "$PWD") || { echo "$why" >&2; exit 1; }"#

    /// Whether a folder on this Mac is one a sandbox could have written to,
    /// while sandboxing is on: a harness (it has `.worktrees/`), a clone in a
    /// harness's `projects/`, or a worktree in its `.worktrees/`.
    static func applies(to path: String) -> Bool {
        guard SandboxCredentials.isEnabled else { return false }
        let expanded = (path as NSString).expandingTildeInPath
        let parts = expanded.split(separator: "/")
        if parts.contains("projects") || parts.contains(".worktrees") { return true }
        return FileManager.default.fileExists(atPath: expanded + "/.worktrees")
    }
}
