---
name: sanitize
description: Build and run tests under AddressSanitizer, UndefinedBehaviorSanitizer, and ThreadSanitizer to catch memory errors, UB, and data races that ordinary test runs miss. Use before merging changes to buffer handling, parsing, lifetime/ownership, or threading — or when a test fails intermittently, crashes non-deterministically, or produces corrupted output.
argument-hint: "[asan|ubsan|tsan|all] [test-target-or-filter]"
allowed-tools: Bash(cmake:*), Bash(ctest:*), Bash(git:*), Bash(ls:*), Bash(find:*), Bash(grep:*), Bash(nproc:*), Read, Grep, Glob, Edit
---

# Sanitize

Run the test suite under sanitizer instrumentation and turn each report into a diagnosis.

Sanitizers find bugs that are *already there* but invisible: a read one byte past a buffer, a
use-after-free that happens to land on still-mapped memory, signed overflow the optimizer is
entitled to exploit, a race that only loses on a loaded machine. Ordinary green tests say
nothing about any of it.

## Which sanitizer to run

| Sanitizer | Catches | Cost |
|---|---|---|
| **ASan** | heap/stack buffer overflow, use-after-free, use-after-return, double free, leaks | ~2× slower, ~3× memory |
| **UBSan** | signed overflow, invalid shifts, null/misaligned deref, bad enum/bool values, invalid casts | ~1.2× slower |
| **TSan** | data races, lock-order inversions | ~5–15× slower, ~5–10× memory |

ASan and UBSan compose in one build. **TSan is mutually exclusive with ASan** — it needs its
own build tree. Interpret `$ARGUMENTS`:

- `asan`, `ubsan`, `tsan` — run just that one
- `all` — run ASan+UBSan, then TSan separately
- *(empty)* — default to ASan+UBSan; mention TSan is available if the code is threaded
- a trailing argument that is not a sanitizer name is a **test target or filter**

## Step 1 — Find the project's sanitizer build

Prefer the project's own configuration over inventing one. Check, in order:

1. **CMake presets** — `cmake --list-presets`. Look for names containing `asan`, `sanitize`,
   `tsan`, `msan`. A project may combine ASan+UBSan under a single preset name.
2. **The project's `AGENT.md` / `CLAUDE.md`** — it may name the sanitizer preset and the
   expected invocation directly. This is authoritative; follow it.
3. **Existing CMake options** — `grep -rn "SANITIZE\|fsanitize" CMakeLists.txt cmake/ 2>/dev/null`.
4. **CI config** — `.github/workflows/*.yml` often reveals how sanitizer builds are invoked.

If you find a preset, use it:
```
cmake --build --preset <sanitizer-preset> -j$(nproc)
```

If none exists, configure an ad-hoc build tree **without modifying the project**:
```
cmake -B out/asan -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_CXX_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g" \
      -DCMAKE_C_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g"
cmake --build out/asan -j$(nproc)
```
For TSan, substitute `-fsanitize=thread` and a separate directory (`out/tsan`). Never edit
`CMakeLists.txt` to add sanitizer flags — the build tree is disposable, the project is not.

Sanitizers need a **Debug or RelWithDebInfo** build with frame pointers, or the reports have
no usable stack traces.

## Step 2 — Set the runtime options

Sanitizers default to permissive. Tighten them so problems fail loudly:

```bash
export ASAN_OPTIONS="detect_leaks=1:abort_on_error=0:print_stacktrace=1:detect_stack_use_after_return=1:strict_string_checks=1"
export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=0"
export TSAN_OPTIONS="halt_on_error=0:second_deadlock_stack=1"
```

`halt_on_error=0` matters: it collects *every* finding in one run instead of stopping at the
first. If the project ships a suppressions file (`*.supp`, often referenced in CI), honour it
via `ASAN_OPTIONS=suppressions=<path>` — but read it first and report what it is hiding.

Leak detection needs the process to exit cleanly; a test harness that calls `_exit()` or
aborts will report nothing.

## Step 3 — Run

Run the full suite, or the target/filter from `$ARGUMENTS`:
```
ctest --preset <sanitizer-preset> --output-on-failure
```
or directly, which gives cleaner output for a single target:
```
./out/asan/src/<module>/<module>_test "<filter>"
```

Sanitizer builds are slow. For a targeted investigation, run the narrowest relevant target
first, then widen. **Say so if you narrowed** — a clean single-target run is not a clean suite.

For **TSan**, a single pass proves little: races are scheduling-dependent. Run threaded tests
several times (5–10) before calling them clean, and say how many passes you ran.

## Step 4 — Diagnose each report

A sanitizer report is a *starting point*, not a conclusion. For each finding:

1. **Read the report properly.** The first stack is where the bad access happened; for
   ASan the second (`allocated by` / `freed by`) is usually where the actual bug lives.
   `SUMMARY` alone is not enough to diagnose anything.
2. **Read the implicated code** and determine the real defect: who owns the memory, what
   invariant broke, which lifetime ended early.
3. **Classify:**
   - **Real bug in the change under test** — fix it.
   - **Real pre-existing bug** — report it with file:line; fix only if in scope, otherwise
     flag it clearly for follow-up.
   - **Third-party / system library** — likely needs a suppression, not a fix. Confirm the
     stack genuinely leaves first-party code before concluding this.
   - **False positive** — genuinely rare. Requires an explicit argument for why the tool is
     wrong. Treat this verdict with suspicion.
4. **Never silence a finding to make the run green.** Adding a suppression, an
   `ASAN_OPTIONS` relaxation, or `__attribute__((no_sanitize))` is a last resort that needs
   a written justification naming the reason.

Common signatures worth recognizing:
- `heap-use-after-free` → object outlived by a reference/iterator/`string_view`/`span`
- `stack-use-after-return` → returned a reference or pointer to a local
- `heap-buffer-overflow` in a parser → off-by-one on a length or terminator check
- `container-overflow` → indexing past `size()` on a container with a valid capacity
- UBSan `signed integer overflow` → arithmetic on a width that cannot hold the result
- TSan race on a `bool` flag → a "benign" flag that still needs to be atomic

## Step 5 — Fix and re-verify

Apply minimal fixes addressing the root cause. Then re-run the same sanitizer configuration
and confirm the report is gone. A fix that merely relocates the symptom will show up as a
different report — check that the new run is genuinely clean, not differently dirty.

Finally, confirm the ordinary (non-sanitizer) test suite still passes.

## Step 6 — Report

- **Configuration** — which sanitizers, which preset or flags, which targets, how many runs
  (TSan especially).
- **Findings** — one entry each: type, location (file:line), root cause, classification.
- **Fixes applied** — what changed and why.
- **Left open** — pre-existing or third-party issues, with enough detail to file them.
- **Coverage caveat** — sanitizers only observe *executed* code. If the suite does not
  exercise the changed path, a clean run proves nothing. Say so explicitly when it applies.
- **Risk assessment** — Low / Medium / High.

## Rules

- NEVER modify the project's build files to add sanitizer flags — use a separate build tree.
- NEVER add a suppression or `no_sanitize` attribute to make output clean without written
  justification.
- NEVER report "clean" from a narrowed run without stating what was narrowed.
- NEVER conclude "false positive" without a concrete argument for why the tool is wrong.
- ASan and TSan cannot share a build tree.
- Prefer the project's existing preset over ad-hoc flags.
- A clean sanitizer run over code the tests never execute is not evidence of correctness.
