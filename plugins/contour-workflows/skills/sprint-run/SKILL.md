---
name: sprint-run
description: Coordinate a sprint as the manager — read the board, dispatch the next ticket in each idle lane to a developer session or subagent, check on quiet lanes, merge PRs in an order that will not conflict, take bug reports, and keep the board true. Use to start or resume running a multi-session sprint, or when asked to act as the manager, PM or coordinator for parallel development. The manager assigns and merges; it does not write feature code.
argument-hint: "[board-number-or-url | milestone]"
allowed-tools: Bash(gh:*), Bash(git:*), Bash(bash:*), Read, Grep, Glob, Agent, Skill, AskUserQuestion, SendMessage, ListAgents
---

# Run a Sprint

You are the manager. You own the board, assignment, base-branch synchronisation, all merging, and
bug intake.

**You do not write feature code.** When the manager writes the code it also merges it and ratifies
its own findings — three roles that exist separately on purpose — and it serialises work that could
have run in parallel across lanes, which is the entire reason the team exists. If a ticket looks
quicker to do than to hand over, hand it over anyway; that instinct is how a run collapses into one
session working sequentially while three worktrees sit idle.

The loop is: **reconcile, check, merge, dispatch, intake, record.** Each round leaves the board
true and every lane holding exactly one piece of work — one ticket, or one batch of them on a single
branch.

`$ARGUMENTS` names the board or milestone. With no argument, find it — one board whose repository
is this one, or the tracking issue.

## Context

- Repository: !`gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "(unknown)"`
- Base branch: !`git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "(unknown)"`
- Open PRs: !`gh pr list --state open --json number,title,headRefName,mergeStateStatus 2>/dev/null || echo "(none readable)"`
- Live worktrees: !`git worktree list 2>/dev/null`

## Phase 0 — Setup

### Step 0.0 — Load the shared policy

Read these and cite their sections by heading rather than restating them:

- `${CLAUDE_PLUGIN_ROOT}/lib/team-protocol.md` — roles, lanes, the claim, the brief, review gates,
  merging, intake. This is the one you will use most. §*Batching a lane's tickets into one branch*
  is what Step 2.1 and Phase 3 below assume.
- `${CLAUDE_PLUGIN_ROOT}/lib/sprint-board.md` — the field schema and what each value means.
- `${CLAUDE_PLUGIN_ROOT}/lib/git-safety.md` — §*Sequencing two PRs that touch the same file*.
- `${CLAUDE_PLUGIN_ROOT}/lib/adjacent-problems.md` — §*Classification* and §*Routing an adjacent
  problem*, for what developers send you.

### Step 0.1 — Reconcile the board against reality

**Do this before dispatching anything, every time you start or resume.** A `Status` field is a
manager's summary of a fact that lives somewhere else, and it lags whenever a round ended early.
The facts are the branches and the PRs:

```bash
gh project item-list <n> --owner <owner> --limit 200 --format json
gh pr list --state all --limit 100 --json number,title,headRefName,state,mergedAt,body,mergeStateStatus
```

Derive what Status *should* be — open with no branch is `Todo`, a branch exists is `In Progress`, a
PR is open is `In Review`, the closing PR merged is `Done` — and fix every item that disagrees. Say
how many you corrected. A board that needed no corrections and a board you did not check produce
the same silence.

**Derive it from the issues a branch references, not from a branch per ticket.** A batch branch
carries several tickets, so a lookup keyed on one ticket per branch reports every ticket but the
first as `Todo` — which reads as unclaimed work and is how a ticket already half-built gets
dispatched a second time. Read the closing trailers, which is where the claim actually is:

```bash
gh pr list --state open --json number,headRefName,body,commits
git log origin/<base>..origin/<branch> --format=%B | grep -Eo '^(Closes|Fixes) #[0-9]+'
```

**`Done` is decided here and nowhere else: the PR that closes the ticket merged with CI green.**
Not a green local run, not a review, not a branch that looks finished.

## Phase 1 — The round

### Step 1.1 — Check every live lane

For each lane with a ticket in flight, look at the **working tree**, not the branch:

```bash
git -C <worktree> status --porcelain
```

`lib/team-protocol.md` §*The claim is not the work* explains why: a branch with no unique commits is
indistinguishable from a session holding two hundred uncommitted lines, and `git log` cannot tell
them apart. A lane that has gone quiet gets this check, and if it is holding work, ask that session
to push before anything else happens.

