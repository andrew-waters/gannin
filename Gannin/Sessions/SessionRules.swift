import Foundation
import SwiftUI

/// Rules that block what a Claude Code session can do, whatever Claude
/// decides (andrew-waters/gannin#129, `plans/2026-10-10-session-rules.md`).
/// The user's own, on this Mac, off until one is set. Enforced by a
/// `PreToolUse` hook in the settings Gannin writes on every start and
/// resume (`SessionScript.settings`), here, on a server and in a sandbox:
/// Claude Code snapshots hooks as it starts, and a hook's deny wins over any
/// allow. The check is inline in the hook's command, so there's no script for
/// a session to edit; the comment count is the one file it keeps.
nonisolated struct SessionRules: Codable, Equatable, Sendable {
    var noForcePush = false
    var pushOnlyToBranch = false
    var noDeletes = false
    var noReleaseWrites = false
    /// At most this many PR comments or reviews an hour per session; nil for
    /// no limit.
    var commentLimit: Int?
    var custom: [Custom] = []

    /// A command pattern (`grep -E`, so plain words work as they are) that's
    /// blocked, or turned into a question for you.
    nonisolated struct Custom: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var name = ""
        var pattern = ""
        var asks = false

        /// Its name as the hook says it: no quotes or backslashes to break the
        /// JSON it prints, and something whatever's typed.
        /// Whether the pattern reads as a regular expression; one that
        /// doesn't blocks every command (the hook fails closed), so Settings
        /// says so. ICU is close enough to `grep -E` for a warning.
        var isValid: Bool {
            (try? NSRegularExpression(pattern: pattern)) != nil
        }

        var shownName: String {
            let cleaned = name.filter { !"\"\\“”".contains($0) && !$0.isNewline }.trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? pattern.filter { !"\"\\“”".contains($0) && !$0.isNewline } : cleaned
        }
    }

    static let defaultCommentLimit = 10

    /// The rules the hook names, as Settings and Activity show them.
    enum Name {
        static let forcePush = "No force push"
        static let branch = "Push only to the session's branch"
        static let deletes = "No branch or tag deletes"
        static let releases = "No gh release writes"
        static let guardRule = "Rules can't be changed from a session"
        static func comments(_ limit: Int) -> String { "At most \(limit) PR comments or reviews an hour" }
    }

    /// The custom rules that have a pattern.
    var activeCustom: [Custom] { custom.filter { !$0.pattern.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// Whether nothing is blocked: sessions then get no hook at all, so they
    /// behave as they did before rules.
    var isEmpty: Bool {
        !noForcePush && !pushOnlyToBranch && !noDeletes && !noReleaseWrites && (commentLimit ?? 0) <= 0 && activeCustom.isEmpty
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        noForcePush = try c.decodeIfPresent(Bool.self, forKey: .noForcePush) ?? false
        pushOnlyToBranch = try c.decodeIfPresent(Bool.self, forKey: .pushOnlyToBranch) ?? false
        noDeletes = try c.decodeIfPresent(Bool.self, forKey: .noDeletes) ?? false
        noReleaseWrites = try c.decodeIfPresent(Bool.self, forKey: .noReleaseWrites) ?? false
        commentLimit = try c.decodeIfPresent(Int.self, forKey: .commentLimit)
        custom = (try? c.decodeIfPresent([Custom].self, forKey: .custom)) ?? []
    }

    static let key = "sessionRules"

    /// The rules set on this Mac, read as each session starts or resumes.
    static var current: SessionRules {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return SessionRules() }
            return (try? JSONDecoder().decode(SessionRules.self, from: data)) ?? SessionRules()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// The tools the hook looks at: commands, file edits (for the guard) and
    /// MCP tools (for the comment limit).
    static let matcher = "Bash|Edit|MultiEdit|Write|NotebookEdit|mcp__.*"

    /// The hook's command for a session on `branch`, writing its count to
    /// `directory` (a shell expression on the session's box); nil with no
    /// rules. Bash, sed, awk, grep and date only, which a Mac, a server and
    /// the sandbox image all have, carried as base64 so its quoting survives.
    /// It fails closed: if the script can't be unpacked or bash fails, the
    /// call is blocked (exit 2) rather than let through.
    func hookCommand(directory: String, branch: String) -> String? {
        guard !isEmpty else { return nil }
        func flag(_ on: Bool) -> String { on ? "1" : "0" }
        // As `SessionScript.quoted`, which is the main actor's.
        func quoted(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        func array(_ values: [String]) -> String { "(" + values.map(quoted).joined(separator: " ") + ")" }
        let rules = activeCustom
        let prelude = """
            dir=\(directory)
            branch=\(quoted(branch))
            guard=1
            force=\(flag(noForcePush))
            onlybranch=\(flag(pushOnlyToBranch))
            deletes=\(flag(noDeletes))
            releases=\(flag(noReleaseWrites))
            limit=\(max(commentLimit ?? 0, 0))
            cname=\(array(rules.map(\.shownName)))
            cpat=\(array(rules.map(\.pattern)))
            cask=\(array(rules.map { $0.asks ? "1" : "0" }))

            """
        let script = Data((prelude + Self.check).utf8).base64EncodedString()
        return #"s=$(printf %s \#(script) | base64 -d) && [ -n "$s" ] && bash -c "$s" || { echo "Gannin's session rules couldn't run here, so this is blocked to be safe." >&2; exit 2; }"#
    }

    /// The prefix of the reason a blocked tool call's result carries, which
    /// the transcript reads the rule's name after (`blockedRule(in:)`).
    static let blockedPrefix = "Blocked by Gannin's session rule “"

    /// The rule named in a tool result the hook denied, if it was one.
    static func blockedRule(in text: String) -> String? {
        guard let start = text.range(of: blockedPrefix),
              let end = text[start.upperBound...].firstIndex(of: "”") else { return nil }
        return String(text[start.upperBound..<end])
    }

    /// The check itself, after the prelude's settings. It reads the tool call
    /// from standard input, splits a command into its parts (`;`, `&&`, `|`,
    /// subshells), finds git's and gh's subcommands in each (quotes taken
    /// off), and prints a deny (or, for an Ask me rule, an ask) with the
    /// rule's name, else nothing. Words are split on spaces, not parsed as
    /// the shell would: it stops the ordinary ways of doing each thing, not
    /// an encoded one. Pushes have to name the session's branch as their
    /// destination, since a bare `git push` or `HEAD` pushes whatever is
    /// checked out when it runs.
    static let check = #"""
input=$(cat)
field() { printf '%s' "$input" | sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' | head -n1 | sed -E 's/\\t/ /g; s/\\\//\//g; s/\\"/"/g; s/\\\\/\\/g'; }
tool=$(field tool_name)
cmd=$(field command)
path=$(field file_path)$(field notebook_path)
decide() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
  exit 0
}
deny() { decide deny "Blocked by Gannin's session rule “$1”. The person running this session set it outside Claude Code, and it can't be changed or got round from here: carry on another way, or stop and say what you needed.$2"; }
guarded="Rules can't be changed from a session"
gitrules=$((force + onlybranch + deletes))
# A command's parts, one a line: split at `;`, `&&`, `||`, `|`, `&` and
# subshells, with redirections to /dev/null or another descriptor dropped.
segments=$(printf '%s\n' "$cmd" | awk '{ gsub(/\\n/, "\n"); gsub(/[0-9]*>+&[0-9-]+|[0-9]*>+[[:space:]]*\/dev\/null/, " "); gsub(/&&|\|\||[;|&()]|\$\(|`/, "\n"); print }')
q="\"'"
# The git or gh subcommand in a segment, its arguments in `args`, without
# quotes; git's `-c` values in `configs`.
words() {
  set -f; w=($1); set +f
  w=("${w[@]//[$q]/}")
  i=0; n=${#w[@]}; sub=""; args=(); configs=()
  while [ $i -lt $n ] && [ "${w[$i]##*/}" != "$2" ]; do i=$((i+1)); done
  [ $i -lt $n ] || return 1
  i=$((i+1))
  while [ $i -lt $n ]; do
    case "${w[$i]}" in
      -c|--config-env) configs+=("${w[$((i+1))]}"); i=$((i+2)) ;;
      -C|--git-dir|--work-tree|--namespace|-R|--repo|--hostname) i=$((i+2)) ;;
      -*) i=$((i+1)) ;;
      *) break ;;
    esac
  done
  [ $i -lt $n ] || return 1
  sub=${w[$i]}; args=("${w[@]:$((i+1))}")
}
# Whether an argument matches one of `|`-separated patterns.
has() {
  local p a IFS='|'
  set -f; set -- $1; set +f
  for p; do for a in "${args[@]}"; do case "$a" in $p) return 0 ;; esac; done; done
  return 1
}
# Whether a short flag, alone or among others (`-fu`), has one of the letters.
flag() {
  local a
  for a in "${args[@]}"; do case "$a" in -[!-]*[$1]*|-[$1]*) [ "${a#-}" != "$a" ] && [ "${a#--}" = "$a" ] && return 0 ;; esac; done
  return 1
}
# The first argument that isn't a flag (or a flag's value): gh's verb.
verb() {
  local a skip=0
  for a in "${args[@]}"; do
    if [ $skip = 1 ]; then skip=0; continue; fi
    case "$a" in -R|--repo|--hostname) skip=1 ;; -*) ;; *) printf %s "$a"; return ;; esac
  done
}
# Git config that changes what push does, or makes an alias of anything.
pushconfig() { printf '%s\n' "$@" | tr 'A-Z' 'a-z' | grep -Eq '^(alias\.|remote\..*\.(push|mirror)|push\.)'; }
if [ "$guard" = 1 ]; then
  case "$path" in
    *dev.andon.gannin/*|*dev.andon.gannin.plist|*.gannin/settings*|*.claude/settings*|*managed-settings*) deny "$guarded" ;;
  esac
  # A command naming what holds the rules may read it, not write it.
  while IFS= read -r seg; do
    case "$seg" in
      *dev.andon.gannin*|*rule-comments*|*.gannin/settings*|*.claude/settings*|*disableAllHooks*|*managed-settings*) ;;
      *) continue ;;
    esac
    case "$seg" in *\>*) deny "$guarded" ;; esac
    set -f; w=($seg); set +f
    w=("${w[@]//[$q]/}")
    case "${w[0]##*/}" in
      cat|head|tail|less|more|grep|egrep|fgrep|rg|ls|wc|stat|file|diff|echo|printf) ;;
      git) case "${w[1]}" in log|diff|show|status|grep|add|commit|blame|ls-files) ;; *) deny "$guarded" ;; esac ;;
      *) deny "$guarded" ;;
    esac
  done <<GUARD
