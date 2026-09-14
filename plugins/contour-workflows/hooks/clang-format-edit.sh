#!/usr/bin/env bash
# PostToolUse hook: run clang-format on C/C++ files that Claude just edited.
#
# Deliberately conservative — it no-ops unless every precondition holds, so that
# installing this plugin never reformats files in a project that did not ask for it:
#
#   * the tool payload names a file that still exists
#   * the file has a C/C++ extension
#   * a .clang-format exists at or above the file's directory
#   * a clang-format is found — and, where the project DECLARES the build it is
#     judged by, that build exactly (see "The declared build" below)
#
# Always exits 0. A formatter must never break the session.
#
# ## The declared build
#
# Two clang-format builds can disagree about the same file, including two that report
# the same release number: a CI job that installs a distribution snapshot and a
# developer's IDE-bundled binary are both "22.1.x" and are not the same formatter. A
# formatter at the wrong build rewrites code the project's own check already accepted,
# and every line of the resulting diff is "just formatting", so review does not catch
# it. Running such a binary with a write, automatically, on every edit is the worst
# place for that to happen.
#
# So a project may state which build it is judged by, in a `.clang-format-version`
# file at or above the edited file (the nearest one wins):
#
#     # The clang-format build CI checks formatting with: PyPI's clang-format==22.1.8.
#     version: clang-format version 22.1.8
#
#   version:  the first line of `clang-format --version`, compared EXACTLY — the whole
#             line, vendor prefix and build suffix included, because the build suffix is
#             the part that tells two same-numbered builds apart. Repeatable: each line
#             is one accepted build. At least one is required.
#   binary:   a command name to try before `clang-format`, e.g. `clang-format-22`.
#             Repeatable, tried in order. It must be a bare `clang-format` or
#             `clang-format-*` name, resolved on PATH: a committed file must not be able
#             to make this hook execute a program the repository ships, nor one that is
#             not a formatter.
#
# Blank lines and `#` comments are ignored; any other line is an error. With a
# declaration, the hook tries every matching executable on PATH for each candidate name
# — not only the first — and formats with the first whose banner is declared. If none
# is, or the declaration cannot be read, it writes NOTHING and tells Claude why, once per
# file per session, so the session formats with the declared build itself.
#
# Without a declaration the hook behaves as it always has — the first `clang-format` on
# PATH — because a project that states no build cannot be wrong about one, and turning
# the hook off for every project that has not adopted the file would be a silent
# regression. It does name the build it used whenever it rewrites a file, so which
# formatter touched the tree is stated rather than inherited.
#
# The formatter runs with the file's directory as its working directory and a relative
# path, so a user-side wrapper that forwards its arguments into another environment
# (e.g. a `clang-format-22` on PATH that calls into WSL) needs no path translation. The
# wrapper is still held to the declaration: its `--version` must report the build.

set -uo pipefail

# Every process this hook starts is paid on every edit, and on Git Bash a start costs
# tens of milliseconds, so the helpers below set variables instead of printing into a
# `$( )`, and paths are split with parameter expansion rather than dirname/tr.

payload=$(cat)

# --- extract .session_id and .tool_input.file_path ------------------------------
# jq preferred; python3 as fallback. Without either, do nothing rather than
# risk a fragile regex parse of arbitrary JSON (paths may contain quotes). One parse
# yields both: the session id on the first line, the path after it.
json_tool=""
if command -v jq >/dev/null 2>&1; then
  json_tool="jq"
  fields=$(printf '%s' "$payload" | jq -r '(.session_id // "") + "\n" + (.tool_input.file_path // "")' 2>/dev/null)
elif command -v python3 >/dev/null 2>&1; then
  json_tool="python3"
  fields=$(printf '%s' "$payload" | python3 -c \
    'import json,sys
try:
  d=json.load(sys.stdin)
  print((d.get("session_id") or "") + "\n" + ((d.get("tool_input") or {}).get("file_path") or ""))
except Exception: pass' 2>/dev/null)
else
  exit 0
fi
case "${fields:-}" in
  *$'\n'*) session=${fields%%$'\n'*}; file=${fields#*$'\n'} ;;
  *) exit 0 ;;
esac