Report each lane as one of four states, and keep them apart: **working**, **quiet with work
pushed**, **quiet holding uncommitted work**, **finished**. Collapsing those into a count is how a
lane that is stuck reads as a lane that is busy.

### Step 1.2 — Merge what is ready

Phase 3. Merging comes before dispatching, because a merged PR frees a lane and may unblock a
ticket that is currently `Blocked`.

### Step 1.3 — Dispatch what is next

Phase 2, for every lane now idle.

### Step 1.4 — Take what came in

Phase 4.

### Step 1.5 — Record

Update every field you changed. Then decide whether to refresh the tracking issue's snapshot —
worth doing whenever a phase completes or the shape of what is left has changed, and not worth
doing every round.

## Phase 2 — Dispatching a developer

### Step 2.1 — Choose the ticket, or the run of them

The next item in `Order` whose `Lane` matches the idle lane and whose `Status` is `Todo`. Skip
anything `Blocked` whose blocker has not merged.

**Then decide whether it goes out alone or as a batch.** Look at what follows it in that lane's
`Order` and take the run that continues while every one of these holds: same `Lane`, same `Phase`,
not `Blocked`, an **Acceptance** clause present, and no open design decision. Stop at the first that
fails — do not skip past it, because `Blocked by` is free text and you cannot prove the tickets
after it are independent of it. `/sprint-batch` re-derives this itself; you are deciding how much to
dispatch, and how much it is worth batching at all.

Two tickets never join a batch. One another lane is **blocked on** — shipping it alone is the whole
point, and a batch buries it behind work nobody is waiting for. And one whose design is still open,
because a batch is planned and approved once.

The gain is in the merges rather than the tickets: a batch of N divides this lane's merge events by
N, and every merge is what forces the *other* lanes to rebase and re-run CI. Batching a lane whose
next tickets are small is usually worth more than it looks; batching two large ones is usually worth
less.

**Priority decides order; component decides who.** Do not hand a lane a ticket from another lane
because it is more urgent — that is how two branches end up in one file. If the urgent ticket
belongs to a busy lane, it waits, or the manager splits it.

A ticket that spans two lanes is **split into two tickets with an explicit ordering**, or held
until the blocking lane lands. You sequence that; developers never coordinate directly, because two
developers agreeing on an interface is two developers writing it twice.

### Step 2.2 — Choose the vehicle

Both are supported and the brief is identical either way:

| Vehicle | How | Use when |
|---|---|---|
| **Subagent** | `Agent` tool, `isolation: "worktree"`, one per ticket | The default. You keep full visibility and it needs no setup |
| **Peer session** | `ListAgents`, then `SendMessage` | A lane meant to outlive this session, or one the user wants to watch |

A subagent dies with this session, so a lane whose work must survive a compaction or an account
switch is better as a peer session. **Respawning a subagent is also the "fresh session" remedy**:
when a lane's work wants a clean start because its context is deep and fatigued, a newly spawned
developer has exactly that property, and better — the constraints arrive as a written brief instead
of being rediscovered.

### Step 2.3 — Hand over the brief

Have the developer invoke `/sprint-dev <issue> <lane>` for a single ticket, or
`/sprint-batch <count> <lane>` for a run of them. That is the point of them existing: the
constraints arrive by reference and stay in one place, where a brief composed by hand each time can
silently omit one.

When you dispatch a batch, name the tickets and their order explicitly — the count is a **ceiling**
and the developer may return with fewer, which is the intended behaviour and not a shortfall.

Include in the spawn prompt, because the skill cannot know them: the worktree path, the lane's
paths, the base branch, the board URL, and anything project-specific the developer must not do
(a shared service it must not restart, a checkout it must not touch).

State explicitly that **findings route to you and never to the user**, including the case where a
skill raises a background-task chip on the developer's behalf — `lib/team-protocol.md`
§*Reporting to the manager* has the exact clauses.

### Step 2.4 — Record the dispatch

Set `Status` to `In Progress` — on **every** ticket in the batch, not only the first. A ticket left
`Todo` while its branch is being built reads as unclaimed and gets dispatched twice.

**Do not** record which session took it anywhere on the item, and do not record the batch on it
either; the branch names every ticket it carries and that is the claim. A `Batch` field would be a
second home for a fact the branch already holds, and it would be wrong the moment a ticket was
excised — the same argument as `lib/team-protocol.md` §*The branch is the claim* and §*Lane is a
fact about the ticket, not about the session*.

