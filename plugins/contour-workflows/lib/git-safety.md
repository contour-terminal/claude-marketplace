# Git safety

Shared rules for the operations that can destroy someone's work — publishing a branch, rewriting
history, stashing, splitting a working tree, and sequencing two branches onto one base.
`/rebase`, `/absorb`, `/fix-ci`, `/work-issue`, `/address-review` and `/sprint-run` read this file
and cite its sections by heading.

It exists because these facts were each re-derived independently in four different skills, and
every re-derivation was a chance to get one subtly wrong — which is exactly what happened. Fix them
here, once.

This is a reference document, not a skill. It has no frontmatter and is never invoked directly.

## Is this branch published?

Test for the branch's **own remote ref**, never for `@{upstream}`:

```
git rev-parse --verify refs/remotes/<remote>/<branch>
```

A branch created with `git checkout -b fix/123 origin/master` — which is what `/work-issue` does —
has `@{upstream}` set to `origin/master` while no remote branch of its own exists. Treat that as
"published" and a later force-push aims at the mainline.

Two cases where the ref is legitimately absent even though the branch *is* published:

- **You have simply never fetched it.** Fetch before concluding anything.
- **The PR comes from a fork.** The head lives on the contributor's remote, so
  `refs/remotes/origin/<branch>` will never exist. Resolve the real remote from the PR metadata
  (`gh pr view --json headRepositoryOwner,headRefName`) rather than assuming `origin`, and if you
  cannot push there, say so instead of silently skipping the push.

## Force-pushing safely

Rewriting published history needs a force-push. Three things make it safe, and all three are load
bearing:

```
git push --force-with-lease=<branch>:<expected-sha> <remote> <branch>
```

1. **Never a bare `--force`.** The lease is the only thing standing between a rewrite and somebody
   else's commits.
2. **Name the expected SHA.** A bare `--force-with-lease` trusts `refs/remotes/<remote>/<branch>`,
   and any fetch has already refreshed that ref — so it cheerfully agrees with a colleague's push
   instead of refusing it.
3. **Name the remote and the refspec.** Without them the destination comes from `push.default`. On
   the branches these skills create, `@{upstream}` is `origin/master`: `simple` errors out, and
   `upstream` force-pushes the feature branch straight at the mainline.

**Which SHA is "expected".** It is the remote tip your work is actually based on — so fetch first,
then record it. Recording a pre-fetch value from a stale clone makes the lease reject a push nobody
else touched, and the skill then reports someone else's work is on the branch when it is only the
user's own staleness.

The corollary: if that fetch *moves* the ref, somebody has pushed since you last looked. Stop and
reconcile before rewriting anything — do not record their commit as your baseline and carry on,
which converts the lease from a guard into a rubber stamp.

**If the lease is rejected, stop.** Report it and let the user decide. Escalating to `--force`
discards precisely what the lease existed to protect.

**Never rewrite the default branch.** Resolve it with
`git symbolic-ref --short refs/remotes/origin/HEAD`, which prints it *with* the `origin/` prefix —
strip that before comparing against `git branch --show-current`, or the comparison never matches
and the guard silently never fires. If it cannot be resolved, stop and ask; guessing `main` on a
repository whose default is `develop` makes the guard pass and the mainline get rewritten.

## Stashes

Whoever creates a stash owns restoring it.

**Record its identity where you create it**, because these skills nest — `/work-issue` invokes
`/rebase` and `/fix-ci`, and each may stash — so `stash@{0}` at restore time is frequently somebody
else's entry:

```
git stash push --include-untracked -m "<skill>: auto-stash"
git rev-parse stash@{0}                       # record this
```

**Pop by identity, not by position.** `git stash pop <sha>` is *not* valid git — it fails with
"is not a stash reference". Look the entry up first:

```
git stash list --format='%H %gd'              # find your SHA, note its stash@{n}
git stash pop 'stash@{n}'
```

**Restore on every exit, not just the successful one.** Enumerate the paths that end the run early
— an unresolved conflict, a rejected lease, a failed verification, a loop that stops converging —
and restore before returning from each. A tree that comes back deceptively clean, with the user's
work in an entry nobody mentioned, is how it gets lost. Return to the branch the stash was taken
from first; popping it somewhere else drops unrelated work into whatever is checked out now.

If the pop conflicts, say so and leave the stash intact rather than forcing it. And check that no
rebase is still in progress before popping at all — `git status` says so plainly.

## Splitting a mixed working tree

Not by hand, and not with the obvious tools. `git add -p` prompts for every hunk and has no stdin
here, and `git stash push --keep-index` leaves untracked files behind, so a following `git add -A`
swallows any newly added file anyway. It *is* possible to stage a computed subset non-interactively
by filtering a patch and applying it with `git apply --cached`, which is what `/absorb` does when it
has a machine-derived hunk-to-commit mapping — but that needs the mapping first, and a skill
separating two changes it just made by hand has no such thing.

