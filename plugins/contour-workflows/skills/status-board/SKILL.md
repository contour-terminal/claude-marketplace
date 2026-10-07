---
name: status-board
description: Keep a local, never-committed STATUS.md current at every state change of a run, and republish it after every edit as a phone-friendly page at one private artifact URL, so the owner can see where the work stands from anywhere without asking. Use to set up a status board or phase board, to keep STATUS.md current while tasks are dispatched, reviewed and landed, to answer "where are we" for a local run that has no project board, or to publish or refresh the status page. The local, board-free counterpart of /sprint-status.
argument-hint: "[init | update | publish]"
allowed-tools: Bash(git:*), Bash(python3:*), Bash(python:*), Bash(date:*), Read, Edit, Write, Grep, Glob, Artifact
---

# Status Board

One file, one page, one link. `STATUS.md` sits at the root of the working tree, is never committed,
and is edited at every state change of a run; after every edit it is rendered into a page that reads
on a phone and republished to the **same** private artifact URL. The owner keeps that one link and
never has to ask where things stand.

**Each working tree has a board of its own** — the main one and every linked worktree: its own
`STATUS.md`, its own rendered page, its own URL. Sessions in different worktrees run this skill in
parallel without touching each other's board, and the owner holds one link per worktree.

`/sprint-status` answers "where are we" from a GitHub project board, its PRs and its branches. This
is the lightweight local tracker: for a run that has no board, or kept alongside one as the owner's
one-link view — in which case the board is authoritative and `STATUS.md` says so, for the reason
`lib/sprint-board.md` §*The tracking-issue mirror* gives for any mirror.

The failure this skill is built against is **a page that looks current and is not.** The usual
shape is not a stale file — it is a file whose `Last updated` line moved while the body still
describes an earlier state: a lane in review that landed an hour ago, a follow-up that was fixed,
a *Now* line naming work that finished. The stamp vouches for the whole body, so a fresh stamp over
a stale body is worse than an old stamp — it tells the owner not to look closer.

`$ARGUMENTS` picks the mode. With none: `init` when there is no `STATUS.md`, otherwise `update`.

## Context

- This working tree, whose root holds its `STATUS.md`: !`git rev-parse --show-toplevel 2>/dev/null || echo "(not a git repository)"`
- Its git dir (under `.git/worktrees/` for a linked worktree): !`git rev-parse --absolute-git-dir 2>/dev/null || echo "(not a git repository)"`
- Its remembered page URL: !`python3 "${CLAUDE_PLUGIN_ROOT}/skills/status-board/status_page.py" --url 2>/dev/null || echo "(not read here; run status_page.py --url before publishing)"`

## Where things live

| What | Where | Why there |
|---|---|---|
| `STATUS.md` | Root of the current working tree | One board per worktree. Sessions in other worktrees have boards of their own, so none of them edits this file, and the renderer never reaches into another worktree for one |
| Its exclusion | `/STATUS.md` in the file `git rev-parse --git-path info/exclude` names | Per clone and never committed, and shared by every worktree: the one line covers each worktree's root. `.gitignore` is committed: the exclusion itself would publish the name of a file nobody else has, and change the repository for everyone to suit one workflow |
| The rendered page | `<git dir>/status-board.html` — the renderer's default | In the working tree's own git dir (`.git/worktrees/<name>/` for a linked one), so it cannot be committed and no other worktree's render overwrites it. An untracked HTML file in a working tree shows in every `git status`, makes the quiet-lanes check in `/sprint-status` Step 3 report the lane as holding work, and is one `git add -A` from a commit |
| The page's URL | `<git dir>/status-board.url`, read and written by the renderer's `--url` and `--remember-url` | Beside the page, private to the worktree, and never committed or pushed. Not `git config --local`: every worktree shares it, so a URL kept there sends every worktree's board to one page |

Ask git for these paths rather than writing `.git/…` by hand: in a linked worktree `.git` is a
file, not a directory.

Boards from before they were per worktree kept the URL in `git config --local status-board.url`.
That board was the one at the main working tree's root, so `--url` in the main tree still reads the
old key until the next `--remember-url`, which retires it.

## Who writes it

