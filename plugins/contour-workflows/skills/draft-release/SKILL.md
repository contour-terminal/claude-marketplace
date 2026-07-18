---
name: draft-release
description: Prepare a release and trigger CI to build a draft — bumps the version in whatever
  file the project actually uses, stamps the changelog, commits, and pushes the release branch
  or tag. Use when cutting a new release. Stops before anything is published; run
  /publish-release afterwards to verify CI and publish.
argument-hint: "[version]"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(bash:*), Bash(date:*), Bash(xmllint:*), Bash(cmake:*), Read, Grep, Glob, Edit
---

# Draft Release

Prepare a release and let CI build a draft of it.

This skill deliberately stops short of publishing. A release is only trustworthy once every
artifact has actually been built and attached — and that cannot be known until CI has run. So
the job here is to get the repository into a releasable state and trigger the build; deciding
whether the result is good enough belongs to `/publish-release`.

- If `$ARGUMENTS` is provided, use it as the target version (accept `1.2.3` or `v1.2.3`).
- Otherwise, propose the next version in Step 3 and confirm it with the user.

## Context

- Current branch: !`git branch --show-current`
- Repository remote: !`git remote get-url origin 2>/dev/null || echo "(no remote)"`
- Working tree: !`git status --porcelain | head -20`

## Step 1 — Preflight

Every one of these is a **stop** condition, not a warning:

1. The working tree is clean. Uncommitted changes would silently ride along into the release.
2. You are on the repository's default branch. Resolve it rather than assuming:
   ```
   git symbolic-ref --short refs/remotes/origin/HEAD   # e.g. "origin/main" -> strip "origin/"
   ```
   If that ref is missing, run `git remote set-head origin -a` once and retry. Only if it
   still cannot be resolved, fall back to `main`, then `master`.
3. The branch is in sync with origin (`git fetch` first, then compare). Releasing from a stale
   checkout produces a release that does not match what is on the server.
4. `gh auth status` succeeds — the release cannot be observed later without it.

## Step 2 — Detect the release model

These projects do not share one release procedure. Detect the one this repository uses:

```
bash "${CLAUDE_PLUGIN_ROOT}/lib/release-model.sh"
```

It prints JSON. The fields that drive everything below are `versionSource`, `versionFile`,
`currentVersion`, `changelog`, `trigger`, and `syncVersion`. A committed
`.github/release.json` overrides any of them; when `override` is `true`, say so in the final
report so the user knows detection was not the whole story.

Two values are fatal:

- `trigger: "none"` — the project has no release workflow at all, so no artifacts would ever
  be produced. **Stop** and tell the user the repository needs a release workflow first.
- `trigger: "publish-first"` — CI only builds *after* a release is published, so artifacts
  cannot be verified beforehand. **Stop** and explain that the workflow must be converted to
  draft-first before this skill can be used safely.

## Step 3 — Decide the version

If `$ARGUMENTS` gave a version, use it. Otherwise propose one from `currentVersion` and the
accumulated changelog entries: fixes only suggest a patch bump, new features suggest a minor
bump. **Never** pick a major bump on your own — always ask.

Then confirm the version with the user before touching anything. Check that
`{tagPrefix}{version}` is not already a tag (`git tag --list`) and that no release with that
tag already exists (`gh release view`). If either exists, **stop**.

## Step 4 — Apply the version bump

What to edit depends entirely on `versionSource`:

**`metainfo`** — the AppStream file *is* both the version and the changelog. The topmost
`<release>` element carries the unreleased work. Turn it into a release with a single edit:

```diff
-    <release version="0.7.0" urgency="medium" type="development">
+    <release version="0.7.0" urgency="medium" date="2026-07-19">
```

Set `version=` to the target version, remove the `type="development"` attribute, and add
`date=` with **today's** date (`date +%Y-%m-%d`). Projects using this model validate in CI
that the date is the day the build runs — see Step 8.

**`pinned`** — write the bare version (no `v`) to `versionFile`, keeping the file's existing
trailing-newline convention.

**`cmake-literal`** — edit the version in the `project(... VERSION "X.Y.Z")` call in
`versionFile`. Change nothing else on that line.

**`git-tag`** — the version comes from the tag at configure time, so there is nothing to edit
in-tree. Skip to the changelog.

Then sync every path listed in `syncVersion` — these are `vcpkg.json` / `package.json`
manifests carrying their own version field that drifts out of step otherwise. Update only the
version field.

If `changelog` names a file other than the version source, add or promote its release section
there too, matching the surrounding style exactly. If `changelog` is `none`, the release notes
will come from GitHub's generated commit summary — mention that in the final report so the
user can decide whether that is good enough.

## Step 5 — Verify the version the build will actually expose

Editing the file is not proof the build agrees. Assert it by replicating the project's own
extraction rule and comparing against the intended version:

| `versionSource` | Check |
|---|---|
| `metainfo` | `xmllint --xpath 'string(/component/releases/release[1]/@version)' <file>` |
| `pinned` | read `versionFile` |
| `cmake-literal` | grep the `project(... VERSION ...)` line |
| `git-tag` | `git describe --tags --match 'v*'` after the tag exists (Step 7) |

If `xmllint` is unavailable, fall back to reading the first `<release>` element, ignoring
commented-out blocks. If the extracted value disagrees with the target version, **stop** — a
mismatch here means the shipped binary would report the wrong version.

For a deeper check, offer to run a CMake configure and read back the version it prints. Do not
require it; it needs the project's dependencies and is slow.

## Step 6 — Commit

Stage only the files changed above and commit with a sign-off:

```
git commit -s -m "Release <version>"
```

Match the repository's own release-commit wording if its history shows a consistent style.
Never hardcode an author or email — `-s` takes it from the committer's own config.

## Step 7 — Trigger the build

Show the user exactly what will be pushed and get explicit confirmation. A pushed tag is
public and awkward to retract, so this is the point of no easy return.

**`release-branch-pr`** — CI keys off a pull request whose head branch is literally named
`release`:

```
git branch -f release HEAD
git push --force-with-lease origin release
gh pr create --base <default-branch> --head release --title "Release <version>"
```

Use `--force-with-lease`, never a bare `--force`. The tag is created by CI, not here — its
final component is the CI run number and is not knowable in advance.

**`tag-push`** — push the commit first, then an annotated tag:

```
git push origin <default-branch>
git tag -a <tagPrefix><version> -m "Release <version>"
git push origin <tagPrefix><version>
```

## Step 8 — Report

State plainly:

1. Which release model was detected, and whether `.github/release.json` overrode it.
2. Every file changed, and the version each now reports.
3. What CI will do next, and the tag to expect. For `release-branch-pr`, note that the fourth
   tag component is the CI run number, so the tag is not final until the build completes.
4. **The same-day constraint**, when the model is `metainfo`: the release date just written is
   validated against the day CI runs. If the build does not finish today, the check will fail
   and the date must be moved forward and the branch re-pushed.
5. That nothing has been published, and `/publish-release` is the next step.

## Rules

- NEVER publish a release, mark one as latest, or flip a draft. That is `/publish-release`.
- NEVER push without showing the user what will be pushed and getting confirmation.
- NEVER uncomment a commented-out `<release>` template — those are stubs for a future cycle,
  and uncommenting one makes the build read a placeholder version.
- NEVER use a bare `git push --force`; `--force-with-lease` only.
- NEVER hardcode a default branch, author, or email.
- NEVER invent changelog entries. Release what the changelog already says; if it is empty,
  say so and let the user decide.
- If detection is ambiguous or contradicts what the user expects, **stop** and ask rather than
  guessing — suggest pinning the answer in `.github/release.json`.