So do not create a mixed tree and then try to separate it. **Sequence the work**: make one fix,
commit it, then make the other. The edits are yours to make, so make them one at a time.

Order matters whenever one of the commits will be amended: amend **first**, while the other change
does not exist yet. Committing the second change first makes it `HEAD`, and the amend then lands on
the wrong commit.

If both changes are already sitting in the tree together, revert one and redo it after the other is
committed. That is simpler and safer than parking it in a stash whose lifecycle then has to survive
an amend, a possible rebase, and every early exit.

Whatever is committed last still has to be built and tested. A fix committed after the verification
step and then pushed has never been compiled.

## Sequencing two PRs that touch the same file

**Before merging two PRs that touch the same file, simulate the second onto a synthetic
`base + first` — not onto the base.** Two branches that each *add* something at the same anchor
are pairwise clean and serially conflicting, always, and every check anybody runs by reflex answers
the pairwise question.

This is the manager's check, so `/sprint-run` reads it. It matters because of *where* it goes
wrong: `mergeStateStatus` answers the pairwise question, `gh pr checks` answers the pairwise
question, and a green PR page answers the pairwise question. The failure surfaces only when the
first PR merges, at which point the second is blocked and has to be rebased and resolved by hand —
after its CI has already passed.

Build the sequence instead:

```
tree="$(git merge-tree --write-tree "$base" "$first")"
sim="$(git commit-tree "$tree" -p "$base" -p "$first" -m 'simulated merge')"
git merge-tree --write-tree "$sim" "$second"; rc=$?
```

### Judge it by the exit status and the output together

`git merge-tree --write-tree` writes a tree **on conflict as well**, so its success and failure
output are the same shape — a hash on the first line. Testing whether the output is empty therefore
reports **clean for every conflict**, confidently and by default. An instrument with no way to
express the failing state reports the passing one.

The exit status alone is better and still not enough:

```
clean                          rc=0    tree on stdout
conflicted                     rc=1    tree on stdout, then stage entries
a ref that cannot be resolved  rc=1    NOTHING on stdout
a usage error                  rc=129  usage text
```

Git returns 1 for a conflict **and** 1 for a branch name it cannot resolve. So testing `rc != 0`
calls a stale or mistyped branch a conflict, and a sequencing loop over a deleted ref reports every
pair as conflicting and sends somebody rebasing against nothing.

Three states, and the discriminator is `rc` **plus** whether stdout carries a tree:

```
out="$(git merge-tree --write-tree "$a" "$b" 2>/dev/null)"; rc=$?
first="$(echo "$out" | sed 1q)"

if [ "$rc" = 0 ]; then
    verdict=clean
elif [ "$rc" = 1 ] && echo "$first" | grep -Eq '^[0-9a-f]{40,64}$'; then
    verdict=conflicted          # a tree was written, so the merge actually ran
else
    verdict="errored rc=$rc"    # no tree: a ref it could not resolve, or worse
fi
```

The shape worth remembering rather than the snippet: **a conflict writes a tree and an error does
not**, so the presence of the tree separates the two states that share an exit code.

### A third branch is only as tested as the tree beneath it

`merge-tree` carries a conflicted tree forward rather than stopping, so a third PR simulated on top
of an unresolved second is being merged against a tree containing **conflict markers**. Its `clean`
is provisional and stands for nothing until the conflict below it is actually resolved and the
simulation re-run. Label such a result unverified rather than reporting it.

### What to do about a conflict you find

**Take the rebase.** Do not relocate the colliding text so the two branches stop overlapping — that
organises a file by merge history instead of by subject, and the next reader inherits both the odd
placement and no explanation for it.

Do not cancel a running job to pre-empt it either. The conflict is *scheduled*: it cannot bite
before the first PR merges, and when it does it announces itself as a blocked queue entry rather
than as a surprise. A conflict with a known arrival time and a mechanical resolution loses to
almost anything you would have to cancel to avoid it.

### Verify the tip you pushed

Measure `<base>...origin/<branch>` — the pushed ref, **three dots** — as the last thing before
reporting. Anything measured earlier describes a tree that is no longer what CI, the queue, or a
reviewer will see; a resolution checked before a subsequent one-line fix produces a write-up whose
prose and whose diffstat disagree, and the reader is right to stop believing the rest of it.

Three dots rather than two for the same reason everywhere else: two-dot compares the base's *tip*
to your HEAD, so the moment the base moves its new commits render as **your deletions**. That
false-alarms on every upstream merge, and a check that cries wolf routinely is one nobody believes
on the day it is right.