**One writer per board:** the session working in that worktree. A session never edits another
worktree's `STATUS.md`, not even to note something about it there; it says so in its own board or
reports to whoever coordinates. Under `/sprint-run` the manager's board is the run's, in the
manager's worktree; developer sessions report to the manager (`lib/team-protocol.md` §*Reporting to
the manager*) and keep a board only in their own worktree, if at all. The file is untracked, so two
writers lose each other's edits with no merge to notice and no history to recover from.

Two sessions in **the same** worktree share its board, and only one of them may write it — the one
coordinating; the other reports to it.

For the same reason, **edit it in place.** A whole-file rewrite from memory silently deletes
whatever the session did not remember, and there is no `git checkout` to bring it back.

## Mode `init`

### Step 1 — Refuse a tracked file

```bash
git ls-files --error-unmatch :/STATUS.md
```

`:/` is the root of the current working tree. Run from a subdirectory, a bare `STATUS.md` looks for
the wrong path and reports a tracked file as untracked.

If that succeeds, `STATUS.md` is committed. Stop and say so: an exclude entry does nothing for a
tracked file, and untracking it is a commit that deletes it for everyone else — the owner's call,
not this skill's.

### Step 2 — Exclude it

Append `/STATUS.md` to the file `git rev-parse --git-path info/exclude` names, unless a line already
covers it. That file is shared by every worktree, so a board set up in another worktree has usually
added it already; do not add a second. Then prove it:

```bash
git check-ignore -v :/STATUS.md
```

The output must name `info/exclude`. A line naming `.gitignore` means a committed rule already
covers it — fine, but leave it alone and do not add a second one.

### Step 3 — Create it

If `STATUS.md` already exists at this working tree's root, it is the board: go to `update` rather
than overwrite it. Otherwise write it from the template below. In a linked worktree the H1 names
the worktree's branch or purpose — `# <project> · <branch> — status` — so its page is not
mistaken for another worktree's. Take the stamp from `date '+%Y-%m-%d %H:%M:%S'`, and
fill the plan, the decisions already made and one row per lane or phase from what the session
actually knows. Leave a section's placeholder out rather than invent content for it — except the
goal and its summary, which every board has: they are the page's title and the paragraph beside it.

### Step 4 — Publish

Mode `publish`. The first publish creates the artifact and remembers its URL.

### The template

```markdown
# <project> — status

Local-only tracker: excluded via `.git/info/exclude`, never committed. Times are local, from `date`, to the second.

**Last updated:** YYYY-MM-DD HH:MM:SS

## Current plan: <what this session's work is about, in one line>

<Two or three sentences that say more: what the work changes and why, what done looks like, and where it lands — one PR, several, a release or none.>

**Decisions:**
- <YYYY-MM-DD HH:MM:SS: a decision the owner made that shapes the plan.>

| Lane | Tasks done | State | Where it is |
|---|---|---|---|
| <Lane: what it delivers> | 2/5 | running | <task 3 (what it is) in review; last commit `abc1234`> |
| <Lane> | 3/3 | landed | <on `<branch>` at `abc1234`; the suite's count> |
| <Lane> | 0/4 | queued | <what it waits for> |

**Now:** <what is running at this moment, one clause per lane.>
**Next:** <the steps from here to done, in order.>

## Key rulings

- <A question that came up during the run, and how it was settled, so it is not argued again.>

## Follow-ups

- <Something found that is outside this plan. The owner decides; it is not silently fixed.>
```

What the page does with it:

- **The goal in `## Current plan:` is the page's title** — the big heading, the browser tab and the
  artifact's name in the gallery — so the owner sees at a glance what the work in this tree is
  about. Write it as that: *"streaming input for the parser"*, not *"phase 2"*. The paragraph right
  under the heading is shown beside it as a short summary, and becomes the page's description.
  The renderer warns when either is missing, and when a list, a table or a labelled line such as
  `**Decisions:**` stands where the summary belongs. The rest of the section stays in the body
  under a plain *Plan* heading.
- The H1 names the project, and in a linked worktree the branch; the page shows it small above
  the title. The preamble line is for someone who opens the file; the page drops everything
  between the H1 and the stamp and says the same in its footer.
- **Any table with an `N/M` column and a `State` column is drawn as progress bars**, one per row,
  and the headline sums every such table: *"7 of 19 tasks done · 1 of 4 lanes landed"*. One table
  per phase works. The first column's header names the rows (`Lane` → lanes, `Phase` → phases) and
  the count column's header names the unit (`Tasks done` → tasks, `Steps done` → steps).
