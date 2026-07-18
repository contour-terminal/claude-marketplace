---
name: add-release-note
description: Add release note entries to the project's metainfo.xml (or changelog) for the changes on the current branch.
argument-hint: [base-branch]
allowed-tools: Bash(git:*), Read, Grep, Glob, Edit
---

# Add Release Note

Add release note entries for the changes on the current branch.

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

## Step 1 — Locate the release notes file

1. Search the project root for common release note files in this priority order:
   - `metainfo.xml` or `*.metainfo.xml` or `*.appdata.xml` (AppStream format)
   - `CHANGELOG.md` or `CHANGES.md`
   - `NEWS` or `NEWS.md`
2. If no file is found, **stop** and ask the user which file to use.
3. Read the release notes file to understand its structure and the style of existing entries.

## Step 2 — Gather branch changes

1. Determine the base branch (from `$ARGUMENTS` or the default).
2. Fetch the commit log:
   ```
   git log --oneline $(git merge-base <base> HEAD)..HEAD
   ```
3. Fetch the full diff for understanding the changes:
   ```
   git diff $(git merge-base <base> HEAD)..HEAD
   ```
4. If there are no commits ahead of the base, **stop** and tell the user there are no changes to document.

## Step 3 — Analyze changes and draft entries

Study the diff and commits carefully to understand what changed. Then draft release note entries following these rules:

### Style rules (derived from the existing entries)

- Read the existing release note entries in the file and **match their style exactly**.
- For AppStream `metainfo.xml` files, entries are `<li>` items inside a `<ul>` within a `<release><description>` block.
- Use the established prefixes from existing entries. Common patterns:
  - **Fixes ...** — for bug fixes (e.g., "Fixes Home/End key encoding in Kitty keyboard protocol")
  - **Adds ...** — for new features (e.g., "Adds DECNKM (DEC mode 66, VT320) to toggle numeric keypad")
  - **Improves ...** / **Improve ...** — for enhancements to existing features
  - **Replaces ...** — for replacements of existing behavior
  - **Changes ...** — for behavior changes
  - **Removes ...** — for removed features
  - **Security: ...** — for security-related fixes
- Each entry should be a single concise sentence. No trailing period unless the existing entries use one.
- Reference GitHub issue numbers where the commit messages mention them (e.g., `(#1234)`).
- Do **not** include internal/refactoring changes that have no user-visible effect unless they are significant architectural changes.
- Do **not** duplicate information — if multiple commits relate to the same logical change, combine them into one entry.

### Grouping

Order entries logically:
1. Security fixes first (if any)
2. Bug fixes
3. Improvements / changes to existing features
4. New features
5. Removals / deprecations

## Step 4 — Insert the entries

### For AppStream metainfo.xml

1. Look for the **first** (topmost) `<release>` element in the `<releases>` section. This is the current/unreleased version.
2. If there is a commented-out unreleased release template, uncomment it and use it. Set an appropriate version placeholder if needed.
3. If the first release already has entries, **prepend** the new entries to the existing `<ul>` list (new entries go at the top of the list within the release, before any existing entries).
4. If there is no unreleased release block, insert a new one **before** the first existing release, using the same XML structure as existing releases. Use a placeholder version like `x.y.z` and omit the `date` attribute.

### For Markdown changelogs

1. Look for an "Unreleased" section. If it exists, add entries there.
2. If there is no "Unreleased" section, create one at the top of the changelog.
3. Follow the existing markdown formatting and bullet style.

## Step 5 — Present the result

1. Show the user the entries that were added, formatted clearly.
2. Remind the user to review the entries and adjust wording if needed.
3. Do **not** commit the changes — leave that to the user.

## Rules

- NEVER remove or modify existing release note entries.
- NEVER commit or push changes.
- NEVER fabricate changes — only document what the diff actually shows.
- Match the existing file's indentation and formatting exactly.
- If a change is ambiguous or hard to summarize, note it and ask the user for guidance rather than guessing.