$segments
GUARD
fi
comment=0
if [ "$tool" != Bash ]; then
  case "$tool" in
    mcp__*[Gg]it[Hh]ub*__add_*comment*|mcp__*[Gg]it[Hh]ub*__pull_request_review_write|mcp__*[Gg]it[Hh]ub*__add_reply_to_pull_request_comment) comment=1 ;;
    *) exit 0 ;;
  esac
  segments=""
fi
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  if words "$seg" git; then
    if [ $gitrules -gt 0 ]; then
      if pushconfig "${configs[@]}"; then deny "$guarded"; fi
      if [ "$sub" = config ] && ! has '--get|--get-all|--get-regexp|-l|--list|get|list' && pushconfig "${args[@]}"; then deny "$guarded"; fi
    fi
    if [ "$sub" = push ]; then
      if [ "$force" = 1 ] && { flag f || has '--force|--force-*|+*|*:+*'; }; then deny "No force push"; fi
      if [ "$deletes" = 1 ] && { flag d || has '--delete|--prune|:*'; }; then deny "No branch or tag deletes"; fi
      if [ "$onlybranch" = 1 ]; then
        hint=" Push with git push origin HEAD:$branch."
        has '--all|--mirror|--tags|--branches' && deny "Push only to the session's branch" "$hint"
        pos=(); skip=0
        for a in "${args[@]}"; do
          if [ $skip = 1 ]; then skip=0; continue; fi
          case "$a" in
            -o|--push-option|--repo|--receive-pack|--exec) skip=1 ;;
            -*) ;;
            *) pos+=("$a") ;;
          esac
        done
        # Without a refspec, or with HEAD alone, what's pushed is whatever
        # is checked out when it runs, so the branch has to be named.
        [ ${#pos[@]} -ge 2 ] || deny "Push only to the session's branch" "$hint"
        for r in "${pos[@]:1}"; do
          r=${r#+}
          case "$r" in *:*) dst=${r#*:} ;; HEAD) dst="" ;; *) dst=$r ;; esac
          case "$dst" in
            "$branch"|refs/heads/"$branch") ;;
            *) deny "Push only to the session's branch" "$hint" ;;
          esac
        done
      fi
    elif [ "$deletes" = 1 ]; then
      case "$sub" in
        branch|tag) { flag dD || has '--delete'; } && deny "No branch or tag deletes" ;;
        update-ref) { flag d || has '--delete|--stdin'; } && deny "No branch or tag deletes" ;;
      esac
    fi
  fi
  if words "$seg" gh; then
    case "$sub $(verb)" in
      "release create"|"release delete"|"release edit"|"release upload"|"release delete-asset")
        [ "$releases" = 1 ] && deny "No gh release writes" ;;
      "pr comment"|"pr review"|"issue comment") comment=1 ;;
    esac
    if [ "$sub" = api ]; then
      # gh api's method: -X, --method, or POST when it's given fields.
      method=""; prev=""
      for a in "${args[@]}"; do
        case "$prev" in -X|--method) method=$a ;; esac
        case "$a" in -X?*) method=${a#-X} ;; --method=*) method=${a#--method=} ;; esac
        prev=$a
      done
      method=$(printf %s "$method" | tr 'a-z' 'A-Z')
      if [ -z "$method" ] && has '-f|-F|--field|--raw-field|--input|-f?*|-F?*|--field=*|--raw-field=*|--input=*'; then method=POST; fi
      writes=0; case "$method" in ""|GET|HEAD) ;; *) writes=1 ;; esac
      if [ "$releases" = 1 ] && [ $writes = 1 ] && has '*releases*'; then deny "No gh release writes"; fi
      if [ "$deletes" = 1 ] && [ "$method" = DELETE ] && has '*git/refs*'; then deny "No branch or tag deletes"; fi
      if [ $writes = 1 ] && has '*/comments|*/comments/*|*/reviews|*/reviews/*|*/replies'; then comment=1; fi
    fi
  fi
