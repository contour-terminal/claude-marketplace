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

Resolve and record everything the later steps depend on. Two of these reach the remote — the
existence check in 1 and, if needed, `git remote set-head` in 2 — but neither updates this
branch's own tracking ref, which is what step 4's recording relies on.

1. **Split `$ARGUMENTS` into flags and a base.** `--no-push` is a flag, not a branch, and callers
   pass it alone (`/rebase --no-push` is `/fix-ci`'s only invocation). Separate them — do not
   discard the flag, Step 5 still needs to know it was given — and if what remains names a branch,
   use it; otherwise take the repository's default branch (below).

   Verify it exists on the remote, and test the **output**, not the exit status:

   ```
   git ls-remote --heads origin 'refs/heads/<base>'      # empty output means it does not exist
   ```

   Both details matter. `git ls-remote --heads origin --no-push` exits 0 with no output, so an
   exit-status check treats a flag — or a typo — as a valid base. And a bare `<base>` matches any
   ref whose tail equals it: asking for `master` on a remote holding `release/master` returns that
   instead, so the check passes and the rebase then runs against a branch nobody named. The full
   refspec matches exactly.

2. **Resolve the default branch, and refuse to rebase it.** `git symbolic-ref --short
   refs/remotes/origin/HEAD` prints it *with* the `origin/` prefix — strip that before comparing
   with `git branch --show-current`, or the comparison never matches and the guard fails open,
   which is the one thing it must not do. If the ref is missing (a clone where `origin/HEAD` was
   never set — the Context block prints `(none)`), run `git remote set-head origin -a` once and
   retry. If it *still* cannot be resolved, **stop and ask**; do not fall back to guessing `main` or
   `master` here. Guessing is safe when resolving a base (step 1 — a wrong guess fails loudly
   against the remote) and unsafe here: on a repository whose default branch is `develop`, guessing
   `main` makes the comparison `develop != main` succeed, the guard stay silent, and the shared
   mainline get rebased and force-pushed. A guard that guesses is not a guard.

   Stop if the current branch is the default branch, or is the base. Note that these are different
   tests: `/rebase develop` while sitting on `master` passes the second and must still be refused
   by the first. Mainline history is shared and rewriting it breaks every branch cut from it;
   `/absorb` refuses for the same reason.

3. **Decide whether commits must build individually.** A repository that expects `git bisect` to
   work needs every commit to build, not just the tip. That choice changes which command Step 2
   runs, so make it now — after Step 2 it cannot be applied without rebasing a second time.

4. **Record whether the branch is published, and its remote tip.**

   Apply *Is this branch published?* from `lib/git-safety.md` — the test is the branch's own
   remote ref, never `@{upstream}`, and a fork PR's head lives on another remote entirely.

   Check publication *first*, and only fetch if it is published — `git fetch origin <branch>` on a
   branch that was never pushed is a fatal error, and `/work-issue` Phase 6 invokes this skill
   before `/create-pr` has pushed anything:

   ```
   git ls-remote --heads origin 'refs/heads/<branch>'    # empty output: unpublished, skip the rest
   git fetch origin <branch>
   git rev-parse --verify refs/remotes/origin/<branch>
   ```

   *Force-pushing safely* says to fetch before recording, so that the baseline is the tip your work
   is actually based on rather than a stale local value.

   If that fetch **moves** the ref, somebody pushed to your branch since you last looked. Stop and
   say so rather than recording their commit as your baseline — rebasing on top of it and then
   leasing against it would rewrite their work with the guard nodding along.

   Step 1 fetches only the base and never this branch, so nothing between here and Step 5 disturbs
   the value.

## Step 1 — Has the base actually moved?

```
git fetch origin <base>
git log --oneline HEAD..origin/<base>
git merge-base HEAD origin/<base>          # record it; Step 3 needs it
```

Fetch the **base ref only**, never a bare `git fetch origin`. A bare fetch also updates
`refs/remotes/origin/<your-branch>`, which is what a plain `--force-with-lease` trusts — refresh it
and the lease silently starts agreeing with whatever a colleague just pushed, the one thing it
exists to prevent.

Record the merge base before rebasing. Once the rebase starts, HEAD sits on top of `origin/<base>`,
so this is the last moment the "what landed upstream" range can be computed at all.

Empty output means there is nothing to do. Say so and stop rather than performing a no-op rebase —
rewriting commit hashes for no reason invalidates everyone's local copies and any review already
in progress. Nothing has been stashed at this point, so this exit is clean.

Otherwise, report what landed underneath: how many commits, and what they touched. That is context
the user needs if a conflict shows up next.

## Step 1.5 — Stash a dirty tree

Only now, once a rebase is actually going to happen. A rebase will not start with uncommitted
changes:

Apply *Stashes* from `lib/git-safety.md`: record the entry's identity as you create it, and
restore it on every exit from here on — not only the successful one. This skill has three early
exits after this point: an unresolvable conflict (Step 3), a failed build or suite (Step 4), and a
rejected lease (Step 5). Each must restore before returning.

## Step 2 — Rebase

```
git rebase origin/<base>
```

If Step 0.3 decided commits must build individually, use the `--exec` form here **instead** — see
Step 4 — rather than the plain command; running it later would be a second rebase onto a base the
branch already sits on.

If it completes cleanly, go to Step 4.

## Step 3 — Resolve conflicts

A rebase replays your commits one at a time, so it can stop **more than once**. Each stop is its
own conflict on its own commit. Work the loop:

1. `git status` to see which files conflict, and `git log -1 --format='%s' REBASE_HEAD` to see
   which of your commits is being replayed. Resolving without knowing which change you are
   replaying is guessing.
2. Read both sides properly. Use the merge base recorded in Step 1:

   ```
   git log --oneline <merge-base>..origin/<base> -- <file>
   ```

   That shows what landed upstream and why; the conflicting hunk alone rarely explains intent. Do
   not reach for `HEAD..origin/<base>` here — mid-rebase, HEAD already sits on top of the base, so
   that range is empty by construction and would silently answer "nothing changed".
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
   `/fix-ci`, which run on any repository. Build incrementally first; fall back to a clean build if it fails, or if the rebase touched build
   inputs, where a stale cache can hide the incompatibility. An unconditional from-scratch build is
   the wrong default here — `/work-issue` runs this skill on every pass of its CI loop. If the repository has nothing to build (a docs or config
   repo), say so and move on to running its tests below.
2. **Run the full suite**, not just the tests near the conflict. The point is to catch what
   upstream changed underneath code you did not touch.
3. **If something fails**, decide honestly whether it is your branch, the new base, or the two
   together. Run the same test against the base before concluding anything — in a scratch worktree
   (`git worktree add ../<repo>-base-$$ origin/<base>`, removed with `git worktree remove` when done
   — a fixed path collides with the one `/fix-ci` creates in the same `/work-issue` loop pass), never by checking the base
   out here: the branch has just been rewritten and a Step 1.5 stash may be outstanding. A failure
   that reproduces there is pre-existing and is not yours to absorb into this rebase.

   Report it using the *Classification* vocabulary from
   `${CLAUDE_PLUGIN_ROOT}/lib/adjacent-problems.md` and stop — restoring the Step 1.5 stash on the
   way out, and saying plainly that the rebase happened but the branch does not build or pass, so
   a caller does not carry on treating this as a successful sync. This skill has no commit step,
   so it does not fix, file or branch off for anything — that is the caller's decision, and
   `/work-issue` and `/fix-ci` both know what to do with a finding labelled adjacent.

Where Step 0.3 decided each commit must build on its own, Step 2 should already have used the
`--exec` form instead of the plain rebase:

```
git rebase origin/<base> --exec '<the project build command>'
```

Do not run it here as a follow-up: that would be a second rebase onto a base the branch already
sits on, rewriting every hash for nothing — the thing Step 1 refuses to do. If you reached this
step having run the plain rebase and per-commit verification was required, say so rather than
silently reporting a success you did not verify.

It stops at the first commit that fails to build, leaving you mid-rebase on a detached HEAD. That
is the point, but it needs finishing: fix the commit and `git rebase --continue`, or
`git rebase --abort` and report. Do not push or restore the stash while a rebase is in progress;
`git status` will say that it still is.

## Step 5 — Publish

Skip this entirely if Step 0.1 saw `--no-push`, or if Step 0.4 found the branch
**unpublished** by the *Is this branch published?* test — not by `@{upstream}`, which is set on
branches that have no remote branch of their own. A caller about to push a fix of its own should
rebase locally and push once: every force-push restarts CI, and two pushes mean two full runs for
one logical change.

Otherwise:

Apply *Force-pushing safely* from `lib/git-safety.md`, with the SHA recorded in Step 0.4:

```
git push --force-with-lease=<branch>:<sha-recorded-in-step-0.4> origin <branch>
```

All three parts are load-bearing — the explicit SHA, the named remote and refspec, and stopping
rather than escalating to `--force` if the lease rejects.

## Step 6 — Restore and report

Restore the Step 1.5 stash if there was one, following *Stashes* in `lib/git-safety.md`.

Report:

- **Base** — which branch, and what landed underneath (commit count and subjects).
- **Conflicts** — every file, and what was kept and why. State "none" if it was clean.
- **Verification** — build result and full-suite result, with numbers.
- **Push** — pushed, skipped (and why), or blocked by a rejected lease.
- **Adjacent findings** — anything the verification turned up that belongs to the base rather than
  to this branch, and where triage sent it.

## Rules

- NEVER rebase the default branch — compare branch names with the `origin/` prefix stripped, and
  stop rather than guessing when the default branch cannot be resolved.
- NEVER treat a zero exit from `git ls-remote` as proof a branch exists; check its output.
- NEVER escalate `--force-with-lease` to `--force`.
- NEVER resolve a conflict you cannot explain — abort and ask.
- NEVER use `-X ours` or `-X theirs` to clear a conflict.
- NEVER report success without building and running the suite; a clean rebase proves nothing. If
  the project has no build or test command to run, say that explicitly in the report instead of
  implying it was verified.
- NEVER rebase when the base has not moved.
- ALWAYS restore a stash you created.
- ALWAYS report each conflict resolution — it is invisible in the resulting diff.
