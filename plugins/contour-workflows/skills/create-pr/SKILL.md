---
name: create-pr
description: Create a GitHub pull request for the current branch. Ensures the branch is pushed, derives a concise title and body from the commits, and opens the PR.
argument-hint: [base-branch]
allowed-tools: Bash(git:*), Bash(gh:*), Read, Grep, Glob
---

# Create Pull Request

Create a GitHub pull request for the current branch against the base branch.

- If `$ARGUMENTS` is provided, use it as the base branch.
- Otherwise, resolve the repository's actual default branch:
  ```
  git symbolic-ref --short refs/remotes/origin/HEAD   # e.g. "origin/main" -> strip "origin/"
  ```
  If that ref is missing, run `git remote set-head origin -a` once and retry. Only if it
  still cannot be resolved, fall back to `main`, then `master`.

## Context

- Current branch: !`git branch --show-current`
- Repository remote: !`git remote get-url origin 2>/dev/null || echo "(no remote)"`

## Step 1 — Validate branch

1. Determine the current branch name.
2. If on `master` or `main` **and** there are uncommitted or untracked changes (check `git status --porcelain`):
   a. Analyze the pending changes (`git diff HEAD`, `git ls-files --others --exclude-standard`) to understand what they do.
   b. Derive a short, descriptive branch name from the changes (e.g., `fix/ghost-text-flicker`, `feature/add-auth-endpoint`). Use `fix/` or `feature/` prefix as appropriate.
   c. Create and switch to the new branch: `git checkout -b <branch-name>`.
   d. Stage and commit the changes following the repository's commit style (see recent `git log --oneline -10`). Group into semantic commits if the changes are logically distinct. Commit with `git commit -s` so the `Signed-off-by:` trailer is derived from the committer's own git config — never hardcode a name.
   e. Continue to Step 2.
3. If on `master` or `main` **without** uncommitted changes, **stop** and tell the user: PRs should be created from a feature/fix branch, not from the main branch.
4. Determine the base branch (from `$ARGUMENTS` or the default).
5. Verify the base branch exists on the remote: `git ls-remote --heads origin <base>`. If not, stop and inform the user.

## Step 2 — Push the branch

1. Check if the current branch has a remote tracking branch: `git rev-parse --abbrev-ref @{upstream} 2>/dev/null`.
2. If not, or if the local branch is ahead of the remote, push:
   ```
   git push -u origin HEAD
   ```
3. Verify the push succeeded.

## Step 3 — Gather commit information

1. Fetch the commit log between the base branch and HEAD:
   ```
   git log --oneline origin/<base>..HEAD
   ```
2. Fetch the full diff stat:
   ```
   git diff --stat origin/<base>..HEAD
   ```
3. If there are no commits ahead of the base, **stop** and tell the user there is nothing to open a PR for.

## Step 4 — Check for a "no changelog" label

This step applies only to repositories that both track a changelog file and define a
`no changelog` label. Detect this rather than assuming it:

1. Determine whether the repository tracks a changelog. Look, in priority order, for an
   AppStream `metainfo.xml` / `*.appdata.xml`, then `CHANGELOG.md`, then `NEWS`:
   ```
   git ls-files '**/metainfo.xml' '**/*.appdata.xml' 'CHANGELOG.md' 'NEWS'
   ```
   If none exist, **skip this step entirely**.
2. Confirm the label exists in the repository:
   ```
   gh label list --search "no changelog" --json name
   ```
   If it does not exist, skip — do not create labels.
3. Check whether the branch touched the changelog file found in (1):
   ```
   git diff --name-only origin/<base>..HEAD -- <changelog-path>
   ```
4. If it was **not** modified, the change either does not warrant an entry (e.g. it fixes
   something introduced after the latest release) or the author intentionally omitted it.
   Set an internal flag (e.g. `ADD_NO_CHANGELOG_LABEL=true`) so Step 6 applies the label.

## Step 5 — Compose the PR

Derive a PR title and body from the commits and diff. Let the shape of the body follow the shape of the change — do not force every PR into the same template.

- **Title**: Short (under 72 characters) and written so it reads well in GitHub's auto-generated release changelog. A reader scanning the changelog should immediately understand *what changed* from the title alone.
  - Start with a capitalized imperative verb that conveys the kind of change: `Add`, `Fix`, `Remove`, `Improve`, `Update`, `Rename`, `Refactor`, `Document`, `Deprecate`, `Revert`, etc.
  - Describe the user-visible outcome, not the internal mechanism. Prefer "Fix ghost-text flicker on resize" over "Adjust repaint timing in Renderer::draw".
  - Avoid vague verbs alone (`Update code`, `Changes`, `Misc fixes`) — they are useless in a changelog.
  - No trailing period, no ticket prefix (`Fixes #123` belongs in the body), no conventional-commit prefix (`feat:`, `fix:`) unless the repository's existing PR history uses them.
  - If there is a single commit and its subject already meets these rules, reuse it. Otherwise synthesize a new title from the overall change.
- **Body**: Choose the form that fits the change:
  - **Small / focused change**: one or two sentences (a short paragraph) describing what changed and why. No headings, no bullet lists — prose is fine.
  - **Medium change**: a short paragraph, optionally followed by a few bullets if there are distinct points worth calling out.
  - **Larger branch (multiple commits, several concerns)**: open with a goal paragraph (no heading) describing why this PR exists — the problem it solves, the motivation, the user-visible outcome — then a `## Changes` section:

    ```
    <goal paragraph — plain prose, no heading>

    ## Changes

    <bullet list of the meaningful changes, grouped logically>
    ```

Guidelines:
- Write from the reviewer's perspective — what do they need to know to understand and judge the change?
- Reference GitHub issue numbers where relevant (e.g., `Fixes #123`).
- Do not pad with boilerplate. If the change is trivial, the body can be a single sentence.
- **Never** include a "Testing" / "Test plan" / "How to test" / "Manual verification" section. Correctness is covered by unit tests in the diff; any manual verification steps belong in a direct message to the user, not in the PR description.
- Do not list files touched, line counts, or other information a reviewer can read from the diff.

## Step 6 — Create the PR

Create the PR using `gh`:

```
gh pr create --base <base> --title "<title>" --body "$(cat <<'EOF'
<body>
EOF
)"
```

If `ADD_NO_CHANGELOG_LABEL` is set (from Step 4), append `--label "no changelog"` to the `gh pr create` command.

## Step 7 — Report

Output the PR URL so the user can open it directly.

## Rules

- NEVER force-push.
- NEVER create a PR from `master` or `main` — if on main with uncommitted changes, create a feature branch first (Step 1).
- NEVER modify source files — this skill only performs git operations (branch, commit, push) and PR creation.
- If a PR already exists for this branch, inform the user and show the existing PR URL instead of creating a duplicate. Check with: `gh pr view --json url 2>/dev/null`.
