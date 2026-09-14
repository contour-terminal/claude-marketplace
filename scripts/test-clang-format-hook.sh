#!/usr/bin/env bash
# Drive plugins/contour-workflows/hooks/clang-format-edit.sh against synthetic project
# trees and FAKE clang-format executables that report chosen `--version` banners.
#
# Each case builds its own tree, runs the hook exactly the way hooks.json does (a JSON
# payload on stdin, `bash <hook>`), and asserts what happened to the file AND what the
# hook told Claude. PATH is a sandbox holding only shims for the tools the hook needs and
# the fakes a case installs, so a real clang-format on the runner can neither satisfy
# nor spoil a case.
#
# `--mutants` is the other direction. A suite that passes has only shown that it passes;
# it has not shown it can FAIL for the reason each case exists. Every row of the mutant
# table breaks one property of the hook (its anchor must occur exactly once, or the row
# refuses rather than testing an unmodified copy), runs the suite against the broken
# copy, and requires the set of failing cases to be EXACTLY the row's expected set — too
# few means a case cannot see its defect, too many means a case is failing for a reason
# nobody named.
#
# bash 3.2 compatible, like the hook it tests: CI runs it under macOS's /bin/bash too.
#
# Usage:
#   bash scripts/test-clang-format-hook.sh               run every case against the hook
#   bash scripts/test-clang-format-hook.sh --mutants     prove each case can fail
#   bash scripts/test-clang-format-hook.sh --hook <path> run the cases against another copy

set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
hook="$repo_root/plugins/contour-workflows/hooks/clang-format-edit.sh"
mode=cases
report_failures=""

while [ $# -gt 0 ]; do
  case "$1" in
    --hook) hook="${2:?--hook needs a path}"; shift 2 ;;
    --mutants) mode=mutants; shift ;;
    --report-failures) report_failures="${2:?--report-failures needs a path}"; shift 2 ;;
    *) printf 'test-clang-format-hook: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -f "$hook" ] || { printf 'test-clang-format-hook: no hook at %s\n' "$hook" >&2; exit 2; }

bash_bin=${BASH:-bash}

# --- mutants -------------------------------------------------------------------
# name | anchor (exact text, must occur once) | replacement | cases that must fail (space-separated)
mutant_rows() {
  cat <<'ROWS'
ignore-version|if [ "$banner" = "$want" ]; then|if true; then|mismatch_does_not_write mismatch_told_once_per_file second_path_match
no-dedupe|grep -Fxq -- "$record" "$state"|false|mismatch_told_once_per_file
undeclared-refuses|formatter=$(command -v clang-format 2>/dev/null) \|\| exit 0|exit 0|no_declaration_writes_first_on_path
binary-name-unchecked|clang-format\|clang-format-*) ;;|*) ;;|malformed_binary_not_clang_format binary_name_is_case_sensitive
backslash-path-allowed|*/*\|*"$backslash"*) declaration_error=|*/*) declaration_error=|malformed_binary_backslash_path
extension-case-sensitive|shopt -s nocasematch|:|uppercase_extension_formatted
nocasematch-leaks|shopt -u nocasematch|:|binary_name_is_case_sensitive
absolute-invocation|( cd "$file_dir" && exec "$formatter" --style=file "./$file_base" )|( exec "$formatter" --style=file "$file" )|relative_invocation
ROWS
}

