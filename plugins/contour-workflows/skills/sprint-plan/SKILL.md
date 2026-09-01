---
name: sprint-plan
description: Set up a sprint that several Claude sessions work in parallel — turn a goal, a milestone, a tracking issue or a pile of issues into a project board with lanes, phases and an explicit order, so a manager session can drive two or three developer sessions without their branches colliding. Use when starting a sprint, planning out a milestone, or splitting one large piece of work across parallel sessions. Run it again to re-sequence or extend a board that already exists.
argument-hint: "[goal | milestone | tracking-issue | issue-list]"
allowed-tools: Bash(gh:*), Bash(git:*), Bash(bash:*), Read, Grep, Glob, Agent, AskUserQuestion
---

# Plan a Sprint

Build the thing a manager session and two or three developer sessions can actually run against: a
board that says what the work is, what order it goes in, and which component each piece belongs to.

The board is not bookkeeping. It is the **only** durable state in a parallel run — sessions die,
compact, and get resumed under other accounts, and everything they knew goes with them. What
survives is what is written down somewhere both a fresh session and a human can read.

Two failures shape this whole skill, and both are cheap now and expensive later:

- **A lane split that mismatches the code** is what makes three branches collide. It is confirmed
  with the user before anything is created, never inferred and applied silently.
- **An order that is a wish rather than a dependency graph** produces a board where the top item
  cannot be started. Order is dependencies first, then what actually blocks the goal.

`$ARGUMENTS` names what to plan: a goal in prose, a milestone, a tracking issue, or a list of issue
numbers. With no argument, ask what the sprint is.

## Context

- Repository: !`git remote get-url origin 2>/dev/null || echo "(no origin remote)"`
- Default branch: !`git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "(unknown — run: git remote set-head origin -a)"`
- Token scopes: !`gh auth status 2>&1 | grep -i 'scopes' || echo "(gh not authenticated)"`
- Open issues: !`gh issue list --limit 5 --state open 2>/dev/null || echo "(none readable)"`

## Phase 0 — Setup

### Step 0.0 — Load the shared policy

Read both, and cite their sections by heading rather than restating them:

- `${CLAUDE_PLUGIN_ROOT}/lib/sprint-board.md` — the field schema, the views, the board README, the
  ticket format, and the milestone fallback.
- `${CLAUDE_PLUGIN_ROOT}/lib/team-protocol.md` — §*Lanes* for how a split is derived and what makes
  one good.

### Step 0.1 — Resolve the owner, and decide the mode

The board's owner is the repository's owner — an organization for an org repo, the user otherwise:

```bash
gh repo view --json owner,name,nameWithOwner
```

Then establish which mode this run is in. **Board mode and milestone mode are different products,
and a silent downgrade to the second reads as a working board**, so decide it explicitly and say
which you got:

- The token needs `project` scope. If `gh auth status` does not list it, that is **not** "no board
  found" — report it as a scope problem and give the remedy: `gh auth refresh -s project`.
- Ask whether to adopt an existing board (`gh project list --owner <owner>`) or create one.
- Only if the user declines the scope, or the forge has no projects, fall back to milestone mode
  (`lib/sprint-board.md` §*Milestone fallback*).

## Phase 1 — The work

### Step 1.1 — Collect the items

Where they come from depends on `$ARGUMENTS`:

| Argument | Where the items come from |
|---|---|
| A milestone | `gh issue list --milestone "<name>" --state all --limit 200` |
| A tracking issue | The issue body plus every issue it links |
| Issue numbers | Those issues, plus anything they say they are blocked on |
| A goal in prose | You produce them — see below |
| One big ticket | Decompose it; each phase of the decomposition becomes a ticket |

For a goal or a big ticket, spawn parallel `Explore` agents over the areas the goal touches and
turn what they find into candidate tickets. Do not skip the read: a sprint planned from the goal
statement alone produces tickets that describe intentions rather than defects, and a developer
cannot close one on evidence.

### Step 1.2 — Write each item in the ticket format

`lib/sprint-board.md` §*Ticket format*. The clause that matters most and gets dropped most is
**Acceptance** — an explicit statement of what must be observably true. It is the handoff to a
developer and the evidence the manager closes on; without it a ticket can only be closed by
opinion.

File new items as real issues (`gh issue create`), with whatever label taxonomy the repository
already uses. Do not invent one for the sprint, and do check whether a label gates a required
check — where one does, the sprint's issues need it as much as anything else.

Existing issues are used as they are. Do not rewrite someone's issue to fit a format; if it lacks
an acceptance clause, add one as a comment and say why.

## Phase 2 — The lanes

### Step 2.1 — Derive candidates

