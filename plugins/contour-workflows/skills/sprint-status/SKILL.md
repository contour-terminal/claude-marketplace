---
name: sprint-status
description: Report where a sprint stands — progress by phase, which lane holds what, what is blocked and on what, where the board disagrees with the branches, and whether a quiet lane is sitting on unpushed work. Read-only unless asked to refresh the tracking issue's dated snapshot. Use to ask "where are we", to hand a sprint over to another session, or before deciding what to work on next.
argument-hint: "[board-number-or-url | milestone] [--snapshot]"
allowed-tools: Bash(gh:*), Bash(git:*), Read, Grep, Glob
---

# Sprint Status

Answer "where are we" from the facts rather than from the board's own summary of them, and say
where the two disagree.

Read-only by default. `--snapshot` additionally refreshes the tracking issue, which is the one
thing here that writes.

The failure this skill is built against is a reporting failure, not a data one. **Skipped, absent,
unstarted and failed are four states, and every convenient summary collapses them.** "25 of 26
green" is arithmetic that is true and useless; *absence of the negative is not the positive* — no
blocked items is not the same as every item having a lane, and no failing lane is not the same as
every lane reporting. Where a state cannot be determined, that is its own outcome and gets said,
not rounded to the nearest neighbour.

`$ARGUMENTS` names the board or milestone; with no argument, find it.

This is a snapshot. For how the sprint is *trending* — throughput over time, where the time goes,
what is aging — use `/sprint-performance`.

## Context

- Repository: !`gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "(unknown)"`
- Worktrees: !`git worktree list 2>/dev/null`
- Open PRs: !`gh pr list --state open --json number,title,headRefName 2>/dev/null || echo "(none readable)"`

## Step 1 — Load the shared policy

`${CLAUDE_PLUGIN_ROOT}/lib/sprint-board.md` for the field schema and what each value means, and
`${CLAUDE_PLUGIN_ROOT}/lib/team-protocol.md` §*The branch is the claim* and §*The claim is not the
work* for why the report is assembled the way it is. Cite by heading; do not restate.

## Step 2 — Gather

Three sources, and the report needs all three because each one alone is misleading:

```bash
gh project item-list <n> --owner <owner> --limit 200 --format json
gh pr list --state all --limit 100 --json number,title,headRefName,state,mergedAt,body
git worktree list --porcelain
```

Custom fields come back from `item-list` as lowercase keys — `lane`, `phase`, `order`,
`blocked by`, and `linked pull requests`.

That last one is present but **incomplete, in exactly the case you are asking about**. It is
populated only once a PR exists and is linked to the issue, so a ticket someone is actively working
— a branch pushed, no PR yet — comes back with nothing there, and reads identically to a ticket
nobody has touched. Measured on a live board: 58 of 173 items carried a linked PR, and one of the
three items in flight was not among them. It also carries only URLs, not whether the PR is open,
merged, or green.

So `gh pr list` is not optional. Cross-reference both, and treat the branches as the fact.

In milestone mode, `gh issue list --milestone` replaces the first and the tracking issue carries
the order. Say which mode you are reporting from — the two are different products.

## Step 3 — Report

Six sections, in this order. Lead with the number the user actually wants.

**Progress.** A per-phase table — Blocked / Todo / In Progress / In Review / Done / Total — and one
headline fraction over the *sequenced* items. Not over the backlog: a fraction that moves when
somebody files a ticket measures filing, not progress. Say how it compares to the last snapshot if
there is one.

**Who has what.** Per lane, the ticket in flight and its PR. Derived from branches and PRs, not
from a field. A lane with nothing in flight is **idle**, and that is a finding — it means the
manager owes it a dispatch.

**Blocked, and on what.** Each blocked item with its blocker, and whether the blocker has since
merged. A blocker that merged and left its dependent `Blocked` is the most common piece of stale
board state there is.

**Where the board disagrees with the branches.** Every item whose `Status` does not match what the
PRs say it should be. This is the section that makes the report worth running rather than reading
the board directly. If there are none, say so explicitly — "checked, none" and "did not check" must
not read the same.

**Quiet lanes.** For every live worktree, `git -C <path> status --porcelain`. A branch with no
unique commits is indistinguishable from a session holding two hundred uncommitted lines, and only
the working tree can tell them apart. Report per lane as one of:

| State | Meaning |
|---|---|
| working | Commits and a clean tree, or recent pushes |
| quiet, pushed | No recent activity, nothing uncommitted — safe |
| **quiet, holding work** | Uncommitted changes in the worktree — **at risk, name the files** |
| finished | PR merged, worktree can go |
| unknown | The worktree path could not be read — say so rather than assuming clean |

**Unsequenced and untriaged.** Items with no lane (nobody will pick them up, and they are invisible
in every lane-grouped view) and items with no `Order`.

## Step 4 — Snapshot, only if asked

With `--snapshot`, refresh the tracking issue per `lib/sprint-board.md` §*The tracking-issue
mirror*. It keeps its shape: the board is authoritative and the snapshot is **dated**, plus what
closed since the last one and the open questions stated honestly — what is unproven, what is
deferred by decision rather than oversight, and where the risk sits.

An undated mirror is indistinguishable from a second source of truth and will be read as one.

## Rules

- **NEVER derive "who has what" from a board field.** The branch is the claim.
- **NEVER report a quiet lane as fine without reading its working tree.**
- **NEVER collapse skipped, absent, unstarted and failed into one count.**
- **NEVER let "checked, found none" and "did not check" render identically.**
- **NEVER write anything without `--snapshot`.** This is a read.
- **ALWAYS say which mode the report came from**, board or milestone.
- **ALWAYS name the files** when a lane is holding uncommitted work. That is the finding, not the
  fact that it is quiet.