if [ "$mode" = mutants ]; then
  work=$(mktemp -d "${TMPDIR:-/tmp}/cf-hook-mutants.XXXXXX") || exit 2
  trap 'rm -rf "$work"' EXIT
  original=$(cat "$hook"; printf x)
  original=${original%x}
  rows=0
  bad=0
  escaped_bar='\|'
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    # Split on unescaped '|': the anchors contain a literal '|' written as '\|'. The
    # escape is spelled through a quoted variable, because an unquoted backslash in a
    # pattern escapes the character after it rather than matching itself.
    row=${row//"$escaped_bar"/$'\001'}
    name=${row%%|*}; row=${row#*|}
    anchor=${row%%|*}; row=${row#*|}
    replacement=${row%%|*}; expected=${row#*|}
    anchor=${anchor//$'\001'/|}
    replacement=${replacement//$'\001'/|}
    rows=$((rows + 1))

    count=$(grep -Fc -- "$anchor" "$hook" || true)
    if [ "$count" != 1 ]; then
      printf 'FAIL mutant %s: its anchor occurs %s time(s) in the hook, not once, so it would test an unmodified or ambiguous copy:\n  %s\n' "$name" "$count" "$anchor"
      bad=$((bad + 1))
      continue
    fi
    mutant="$work/$name.sh"
    # Spliced from a prefix and a suffix rather than `${original/"$anchor"/"$replacement"}`:
    # bash 3.2 keeps the quotes of a quoted replacement literally and bash 5.2 expands `&`
    # in an unquoted one, and only prefix/suffix removal means the same on both.
    before=${original%%"$anchor"*}
    after=${original#*"$anchor"}
    printf '%s%s%s' "$before" "$replacement" "$after" > "$mutant"
    if cmp -s "$mutant" "$hook"; then
      printf 'FAIL mutant %s: the replacement left the hook byte-identical\n' "$name"
      bad=$((bad + 1))
      continue
    fi

    failures="$work/$name.failures"
    : > "$failures"
    "$bash_bin" "$0" --hook "$mutant" --report-failures "$failures" > "$work/$name.log" 2>&1
    rc=$?
    got=$(sort < "$failures" | tr '\n' ' ')
    got=${got% }
    want=$(for case_name in $expected; do printf '%s\n' "$case_name"; done | sort | tr '\n' ' ')
    want=${want% }
    if [ "$rc" -eq 0 ]; then
      printf 'FAIL mutant %s: the suite PASSED against it, so no case can see that defect\n' "$name"
      bad=$((bad + 1))
    elif [ "$got" != "$want" ]; then
      printf 'FAIL mutant %s: expected exactly [%s] to fail, got [%s] (exit %s)\n' "$name" "$want" "$got" "$rc"
      sed 's/^/    /' "$work/$name.log"
      bad=$((bad + 1))
    else
      printf 'ok   mutant %s: killed by [%s]\n' "$name" "$got"
    fi
  done <<< "$(mutant_rows)"

  if [ "$rows" -eq 0 ]; then
    printf 'FAIL: the mutant table is empty, so nothing was proven\n'
    exit 1
  fi
  printf '%s mutant(s) ran, %s not killed as expected\n' "$rows" "$bad"
  [ "$bad" -eq 0 ]
  exit $?
fi

# --- sandbox ---------------------------------------------------------------------
work=$(mktemp -d "${TMPDIR:-/tmp}/cf-hook-test.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
tools="$work/tools"
mkdir -p "$tools"

# One shim per tool the hook (or a fake) runs, each exec-ing the real binary by absolute
# path. A symlink would be simpler and is not portable: Git Bash copies instead of
# linking, and a copied MSYS executable cannot find its runtime DLL.
for tool in cat tr cmp mktemp rm mkdir cksum dirname grep sed sort; do
  real=$(command -v "$tool" 2>/dev/null) || { printf 'test-clang-format-hook: %s is not installed\n' "$tool" >&2; exit 2; }
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$tools/$tool"
  chmod +x "$tools/$tool"
done

json_tools=""
if command -v jq >/dev/null 2>&1; then
  json_tools="jq"
fi
if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
  json_tools="$json_tools python3"
fi
if [ -z "$json_tools" ]; then
  printf 'test-clang-format-hook: neither jq nor python3 is available, so the hook would no-op in every case and nothing could be tested\n' >&2
  exit 2
fi

# Put exactly one JSON tool on the sandbox PATH.
use_json_tool() {
  rm -f "$tools/jq" "$tools/python3"
  real=$(command -v "$1")
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$tools/$1"
  chmod +x "$tools/$1"
}

# make_fake <dir> <name> <banner> [empty]
# A formatter that answers --version with <banner> and otherwise squeezes runs of spaces
# and stamps which fake ran (`<name>@<dir>`). It logs its working directory and
# arguments to $FAKE_CALL_LOG. The script is static; what varies lives in sidecar files
# beside it, so no banner text is ever spliced into shell source.
make_fake() {
  mkdir -p "$1"
  cat > "$1/$2" <<'FAKE'
#!/bin/sh
if [ "$1" = "--version" ]; then cat "$0.banner"; exit 0; fi
printf '%s|%s\n' "$PWD" "$*" >> "$FAKE_CALL_LOG"
[ -f "$0.empty" ] && exit 0
for last; do :; done
grep -v '^// formatted by' "$last" | sed 's/   */ /g'
printf '// formatted by %s@%s\n' "${0##*/}" "${0%/*}"
FAKE
  chmod +x "$1/$2"
  printf '%s\n' "$3" > "$1/$2.banner"
  if [ "${4:-}" = empty ]; then
    : > "$1/$2.empty"
  fi
}

# make_crlf_fake <dir> <name> <banner>: --version ends its line with CRLF, as a Windows
# executable writing text-mode stdout does.
make_crlf_fake() {
  make_fake "$1" "$2" "$3"
  printf '%s\r\n' "$3" > "$1/$2.banner"
}

# new_project <dir>: a tree with a style file and an unformatted source.
new_project() {
  mkdir -p "$1/src"
  printf 'BasedOnStyle: LLVM\n' > "$1/.clang-format"
  printf 'int   main( ){return 0;}\n' > "$1/src/a.cpp"
}

payload_for() { # <file> [session]
  local sid="${2:-session-1}"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg f "$1" --arg s "$sid" '{session_id:$s,tool_name:"Edit",tool_input:{file_path:$f}}'
  else
    F="$1" S="$sid" python3 -c 'import json,os; print(json.dumps({"session_id":os.environ["S"],"tool_name":"Edit","tool_input":{"file_path":os.environ["F"]}}))'
  fi
}

# run_hook <path-prefix> <file> [session] -> sets $out and $rc
run_hook() {
  local prefix="$1" target="$2" sid="${3:-session-1}" path
  path="$tools"
  [ -n "$prefix" ] && path="$prefix:$tools"
  out=$(payload_for "$target" "$sid" | PATH="$path" TMPDIR="$work/tmp" "$bash_bin" "$hook" 2>"$work/stderr")
  rc=$?
}

mkdir -p "$work/tmp"
export FAKE_CALL_LOG="$work/calls.log"

fail_reason=""
expect() { # <condition-description> <test command...>
  local what="$1"
  shift
  if ! "$@"; then
    fail_reason="${fail_reason:+$fail_reason; }$what"
  fi
}
contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
not_contains() { ! contains "$1" "$2"; }
is_empty() { [ -z "$1" ]; }
exit_zero() { [ "$rc" -eq 0 ]; }
unchanged() { [ "$(cat "$1")" = 'int   main( ){return 0;}' ]; }
formatted_by() { [ "$(cat "$1")" = "int main( ){return 0;}
// formatted by $2" ]; }

Ubuntu='Ubuntu clang-format version 22.1.8 (++20260714014902+ca7933e47d3a-1~exp1~20260714135019.80)'
Other='clang-format version 22.1.3 (https://github.com/llvm/llvm-project e9846648fd6183ee6d8cbdb4502213fcf902a211)'
Pypi='clang-format version 22.1.8'

declare_build() { # <project> <lines...>
  local p="$1"
  shift
  printf '%s\n' "$@" > "$p/.clang-format-version"
}

# --- cases -------------------------------------------------------------------
case_match_writes_with_declared_build() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format-22 "$Ubuntu"
  make_fake "$p/bin" clang-format "$Other"
  declare_build "$p" "version: $Ubuntu" "binary: clang-format-22"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "file formatted by the declared build" formatted_by "$p/src/a.cpp" "clang-format-22@$p/bin"
  expect "context announces the rewrite" contains "$out" "reformatted"
  expect "context names the declared build" contains "$out" "22.1.8 (++20260714014902"
}

case_match_crlf_banner() {
  local p="$work/$1"; new_project "$p"
  make_crlf_fake "$p/bin" clang-format "$Ubuntu"
  declare_build "$p" "version: $Ubuntu"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "a CRLF banner still matches" formatted_by "$p/src/a.cpp" "clang-format@$p/bin"
}

case_mismatch_does_not_write() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Other"
  make_fake "$p/bin" clang-format-22 "$Pypi"
  declare_build "$p" "version: $Ubuntu" "binary: clang-format-22"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "file untouched" unchanged "$p/src/a.cpp"
  expect "context says it did not format" contains "$out" "did NOT format"
  expect "context names the expected build" contains "$out" "22.1.8 (++20260714014902"
  expect "context names what was found (other)" contains "$out" "22.1.3 (https://github.com/llvm/llvm-project"
  expect "context names what was found (pypi)" contains "$out" "clang-format version 22.1.8"
  expect "no formatter was asked to format" not_file "$work/calls.log"
}
not_file() { [ ! -s "$1" ]; }

case_mismatch_told_once_per_file() {
  local p="$work/$1"; new_project "$p"
  printf 'int   b( ){return 0;}\n' > "$p/src/b.cpp"
  make_fake "$p/bin" clang-format "$Other"
  declare_build "$p" "version: $Ubuntu"
  run_hook "$p/bin" "$p/src/a.cpp" s1
  expect "first edit is told" contains "$out" "did NOT format"
  run_hook "$p/bin" "$p/src/a.cpp" s1
  expect "second edit of the same file in the same session is silent" is_empty "$out"
  expect "and the file is still untouched" unchanged "$p/src/a.cpp"
  run_hook "$p/bin" "$p/src/b.cpp" s1
  expect "another file is told" contains "$out" "did NOT format"
  run_hook "$p/bin" "$p/src/a.cpp" s2
  expect "another session is told" contains "$out" "did NOT format"
  make_fake "$p/bin2" clang-format "$Pypi"
  run_hook "$p/bin:$p/bin2" "$p/src/a.cpp" s1
  expect "a changed reason is told again" contains "$out" "clang-format version 22.1.8"
  expect "exit 0" exit_zero
}

case_declared_but_no_binary() {
  local p="$work/$1"; new_project "$p"
  declare_build "$p" "version: $Ubuntu" "binary: clang-format-22"
  run_hook "" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "file untouched" unchanged "$p/src/a.cpp"
  expect "context says nothing was found" contains "$out" "no executable named any of: clang-format-22 clang-format"
}

case_malformed_unknown_key() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Ubuntu"
  declare_build "$p" "verison: $Ubuntu"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "file untouched" unchanged "$p/src/a.cpp"
  expect "context names the unknown key" contains "$out" "unknown key 'verison'"
}

case_malformed_no_version() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Ubuntu"
  declare_build "$p" "# only a comment" "binary: clang-format"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "file untouched (an empty declaration is not an absent one)" unchanged "$p/src/a.cpp"
  expect "context says there is no version" contains "$out" "no 'version:' line"
}

case_malformed_binary_not_clang_format() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" rm "$Ubuntu"
  declare_build "$p" "version: $Ubuntu" "binary: rm"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "file untouched" unchanged "$p/src/a.cpp"
  expect "context refuses the name" contains "$out" "not a bare clang-format or clang-format-* command name"
}

case_malformed_binary_path() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Ubuntu"
  declare_build "$p" "version: $Ubuntu" "binary: clang-format-x/../../bin/clang-format"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "file untouched" unchanged "$p/src/a.cpp"
  expect "context refuses the path" contains "$out" "a path rather than a command name"
}

case_malformed_binary_backslash_path() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Ubuntu"
  declare_build "$p" "version: $Ubuntu" 'binary: clang-format-x\..\..\bin\clang-format'
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "file untouched" unchanged "$p/src/a.cpp"
  expect "context refuses the backslashed path" contains "$out" "a path rather than a command name"
}

case_declaration_crlf_file() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Ubuntu"
  printf '# comment\r\n\r\nversion: %s\r\n' "$Ubuntu" > "$p/.clang-format-version"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "a CRLF declaration parses and matches" formatted_by "$p/src/a.cpp" "clang-format@$p/bin"
}

case_repeated_versions_any_matches() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Pypi"
  declare_build "$p" "version: $Ubuntu" "version: $Pypi"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "the second declared build is accepted" formatted_by "$p/src/a.cpp" "clang-format@$p/bin"
}

case_second_path_match() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/first" clang-format "$Other"
  make_fake "$p/second" clang-format "$Ubuntu"
  declare_build "$p" "version: $Ubuntu"
  run_hook "$p/first:$p/second" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "the matching build later on PATH formats, not the first one" formatted_by "$p/src/a.cpp" "clang-format@$p/second"
}

