---
name: update-pr
description: Refresh an existing pull/merge request's title, description, and labels to match what the branch actually contains now. Use after a branch has moved on from the PR that describes it — new commits, dropped work, scope changes during review.
argument-hint: "[pr-number-or-url]"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(glab:*), Read, Grep, Glob
---

# Update Pull Request

Re-derive a PR/MR's title, body, and labels from the branch's *current* commits, and apply
only what genuinely changed.

## Context

- Current branch: !`git branch --show-current`
- Repository remote: !`git remote get-url origin 2>/dev/null || echo "(no remote)"`

## Step 1 — Detect the platform

Extract the **host** from the remote URL (handle both `git@host:owner/repo.git` and
`https://host/owner/repo.git` forms). Do not match on the literal string `gitlab.com` —
most GitLab deployments are self-hosted under an unrelated hostname:

1. If the host is `github.com` → use `gh`.
2. Otherwise probe, in order, and use whichever succeeds:
   ```
   gh repo view --json nameWithOwner 2>/dev/null     # GitHub (incl. Enterprise)
   glab repo view 2>/dev/null                        # GitLab (incl. self-hosted)
   ```
3. If neither succeeds, report which probe failed and stop rather than guessing.

## Step 2 — Locate the PR/MR and read its current state

- If `$ARGUMENTS` is given, use it as the PR/MR number or URL.
- Otherwise find the one for the current branch:
  - **GitHub**: `gh pr view --json number,url,title,body,labels,baseRefName,state`
  - **GitLab**: `glab mr view --output json`

If none is found, **stop** and suggest `/create-pr` instead. If the PR is merged or closed,
**stop** — there is nothing useful to update.

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

Derive a title and body from the *current* commits, using the same rules `/create-pr` uses:

- **Title**: under 72 characters, capitalized imperative verb (`Add`, `Fix`, `Remove`,
  `Improve`, `Refactor`, …), describing the user-visible outcome rather than the internal
  mechanism. No trailing period, no ticket prefix, no `feat:`/`fix:` prefix unless the
  repository's PR history uses them. If a single commit's subject already satisfies this,
  reuse it.
- **Body**: let the shape follow the change — a sentence or two for a focused change; a
  goal paragraph plus a `## Changes` bullet list for a larger branch.
- **Never** add a "Testing" / "Test plan" / "How to test" section.
- Do not list touched files or line counts.

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

Only adjust labels the skill can justify from the diff:

1. Fetch available labels: `gh label list --json name` (GitHub) / `glab label list` (GitLab).
2. **Changelog label**: if the repository tracks a changelog (`metainfo.xml`,
   `*.appdata.xml`, `CHANGELOG.md`, or `NEWS`) and defines a `no changelog` label:
   - branch does *not* touch the changelog → the label should be present;
   - branch *does* touch it → the label should be removed if previously applied.
3. **Never remove labels this skill did not add.** Triage labels (`bug`, `enhancement`,
   `good first issue`), release/milestone markers, and priority labels are set by humans
   and must be left untouched.
4. Never create new labels.

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

- NEVER modify source files — this skill only reads git state and edits PR metadata.
- NEVER push, commit, or otherwise alter the branch.
- NEVER discard hand-written description content that the branch has not invalidated.
- NEVER touch labels unrelated to the changelog rule.
- NEVER create labels that do not already exist.
- If the PR is closed or merged, stop.
