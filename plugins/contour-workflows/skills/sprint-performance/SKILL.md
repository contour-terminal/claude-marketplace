---
name: sprint-performance
description: Report how a sprint is performing over time rather than where it stands — throughput per day and per week, a burnup that shows scope changes instead of hiding them, cycle time split into queue/build/review with medians and p90, aging work in progress, blocked items, integrity checks, and a forecast range rather than a date. Reconstructs the history the board does not store, from issue, commit and PR timestamps, and names what it could not determine. Renders as terminal tables and as a charted report for Claude Desktop. Read-only — writes nothing to the board, the issues or the repository. Use to ask whether a sprint is speeding up or slowing down, to find which stage is slow, or to run a retrospective. Measures components, never people.
argument-hint: "[board-number-or-url | milestone] [--since YYYY-MM-DD] [--ascii] [--no-publish]"
allowed-tools: Bash(gh:*), Bash(git:*), Bash(bash:*), Bash(date:*), Read, Grep, Glob, Artifact
---

# Sprint Performance

Answer "are we speeding up or slowing down, and which stage is slow" — from timestamps that
actually exist, over a window that is named rather than assumed.

`/sprint-status` is a snapshot; this is a derivative. A count cannot tell a sprint that closed nine
tickets last week and one this week from a sprint that closed one last week and nine this one, and
those are opposite situations. Run both: neither substitutes for the other.

Read-only. It writes nothing to the board, the issues or the repository — the only thing it
produces is a report.

Three failures shape it.

**A denominator failure.** Every number here is a rate, a rate is a ratio over a window, and a
window chosen by an unstated rule is a number with an unstated denominator that will be believed
anyway. So day 0 is named, along with the rung it came from and what it would have been one rung up.

**Reconstruction passing for record.** The board stores the current value of every field and no
history — see `lib/sprint-board.md` §*What the board cannot tell you about time*. Everything here is
rebuilt from issue, commit and PR timestamps, which means some states are simply **invisible**, and
those get their own section rather than being rounded to the nearest neighbour.

**A report that becomes a performance review.** Lanes are components, not people. A slow lane is a
slow *component* — its tickets sit in review, its dependencies land late. `gather.sh` collects no
author, no assignee and no merged-by anywhere in its schema, so there is nothing here to break down
by person. That is the guardrail implemented rather than asserted, and it stays that way.

`$ARGUMENTS` names the board or milestone and the switches; with no argument, find the board.

## Context

- Repository: !`gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "(unknown)"`
- Now (UTC): !`date -u +%Y-%m-%dT%H:%M:%SZ`
- Token scopes: !`gh auth status 2>&1 | grep -i scopes || echo "(gh not authenticated)"`
- Default branch: !`git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "(unknown — run: git remote set-head origin -a)"`
- awk: !`awk --version 2>&1 | head -1`

The `awk` line earns its place: every number is computed in awk under POSIX constraints, so which
flavour is present is the first thing to check when the output looks wrong.

## Step 1 — Load the shared policy

`${CLAUDE_PLUGIN_ROOT}/lib/sprint-board.md` for §*Field schema*, §*Milestone fallback* and
§*What the board cannot tell you about time*; `${CLAUDE_PLUGIN_ROOT}/lib/team-protocol.md` for
§*Lane is a fact about the ticket, not about the session* and §*The branch is the claim*. Cite them
by heading; do not restate them.

## Step 2 — Fix the window

`gather.sh` resolves day 0 by a ladder and reports which rung it used. Read the `M day0_*` records
it emits and **say the rung out loud in the report**:

| Rung | Source | Why it is here |
|---|---|---|
| R0 | `--since YYYY-MM-DD` | A human knows when the sprint was declared. Always wins |
| R1 | Board or milestone `createdAt` | The declaration date. Exists even when nothing is done yet |
| R2 | Earliest non-archived `ProjectV2Item.createdAt` | When tickets were sequenced. Survives a **reused** board, which R1 does not |
| R3 | Earliest issue `createdAt` | Available in milestone mode, where R2 has no home |
| R4 | Earliest commit `authoredDate` across **all** tickets | The commit-derived rule, without the survivorship bias |
| R5 | No basis | Window undetermined; say so rather than inventing one |

The obvious rule — *the first commit of the oldest ticket marked done* — is the right instinct
pointed at the wrong sample, and it sits at R4 with its restriction removed rather than at the top.
It looks only at **done** tickets, but the ticket that started earliest is very often the hard one
still open, so it picks a day 0 that is too late and inflates every rate that divides by the window.
It is undefined in the first week, which is exactly when the question gets asked. And dropping the
restriction uses strictly more data for a strictly better answer, so the restriction only removes
evidence.

Two traps `gather.sh` handles, both of which must reach the report rather than being silently
absorbed:

- **A commit that predates day 0 by more than a fortnight** is not used to set the window. A rebased
  or cherry-picked branch keeps its original author date, and one such ticket would stretch every
  denominator with no visible symptom.
- **A board reused for a second sprint** carries the first sprint's date, which halves every rate
  invisibly. If the board predates its own earliest item by more than the span of the additions,
  day 0 falls to R2 and says why.

Report **declared → first commit** as its own figure. It is often the largest single interval in the
whole report, and burying it inside "elapsed days" is how a planning problem gets read as a delivery
problem.

## Step 3 — Gather

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/sprint-performance/gather.sh" \
  --owner "<owner>" --number <n> --repo "<owner/name>" > "$TMPDIR/sprint.tsv"