case_nearest_declaration_wins() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Other"
  declare_build "$p" "version: $Ubuntu"
  declare_build "$p/src" "version: $Other"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "the declaration beside the file governs it" formatted_by "$p/src/a.cpp" "clang-format@$p/bin"
}

case_no_declaration_writes_first_on_path() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Other"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "file formatted with the PATH clang-format" formatted_by "$p/src/a.cpp" "clang-format@$p/bin"
  expect "context names the build used" contains "$out" "22.1.3 (https://github.com/llvm/llvm-project"
  expect "context says no build is declared" contains "$out" "declares no build"
}

case_no_declaration_no_formatter_silent() {
  local p="$work/$1"; new_project "$p"
  run_hook "" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "file untouched" unchanged "$p/src/a.cpp"
  expect "nothing said" is_empty "$out"
}

case_uppercase_extension_formatted() {
  local p="$work/$1"; new_project "$p"
  # A new name rather than a rename: a case-only rename is a no-op on the
  # case-insensitive filesystems macOS and Windows default to.
  printf 'int   main( ){return 0;}\n' > "$p/src/B.CPP"
  make_fake "$p/bin" clang-format "$Ubuntu"
  declare_build "$p" "version: $Ubuntu"
  run_hook "$p/bin" "$p/src/B.CPP"
  expect "exit 0" exit_zero
  expect "an upper-case extension is still C++" formatted_by "$p/src/B.CPP" "clang-format@$p/bin"
}

