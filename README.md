# Contour Terminal — Claude Code Marketplace

The Contour Terminal organization's custom [Claude Code](https://claude.com/claude-code)
plugin marketplace. It packages the git, review, CI, and analysis workflows we use day to
day so everyone gets the same well-worn paths instead of re-deriving them per person.

Currently it hosts one plugin: **`contour-workflows`**.

## Install

Add the marketplace, then install the plugin:

```
/plugin marketplace add contour-terminal/claude-marketplace
/plugin install contour-workflows@contour-terminal
```

Or declaratively, in `~/.claude/settings.json` (user-wide) or `.claude/settings.json`
(one project):

```json
{
  "extraKnownMarketplaces": {
    "contour-terminal": {
      "source": { "source": "github", "repo": "contour-terminal/claude-marketplace" }
    }
  },
  "enabledPlugins": {
    "contour-workflows@contour-terminal": true
  }
}
```

> These two keys are all that is needed. Never paste credentials, tokens, or `mcpServers`
> blocks into a file you might later share — this repo is public.

To pick up new versions later: `/plugin marketplace update contour-terminal`.

## Skills

Invoke as `/<skill>`, or `/contour-workflows:<skill>` when a name is ambiguous.

### Git & commits

| Skill | What it does |
|---|---|
| `/commit` | Groups pending changes into atomic semantic units and makes one commit per group. |
| `/amend` | Folds working-tree changes into the last commit, optionally rewording. Refuses to rewrite shared history; force-pushes only with `--force-with-lease`. |
| `/rewrite-branch` | Rebuilds a messy branch as one clean commit per semantic unit. Saves a backup ref first and verifies the final tree is identical. |

### Pull requests & review

| Skill | What it does |
|---|---|
| `/create-pr` | Pushes the branch and opens a PR with a changelog-quality title and a body shaped to the size of the change. |
| `/update-pr` | Refreshes an existing PR's title, description, and labels after the branch has moved on. Preserves hand-written content. |
| `/address-review` | Works through review comments one by one: investigates, applies the valid ones, and explains why the rest are wrong. Commits the result. |
| `/review-branch` | Reviews a whole branch through a C++23 lens — idioms, const correctness, naming, coverage, performance, risk rating. |
| `/fix-ci` | Pulls failing CI logs, diagnoses root causes, fixes them, amends, and pushes. |

### Issues

| Skill | What it does |
|---|---|
| `/work-issue <n>` | Takes an issue to a committed branch. Reads everything it links to, classifies it bug/feature/chore, then reproduces-and-regression-tests or designs-and-tests accordingly. |

### C++

| Skill | What it does |
|---|---|
| `/cpp-guidelines` | The C++23 standards and load-bearing design principles used across these projects — `std::expected` error handling, dependency injection, data-driven design, testability, zero-warning policy. Defers to each project's `.clang-tidy` and `AGENT.md`. |
| `/sanitize` | Builds and runs tests under ASan/UBSan/TSan, then diagnoses each report to a root cause. Uses the project's own sanitizer preset when one exists, otherwise a disposable build tree. |

### Analysis

| Skill | What it does |
|---|---|
| `/analyze-project` | Full project analysis: scope, architecture, data and execution flow, a deep performance pass, strengths, weaknesses, suggested next features. |
| `/sloc [path…]` | Source lines of code — grand total plus per-module and per-language breakdowns, each split into project vs. test code. |

### Releases

| Skill | What it does |
|---|---|
| `/add-release-note` | Drafts changelog entries for the branch, matching the project's existing style. Finds AppStream `metainfo.xml`, `CHANGELOG.md`, or `NEWS` automatically. |
| `/draft-release [version]` | Bumps the version wherever the project actually keeps it, stamps the changelog, commits, and pushes the release branch or tag so CI builds a draft. Publishes nothing. |
| `/publish-release [version]` | The gate before going public: refuses until every CI job is green and every expected artifact is attached, then publishes, marks it latest, and opens the next development cycle in the changelog. |
| `/update-flathub [version]` | Bumps a published release into its `flathub/<app-id>` manifest — recomputes the source tarball checksum and opens the pull request. |

