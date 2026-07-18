---
name: sloc
description: Count the project's source lines of code — a grand total plus a per-module breakdown, each split into project code vs. test code (unit/integration). Use to gauge a codebase's size and complexity. Optionally scope to one or more paths.
allowed-tools: Bash, Read
argument-hint: "[path ...]"
---

# SLOC — source lines of code, per module, code vs. test

Measure how large the current project has become: a **grand total**, a
**per-module breakdown**, and within each module a split between **project
code** and **test code** (unit *and* integration/manual test harnesses).

Optional arguments narrow the scope to one or more path prefixes: $ARGUMENTS

## How to run it

Run the bundled counter from the project directory, forwarding any path
arguments verbatim:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/sloc/count.sh" $ARGUMENTS
```

It prints two ready-made tables — a **Module** table (Code / Test / Total /
Files / Test%) sorted by size, and a **Language** table. Show the script's
output as-is; do not reformat or recompute the numbers by hand.

## What it measures (and why)

- **Only tracked source.** Inside a git repo it counts `git ls-files` output,
  so `.gitignore`d build artifacts, vendored deps, and generated files are
  excluded — this is "code we wrote", not "bytes on disk". Outside git it falls
  back to `find` with a prune list (`build/`, `node_modules/`, `vendor/`, …).
- **Physical lines** (`wc -l`), including blanks and comments. This is the
  common "SLOC" figure. It is not a comment/blank/code split — see the
  enhancement note below if the user wants that.
- **Binaries never counted.** A source-extension allowlist keeps images,
  audio, and video out of the tally.

## Classification is data-driven (three tables in `count.sh`)

Everything that decides a file's fate lives in a table near the top of the
script — extend behaviour by adding a row, never by editing logic:

1. **`CODE_EXTS`** — which extensions are source code (C/C++, Rust, Go, Python,
   JS/TS, shaders, QML, shell, …). Drives both the file filter and the
   language table.
2. **Test patterns** (awk regexes in `count_awk`) — a file is *test code* when a
   path component is `test(s)`/`spec(s)`/`__tests__`/`testing`, or its basename
   ends `_test`/`_spec`/`Test`/`Spec`, starts `test_`/`spec_`, or matches
   `*.test.*`/`*.spec.*`. This deliberately captures both unit tests and
   integration/manual test scripts.
3. **`PRUNE_DIRS`** — directories skipped in the non-git fallback.

**Module attribution:** a path under a source container (`src/`, `lib/`,
`source/`) is attributed to its second component (`src/vtbackend/…` →
`vtbackend`); any other top-level directory is its own module; repo-root files
land in `(root)`. Test files stay attributed to their owning module, so a
module's Test% reflects its own test weight.

If the current project uses a convention the tables miss (e.g. a `.zig` file, or
a `qa/` test directory), read `count.sh`, add the row, and re-run — mention to
the user what you extended.

## Presenting the result

After running, add a **brief** interpretation beneath the tables (2–5 lines):

- Call out the largest modules and what dominates the total.
- Note the overall **test-to-code ratio** and any module that is conspicuously
  under- or over-tested (very low Test%, or Test% far above the project mean).
- Flag anything surprising (e.g. a "module" that is really a docs/scripts dir).

Keep it factual and short — the tables carry the detail.

## Optional: comment/blank/code breakdown

This skill is intentionally dependency-free. If the user explicitly wants a
true code-vs-comment-vs-blank split, and `tokei`, `cloc`, or `scc` is installed
(`command -v tokei cloc scc`), run that tool additionally for the finer
breakdown — but keep this script's per-module code/test split as the primary
answer, since those tools don't classify test code the same way.
