---
name: address-review
description: Address code review comments on a GitHub or GitLab pull/merge request. Investigates each comment, applies valid suggestions, and explains why invalid ones are incorrect. Commits all adaptations.
argument-hint: [pr-number-or-url]
allowed-tools: Bash(git:*), Bash(gh:*), Bash(glab:*), Bash(ctest:*), Bash(cmake:*), Read, Grep, Glob, Edit, Write, Agent
---

# Address Code Review Comments

Analyze code review comments on the current branch's pull/merge request, investigate each one
thoroughly, apply valid suggestions, and explain why invalid ones are incorrect.

## Context

- Current branch: !`git branch --show-current`
- Repository remote: !`git remote get-url origin 2>/dev/null || echo "(no remote)"`

## Phase 0 — Detect Platform and Locate the PR/MR

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

### Step 0.2 — Locate the pull/merge request

- If `$ARGUMENTS` is provided, use it as the PR/MR number or URL.
- Otherwise, find the PR/MR for the current branch:
  - **GitHub**: `gh pr view --json number,url,title,state 2>/dev/null`
  - **GitLab**: `glab mr view --output json 2>/dev/null`
- If no open PR/MR is found for the current branch, **stop** and inform the user.

## Phase 1 — Fetch Review Comments

### Step 1.1 — Retrieve all review comments

Fetch all review comments (not general PR/MR description comments, but inline code review comments):

- **GitHub**: Use the REST API to get both review comments and review threads:
  ```
  gh api repos/{owner}/{repo}/pulls/{number}/comments --paginate
  ```
  Also fetch review bodies (top-level review summaries):
  ```
  gh api repos/{owner}/{repo}/pulls/{number}/reviews --paginate
  ```

- **GitLab**: Use:
  ```
  glab api projects/{id}/merge_requests/{iid}/notes --paginate
  ```

### Step 1.2 — Parse and organize comments

