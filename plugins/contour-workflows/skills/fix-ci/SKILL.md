---
name: fix-ci
description: Check GitHub/GitLab CI failures, diagnose root causes, fix them, amend into the existing commit, and push.
argument-hint: [pr-or-mr-number-or-url]
allowed-tools: Bash(git:*), Bash(gh:*), Bash(glab:*), Bash(ctest:*), Bash(cmake:*), Read, Grep, Glob, Edit, Write, Agent
---

# Fix CI Failures

Diagnose and fix CI failures on a pull/merge request. Amend the fix into the existing commit(s) and push.

## Context

- Current branch: !`git branch --show-current`
- Repository remote: !`git remote get-url origin 2>/dev/null || echo "(no remote)"`

## Phase 0 — Setup and Branch Preparation

### Step 0.1 — Determine the hosting platform

Extract the **host** from the remote URL (handle both `git@host:owner/repo.git` and
`https://host/owner/repo.git` forms), then determine the platform. Do not match on the
literal string `gitlab.com` — most GitLab deployments are self-hosted under an unrelated
hostname:

1. If the host is `github.com` → use `gh`.
2. Otherwise probe, in order, and use whichever succeeds:
   ```
   gh repo view --json nameWithOwner 2>/dev/null     # GitHub (incl. Enterprise)
   glab repo view 2>/dev/null                        # GitLab (incl. self-hosted)
   ```
3. If neither succeeds, the CLI for that platform is probably not authenticated —
   report which probe failed and stop, rather than guessing.
4. If both succeed (unusual), prefer the one whose configured host matches the remote host.

### Step 0.2 — Save local state if dirty

Check whether the working tree is clean:
```
git status --porcelain
```

If there are uncommitted changes:
1. Stash everything: `git stash push --include-untracked -m "fix-ci: auto-stash before CI fix"`
2. Set an internal flag `STASH_APPLIED=true` so we can restore later.
3. Inform the user that changes were stashed.

### Step 0.3 — Locate the PR/MR and switch to its branch

**If `$ARGUMENTS` is provided** (a PR/MR number or URL):
1. Fetch the PR/MR metadata to find its head branch:
   - **GitHub**: `gh pr view $ARGUMENTS --json headRefName,number,url,title,state`
   - **GitLab**: `glab mr view $ARGUMENTS --output json`
2. If the current branch is NOT the PR/MR's head branch:
   - Fetch the branch: `git fetch origin <branch>`
   - Check it out: `git checkout <branch>`
   - Set an internal flag `SWITCHED_BRANCH=true` and remember the original branch name.

**If `$ARGUMENTS` is NOT provided**:
1. Find the PR/MR for the current branch:
   - **GitHub**: `gh pr view --json number,url,title,state,headRefName 2>/dev/null`
   - **GitLab**: `glab mr view --output json 2>/dev/null`
2. If no open PR/MR is found for the current branch, **stop** and inform the user.

Record the PR/MR number and URL for use throughout the remaining phases.

## Phase 1 — Identify CI Failures

### Step 1.1 — Fetch CI check/pipeline status

Retrieve CI status for the PR/MR:

- **GitHub**: Use the `gh` CLI to list check runs and their status:
  ```
  gh pr checks $PR_NUMBER
  ```
  Also fetch detailed check run information:
  ```
  gh api repos/{owner}/{repo}/commits/{sha}/check-runs --paginate
  ```
  Where `{sha}` is the HEAD commit of the PR branch.

- **GitLab**: Use `glab` or the API to get pipeline status:
  ```
  glab ci status
  ```
  Or:
  ```
  glab api projects/{id}/merge_requests/{iid}/pipelines
  ```
  Then fetch failed jobs:
  ```
  glab api projects/{id}/pipelines/{pipeline_id}/jobs
  ```

### Step 1.2 — Identify failed checks/jobs