case_binary_name_is_case_sensitive() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" CLANG-FORMAT-22 "$Ubuntu"
  declare_build "$p" "version: $Ubuntu" "binary: CLANG-FORMAT-22"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "file untouched" unchanged "$p/src/a.cpp"
  expect "the extension check's case-insensitivity does not leak into the name check" contains "$out" "not a bare clang-format or clang-format-* command name"
}

case_not_cxx_untouched() {
  local p="$work/$1"; new_project "$p"
  printf 'int   main( ){return 0;}\n' > "$p/src/a.txt"
  make_fake "$p/bin" clang-format "$Ubuntu"
  declare_build "$p" "version: $Ubuntu"
  run_hook "$p/bin" "$p/src/a.txt"
  expect "exit 0" exit_zero
  expect "non-C++ file untouched" unchanged "$p/src/a.txt"
  expect "nothing said" is_empty "$out"
}

case_no_style_untouched() {
  local p="$work/$1"; new_project "$p"
  rm -f "$p/.clang-format"
  make_fake "$p/bin" clang-format "$Ubuntu"
  declare_build "$p" "version: $Ubuntu"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "file untouched without a .clang-format" unchanged "$p/src/a.cpp"
  expect "nothing said" is_empty "$out"
}

case_already_formatted_no_write() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Ubuntu"
  declare_build "$p" "version: $Ubuntu"
  run_hook "$p/bin" "$p/src/a.cpp"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "still formatted" formatted_by "$p/src/a.cpp" "clang-format@$p/bin"
  expect "a no-op format says nothing" is_empty "$out"
}

