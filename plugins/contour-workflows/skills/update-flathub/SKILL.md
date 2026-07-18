---
name: update-flathub
description: Bump a published release into its Flathub manifest — resolves the app ID, computes
  the release tarball checksum, updates the manifest's source URL and sha256, and opens a pull
  request against the Flathub repository. Use after /publish-release for projects shipped on
  Flathub.
argument-hint: "[version-or-tag]"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(curl:*), Bash(sha256sum:*), Bash(bash:*), Bash(xmllint:*), Read, Grep, Glob, Edit
---

# Update Flathub

Carry a published release over into its Flathub manifest.

Flathub packaging lives in a repository owned by the **Flathub organisation**, not by the
project — `flathub/<app-id>`. Nothing in the project's own CI touches it, so this step is
invisible from the project side and easy to forget entirely. When it is forgotten, Flathub
users keep receiving an old version indefinitely while every other channel moves on.

- If `$ARGUMENTS` is provided, use it as the version or tag to package.
- Otherwise, use the project's latest published release.

## Context

- Repository remote: !`git remote get-url origin 2>/dev/null || echo "(no remote)"`
- Latest release: !`gh release view --json tagName,isDraft,isPrerelease,publishedAt 2>/dev/null || echo "(none)"`

## Step 1 — Establish what is being packaged

1. Read the AppStream ID from the project's metainfo file — this *is* the Flathub repository
   name:
   ```
   xmllint --xpath 'string(/component/id)' metainfo.xml
   ```
   If the project has no metainfo file, it is not an AppStream desktop app and almost
   certainly not on Flathub. **Stop** and say so.
2. Resolve the release to package. It must be **published**, not a draft — Flathub builds from
   a source tarball that only exists once the tag is public. If the release is still a draft,
   **stop** and point at `/publish-release`.
3. Note the tag and the owner/repo of the project.

## Step 2 — Locate the Flathub manifest repository

In order:

1. A sibling checkout next to the project directory named after the app ID. Verify its
   `origin` really points at `flathub/<app-id>` before trusting it — and if it is on a stale
   feature branch, note that rather than working from it blindly.
2. Otherwise clone it into a temporary directory:
   ```
   gh repo clone flathub/<app-id> -- --depth=50
   ```

Work from the repository's default branch, freshly fetched. Flathub's stable branch is the one
that actually ships; a manifest edited on some leftover release branch reaches nobody.

Report how far behind the manifest is — comparing the version currently pinned in the manifest
against the release being packaged tells the user whether this is a routine bump or a catch-up
after several missed releases.

## Step 3 — Compute the source tarball checksum

The manifest pins the project's source archive by URL and SHA-256:

```
https://github.com/<owner>/<repo>/archive/refs/tags/<tag>.tar.gz
```

Download it and hash it:

```
curl -fsSL -o /tmp/<repo>-<tag>.tar.gz "<url>"
sha256sum /tmp/<repo>-<tag>.tar.gz
```

If the download fails, **stop** — a tag that GitHub will not serve as a tarball cannot be
packaged, and a guessed checksum would fail Flathub's build in a way that is tedious to trace
back to here.

## Step 4 — Update the manifest

The manifest is a YAML (or JSON) file named after the app ID. It usually contains **many**
`type: archive` sources — most of them vendored dependencies staged into a dependency
directory. Change only the project's own source.

Identify it by its URL pointing at the project's own `<owner>/<repo>`, and by the absence of a
`dest:` staging path. Update exactly two fields on that entry:

```diff
       - type: archive
-        url: https://github.com/<owner>/<repo>/archive/refs/tags/<old-tag>.tar.gz
-        sha256: <old-sha>
+        url: https://github.com/<owner>/<repo>/archive/refs/tags/<new-tag>.tar.gz
+        sha256: <new-sha>
```

Leave everything else alone unless the user asks — runtime version, `finish-args`, build
options, and patches are packaging decisions with their own consequences.

Two things are worth *raising* without changing them unprompted:

- **Pinned dependency versions.** If the release bumped a dependency that the manifest also
  pins by tag, the manifest will build the old one. Point out any that look out of step and
  offer to update them, each with a freshly computed checksum.
- **Stale patches.** If the manifest applies a `type: patch`, check it still applies against
  the new tarball. A patch that no longer applies fails the Flathub build.

## Step 5 — Open the pull request

Flathub is a different organisation, so pushing is not a given. Show the user the diff and get
explicit confirmation before anything leaves the machine.

```
git checkout -b <version>
git commit -s -am "Update to <version>"
git push origin <version>
gh pr create --repo flathub/<app-id> --title "Update to <version>"
```

Match the branch and commit-message convention already visible in the manifest repository's
history rather than imposing a new one.

If you lack push access, **stop** and hand the user the finished diff so they can apply it
themselves — do not fork the repository or invent an alternative route without being asked.

## Step 6 — Report

1. The app ID, the version packaged, and how far behind the manifest had been.
2. The tarball URL and the checksum you computed.
3. The pull request URL, or the diff if it could not be pushed.
4. Anything you deliberately left alone — outdated dependency pins, a suspect patch, a runtime
   version worth revisiting.
5. That Flathub builds the pull request itself, and the update reaches users only once a
   Flathub maintainer merges it.

## Rules

- NEVER package a draft or unpublished release.
- NEVER write a checksum you did not compute from the downloaded artifact.
- NEVER modify a dependency source, runtime version, or `finish-args` without being asked.
- NEVER push to a repository outside the project's organisation without explicit confirmation.
- NEVER force-push to a Flathub branch.
- If the manifest's structure does not match what is described here, **stop** and show the
  user what you found instead of editing speculatively.
