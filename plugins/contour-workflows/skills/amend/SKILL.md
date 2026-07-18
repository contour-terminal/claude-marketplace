---
name: amend
description: Fold the current working-tree changes into the most recent commit, optionally rewording its message. Use when a follow-up edit belongs to the commit you just made rather than in a new commit — typo fixes, review tweaks, a forgotten file. Refuses to rewrite history that others may have built on.
argument-hint: "[new commit message]"
allowed-tools: Bash(git:*), Read, Grep, Glob
---

# Amend

Fold the pending changes into `HEAD` instead of creating a new commit.

## Context

- Current branch: !`git branch --show-current`
- Git status: !`git status --short`
- Full diff of all changes: !`git diff HEAD`
- Untracked files: !`git ls-files --others --exclude-standard`
- Commit to be amended: !`git log -1 --format='%H%n%s%n%n%b'`
- Upstream tracking state: !`git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo "(no upstream)"`

## Step 1 — Safety check

Amending rewrites history. Decide whether that is safe **before** touching anything.

1. **Nothing to do?** If there are no staged, unstaged, or untracked changes *and*
   `$ARGUMENTS` is empty, report that there is nothing to amend and stop.

2. **Is `HEAD` already published?** Check whether the commit exists on the upstream branch:
   ```
   git branch -r --contains HEAD
   ```
   - **Not on any remote** → safe. Proceed.
   - **On the remote, but the branch is a personal topic/PR branch** → proceed, but the
     push in Step 5 must use `--force-with-lease`.
   - **On the remote, and the branch is the repository's default branch** (resolve via
     `git symbolic-ref --short refs/remotes/origin/HEAD`) → **stop**. Never rewrite the
     shared mainline. Tell the user to make a normal commit instead.

3. **Is `HEAD` a merge commit?** (`git rev-parse HEAD^2` succeeds) → stop and explain that
   amending a merge is error-prone; a new commit is the right move.

4. **Is `HEAD` someone else's commit?** Compare `git log -1 --format='%ae'` against
   `git config user.email`. If they differ, warn the user and ask before continuing —
   amending rewrites the authorship metadata of a commit they did not write.

## Step 2 — Confirm the changes belong to that commit

Read the diff above and the message of `HEAD`. Amending is correct when the pending changes
*complete or correct* the existing commit. It is the wrong tool when they are a logically
separate change.

If the pending changes look like a distinct semantic unit (e.g. `HEAD` is a bug fix and the
new changes add an unrelated feature), say so and recommend `/commit` instead. Do not amend
just because you were asked to — say what you observed, then let the user decide.

If the changes span *both* — some belong to `HEAD`, some do not — stage only the belonging
subset with `git add <path>`, amend those, and report clearly which changes were left in the
working tree.

## Step 3 — Stage

Stage the changes that belong to the commit:
```
git add <path>...
```
Prefer naming paths explicitly over `git add -A`. Include relevant untracked files, but
never stage files that look like they carry secrets (`.env`, `*.key`, `*.pem`, credentials).

## Step 4 — Amend

- **Keep the existing message** (no `$ARGUMENTS`):
  ```
  git commit --amend --no-edit
  ```

- **Reword** (with `$ARGUMENTS`, or when the original message no longer describes the
  commit's content after folding in these changes): pass `-s` so the `Signed-off-by:`
  trailer is derived from the committer's own git config, and follow the repository's
  existing message conventions (`git log --oneline -10`). Avoid `feat:`/`fix:` prefixes;
  use the module area instead (`vtbackend:`, `ci:`, `build:`).
  ```
  git commit -s --amend -m "$(cat <<'EOF'
  <summary line>

  <optional body>
  EOF
  )"
  ```

If a pre-commit hook fails, fix the issue, re-stage, and amend again. Never pass
`--no-verify`.

## Step 5 — Push (only if already published)

If Step 1 found the commit on the remote and the branch is a personal topic branch:
```
git push --force-with-lease
```

`--force-with-lease` aborts if someone else pushed in the meantime. **Never** use a bare
`--force`. If the lease check rejects the push, stop and report it — do not retry with
`--force`; someone else's work is on that branch.

If the commit was never pushed, do not push at all. That is the user's call.

## Step 6 — Report

Show the resulting commit (`git log -1 --stat`) and state plainly:
- what was folded in,
- whether the message changed,
- whether a force-push happened,
- anything intentionally left in the working tree.

## Rules

- NEVER amend on the repository's default branch when the commit is already pushed.
- NEVER use bare `git push --force` — always `--force-with-lease`.
- NEVER skip hooks (`--no-verify`).
- NEVER amend a merge commit.
- If the pending changes are a separate semantic unit, recommend `/commit` instead.
- Do not stage files that likely contain secrets.
