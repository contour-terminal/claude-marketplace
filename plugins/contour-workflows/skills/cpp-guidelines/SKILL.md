---
name: cpp-guidelines
description: The C++23 coding standards and load-bearing design principles used across Contour Terminal projects — error handling with std::expected, dependency injection, configuration at construction time, data-driven design, testability, and the zero-warning policy. Load before writing, reviewing, or refactoring C++ in these repositories, or when deciding how to structure a new module, class, or fallible API.
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