# A Windows drive path may arrive with backslashes; Git Bash reads those as escapes
# rather than separators, so no directory would be found in it. Only a drive-letter
# path is rewritten — on POSIX a backslash is a legal filename byte. The backslash is
# spelled through a variable and a quoted pattern: an unquoted `\\*` in a case pattern
# matches nothing, silently.
backslash=$'\\'
case "$file" in
  [A-Za-z]:"$backslash"*) file=${file//"$backslash"//} ;;
esac

[ -n "$file" ] || exit 0
[ -f "$file" ] || exit 0   # deleted, renamed, or a directory

# --- C/C++ only ---------------------------------------------------------------
# nocasematch rather than ${file,,}, which needs bash 4.0+ where macOS ships 3.2.
shopt -s nocasematch
case "$file" in
  *.c|*.cc|*.cpp|*.cxx|*.c++|*.h|*.hh|*.hpp|*.hxx|*.h++|*.inl|*.ipp|*.tpp|*.cu|*.cuh) ;;
  *) exit 0 ;;
esac
shopt -u nocasematch

case "$file" in
  */*) file_dir=${file%/*}; file_dir=${file_dir:-/} ;;
  *) file_dir=. ;;
esac
file_dir=$(cd "$file_dir" 2>/dev/null && pwd) || exit 0
file_base=${file##*/}

# trim <text>: sets `trimmed` to <text> without leading or trailing whitespace.
trim() {
  trimmed=$1
  trimmed=${trimmed#"${trimmed%%[![:space:]]*}"}
  trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
}

# banner_of <binary>: sets `banner` to the first non-empty line of `<binary> --version`,
# without the carriage return a Windows executable ends it with.
banner_of() {
  local out line
  banner=""
  out=$("$1" --version 2>/dev/null) || true
  while IFS= read -r line; do
    trim "${line%$'\r'}"
    if [ -n "$trimmed" ]; then
      banner=$trimmed
      return 0
    fi
  done <<< "$out"
  return 0
}

# --- emit additionalContext ------------------------------------------------------
emit_context() {
  case "$json_tool" in
    jq)
      jq -n --arg m "$1" \
        '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
      ;;
    python3)
      MSG="$1" python3 -c \
        'import json,os; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":os.environ["MSG"]}}))'
      ;;
  esac
}

# Say a refusal once per (session, file, reason). The same edit loop touching one file
# twenty times needs to hear it once; a CHANGED reason — a binary installed or removed
# mid-session — is news and is said again. Without a session id, or where the record
# cannot be written, it is said every time: repeating is the safe direction.
emit_once() {
  local message="$1" sid state_dir state record
  sid=${session//[!A-Za-z0-9._-]/}
  if [ -n "$sid" ]; then
    state_dir="${TMPDIR:-/tmp}/claude-clang-format-edit"
    state="$state_dir/$sid"
    record=$(printf '%s\n%s' "$file_dir/$file_base" "$message" | cksum)
    if [ -f "$state" ] && grep -Fxq -- "$record" "$state" 2>/dev/null; then
      return 0
    fi
    { [ -d "$state_dir" ] || mkdir -p "$state_dir" 2>/dev/null; } \
      && printf '%s\n' "$record" >> "$state" 2>/dev/null
  fi
  emit_context "$message"
}

# --- find the style file and the declaration, walking up once ------------------
# Without a .clang-format, clang-format would impose its built-in LLVM style on a
# project that never opted in — which is worse than doing nothing.
style=""
declaration=""
dir=$file_dir
while [ -n "$dir" ]; do
  if [ -z "$style" ] && { [ -f "$dir/.clang-format" ] || [ -f "$dir/_clang-format" ]; }; then
    style=1
  fi
  if [ -z "$declaration" ] && [ -f "$dir/.clang-format-version" ]; then
    declaration="$dir/.clang-format-version"
  fi
  [ -n "$style" ] && [ -n "$declaration" ] && break
  [ "$dir" = "/" ] && break
  parent=${dir%/*}
  parent=${parent:-/}
  [ "$parent" = "$dir" ] && break
  dir=$parent
done
[ -n "$style" ] || exit 0

# --- read the declaration ----------------------------------------------------------
declared_versions=""
declared_binaries=""
declaration_error=""
if [ -n "$declaration" ]; then
  if [ ! -r "$declaration" ]; then
    declaration_error="it is not readable"
  else
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
      lineno=$((lineno + 1))
      trim "${line%$'\r'}"
      line=$trimmed
      case "$line" in
        ''|'#'*) continue ;;
        *:*) ;;
        *) declaration_error="line $lineno is not 'key: value'"; break ;;
      esac
      trim "${line%%:*}"
      key=$trimmed
      trim "${line#*:}"
      value=$trimmed
      if [ -z "$value" ]; then
        declaration_error="line $lineno gives '$key' no value"
        break
      fi
      case "$key" in
        version)
          declared_versions="$declared_versions$value"$'\n'
          ;;
        binary)
          case "$value" in
            clang-format|clang-format-*) ;;
            *) declaration_error="line $lineno names binary '$value', which is not a bare clang-format or clang-format-* command name"; break ;;
          esac
          case "$value" in
            */*|*"$backslash"*) declaration_error="line $lineno names binary '$value', which is a path rather than a command name"; break ;;
          esac
          declared_binaries="$declared_binaries$value"$'\n'
          ;;
        *)
          declaration_error="line $lineno has unknown key '$key' (known: version, binary)"
          break
          ;;
      esac
    done < "$declaration"
    if [ -z "$declaration_error" ] && [ -z "$declared_versions" ]; then
      declaration_error="it has no 'version:' line"
    fi
  fi
