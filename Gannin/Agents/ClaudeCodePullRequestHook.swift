import Foundation

extension ClaudeCodeProvider {
    /// The script the settings' PostToolUse hook runs, beside the settings file.
    static let pullRequestHookFile = "pr-hook.sh"

    var hookScripts: [String: String] { [Self.pullRequestHookFile: Self.pullRequestHookScript] }

    /// A script that records a PR the session opens in the `pr` file beside it.
    /// A new PR's URL is in the result of a call that creates one; only those
    /// results are read, since any other call that mentions a PR (viewing or
    /// listing them, a file naming one) would otherwise be recorded as the
    /// session's own. A creating call is a Bash command that runs, at the start
    /// of a command (after `&&`, `;`, `|`, `(`, `$(`, a backtick or a newline,
    /// and any `VAR=value` words):
    /// - `gh pr create`: its result is the new PR's URL, so every URL in it is
    ///   kept.
    /// - `gh api` to a path ending in `/pulls` with `-X POST`, `--method POST`,
    ///   or a `-f`, `-F`, `--field`, `--raw-field` or `--input` (which make gh
    ///   POST), and no `-X GET`, all in that one `gh api` command (up to the
    ///   next `&&`, `;`, `|`, quote or newline), not elsewhere in the call. Its
    ///   result is the whole PR, body included, so only its `html_url` or `url`
    ///   is kept (a REST object's `url` is on api.github.com, so it never
    ///   matches).
    /// - A PR-creating MCP tool (`create_pull_request`): the `html_url` or `url`
    ///   of its result, which may be an object, a string of JSON, or content
    ///   blocks whose text is JSON.
    /// Left out, so the session records no PR: a wrapper script, a `gh` reached
    /// through `xargs`, `env` or `then`, a quoted `VAR="a b"` prefix, and
    /// `gh api` with its method or path in a variable.
    ///
    /// With `jq` on the box the call is parsed as JSON, so the order of Claude
    /// Code's keys doesn't matter. Without it the script falls back to `sed`
    /// and `grep` on the raw text, which relies on `tool_name` and `tool_input`
    /// coming before `tool_response`. A call can open more than one PR (one per
    /// repo in one command), so every URL seen is kept, one per line.
    ///
    /// Run with `sh`, with the hook's JSON on standard input. It finds the `pr`
    /// file from its own location, which holds wherever the folder is mounted.
    static var pullRequestHookScript: String {
        let signalCode = SessionScript.signalCode
        return #"""
        d=$(cd "$(dirname "$0")" && pwd)
        input=$(cat)

        parsed() {
          printf '%s' "$input" | jq -r '
            def urlre: "https://github\\.com/[^\"\\\\ ]+/pull/[0-9]+";
            def lead: "(^|[&;|\n(`]) *([A-Za-z_][A-Za-z0-9_]*=[^ ]+ +)*";
            def objs:
              if type == "string" then (try (fromjson | objs) catch empty)
              elif type == "array" then (.[] | objs)
              elif type == "object" then ., ((.content? | objs), (.text? | objs))
              else empty end;
            def bashout: if type == "object" then (.stdout // "") elif type == "string" then . else "" end;
            def posts($c):
              [$c | match("gh api [^&;|`\"\n]*"; "g").string
                | select(test("/pulls( |$)"))
                | select(test("(-X ?|--method[ =])POST| (-[fF]|--field|--raw-field|--input)[ =]"; "i"))
                | select(test("(-X ?|--method[ =])GET"; "i") | not)] | length > 0;
            (.tool_name // "") as $tool
            | ((.tool_input | objects | .command | strings) // "") as $c
            | .tool_response as $r
            | if $tool == "Bash" and ($c | test(lead + "gh pr create")) then
                $r | bashout | scan(urlre)
              elif ($tool | test("create_pull_request$")) then
                $r | objs | (.html_url?, .url?) | strings | scan(urlre)
              elif $tool == "Bash" and ($c | test(lead + "gh api ")) and posts($c) then
                $r | bashout | scan("\"(?:html_)?url\": ?\"(https://github\\.com/[^\"\\\\ ]+/pull/[0-9]+)") | .[0]
              else empty end'
        }

        legacy() {
          call=$(printf '%s' "$input" | sed 's/"tool_response".*//')
          has() { printf '%s' "$call" | grep -Eq -- "$1"; }
          # Each `gh api` command on its own line, ending at a separator, an
          # unescaped quote or a newline, so a flag on another command in the same
          # call isn't taken as this one's.
          creates() { printf '%s' "$call" | grep -Eo 'gh api ([^&;|`"\\]|\\[^n])*' | grep -E '/pulls([ ]|\\|$)' | grep -Ei '(-X ?|--method[ =])POST| (-[fF]|--field|--raw-field|--input)[ =]' | grep -Eiv '(-X ?|--method[ =])GET' | grep -q .; }
          start='"tool_name": ?"Bash".*"command": ?"(.*(&&|;|\||\\n|\(|`))? *([A-Za-z_][A-Za-z0-9_]*=[^ ]+ +)*'
          url='https://github\.com/[^"\\ ]+/pull/[0-9]+'
          if has "$start"'gh pr create'; then
            re=$url
          elif has '"tool_name": ?"[^"]*create_pull_request"' || { has "$start"'gh api ' && creates; }; then
            re='"(html_)?url\\*": ?\\*"'"$url"
          else
            return 0
          fi
          printf '%s' "$input" | sed 's/.*"tool_response"//' | grep -Eo "$re" | grep -Eo "$url"
        }

        if command -v jq >/dev/null 2>&1 && urls=$(parsed 2>/dev/null); then
          :
        else
          urls=$(legacy)
        fi

        printf '%s\n' "$urls" | while IFS= read -r found; do
          [ -n "$found" ] || continue
          grep -qxF "$found" "$d/pr" 2>/dev/null || { printf '%s\n' "$found" >> "$d/pr"; printf '\033]\#(signalCode);pr:%s\007' "$found" > /dev/tty 2>/dev/null; }
        done
        exit 0
        """#
    }
}
