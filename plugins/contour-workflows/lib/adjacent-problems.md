# Adjacent problems

Shared policy for the skills that find real problems outside the work they were asked to do —
`/work-issue`, `/fix-ci`, and `/address-review` act on it; `/cpp-review`, `/review-branch`,
`/sanitize` and `/rebase` use its *Classification* vocabulary so their findings arrive ready to
triage — they diagnose and report but do not commit, so routing is the caller's job.
Each of those skills reads this file and cites the sections it needs by heading; none of them
restate the rules. Changes here apply to all of them, which is the point: without a shared answer,
every skill invents its own version of "note it and move on" and they drift.

This is a reference document, not a skill. It has no frontmatter and is never invoked directly.

## Why this exists

Real work turns up problems nobody asked about: a lifetime bug two lines from the one you came to
fix, a review finding in untouched code, a CI job that was already red before this branch existed.
Both reflexes are wrong. Fixing it silently buries an unrelated change in a commit that claims to
be about something else, and a reviewer who cannot see it cannot judge it. Noting it and walking
past throws away the most expensive part — you are already in the code, with the context loaded,
and that context is gone tomorrow.

So neither reflex: classify it, size it, and route it.

## Classification

Every finding is exactly one of:

- **In-scope** — what this work is *for*. Just do it.
- **Adjacent** — real, outside the remit, and the work can be completed and verified without it.
  This is what the rest of this document is about.
- **Blocker** — the work cannot be done, or cannot be *verified*, without addressing it first. A
  blocker is not adjacent and does not get deferred: say what it is and stop. A test you cannot
  trust is the common case — if the suite was already failing on the base branch, "my tests pass"
  means nothing until you know which failures are yours.

Two further distinctions matter before triage:

- **Pre-existing vs. introduced.** Compare against the base branch rather than assuming
  (`git diff origin/<base>..HEAD -- <file>`, or run the same check on the base). A problem your
  change *introduced* is in-scope no matter how unrelated it feels.
- **Pre-existing vs. infrastructure.** A flaky test, a CI timeout, a network blip, or a runner
  running out of memory is not a code problem. It has nothing to fix, nothing to file a useful
  ticket about, and nothing to branch off for. It never enters triage — report it as
  infrastructure and leave it alone.

## Sizing an adjacent problem

Small means all of:

- a few lines, in code this work already touches;
- no design decision — the correct fix is obvious and uncontested;
- no new API, no new dependency, no change to a public interface;
- testable with an obvious case, or not observable at all.

Anything else is not small. When it is genuinely borderline, treat it as not small — the cost of
asking is one message, and the cost of a surprise refactor inside someone else's branch is a
re-review.

## Routing an adjacent problem

A skill that does not commit cannot route. If you have no commit step of your own — you are
diagnosing or reviewing, not landing changes — stop after *Classification*: report the finding as
adjacent, with the evidence, and leave the routing to whoever is committing. Improvising a commit
procedure is exactly what this file exists to prevent.

**Small → fix it now, in its own commit.** Separate from the commits belonging to the primary
work, so it reviews on its own terms and reverts without taking the real change with it. Give it
its own test where the behavior is observable, and its own commit message saying what it is and
why it was in the way. Then say so in the report.

**Not small, or it carries a design decision → ask.** Present it with `file:line`, what fixing it
would take, and why it does not fit inside this branch. Then follow the answer:

- **Address it now anyway.** The user may want it done while the context is loaded. Still separate
  commits — the reason for separating never went away.
- **File a ticket.** `gh issue create` or `glab issue create`, carrying enough evidence to be
  actionable by someone who was not here: the location, what is wrong, how to observe it, and why
  it was deferred. A ticket that just says "clean up `Foo::bar`" is worse than nothing. Link it
  from the issue or PR the current work belongs to.
- **Start it in parallel.** When the problem is genuinely independent of this branch — different
  files, no shared design decision — a separate worktree lets it proceed without blocking or
  entangling the current work:
  ```
  git worktree add ../<repo>-<slug> -b <branch> origin/<base>
  ```
  Suggest it and explain why it is independent. Do not create it unasked: it puts a second
  checkout on the user's disk and a second branch in their repository.

## Guards

- **The primary work stays the priority.** An adjacent fix never delays it, never blocks it, and
  never grows it. If the detour is becoming the job, stop and say so.
- **Never fold an adjacent fix into a commit belonging to the primary work.** If it cannot stand as
  its own commit, it is not separable enough to be doing here.
- **Never let a triage decision go unrecorded.** Every one reaches the report — fixed in which
  commit, filed as which ticket, suggested as which worktree, or declined and why. A decision
  nobody can see is indistinguishable from an oversight.
- **Never route around a blocker.** Deferring something the work depends on produces a branch that
  looks finished and is not.