case_empty_output_no_write() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Ubuntu" empty
  declare_build "$p" "version: $Ubuntu"
  run_hook "$p/bin" "$p/src/a.cpp"
  expect "exit 0" exit_zero
  expect "empty formatter output (an ignored file) never truncates the file" unchanged "$p/src/a.cpp"
  expect "nothing said" is_empty "$out"
}

case_relative_invocation() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Ubuntu"
  declare_build "$p" "version: $Ubuntu"
  : > "$work/calls.log"
  run_hook "$p/bin" "$p/src/a.cpp"
  local call want_dir
  call=$(cat "$work/calls.log")
  want_dir=$(cd "$p/src" && pwd)
  expect "exit 0" exit_zero
  expect "the formatter ran in the file's directory on a relative path" [ "$call" = "$want_dir|--style=file ./a.cpp" ]
}

case_malformed_payload_exit0() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Ubuntu"
  out=$(printf '{not json' | PATH="$p/bin:$tools" TMPDIR="$work/tmp" "$bash_bin" "$hook" 2>/dev/null)
  rc=$?
  expect "exit 0" exit_zero
  expect "nothing said" is_empty "$out"
}

case_windows_backslash_path() {
  local p="$work/$1"; new_project "$p"
  make_fake "$p/bin" clang-format "$Ubuntu"
  declare_build "$p" "version: $Ubuntu"
  local native
  native=$(cygpath -w "$p/src/a.cpp")
  run_hook "$p/bin" "$native"
  expect "exit 0" exit_zero
  expect "a backslashed drive path is formatted" formatted_by "$p/src/a.cpp" "clang-format@$p/bin"
}

