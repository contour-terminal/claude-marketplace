---
name: apply-guidelines
description: Refactor a C++ codebase into conformance with the project's own coding guidelines — configuration at construction time, dependency injection, data-driven design, enum class over bool in API surface, std::expected error handling, testability, C++23 idioms. Surveys and reports findings before touching anything, then refactors module by module with a build and test run between passes. Optionally scope to one or more paths; defaults to the whole first-party source tree.
argument-hint: "[path ...]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# Apply the coding guidelines

Bring existing code into conformance with the project's design principles. This is a
*refactoring* skill: behaviour-preserving by default, driven by a survey you present before you
edit anything.

Optional arguments narrow the scope to one or more path prefixes: $ARGUMENTS

## Step 0 — Resolve the scope, and say what it is

- **With arguments**: the scope is exactly those paths.
- **Without arguments**: the scope is the whole first-party source tree. Derive it from the
  repository-layout section of `AGENT.md` when the project has one; otherwise fall back to `src/`
  (or the project's equivalent), excluding vendored dependencies, generated code, and build trees.

Echo the resolved scope and the module list before doing anything else. A full-codebase run is
large — the user must be able to see, at a glance, what you are about to inspect.

## Step 1 — Read the rules from the project, not from memory

The rules live in the repository, and this skill does not restate them:

1. `AGENT.md` / `CLAUDE.md` — the design principles and their project-specific carve-outs.
2. Every `.clang-tidy` in scope (projects commonly layer a base file with per-module overrides)
   and `.clang-format`. These are machine-enforced and win over any prose.
3. The `cpp-guidelines` skill for the cross-project baseline.

Where a guideline and the code around it disagree, **follow the surrounding code** and report
the inconsistency. Consistency within a file beats compliance in the abstract.

## Step 2 — Survey (mandatory; no edits yet)

Find candidate violations across the scope. The recipes below are starting points, not the
definition — read what they turn up and judge it.

**Configuration after construction**

```bash
grep -rn "void set[A-Z]" --include='*.h' <scope>          # candidate setters
grep -rn "static void set\|static inline [^c]" --include='*.h' <scope>   # global knobs
grep -rn "void \(init\|initialize\|setup\|configure\)[A-Za-z]*(" --include='*.h' <scope>
```

Then classify each hit with the test from the guidelines: *would two differently-configured
instances be two different objects, or one object in two states?* A setter over **domain state**
the class exists to manage is not a finding. A setter over **policy, collaborators or tuning**
is. A `static` setter is always a finding.

Also look for: default constructors followed by a run of setters at every call site; singletons
(`static X* instance()`); objects that must be primed before their first real method call.

**Call-site evidence — construction immediately followed by setter calls**

Setters declared in *base classes* (outside the scope) are easily missed because the header
grep only covers the scope's own files. The real violation lives at the call site:

```bash
# Find construction of heap objects whose pointer is then immediately configured
# with setters — the hallmark of two-phase init at the call site.
grep -rnE "make_unique<|make_shared<| new " --include='*.cpp' <scope> -A 6 \
  | grep -B 6 "->set[A-Z]"
```

For each match:
- Is the setter called on the *same variable* that was just constructed? If so, it's a finding.
- Does the setter configure **policy, collaborators, or tuning** (not domain state)? If so,
  the parameters should be constructor arguments instead.
- Check *inherited* setters too: if class `Foo` derives from `Bar` which declares `setX()`,
  and a call site constructs `Foo` then calls `->setX()`, that's equally a violation —
  add the parameters to `Foo`'s constructor and have it call `Bar::setX()` in its body.

This is how `SelfUnbindingChannelPty` was missed: `setWriteSink` / `setResizeSink` are
declared on the base class `ChannelPty` (in `src/vtpty/`), outside the scope; only the call
sites in `NativeController.cpp` and `TmuxController.cpp` showed the pattern.

**`bool` in parameters, returns and members**

```bash
grep -rnE "\(bool [a-z_]|, *bool [a-z_]" --include='*.h' <scope>   # bool parameters
grep -rnE "bool [a-z_]+ *= *(true|false)" --include='*.h' <scope>  # defaulted — worst case
grep -rnE "^[[:space:]]+bool [_a-z][A-Za-z0-9_]* *(=[^;]*)?;" --include='*.h' <scope>  # members
```

Multi-line signatures hide from the first recipe when `bool` starts the line — check the
declarations around any hit. The third recipe insists on the `;` (with an optional initializer)
precisely to exclude member *functions* returning `bool`; drop that and roughly two thirds of the
hits are `bool operator==`-style declarations. To confirm a suspect signature from the other side,
grep its call sites for bare literals (`grep -rn "FunctionName(" --include='*.cpp' <scope>`); do
not try to enumerate call sites with a `true|false` pattern, it drowns in noise.

Classify with the question from the guidelines: *at the call site, can you tell what `true` means
without opening the header?*

- A `bool` **return** whose function name asks the question — `empty()`, `contains()`,
  `is…`/`has…`/`can…`, a comparison operator, `explicit operator bool()` — is **not** a finding.
- A `bool` return on a *fallible* operation belongs to **error handling** below, not here: the fix
  is `std::expected<void, E>`, which carries the reason, not an enum.
- A setter that only assigns a `bool` member: judge the **member** first. Fix the member and the
  setter follows it; if the member is legitimately boolean, the setter is not a finding either.
- Framework overrides and slots, concept-required predicates, and JSON/protocol/config boundaries
  are **document**, not **fix**.
- Two or more `bool` members in one type: where some combinations cannot legally occur they are one
  `enum class` of states. Flag that one explicitly — collapsing combinations that were reachable
  changes behaviour and needs a test pinning it.

Rank by how much the call site loses: several `bool`s in one signature, then a defaulted `bool`
parameter, then a single `bool` parameter, then a `bool` member, then a `bool` return.

The clearest example in Contour is `TerminalSession`'s guarded-role API — four methods taking
`(bool allow, bool remember)`, plus `executeRole(GuardedRole, bool, bool)`. The two arguments are
adjacent, identically typed, silently exchangeable, and together they gate a permission decision:
swapping them at one call site grants what should have been remembered and remembers what should
have been granted, with no diagnostic. Two enums make the call sites legible and make the swap a
compile error. Signatures like this one are where to start, not the long tail of single flags.

It also shows the cost to check for first: those four are `Q_INVOKABLE`, so their real call sites
are in QML. An enum reaches QML only once it is registered with the meta-object system (`Q_ENUM`),
and the QML side then has to name the enumerators. That is a fine refactor, but it is a wider one
than the header suggests — find the QML callers before promising it, and split the C++-internal
`executeRole` from the QML-facing four if only part of it is worth doing now.

Note also that a struct of public `bool` fields deserialized from a config file is the documented
boundary case, and there are usually many of them. Convert at the boundary if anywhere; do not
open a sweep of the config schema unless the user asked for one.

**Other principles**

- **DI** — construction of concrete I/O, clocks, RNG, filesystem or network access inside a
  class rather than injection through an interface.
- **Data-driven** — `switch`/`if` ladders over an enum, or parallel tables that must be edited
  together. Ask: "if a sixth case showed up tomorrow, how many places would I edit?"
- **Error handling** — fallible API returning `bool`, a sentinel, or a bare `std::optional`
  where `std::expected<T, E>` would carry the reason. Exceptions used for recoverable failures.
- **Testability** — logic that cannot be reached headlessly because a pure decision is welded to
  I/O or a UI type. The fix is to extract the decision into a dependency-free header.
- **C++23 and const correctness** — `std::span`, `std::ranges`, `std::format`, structured
  bindings, deducing `this`; missing `[[nodiscard]]`; member functions that could be `const`;
  C-style loops. Missing Doxygen on public API.

**Present the findings as a ranked table before editing anything** — `file:line`, principle,
what is wrong, and a classification:

| Class | Meaning |
|---|---|
| **fix** | A real violation with a behaviour-preserving refactor. |
| **document** | A justified exception. The fix is a comment at the declaration saying *why*, not a refactor. |
| **out of scope** | Real, but needs a design change, an API break, or work the user has not asked for. List it; do not do it. |

Sort by severity, group by module, and state the totals. **Stop here and get agreement on what
to fix before making the first edit.** On a full-codebase run, also propose which modules to
take first.

The **document** class matters as much as **fix**. The guidelines list exceptions — live
reconfiguration, externally-driven geometry, framework-mandated property assignment, deliberate
rebinding seams, cyclic wiring. When a finding is one of these, the correct outcome is a
documented declaration, and forcing a refactor makes the code worse.

## Step 3 — Refactor in passes

Never produce one giant diff.

- **One module per pass**, in dependency order, **bottom-up** — the layering is in the project's
  `AGENT.md`. Lower layers first means later passes build on already-clean foundations.
- Within a module, batch by principle so each change set has one reason to exist.
- Build and test after every pass (Step 4). Do not start the next pass on a red tree.
- Keep each pass reviewable. If a module is too large for one, split it by subsystem and say so.

**Hard rules**

- Never silence a diagnostic with `NOLINT`, a `#pragma`, or a widened `-Wno-error=…`. Fix the
  cause. If you cannot, the finding is **out of scope**, not suppressed.
- Never reformat unrelated lines. Run `clang-format` on files you touched, nothing else.
- Never add a dependency edge between modules to make a refactor easier. If the clean fix needs
  one, the finding is **out of scope** — report it as an architectural issue.
- Behaviour-preserving by default. Anything that changes behaviour is called out explicitly and
  needs a test that pins the new behaviour.
- New and changed logic lands with tests. A refactor that reduces coverage is not done.

**Moving configuration into the constructor** — the usual shape:

1. Add the parameter to the constructor and store it in a private member.
2. Update every construction site; the compiler finds them all once the setter is gone.
3. Delete the setter. If a call site genuinely cannot supply the value at construction, that
   call site is the finding — re-classify it as **document** or **out of scope** and say why.
4. For a `static` knob, thread the value from wherever it is read (typically config parsing)
   down to the constructor. This usually removes a cross-module reach as a side effect.
5. When the parameter list gets long, group related parameters into a config struct rather than
   keeping setters — that is what data-driven design wants anyway.

**Replacing a `bool` with an `enum class`** — the usual shape:

1. Declare the enum next to the function it serves, or in the module's public header when several
   functions share it. Name it after the decision, not the type.
2. Change the signature. Do **not** add an implicit conversion, a `bool` overload, or a defaulted
   argument to keep old call sites compiling — the whole point is that the compiler enumerates
   them for you.
3. Fix every call site the compiler names, mapping `true`/`false` onto the enumerators. Work
   outward from the declaration; a wide sweep of these is still one mechanical change set.
4. Delete any `/*flag=*/` argument comments the enum has just made redundant.
5. Where a call site passes a runtime `bool` from config parsing or a wire format, convert *at that
   boundary*. The boundary is the documented exception; it is not a reason to revert the signature.

## Step 4 — Verify each pass

Use the project's own presets; `AGENT.md` names them. Typically:

```bash
cmake --build --preset clang-asan
ASAN_OPTIONS="hard_rss_limit_mb=4096" ctest --preset=clang-asan
```

- The build must be clean under `-Werror`, and clang-tidy diagnostics count as build breaks
  where the project promotes them (`WarningsAsErrors`).
- The full suite must pass, not just the module's own target.
- For hot-path changes, check for regressions with Callgrind (`valgrind --tool=callgrind`,
  analyzed via `callgrind_annotate`).

If a pass cannot be made green, revert that pass and report it rather than leaving the tree
broken or the work half-applied.

## Step 5 — Commit and report

Group the changes into atomic semantic units and commit one per unit — hand off to `/commit`
if it is available. Do not mix a mechanical sweep with a behavioural fix in one commit.

Final report:

- **Fixed** — per module, which violations and how many.
- **Documented** — the exceptions kept, each with the reason recorded at the declaration.
- **Out of scope** — what was found and deliberately not done, so it is not silently lost.
- **Performance impact**, a **risk assessment**, and **code coverage** results — the house
  summary format.
