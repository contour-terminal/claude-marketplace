---
name: commit
description: Commit the current changes by grouping them into semantic units and creating one commit per group. This skill should be used when users want to commit their work with well-organized, atomic commits.
allowed-tools: Bash(git:*), Read, Grep, Glob
---

# Semantic Commit

Create atomic, well-organized git commits by analyzing all pending changes, grouping them
into semantic units, and committing each group individually.

## Context

- Current branch: !`git branch --show-current`
- Git status: !`git status`
- Full diff of all changes (staged and unstaged): !`git diff HEAD`
- Untracked files: !`git ls-files --others --exclude-standard`
- Recent commit style: !`git log --oneline -10`

## Workflow

### Step 1 — Analyze all changes

Examine the full diff and untracked files above. For each changed or new file, understand
the *purpose* of the change: is it a bug fix, a new feature, a refactor, a test addition,
a documentation update, a build/config change, a rename, etc.?

Read individual files when the diff alone is insufficient to understand the intent.

### Step 2 — Group changes into semantic units

Partition all changes into the smallest meaningful groups where each group represents a
single logical change. Guidelines for grouping:

- A bug fix and its corresponding test belong in the same group.
- A new feature and its tests belong in the same group.
- A pure refactor (no behavior change) is its own group.
- Documentation-only changes are their own group.
- Build system or CI configuration changes are their own group.
- Renames or moves are their own group.
- Formatting-only changes are their own group.
- If a file contains changes that belong to multiple semantic groups, use `git add -p` (with
  non-interactive hunk selection via individual `git add` of specific files or line-based
  staging strategies) to stage only the relevant hunks.

Present the proposed grouping to the user as a numbered list, showing which files (and
which changes within files) belong to each group, along with a draft commit message for
each. Then proceed without waiting for confirmation.

### Step 3 — Commit each group

For each semantic group, in logical order (foundational changes first):

1. **Reset the staging area**: `git reset HEAD` (only if anything is currently staged and
   does not belong to this group).
2. **Stage exactly the files/hunks for this group**: use `git add <file>...` for whole
   files, or `git add -p` techniques for partial files.
3. **Commit** with a concise, descriptive message following the style of recent commits in
   the repository. Pass `-s` so git appends a `Signed-off-by:` trailer derived from the
   committer's own `user.name` / `user.email` — never hardcode a name.

   Avoid commit message prefixes like feat, fix, docs, etc.
   Use the project module area as prefix instead, if applicable (e.g., "auth:", "db:", "ci:", "build:", etc.).

   Use a HEREDOC to pass the commit message:
   ```
   git commit -s -m "$(cat <<'EOF'
   <summary line>

   <optional body>
   EOF
   )"
   ```

   If the harness is configured with a commit attribution trailer, it is appended
   automatically — do not write one into the message body yourself.

4. **Verify** the commit was created: `git log --oneline -1`.

### Step 4 — Final verification

After all groups are committed, run `git status` to confirm the working tree is clean (or
that only intentionally untracked files remain). Run `git log --oneline -<N>` (where N is
the number of commits just created) to show the user the resulting commit history.

## Rules

- NEVER use interactive git flags (`-i`, `--interactive`).
- NEVER amend existing commits.
- NEVER push to a remote.
- NEVER skip pre-commit hooks (`--no-verify`).
- If a pre-commit hook fails, fix the issue, re-stage, and create a NEW commit.
- Do not commit files that likely contain secrets (`.env`, credentials, tokens).
- Prefer staging specific files by name over `git add -A` or `git add .`.
- If there are no changes to commit, report that and stop.
