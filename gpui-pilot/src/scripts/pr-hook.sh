input=$(cat)
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
  exit 0
fi
printf '%s' "$input" | sed 's/.*"tool_response"//' | grep -Eo "$re" | grep -Eo "$url" | while IFS= read -r found; do grep -qxF "$found" __PR__ 2>/dev/null || { printf '%s\n' "$found" >> __PR__; printf '\033]7777;pr:%s\007' "$found" > /dev/tty 2>/dev/null; }; done
exit 0