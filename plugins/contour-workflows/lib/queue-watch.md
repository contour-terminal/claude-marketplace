# Watching a queue land

A backgrounded loop that watches pull requests through CI and the merge queue, arms what
is not armed, and prints one line per tick. It never fixes anything.

This is the multi-PR counterpart to the single-PR wait in `sprint-batch` §*Step 7*. That
step is still right for one PR: `gh pr checks <n> --watch` blocks on one round trip and
tells you when it is done. What it cannot do is watch **five** PRs, notice a sixth
arriving, arm auto-merge on the ones whose checks have only just appeared, or tell you
that one went `DIRTY` under a merge that landed while you were waiting.

## Why it exists

A merge queue takes 20–60 minutes per pull request. Without a watcher the manager has two
options and both are bad: poll in the foreground, spending a full model turn on every
check and learning nothing most times; or stop, and let the sprint stall until somebody
asks again.

The watcher converts *N* round trips into one. **That is the entire benefit and it is
large** — on a sprint of three or four PRs it is the difference between a dozen turns of
"still pending" and one line of output that already says what happened.

It is worth being precise about what is saved, because the obvious reading is wrong: the
wall-clock does not shrink. CI takes as long as it takes. What shrinks is the *number of
model turns spent waiting*, and on a long sprint that is the dominant token cost.

## The rules, and why each one is there

Every rule below is a scar. None of them is obvious in advance, which is why they are
written down rather than left to whoever writes the next loop.

- **Report in UTC, and say so.** `gh` returns UTC in every timestamp field; your shell
  probably does not. Comparing the two invents an offset-sized hang — and an hour or two
  is exactly the size that reads as "wedged" rather than "arithmetic". This has cost a
  cancelled, entirely healthy CI job, followed by a confident post-hoc story about runner
  starvation built on the coincidence that two queued jobs started shortly afterwards.
  Print `date -u`, suffix the `Z`.

- **Re-arm every tick, not once at the start.** A pull request becomes armable only once
  its checks exist. Arming the set you can see at tick 1 misses everything dispatched
  afterwards, and the loop then watches them sit there forever.

- **"Queued" and "not armed" are different states, and the obvious predicate cannot tell
  them apart.** `autoMergeRequest != null` is **not** "this will land": a PR *already in
  the merge queue* reports it as **null**, because it no longer has an auto-merge request
  — it has a queue entry. A watcher keyed on that predicate re-arms a queued PR on every
  tick, is told *"already queued to merge"*, and prints `armed:#N` each round — a log that
  reads as action where nothing happened and nothing needed to. Ask both questions.

- **Separate `DIRTY` from `RED`.** One needs a rebase, the other needs a fix; they are
  usually different people and always different work. A watcher that folds them into
  "not mergeable" makes the manager open both to find out which.

- **Name the failing checks. Never count them.** "3 failures" is arithmetic that is true
  and useless. The names are what decide whether it is one flaky packaging job or the
  whole Windows matrix.

- **Bound the loop, and print a terminal line on both exits.** *Drained*, *still draining
  after N rounds* and *died* are three states, and a loop that simply stops looks
  identical to one that was killed. Say which.

- **It arms and reports. It does not fix.** Judging a red, rebasing a conflict, or
  deciding a flake is worth a re-run all need judgement. A watcher that re-runs failing
  jobs on a timer manufactures green.

- **Do not kill it with `pkill -f`.** The pattern matches the shell running it, so it
  kills itself; the exit code you get back (`143`, `144`) then reads as a failing tree
  rather than as suicide. `pgrep -x` is not the fix either — it cannot match a process
  name longer than 15 characters and answers **zero**, which reads as "nothing running".
  Walk `/proc/*/cmdline`, or keep the PID.

## Reference implementation

Adjust the repo and the exit condition; keep the rules.

```bash
#!/usr/bin/env bash
# Timestamps are UTC and say so: gh reports UTC, your shell may not, and comparing
# the two invents an offset-sized hang.
set -u
REPO=<owner>/<repo>
cd <checkout> || exit 1

# Is this PR in the merge queue? `autoMergeRequest` is null for a queued PR, so the
# obvious predicate answers "not armed" for the one state that needs no arming.
queued() {
  gh run list --repo "$REPO" --limit 30 --json headBranch \
    -q '.[].headBranch' 2>/dev/null | grep -q "gh-readonly-queue/.*pr-$1-"
}

for round in $(seq 1 24); do
  git fetch -q origin master 2>/dev/null
  master=$(git rev-parse --short origin/master)
  note=""
  for pr in $(gh pr list --repo "$REPO" --state open --json number -q '.[].number' 2>/dev/null | sort -n); do
    st=$(gh pr view "$pr" --repo "$REPO" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null)
    [ "$st" = "DIRTY" ] && note="$note DIRTY:#$pr"

    fails=$(gh pr checks "$pr" --repo "$REPO" 2>/dev/null | awk -F'\t' '$2=="fail"{printf "%s,", $1}')
    [ -n "$fails" ] && note="$note RED:#$pr($fails)"

    if queued "$pr"; then
      note="$note queued:#$pr"
    else
      au=$(gh pr view "$pr" --repo "$REPO" --json autoMergeRequest -q '.autoMergeRequest != null' 2>/dev/null)
      [ "$au" = "false" ] \
        && gh pr merge "$pr" --repo "$REPO" --auto >/dev/null 2>&1 \
        && note="$note armed:#$pr"
    fi
  done
  open=$(gh pr list --repo "$REPO" --state open --json number -q 'length' 2>/dev/null)
  printf '%sZ master=%s open_prs=%s%s\n' "$(date -u +%H:%M:%S)" "$master" "$open" \
    "$( [ -n "$note" ] && printf ' |%s' "$note" )"
  [ "${open:-9}" -eq 0 ] && { echo "RESULT: queue drained"; exit 0; }
  sleep 300
done
echo "RESULT: still draining after 24 rounds"
```

Add whatever else the sprint is measured by — an open-bug count, a phase tally — to the
same line. One line per tick that carries every number the manager would otherwise ask
for separately is the point.

## Prefer a native waiter where one exists

If the harness offers a blocking wait on a condition — Claude Code's `Monitor` tool with
an until-loop, for instance — **use it instead of a hand-rolled `sleep` loop.** It is
cheaper, it cannot be killed by a stray pattern match, and it does not need the process
hygiene above. The bash form is the fallback for when the condition is a computed summary
across several pull requests rather than a single predicate, and for when you want the
per-tick log as a record.

Chaining short sleeps to approximate a long one is not a workaround; it is the same poll
loop with more turns.

## When not to use it

- **One PR.** `gh pr checks <n> --watch` is simpler and blocks properly.
- **When something is already red.** A watcher will faithfully report the same red every
  five minutes. Fix it, then watch.
- **As a substitute for looking.** A drained queue means the PRs merged, not that the work
  was right. The manager still reviews.
