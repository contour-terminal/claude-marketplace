---
name: cpp-guidelines
description: The C++23 coding standards and load-bearing design principles used across Contour Terminal projects — error handling with std::expected, dependency injection, configuration at construction time, enum class over bool in API surface, data-driven design, testability, and the zero-warning policy. Load before writing, reviewing, or refactoring C++ in these repositories, or when deciding how to structure a new module, class, or fallible API.
allowed-tools: Read, Grep, Glob
---

# C++ Guidelines

The standards below apply across Contour Terminal C++ projects. They describe *how code should
be shaped*; each repository's own `AGENT.md` / `CLAUDE.md` remains authoritative for
project-specific detail — module layout, build presets, test targets, and domain references.

**Precedence, highest first:**

1. **Per-module `.clang-tidy` and `.clang-format` files.** Naming conventions and
   static-analysis rules live there and are machine-enforced. They win over any prose here.
   Projects commonly layer these — a base `src/.clang-tidy` with per-module overrides.
2. **The project's own `AGENT.md` / `CLAUDE.md`.**
3. **This document.**
4. **Surrounding code.** Match its idiom, naming, and comment density.

## Language guidelines

- Prefer C++23: `constexpr`, `std::ranges`, `std::format`, `std::expected`, structured bindings
- C-style loops are forbidden; use range-based for loops exclusively
- Use `std::views::iota` and other views for generating and transforming ranges
- Use `std::span` for passing arrays and contiguous sequences
- Use `auto` type deduction to improve readability
- Use `const` correctness throughout (refs, pointers, member functions)
- Mark return values `[[nodiscard]]` where ignoring the result would be a bug
- Use smart pointers for ownership; do not use raw owning pointers
- Do not introduce new third-party dependencies without strong justification
- Do not suppress clang-tidy warnings with `NOLINT` comments; fix the underlying issue
- Run `clang-format` after changes; formatting rules live in `.clang-format`
- Document new public functions, classes, structs, and their members using Doxygen style:
  ```cpp
  /// Short description of the function (be concise).
  /// @param name Description.
  /// @return Description.
  ```

## Design patterns & principles

Always aim for a clean software architecture. The following principles are **load-bearing** and
should be adhered to unless there is a very strong, explicitly justified reason not to.

### Error handling: `std::expected<T, E>`

Prefer `std::expected<T, E>` for fallible API surface. Give each subsystem its own error enum,
introduced *as the need arises* — do not invent a taxonomy up front. Chain monadically with
`and_then`, `or_else`, `transform`, `transform_error` rather than nested `if`s. Reserve
exceptions for programmer errors (precondition violation, contract misuse), not for expected,
recoverable failures.

### `enum class` over `bool`

**A `bool` in an API is an anonymous enum whose two values are named after their representation
instead of their meaning.** A `bool` parameter, return type, or data member is a finding unless one
of the exceptions below applies; the replacement is a purpose-named `enum class`. As with the
principles around it, depart from this only for a strong reason, stated at the declaration.

The parameter case carries all three costs at once:

- **The call site loses the meaning.** `renderLine(line, true, false)` tells a reader nothing, and
  no amount of careful naming *inside* the function repairs the code that calls it.
- **The compiler stops helping.** `bool` accepts pointers, integers and characters through implicit
  conversion, so an overload taking `bool` can quietly swallow an argument meant for another one,
  and two adjacent `bool` parameters can be exchanged without a diagnostic. An `enum class`
  converts from nothing.
- **A third case rewrites every signature.** When yes/no becomes yes/no/inherit, a `bool` forces a
  signature change and an edit at every call site; an `enum class` gains an enumerator and `switch`
  exhaustiveness names the places that must now handle it — the same argument data-driven design
  makes.

**The shape of the fix.**

- **Name the enum after the decision, not after the type.** Prefer
  `enum class LineWrap { Truncate, Wrap }` over `enum class BoolArg { True, False }`. Domain words
  beat `Yes`/`No`; reserve `Yes`/`No` for a type whose own name already reads as the question —
  `JumpOver::Yes`, `HighlightSearchMatches::No`.
- **Give it an explicit underlying type**, `enum class LineWrap : uint8_t { Truncate, Wrap }`, in
  line with the rest of the project's enums. Order the enumerators so the off/absent/default case
  is zero — then a zero-initialized value still means what the `false` meant, and the ordering is
  one less thing to get inconsistent between two enums that answer the same kind of question.
