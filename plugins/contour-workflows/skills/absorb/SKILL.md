---
name: absorb
description: Absorb the pending working-tree changes into the branch commits that introduced the lines they touch, via fixup commits and an autosquash rebase. Use for review tweaks, typo fixes, and follow-up corrections that belong to an earlier commit of the current branch — not just the most recent one. Refuses to rewrite published mainline history.
allowed-tools: Bash(git:*), Read, Grep, Glob
---

# Absorb

Fold each pending change into **the commit that introduced the code it modifies**, rather
than into a single commit. This is the manual equivalent of `git absorb`: per-hunk blame →
`git commit --fixup=<sha>` → `git rebase --autosquash`.

## Context

- Current branch: !`git branch --show-current`
- Git status: !`git status --short`
- Unstaged+staged diff with zero context (hunk line ranges): !`git diff HEAD -U0`
- Untracked files: !`git ls-files --others --exclude-standard`
- Default branch: !`git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "(none)"`
- Upstream tracking state: !`git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo "(no upstream)"`

## Step 0 — Pre-flight

1. **Nothing to absorb?** If there are no staged or unstaged changes to tracked files,
   report that and stop. (Untracked files can never be absorbed — see Step 2.)

2. **Refuse on the default branch.** Apply *Force-pushing safely* → "Never rewrite the default
   branch" from `${CLAUDE_PLUGIN_ROOT}/lib/git-safety.md` (read it with the **Read** tool): strip
   the `origin/` prefix before comparing, and stop rather than guessing if it cannot be resolved.
   If the current branch *is* the default branch, stop — this skill rewrites history and the
   mainline is shared. Recommend `/commit` instead.

3. **If the branch is published, record its lease baseline.** Apply *Is this branch published?*,
   then fetch that branch and record its tip — Step 5 needs the value, and Step 4's rebase will
   have rewritten everything by then:
   ```
   git fetch origin <branch>
   git rev-parse --verify refs/remotes/origin/<branch>
   ```
   If the fetch moves the ref, somebody has pushed to the branch; stop and reconcile rather than
   absorbing on top of it.

4. **Determine the absorb range.** The candidate commits are exactly those unique to this
   branch:
   ```
   git merge-base HEAD origin/<default-branch>
   git log --format='%H %s' <merge-base>..HEAD
   ```
   If the range is empty, stop — there is nothing on this branch to absorb into.

5. **Exclude merge commits** from the candidate set (`git log --no-merges`). A fixup can
   never target a merge.

6. **Foreign authorship.** If any candidate commit's author (`%ae`) differs from
   `git config user.email`, note it now; you will need to warn before targeting it.

## Step 1 — Map each hunk to its base commit

For every hunk in the `-U0` diff:

1. Take the **pre-image** line range (`@@ -<start>,<count> +...`).

2. **Modified or deleted lines** (`count > 0`): blame those exact lines:
   ```
   git blame -L <start>,<start+count-1> --porcelain HEAD -- <path>
   ```
   Collect the commit SHAs. Keep only SHAs inside the absorb range from Step 0.

3. **Pure insertions** (`count == 0`, i.e. `@@ -<n>,0 @@`): there is no line to blame.
   Blame the immediately surrounding lines instead (`<n>` and `<n>+1`, clamped to the file)
   and use those as the candidate. An insertion between two lines from *different* in-range
   commits is ambiguous — treat it as unattributable (Step 2).

4. **Resolve to one target per hunk:**
   - All blamed SHAs in range and identical → that commit is the target.
   - Several in-range SHAs → target the **newest** of them (`git rev-list` order), since a
     later commit's version of those lines is what the change is correcting.
   - No blamed SHA in range (the lines come from before the branch point, or from an
     untracked/new file) → **unattributable**.

Group hunks by target commit. Report the mapping to the user as a short table
(`<file>:<lines> → <short-sha> <subject>`) before making any commit.

## Step 2 — Handle what cannot be absorbed

Leave in the working tree, untouched:

- unattributable hunks (they belong to code the branch did not introduce),
- all untracked files (no history to attribute them to),
- anything touching a commit whose author is not the user, unless they confirm.

Do not invent a target for them and do not fold them into `HEAD` as a consolation. Report
them explicitly at the end and suggest `/commit` if they are a change of their own.

If *every* hunk is unattributable, stop after reporting — do not rebase.

## Step 3 — Create fixup commits

For each target commit, in any order:

```
git add <paths or hunks for this target>
git commit --fixup=<target-sha>
```

- Stage only that target's hunks. When a file's hunks map to more than one target, stage
  selectively — write the desired subset to the index rather than the whole file
  (`git apply --cached` with a filtered patch is the non-interactive way; never `git add -p`).
- Never `git add -A`. Never stage files that look like secrets (`.env`, `*.key`, `*.pem`).
- Let hooks run. If a pre-commit hook fails, fix it, re-stage, and retry. Never `--no-verify`.

## Step 4 — Autosquash

Once all fixups exist:

```
git -c sequence.editor=true rebase -i --autosquash --autostash <merge-base>
```

`--autostash` parks anything still in the working tree (the Step 2 leftovers) and restores
it afterwards. `sequence.editor=true` accepts the generated todo list unedited — the skill
must never open an interactive editor.

If the rebase stops with a conflict:
1. Report the conflicting path and the commit being replayed.
2. Resolve it only if the resolution is unambiguous (the fixup content is what wins).
3. Otherwise run `git rebase --abort`, restoring the branch exactly as it was, and tell the
   user. Never leave the user in a detached mid-rebase state without saying so.

Afterwards verify no `fixup!` commits survived:
```
git log --oneline <merge-base>..HEAD
```

## Step 5 — Push (only if the branch is already published)

Absorbing rewrites every commit from the earliest target onward, so a published branch
needs a force push:
```
git push --force-with-lease=<branch>:<sha-recorded-in-step-0.3> origin <branch>
```

Only do this if the branch is **published** and is a personal topic/PR branch. Apply
*Is this branch published?* and *Force-pushing safely* from `${CLAUDE_PLUGIN_ROOT}/lib/git-safety.md`
(read it with the **Read** tool): the test is the branch's own remote ref rather than `@{upstream}`,
and the push names an expected SHA plus the remote and refspec.

**Never** a bare `--force` — if the lease rejects, stop and report; someone else's work is on that
branch. If the branch was never pushed, do not push. That is the user's call.

## Step 6 — Report

State plainly:
- which hunks were absorbed into which commit,
- what was left in the working tree and why,
- whether a rebase conflict occurred,
- whether a force-push happened.

Show the final `git log --oneline <merge-base>..HEAD` and `git status --short`.

## Rules

- NEVER absorb into a commit outside `<merge-base>..HEAD`.
- NEVER absorb on the repository's default branch.
- NEVER target a merge commit.
- NEVER fall back to amending `HEAD` for changes you could not attribute — leave them.
- NEVER use interactive git flags that open an editor or prompt (`git add -p`, bare `rebase -i`).
- NEVER force-push except as *Force-pushing safely* in `lib/git-safety.md` describes.
- NEVER decide a branch is published from `@{upstream}`.
- NEVER skip hooks (`--no-verify`).
- Do not stage files that likely contain secrets.
- Commit messages are never reworded here; a fixup keeps the target's message. Use
  `/rewrite-branch` if the history itself needs restructuring.