cases="
match_writes_with_declared_build
match_crlf_banner
mismatch_does_not_write
mismatch_told_once_per_file
declared_but_no_binary
malformed_unknown_key
malformed_no_version
malformed_binary_not_clang_format
malformed_binary_path
malformed_binary_backslash_path
declaration_crlf_file
repeated_versions_any_matches
second_path_match
nearest_declaration_wins
no_declaration_writes_first_on_path
no_declaration_no_formatter_silent
uppercase_extension_formatted
binary_name_is_case_sensitive
not_cxx_untouched
no_style_untouched
already_formatted_no_write
empty_output_no_write
relative_invocation
malformed_payload_exit0
windows_backslash_path
"

ran=0
passed=0
failed=0
skipped=0
failed_names=""
for json_tool in $json_tools; do
  use_json_tool "$json_tool"
  for name in $cases; do
    if [ "$name" = windows_backslash_path ] && ! command -v cygpath >/dev/null 2>&1; then
      printf 'SKIP [%s] %s: no cygpath, so this host has no drive-letter paths\n' "$json_tool" "$name"
      skipped=$((skipped + 1))
      continue
    fi
    rm -f "$work/calls.log"
    fail_reason=""
    out=""
    rc=0
    "case_$name" "$json_tool-$name"
    ran=$((ran + 1))
    if [ -z "$fail_reason" ]; then
      printf 'ok   [%s] %s\n' "$json_tool" "$name"
      passed=$((passed + 1))
    else
      printf 'FAIL [%s] %s: %s\n' "$json_tool" "$name" "$fail_reason"
      [ -s "$work/stderr" ] && sed 's/^/    stderr: /' "$work/stderr"
      [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    output: /'
      failed=$((failed + 1))
      case " $failed_names " in *" $name "*) ;; *) failed_names="$failed_names $name" ;; esac
    fi
  done
done

if [ -n "$report_failures" ]; then
  for name in $failed_names; do printf '%s\n' "$name"; done > "$report_failures"
fi

printf '%s case run(s) with JSON tool(s) [%s]: %s passed, %s failed, %s skipped\n' \
  "$ran" "${json_tools# }" "$passed" "$failed" "$skipped"
[ "$ran" -gt 0 ] || { printf 'FAIL: no case ran\n'; exit 1; }
[ "$failed" -eq 0 ]