- A table with more than one `N/M` column counts the one headed like `Tasks done`. With no such
  header the renderer counts the first and warns, because a `Tests` column of `212/212` ahead of
  the task count would draw an unfinished lane as finished.
- A table of test results — `1204/1204` beside `PASS` — is not progress, and is not drawn as it: the
  state column must hold at least one of the state words below.
- `**Now:**`, `**Next:**` and `**Blocked:**` at the start of a line become labelled lines.
- Nest list items with **four** spaces. The page reads two as a sibling of the item above, where
  GitHub would nest it, and the renderer warns where it sees that.
- **Every date and time is written in full, `YYYY-MM-DD HH:MM:SS`**: the stamp, each dated
  decision or ruling, and any time the body mentions. The renderer warns about a time that stops at
  the minute and about a list item that opens with a date and no time, and the page's own
  *Page generated* line carries seconds too. Two entries made in the same minute keep their order,
  and a reader can match an entry to a log line or a commit.

The state column starts with one of these; anything after it stays as written
(`blocked — on the schema decision`):

| State | Means | Drawn as |
|---|---|---|
| `running` | A task in the row is being worked or reviewed now (`in progress`, `in review` read the same) | The next rung amber; named under *In progress* |
| `landed` | Every task done and on the integration branch (`merged` reads the same) | All rungs green; counted as landed |
| `done` | Every task done, with nothing to land | All rungs green; counted as done |
| `queued` | Not started. An empty cell reads as queued | Grey |
| `blocked` | Cannot move until something named happens (`on hold` reads the same) | The next rung red; named under *Blocked* |

The headline says *landed* when every finished row landed or merged, and *done* otherwise.

## Mode `update` — the discipline

### When

**At every state change, in the same turn** as the change:

- a task dispatched, reported, reviewed, fixed or completed;
- a branch landed or merged;
- a baseline or a test count moved;
- a ruling made — by the owner, or a question settled mid-run;
- a blocker appeared or cleared;
- the plan changed.

Not at the end of a batch. A page brought up to date when the batch finished was wrong for the
whole batch, which is exactly when the owner looked.

### What, at every edit

1. **The stamp.** Run `date '+%Y-%m-%d %H:%M:%S'` and write what it prints. Never estimate it,
   never carry a time forward from earlier in the session. A stamp is a claim that the body was true
   at that second, and a guessed one is a claim nobody checked. A dated entry added in the same edit
   takes its time from the same `date` call, or from the event's own record (a commit, a message)
   when it happened earlier — never from memory.
2. **The row.** Its `N/M`, its state, and *where it is* — the commit, the PR, what is in review.
3. **`Now` and `Next`.**
4. **Any count that moved** — a baseline, a test total — wherever the file states it.

### What, at a milestone

A lane landed, a phase finished, the plan changed, a ruling was made: **update the body, not just
the header.**

- Rewrite the plan's goal and summary and *Now* so they describe this state, not the one the plan
  started from. The goal and summary are the first thing on the page: a stale one there misleads
  before anything else is read.
- Prune follow-ups that got fixed. Move a settled question into *Key rulings*.
- When a plan finishes, the next one replaces it; it is not appended underneath. If the finished one
  is worth keeping, move it to a local archive file excluded the same way.

### The read-back

Before publishing, read the whole file once and check that every sentence holds at the stamp:
*Now* names only rows whose state is `running`; no row says `running` for work that landed; *Next*
lists nothing already done; every follow-up is still open. This is what makes the stamp true. A
header that moved while the body still describes an earlier state is the failure this skill exists
for.

### Status, not notes

Goal, decisions, the progress table, *Now*, *Next*, rulings, follow-ups. Lessons learned, rules for
working in the repository and how-tos belong somewhere else — a `NOTES.md`, the project's own agent
instructions — and history belongs in the archive. A status file that accumulates everything
becomes a document the owner has to read in order to find the status.

Then publish. Every edit ends in a publish, or the page and the file have already diverged.

## Mode `publish`