These four are a pipeline: add notes as you go, `/draft-release` to cut it, `/publish-release`
once CI proves the artifacts exist, and `/update-flathub` for anything shipped on Flathub.

#### How the release skills adapt per project

Our repositories do not share one release procedure, so the skills detect the one each project
actually uses rather than hardcoding any of them — via
`plugins/contour-workflows/lib/release-model.sh`, which probes for the version source
(`metainfo.xml`, a committed `version.txt`, `git describe`, or a literal `project(… VERSION …)`),
the changelog file, and how the release workflow is triggered.

Where detection is ambiguous, or a project wants to pin the answer, commit a
`.github/release.json` — its fields are merged over whatever was detected:

```json
{
  "versionSource": "metainfo.xml",
  "changelog": "metainfo.xml",
  "trigger": "release-branch-pr",
  "artifacts": ["*.deb", "*.dmg", "*.msi", "*.zip"],
  "syncVersion": ["vcpkg.json"]
}
```

`/draft-release` and `/publish-release` both refuse to run against a workflow that only builds
*after* a release is published, because that ordering makes it impossible to verify artifacts
before publishing.

## Hooks

The plugin ships one hook: **clang-format on edit**. After Claude edits or writes a C/C++
file, the file is reformatted in place with `clang-format`, so formatting noise never reaches
review.

It is deliberately conservative and no-ops unless every condition holds:

- the edited file has a C/C++ extension,
- `clang-format` is on `PATH`,
- a `.clang-format` file exists at or above the file's directory.

So it stays silent in non-C++ repos and in C++ repos that don't define a style. To opt out
entirely, disable the plugin's hooks in `/plugin` — or install the skills without them by
copying the `skills/` directory into a project.

Both GitHub and GitLab are supported where it matters (`/create-pr`, `/update-pr`,
`/address-review`, `/fix-ci`, `/work-issue`); the platform is detected by probing `gh` and
`glab` rather than by pattern-matching the remote URL, so self-hosted GitLab works.

## Contributing

### Adding a skill

1. Create `plugins/contour-workflows/skills/<name>/SKILL.md`. The filename must be
   **uppercase `SKILL.md`** — a lowercase `skill.md` is silently ignored and the skill will
   never load.
2. Frontmatter:
   ```yaml
   ---
   name: my-skill
   description: One or two sentences covering what it does *and* when to use it. This is
     the only thing Claude sees when deciding whether to reach for the skill, so lead with
     the trigger, not the implementation.
   argument-hint: "[optional-arg]"
   allowed-tools: Bash(git:*), Read, Grep, Glob
   ---
   ```
3. Keep `allowed-tools` as tight as the skill actually needs. The subagent tool is named
   `Agent` (not `Task`).
4. Bundle supporting scripts next to `SKILL.md` and reference them via
   `${CLAUDE_PLUGIN_ROOT}` — never `~/.claude/...`. Plugins run from a cache directory, so
   absolute home paths break on install:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/my-skill/helper.sh"
   ```
5. Add it to the table above.
6. Bump `version` in **both** `plugins/contour-workflows/.claude-plugin/plugin.json` and
   the entry in `.claude-plugin/marketplace.json`. The version is pinned, so users receive
   nothing until it changes.

### Writing portable skills

This plugin is shared across an organization and published publicly. That rules out a few
habits that are fine in a personal skill:

- **No personal identity.** Use `git commit -s` so the `Signed-off-by:` trailer comes from
  whoever is actually committing. Never hardcode a name or email.
- **No hardcoded default branch.** Resolve it:
  `git symbolic-ref --short refs/remotes/origin/HEAD`, stripping `origin/`. Do not assume
  `master` or `main`.
- **No repo-specific special cases.** Detect the condition instead — check whether a
  changelog file exists, whether a label is defined — so the skill degrades gracefully
  elsewhere.
- **No secrets, ever.** No tokens, keys, internal hostnames, or credential-bearing config.
  `.gitignore` blocks the usual suspects, but it is not a substitute for looking.

### Validating

```
claude plugin validate ./plugins/contour-workflows --strict
```

Then install from a local path to try changes before pushing:

```
/plugin marketplace add /path/to/claude-marketplace
/plugin install contour-workflows@contour-terminal
```

## License

Apache-2.0. See [LICENSE](LICENSE).
