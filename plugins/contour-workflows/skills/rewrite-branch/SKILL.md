---
name: rewrite-branch
description: Rewrite the current branch history by analyzing the full diff against the base branch, grouping changes into semantic units, and recreating one clean commit per group. Use when a branch has messy or WIP commits that need to be reorganized into a clean, logical history.
argument-hint: [base-branch]
allowed-tools: Bash(git:*), Read, Grep, Glob
---

# Rewrite Branch History

Analyze the entire diff of the current branch against its base, group all changes into
semantic units, and rebuild the branch history with one atomic commit per group.

## Context

- Current branch: !`git branch --show-current`
- Git status (must be clean): !`git status --short`
- Base branch argument: use the argument if provided, otherwise resolve the repository's
  actual default branch via `git symbolic-ref --short refs/remotes/origin/HEAD` (strip the
  `origin/` prefix), falling back to `main`, then `master`
- Recent commit style on the branch: !`git log --oneline -20`

## Workflow

### Step 0 — Pre-flight checks

1. **Refuse to run on `main` or `master`.**  If the current branch is `main` or `master`,
   stop immediately and tell the user this skill only works on feature/topic branches.

2. **Working tree must be clean.**  If `git status --short` shows any output (staged,
   unstaged, or untracked changes that are tracked), stop and ask the user to commit or
   stash their changes first.

3. **Determine the base branch.**  Use the argument supplied by the user.  If no argument
   was given, resolve the repository's default branch with
   `git symbolic-ref --short refs/remotes/origin/HEAD` and strip the `origin/` prefix;
   only if that fails, try `main`, then `master`.  Confirm the base exists
   with `git rev-parse --verify <base> 2>/dev/null`.

4. **Find the merge base:**
   ```
   MERGE_BASE=$(git merge-base <base-branch> HEAD)
   ```

5. **Require at least one commit** beyond the merge base.  If `git rev-list
   $MERGE_BASE..HEAD --count` is `0`, stop and report there is nothing to rewrite.

### Step 1 — Gather the full picture

Collect the complete diff between the merge base and HEAD:

```
git diff $MERGE_BASE..HEAD
```

Also list all files changed:

```
git diff --stat $MERGE_BASE..HEAD
```

And list the current commits on the branch:

```
git log --oneline $MERGE_BASE..HEAD
```

Read individual files when the diff alone is insufficient to understand the intent of a
change.

### Step 2 — Group changes into semantic units

Partition **all** changes (across every commit on the branch) into the smallest meaningful
groups where each group represents a single logical change.  Ignore the existing commit
boundaries — treat the branch as one large changeset.

Guidelines for grouping (same conventions as `/commit`):

- A bug fix and its corresponding test belong in the same group.
- A new feature and its tests belong in the same group.
- A pure refactor (no behavior change) is its own group.
- Documentation-only changes are their own group.
- Build system or CI configuration changes are their own group.
- Renames or moves are their own group.
- Formatting-only changes are their own group.
- Infrastructure or scaffolding that later groups depend on should come first.
- If a single file contains changes belonging to multiple groups, note which hunks belong
  to which group so they can be staged separately.

Present the proposed grouping to the user as a numbered list, showing:
- Which files (and which hunks within files, if split) belong to each group.
- A draft commit message for each group.
- The order in which the groups will be committed (foundational changes first).

**Wait for user confirmation before proceeding.**  The user may ask to merge groups, split
groups, reorder, or adjust commit messages.

### Step 3 — Save a backup ref

Before rewriting, create a backup reference so the user can recover the original history:

```
git branch backup/<branch-name>-pre-rewrite
```

If that branch name already exists, append a numeric suffix (e.g., `-2`, `-3`).

Tell the user about the backup branch.

### Step 4 — Reset to merge base

Soft-reset the branch to the merge base so all changes become unstaged:

```
git reset --soft $MERGE_BASE
git reset HEAD
```

The first command moves HEAD to the merge base while keeping all changes staged.
The second un-stages everything so we can selectively re-stage per group.

### Step 5 — Re-commit each group

For each semantic group, in the order determined in Step 2:

1. **Stage exactly the files/hunks for this group**: use `git add <file>...` for whole
   files, or `git add -p` techniques (non-interactive hunk selection) for partial files.
2. **Commit** with the agreed-upon message, following the style of recent commits in the
   repository.  Pass `-s` so git appends a `Signed-off-by:` trailer derived from the
   committer's own `user.name` / `user.email` — never hardcode a name.

   Avoid commit message prefixes like feat, fix, docs, etc.
   Use the project module area as prefix instead, if applicable (e.g., "auth:", "db:",
   "ci:", "build:", etc.).

   Use a HEREDOC to pass the commit message:
   ```
   git commit -s -m "$(cat <<'EOF'
   <summary line>

   <optional body>
   EOF
   )"
   ```

3. **Verify** the commit was created: `git log --oneline -1`.

### Step 6 — Final verification

After all groups are committed:

1. Run `git status` to confirm the working tree is clean.
2. Run `git log --oneline $MERGE_BASE..HEAD` to show the new history.
3. Run `git diff backup/<branch-name>-pre-rewrite..HEAD` to verify the **net result is
   identical** to the original branch.  If the diff is empty, the rewrite is correct.  If
   it is not empty, **stop and report the discrepancy** — do not silently proceed.
4. Summarize what was done: number of original commits, number of new commits, and the
   backup branch name in case the user wants to restore.

## Rules

- NEVER use interactive git flags (`-i`, `--interactive`).
- NEVER amend existing commits (each group gets a fresh commit).
- NEVER push to a remote.
- NEVER skip pre-commit hooks (`--no-verify`).
- NEVER delete the backup branch — the user decides when to remove it.
- NEVER operate on `main` or `master`.
- If a pre-commit hook fails, fix the issue, re-stage, and create a NEW commit.
- Do not commit files that likely contain secrets (`.env`, credentials, tokens).
- Prefer staging specific files by name over `git add -A` or `git add .`.
- If the final diff verification shows a discrepancy, attempt to fix it.  If you cannot,
  restore the original branch from the backup and report the failure.
- If anything goes wrong mid-rewrite, restore from backup:
  ```
  git reset --hard backup/<branch-name>-pre-rewrite
  ```
  and report the error to the user.
