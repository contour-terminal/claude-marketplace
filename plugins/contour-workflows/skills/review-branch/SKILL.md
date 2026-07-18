---
name: review-branch
description: Review the current Git branch against its base branch through a C++23 lens — idiom modernization (std::expected, std::span, ranges, deducing this), const correctness, naming, test coverage of changed lines, performance, and a risk rating. Use for whole-branch C++ review; for a general-purpose correctness pass over the uncommitted diff, prefer the built-in /code-review.
argument-hint: [base-branch]
allowed-tools: Bash(git:*), Bash(gh:*), Bash(ctest:*), Bash(cmake:*), Read, Grep, Glob, Agent
---

## Branch Review

Review all changes on the current branch compared to the base branch.

The base branch defaults to the repository's actual default branch — resolve it with
`git symbolic-ref --short refs/remotes/origin/HEAD` and strip the `origin/` prefix (falling
back to `main`, then `master`) — unless the user specifies one via `$ARGUMENTS`.

### Step 1 — Gather context

1. Run `git log --oneline $(git merge-base ${ARGUMENTS:-master} HEAD)..HEAD` to list the commits under review.
2. Run `git diff $(git merge-base ${ARGUMENTS:-master} HEAD)..HEAD` to obtain the full diff.
3. Identify every file touched and read relevant surrounding context where the diff alone is insufficient.

### Step 2 — Review categories

Evaluate every changed hunk against **each** of the following categories. For each category, list concrete findings with file paths and line references. If a category has no findings, state that explicitly.

#### 2.1 Code quality
- Readability, structure, and adherence to project conventions (see CLAUDE.md / .clang-format / .clang-tidy).
- Proper error handling; no swallowed errors or silent failures.
- No unnecessary complexity or dead code introduced.
- Const correctness.

#### 2.2 C++23 language and library features
- Flag opportunities to replace older patterns with C++23 equivalents (e.g., `std::expected`, `std::print`, `std::ranges`, `std::flat_map`, `std::generator`, `if consteval`, deducing `this`, `std::unreachable()`, `std::to_underlying()`, multidimensional `operator[]`, `std::stacktrace`, `<format>` header, `std::move_only_function`).
- Do **not** suggest C++23 features that would require sweeping unrelated changes; keep suggestions scoped to the diff.

#### 2.3 Descriptive naming
- Variables, functions, types, and constants should have clear, self-documenting names.
- Flag abbreviations, single-letter names (outside tiny lambdas/loops), or misleading names.

#### 2.4 Test coverage of changed lines
- For every non-trivial logic change, check whether a corresponding test exists or was added.
- List changed lines/functions that lack test coverage and suggest what tests to add.

#### 2.5 Performance impact
- Identify changes that may regress performance: unnecessary copies, allocations in hot paths, algorithmic complexity changes, lock contention, cache-unfriendly access patterns.
- Also note positive performance improvements.
- When uncertain, say so rather than speculating.

#### 2.6 Risk assessment
- Rate overall risk as **Low**, **Medium**, or **High**.
- Call out changes that affect public API, ABI, configuration, persistence formats, or security boundaries.
- Highlight potential data races, undefined behavior, or platform-specific pitfalls.

#### Step 3 — Proposed changes
- Suggest a change for each finding that needs one.

#### Step 4 — Code duplication
- Detect any new code duplication introduced by the changes. If found, suggest refactoring to eliminate it.

### Step 5 — Summary

Provide a concise summary table:

| Category | Findings | Severity |
|---|---|---|
| Code quality | … | … |
| C++23 opportunities | … | … |
| Naming | … | … |
| Test coverage | … | … |
| Performance | … | … |
| Risk | … | … |

End with an overall verdict: **Approve**, **Approve with suggestions**, or **Request changes**, along with a brief rationale.