- **Flags that genuinely combine are a bitmask, not a pile of enums.** Where several booleans are
  truly orthogonal and every combination is legal, the answer is one bitmask type — not an
  `enum class` per flag, and not an enum of states. Protocol-defined bit positions are the usual
  case, and are why `cppcoreguidelines-use-enum-class` is sometimes deliberately disabled.
- **A strong typedef is the other acceptable shape** where a value must stay boolean in behaviour
  but distinct in type: `using Handled = boxed::boxed<bool, HandledTag>;`. Reach for it when the
  type name supplies the meaning and the two states have no better names of their own.

**Per position.**

- **Parameters.** A defaulted `bool` is the worst form — `bool force = false` shows neither the
  name nor the value at the call site, so prefer two named functions. Two adjacent `bool`
  parameters are the next worst, being silently exchangeable; fix those signatures first.
- **Returns.** A `bool` return is right when the function name *asks the question*: `empty()`,
  `contains()`, `is…`/`has…`/`can…`, the comparison operators, `explicit operator bool()`. It is a
  finding when it reports success or failure — that is `std::expected<void, E>`, which carries the
  reason instead of discarding it — or when it selects between two named outcomes, which is an
  `enum class`.
- **Members.** The same test as parameters, plus one more: two or more `bool` members in a type are
  usually a state machine hiding in flags. Where some combinations cannot legally occur, the states
  are one `enum class`, not a set of independent switches.
- **A surviving `bool` reads as a predicate** — `_isVisible`, not `_visible` — so the use site
  still reads as a question.

**When you cannot.** Each of these must be documented at the declaration, with the reason:

- **The parameter is the property** — a setter that exists only to assign a `bool` member which
  itself passed the test above. This is the narrow carve-out, not a general licence: if the member
  should have been an `enum class`, so should the setter.
- **A signature you do not own** — a framework virtual or slot, a standard concept
  (`std::predicate`, comparators), a C callback typedef.
- **Serialization and wire boundaries** — JSON fields, protocol flags, config keys whose external
  representation is a boolean. Convert at the boundary and keep the `enum class` inside it.
- **Generic code with no domain meaning** — a `bool` template argument threaded to `if constexpr`.

**Enforcement.** Mostly a review question — *at the call site, can you tell what `true` means
without opening the header?* — because the two checks that would help are usually switched off in
a codebase that predates this principle. `bugprone-easily-swappable-parameters` flags adjacent
parameters of convertible type, and `readability-implicit-bool-conversion` catches the conversions
that let a `bool` overload swallow a pointer; check whether the project disables them before
assuming a clean build means clean signatures. Enabling either on a single module is a reasonable
first move, and what it then reports is the finding, not noise. Where a `bool` is deliberately
kept, `bugprone-argument-comment` with `CommentBoolLiterals` (off by default, even when
`bugprone-*` is on) turns `/*wrap=*/true` into a *checked* comment rather than a hopeful one — a
mitigation, not a substitute for the type.

### Dependency injection

**This is a load-bearing principle, not a nice-to-have.** Anything that touches I/O, time,
randomness, the filesystem, the network, or any other ambient/global resource is reached
through an interface — never through a concrete type, a singleton, or a free function with
hidden state.

### Configuration at construction time

**A constructed object is a usable object.** Everything a class needs to do its job —
collaborators, policy, tuning knobs, limits — is supplied to its constructor and is fixed
thereafter. No `init()`/`setup()` second phase, no default constructor followed by a run of
setters, no static knob poked from elsewhere at startup.

This is the **Complete Constructor** pattern, realized through **constructor injection** and
**immutability**; in C++ it is **RAII** generalized from resources to configuration. What it
forbids is **two-phase initialization** and the **temporal coupling** it creates — a hidden call
order the caller must know, and a not-yet-configured state every method must tolerate.

**Configuration is not state.** This governs how an object is *set up*, not what it does
afterwards. A setter that mutates the domain state the object exists to manage is fine — a
cell's colour, a protocol mode toggled by an incoming escape sequence. A setter that installs a
policy read once from the config file at startup is not, and a `static` one is the worst case.
Ask: *would two differently-configured instances be two different objects, or one object in two
states?* Different objects → constructor.

- Omit the default constructor when there is nothing sensible to default to.
- Configuration members are private and have no setter. Prefer this encapsulated immutability
  over `const` members: a `const` member deletes copy- and move-assignment, quietly breaking
  types held in containers or reassigned. Reserve `const`/reference members for value types that
  genuinely never need assignment — and check whether the project's `.clang-tidy` enables
  `cppcoreguidelines-avoid-const-or-ref-data-members` before reaching for them.
