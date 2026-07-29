---
name: update-pr
description: Refresh an existing pull/merge request's title, description, and labels to match what the branch actually contains now. Use after a branch has moved on from the PR that describes it — new commits, dropped work, scope changes during review.
argument-hint: "[pr-number-or-url]"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(glab:*), Read, Grep, Glob
---

# Update Pull Request

Re-derive a PR/MR's title, body, and labels from the branch's *current* commits, and apply
only what genuinely changed.

## Step 0 — Load the conventions

Read `${CLAUDE_PLUGIN_ROOT}/lib/pr-conventions.md` with the **Read** tool before anything else.
It holds the procedure this skill shares with `/create-pr` and `/draft-pr` — platform detection,
the changelog label rule, and the title/body composition rules — and the steps below cite its
sections by heading rather than restating them.

## Context

- Current branch: !`git branch --show-current`
- Repository remote: !`git remote get-url origin 2>/dev/null || echo "(no remote)"`

## Step 1 — Detect the platform

Apply *Platform detection*. Everything below uses `gh` or `glab` accordingly.

## Step 2 — Locate the PR/MR and read its current state

- If `$ARGUMENTS` is given, use it as the PR/MR number or URL.
- Otherwise find the one for the current branch:
  - **GitHub**: `gh pr view --json number,url,title,body,labels,baseRefName,state`
  - **GitLab**: `glab mr view --output json`

If none is found, **stop** and suggest `/create-pr` — or `/draft-pr`, if the branch is not ready
for review yet. If the PR is merged or closed, **stop** — there is nothing useful to update.

Record the existing title, body, labels, and base branch. The base branch comes from the
PR itself; do not re-derive it.

## Step 3 — Gather what the branch contains now

```
git fetch origin <base>
git log --oneline origin/<base>..HEAD
git diff --stat origin/<base>..HEAD
```

If there are no commits ahead of the base, **stop** and report it — the branch may have
already been merged or reset.

## Step 4 — Compose the updated title and body

Derive a title and body from the *current* commits by applying *Composing the title and body* —
the same rules `/create-pr` and `/draft-pr` use, so a description does not change character just
because it was rewritten rather than written.

One addition specific to updating: if the PR is a draft, leave it a draft. Marking it ready is the
author's call, not this skill's.

### Preserving human edits — important

The description may contain text a person wrote by hand. Treat the existing body as
authoritative unless the branch contradicts it:

- **Preserve** sections that are clearly hand-authored and still accurate: review notes,
  screenshots, `Fixes #123` references, discussion links, checklists, deployment caveats.
- **Preserve** any `<!-- comment -->` blocks and template scaffolding from the repository's
  PR template.
- **Rewrite** only the parts that the branch has outgrown — a summary that describes work
  no longer present, a changes list missing recent commits.
- If the existing body was clearly written by a person and still describes the branch
  accurately, **leave it alone** and say so. An unchanged good description is a valid
  outcome; do not churn it to look busy.

## Step 5 — Recompute labels

Only adjust labels the skill can justify from the diff. Apply *The changelog label rule* — both
halves of it are live here, since an existing PR may already carry the label:

- branch does *not* touch the changelog → the label should be present;
- branch *does* touch it → the label should be removed if previously applied.

Its guards are what matter most in an update: **never remove labels this skill did not add**
(triage labels like `bug`, `enhancement`, `good first issue`, plus release/milestone markers and
priority labels are set by humans and must be left untouched), and never create new labels.

## Step 6 — Show the delta, then apply

Present a before/after comparison of exactly what will change:

```
Title:   <unchanged>  |  "<old>" -> "<new>"
Body:    <unchanged>  |  <n> section(s) rewritten, <m> preserved
Labels:  +no changelog  -none
```

If nothing changed, report that and stop without calling the API.

Otherwise apply:
- **GitHub**: `gh pr edit <number> --title "<title>" --body "$(cat <<'EOF' … EOF)"`,
  plus `--add-label` / `--remove-label` as needed.
- **GitLab**: `glab mr update <iid> --title "<title>" --description "…"`,
  plus `--label` / `--unlabel`.

Pass only the flags for fields that actually changed.

## Step 7 — Report

Output the PR/MR URL and a one-line summary of what was updated.

## Rules

- Follow *Portability rules* from the conventions file.
- NEVER modify source files — this skill only reads git state and edits PR metadata.
- NEVER push, commit, or otherwise alter the branch.
- NEVER change a PR's draft status in either direction.
- NEVER discard hand-written description content that the branch has not invalidated.
- NEVER touch labels unrelated to the changelog rule.
- NEVER create labels that do not already exist.
- If the PR is closed or merged, stop.
