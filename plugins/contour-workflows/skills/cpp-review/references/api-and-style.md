# API design and style

The governing question for an interface: can a reasonable caller use this wrongly without the compiler stopping them? Good C++ APIs make the correct use the easy use and the incorrect use fail to compile.

Style, meanwhile, is judged against the codebase — not against any external ideal. Read the surrounding file before commenting on naming or structure. Consistency with neighbors beats conformity to a guideline the project doesn't follow.

## Interfaces that invite misuse

- Adjacent parameters of the same type (`Rect(int, int, int, int)`, or two `bool`s) — callers will transpose them eventually. Strong types or a small struct fix it; whether it's worth the churn depends on how widely called it is.
- `bool` parameters at call sites: `Draw(true)` tells the reader nothing. An enum is self-documenting.
- Output parameters where a return value (or a struct, or `std::optional`) would work. C++17 structured bindings make multiple returns cheap.
- Ownership that isn't visible in the signature. A raw `T*` parameter should mean "borrowed, not owned"; if the callee takes ownership, the type should say so (`unique_ptr<T>`).
- Returning `T*` where null is possible but undocumented — `optional`, a reference, or an explicit comment.
- Functions returning a reference to internal state, which lets callers mutate around the class's invariants and creates a lifetime dependency on the parent object.
- Missing `[[nodiscard]]` on functions whose whole purpose is the returned value — especially error-returning functions, where a dropped result is a silently swallowed failure.
- Constructors of one argument that aren't `explicit`, enabling surprising implicit conversions. Same for conversion operators.
- Booleans returned to indicate failure where the failure reason matters. Whether the fix is `expected`, a status type, or an exception depends entirely on what the codebase already uses — match it.

## Changing behavior callers already depend on