- A long constructor is a fact about the *data*, not a reason to add setters: group related
  parameters into a config struct (which data-driven design wants anyway). A builder is for
  genuinely optional, order-independent parameters only.
- Never wire with a global. A `static` setter is post-construction configuration plus unbounded
  scope, no thread-safety, and state leaking between tests.
- Fallible setup belongs in a static factory returning `std::expected<T, E>` — not in a
  constructor that leaves the object half-built.

**When you cannot.** Each of these must be documented at the declaration, with the reason:

- **Live reconfiguration is the feature** — settings that must change while running, such as
  fonts or DPI on a config reload. Weigh the price first: a mutable object typically grows a
  mutex, a staged-vs-published copy of its state, and an apply step, all of which are pure cost
  wherever the requirement does not actually exist.
- **Externally-driven geometry** — window size, page size, margins. The window manager decides.
- **Framework-mandated** — UI toolkits that default-construct types and then assign properties
  (Qt/QML `Q_PROPERTY` being the common case) leave no choice.
- **Documented rebinding seams** — a deliberate `setX()` that lets a collaborator move between
  owners at runtime. The seam is the design; say so at the declaration.
- **Cyclic wiring** — when A and B must know each other, one `attach`-style call after
  construction is acceptable; a *sequence* of them is not.

**Enforcement.** The mechanical half is automated wherever `cppcoreguidelines-pro-type-member-init`
and `cppcoreguidelines-prefer-member-initializer` are enabled: every member initialized, in the
member-initializer list. The design half is a review question — *how many calls must a caller
make before this object is usable?* The answer must be zero. This is also why it pays off for
testing: a fully-constructed object is built with test doubles in one expression, with no setup
ritual and no half-configured state to reason about.

### Data-driven design

**Behaviour is described by data; code interprets that data.** This is equally load-bearing and
goes well beyond "no magic numbers". The aim is that adding a flag, a protocol verb, a storage
backend, or an error code is a matter of *adding a row to a table*, not editing logic scattered
across the codebase.

As with DI, **adhere to this unless there is a very strong, explicitly justified reason not
to.** When in doubt, ask: "if a sixth case showed up tomorrow, how many places would I edit?"
If the answer is more than one, the design is not data-driven enough yet.

### Testability of every code area

**Every code area must be testable, and new code lands with tests.** Modules ship a Catch2
`*_test` target; GUI-layer code typically uses `Qt6::Test`.

Code that is not headless-constructible (GUI/RHI stacks in particular) is made testable by
*extracting pure decisions into dependency-free headers* and driving the rest offscreen. If
something is hard to test, that is a design smell: inject the dependency and extract the
decision, don't skip the test. Aim always to increase coverage.

## Zero-warning policy

**The codebase is warning-free, and a warning is a build break.** Dev and CI builds compile with
`-Werror`.

- Fix the cause of a warning — never silence it. No `NOLINT`, no `#pragma` mutes, and no
  widening of `-Wno-error=…` without an explicit, justified reason.
- clang-tidy runs as part of the pedantic build; treat its diagnostics the same way — fix,
  don't suppress.

## Architectural boundaries

Projects layer their modules bottom-up: foundational utilities at the base, domain engines
above, presentation last. **Lower layers must not depend on higher ones**, and presentation
layers must not reach around the domain layer into internals.

Consult the project's `AGENT.md` for its concrete module list and dependency order before
adding a dependency edge between modules.

## Workflow expectations

- Ensure changes are covered by tests, and run them. The project's `AGENT.md` documents the
  build and test invocations (typically a `cmake --build --preset <preset>` and a matching
  `ctest --preset <preset>`); prefer a sanitizer-enabled preset for development.
- The zero-warning policy is non-negotiable — the build must be clean under `-Werror`.
- After code changes, look for duplication and simplify (`/simplify` does this).
- For performance-sensitive changes, check for regressions with Callgrind
  (`valgrind --tool=callgrind`, analyzed via `callgrind_annotate`).
- In change summaries, report: **performance impact** (if any), a **risk assessment**, and
  **code coverage** results.

## Applying this skill

When writing or reviewing code:

1. Read the project's `.clang-tidy` and `AGENT.md` first — they override this document.
2. Check the design principles *before* the language details. A correctly-formatted class that
   constructs its own filesystem access has the more serious problem.
3. When a guideline and the surrounding code disagree, follow the surrounding code and note the
   inconsistency rather than reformatting unrelated lines.
