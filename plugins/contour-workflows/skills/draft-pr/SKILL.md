---
name: draft-pr
description: Open a draft pull request (GitHub) or draft merge request (GitLab) for the current branch. Does everything /create-pr does — pushes the branch, derives a changelog-quality title and a body shaped to the change — but opens it as a draft, for early CI runs and review feedback before the branch is ready to merge.
argument-hint: [base-branch]
allowed-tools: Bash(git:*), Bash(gh:*), Bash(glab:*), Read, Grep, Glob
---

# Draft Pull Request

Open a **draft** pull/merge request for the current branch against the base branch. Identical to
`/create-pr` except that the PR is marked as a draft — use it to get CI running and invite early
comments on work that is not ready to merge.

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

## Step 3 — Check for an existing PR/MR

Before pushing anything, check whether the branch already has one:

```
gh pr view --json url,state,isDraft 2>/dev/null        # GitHub
glab mr view --output json 2>/dev/null                 # GitLab (see "draft"/"work_in_progress")
```

- Already open **and a draft** → report its URL and stop. There is nothing to do.
- Already open and **not** a draft → report its URL and **stop**. Do not convert it: someone marked
  it ready deliberately. Tell the user they can undo that themselves with `gh pr ready <n> --undo`
  or `glab mr update <iid> --draft`, then re-run this skill if they want.
- Merged or closed → stop and say so.

## Step 4 — Push the branch

Apply *Pushing the branch*.

## Step 5 — Gather commit information

Apply *Gathering commit information*. If there are no commits ahead of the base, **stop** and tell
the user there is nothing to open a draft PR for.

## Step 6 — Check the changelog label

Apply *The changelog label rule*. A draft is still a real PR, so the rule applies unchanged: if the
branch does not touch the changelog, set an internal flag (e.g. `ADD_NO_CHANGELOG_LABEL=true`) so
Step 8 applies the label.

## Step 7 — Compose the PR

Apply *Composing the title and body*. Draft status is not a licence to skimp — the description is
what early reviewers read, and it carries over unchanged when the PR is marked ready.

Do not prefix the title with `Draft:`, `WIP:`, or similar. Both platforms track draft status as
real metadata, and `glab` adds its own `Draft:` prefix — a manual one would be duplicated and would
survive into the changelog after the PR is marked ready.

## Step 8 — Create the draft PR/MR

**GitHub:**

```
gh pr create --draft --base <base> --title "<title>" --body "$(cat <<'EOF'
<body>
EOF
)"
```

**GitLab:**

```
glab mr create --draft --target-branch <base> --title "<title>" --description "$(cat <<'EOF'
<body>
EOF
)" --yes
```

`--yes` skips the submission confirmation prompt; without it `glab` blocks waiting for input.
Passing `--description` explicitly is what keeps it from opening an editor.

If `ADD_NO_CHANGELOG_LABEL` is set (from Step 6), append `--label "no changelog"` — the flag spells
the same on both tools.

## Step 9 — Report

Output the draft PR/MR URL, and tell the user how to promote it when the branch is ready:

- **GitHub**: `gh pr ready <number>`
- **GitLab**: `glab mr update <iid> --ready`

## Rules

- Follow *Portability rules* from the conventions file — in particular: never force-push, and never
  modify source files. This skill only performs git operations (branch, commit, push) and PR
  creation.
- NEVER create a PR from `master` or `main` — if on main with uncommitted changes, create a feature
  branch first (Step 2).
- NEVER downgrade an existing ready PR to draft (Step 3). Report and stop instead.
- NEVER mark the PR ready — promoting a draft is the author's call.
- To open a normal, ready-for-review PR instead, use `/create-pr`.