When a change alters what existing code observes — not the signature, but the *behavior* — the question stops being "is the new behavior more correct?" and becomes "who is relying on the old behavior, and how would they find out?" A shipped library's observable behavior is its contract whether or not anyone wrote it down ([Hyrum's law](https://www.hyrumslaw.com/)).

Ask this whenever a diff touches:

- **An edge case in a parser, matcher, or format string.** The empty input, the doubled delimiter, the trailing separator. These are exactly what nobody documented and somebody depends on. A rewrite that "cleans up" the handling of `""` or of a second `-` is a behavior change even when the old handling was clearly an accident.
- **What a function does on invalid or degenerate input.** Throwing where it used to return a default (or vice versa) is a behavior change even if the new answer is better.
- **When a value is read.** Snapshotting a flag once instead of re-reading it per call is a semantic change, not just an optimization.
- **A macro or template that expands into user code.** Its behavior is baked into every caller that already compiled against it.

The useful review comment names the affected input and asks how the change reaches users: "this makes `parse("")` throw where it used to yield the default — is that intended, and does it need a release note?" That is more actionable than either "this is wrong" or silence.

Two things make the question sharper. **How long has the current behavior shipped?** A macro released two years and four versions ago has dependents; a function added last week does not. Check the tags or the changelog rather than guessing. And **is this reachable from a public header?** If yes, the constraint is what consumers compiled against, not what the project intends.

None of this means the change is wrong. Deliberate behavior fixes are why libraries have major versions. It means the change needs a decision and a note, and that a review which only evaluates correctness has skipped the part that breaks people.

## Const-correctness and the type system

- Member functions that don't mutate should be `const`. If a change makes an existing method non-const, check whether that forces const to be dropped up the call chain — that ripple is worth calling out.
- `const` on by-value parameters in declarations is noise; on references and pointers it's meaningful.
- Prefer `enum class` over unscoped enums for new code — implicit int conversion causes real bugs.
- Magic numbers and repeated string literals that should be named constants, especially if the same literal now appears in more than one place after the change.
- Missing `override` on overriding functions; `virtual` repeated where `override` is present.
- Types that should be moveable but aren't, because a user-declared destructor suppressed the implicit move.

## Error handling

- New error paths that are silently swallowed — caught and ignored, or a return value dropped.
- Catching by value or catching `...` and continuing without logging.
- Error handling inconsistent with the file's existing approach (mixing exceptions into a status-code codebase or vice versa) — this is a real finding, since mixed conventions are where errors get lost.
- Assertions used for conditions that can occur at runtime from untrusted input. Assertions are for programmer errors; input validation needs real checks that survive a release build.

## Does this already exist?

When a change introduces a new abstraction — an enum, a cost model, a status type, a helper, a trait — the first question a maintainer will ask is whether the project already has one. Reviewing the abstraction purely on its own merits misses this entirely, and it's a large fraction of what real reviewers spend their attention on.

Before accepting a new construct, grep for the vocabulary it's competing with. A new three-valued cost enum in a codebase that already has `TCC_Free`/`TCC_Basic`/`TCC_Expensive` will be asked to justify itself, and the honest answer may be that the existing one doesn't fit — but the comparison has to happen. Same for a new `Result` type next to an existing status class, a new string helper next to a `StringUtil`, a new lock wrapper next to an internal one.

Two failure modes are worth separating. Duplicating existing machinery fragments the codebase. But *reusing* machinery designed for a different layer is also a real objection — a cost model built for the IR level may carry assumptions that don't hold in the backend. Raise the existence of the alternative and let the author say which applies; don't assume either answer.

The same instinct applies to naming and qualification: a new member of an existing hierarchy should be declared and qualified the way its neighbors are. Check where the surrounding declarations actually live rather than assuming the class you found it through is the one that owns it.

### The inverse: is the old thing still used?

When a change *replaces* a mechanism, the same grep runs in the other direction. A refactor that introduces a new accessor, a new cost path, or a new spelling of an existing helper usually leaves the old one standing — and whether that is correct depends entirely on whether anything still calls it.

Grep for callers before commenting either way. Two outcomes, and the review comment differs:

- **Nothing calls it.** Then it is dead code the change should delete, and saying "this preserves the old API for compatibility" is actively wrong — you are defending a function with no callers.
- **Something calls it, possibly something you cannot see.** Then it must stay, and the useful comment is to reimplement it in terms of the new mechanism rather than leave two parallel implementations to drift.

The second case is the one that needs care in a repository mirrored from an internal monorepo — Abseil, googletest, protobuf, LLVM. A helper with no callers *in the public tree* may have many inside, so "delete it" is a recommendation you cannot make from the outside. Ask instead: "is anything still using this, including internally?" That question is answerable in one sentence by someone who can see, and it is the same question whether the answer turns out to be delete or reimplement.

What to avoid is the middle path of assuming the retention is deliberate and praising it. Deciding a leftover is "considerate backward compatibility" without checking is the same unverified-assumption error as calling it dead — it just fails in the friendlier direction.

## Matching the codebase

Check these against the actual surrounding code rather than a general standard:

- Naming: `m_foo` vs `foo_`, `CamelCase` vs `snake_case` for functions, namespace conventions.
- Header hygiene: include-what-you-use, forward declarations over includes in headers, include ordering if the project has one.
- Whether the project uses exceptions at all, RTTI, the standard library vs an internal alternative (`absl::`, `folly::`, a custom `StringView`).
- Whether new code should be in a module, and where the project puts implementation details (`detail` namespace, `Impl` suffix, pimpl).

## Testing and documentation

- A change fixing a bug that adds no test: worth asking whether one is feasible, since the absence is how the bug returns. Frame it as a question — sometimes the surface genuinely isn't testable in the existing harness.
- New branches with no coverage, especially error paths.
- Comments that the change made stale — the comment above a function still describing the old behavior is a trap for the next reader, and it's easy to miss because the diff shows the code line, not the comment three lines up.
- Documented invariants ("callers must hold the lock", "must outlive") that the change now violates or should extend.