From the CI status, identify all **failed** checks or jobs. For each failure, record:
- **Check/Job name**
- **Status** (failed, error, cancelled, timed out)
- **URL** to the check run or job log

If there are no failures (all checks pass), **stop** and inform the user that CI is green.

### Step 1.3 — Fetch failure logs

For each failed check/job, fetch the logs:

- **GitHub**:
  ```
  gh api repos/{owner}/{repo}/actions/runs/{run_id}/jobs
  ```
  Then for each failed job:
  ```
  gh api repos/{owner}/{repo}/actions/jobs/{job_id}/logs
  ```
  Or use:
  ```
  gh run view {run_id} --log-failed
  ```

- **GitLab**:
  ```
  glab ci trace {job_id}
  ```
  Or:
  ```
  glab api projects/{id}/jobs/{job_id}/trace
  ```

### Step 1.4 — Summarize failures

Present a numbered summary of all CI failures:

```
# CI Failures Found

1. [FAILED] build-linux — Compilation error in src/foo.cpp:42
2. [FAILED] test-unit — 3 test failures in test_bar
3. [FAILED] lint — clang-format violations in 2 files
...
```

## Phase 2 — Root Cause Analysis

For each CI failure, perform thorough root cause analysis.

### Step 2.1 — Categorize the failure

Determine the failure type:
- **Build failure**: compilation error, linker error, missing dependency
- **Test failure**: unit test, integration test, or end-to-end test failure
- **Lint/Format failure**: code style violations, static analysis warnings
- **Infrastructure failure**: timeout, out-of-memory, flaky test, network issue
- **Other**: security scan, coverage threshold, etc.

### Step 2.2 — Analyze error messages

Parse the CI logs carefully to extract:
- **Exact error messages** with file paths and line numbers.
- **Stack traces** or assertion failure details.
- **Expected vs actual** values in test failures.
- **Compiler error context** including the full template instantiation chain if applicable.

### Step 2.3 — Locate the root cause in the codebase

For each failure:
1. Read the file(s) mentioned in the error output.
2. Read the surrounding context (at least 30 lines before and after).
3. Cross-reference with the branch's diff to determine whether the failure is caused by changes in this PR/MR or is a pre-existing issue:
   ```
   git diff origin/<base>..HEAD -- <file>
   ```
4. Trace the execution path to understand *why* the failure occurs.

For **build failures**:
- Check for missing includes, wrong types, API mismatches, incorrect function signatures.
- If a header changed, check all files that include it.

For **test failures**:
- Read the failing test code to understand what is being tested.
- Read the code under test to understand the expected behavior.
- Determine if the test expectation is correct and the code is wrong, or if the test needs updating due to intentional behavior changes.

For **lint/format failures**:
- Identify which files need reformatting or which lint rules are violated.
- Determine the correct fix (run the formatter, fix the lint issue).

### Step 2.4 — Distinguish fixable from unfixable

Classify each failure:
- **Fixable**: The failure is caused by the PR/MR changes and can be corrected.
- **Pre-existing**: The failure exists on the base branch too — not caused by this PR/MR.
- **Infrastructure**: Flaky test, timeout, or CI environment issue — not a code problem.

For **pre-existing** and **infrastructure** failures, note them in the report but do not attempt to fix them.

## Phase 3 — Implement Fixes

### Step 3.1 — Fix each failure

For each **fixable** failure, apply the minimal fix:

- **Build failures**: Fix the compilation/linker error. Maintain existing code style.
- **Test failures**:
  - If the test expectation is correct → fix the code under test.
  - If the test needs updating due to intentional behavior changes → update the test. Include a brief comment explaining why the expectation changed.
- **Lint/Format failures**: Run the project's formatter/linter or manually fix violations.
  - For clang-format: `git diff --name-only origin/<base>..HEAD | xargs clang-format -i`
  - For other linters: follow the project's conventions.

### Step 3.2 — Build and test locally

After applying all fixes:

