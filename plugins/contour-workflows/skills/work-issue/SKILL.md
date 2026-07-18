---
name: work-issue
description: Take a GitHub or GitLab issue from URL or number all the way to a committed branch. Reads the issue and everything it links to, classifies it as a bug, feature, or chore, then follows the matching workflow — reproduce-and-regression-test for bugs, design-and-test for features. Use for "implement issue 123", "fix this bug report", or any linked issue.
argument-hint: "<issue-number-or-url>"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(glab:*), Bash(ctest:*), Bash(cmake:*), Read, Grep, Glob, Edit, Write, Agent, WebFetch, WebSearch
---

# Work an Issue

Turn an issue into a well-tested, committed branch. The workflow forks by issue *kind*:
bugs demand a failing test before a fix; features demand a design before code.

## Guiding principles

1. **Understand before acting.** Read the issue and everything it links to first.
2. **Reproduce before fixing.** A bug you cannot reproduce is a bug you cannot verify fixed.
3. **Test-first for bugs.** The regression test must fail before the fix and pass after.
4. **Minimal, correct fixes.** Fix the root cause, not the symptom; do not opportunistically refactor.
5. **Evidence-based.** Cite concrete file paths and line numbers for every claim.
6. **No regressions.** Run the full suite before reporting done.

## Context

- Current branch: !`git branch --show-current`
- Repository remote: !`git remote get-url origin 2>/dev/null || echo "(no remote)"`
- Working tree: !`git status --short`

---

## Phase 0 — Setup

### Step 0.1 — Detect the platform

Extract the **host** from the remote URL (handle both `git@host:owner/repo.git` and
`https://host/owner/repo.git` forms). Do not match on the literal string `gitlab.com` —
most GitLab deployments are self-hosted under an unrelated hostname:

1. If the host is `github.com` → use `gh`.
2. Otherwise probe, in order, and use whichever succeeds:
   ```
   gh repo view --json nameWithOwner 2>/dev/null     # GitHub (incl. Enterprise)
   glab repo view 2>/dev/null                        # GitLab (incl. self-hosted)
   ```
3. If neither succeeds, report which probe failed and stop rather than guessing.

### Step 0.2 — Resolve the issue reference

`$ARGUMENTS` is either a plain number or a full URL. If it is a URL pointing at a
*different* repository than `origin`, note that explicitly — the fix may belong elsewhere.

If `$ARGUMENTS` is empty, **stop** and ask which issue to work on.

---

## Phase 1 — Understand

### Step 1.1 — Fetch the issue

- **GitHub**: `gh issue view <number> --json number,title,body,labels,comments,state,url`
- **GitLab**: `glab issue view <number> --output json`

If the issue is already closed, **stop** and report it — confirm with the user before
working on closed issues.

Extract: title, reported behavior, expected behavior, reproduction steps, environment
details, acceptance criteria, labels, and any related issues or PRs.

### Step 1.2 — Follow embedded links

Scan the body *and all comments* for links. This is often where the real specification
lives. For each link:

1. **Classify**: spec/RFC/standard · related issue · documentation · code permalink · external reference.
2. **Fetch**:
   - specs, RFCs, docs, blog posts → `WebFetch`
   - related GitHub issues → `gh issue view` / `gh api`
   - related GitLab issues → `glab issue view` / `glab api`
   - code permalinks → `Read` the referenced file at the referenced lines
   - unfetchable links → note them, try `WebSearch` for an alternative source
3. **Extract** what is relevant and fold it into the understanding below.

Follow links one level deep by default. Go deeper only when a linked document itself points
at the authoritative spec.

### Step 1.3 — Classify the issue

Decide which kind of work this is, and **state the classification and your reasoning**
before proceeding:

| Kind | Signals | Workflow |
|---|---|---|
| **bug** | "crashes", "wrong output", "regression", steps to reproduce, a `bug` label | Phase 2B |
| **feature** | "add", "support for", "it would be nice", acceptance criteria, an `enhancement` label | Phase 2F |
| **chore** | dependency bump, CI config, docs, typo, mechanical refactor | Phase 2C |

Labels are a hint, not the decision — read the content. If the issue is genuinely mixed
(a bug report that also requests an enhancement), say so and handle the bug first, or ask
which the user wants.

If critical information is missing — no reproduction steps for a bug, no acceptance
criteria for a vague feature — **say what is unknown rather than guessing**. For a bug
you cannot reproduce, stop and report what you tried.

### Step 1.4 — Create the branch

1. Derive a short kebab-case description (3–5 words) from the issue title.
2. If the working tree is dirty, stash: `git stash push --include-untracked` (tell the user).
3. Resolve the default branch:
   ```
   git fetch origin
   git symbolic-ref --short refs/remotes/origin/HEAD   # strip the "origin/" prefix
   ```
   Fall back to `main`, then `master`, only if that fails.
4. Branch from the freshly-fetched base, prefixed by kind:
   ```
   git checkout -b fix/<issue>-<desc> origin/<base>       # bug
   git checkout -b feature/<issue>-<desc> origin/<base>   # feature
   git checkout -b chore/<issue>-<desc> origin/<base>     # chore
   ```

