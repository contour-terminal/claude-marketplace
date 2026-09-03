# The sprint board

Shared policy for the board that carries a multi-session sprint — its fields, its views, what it
must say about itself, and how it degrades when the tooling is not available. `/sprint-plan`
creates and seeds it; `/sprint-run` and `/sprint-status` read and update it. Each cites the
sections it needs by heading.

The board is **authoritative for state and order**. That is a decision with a cost — reading it
needs a token scope that a CI job and some sessions do not have — and *The tracking-issue mirror*
below is how that cost is paid without creating a second queue.

This is a reference document, not a skill. It has no frontmatter and is never invoked directly.

## Field schema

Six fields beyond the built-ins. Every one of them answers a question the manager asks out loud
during a run; a field that answers no such question is a field that goes stale.

| Field | Type | Options / meaning |
|---|---|---|
| `Status` | single-select | `Blocked` · `Todo` · `In Progress` · `In Review` · `Done` |
| `Lane` | single-select | One option per lane, prefixed so it sorts: `L <name>`, `N <name>`, `D <name>`, plus `manager` |
| `Phase` | single-select | The sprint's ordered partitions, plus `Deferred` and `Backlog` |
| `Priority` | single-select | `Critical` · `High` · `Medium` · `Low` |
| `Order` | number | The global sequence. Dependencies first, then what actually blocks the goal |
| `Blocked by` | text | What a `Blocked` item is waiting on |

Three things about this schema are load-bearing rather than cosmetic.

**`Status` distinguishes `In Progress` from `In Review`.** Those are different questions for the
manager — one needs watching, the other needs merging — and a three-state Status forces them
together.

**`Priority` is left empty for normal work.** It marks the exceptions. A board where every item
carries a priority has a field that discriminates nothing; on a real board of 172 items, 89 of them
carried none and that is the healthy shape.

**There is no field naming the session.** See `lib/team-protocol.md` §*Lane is a fact about the
ticket, not about the session*. `Lane` says which files; the linked PR says who. A field naming a
session goes stale silently, and a stale claim reads as coverage.

`Phase` is what makes a large sprint legible. Phases are *ordered partitions of the goal*, named
for what becomes true when each completes — "the fleet dispatches at all", "no wrong answer served"
— not for a date or a sprint number. `Deferred` means sequenced but held behind a dependency that
is not itself scheduled; `Backlog` means real work, not yet sequenced. Keeping those two apart is
what stops a backlog from reading like a plan.

## Views

Seven views, each the standing form of one question the manager asks. Their filters:

| View | Layout | Filter |
|---|---|---|
| `1 — Progress through the plan` | board, grouped by `Phase` | `-phase:"Backlog"` |
| `2 — Who has what` | table, grouped by `Lane` | `-status:Done` |
| `3 — Up next, in Order` | table, sorted by `Order` | `-status:Done,Blocked` |
| `4 — Blocked, and on what` | table | `status:Blocked` |
| `5 — Needs triage (no lane yet)` | table | `no:lane` |
| `6 — <the current phase>` | table, sorted by `Order` | `phase:"<name>"` |
| `7 — Shipped` | board | `status:Done` |

Number the names. The forge orders views by creation, so a name that does not sort is a set of tabs
that reshuffle as you add one.

View 5 is the one that earns its place least obviously and is worth keeping: an item with no lane
is an item **nobody will pick up**, and it is invisible in every other view precisely because those
are grouped or filtered by the field it lacks.

View 6 is re-pointed at the current phase as the sprint advances, rather than accumulating one view
per phase.

## Board mechanics

The tooling is uneven here and the gaps are not documented in the obvious place. These are measured
against `gh` 2.98.0 and the current GraphQL schema.

**Fields** are creatable with `gh project field-create --data-type SINGLE_SELECT
--single-select-options "a,b,c"`. It is **not idempotent** — a repeat fails with *"Name has already
been taken"* — so read `gh project field-list` first and create only what is missing.

**The built-in `Status` field cannot be created, only amended.** A new project ships with
`Todo`/`In Progress`/`Done`, and the two extra options go on with `updateProjectV2Field`. Send the
**full** option list, and re-send each existing option **with its `id`**, or the existing ones are
replaced rather than kept and every item's Status value goes with them:

```
gh api graphql -f query='
mutation($f:ID!){ updateProjectV2Field(input:{fieldId:$f, singleSelectOptions:[
  {name:"Blocked", color:RED, description:"Waiting on something outside this ticket"},
  {id:"<existing>", name:"Todo", color:GREEN, description:"Sequenced, not started"},
  ...
]}){ projectV2Field { ... on ProjectV2SingleSelectField { options { id name } } } } }' -F f="$FIELD_ID"
```

`name`, `color` and `description` are all required on every option, including the ones you are
merely preserving.

**Views cannot be made with `gh project` at all** — there is no `view-create` subcommand. They take
two GraphQL mutations each, because `createProjectV2View` accepts no filter and
`updateProjectV2View` is where the filter goes:

```
createProjectV2View(input:{projectId:$p, name:$n, layout:TABLE_LAYOUT}){ projectV2View { id } }
updateProjectV2View(input:{viewId:$v, filter:"-status:Done,Blocked"}){ projectV2View { filter } }
```

**Setting a field on an item** does not need node ids: `gh project item-edit <n> --owner <o> --url
<issue-url> --field "Status" --value "In Progress"`. One field per invocation.

