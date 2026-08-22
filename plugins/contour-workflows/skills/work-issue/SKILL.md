---
name: work-issue
description: Take a GitHub or GitLab issue from URL or number all the way to a merged-ready pull request. Reads the issue and everything it links to, challenges whether it is worth building as written, classifies it as a bug, feature, or chore, plans it for approval, then implements it phase by phase behind /simplify and /code-review gates before opening a PR and driving CI to green. Use for "implement issue 123", "fix this bug report", or any linked issue.
argument-hint: "<issue-number-or-url>"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(glab:*), Bash(ctest:*), Bash(cmake:*), Read, Grep, Glob, Edit, Write, Agent, Skill, WebFetch, WebSearch
---

# Work an Issue

Turn an issue into a well-tested change that is merged-ready and green. The workflow forks by
issue *kind*: bugs demand a failing test before a fix; features demand a design before code.

## Guiding principles

1. **Understand before acting.** Read the issue and everything it links to first.
2. **Challenge before building.** An issue is a request, not a specification. A well-implemented
   wrong thing is still the wrong thing.
3. **Agree the approach before writing it.** Plan first, get approval, then implement.
4. **Reproduce before fixing.** A bug you cannot reproduce is a bug you cannot verify fixed.
5. **Test-first for bugs.** The regression test must fail before the fix and pass after.
6. **Minimal, correct fixes.** Fix the root cause, not the symptom. "Minimal" bounds *scope*, not
   craft: `/simplify` over code this change touched, and an adjacent fix in its own commit, are
   both in bounds — neither is opportunistic refactoring.
7. **Review every phase, not just the end.** A problem caught inside the phase that caused it is
   cheap; the same problem found three phases later is archaeology.
8. **Evidence-based.** Cite concrete file paths and line numbers for every claim.
9. **No regressions.** Run the full suite before reporting done.
10. **Done means green.** The work is finished when CI is green on a real PR, not when the code
    compiles locally.

## Plan approval and phase gates

Two mechanisms used throughout the workflows below. They are described once here rather than
restated in each branch.

### The plan

Before touching a single file, enter plan mode, write the plan, and get it approved via
`ExitPlanMode`. Approval is what separates "this is what I intend to do" from "this is what I did";
asking afterwards is asking the user to review a fait accompli.

A plan says what will change, why that shape, and — the part the gates depend on — how the work
**decomposes into phases**. A phase is a slice that stands on its own: it builds, its tests pass,
and it leaves the tree in a state you would show someone. "Add the parser", "wire it into the
config loader", "handle the error path" are phases; "write the code" is not.

Plans are proportionate: a one-hunk chore is a one-sentence, one-phase plan. Do not manufacture
phases to have something to gate.

### The phase gate

Close every phase the same way, before starting the next one:

1. **Tests green.** The phase's own tests pass and the full suite still passes. This comes first
   because everything after it edits code, and edits on top of a red tree cannot be judged.
2. **`/simplify`.** It reviews the changed code for reuse, duplication and altitude, and *applies*
   its fixes rather than reporting them — so re-run the suite afterwards. It does not hunt bugs;
   that is the next step's job.
3. **`/code-review medium`.** Name the level explicitly: with none given it silently reuses
   whichever ran last, and a gate whose depth depends on unrelated history is not a gate. Running
   it *after* `/simplify` means the review reads the code that will actually be committed, and
   spends its attention on correctness rather than cleanups already handled.
4. **Address every finding** before the next phase begins. Findings about code this change did not
   touch are *adjacent* — route them through `lib/adjacent-problems.md` rather than absorbing them
   silently or ignoring them. A finding deliberately declined is recorded, not dropped.

**When the plan is a single phase**, the phase gate and the final pass in Phase 3 cover the same
code. Run the gate once, at the deeper level, and skip the duplicate — reviewing a two-line diff
twice is ceremony, not rigour.

## Context

- Current branch: !`git branch --show-current`
- Repository remote: !`git remote get-url origin 2>/dev/null || echo "(no remote)"`
- Working tree: !`git status --short`

---

## Phase 0 — Setup

### Step 0.0 — Load the shared policy

Read `${CLAUDE_PLUGIN_ROOT}/lib/adjacent-problems.md` with the **Read** tool. It governs what to do
with a real problem that is not the one you came for; *The phase gate* above and Phases 2, 3 and 7
all cite it.

Do not read `lib/pr-conventions.md` — `/create-pr` and `/draft-pr` read it themselves in Phase 6,
and its *Portability rules* bind every reader to never force-push, which Phase 7 must do.

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

### Step 1.3 — Challenge the issue

An issue is what somebody wanted at the moment they wrote it. Before building it, judge whether it
is worth building *as written*, and **state the verdict**. Nothing has been created yet, so this is
the cheapest moment to change course.

Work through:

- **Is the problem real?** Where reproduction is cheap, reproduce it. Reports are sometimes
  misdiagnosed, already fixed, or describe intended behavior.
