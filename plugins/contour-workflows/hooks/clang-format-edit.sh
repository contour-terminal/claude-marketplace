#!/usr/bin/env bash
# PostToolUse hook: run clang-format on C/C++ files that Claude just edited.
#
# Deliberately conservative — it no-ops unless every precondition holds, so that
# installing this plugin never reformats files in a project that did not ask for it:
#
#   * the tool payload names a file that still exists
#   * the file has a C/C++ extension
#   * clang-format is on PATH
#   * a .clang-format exists at or above the file's directory
#
# Always exits 0. A formatter must never break the session.

set -uo pipefail

payload=$(cat)

# --- extract .tool_input.file_path -------------------------------------------
# jq preferred; python3 as fallback. Without either, do nothing rather than
# risk a fragile regex parse of arbitrary JSON (paths may contain quotes).
json_tool=""
if command -v jq >/dev/null 2>&1; then
  json_tool="jq"
  file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
elif command -v python3 >/dev/null 2>&1; then
  json_tool="python3"
  file=$(printf '%s' "$payload" | python3 -c \
    'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("file_path","") or "")
except Exception: pass' 2>/dev/null)
else
  exit 0
fi

[ -n "${file:-}" ] || exit 0
[ -f "$file" ] || exit 0   # deleted, renamed, or a directory

# --- C/C++ only ---------------------------------------------------------------
# Lowercase via tr, not ${file,,} — the latter needs bash 4.0+ and macOS ships 3.2.
file_lc=$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')
case "$file_lc" in
  *.c|*.cc|*.cpp|*.cxx|*.c++|*.h|*.hh|*.hpp|*.hxx|*.h++|*.inl|*.ipp|*.tpp|*.cu|*.cuh) ;;
  *) exit 0 ;;
esac

command -v clang-format >/dev/null 2>&1 || exit 0

# --- require a .clang-format at or above the file ------------------------------
# Without one, clang-format would impose its built-in LLVM style on a project
# that never opted in — which is worse than doing nothing.
dir=$(cd "$(dirname -- "$file")" 2>/dev/null && pwd) || exit 0
found=""
while [ -n "$dir" ]; do
  if [ -f "$dir/.clang-format" ] || [ -f "$dir/_clang-format" ]; then
    found=1
    break
  fi
  [ "$dir" = "/" ] && break
  dir=$(dirname -- "$dir")
done
[ -n "$found" ] || exit 0

# --- format -------------------------------------------------------------------
# Only rewrite when the result actually differs, so unchanged files keep their
# mtime and no needless write is reported.
formatted=$(clang-format --style=file "$file" 2>/dev/null) || exit 0
[ -n "$formatted" ] || exit 0

if ! printf '%s\n' "$formatted" | cmp -s - "$file"; then
  printf '%s\n' "$formatted" > "$file" || exit 0

  # Announce the rewrite. A PostToolUse hook that changes a file behind Claude's
  # back leaves its cached view stale, so a later Edit can fail on a string that
  # no longer matches. Emitting additionalContext tells Claude to re-read before
  # editing this file again.
  msg="clang-format reformatted $file after the edit. The on-disk content now differs from what was just written — re-read it before making further edits to it."
  case "$json_tool" in
    jq)
      jq -n --arg m "$msg" \
        '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
      ;;
    python3)
      MSG="$msg" python3 -c \
        'import json,os; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":os.environ["MSG"]}}))'
      ;;
  esac
fi

exit 0
