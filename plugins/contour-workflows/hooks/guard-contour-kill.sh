#!/usr/bin/env bash
# PreToolUse hook: block name-matched kills of a protected process (default: contour).
#
# Why this exists: `pkill -x contour`, `pkill -f contour` and `killall contour` select
# processes by NAME, so a teardown meant for a build-tree test binary
# (out/.../src/contour/contour) also SIGKILLs a developer's daily-driver terminal
# (/usr/local/bin/contour) — every process called "contour" dies at once. That exact
# mistake killed a live session. This hook denies the bare-name forms and points at a
# scoped rewrite; it leaves path/socket/PID-scoped kills alone.
#
# Deliberately conservative:
#   * only ever looks at kills that reference a protected name by bare (non-path) token
#   * fails OPEN — any parsing trouble exits 0 (allow), so a hook bug can never wedge Bash
#   * degrades gracefully elsewhere — in a repo with no "contour" process nothing ever fires
#
# Protected names are data-driven: override with CLAUDE_KILL_GUARD_NAMES (space-separated).

set -uo pipefail

payload=$(cat)

# --- extract .tool_input.command ---------------------------------------------
# jq preferred; python3 as fallback. Without either, allow rather than risk a
# fragile regex parse of arbitrary JSON.
json_tool=""
if command -v jq >/dev/null 2>&1; then
  json_tool="jq"
  cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)
elif command -v python3 >/dev/null 2>&1; then
  json_tool="python3"
  cmd=$(printf '%s' "$payload" | python3 -c \
    'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("command","") or "")
except Exception: pass' 2>/dev/null)
else
  exit 0
fi

[ -n "${cmd:-}" ] || exit 0

# --- is this a name-based process killer at all? ------------------------------
# pkill/killall select by name directly; pgrep/pidof only matter when their output
# is piped into a kill (kill $(pgrep -x contour), pidof contour | xargs kill).
is_killer=0
if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])(pkill|killall)([^[:alnum:]_]|$)'; then
  is_killer=1
elif printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])(pgrep|pidof)([^[:alnum:]_]|$)' \
  && printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])(kill|xargs)([^[:alnum:]_]|$)'; then
  is_killer=1
fi
[ "$is_killer" -eq 1 ] || exit 0

# --- does it name a protected process as a BARE name (not a path segment)? -----
# A bare token has non-path boundaries on both sides: preceded by start/space/quote/=
# (not '/' '.' '-' or a word char) and followed likewise. So `contour`, `-x contour`,
# `-f 'contour'` match, but `out/.../src/contour/contour`, `$D/live.sock` and
# `contour-daemon` (a distinct cmdline the daily driver never has) do not.
read -ra guard_names <<< "${CLAUDE_KILL_GUARD_NAMES:-contour}"
hit=""
for name in "${guard_names[@]}"; do
  [ -n "$name" ] || continue
  if printf '%s' "$cmd" | grep -qE "(^|[^./[:alnum:]_-])${name}([^./[:alnum:]_-]|\$)"; then
    hit="$name"
    break
  fi
done
[ -n "$hit" ] || exit 0

# --- block it -----------------------------------------------------------------
reason="Refusing a name-matched kill of \"${hit}\". pkill/killall/pgrep by bare name hits EVERY process called \"${hit}\", including a developer's daily-driver terminal — this exact mistake SIGKILLed a live session. Scope the kill to what you spawned instead: kill the recorded PID, or match a unique path/socket, e.g.  pkill -f \"\$SOCKET\"  or  pkill -f 'out/clang-*/src/${hit}/${hit}'. (Protected names come from CLAUDE_KILL_GUARD_NAMES; a full explicit path like pkill -f '/usr/local/bin/${hit}' is still allowed when you truly mean the installed one.)"

case "$json_tool" in
  jq)
    jq -n --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    ;;
  python3)
    REASON="$reason" python3 -c \
      'import json,os; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":os.environ["REASON"]}}))'
    ;;
esac

exit 0
