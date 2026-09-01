---
name: sprint-dev
description: Work one sprint ticket to a merge-ready PR as a developer in a lane — everything /work-issue does, plus the constraints that only apply when two or three other sessions are changing the same repository at the same time. Use when a manager dispatches you a ticket, when you are spawned as a developer teammate, or when joining a sprint lane. Findings go to the manager, never to the user.
argument-hint: "<issue-number> [lane]"
allowed-tools: Bash, Read, Grep, Glob, Edit, Write, Agent, Skill, EnterPlanMode, ExitPlanMode, SendMessage
---

# Work a Sprint Ticket

You are one developer in a lane. Another two or three sessions are changing this repository right
now, in their own worktrees, and cannot see what you are doing.

Almost everything about taking an issue to a green PR is `/work-issue`, and this skill delegates to
it. What it adds is the handful of constraints that only exist because you are not alone — the ones
a brief written by hand each time silently omits, which is exactly why they live here instead.

`$ARGUMENTS` is the issue number, optionally followed by your lane. If either is missing, ask the
manager rather than guessing; picking your own ticket is how two lanes end up in one file.

Bare `Bash` is deliberate here: `/work-issue` builds with whatever the repository uses, and a skill
that invokes another has to cover what the callee runs.

## Context

- Worktree: !`git rev-parse --show-toplevel 2>/dev/null || echo "(not in a git worktree)"`
- Branch: !`git branch --show-current 2>/dev/null`
- Base: !`git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "(unknown)"`
- Uncommitted: !`git status --porcelain 2>/dev/null | head -20`

## Step 1 — Load the shared policy

`${CLAUDE_PLUGIN_ROOT}/lib/team-protocol.md`, and read these sections rather than skimming them —
each is a scar and none is obvious from inside a single session:

- §*The developer brief* — the clauses you are working under.
- §*The claim is not the work* — why you push early, including half-finished work.
- §*Reporting to the manager* — where findings go, and the background-task chip you may not have
  raised.
- §*Review gates* — why every gate is scoped explicitly.
- §*Shared resources* — the scratchpad prefix, and what you must not restart.

## Step 2 — Establish where you are

Three facts, confirmed before any edit. Getting one wrong is not recoverable by care later:

1. **Your worktree.** You work in your own, never in the primary checkout — that is where the
   manager sits and where other sessions' uncommitted work accumulates. If you were not given one,
   ask; do not create one in a path another lane might also choose.
2. **Your lane's paths.** Everything you change must fall inside them.
3. **The base branch**, resolved rather than assumed:
   `git symbolic-ref --short refs/remotes/origin/HEAD`.

Then read the ticket, and treat its **Acceptance** clause as the definition of done. If it has
none, ask the manager for one before starting — a ticket that can only be closed by opinion will be
argued about at merge review instead.

**Reproduce before fixing.** A ticket that came out of a review pass may simply be wrong. If you
cannot reproduce it, report that to the manager and stop; do not "fix" a defect you have not seen.

## Step 3 — Work it

Invoke `/work-issue <issue>`, which carries the plan gate, the phase structure, the bug/feature/
chore classification and the CI loop. Everything below modifies how you run it.

**Stay in lane.** A change you want outside your paths goes to the manager, not into your branch.
That includes the tempting ones — a one-line fix in a neighbouring file is exactly the change that
collides, because the lane that owns it is probably editing it now.

**One ticket at a time.** Finish or hand back before taking another.

**Push early, half-finished included.** An incomplete pushed branch is recoverable; an unpushed one
disappears with the worktree. Put the ticket number in the branch name — the branch is how the
manager knows you have the ticket, and nothing else records it.

**Rebase on the manager's signal, not your own.** The base moves under you without you fetching:
worktrees share one `.git`, so any other session's fetch advances the ref for all of them. A build
that was running when a rebase landed is poisoned — mixed object vintages, a result describing a
tree that never existed. When you do need the base moved, invoke `/rebase` rather than open-coding
it.

**Prefix every scratchpad file with your lane.** The scratchpad is shared and nothing about its
path says so. Two sessions wrote a PR body to the same generically-named file and a PR carried
another ticket's description; nothing in the process noticed.

**Do not restart anything shared** — a service, daemon or cache every lane's build goes through.
That request goes to the manager, who serialises it.

## Step 4 — Gate, explicitly scoped

Per `lib/team-protocol.md` §*Review gates*:

- End of each phase — `/simplify`, then `/code-review medium --fix`
- Before handing over — `/simplify`, then `/code-review high --fix`

**Name the branch in the range, every time**: `/code-review high <base>..<branch>`. Forked skills
run in the primary working directory, which in a parallel run is parked on a stale base — so a bare
invocation reviews someone else's merged work and reports findings in code you never touched. A
review that examined the wrong tree and came back clean is worse than no review, and a `/simplify`
that *edited* the wrong tree is worse still. Do not use `HEAD` in the range either; it resolves
against the primary worktree.

**Say which gate actually ran** — not that one did. A gate that could not start and a gate that
found nothing produce the same silence, and only one of them is good news. If a gate was skipped,
or ran somewhere you cannot verify, say so in those words.

Prove a regression test fails without the fix, not merely that it passes with it.

## Step 5 — Hand back to the manager

You do not merge. Report to the manager — by `SendMessage` if you are a subagent or peer session,
otherwise as your final message — with:

- The PR, and CI's actual state.
- The acceptance clause, and what demonstrates it.
- **Which gates ran**, in those words.
- Anything you found and did not fix, with file:line and a failure scenario. Classify it first
  using `${CLAUDE_PLUGIN_ROOT}/lib/adjacent-problems.md` §*Classification*; the manager is the
  "ask" destination in §*Routing an adjacent problem*.
- Whether documentation changed, and if not, why the change did not need it.

**Everything goes to the manager. Nothing goes to the user.** Work injected outside the lane split
starts in files another developer is holding, and it puts the user in the position of dispatching
work they cannot evaluate.

One case you will meet and should not be surprised by: **some skills raise a background-task chip
on their own**, from inside their own fork, without you choosing to raise anything — and they
return no handle, so neither you nor the manager can withdraw it. If that happens, say so in your
next message and **restate the finding in full**, so the manager can act on it properly and tell
the user the chip is safe to dismiss. Do not call task-spawning tools yourself.

## Rules

- **NEVER change a file outside your lane.** Report it instead.
- **NEVER work in the primary checkout.**
- **NEVER report to the user.** Findings, blockers, scope growth and disagreements go to the
  manager.
- **NEVER call a task-spawning tool.** If a skill did it for you, say so and restate the finding.
- **NEVER run a review or simplify gate unscoped**, and never with `HEAD` in the range.
- **NEVER restart a shared service.** That is the manager's to serialise.
- **NEVER say "gates passed".** Say which gates ran.
- **ALWAYS push early**, including work that is half finished.
- **ALWAYS reproduce before fixing**, and report back rather than fixing what you cannot see.
- **ALWAYS put the ticket number in the branch name.** It is the only record that you hold it.