### Step 1 — Render

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/status-board/status_page.py"
```

(`python` where that is the interpreter's name.) It finds this working tree's `STATUS.md` from
anywhere inside it, writes the page to the working tree's git dir, and prints one line: the path,
and the headline it drew. `--source`, `--output` and `--title` override the defaults; `--standalone`
writes a complete HTML document instead of the fragment the `Artifact` tool wraps itself.

**In a linked worktree, add `--output <scratchpad>/status-board.html`.** Its git dir lies under the
main tree's `.git/worktrees/`, outside the session's working directory, and the `Artifact` tool
publishes only files under that directory or the session's scratchpad. The scratchpad is the
session's own, so this stays parallel-safe. Do the same anywhere the tool refuses the default path.

**A warning is a defect in `STATUS.md`, not in the page**: a missing goal or summary, a missing or
malformed stamp, a time without its seconds, a dated entry without its time, a count above its
total, a state word the page does not know, a count column it had to guess, a list nested at fewer
than four spaces. Fix the file and render again; do not publish over a warning.

The renderer needs the `markdown` package and says so in one line — `pip install markdown` — when it
is missing. Installing it is the owner's call: say what is missing rather than install it unasked.

### Step 2 — Publish to the one URL

Read this worktree's URL — the context above shows it, and from anywhere in the worktree:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/status-board/status_page.py" --url
```

**A URL is remembered.** If this session has neither published nor read that artifact yet, read it
once with the `Artifact` tool first: the tool refuses to update an artifact the session did not
create and has not read. Then publish the rendered file to
that URL. The page is finished as rendered: publish the file as it is, not a rewrite of it.

**No URL yet.** Publish the file as a new artifact, with a generic icon word such as `checklist` and
a one-line description that names the worktree, and remember its URL at once:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/status-board/status_page.py" --remember-url "<the artifact URL>"
```

Give the owner the link, and say which worktree it follows. It is the only time they need it;
afterwards it does not change. Never publish to a URL another worktree remembered: that page is
its board, and the two would overwrite each other at every edit.

**The read reports the artifact gone** — deleted, or not accessible to this account. This, and only
this, replaces it: say so, publish a new one, `--remember-url` the new one, and give the owner the new
link in so many words. The link they have is dead, and that is the one thing they must learn.

**The read fails any other way** — a network error, expired authentication, a tool not loaded.
Report the error and stop; do not create a second artifact. A failed read is not a missing page,
and a replacement made for a passing reason leaves the owner's link on a page nobody updates.

The artifact is **private**. Publishing sends the content of `STATUS.md` to a page on claude.ai that
only the owner can open: say so on the first publish, and keep credentials, tokens and anything else
secret out of the file. Never change the artifact's sharing, and never suggest hosting the page
anywhere else.

### Step 3 — Say which one the owner got

After a republish to the known URL, one line is enough — the page is the report, so do not paste it
back into the conversation. Say which tier it was: the artifact, or a local file.

**No `Artifact` tool in the session, or the owner declined publishing:** render with `--standalone`
and give the file's path. Do not apologise and do not retry; say that the page is local only and
that `STATUS.md` itself is complete.

## When the worktree goes away

`git worktree remove` deletes an ignored `STATUS.md` without asking, and with it the worktree's git
dir, which holds the page and its URL. The artifact itself stays, frozen at its last publish. Before
a worktree with a board is removed, publish its final state — say so on the page when the run is
over — and copy anything worth keeping somewhere that outlives the worktree.

## Rules

- **NEVER commit or push `STATUS.md`, or exclude it through `.gitignore`.** `.git/info/exclude` only.
- **NEVER let a tracked file, a commit message, a PR or an issue refer to `STATUS.md` or carry the
  page's URL.** Nobody else has either; a pointer to them is a dead link in public.
- **NEVER write a timestamp that did not come from `date` or the event's own record, and never one
  without its seconds.**
- **NEVER move the stamp without the read-back.** The stamp vouches for the body.
- **NEVER save updates for the end of a batch.** Same turn as the change.
- **NEVER create a second artifact unless a read reports the remembered one gone.** A read that
  failed for another reason is not a missing page, and the owner keeps one link.
- **NEVER change the artifact's sharing, or suggest publishing the page anywhere else.**
- **NEVER publish over a warning from the renderer.**
- **ALWAYS keep one writer per board**: the session in that worktree. Never edit another
  worktree's `STATUS.md`, and never publish to another worktree's URL.
- **ALWAYS say which tier the owner got**: the artifact URL, or a local file path.
