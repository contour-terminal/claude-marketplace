---
name: sprint-batch
description: Work several sprint tickets from one lane onto a single branch, so one pull request, one CI cycle, one rebase and one merge cover all of them instead of one each. Use when a manager dispatches a run of tickets rather than a single one, when a lane's queue is several small tickets deep, or when CI waits and cascading cross-lane rebases are costing more than the tickets themselves. The count is a ceiling, not a quota. Findings go to the manager, never to the user.
argument-hint: "[count] [lane]"
allowed-tools: Bash, Read, Grep, Glob, Edit, Write, Agent, Skill, EnterPlanMode, ExitPlanMode, SendMessage
---

# Work a Batch of Sprint Tickets

You are one developer in a lane and the manager has given you several tickets instead of one. They
go onto **one branch**, become **one pull request**, and are proved by **one CI cycle**.

The failure this skill is built against is not a code failure, it is an arithmetic one. A sprint
that runs one ticket per branch pays, for every ticket, a plan approval, a whole-branch review, a
PR, a CI loop whose every pass rebuilds and re-tests the tree, and a merge — and each of those
merges moves the base under every other lane in flight, which forces *their* rebases, which restarts
*their* CI. The cost is not linear in the tickets, it compounds across the lanes. **The rebase train
is driven by merge frequency**, so dividing the merges by the batch size is the whole idea and
everything below follows from it.

What batching does not change: the lane split, who reviews what, or what `Done` means. It is still
one lane, one branch, one developer, and every ticket still closes on its own merged commit. What it
does change is that a batch **fails as a unit** unless a ticket can be taken out of it — which is
why Step 4 gives every ticket its own commits and Step 8 is a first-class procedure rather than an
improvisation.

`$ARGUMENTS` is the ticket count, optionally followed by your lane. If the lane is missing, ask the
manager rather than guessing; picking your own tickets is how two lanes end up in one file. A batch
of one is `/sprint-dev`, and so is a ticket that Step 2 says must go alone.

Bare `Bash` is deliberate here: this skill builds and tests with whatever the repository uses, and a
skill that invokes another has to cover what the callee runs.

## Context

- Worktree: !`git rev-parse --show-toplevel 2>/dev/null || echo "(not in a git worktree)"`
- Branch: !`git branch --show-current 2>/dev/null`
- Base: !`git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "(unknown)"`
- Uncommitted: !`git status --porcelain 2>/dev/null | head -20`
- Tickets already on this branch: !`git log --format=%B origin/HEAD..HEAD 2>/dev/null | grep -Eo '^(Closes|Fixes) #[0-9]+' | sort -u | tr '\n' ' ' | grep . || echo "(none)"`

The last line earns its place on a resumed batch. A batch branch carries several closing trailers
and nothing else on the branch says how far it got; reading them is how a session that compacted
mid-batch finds out which tickets it already delivered without re-reading every commit.

## Step 1 — Load the shared policy

Read these and cite their sections by heading rather than restating them:

- `${CLAUDE_PLUGIN_ROOT}/lib/team-protocol.md` — §*Batching a lane's tickets into one branch* first,
  then §*The developer brief*, §*The claim is not the work*, §*Review gates*, §*Reading a red
  check*, and §*Reporting to the manager*.
- `${CLAUDE_PLUGIN_ROOT}/lib/phase-gates.md` — §*The plan* and §*The phase gate*. A batch **is** a
  multi-phase plan whose phases are tickets, so that file already describes most of what you do.
- `${CLAUDE_PLUGIN_ROOT}/lib/git-safety.md` — §*Force-pushing safely*, which Steps 7 and 8 need.
- `${CLAUDE_PLUGIN_ROOT}/lib/adjacent-problems.md` — §*Classification*, for what you find and do not
  fix.

## Step 2 — Establish where you are, and choose the batch

Three facts first, exactly as `/sprint-dev` §*Step 2 — Establish where you are* establishes them:
**your own worktree** never the primary checkout, **your lane's paths**, and the base branch
resolved rather than assumed with `git symbolic-ref --short refs/remotes/origin/HEAD`.

