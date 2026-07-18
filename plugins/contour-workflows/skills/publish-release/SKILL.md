---
name: publish-release
description: Verify a drafted release and publish it — refuses until CI is fully green and
  every expected artifact is attached, then publishes, marks it latest, and opens the next
  development cycle in the changelog. Use after /draft-release, once CI has run.
argument-hint: "[version-or-tag]"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(bash:*), Bash(date:*), Bash(xmllint:*), Read, Grep, Glob, Edit
---

# Publish Release

Turn a drafted release into a published one — but only once it has earned it.

The whole point of the draft stage is that a half-built release is indistinguishable from a
good one until you check. A missing `.msi` or a silently skipped build job produces a release
page that looks complete and leaves a platform's users with nothing. So this skill is
structured as a gate: it verifies first, publishes second, and treats every ambiguity as a
reason to stop rather than proceed.

- If `$ARGUMENTS` is provided, use it to select the release (accept `1.2.3`, `v1.2.3`, or a
  full tag).
- Otherwise, find the draft releases and pick the only one. If there are several, list them
  and ask.

## Context

- Current branch: !`git branch --show-current`
- Repository remote: !`git remote get-url origin 2>/dev/null || echo "(no remote)"`
- Draft releases: !`gh release list --limit 20 2>/dev/null | grep -i draft || echo "(none)"`

## Step 1 — Resolve the release and the model

1. Detect the release model:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/lib/release-model.sh"
   ```
2. Identify the target draft:
   ```
   gh release view <tag> --json tagName,isDraft,isPrerelease,body,assets,createdAt,targetCommitish
   ```
   `isLatest` is **not** a valid field for `gh release view` — asking for it makes the whole
   command fail with `Unknown JSON field`. It only exists on `gh release list`, and it would
   be useless here regardless: a draft is never the latest release, so it is always false.
   See Step 5 for how to find the current latest.
3. If the release is not a draft, it is already published — **stop** and say so. Do not
   re-publish or re-tag.

## Step 2 — Assert CI is fully green

Find the workflow run that produced this release — match on the tag, or on the release branch
for the `release-branch-pr` model:

```
gh run list --limit 20 --json databaseId,headBranch,headSha,status,conclusion,workflowName
gh run view <run-id> --json jobs --jq '.jobs[] | {name, status, conclusion}'
```

Then judge it job by job, not by the run's summary conclusion:

- Every job must have `conclusion: "success"`.
- `failure`, `cancelled`, `timed_out`, and `action_required` all **block**.
- A `skipped` job blocks too, unless it is skipped by a condition that genuinely does not
  apply to this release. Say which job was skipped and why you accepted it — never wave one
  through silently.
- If the run is still `in_progress` or `queued`, **wait** rather than failing. Poll every 60
  seconds and report progress. A release that is merely not finished yet is not a failure.

If anything failed, show the failing job's log tail, explain the cause, and **stop**. Suggest
`/fix-ci` for diagnosing it.

### The stale-date failure

For the `metainfo` model, a release check validates that the release date equals the day the
build runs. A release prepared yesterday fails today with a date mismatch. If you see that
specific failure, offer to move the date forward to today, amend, and re-push the release
branch with `--force-with-lease` — then wait for the new run.

## Step 3 — Assert every artifact is attached

Read the actual asset list:

```
gh release view <tag> --json assets --jq '.assets[] | {name, size, state}'
```

Establish what *should* be there, in this order of preference:

1. `artifacts` from the detected model, when non-empty — these are the globs the release
   workflow declares.
2. Otherwise, the previous release's asset set. Fetch it
   (`gh release view <previous-tag> --json assets`), replace the version string in each name
   with a wildcard, and require the same shapes this time. This is self-maintaining: it
   notices a platform that used to ship and no longer does.
3. If there is no previous release either, you cannot know what is expected. Say so plainly,
   list what is present, and ask the user to confirm the set is complete.

Then check:

- Every expected pattern matches at least one asset. A missing pattern **blocks**.
- No asset has a zero size or a `state` other than `uploaded` — a partially uploaded asset is
  worse than an absent one, because it looks fine.
- If the workflow generates a checksum file, it is present and lists every other asset.

Report the comparison as a table of expected vs. found. If anything is missing, **stop** and
name the platform that would be left without a download.

## Step 4 — Sanity checks

- The release body is non-empty. An empty body means the notes generation failed.
- The tag matches the intended version, and for the `pinned` model the tag agrees with the
  committed version file.
- For `release-branch-pr`, the release pull request is **merged**. Publishing a release whose
  changes never landed on the default branch leaves the tag pointing at work that is not in
  the mainline.

## Step 5 — Publish

Show the user a summary — tag, title, asset count, and whether it will become the latest
release — and get explicit confirmation. Publishing is public and effectively irreversible.

To say what `--latest` would displace, read the current latest release. This is the one place
`isLatest` is available, and it is only valid on `release list`, never on `release view`:

```
gh release list --json tagName,isLatest --jq '.[] | select(.isLatest) | .tagName'
```

An empty result means this is the project's first published release, so it becomes latest
unconditionally.

```
gh release edit <tag> --draft=false --latest
```

Omit `--latest` if the user is publishing an older patch release that should not displace a
newer one, or if the release is a prerelease.

## Step 6 — Open the next development cycle

A released changelog section has no room for the next PR's entry, so the first contributor
after a release has nowhere to write. Prepare that space now, while the context is fresh.

Ask the user which version comes next. Propose the obvious patch bump from the version just
published, but let them choose a minor or major instead — they know what is planned.

Then, **on the default branch** (check it out and pull first — a `release-branch-pr` flow
leaves you on the release branch):

**`metainfo`** — insert a fresh development block directly above the release just published,
matching the file's existing indentation:

```xml
    <release version="<next>" urgency="medium" type="development">
      <description>
        <ul>

        </ul>
      </description>
    </release>
```

**Markdown changelogs** — add an `Unreleased` (or next-version) section at the top, following
the heading style already used in the file.

**No changelog** — there is nothing to stub. Say so, and mention that release notes for this
project come from GitHub's generated commit summary.

For the `pinned` and `cmake-literal` models, also offer to bump the version file to the next
version, so builds off the default branch stop claiming to be the version that was just
released. Ask rather than assuming — some projects bump only at release time.

Commit with `git commit -s`. If pushing directly to the default branch is rejected by branch
protection, open a pull request instead rather than forcing anything.

## Step 7 — Report

1. The published release, its tag, and its URL.
2. The expected-vs-found artifact table, so the verification is auditable.
3. What was stubbed for the next cycle, and whether it was pushed or left as a PR.
4. If the project ships to Flathub, note that the Flathub manifest is a separate repository
   and is **not** updated by this skill — point at `/update-flathub`.

## Rules

- NEVER publish while any job is failing, cancelled, or unexplained-skipped.
- NEVER publish with an expected artifact missing — a platform silently losing its download is
  the exact failure this skill exists to prevent.
- NEVER accept the run's summary conclusion in place of checking individual jobs.
- NEVER re-tag, delete, or overwrite an already-published release.
- NEVER push to the default branch by force, and never bypass branch protection.
- Treat "still running" as a reason to wait, not a reason to fail.
- If you cannot determine what artifacts were expected, say so explicitly rather than
  declaring the release complete.