fi

if [ -n "$declaration_error" ]; then
  emit_once "clang-format did NOT format $file_dir/$file_base: the formatter declaration $declaration could not be used ($declaration_error), so the build this project is judged by is unknown and nothing was written. The file is exactly as the edit left it. Fix the declaration, or format the file yourself with the build the project's CI uses."
  exit 0
fi

# --- choose the formatter ----------------------------------------------------------
formatter=""
formatter_banner=""
if [ -n "$declaration" ]; then
  names="${declared_binaries}clang-format"
  probed=""
  seen=$'\n'
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    paths=$(type -ap "$name" 2>/dev/null) || true
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      case "$seen" in
        *$'\n'"$candidate"$'\n'*) continue ;;
      esac
      seen="$seen$candidate"$'\n'
      banner_of "$candidate"
      probed="$probed"$'\n'"  $candidate: ${banner:-<no version output>}"
      while IFS= read -r want; do
        [ -n "$want" ] || continue
        if [ "$banner" = "$want" ]; then
          formatter=$candidate
          formatter_banner=$banner
          break
        fi
      done <<< "$declared_versions"
      [ -n "$formatter" ] && break
    done <<< "$paths"
    [ -n "$formatter" ] && break
  done <<< "$names"

  if [ -z "$formatter" ]; then
    expected=""
    while IFS= read -r want; do
      [ -n "$want" ] && expected="$expected"$'\n'"  $want"
    done <<< "$declared_versions"
    if [ -z "$probed" ]; then
      found=$'\n'"  no executable named any of: ${names//$'\n'/ }"
    else
      found=$probed
    fi
    emit_once "clang-format did NOT format $file_dir/$file_base: $declaration declares the clang-format build this project is judged by, and no clang-format on PATH is that build, so nothing was written. The file is exactly as the edit left it.
Expected (the whole --version line, exactly):${expected}
Found:${found}
Format the file with the declared build before committing (for example through the environment that has it installed). Do not format it with any other clang-format: a different build can rewrite code the declared one accepts."
    exit 0
  fi
else
  formatter=$(command -v clang-format 2>/dev/null) || exit 0
  [ -n "$formatter" ] || exit 0
fi

# --- format -------------------------------------------------------------------
# Written through a temporary file so what lands on disk is the formatter's exact
# output, and only when it differs, so unchanged files keep their mtime and no needless
# write is reported. Empty output is also what a file listed in .clang-format-ignore
# produces, so it never overwrites anything.
tmp=$(mktemp "${TMPDIR:-/tmp}/clang-format-edit.XXXXXX") || exit 0
trap 'rm -f "$tmp"' EXIT

( cd "$file_dir" && exec "$formatter" --style=file "./$file_base" ) > "$tmp" 2>/dev/null || exit 0
[ -s "$tmp" ] || exit 0

if ! cmp -s "$tmp" "$file"; then
  cat "$tmp" > "$file" || exit 0

  # Announce the rewrite. A PostToolUse hook that changes a file behind Claude's
  # back leaves its cached view stale, so a later Edit can fail on a string that
  # no longer matches. Emitting additionalContext tells Claude to re-read before
  # editing this file again.
  if [ -n "$declaration" ]; then
    provenance="the build declared in $declaration"
  else
    banner_of "$formatter"
    formatter_banner=$banner
    provenance="the first clang-format on PATH; this project declares no build in a .clang-format-version"
  fi
  emit_context "clang-format (${formatter_banner:-unknown version}; $provenance) reformatted $file after the edit. The on-disk content now differs from what was just written — re-read it before making further edits to it."
fi

exit 0