1. Build: `cmake --build --preset clang-debug`
2. Run tests: `ctest --preset=clang-debug`
3. All tests must pass. If any test fails:
   - If it is related to the fix, investigate and correct.
   - If it is a pre-existing failure, note it but do not block on it.

### Step 3.3 — Run formatters if applicable

If the project uses clang-format or similar tools, run them on modified files to ensure no new formatting violations are introduced.

## Phase 4 — Amend and Push

### Step 4.1 — Amend the commit

Stage all fixed files and amend them into the appropriate commit:

1. If the branch has a **single commit** ahead of the base:
   ```
   git add -A
   git commit --amend --no-edit
   ```

2. If the branch has **multiple commits** and the fix logically belongs to a specific commit:
   - Use `git stash` to save the fix.
   - Use `git rebase -i` non-interactively to mark the target commit for editing:
     ```
     GIT_SEQUENCE_EDITOR="sed -i 's/^pick <short-sha>/edit <short-sha>/'" git rebase -i origin/<base>
     ```
   - Apply the stashed fix: `git stash pop`
   - Amend: `git add -A && git commit --amend --no-edit`
   - Continue: `git rebase --continue`
   - If conflicts arise during rebase, resolve them.

3. If the fix does not logically belong to any specific commit (e.g., a formatting fix),
   amend it into the **last** commit:
   ```
   git add -A
   git commit --amend --no-edit
   ```

### Step 4.2 — Force-push

Push the amended commit(s) to the remote:
```
git push --force-with-lease
```

Use `--force-with-lease` (not `--force`) to prevent accidentally overwriting concurrent changes by others.

## Phase 5 — Cleanup

### Step 5.1 — Restore original branch if switched

If `SWITCHED_BRANCH=true`:
1. Switch back to the original branch: `git checkout <original-branch>`

### Step 5.2 — Restore stashed changes

If `STASH_APPLIED=true`:
1. Pop the stash: `git stash pop`
2. Inform the user that their stashed changes have been restored.
3. If the stash pop fails (conflicts), inform the user and leave the stash intact.

## Phase 6 — Summary Report

Output a detailed report:

### CI Failures Analyzed
For each failure:
```
### Failure #N — [STATUS] — check-name
**Type**: Build / Test / Lint / Infrastructure
**Root Cause**: <precise description, citing file paths and line numbers>
**Classification**: Fixable / Pre-existing / Infrastructure
**Fix Applied**: <description of what was changed, or "N/A" if not fixable>
```

### Changes Made
- Bullet list of every file modified, with a brief description of the change.

### Commits Amended
- Which commit(s) were amended, with their short SHA and subject line.

### Unfixed Failures
- List any failures that were not fixed, with explanation (pre-existing, infrastructure, etc.).

### Build & Test Results
- Local build status (pass/fail).
- Local test suite status (pass/fail, number of tests run).

### Risk Assessment
- **Risk level**: Low / Medium / High.
- What could go wrong with the applied fixes.
- Whether any fixes change behavior beyond what CI requires.

### Push Status
- Confirm the force-push succeeded.
- Provide the PR/MR URL for the user to check the updated CI status.

## Rules

- ALWAYS use `--force-with-lease` instead of `--force` when pushing amended commits.
- NEVER introduce behavioral changes beyond what is needed to fix the CI failure.
- NEVER skip the local build/test verification step.
- NEVER leave the working tree in a dirty or unexpected state — always restore stashes and return to the original branch.
- NEVER silently discard local changes — always stash and restore.
- If a CI failure is due to a flaky test or infrastructure issue (not a code defect), do NOT modify any code. Report it as an infrastructure issue in the summary.
- If ALL failures are pre-existing or infrastructure-related, skip the amend/push steps and only produce the summary report.
- When amending commits, preserve the original commit message and author information (`--no-edit`).
- When in doubt about whether a test failure is caused by the PR/MR changes, compare the same test on the base branch before modifying anything.