- **Does it prescribe a solution where it should describe a problem?** Issues arrive as "add a
  `--force` flag" when the underlying need is served better another way. Name the need, then say
  whether the prescription serves it.
- **Does the requested shape fit the architecture?** For C++ repositories invoke `/cpp-guidelines`
  and judge against its *Design patterns & principles* and *Architectural boundaries*. An issue
  asking for a global, a construct-then-configure setter, or a new `bool` parameter in an API is
  asking for something this codebase has already decided against. Elsewhere, judge against the
  architecture the surrounding code exhibits.
- **Is it in the right layer?** A fix in the wrong module is a fix somebody moves later.
- **Does it conflict with something already there?** Existing behavior, another open issue, or a
  deliberate decision visible in `git log`.
- **Is it specified enough to know when it is done?** Missing acceptance criteria and missing
  reproduction steps block verification; they are not details to fill in later.

Land on one verdict:

- **Sound** — say so and proceed.
- **Sound problem, wrong prescription** — say what you would do instead and get a decision. This
  usually deserves a comment on the issue rather than a silent divergence: the author should learn
  their suggestion was reshaped, and future readers should see why.
- **Underspecified** — name what is missing and ask, rather than filling the gap with a guess that
  turns out at review time to have been the whole disagreement.
- **Architecturally problematic** — name the principle it cuts against, with `file:line` and the
  guideline section. Implementing it anyway is writing tomorrow's refactor today.

Do not proceed past a non-sound verdict on your own judgement. "Do it anyway" is a perfectly good
answer — but it is the user's to give.

### Step 1.4 — Classify the issue

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

### Step 1.5 — Create the branch

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

### Step 2B.3 — Plan and get approval

Now, and not before: a plan written without the root cause is a guess with formatting. Follow
*The plan* above. Cover both the regression test and the fix, since approval has to precede
either, and decompose into phases if the fix spans more than one coherent slice — a fix plus the
call sites that share the flaw is usually two.

### Step 2B.4 — Write the failing test first

Add a regression test that reproduces the bug, plus negative and edge cases around it.
Follow the project's existing test conventions and place it beside comparable tests.

**Run it and confirm it fails**, for the reason the issue describes. A test that passes
before the fix is testing the wrong thing — go back to Step 2B.2.

### Step 2B.5 — Apply the minimal fix

Fix the root cause. Do not reformat surrounding code, rename things, or refactor
opportunistically.

Work the approved plan one phase at a time, closing each with *The phase gate*.

Adjacent bugs you notice on the way are not a distraction to be suppressed and not a licence to
widen the branch — route them through `lib/adjacent-problems.md`, which is exactly the decision you
are facing.

### Step 2B.6 — Verify

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

### Step 2F.3 — Design, and get the plan approved

Produce a design that follows the codebase's existing architecture. Favor dependency
injection so the feature is testable in isolation — inject collaborators rather than
constructing them internally or reaching for globals. Cite the file paths and line numbers
that justify each decision.

The design *is* the plan, so present it through `ExitPlanMode` per *The plan* above rather than as
prose to skim past, and decompose it into phases. A feature large enough to need a design is
almost always large enough to have more than one.

### Step 2F.4 — Implement with tests

Implement the design, writing tests alongside: the happy path, edge cases, error paths, and
any acceptance criteria stated in the issue. Match the surrounding code's idiom and comment
density.

Work the approved plan one phase at a time, closing each with *The phase gate*. Route anything the
gates surface in code this feature did not touch through `lib/adjacent-problems.md`.

### Step 2F.5 — Verify

Full test suite green; acceptance criteria each demonstrably met.

---

## Phase 2C — Chore workflow

Make the change directly. Keep it mechanical and reviewable. Add or update tests where the
change has observable behavior; a dependency bump or CI tweak may legitimately have none —
in that case verify by running the affected pipeline step locally.

Chores still get a plan, but a proportionate one: for genuinely mechanical work it is a sentence
and a single phase, which then collapses with the final pass per *The phase gate*.

---

## Phase 3 — Final review pass

Once the last phase is closed, review the branch as a whole:

1. **`/simplify`** over the full branch diff. The per-phase runs each saw one phase's code, so
   duplication that spans phases has been invisible until now — this is the only run that can see
   it. It is usually quick, precisely because the per-phase runs cleared everything local.
2. **`/code-review high`** over the full branch diff. Deeper than the per-phase `medium`: broader
   coverage, and worth the extra noise once, on the finished shape of the change.
3. **Address every finding.** Adjacent ones route through `lib/adjacent-problems.md`. Re-run the
   full suite afterwards, since both steps can edit code.

Nothing gets committed with findings outstanding. A finding deliberately declined is a decision,
recorded in the Phase 8 report — not an omission.

Skip this when the plan was a single phase and its gate already ran at this depth.

## Phase 4 — Release note