done <<SEGMENTS
$segments
SEGMENTS
# Custom rules before the count, so a call they stop isn't counted. An
# Ask me answered No still counts: the hook can't hear the answer.
if [ "$tool" = Bash ]; then
  k=0
  while [ $k -lt ${#cname[@]} ]; do
    printf '%s' "$cmd" | grep -Eq -- "${cpat[$k]}" 2>/dev/null
    case $? in
      0)
        if [ "${cask[$k]}" = 1 ]; then
          decide ask "Gannin's session rule “${cname[$k]}” asks the person running this session before this runs."
        fi
        deny "${cname[$k]}" ;;
      1) ;;
      # A pattern grep can't read blocks rather than silently matching nothing.
      *) deny "${cname[$k]}" " Its pattern isn't a valid regular expression, so it blocks every command until it's fixed in Gannin's Settings." ;;
    esac
    k=$((k+1))
  done
fi
# Calls running at once can each read the log before the other writes it,
# so a burst can slip one or two past the limit.
if [ "$limit" -gt 0 ] 2>/dev/null && [ "$comment" = 1 ]; then
  now=$(date +%s); log="$dir/rule-comments"
  recent=$(awk -v since=$((now - 3600)) '$1 > since' "$log" 2>/dev/null)
  if [ "$(printf '%s' "$recent" | grep -c .)" -ge "$limit" ]; then
    deny "At most $limit PR comments or reviews an hour"
  fi
  { [ -n "$recent" ] && printf '%s\n' "$recent"; printf '%s\n' "$now"; } > "$log.$$" && mv "$log.$$" "$log"