---

## Phase 2B — Bug workflow

### Step 2B.1 — Locate the code

Use Grep/Glob/Read to find the code on the failing path. For a large or unfamiliar
codebase, launch the Agent tool with `subagent_type=Explore` for broad searches, in
parallel where the searches are independent.

### Step 2B.2 — Root cause analysis

Trace the actual execution path and identify the **root cause**, not the surface symptom.
State it as: *"`Foo::bar()` at `src/foo.cpp:142` assumes X, but when Y the invariant breaks
because Z."*

Determine when it was introduced (`git log -S`, `git blame`) — this tells you whether a
release note is warranted and whether other call sites share the flaw.

### Step 2B.3 — Write the failing test first

Add a regression test that reproduces the bug, plus negative and edge cases around it.
Follow the project's existing test conventions and place it beside comparable tests.

**Run it and confirm it fails**, for the reason the issue describes. A test that passes
before the fix is testing the wrong thing — go back to Step 2B.2.

### Step 2B.4 — Apply the minimal fix

Fix the root cause. Do not reformat surrounding code, rename things, or refactor
opportunistically. If you find adjacent bugs, note them in the report — do not fix them here.

### Step 2B.5 — Verify

1. The new test now passes.
2. The full suite passes (`ctest` or the project's runner) — no regressions.
3. Re-read the issue's reproduction steps and confirm each is addressed.

Skip to Phase 3.

---

## Phase 2F — Feature workflow

### Step 2F.1 — Synthesize a specification

From the issue plus all linked material, write:
- **Goal** — one sentence.
- **Behavior** — what it does, step by step.
- **Inputs / outputs** — what flows in and out.
- **Constraints** — compatibility, performance, edge cases.
- **Open questions** — anything still unclear.

Present the spec. If an open question blocks design, **ask the user** rather than assuming.

### Step 2F.2 — Explore integration points

Find, with concrete paths: the entry point where the feature is triggered; existing
patterns for comparable features (base classes, interfaces, conventions); the test
infrastructure and utilities available; and the components it will interact with. Use the
Agent tool with `subagent_type=Explore` when the integration points are unclear.

### Step 2F.3 — Design

Produce a design that follows the codebase's existing architecture. Favor dependency
injection so the feature is testable in isolation — inject collaborators rather than
constructing them internally or reaching for globals. Cite the file paths and line numbers
that justify each decision.

Present the design before writing code.

### Step 2F.4 — Implement with tests

Implement the design, writing tests alongside: the happy path, edge cases, error paths, and
any acceptance criteria stated in the issue. Match the surrounding code's idiom and comment
density.

### Step 2F.5 — Verify

Full test suite green; acceptance criteria each demonstrably met.

---

## Phase 2C — Chore workflow

Make the change directly. Keep it mechanical and reviewable. Add or update tests where the
change has observable behavior; a dependency bump or CI tweak may legitimately have none —
in that case verify by running the affected pipeline step locally.

---

## Phase 3 — Release note

If the repository tracks a changelog (`metainfo.xml`, `*.appdata.xml`, `CHANGELOG.md`, or
`NEWS`) and the change is user-visible, add an entry in the existing style — the
`/add-release-note` skill does exactly this.

Skip for internal refactors, test-only changes, and bugs introduced *after* the most recent
release (there is nothing for users to be told about).

## Phase 4 — Commit

Commit the work, referencing the issue so it is linked and auto-closed:

```
git commit -s -m "$(cat <<'EOF'
<module>: <summary line>

<what changed and why — the root cause for a bug, the capability for a feature>

Fixes #<issue-number>
EOF
)"
```

Use `-s` so the `Signed-off-by:` trailer comes from the committer's own git config. Use the
module area as prefix (`vtbackend:`, `ci:`, `build:`) rather than `feat:`/`fix:`. Use
`Fixes #N` for bugs, `Closes #N` for features and chores.

If the work splits into distinct semantic units, make one commit per unit — `/commit`
encodes that grouping logic.

## Phase 5 — Report

- **Issue** — number, title, URL, and your classification with reasoning.
- **Root cause** *(bugs)* — the precise mechanism, with file:line.
- **Change** — what was modified and why.
- **Tests** — what was added; for bugs, explicit confirmation it failed before and passes after.
- **Coverage** — coverage of the changed lines, if the project reports it.
- **Performance impact** — hot paths, allocations, complexity; state "none" if none.
- **Risk assessment** — Low / Medium / High with justification.
- **Follow-ups** — adjacent problems noticed but deliberately not fixed.

Then offer `/create-pr`.

## Rules

- NEVER fix a bug you have not reproduced.
- NEVER write the fix before the failing test (bugs).
- NEVER guess at missing requirements — ask, or state the assumption prominently.
- NEVER expand scope beyond the issue; note adjacent problems instead of fixing them.
- NEVER push or open a PR — that is `/create-pr`.
- NEVER work a closed issue without confirming with the user.
- ALWAYS branch from a freshly fetched default branch.
- ALWAYS run the full test suite before reporting done.