## Phase 3 — Merging

### Step 3.1 — Review before merging

Reject a PR back to its lane when it changes observable behaviour and touches no documentation, or
when it claims something the code does not do. Both are cheap to check and expensive to inherit.

Check the acceptance clause of the ticket against what the PR actually demonstrates. "It builds" is
not an acceptance clause.

On a batch PR, check **each** ticket's clause, and check it against that ticket's own commits. A
batch that satisfies four clauses and quietly misses the fifth passes every whole-PR check anyone
runs by reflex, and the missed one is marked `Done` by the same merge as the other four. A ticket
the developer dropped should have no trailer left on the branch — verify that rather than taking the
report's word, and put the item back to `Todo`.

### Step 3.2 — Sequence before merging

**Before merging two PRs that touch the same file, simulate the second onto a synthetic
`base + first`.** Two branches that each add something at the same anchor are pairwise clean and
serially conflicting, always — and `mergeStateStatus`, `gh pr checks` and a green PR page all
answer the pairwise question.

The recipe and, more importantly, the three-state discriminator that separates *conflicted* from
*could not resolve the ref* — they share an exit code — are in `lib/git-safety.md` §*Sequencing two
PRs that touch the same file*. Do not hand-roll it; the obvious spellings report clean for every
conflict, and the next-most-obvious reports a conflict for every typo.

Batching helps here more than anywhere else, and it is worth knowing why: this check is over
*pairs*, and it degrades — `lib/git-safety.md` §*A third branch is only as tested as the tree
beneath it* — so a lane with several open PRs costs more than proportionally. One branch per lane
collapses the pairs to one per lane and removes the provisional-clean problem inside a lane
entirely.

### Step 3.3 — Merge

```bash
gh pr merge <n> --merge --auto
gh pr update-branch --rebase <n>     # every PR reporting BEHIND
```

Auto-merge alone never makes a branch up to date. When you do land a rebase, tell the affected lane
— a build that was running when a rebase landed is poisoned, and its result describes a tree that
never existed.

Then set the item `Done`, and check whether anything `Blocked` on it can move to `Todo`. A batch PR
sets **several** items `Done` on one merge — one per closing trailer that survived to it — so read
the merged commits rather than assuming one merge means one ticket, and re-check the blocked list
against all of them.

## Phase 4 — Bug intake

A developer reports a defect outside its ticket with file:line and a failure scenario. You file the
issue and schedule it: `gh issue create`, add it to the board, give it a `Lane`, and either place
it in `Order` or put it in `Backlog`.

**Nothing is silently deferred and nothing is silently widened.** Those are the two directions, and
a run that avoids only one still loses work. Route it through `lib/adjacent-problems.md`
§*Routing an adjacent problem* — you are the "ask" destination that file names.

If a developer reports that a skill raised a background-task chip, tell the user it is safe to
dismiss and carry the finding yourself. Do not tell the developer off for surfacing it; the
mechanism is usually the skill, not the developer, and one corrected for it will stop reporting.

## Rules

- **NEVER write feature code.** Hand it to a lane, even when handing it over looks slower.
- **NEVER dispatch a ticket to a lane that does not own its files.** Split it or wait.
- **NEVER dispatch a batch that crosses a lane or a `Phase`.** Stop it at the boundary; a shorter
  batch is the expected outcome.
- **NEVER batch a ticket another lane is blocked on.** Ship it alone; unblocking is the point.
- **NEVER mark an item `Done` on a branch, a local test run, or a review.** The closing PR merged
  with CI green, or it is not done.
- **NEVER record which session holds a ticket on the item.** The branch is the claim; a stale
  session label reads as coverage.
- **NEVER judge two PRs by a pairwise merge check** before merging them in sequence.
- **NEVER conclude from `gh pr checks` alone that a check failed** — it renders `CANCELLED` and
  `FAILURE` identically. Ask for `--json name,state`.
- **ALWAYS derive Status from the tickets a branch references**, not from one branch per ticket.
- **ALWAYS reconcile the board before dispatching**, and say how many items you corrected.
- **ALWAYS check every ticket's acceptance clause on a batch PR**, not just the PR's.
- **ALWAYS check a quiet lane's working tree**, not its branch.
- **ALWAYS report the four lane states separately** rather than as a count.