Then choose the tickets. Walk your lane's `Todo` items in ascending `Order` and **stop — do not skip
past — at the first of these**, taking however many you collected:

| Stop at | Why |
|---|---|
| A ticket in another lane | Cross-lane batching reintroduces exactly the collision the lane split exists to prevent |
| A ticket in another `Phase` | A phase is *what becomes true when it completes*; batching across the boundary makes that signal arrive mixed with unrelated work, and the next phase's items may be waiting on another lane |
| A `Blocked` ticket whose blocker has not merged | `Blocked by` is free text, so you cannot prove the tickets after it do not depend on it either |
| A ticket with no **Acceptance** clause | One that can only be closed by opinion gets argued about at merge review — and here it takes the whole batch with it. Ask the manager for one |
| A ticket whose design is genuinely open | One plan is approved for the whole batch, so a ticket needing a decision of its own goes alone |

**The count is a ceiling and never a quota.** Taking fewer is the normal case, and a batch padded to
reach the number is a batch that will be excised down to it later, expensively. Say how many you
took and what stopped you.

Then fix the order within the batch. `Order` decides where it has an opinion; where it does not, put
the ticket **most likely to turn out wrong last**. Dropping the tip is a `reset`; dropping from the
middle is a `rebase --onto`. Bug tickets that came out of a review pass are the usual candidates,
because they may not reproduce at all.

**A ticket another lane is blocked on is not batched.** Ship it alone and fast — unblocking someone
is the entire point of shipping it, and a batch buries it behind work nobody is waiting for.

## Step 3 — Plan the batch once

One plan, per `lib/phase-gates.md` §*The plan*, with **one phase per ticket** and the phases in the
Step 2 order. Approved once, the way `/sprint-dev` already has a plan approved.

This is where the first saving lands: N plan approvals become one. It is also where a batch that
should not have been a batch reveals itself — if the plan cannot say what each ticket changes
without describing the others, they are not independent and Step 8 will not be able to separate
them. Hand it back to the manager instead of building it.

Cut the branch once, from the freshly fetched base, naming the tickets it carries — the branch is
the claim for **all** of them, per `lib/team-protocol.md` §*The branch is the claim*, so the numbers
have to be visible on it.

## Step 4 — Work each ticket as its own phase

For each ticket, follow `/work-issue` §*Phase 1 — Understand* (fetch it, follow what it links to,
challenge it, classify it bug/feature/chore) and then its matching §*Phase 2B — Bug workflow*,
§*Phase 2F — Feature workflow* or §*Phase 2C — Chore workflow*, **and stop at the end of Phase 2**.

**Do not invoke `/work-issue` itself.** It opens a PR and drives its own CI loop per issue, which is
precisely the cost this skill exists to amortise. Its Phases 3 through 7 happen once here, in Steps
6 and 7.

Close each ticket with `lib/phase-gates.md` §*The phase gate*, with three deltas:

- **Record the ticket base** — `git rev-parse HEAD` before you start it. It is the review range and
  the excision point both.
- **Gate at `/code-review medium --fix <ticket-base>..<branch>` only.** Name the branch, never
  `HEAD`: `lib/team-protocol.md` §*Review gates* explains why a forked skill resolves `HEAD` against
  the primary worktree, which in a parallel run is parked on a stale base. No `/simplify` yet — it
  runs once, in Step 6, where it can finally see duplication spanning two tickets.
- **Exactly one commit per ticket carries the closing trailer** — `Fixes #N` for a bug, `Closes #N`
  for a feature or chore, on a `-s` commit whose subject carries the module area, per `/work-issue`
  §*Phase 5 — Finalize the history*. This is load-bearing twice over: it is what flips that board
  item when the PR merges, and it is what makes the ticket findable and excisable after the SHAs
  have moved.

Push at every ticket boundary, half-finished work included. An incomplete pushed branch is
recoverable and an unpushed one disappears with the worktree — and here it disappears with several
tickets' worth of work, not one.