Read a split off what the repository already asserts about itself, in the order given in
`lib/team-protocol.md` §*Lanes*: `CODEOWNERS`, then existing area-style labels, then the top-level
source directories weighted by where the sprint's tickets actually land.

Then check the two properties that file names — every ticket in exactly one lane, and lanes of
comparable size **in tickets**. Report both checks. A ticket in no lane means the split has a hole;
a ticket in two means it needs splitting or the boundary is wrong.

### Step 2.2 — Confirm before creating anything

Present the proposed lanes with their paths and their ticket counts, and get agreement. Use
`AskUserQuestion` where there is a real choice between two defensible splits.

This is the one step not to skip for speed. Correcting a lane split costs a conversation now and a
round of cross-lane rebases later.

## Phase 3 — Phases and order

**Phases** are ordered partitions of the goal, named for *what becomes true when each completes* —
not for a date or a number. Add `Deferred` (sequenced but held behind something unscheduled) and
`Backlog` (real work, not yet sequenced); keeping those apart is what stops a backlog from reading
like a plan.

**Order** is one integer per sequenced item across the whole sprint. Dependencies first, then what
actually blocks the goal. Record what each item is blocked on as you go — it is the justification
for the number, and `Blocked by` is where it lives.

Sanity-check the result by reading it back as a sentence: *"nothing above line N can start until
line N lands"*. If that is false anywhere, the order is decorative.

## Phase 4 — Create the board

Create or adopt the project, then run the setup script. It is idempotent — it reads what exists and
creates only what is missing, so it is also the way to extend a board later:

```bash
gh project create --owner "<owner>" --title "<sprint title>" --format json

bash "${CLAUDE_PLUGIN_ROOT}/skills/sprint-plan/board-setup.sh" \
  --owner "<owner>" --number <n> \
  --lanes  "L <name>,N <name>,D <name>,manager" \
  --phases "<phase 1>,<phase 2>,Deferred,Backlog" \
  --current-phase "<phase 1>"
```

Then add the items and set their fields. `gh project item-edit` takes one field per invocation and
does not need node ids:

```bash
gh project item-add <n> --owner "<owner>" --url <issue-url>
gh project item-edit <n> --owner "<owner>" --url <issue-url> --field "Lane"  --value "L <name>"
gh project item-edit <n> --owner "<owner>" --url <issue-url> --field "Order" --number 7
```

**Two things the API cannot do**, and they must be reported rather than quietly left undone:
grouping and sorting a view. Tell the user to group view 1 by `Phase`, group view 2 by `Lane`, and
sort views 3 and 6 by `Order` — the script prints this too. A board reported as complete while its
main view is ungrouped is a board the user will find broken.

## Phase 5 — Make the board self-explaining

### Step 5.1 — The board README

Write it from `lib/sprint-board.md` §*The board README*, and set it:

```bash
gh project edit <n> --owner "<owner>" --readme "$(cat <readme-file>)"
```

This is what lets a session that has never seen the sprint act on it without asking. Keep board
*state* out of it beyond the single progress fraction — the fields carry state, and prose restating
them goes stale on the next merge.

### Step 5.2 — The tracking issue

Open the mirror described in `lib/sprint-board.md` §*The tracking-issue mirror*. It exists because
reading a board needs `project` scope and a CI job or a `repo`-scope session does not have it.

It says in its own first lines that the board is authoritative and that **if the two disagree the
board is right** — except in milestone mode, where that sentence is false and the issue really is
the order. Get this the right way round; it is the difference between a mirror and a second queue.

## Phase 6 — Report

State, in this order:

- Which mode: board or milestone. Never leave this implied.
- The board URL, and the scope needed to read it.
- The lanes, with paths and ticket counts.
- The phases, and how many items are sequenced versus in the backlog.
- **What was left undone** — view grouping and sorting, any item you could not classify, any ticket
  still lacking an acceptance clause.

Then say what starts the run: `/sprint-run` in the manager session, and `/sprint-dev <issue>` in
each developer session or subagent.

## Rules

- **NEVER create a lane split without confirming it.** It is the one setup error that makes
  everything downstream collide.
- **NEVER report a milestone-mode setup as a board.** They behave differently and the user must
  know which they have.
- **NEVER report a missing `project` scope as a missing board.** Different problem, different
  remedy, and the API failure reads the same for both.
- **NEVER add a field naming a session** — an assignee-like `Dev-1`/`Dev-2`. Lane says which files;
  the linked PR says who. See `lib/team-protocol.md` §*Lane is a fact about the ticket*.
- **NEVER file a ticket with no acceptance clause.** It cannot be closed on evidence.
- **ALWAYS report the steps the API could not perform**, rather than a setup that is silently
  partial.
- **ALWAYS re-run the setup script** to extend a board rather than editing its schema by hand.
