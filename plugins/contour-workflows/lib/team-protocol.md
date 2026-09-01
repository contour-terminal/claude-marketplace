# Team protocol

Shared policy for running one repository with several Claude sessions at once — a **manager** that
owns the board and the merges, and two or three **developers** that each hold a component.
`/sprint-plan`, `/sprint-run`, `/sprint-status` and `/sprint-dev` read this file and cite its
sections by heading.

It exists because the interesting failures in a parallel run are not merge conflicts. They are
*representation* failures: a value that says who is working on something and has quietly stopped
being true, a branch that looks empty while a worktree holds two hundred uncommitted lines, a
review that examined the wrong tree and came back clean. Each rule below is a scar, and the prose
keeps the failure rather than stating the rule alone — a rule without its failure gets argued away
by the next reader, usually persuasively.

This is a reference document, not a skill. It has no frontmatter and is never invoked directly.

## Roles

One manager session. Two or three developer sessions.

The manager owns the board, assignment, base-branch synchronisation, all PR merging, and bug
intake. **It does not write feature code.** When it does, it stops being able to review, and
reviewing its own work is how a wrong finding gets ratified twice. It also serialises work that
could have run in parallel across lanes, which is the entire reason the team exists.

Developers each work in their own git worktree, on their own branch, **one ticket at a time**.

Developers never coordinate directly. Two developers agreeing on an interface is two developers
writing it twice; the manager sequences that instead. A ticket that spans two lanes is **split into
two tickets with an explicit ordering**, or held until the blocking lane lands.

## Lanes

**Tickets are assigned by component, not by priority.** Priority decides *order*; component decides
*who*, because that is what keeps three branches from colliding.

A lane is a set of paths one developer owns for the duration of the sprint. Three is the usual
number — beyond that the paths get too fine to hold a whole ticket, and the splitting cost
overtakes the parallelism.

**Deriving lanes for a repository that has none.** Do not invent a taxonomy. Read one off what the
repository already asserts about itself, in this order, and stop at the first that yields a clean
partition:

1. `CODEOWNERS` — an ownership split someone already thought about.
2. Existing `area/*` (or equivalent) labels, especially where they mirror a docs or rules layout.
3. The top-level source directories, weighted by where the sprint's tickets actually land.

Then **confirm the split with the user before creating anything.** A lane split that mismatches the
code is the one setup error that makes everything downstream collide, and it is cheap to correct
before tickets are assigned and expensive afterwards.

Two properties a good split has, both worth checking explicitly:

- **Every ticket in the sprint falls in exactly one lane.** A ticket in none means the split has a
  hole; a ticket in two means it needs splitting, or the boundary is in the wrong place.
- **The lanes are of comparable size in *tickets*, not in files.** A lane holding one ticket is a
  developer idle for the sprint.

### Lane is a fact about the ticket, not about the session

Lane says which files a ticket touches. That does not change when a session dies, compacts, or is
resumed under another account — which is exactly what makes it safe to store.

The tempting alternative is a field naming the *session* (`Dev-1`, `Dev-2`, an assignee, a label).
Do not add one. A session is the least durable thing in the run, so such a value is wrong the
moment the session ends, and it is wrong in the worst available direction: **a stale claim reads as
coverage.** Nobody picks up a ticket that appears to be handled.

If you inherit a board carrying such a field, retire it rather than deleting it — a field named
`Agent (retired — use Lane)` tells the next reader what happened and why, which an absence does not.

## The branch is the claim

**A ticket is in progress if and only if an open branch or PR references it** (`Refs #N` /
`Closes #N`). Put the ticket number in the branch name so the link is visible without opening
anything.

Nothing else records assignment — not a label, not a title prefix, not a name in a file. The branch
cannot go stale in the way those can: it either exists or it does not, and the forge already renders
the link on the issue.

For the live picture, read the linked pull requests plus `In Progress` versus `In Review`, and
treat *those* as the answer. A board's Status field is a manager's summary of that fact and can lag
it; the branch is the fact.

## The claim is not the work

A branch says what a session has **pushed**. It says nothing about what is sitting uncommitted in
that session's worktree, and that is where work is actually lost.

A branch whose tip is already an ancestor of the base, with zero unique commits, looks from the
outside like a session that did nothing. It can just as easily be a session holding two hundred
uncommitted lines. `git log` cannot tell those apart:

```
git -C path/to/worktree status --porcelain
```

That is the check, and it is the *working tree* rather than the commits. It has found eight
modified files for one ticket in a worktree named for a different one, in a session silent for two
hours, on a branch that looked empty — after a check of the commits had already concluded nothing
was at risk.

So a session that goes quiet gets its working tree looked at, not its branch. And push early,
including work that is half finished: an incomplete pushed branch is recoverable, an unpushed one
disappears with the worktree.

## The developer brief

Every developer starts with the same brief, whether it is spawned as a subagent or is a session you
opened yourself. `/sprint-dev` carries it, which is the point — a brief composed by hand each time
can silently omit a constraint, and the omission is invisible until it costs something.

The brief is: the ticket, its acceptance criteria, the lane and its paths, the worktree path, the
base branch, and every clause below.

- **Stay in lane.** A change wanted outside your paths goes to the manager, not into your branch.
- **One ticket at a time.** Finish or hand back before taking another.
- **Push early**, half-finished included. See *The claim is not the work*.
- **Reproduce before fixing.** A ticket that came out of a review pass may be wrong; a developer who
  cannot reproduce it reports back rather than "fixing" it. Prove a regression test fails without
  the fix, not merely that it passes with it.