**A recorded SHA does not survive a rebase, and a batch holds several of them.** `/absorb` and every
autosquash rewrite the branch; `lib/phase-gates.md` §*The phase gate* already warns that one
orphaned phase base silently widens a review range to almost the whole branch, and a batch has one
per ticket. So after any history rewrite, **re-derive the boundaries from the trailers rather than
trusting what you wrote down** — the second command lists exactly the boundary commits, one per
ticket, in order:

```
git log origin/<base>..<branch> --format='%h %s' --reverse
git log origin/<base>..<branch> --format='%h %s' --reverse --grep='^\(Closes\|Fixes\) #'
```

Stay in lane throughout. A change wanted outside your paths goes to the manager, not into the
branch — and a batch makes that temptation stronger, because the branch is already large enough that
one more file looks like nothing.

## Step 5 — Open the draft PR early, and then look away

As soon as the **first** ticket's gate closes, push and run `/draft-pr`. It reads
`lib/pr-conventions.md` for platform detection, the base, the changelog label rule and title/body
composition; the body takes that file's §*Composing the title and body* **Larger branch** form, with
the goal paragraph naming the batch and the `## Changes` bullets grouped one per ticket. `/draft-pr`
never promotes the PR — that is the author's call and stays so.

**Keep every closing keyword on the commits and out of the PR body.** Then excising a ticket in Step
8 removes its trailer mechanically, instead of depending on somebody remembering to edit prose that
still promises to close it.

Keep pushing at each ticket boundary. CI now runs alongside the rest of the batch and costs nothing
to ignore, which is the point: the wait overlaps the work instead of following it.

**Look at CI exactly once, after the first ticket, and then not again until Step 7.** One look
catches an environment break after one ticket instead of after all of them. Looking more often does
not make CI faster and each look is a full round trip — a poll loop is one of the largest and least
useful token costs in a sprint.

## Step 6 — Gate the batch, once

With every ticket committed, run over the whole branch, once:

1. **`/simplify`.** Each per-ticket `medium` ran while the later tickets did not exist, so
   duplication spanning two of them has been invisible until now — `/work-issue` §*Phase 3 — Final
   review pass* makes the same argument about phases, and it is stronger here because tickets are
   less related to each other than phases of one change are.
2. **`/code-review high --fix <base>..<branch>`.** Once for the batch. This is the pass that N
   separate PRs would have run N times.
3. **Address every finding**, `/absorb` putting each on the commit that introduced the line —
   which is what keeps a finding attributable to its ticket. Re-run the full suite afterwards, and
   re-derive the ticket boundaries, because `/absorb` rebased.
4. **The release note and the history check**, once — `/add-release-note` if the repository tracks a
   changelog and any ticket in the batch is user-visible, then the check in `/work-issue`
   §*Phase 5 — Finalize the history* that every ticket's trailer is present and on the right
   commit.

**If the batch diff is now too large for one `high` review to hold, the batch was too big.** That is
the real limit, and the count was only ever a ceiling on top of it. Say so in the report rather than
letting a review skim.

## Step 7 — One rebase, one CI wait

**`/rebase` exactly once**, here, and on the manager's signal — not per ticket, not on every pass of
a loop. It builds and runs the full suite before it force-pushes, and in a sprint its cheap
no-op exit never fires because the manager is landing other lanes between rounds. Running it per
ticket is how the branch pays that cost N times for one merge.

Then wait once. Confirm the run belongs to the **current** head SHA before reading anything —
`gh pr view <number> --json headRefOid`, then match it — or you read the previous head's results and
declare victory on a CI that never ran against this tree. Then block on it **in the background**
rather than polling:

```
gh pr checks <number> --watch          # GitHub
glab ci status                         # GitLab
```

One backgrounded blocking wait costs one round trip for a run of any length. A poll loop costs one
per poll and learns nothing extra.

Red is not simply red. Ask for the state explicitly with `gh pr checks <n> --json name,state` before
diagnosing anything — `lib/team-protocol.md` §*Reading a red check* has why, and why a red that
follows a multi-label edit is usually self-inflicted and clearing itself. Then invoke `/fix-ci`,
which brings its own rebase; do not add a second. Re-gate only what it changed, scoped, per
`/work-issue` §*Step 7.4 — Re-gate whatever CI changed*.