fi
exit 0
"""#
}

/// Settings › General › Session rules: the ready-made rules to tick, the
/// comment limit, and custom rules.
struct SessionRulesSection: View {
    @State private var rules = SessionRules.current

    var body: some View {
        Section {
            Toggle(SessionRules.Name.forcePush, isOn: $rules.noForcePush)
            Toggle(SessionRules.Name.branch, isOn: $rules.pushOnlyToBranch)
            Toggle(SessionRules.Name.deletes, isOn: $rules.noDeletes)
            Toggle(SessionRules.Name.releases, isOn: $rules.noReleaseWrites)
            Toggle("Limit PR comments and reviews", isOn: Binding(
                get: { (rules.commentLimit ?? 0) > 0 },
                set: { rules.commentLimit = $0 ? SessionRules.defaultCommentLimit : nil }
            ))
            if let limit = rules.commentLimit, limit > 0 {
                Stepper(value: Binding(get: { limit }, set: { rules.commentLimit = $0 }), in: 1...100) {
                    Text("At most \(limit) an hour per session")
                }
            }
            ForEach($rules.custom) { $rule in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Name", text: $rule.name, prompt: Text("No npm publish"))
                        TextField("Pattern", text: $rule.pattern, prompt: Text("npm publish"))
                            .font(.body.monospaced())
                        Picker("When it matches", selection: $rule.asks) {
                            Text("Block").tag(false)
                            Text("Ask me").tag(true)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Remove", systemImage: "minus.circle") {
                            rules.custom.removeAll { $0.id == rule.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                    if !rule.pattern.isEmpty && !rule.isValid {
                        Text("This pattern isn't a valid regular expression, so this rule blocks every command until it's fixed.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            Button("Add Rule") { rules.custom.append(.init()) }
            Text("Each rule is checked by Gannin before claude runs a command, in every session you start or resume from now on, on this Mac, a server or a sandbox, in either mode. A blocked command shows in the session's Activity with the rule's name, and claude is told why so it can carry on another way. Ask me puts the session in Needs you for you to allow or deny. A pattern is matched against the whole command as an extended regular expression; plain words work as they are.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("While any rule is on, a session can't change Gannin's settings, its own settings file or Claude Code's (reading them with cat, grep and the like is fine, other commands naming them are blocked), or set git config that changes what push does. Push only to the session's branch needs the branch named, as git push origin HEAD:<branch>. Rules match commands as they're written, which stops mistakes and casual prompt injection, not someone set on getting round them (an encoded or scripted command); protect shared branches on GitHub too.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Session rules")
        }
        .onChange(of: rules) { _, rules in SessionRules.current = rules }
    }
}