- **Rebase on the manager's signal**, not on your own schedule. A build that was running when a
  rebase landed is poisoned — mixed object vintages, a result describing a tree that never existed.
- **Say which gate actually ran.** Not that one did. A gate that could not start and a gate that
  found nothing produce the same silence, and only one of them is good news.
- **Report findings to the manager. Never to the user.** See *Reporting to the manager*.

## Reporting to the manager

Everything a developer discovers routes to the manager: findings, blockers, scope growth,
pre-existing bugs, and disagreements with the ticket. Nothing goes to the user directly.

This is not deference. Work injected outside the lane split starts in files another developer is
holding, and it puts the user in the position of dispatching work they have no way to evaluate —
which is the whole thing the manager/developer split exists to avoid.

**The mechanism is usually not the developer.** Some skills raise a background-task chip on their
own, from inside their own fork, without the developer choosing to raise anything — and they do not
return a handle, so neither the developer nor the manager can withdraw it. Two consequences, and
the first is the one that gets missed:

- **Do not accuse a developer of raising a chip before asking.** It is more often the skill.
- A developer whose skill raised one **says so in its next message and restates the finding in
  full**, so the manager can act on it through the proper channel and tell the user the chip is
  safe to dismiss.

Developers do not call task-spawning tools directly.

Route the channel, not the content. A finding raised the wrong way is still a finding, and a
developer corrected for raising one will stop raising them.

For classifying and routing a problem that is not the one the ticket named, use
`lib/adjacent-problems.md` — its *Classification* and *Routing an adjacent problem* sections. The
manager is the "ask" destination that file refers to.

## Shared resources

Anything every lane touches is serialised by the manager, because a developer cannot see the other
lanes to know when it is safe.

- **Nobody works in the primary checkout.** It is where the manager sits and where uncommitted work
  accumulates. Developers get their own worktrees.
- **A shared service, daemon or cache that every lane's build goes through is not restarted by a
  developer.** A ticket needing one goes back to the manager, who serialises it.
- **The base branch moves under you without you fetching.** Worktrees of one repository share a
  `.git`, so any other session's fetch advances the ref for all of them. Anything you compare
  against the base is compared against a ref another session may have moved seconds ago, and
  nothing in your own shell will have hinted at it.
- **The scratchpad is shared, and nothing about its path says so.** Two sessions wrote a PR body to
  the same generically-named file; the second replaced the first, and a PR carried another
  ticket's description until the session that *lost* the file noticed. Nothing in the process did.
  **Prefix every scratchpad file and directory with the lane that owns it**, and re-stage under a
  prefixed name before reporting a result that a generically-named script produced. A published PR
  body is at least visible; a helper script replaced between staging it and running it reports
  success either way.

## Review gates

Every developer, every PR, **scoped explicitly** as `<base>..<branch>`:

- **At the end of each phase within a PR** — `/simplify`, then `/code-review medium --fix`
- **Before handing the PR to the manager** — `/simplify`, then `/code-review high --fix`

`/simplify` runs first by design. It is quality-only and does not hunt for bugs, so shrinking the
change before the correctness pass means the review examines less code and its findings land on
code that will actually ship, rather than on lines about to be deleted.

**The explicit scope is not optional.** Forked skills run in the primary working directory, so a
bare invocation operates on the wrong tree — and in a run with several worktrees live, the primary
is usually parked on a stale base. A review that silently examined the wrong branch and came back
clean is worse than no review, and a `/simplify` that *edited* the wrong tree is worse still.

Name the branch in the range rather than `HEAD`: `HEAD` resolves against the primary worktree, so a
`<sha>..HEAD` range inverts into a giant revert diff whenever the primary is behind. Branches made
in a linked worktree are visible from the primary one, so naming the branch always works.

## Reading a red check

**A red check's cause matters more than its redness**, and the common tooling collapses the
distinction: `gh pr checks` renders `CANCELLED` and `FAILURE` identically. Ask for the state
explicitly before diagnosing anything:

```
gh pr checks <n> --json name,state
```

Label-driven gates are where this bites, because applying several labels at once fires several
events and a concurrency group cancels the earlier runs. Red *immediately after* a multi-label edit
is usually self-inflicted and already being cleared by a queued run — **wait**, because firing
another event cancels the survivor and starts the cycle over. Red on a PR whose labels have been
stable for minutes, with nothing queued, is genuinely stuck and needs one fresh event.

Do not re-run the whole workflow to clear it; that races the concurrency group and makes it worse.

The general shape, which outlives any particular CI: **when an instrument renders two states
identically, get the state from somewhere else before acting on the rendering.**

## Merging

Merging is the manager's, and it is the only place `Done` is decided. **A ticket is Done when the
PR that closes it has merged with CI green.** Nothing is Done on the strength of a branch, a local
test run, or a review.

Auto-merge alone never makes a branch up to date — enable it, then bring every branch reporting
`BEHIND` up to the base:

```
gh pr merge <n> --merge --auto
gh pr update-branch --rebase <n>
```

Before sequencing two PRs that touch the same file, read `lib/git-safety.md` §*Sequencing two PRs
that touch the same file*. Two branches can be pairwise clean and serially conflicting, and every
check anybody runs by reflex answers the pairwise question.

The manager also rejects at merge review: a PR that changes observable behaviour and touches no
documentation, and a PR that claims something the code does not do.

## Bug intake

A developer finding a defect outside its ticket either **fixes it inline** — trivial *and* in-lane,
both clauses — or **reports it to the manager** with file:line and a failure scenario. The manager
files the issue and schedules it.

Nothing is silently deferred and nothing is silently widened. Those are the two failure directions,
and a run that avoids only one of them still loses work.
