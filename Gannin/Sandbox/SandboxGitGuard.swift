import Foundation
import Synchronization

/// What keeps a sandbox from running code on the Mac through git
/// (andrew-waters/gannin#8, R5). A sandbox can write the `.git` of the repos
/// it works on, so it could set `core.fsmonitor`, a filter or diff driver,
/// `core.sshCommand` or an include there, or point a worktree's `.git` at a
/// git dir of its own, and git on the Mac would then run what it says.
/// Before Gannin runs git on the Mac in a repo a sandbox can reach, hooks,
/// fsmonitor and submodules are switched off for that run (`GIT_CONFIG_PARAMETERS`
/// outranks the repo's config), each worktree's `.git` must lead back to a real clone, and
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
        # As if given with -c, which git passes on to the repos it runs git in
        # for submodules too: no hooks, no fsmonitor, and no submodule (a repo
        # a sandbox nested in a worktree, with a config of its own) looked into.
        export GIT_CONFIG_PARAMETERS="'core.hooksPath'='/dev/null' 'core.fsmonitor'='false' 'diff.ignoreSubmodules'='all' 'submodule.recurse'='false' 'status.submoduleSummary'='false'"
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
          # The clones and the harness are mounted read-only, so their config is
          # the user's own. A git dir in an issue's folder, though, a sandbox
          # made itself, and its config can name filters or an sshCommand.
          case "$common" in (*/.worktrees/*) ;; (*) return 0 ;; esac
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

    /// Whether a folder on this Mac is one a sandbox could have written to:
    /// inside the harness of a session that runs in a sandbox here (its
    /// clones in `projects/` and worktrees in `.worktrees/`), whether or not
    /// sandboxing is still on, as such sessions stay sandboxed.
    static func applies(to path: String) -> Bool {
        let real = realPath(path)
        return roots.withLock { roots in roots.contains { real == $0 || real.hasPrefix($0 + "/") } }
    }

    /// The harnesses sandboxed sessions on this Mac run in, at their real
    /// paths, kept by `SessionStore` as sessions come and go.
    static func setRoots(_ paths: [String]) {
        let real = Set(paths.map(realPath))
        roots.withLock { $0 = real }
    }

    private static let roots = Mutex<Set<String>>([])

    /// The path as `pwd -P` gives it, which is how mounts and git record
    /// paths (Foundation's resolving drops `/private` from `/private/var`).
    /// A path that isn't there yet is left as it is, `~` expanded.
    static func realPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard let resolved = realpath(expanded, nil) else { return expanded }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