For each review comment, extract:
- **Author**: who wrote the comment.
- **File path**: which file the comment is on.
- **Line number(s)**: the specific line(s) or range the comment refers to.
- **Comment body**: the actual review text.
- **Whether it is resolved/outdated**: skip already-resolved threads.
- **Suggested code change**: if the reviewer used a suggestion block (```suggestion), extract it.

Filter out:
- Comments authored by the PR/MR owner (self-comments / notes to self).
- Already-resolved review threads.
- Bot comments (e.g., CI status, linters).

Group remaining comments by file path for efficient analysis.

### Step 1.3 — Present the comment inventory

List all unresolved review comments in a numbered summary:

```
# Review Comments Found

1. [file.cpp:42] @reviewer: "Consider using std::span here instead of raw pointer"
2. [file.cpp:87] @reviewer: "This could be a constexpr function"
3. [test.cpp:15] @reviewer: "Missing edge case test for empty input"
...
```

## Phase 2 — Investigate Each Comment

For each unresolved review comment, perform the following analysis:

### Step 2.1 — Read the relevant code

Read the file and surrounding context (at least 30 lines before and after the commented line)
to fully understand the code in question. If the comment references other files or functions,
read those as well.

### Step 2.2 — Understand the reviewer's concern

Determine what the reviewer is asking for. Common categories:
- **Bug report**: reviewer believes the code is incorrect.
- **Style/convention**: reviewer suggests a different coding style or pattern.
- **Performance**: reviewer suggests a more efficient approach.
- **Safety**: reviewer identifies a potential safety issue (UB, race condition, etc.).
- **Missing test**: reviewer asks for additional test coverage.
- **Simplification**: reviewer suggests a simpler approach.
- **Naming**: reviewer suggests better variable/function/type names.
- **C++ idiom**: reviewer suggests a more idiomatic C++ approach.
- **Documentation**: reviewer asks for comments or documentation.
- **Question**: reviewer is asking for clarification, not requesting a change.

### Step 2.3 — Evaluate correctness

Thoroughly investigate whether the reviewer is correct:

1. **If the reviewer suggests a code change**, verify that:
   - The suggested change compiles and is syntactically correct.
   - The suggested change preserves the intended semantics.
   - The suggested change does not introduce new bugs or regressions.
   - The suggested change is actually an improvement (not just different).

2. **If the reviewer reports a bug**, verify that:
   - The bug actually exists by tracing the code path.
   - The proposed fix (if any) is correct.
   - The bug manifests under realistic conditions, not just theoretical ones.

3. **If the reviewer suggests a style change**, verify that:
   - The suggestion aligns with the project's coding conventions.
   - The suggestion is consistent with surrounding code in the same file/module.

4. **Check for broader implications**:
   - Does the suggested change affect other call sites?
   - Does it change public API or behavior?
   - Are there performance implications?
   - Would it require changes elsewhere to maintain consistency?

### Step 2.4 — Classify the verdict

For each comment, arrive at one of these verdicts:

- **ACCEPT**: The reviewer is correct. Apply the change.
- **ACCEPT WITH MODIFICATION**: The reviewer's concern is valid, but the exact suggestion needs adjustment. Apply a modified version.
- **DECLINE**: The reviewer is incorrect or the suggestion would make the code worse. Prepare a clear, respectful explanation of why.
- **QUESTION**: The comment is ambiguous or requires more context from the reviewer. Note what clarification is needed.
- **NOT APPLICABLE**: The comment is about something already resolved, outdated, or a misunderstanding of the code.

## Phase 3 — Apply Accepted Changes

### Step 3.1 — Apply changes

For each comment with verdict ACCEPT or ACCEPT WITH MODIFICATION:

1. Make the code change using the Edit tool.
2. If the reviewer used a suggestion block, apply it exactly (for ACCEPT) or with your modifications (for ACCEPT WITH MODIFICATION).
3. Maintain consistent code style (run through project formatting if applicable).
4. If a change in one location requires corresponding changes elsewhere (e.g., updating call sites, header declarations), make all necessary related changes.

### Step 3.2 — Build and test

After applying all changes:

1. Build the project to ensure no compilation errors.
2. Run the test suite to ensure no regressions.
3. If any test fails, investigate whether the failure is caused by your changes:
   - If yes, fix the issue while staying true to the reviewer's intent.
   - If no (pre-existing failure), note it but do not block on it.

## Phase 4 — Commit

### Step 4.1 — Create the commit

Stage all modified files and create a single commit with a descriptive message:

```
git commit -s -m "$(cat <<'EOF'
Address code review feedback

<For each accepted comment, one bullet describing the change:>
- file.cpp: Use std::span instead of raw pointer (per @reviewer)
- file.cpp: Make helper function constexpr (per @reviewer)
- test.cpp: Add edge case test for empty input (per @reviewer)
EOF
)"
```

If there are many changes, group them logically in the commit body.

## Phase 5 — Summary Report

Output a detailed report with the following sections:

### Comments Addressed

For each review comment, report:

```
### Comment #N — [VERDICT] — file.cpp:42 — @reviewer
> "Original comment text"

**Analysis**: <your investigation findings>
**Action**: <what you did and why>
```

### Accepted Changes
- Bullet list of every change made, with file paths and line references.
- For ACCEPT WITH MODIFICATION verdicts, explain what was modified and why.

### Declined Comments
- For each DECLINE verdict, provide a clear, respectful, technically precise explanation
  of why the reviewer's suggestion was not applied. This should be detailed enough that
  you can post it as a reply to the reviewer.
- Include code references and reasoning.

### Questions for Reviewer
- For each QUESTION verdict, state what clarification is needed.

### Files Changed
- Bullet list of every file modified.

### Build & Test Results
- Build status (pass/fail).
- Test suite status (pass/fail, number of tests run).
- Any pre-existing test failures noted.

### Risk Assessment
- **Risk level**: Low / Medium / High.
- What could go wrong with the applied changes.
- Whether any changes affect public API or behavior.

## Rules

- NEVER force-push or rewrite history.
- NEVER dismiss or resolve review threads on the platform — let the reviewer do that.
- NEVER post replies to review comments automatically — only prepare reply text for the user to post.
- NEVER apply changes that you cannot verify are correct.
- NEVER skip the build/test verification step.
- When declining a reviewer's suggestion, be respectful and technically precise. The goal is
  constructive discourse, not winning an argument.
- If ALL comments are declined, still create the summary report but skip the commit step.
- Prefer minimal changes that address the reviewer's concern without scope creep.
