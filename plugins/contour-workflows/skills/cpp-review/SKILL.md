---
name: cpp-review
description: Use when the user asks for a review of C++ changes — "review this PR", "look at my diff", "does this look right", "can you check this before I merge", "what did I miss" — or pastes or points at .cpp/.cc/.h/.hpp/.ixx/.cppm code wanting feedback rather than a new feature. Also use for narrower questions about a C++ change — thread safety, data races, performance, needless copies or allocations, memory safety, lifetimes, dangling references, undefined behavior (is this UB), API design, style consistency, C++20/23 idiom — since the same context-gathering applies. Prefer this skill over reviewing the diff cold; C++ bugs are usually invisible in the diff alone.
---

# C++ code review

Reviewing C++ well means reviewing the code that *isn't* in the diff. A three-line change can be correct in isolation and catastrophic given the destructor two files away, the lock discipline established in a header, or the fact that the caller stores the returned reference. Most bad C++ reviews are bad because the reviewer only read the patch.

So the working assumption here is: gather context first, form a model of the object lifetimes and threading involved, *then* look for problems.

## Workflow

**1. Get the change.**

For a PR or branch: `git diff --merge-base <base>` (usually `main` or `origin/main`) to avoid noise from other people's commits. `git log --oneline <base>..HEAD` gives the author's own framing of what they were doing, which is useful for spotting a mismatch between intent and effect.

If the user pasted code with no repository, work with what's there — but say explicitly which checks you couldn't perform without the surrounding definitions, rather than silently reviewing a subset.

**2. Read outward from the diff.**

Read the tests the change adds or touches, as code rather than as evidence that testing happened. A test that runs the new path but asserts nothing — or asserts only that no crash occurred, or checks a return value without checking the error it was supposed to produce — leaves the feature uncovered while looking covered, which is worse than no test because it suppresses the question. Verify each new test would actually fail if the behaviour it names regressed.

For each changed entity, the surrounding context that usually matters:

- The full definition of any changed function, not just the changed hunk.
- The class declaration for any changed member — what owns what, what the destructor does, what the special member functions look like (or whether they're implicit).
- Callers, via grep. Especially for anything returning a reference, pointer, `string_view`, `span`, or iterator: who holds onto the result, and how long does the referent live?
- Any comment describing an invariant or lock discipline ("caller must hold `mu_`", "not thread-safe", "must outlive").
- **The language standard the project actually builds with**, before judging any construct the diff introduces. Check `CMakeLists.txt` / `.bazelrc` / the build files for `CXX_STANDARD` or `-std=`, and check the README for a stated minimum — a library's supported standard is frequently older than the standard its maintainers write tests in. If a changed file is a public header, the binding constraint is what *consumers* compile with, not what CI happens to run.

  This is cheap and it is where reviews of library code most often go wrong in the opposite direction: not "you should modernize" but "the construct you just added doesn't exist in the standard this project supports." `if constexpr`, `<=>`, concepts, `std::string_view`, structured bindings, and inline variables are the usual offenders. See the Availability section of `references/modern-cpp.md`.

Read the headers involved. In C++ the header is where the contract lives.

**3. Build a model before judging.**

Before writing findings, be able to answer for yourself:

- Who owns each non-trivial object here, and when does it die?
- Which of this code runs on more than one thread, and what protects the shared state?
- What is the hot path, if any, and what does a single call allocate or copy?

If you can't answer one of these from the code, that gap is itself often the finding — an ownership model you can't reconstruct is one the next maintainer can't either.

**4. Before calling anything a bug, check that the bad state is reachable.**

The type system tells you a value *can* be null, or that two threads *could* touch a member. It doesn't tell you whether the path that reaches this code can execute while that's true. Reasoning from the type alone is the most common way a review produces a confident, wrong finding.

So for each suspected defect, ask what has to be true for it to fire, and go look for evidence that it can be:

- A UI event handler can't run after its window is torn down, so a weak reference resolved inside one usually can't be dead. The same expression in a timer callback, a posted task, or a coroutine resuming after `co_await` genuinely can be.
- A member only written in a constructor and read afterward isn't racing, however unsynchronized it looks.
- A branch guarded by an earlier check upstream isn't reachable in the state you're imagining.

If you can't establish reachability, the finding isn't a blocker — it's a question. Ask it as one: "can `Foo()` be entered after the window closes?" is useful and costs the author nothing if the answer is no. Asserting a crash that can't happen costs them a debugging session and costs you their attention on the findings that were right.

Run this in the other direction too. When a change *adds* defensiveness — a new null guard, a weak reference where a strong one was, a lock around something — ask whether the state it defends against is reachable. Unnecessary guards aren't free: they add paths nobody tests, and a weak reference that can never expire hides the ownership story rather than clarifying it. "Does this need to be weak?" is as legitimate a review comment as "this should be weak."

**5. Check the areas the change touches.**

Read the relevant reference file rather than working from memory — they cover the specific traps worth checking:

- `references/memory-and-lifetimes.md` — ownership, dangling, UB, error paths, C++20/23-specific hazards
- `references/concurrency.md` — races, lock discipline, atomics, coroutines
- `references/performance.md` — copies, allocations, algorithmic surprises in the hot path
- `references/api-and-style.md` — interface design, const-correctness, naming and consistency with the surrounding codebase
- `references/architecture.md` — dependency direction, responsibilities, duplication, and what a diff can and can't tell you about design
- `references/modern-cpp.md` — C++20/23 idiom, and the bar an idiom finding has to clear
- `references/core-guidelines.md` — C++ Core Guidelines rules worth citing, and how to cite one without turning the review into rule-quoting

Load the ones the change actually touches. A pure header refactor doesn't need the concurrency file; a change to a lock-free queue needs it before anything else.

**6. Verify what you can mechanically.**

If the repo has a build configured, compiling the change catches more than reading does. Where it's cheap and the tooling already exists, prefer it: a targeted `clang-tidy` run on changed files, or building a specific target. Don't spend a long time setting up infrastructure that isn't there — mention it as a suggestion instead.

No repo doesn't mean no compiler. When the project build is out of reach — a pasted diff, a tree too big to configure — reconstruct the construct in question verbatim with minimal stubs in a standalone file and compile that. A dozen lines settles "does this compile" and "which overload gets selected" in minutes, and it cuts both ways: confirming a real defect and clearing a suspected one are equally valuable outcomes.

State each claim at the confidence you earned. "This does not compile" is a prediction unless something was actually compiled — unverified, write it as "this should fail to compile because ⟨mechanism⟩" and name the assumption that could save it (the member you inferred to be a `vector`, the overload you assumed exists). The same discipline applies to "this overload is never selected" and "this branch is dead". Findings argued from reading are legitimate — presented as reasoning, not as build results.

## Findings

Report by severity, highest first. The point of the ordering is that the author reads top-down and stops when they run out of attention, so the thing that would page them at 3am has to be first.

- **Blocker** — miscompiles, UB, data races, leaks, breaking API changes, security issues. Reserve this for defects you established are reachable (step 4). If the bad state depends on a path you couldn't confirm exists, it belongs below as a question, not here.
- **Should fix** — real problems that aren't correctness failures: needless copies in a hot path, an API that invites misuse, missing error handling on a plausible path.
- **Nit** — style, naming, small clarity improvements. Label them as optional.

Before labelling anything a Blocker, state the consequence in one sentence: *what goes wrong at runtime, for whom.* If that sentence is about a reader rather than an execution — a misleading comment, a name that will confuse someone, a redundant construct — it is not a Blocker no matter how certain you are that it's wrong. Correctness of the observation and severity of the consequence are independent, and conflating them is the most common way a review loses the author's trust: they open the top finding expecting a crash and get a comment fix.

Two specific traps:

- **Inefficiency is not a Blocker.** An allocation on a path you believe is hot is a Should-fix until you have established the path is actually hot *and* the cost is material. Check what surrounds it — an extra `vector` construction next to a `new` in the same function is noise, not a defect. Quantify before escalating (Core Guidelines Per.7).
- **A misleading comment or a contradiction between comment and code is a Should-fix**, even when the code it describes is subtle and the comment is genuinely wrong. Nothing executes a comment.

Format each finding as:

```
[Blocker] path/to/file.cpp:142 — Short statement of the problem
<Why it's wrong: the mechanism, the sequence of events that breaks.>
<Suggested fix, as code if it's short.>
```

Anchoring to `file:line` matters because the author navigates by it. A finding without a location is a finding they have to hunt for.

Also mark whether each finding is about the change or about code the change did not touch. Read
`${CLAUDE_PLUGIN_ROOT}/lib/adjacent-problems.md` with the **Read** tool and apply its
*Classification* vocabulary — **in-scope** or **adjacent** — labelling the adjacent ones. Read it
rather than inferring from the words: the distinctions that make the label useful downstream
(pre-existing vs. introduced, adjacent vs. blocker) are the file's, not guesses. This costs one word and saves the author a decision:
a finding marked adjacent is one `/address-review` and `/work-issue` already know how to route,
instead of re-deriving whether it was ever this branch's job.

Scope and severity are independent axes, and the word *blocker* appears on both — an adjacent
finding can still be a severity Blocker (pre-existing UB is still UB), and an in-scope finding can
be a Nit. Say which you mean. Nothing else from that file applies here: this skill produces a
review, not commits, so sizing, fixing, ticket-filing and worktrees are the acting skill's job, not
the reviewer's.

End with a short summary — two or three sentences on the overall shape of the change and whether it's ready to merge. Include what's *good* if something is genuinely well done; a review that only ever finds fault trains the author to discount it.

## Keeping the signal high

The failure mode of automated review is volume. Twenty findings where three matter is worse than three findings, because the author now has to do the triage you were supposed to do.

Concretely:

- Don't report what a formatter or linter already catches. If the repo has `.clang-format` or `.clang-tidy`, whitespace and include-order findings are noise.
- Don't restate what the code does. The author wrote it.
- Don't recommend a pattern purely because it's modern. `std::expected` instead of an error code is a real suggestion when it fits the codebase's existing error handling and a distraction when the codebase uses `absl::Status` everywhere. An idiom finding needs a reason beyond novelty — a bug the older spelling has, or an inconsistency it creates with the file around it. See `references/modern-cpp.md`.
- Don't cite a C++ Core Guidelines rule as if the citation were the finding. A rule number is a reference for a defect you can already state in your own words, and many rules are advisory or assume a codebase that allows exceptions, RTTI, and the full standard library. See `references/core-guidelines.md`.
- Don't redesign from a diff. Structural observations that the change itself makes visible are fair; verdicts on whether the overall design is right are not, because a patch doesn't carry the history that judgment needs. See `references/architecture.md`.
- Distinguish "this is wrong" from "I'd have done it differently." Say which one you mean. Preference dressed as correctness is how reviews turn adversarial.
- If you're unsure whether something is a bug — the surrounding code is ambiguous, the invariant might hold for reasons you can't see — say so and ask, rather than asserting. "Is `parent_` guaranteed to outlive this?" is a useful review comment. A confident wrong accusation costs the author time and costs you credibility on the findings that were right.

Match the codebase's existing conventions over your own preferences. If the surrounding code uses `m_` prefixes and out-parameters, a change that follows suit is consistent, not wrong.