If the repository tracks a changelog (`metainfo.xml`, `*.appdata.xml`, `CHANGELOG.md`, or
`NEWS`) and the change is user-visible, add an entry in the existing style — the
`/add-release-note` skill does exactly this.

Skip for internal refactors, test-only changes, and bugs introduced *after* the most recent
release (there is nothing for users to be told about).

## Phase 5 — Commit

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
encodes that grouping logic. Adjacent fixes keep their own commits and do not carry the issue
trailer; they were never what the issue asked for.

## Phase 6 — Open the PR/MR

First run **`/rebase`**, so the very first CI run is judged against current `origin/HEAD` rather
than whatever the base was when the branch started.

Then open it:

- **`/create-pr`** normally.
- **`/draft-pr`** when a Follow-up leaves the branch short of ready-to-merge.

Both read `lib/pr-conventions.md` for platform detection, base resolution, the push, the changelog
label rule, and title/body composition — do not restate any of that here.

Record the PR/MR number and URL; Phase 7 needs both.

## Phase 7 — Drive CI to green

Loop until green or until one of the stop conditions fires.

### Step 7.1 — Sync onto the latest base

Run **`/rebase`**, which detects whether the base moved, resolves any conflicts, proves the branch
still builds and passes its suite, and force-pushes with a lease. It stops on its own when the base
has not moved, so this is cheap to run every pass — and it needs to run every pass, because other
branches keep landing while yours is in review.

If it stops on an unresolvable conflict or a rejected lease, stop the loop too and report.

### Step 7.2 — Wait for the run

```
gh pr checks <number> --watch        # GitHub
glab ci status                       # GitLab
```

CI takes minutes to hours, which is longer than a single command is allowed to block — poll at
intervals or run the watch in the background rather than hanging one call until it is killed.

### Step 7.3 — Green? Done. Red? Fix it

Invoke **`/fix-ci`**, which owns diagnosis, the fix, the amend into the right commit, and the
`--force-with-lease` push. It classifies each failure as fixable, pre-existing, or infrastructure —
pre-existing ones route through `lib/adjacent-problems.md`, infrastructure ones are not code
problems and are simply reported.

### Step 7.4 — Re-gate whatever CI changed

Phase 3 reviewed the branch as it stood *before* CI touched it. If `/fix-ci` changed source — as
opposed to formatting or CI configuration — run `/simplify` and then `/code-review medium` over
that delta, so nothing reaches the merge unreviewed.

### Step 7.5 — Back to Step 7.1

The base may have moved again while CI was running. That is the whole reason this is a loop.

**Stop and report** instead of looping again when:

- every check is green — the goal;
- the same check has failed three times running: the fix is not converging and a fourth attempt is
  guessing. Say what was tried and hand it back;
- a rebase conflict could not be resolved confidently, or the lease was rejected;
- what remains red is infrastructure, or work the user chose to defer. Say plainly that CI is not
  green and why, rather than implying the branch is finished.

Never make CI green by deleting, skipping or disabling a test. A green wrung out of a suite that no
longer checks anything is worse than an honest red, because it survives review.

## Phase 8 — Report

- **Issue** — number, title, URL, and your classification with reasoning.
- **Challenge verdict** — sound, or what you pushed back on and what was decided.
- **Root cause** *(bugs)* — the precise mechanism, with file:line.
- **Change** — what was modified and why.
- **Tests** — what was added; for bugs, explicit confirmation it failed before and passes after.
- **Review gates** — the phases, and the `/simplify` + `/code-review` runs that closed each.
- **Adjacent problems** — every triage decision and its outcome: fixed in which commit, filed as
  which ticket, suggested as which worktree, or declined and why.
- **Coverage** — coverage of the changed lines, if the project reports it.
- **Performance impact** — hot paths, allocations, complexity; state "none" if none.
- **Risk assessment** — Low / Medium / High with justification.
- **Pull request** — URL, and the final CI status.
- **Rebases** — how many, and what landed underneath the branch on the way.
- **Follow-ups** — anything left deliberately undone.

If the PR was opened as a draft, say how to promote it — `gh pr ready <number>` or
`glab mr update <iid> --ready`. Promoting is the author's call, so do not do it.

## Rules

- NEVER fix a bug you have not reproduced.
- NEVER write the fix before the failing test (bugs).
- NEVER modify a file before the plan is approved.
- NEVER build past a non-sound challenge verdict without an explicit decision from the user.
- NEVER guess at missing requirements — ask, or state the assumption prominently.
- NEVER fold an adjacent fix into a commit belonging to the issue; it gets its own.
- NEVER escalate `--force-with-lease` to `--force`.
- NEVER rebase or force-push the default branch.
- NEVER make CI green by disabling, skipping or deleting a test.
- NEVER work a closed issue without confirming with the user.
- ALWAYS branch from a freshly fetched default branch.
- ALWAYS close each phase with `/simplify` then `/code-review`, naming the level.
- ALWAYS run the full test suite before reporting done.
- ALWAYS rebase onto the latest base before judging a CI result.
