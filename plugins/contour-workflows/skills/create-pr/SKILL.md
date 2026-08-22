---
name: create-pr
description: Create a GitHub pull request or GitLab merge request for the current branch. Ensures the branch is pushed, derives a concise title and body from the commits, and opens the PR.
argument-hint: [base-branch]
allowed-tools: Bash(git:*), Bash(gh:*), Bash(glab:*), Read, Grep, Glob
---

# Create Pull Request

Open a pull/merge request for the current branch against the base branch.

## Step 0 — Load the conventions

Read `${CLAUDE_PLUGIN_ROOT}/lib/pr-conventions.md` with the **Read** tool before anything else.
It holds the shared procedure — platform detection, branch handling, the changelog label rule, and
the title/body composition rules — and the steps below cite its sections by heading rather than
restating them.

## Context

- Current branch: !`git branch --show-current`
- Repository remote: !`git remote get-url origin 2>/dev/null || echo "(no remote)"`

## Step 1 — Detect the platform

Apply *Platform detection*. Everything below uses `gh` or `glab` accordingly.

## Step 2 — Validate the branch and resolve the base

Apply *Branch validation*, then *Resolving the base branch*.

This skill's argument is `$ARGUMENTS` — if that is non-empty, it is the base branch. Pass it into
the resolution rule; the conventions file cannot read it itself.

## Step 3 — Push the branch

Apply *Pushing the branch*.

## Step 4 — Gather commit information

Apply *Gathering commit information*. If there are no commits ahead of the base, **stop** and tell
the user there is nothing to open a PR for.

## Step 5 — Check the changelog label

Apply *The changelog label rule*. Since this skill is opening a new PR, only the "should be
present" half can apply: if the branch does not touch the changelog, set an internal flag (e.g.
`ADD_NO_CHANGELOG_LABEL=true`) so Step 7 applies the label.

## Step 6 — Compose the PR

Apply *Composing the title and body*.

## Step 7 — Create the PR/MR

**GitHub:**

```
gh pr create --base <base> --title "<title>" --body "$(cat <<'EOF'
<body>
EOF
)"
```

**GitLab:**

```
glab mr create --target-branch <base> --title "<title>" --description "$(cat <<'EOF'
<body>
EOF
)" --yes
```

`--yes` skips the submission confirmation prompt; without it `glab` blocks waiting for input.
Passing `--description` explicitly is what keeps it from opening an editor.

If `ADD_NO_CHANGELOG_LABEL` is set (from Step 5), append `--label "no changelog"` — the flag spells
the same on both tools.

## Step 8 — Report

Output the PR/MR URL so the user can open it directly.

## Rules

- Follow *Portability rules* from the conventions file. They scope to the operations described
  there: this skill only performs git plumbing (branch, commit, push) and PR creation, and does
  neither a force-push nor a source edit while doing them. A caller that rebases its own branch
  before or after invoking this skill is not in breach — see `/rebase`.
- NEVER create a PR from `master` or `main` — if on main with uncommitted changes, create a feature
  branch first (Step 2).
- If a PR/MR already exists for this branch, inform the user and show the existing URL instead of
  creating a duplicate. Check with `gh pr view --json url 2>/dev/null` or
  `glab mr view --output json 2>/dev/null`.
- To open the PR as a draft instead, use `/draft-pr`.
