---
name: rebase
description: Rebase the current branch onto the latest origin base, resolving any merge conflicts and proving the result still builds and passes its tests. Use whenever a branch has fallen behind — "rebase my branch", "update against master", "main moved", a stale PR, or a CI result that was judged against an old base. Refuses to rewrite published mainline history.
argument-hint: "[base-branch] [--no-push]"
allowed-tools: Bash, Read, Grep, Glob, Edit
---

# Rebase

Put the current branch back on top of the base it is supposed to merge into, with conflicts
genuinely resolved and the result verified.

A branch is only ever tested against the base it was cut from. While it sits in review, other work
lands, and from that moment CI is judging a merge nobody has performed. The failure modes are
quiet: a check goes red for something already fixed upstream, or stays green past a semantic
conflict that only appears once both changes sit in the same tree.

The rebase itself is the easy part. What makes this a skill rather than one command is everything
around it — conflicts resolved with intent rather than by picking a side, and a branch proven to
still work afterwards.

## Context

- Current branch: !`git branch --show-current`
- Working tree: !`git status --short`
- Default branch: !`git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "(none)"`
- Upstream tracking: !`git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo "(no upstream)"`

## Step 0 — Pre-flight

1. **Resolve the base.** If `$ARGUMENTS` names a branch, use it. Otherwise resolve the
   repository's actual default branch from the context above — strip the `origin/` prefix, and
   fall back to `main`, then `master`, only if that fails. Never assume the name.

2. **Refuse on the default branch.** Compare the current branch against the repository's *default*
   branch (`git symbolic-ref --short refs/remotes/origin/HEAD`), not against the base resolved in
   step 1 — otherwise `/rebase develop` while sitting on `master` sails straight past this guard
   and rewrites mainline. Also stop if the current branch simply *is* the base. Mainline history is
   shared and rewriting it breaks every branch cut from it; `/absorb` refuses for the same reason.

3. **Deal with a dirty tree.** A rebase will not start with uncommitted changes. Stash them
   (`git stash push --include-untracked -m "rebase: auto-stash"`), remember that you did, and tell
   the user — silently pocketing someone's work in progress is how it gets lost.

   **Restore it on every exit, not just the happy one.** This skill stops early in several places:
   the base has not moved (Step 1), a conflict could not be resolved (Step 3), the lease was
   rejected (Step 5). Each of those must pop the stash before returning, or the user's tree comes
   back deceptively clean with their work parked in a stash entry they were never told to look for.
   Cheapest way to get this right is to check whether the base moved *before* stashing — see
   Step 1.

4. **Note whether the branch is published.** `git rev-parse --abbrev-ref '@{upstream}'`. A branch
   with an upstream will need a force-push; a purely local one will not.

## Step 1 — Has the base actually moved?

Run this check *before* Step 0.3's stash where you can — the overwhelmingly common answer is "no",
and not stashing at all is simpler than remembering to restore.

```
git fetch origin <base>
git log --oneline HEAD..origin/<base>
```

Fetch the **base ref only**, never a bare `git fetch origin`. A bare fetch also updates
`refs/remotes/origin/<your-branch>`, which is precisely the ref a plain `--force-with-lease` uses
as its expected value in Step 5 — refresh it and the lease silently starts agreeing with whatever
a colleague just pushed, which is the one thing it exists to prevent.

Empty output means there is nothing to do. Say so and stop rather than performing a no-op rebase —
rewriting commit hashes for no reason invalidates everyone's local copies and any review already
in progress.

Otherwise, report what landed underneath: how many commits, and what they touched. That is context
the user needs if a conflict shows up next.

## Step 2 — Rebase

```
git rebase origin/<base>
```

If it completes cleanly, go to Step 4.

## Step 3 — Resolve conflicts

A rebase replays your commits one at a time, so it can stop **more than once**. Each stop is its
own conflict on its own commit. Work the loop:

1. `git status` to see which files conflict, and `git log -1 --format='%s' REBASE_HEAD` to see
   which of your commits is being replayed. Resolving without knowing which change you are
   replaying is guessing.
2. Read both sides properly. `git log --oneline HEAD..origin/<base> -- <file>` shows what landed
   upstream and why; the conflicting hunk alone rarely explains intent.
3. Resolve so that **both** intents survive. Taking one side wholesale is almost always wrong — if
   upstream tightened a check and your commit added a branch, the answer is the tightened check on
   your branch too, not one or the other.