Stop and report on the conditions in `/work-issue` §*Step 7.5 — Back to Step 7.1*, plus one that
only exists here: **when one ticket's code has failed three times running, drop that ticket — not
the batch.** Step 8.

Never make CI green by deleting, skipping or disabling a test.

## Step 8 — Dropping a ticket

Reached from Step 4 or Step 7, not in order. **A batch that cannot shed a ticket holds every
finished ticket in it hostage to its worst one**, and that is the failure batching introduces, so
this is a routine operation and not a defeat.

Drop a ticket when you cannot reproduce what it describes, when it turns out to be wrong, when it
needs a change outside your lane, when it needs a decision only the manager can make, or when its
fix is not converging.

Re-derive its ticket base `A` and its last commit `B` from the trailers first — anything you
recorded earlier is orphaned if the branch has been rebased since:

```
git rebase --onto <A> <B> <branch>              # excise a ticket from the middle
git reset --hard <A>                            # or, when it is the tip segment
git log origin/<base>..<branch> --grep='#<n>'   # must come back empty
```

Then **build and run the full suite**, force-push with a lease naming the expected SHA per
`lib/git-safety.md` §*Force-pushing safely*, edit the ticket out of the PR body, and report it to
the manager so the board item goes back to `Todo`.

**If the suite fails after the excision, a later ticket depended on the dropped one and nobody
declared it.** Hand the whole batch back to the manager to re-sequence. Do not invent the missing
dependency's resolution inside a branch that was built on the assumption it did not exist.

## Step 9 — Hand back to the manager

You do not merge. Report once — by `SendMessage` if you are a subagent or peer session, otherwise as
your final message — and report **per ticket**, not per batch:

- Every ticket: delivered or dropped, and for a dropped one, why and what it needs.
- Each delivered ticket's acceptance clause, and what demonstrates it.
- **Which gates actually ran**, in those words. A gate that could not start and a gate that found
  nothing produce the same silence, and only one of them is good news.
- Anything you found and did not fix, with file:line and a failure scenario, classified first with
  `lib/adjacent-problems.md` §*Classification*.
- Whether documentation changed, and where it did not, why the change did not need it.

Then two lines the manager cannot get anywhere else: **which tickets share this branch**, so the
merge is known to close all of them at once, and **the single CI state that covers them all**.

**Everything goes to the manager and nothing to the user.** If a skill raised a background-task chip
from inside its own fork — some do, without you choosing to — say so and restate the finding in
full, so the manager can act on it and tell the user the chip is safe to dismiss. Do not call
task-spawning tools yourself.

## Rules

- **NEVER batch across a lane or across a `Phase`.** Stop the batch at the boundary and take fewer.
- **NEVER pad a batch to reach the count.** It is a ceiling; a review-sized diff is the real limit.
- **NEVER batch a ticket another lane is blocked on.** Ship it alone; unblocking is the point.
- **NEVER let one bad ticket hold the batch.** Excise it and deliver the rest.
- **NEVER poll CI in a loop.** One backgrounded blocking wait, after the batch is complete.
- **NEVER rebase per ticket.** Once per batch, in Step 7, on the manager's signal.
- **NEVER trust a ticket base across a rebase.** Re-derive the boundaries from the trailers.
- **NEVER run a review gate unscoped**, and never with `HEAD` in the range.
- **NEVER change a file outside your lane**, however small, and however large the branch already is.
- **NEVER report to the user.** Findings, blockers and scope growth go to the manager.
- **ALWAYS give each ticket its own commits and exactly one closing trailer.** It is what makes the
  ticket excisable and what marks it `Done` on merge.
- **ALWAYS push at every ticket boundary**, half-finished work included.
- **ALWAYS build and run the full suite after an excision**, before pushing it.
- **ALWAYS say how many tickets you took and what stopped you** from taking more.
- **ALWAYS report per ticket.** A batch-level "done" hides which one was not.