```

Milestone mode is `--milestone "<title>" --repo "<owner/name>"`. `--self-check` probes gh, the
token scopes and the default branch without fetching anything, which is the fastest way to tell the
three failures apart. **Say which mode the report came from** — board and milestone are different
products and a silent downgrade reads as a working board.

Four sources, because each alone is misleading. The board over GraphQL, not `gh project item-list`
— `item-list` cannot return `ProjectV2Item.createdAt`, and that timestamp is the only record of when
an item joined the sprint, which is what separates scope growth from a slow team. Pull requests with
their `commits`, joined to tickets through `closingIssuesReferences`, which is the only link GitHub
actually asserts. Branches with no PR yet, from `git` — per §*The branch is the claim* a pushed
branch **is** work in flight, and it is invisible to `gh pr list` entirely, so without it a ticket
somebody is actively working reads exactly like one nobody has touched. And `stateReason`, twice
over: `REOPENED` is the reopened check without a timeline query, and `NOT_PLANNED` is excluded from
throughput, because counting a won't-do closure as delivery is the cheapest way to make a stalling
sprint look healthy.

If `gather.sh` records an `M unknown` line, that line belongs in the report. It is the gatherer's own
record of what it could not see, and it is worth more than a clean-looking number.

## Step 4 — Compute

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/sprint-performance/metrics.sh" \
  --format text --now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TMPDIR/sprint.tsv"
```

**Show the output as-is; do not reformat it or recompute the numbers by hand.** This is the `/sloc`
rule and it binds harder here: a model eyeballing a p90 over fourteen samples gets it wrong, and the
wrongness is plausible, which is the worst kind. Add `--ascii` where the terminal cannot render
block glyphs — a legacy Windows console has `█` and `░` but not `▁▂▃▄▅▆▇`, so the sparklines are the
only thing that breaks and `--ascii` is the fix.

What you add is what a script cannot. The script names *which* tickets are the outliers; you read
them and say *why*. Lead with the finding, not with the first section.

## Step 5 — Render, and say which tier the user got

Three tiers, degrading rather than failing.

**Terminal, always.** Never skipped even when a richer tier succeeds — it is the copy that survives
in the transcript.

**A self-contained HTML report.** Inline SVG, no JavaScript, no external request of any kind, and
theme-aware in both directions:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/sprint-performance/metrics.sh" \
  --format artifact --now "<same stamp>" --out "$TMPDIR/sprint-performance.html" "$TMPDIR/sprint.tsv"
```

**Rendered inline**, by publishing that file with the `Artifact` tool — a favicon such as 📈, and a
one-line description naming the sprint and the window. Use `--format html` instead of `artifact`
when the user wants a file to open in a browser: the Artifact tool supplies its own
doctype/head/body and the `artifact` format deliberately omits them, while `html` is a whole
document. **Publishing sends the sprint's ticket titles and metrics to a claude.ai-hosted page**;
say so, and honour `--no-publish` by producing `--format html` to a path instead.

Write the file outside the work tree — an untracked HTML file inside a lane's worktree makes
`/sprint-status` §*Quiet lanes* report that lane as holding work, which is a false alarm this skill
would have manufactured for another one.

When the `Artifact` tool is not in the session, do not apologise and do not retry: name the file
path and say the terminal tables above are complete.

## Rules

- **NEVER report a rate without the n it came from.** Six weeks of a three-lane sprint is six points,
  and a trend drawn through six points is astrology.
- **NEVER print a percentile for n < 5.** With five samples there is no ninetieth percentile, there
  is a sorted list — print the list, which `metrics.sh` already does.
- **NEVER report a bare mean of cycle time.** One thirty-day ticket moves the mean of ten and moves
  the median by nothing, and the median is the one that answers the question.
- **NEVER break a metric down by person**, or invite the reader to. A lane is a component; the data
  to read it any other way was deliberately never collected.
- **NEVER present a burndown.** It hides scope growth inside the slope, where it reads as the team
  slowing down. A burnup makes it a second line.
- **NEVER count a ticket closed as `NOT_PLANNED` as throughput**, and never count one `Done` without
  a merged closing PR. Done is decided in `lib/sprint-board.md` and nowhere else; a hand-set Status
  is reported separately as *done by opinion*.
- **NEVER treat "no checks found" as "checks failed", or either as "checks passed".** Absent,
  pending, skipped, failed and passed are five states, and a repository on legacy commit statuses
  returns `state` where a reader that knows only `conclusion` sees nothing.
- **NEVER give a single completion date.** Three trailing rates give three dates and the spread
  between them is the finding. With zero trailing throughput the answer is *no basis for a
  forecast* — not a date, not "0 days remaining".
- **NEVER let "checked, none" and "did not check" render identically.**
- **NEVER recompute or reformat the script's numbers by hand.**
- **NEVER write to the board, an issue, a label or the repository.** This is a read.
- **ALWAYS name the rung day 0 came from**, and say what it would have been one rung up. A board
  created three weeks after the first commit means the sprint ran before it was planned.
- **ALWAYS say which mode the report came from**, board or milestone.
- **ALWAYS carry the "what could not be determined" section**, including the `M unknown` lines the
  gatherer recorded, and say "checked, none" when it is genuinely empty.
- **ALWAYS say which rendering tier the user got** — an Artifact URL, or a file path. A silent
  downgrade reads as the full thing.