4. `git add <files>` and `git rebase --continue`. Repeat until the rebase finishes.

Two things not to do:

- **Do not resolve a conflict you do not understand.** If the upstream change and yours disagree
  about something neither comment explains, `git rebase --abort` and stop. A plausible guess at
  somebody else's intent is worse than asking, because it reads as a merge rather than a decision
  and nobody reviews it again.
- **Do not use `-X ours`/`-X theirs` to make it go away.** They discard the other side silently and
  produce exactly the semantic conflict this skill exists to catch.

Record every resolution with `file:line` and one sentence on what you kept and why. This is the
part of a rebase nobody can see afterwards — the diff shows the result, never the decision.

## Step 4 — Verify it still works

A rebase that compiles is not a rebase that works. Semantic conflicts — your caller, their renamed
callee; your test, their changed default — merge without complaint.

1. **Build.** Use whatever the project actually builds with — a CMake preset, `cargo build`,
   `npm run build`, `go build`, `make`. Read `CLAUDE.md`/`AGENT.md`, the README, or the CI workflow
   to find out rather than assuming a C++ toolchain; this skill is invoked by `/work-issue` and
   `/fix-ci`, which run on any repository. Build clean — a stale cache hides exactly the
   incompatibility a rebase introduces. If the repository has nothing to build (a docs or config
   repo), say so and go to step 2.
2. **Run the full suite**, not just the tests near the conflict. The point is to catch what
   upstream changed underneath code you did not touch.
3. **If something fails**, decide honestly whether it is your branch, the new base, or the two
   together. Run the same test on `origin/<base>` before concluding anything — a failure that
   reproduces there is pre-existing and is not yours to absorb into this rebase.

   Report it using the *Classification* vocabulary from
   `${CLAUDE_PLUGIN_ROOT}/lib/adjacent-problems.md` and stop there. This skill has no commit step,
   so it does not fix, file or branch off for anything — that is the caller's decision, and
   `/work-issue` and `/fix-ci` both know what to do with a finding labelled adjacent.

Where each commit must build on its own — a repository that expects bisectability — verify them
all rather than only the tip:

```
git rebase origin/<base> --exec '<the project build command>'
```

This stops the rebase at the first commit that fails to build, leaving you mid-rebase on a detached
HEAD. That is the point — but it needs finishing: fix the commit and `git rebase --continue`, or
`git rebase --abort` and report. Do not push or restore the stash while a rebase is in progress;
`git status` will tell you it still is.

## Step 5 — Publish

Skip this entirely if `$ARGUMENTS` contains `--no-push`, or if the branch has no upstream. A
caller that is about to push a fix of its own should rebase locally and push once: every force-push
restarts CI, and two pushes mean two full runs for one logical change.

Otherwise:

Record the branch's remote tip *before* any fetching (`git rev-parse refs/remotes/origin/<branch>`),
and name it in the lease:

```
git push --force-with-lease=<branch>:<recorded-sha>
```

A rebase rewrites history, so the push must be forced. The explicit expectation is what makes the
lease mean anything: a bare `--force-with-lease` trusts the remote-tracking ref, and any fetch
between then and now has already quietly updated it to include a colleague's push. Never `--force`.

**If the lease is rejected, stop.** Someone else's commits are on that branch. Escalating to
`--force` discards precisely what the lease existed to protect. Report it and let the user decide.

## Step 6 — Restore and report

Restore the Step 0 stash if there was one. If it conflicts, say so and leave the stash intact
rather than forcing it.

Report:

- **Base** — which branch, and what landed underneath (commit count and subjects).
- **Conflicts** — every file, and what was kept and why. State "none" if it was clean.
- **Verification** — build result and full-suite result, with numbers.
- **Push** — pushed, skipped (and why), or blocked by a rejected lease.
- **Adjacent findings** — anything the verification turned up that belongs to the base rather than
  to this branch, and where triage sent it.

## Rules

- NEVER rebase the default branch.
- NEVER escalate `--force-with-lease` to `--force`.
- NEVER resolve a conflict you cannot explain — abort and ask.
- NEVER use `-X ours` or `-X theirs` to clear a conflict.
- NEVER report success without building and running the suite; a clean rebase proves nothing. If
  the project has no build or test command to run, say that explicitly in the report instead of
  implying it was verified.
- NEVER rebase when the base has not moved.
- ALWAYS restore a stash you created.
- ALWAYS report each conflict resolution — it is invisible in the resulting diff.