**A whole board can be cloned** with `gh project copy --source-owner … --target-owner …`, which
carries fields and views. Where a house board already exists, marking it a template and copying it
is more reliable than rebuilding the schema, and much faster.

## The board README

The board's description field is not decoration. It is what lets a session that has never seen this
sprint act on it without asking, and writing it is part of creating the board.

It states, in this order:

1. **What this is** — the goal in two sentences, and what put the items on it.
2. **The ordering rule** — *why* `Order` is the sequence it is. "Dependencies first, then what
   actually blocks the goal" is a rule a session can apply to a new ticket; a bare number is not.
3. **The phases**, each with what becomes true when it completes, and any hard sequencing inside
   one.
4. **Progress**, as a fraction of the sequenced items — not of the backlog, which would make the
   number move when somebody files a ticket.
5. **What "done" means** — the closing PR merged with CI green. Nothing on the strength of a
   branch.
6. **Who is working on what** — that it is `Lane`, that lanes are component ownership, and that the
   live claim is the linked PR. If session-to-lane names are recorded at all, they are recorded
   *here*, in one place, and nowhere per-item.
7. **A pointer to the protocol** — `lib/team-protocol.md`, or the project's own copy of it.

Keep board *state* out of it beyond the single progress fraction. The fields carry state; prose
restating them goes stale on the next merge, which is the failure the board exists to fix.

## What the board cannot tell you about time

The board holds the **current** value of every field and no record of when it got there. There is no
field-history API reachable through `gh project`, so **no question of the form "how long has this
been In Progress" has an answer from the board.** Anything shaped like one is reconstructed from
issue, commit and PR timestamps — which measure different moments, and miss some entirely.

Two absences are worth naming, because both look like data:

- **`Blocked by` carries no timestamp.** How long an item has been blocked is recorded nowhere.
  `updatedAt` is not a substitute; it moves for a label change.
- **A `Status` set by hand leaves no trace of the value it replaced.** Reconciling it against the
  branches corrects the present and recovers no past.

This is what makes the dated snapshot below more than a convenience. A run of dated snapshots is the
only durable status history this system has, so the one written today is what makes next week's
"blocked for how long" answerable at all. A sprint that never took one has no history to report,
only a present.

`/sprint-performance` reconstructs what it can from timestamps and names what it could not determine
rather than rounding it to the nearest neighbour.

## The tracking-issue mirror

Reading a project board needs a token with `project` scope. A `repo`-scope session, a CI job, or a
contributor without it is otherwise locked out of the plan for the work it is doing — so the sprint
also gets **one tracking issue** in the repository.

It is a mirror, not a queue, and it says so in its own first lines: the board is authoritative, and
**if the two disagree the board is right**. It carries:

- The board's URL and the scope needed to read it.
- A **dated** snapshot — a per-phase table of counts, and the sequenced queue in `Order`.
- What closed since the previous snapshot, with one line each on what was actually wrong.
- **Open questions, honestly stated.** What is unproven, what is deferred by decision rather than
  by oversight, and where the remaining risk sits. This is the section that makes the issue worth
  reading rather than worth regenerating.

The date is the load-bearing part. An undated mirror is indistinguishable from a second source of
truth, and will be read as one.

The dated snapshot is also the only status history the board keeps — see §*What the board cannot
tell you about time* above.

## Ticket format

The title is a **problem statement**, not an imperative. *"A node cannot reload its configuration,
and a reload that drops unreloadable fields silently would be worse"* survives being read a month
later by someone deciding whether it still matters; *"Add config reload"* does not, because it
asserts the solution and hides the reason.

The body carries:

- What breaks, and **how you know** — the test, the measurement, or the failure. Most defects worth
  a sprint are silent, and an issue describing only the rule and not its consequence is one the
  next reader will argue away, usually correctly.
- The constraint that makes the naive fix wrong, where there is one.
- **Acceptance** — an explicit clause naming what must be observably true. This is the handoff to a
  developer and the evidence the manager closes on. A ticket without it cannot be closed by
  anything but opinion.
- Its `Phase`, and what it is blocked on.

Labels follow whatever taxonomy the repository already has; do not invent one for the sprint. Where
a `type/`-style label gates a check, the sprint's tickets need it as much as any other.

## Milestone fallback

Not every repository has a project board, and not every token can read one. Detect this and
**degrade rather than fail** — and tell the user which mode is in use, because the two behave
differently and a silent downgrade is read as a working board.

The distinction that matters: **no board** and **no `project` scope** are different states with
different remedies, and the API failure looks similar. A scope failure is fixed by
`gh auth refresh -s project` and should say so; reporting it as "no board found" sends the user to
create one they may already have.

In milestone mode:

- A **milestone** replaces the board and holds the sprint's items.
- `Lane`, `Phase` and `Priority` become **labels** (`lane/*`, `phase/*`, and whatever priority
  labels exist).
- `Order` has no home — GitHub milestones cannot carry one — so **the tracking issue becomes
  authoritative for order**, and it stops being a mirror. Say so in it, in place of the "the board
  is right" line, which is false here.
- `Status` is derived rather than stored: open with no linked PR is `Todo`, open with a branch is
  `In Progress`, open with a PR is `In Review`, closed is `Done`, and a `blocked` label is
  `Blocked`.

That derivation is worth noting for the board case too. It is where the board's Status field is
*supposed* to come from, which is why `/sprint-run` can reconcile a stale Status against the linked
PRs rather than trusting it.
