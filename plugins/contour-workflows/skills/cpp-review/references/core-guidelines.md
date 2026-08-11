# C++ Core Guidelines

The [C++ Core Guidelines](https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines) (Stroustrup/Sutter) are the closest thing the language has to an agreed-on standard of care. Their value in review is that they turn "I'd have done it differently" into a citable rule with a stated rationale — which is exactly the distinction `SKILL.md` asks you to make.

Their danger is the opposite: they are large, and most rules are advisory. A review that cites rule numbers at every opportunity is the volume failure mode wearing a badge of authority.

## How to use a guideline in a finding

**Cite one when it sharpens a finding you already have.** The finding stands on the defect; the reference explains why the rule exists and gives the author somewhere to read further. `F.7`, `R.30`, `ES.47` are anchors, not arguments.

Good:
```
[Should fix] src/parser.cpp:88 — Takes shared_ptr<Config> but never retains it
The function reads two fields and returns; taking shared_ptr forces a refcount
bump (atomic, contended) on every call and tells the reader ownership is being
shared when it isn't. Take `const Config&`. (Core Guidelines F.7, R.30.)
```

Bad — the rule *is* the finding, with no defect behind it:
```
[Nit] src/parser.cpp:88 — Violates F.7
```

**Never cite a rule number alone.** If you can't state the mechanism in your own words, you don't have a finding yet.

**A guideline is not automatically right for this codebase.** Many rules explicitly assume you can use exceptions, RTTI, and the standard library freely. Embedded, game-engine, and kernel-adjacent codebases routinely disable those, and EASTL, Abseil, and LLVM each have house idioms that consciously depart from the guidelines. Local convention wins — the same rule `SKILL.md` states for style. When a codebase departs from a guideline *consistently*, that's its convention, not a finding to raise on every file.

## The rules that carry real weight in review

These map onto defects the other reference files already cover; the value here is the vocabulary and the rationale.

**Lifetime and ownership** — the highest-yield section, and the one with actual enforcement behind it (the Lifetime profile, `clang-tidy`, MSVC's analyzer).

- **R.30** — take smart pointers as parameters only to express ownership transfer or sharing. A `shared_ptr` parameter that is only read is a contended atomic and a lie about ownership. **R.36**/**R.34** distinguish `const shared_ptr&` (retain-maybe) from `shared_ptr` by value (retain-yes).
- **F.7** — for general use, take `T*` or `T&`, not a smart pointer. Functions that merely *use* an object should not participate in its ownership.
- **I.11** — never transfer ownership by raw pointer or reference. A raw `T*` return that the caller must `delete` is a leak waiting to happen; say `unique_ptr`.
- **F.22 / F.60** — `T*` for a single object, `not_null<T*>` or `T&` when null is not valid. Encoding "never null" in the type deletes a class of check.
- **C.20** — if you can avoid defining default operations, do (rule of zero). **C.21** — if you define or `=delete` any copy/move/destructor, define or delete them all (rule of five). A class that defines a destructor and nothing else is the classic silent-double-free setup.
- **ES.65** — don't dereference an invalid pointer. The catch-all the lifetime profile enforces.

**Interfaces**

- **I.13** — don't pass an array as a single pointer; that's `span`.
- **I.23** — keep the number of function arguments low; long same-typed parameter lists are transposable at the call site.
- **I.30** — encapsulate rule violations. Ugly-but-necessary code belongs behind one interface, not spread across callers.

**Expressions and statements**

- **ES.47** — use `nullptr`, not `0` or `NULL`.
- **ES.49 / Type.4** — if you must cast, name it; avoid `reinterpret_cast` and C-style casts. Overlaps `modern-cpp.md` on `bit_cast`.
- **ES.20** — always initialize an object. Uninitialized reads are UB and the single most common source of nondeterministic bugs.
- **ES.56** — write `std::move` only when you need to move explicitly; a `move` on a return value pessimizes copy elision.

**Concurrency** — see `concurrency.md` for the mechanics.

- **CP.2** — avoid data races. The umbrella rule.
- **CP.3** — minimize explicit sharing of writable data.
- **CP.20** — use RAII (`scoped_lock`, `lock_guard`), never plain `lock()`/`unlock()`. An early return or a throw between them leaves the mutex held.
- **CP.21** — use `std::lock` or `std::scoped_lock` to acquire multiple locks, which is the standard fix for lock-ordering deadlock.
- **CP.42** — don't `wait` without a condition; spurious wakeups are real.

**Error handling**

- **E.6** — use RAII to prevent leaks on the error path. The error path is where leaks live because nobody tests it.
- **E.14** — prefer purpose-designed exception types over builtins. Subordinate to house convention: a codebase on `absl::Status` or `std::expected` is not violating this.

**Performance**

- **Per.7 / Per.11** — measure before optimizing; move computation from run time to compile time. The first half matters in review: a performance finding without a plausible hot path is speculation. See `performance.md`.

## Enforcement is cheaper than argument

Much of this is mechanically checkable, and pointing at the check beats debating the rule:

- `clang-tidy` ships `cppcoreguidelines-*` and `bugprone-*` checks; if the repo has a `.clang-tidy`, look at which are already enabled before raising something by hand.
- The Guidelines Support Library (GSL) provides `not_null`, `span`, `finally`. Only suggest it if the project already depends on it — proposing a new dependency in a code review is out of scope for a diff.
- MSVC `/analyze` and the Lifetime profile catch a subset of the ownership rules.

If a finding you're about to write by hand is one an already-configured check would have caught, that's worth saying instead: the fix is enabling the check, not fixing this one instance.
