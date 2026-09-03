#!/usr/bin/env bash
#
# sprint-gather — collect a sprint's history from GitHub into the normalized TSV that
# metrics.sh consumes.
#
# Usage:
#   gather.sh --owner <owner> --number <n> [--repo <owner/name>] [--limit 300]
#   gather.sh --milestone <title> --repo <owner/name> [--limit 300]
#   gather.sh --self-check                 # probe gh, scopes and fields; emit no data
#
# Writes TSV to stdout, progress and diagnostics to stderr. Reads nothing from stdin.
#
# Everything that touches the network lives here, so that metrics.sh can stay a pure function
# of its input and therefore be testable against a fixture. That split is the whole point.
#
# A gh call that fails records `M <TAB> unknown <TAB> <detail>` and carries on. A partial gather
# that names its gaps is worth more than a clean failure, because the gaps end up in the report
# instead of being silently rounded to zero.
#
# Extending behaviour = adding a row to one of the tables below, never editing logic.

# Every single-quoted string below is a GraphQL document or a jq program, and the $-prefixed
# names in them are GraphQL variables bound by `gh api -F` or jq bindings, not shell
# expansions. Single quotes are exactly right there, so SC2016 is a false positive for this
# whole file.
# shellcheck disable=SC2016
set -euo pipefail

owner=""; number=""; repo=""; milestone=""; limit=300; selfcheck=0

die()  { printf 'sprint-gather: %s\n' "$*" >&2; exit 1; }
note() { printf 'sprint-gather: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------------------------
# Table 1 — CI rollup normalization. GitHub returns two different shapes in statusCheckRollup:
# a CheckRun carries `conclusion`, a legacy StatusContext carries `state`. A reader that knows
# only `conclusion` reports "no checks" for a repository whose CI is perfectly healthy.
# Absent, pending, failed and passed stay four distinct outcomes here and all the way through.
#   match|verdict
# ---------------------------------------------------------------------------------------------
# FAILURE  <- FAILURE ERROR TIMED_OUT CANCELLED ACTION_REQUIRED STARTUP_FAILURE
# PENDING  <- PENDING EXPECTED QUEUED IN_PROGRESS WAITING REQUESTED
# SUCCESS  <- SUCCESS NEUTRAL SKIPPED
# ABSENT   <- the rollup is empty or absent

while [ $# -gt 0 ]; do
  case "$1" in
    --owner)      owner="${2:-}";     shift 2 ;;
    --number)     number="${2:-}";    shift 2 ;;
    --repo)       repo="${2:-}";      shift 2 ;;
    --milestone)  milestone="${2:-}"; shift 2 ;;
    --limit)      limit="${2:-}";     shift 2 ;;
    --self-check) selfcheck=1;        shift ;;
    -h|--help)    sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    --)           shift; break ;;
    *)            die "unknown option: $1" ;;
  esac
done

command -v gh  >/dev/null 2>&1 || die "gh is not on PATH"
command -v git >/dev/null 2>&1 || die "git is not on PATH"

# Capture and match, never `gh auth status | grep -q`: under `pipefail` grep -q exits at the
# first match, gh dies of SIGPIPE, and the pipeline reports failure *because* the scope is there.
auth_status="$(gh auth status 2>&1 || true)"
case "$auth_status" in
  *"not logged"*) die "gh is not authenticated — run: gh auth login" ;;
esac
has_project_scope=0
case "$auth_status" in
  *"'project'"*|*" project"*|*",project"*) has_project_scope=1 ;;
esac

if [ -z "$repo" ]; then
  repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
fi
[ -n "$repo" ] || die "could not determine the repository — pass --repo <owner/name>"
[ -n "$owner" ] || owner="${repo%%/*}"

if [ "$selfcheck" -eq 1 ]; then
  printf 'repo:            %s\n' "$repo"
  printf 'project scope:   %s\n' "$([ "$has_project_scope" -eq 1 ] && echo present || echo "MISSING — run: gh auth refresh -s project")"
  printf 'gh version:      %s\n' "$(gh --version 2>/dev/null | head -1)"
  printf 'default branch:  %s\n' "$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo '(unknown)')"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/rec.tsv"
: > "$tmp/meta.tsv"

meta()    { printf 'M\t%s\t%s\n' "$1" "$2" >> "$tmp/meta.tsv"; }
unknown() { printf 'M\tunknown\t%s\n'  "$1" >> "$tmp/meta.tsv"; }

# =============================================================================================
# Mode. Board and milestone are different products and a silent downgrade reads as a working
# board, so the two failures that look alike here are kept apart: "no board" is fixed by making
# one, "no project scope" by `gh auth refresh -s project`, and telling a user the second is the
# first sends them to create a board they already have.
# =============================================================================================
mode=""
project_id=""
if [ -n "$number" ]; then
  if [ "$has_project_scope" -eq 0 ]; then
    die "board $number was requested but the token has no 'project' scope — run: gh auth refresh -s project"
  fi
  project_id="$(gh project view "$number" --owner "$owner" --format json --jq '.id' 2>/dev/null || true)"
  [ -n "$project_id" ] || die "could not read board $number for owner $owner (it may not exist, or the token cannot see it)"
  mode=board
elif [ -n "$milestone" ]; then
  mode=milestone
else
  die "pass either --number <board> or --milestone <title>"
fi
meta mode "$mode"

# =============================================================================================
# Source 1 — the board, over GraphQL rather than `gh project item-list`.
#
# item-list cannot return ProjectV2Item.createdAt, and that timestamp is the only record of when
# an item joined the sprint — which makes it the only way to tell scope growth from a slow team.
# =============================================================================================
if [ "$mode" = board ]; then
  meta board_url "https://github.com/orgs/$owner/projects/$number"
  board_meta="$(gh api graphql -F p="$project_id" -f query='
    query($p:ID!){ node(id:$p){ ... on ProjectV2 { title createdAt } } }' \
    --jq '[(.data.node.title // "sprint"), (.data.node.createdAt // "")] | @tsv' 2>/dev/null || true)"
  if [ -n "$board_meta" ]; then
    meta board_title  "$(printf '%s' "$board_meta" | cut -f1)"
    meta board_created "$(printf '%s' "$board_meta" | cut -f2)"
  else
    unknown "the board title and creation date could not be read; day 0 falls to the earliest item added"
  fi
  gh api graphql --paginate -F p="$project_id" -f query='
    query($p:ID!, $endCursor:String){
      node(id:$p){ ... on ProjectV2 {
        items(first:100, after:$endCursor){
          pageInfo{ hasNextPage endCursor }
          nodes{
            createdAt isArchived
            content{ __typename
              ... on Issue { number title url createdAt closedAt updatedAt state stateReason } }
            fieldValues(first:20){ nodes{
              __typename
              ... on ProjectV2ItemFieldSingleSelectValue{ name   field{ ... on ProjectV2FieldCommon{ name } } }
              ... on ProjectV2ItemFieldNumberValue      { number field{ ... on ProjectV2FieldCommon{ name } } }
              ... on ProjectV2ItemFieldTextValue        { text   field{ ... on ProjectV2FieldCommon{ name } } }
            } }
          } } } } }' --jq '
    .data.node.items.nodes[]
    | select(.isArchived != true)
    | select(.content.number != null)
    | . as $it
    | ($it.fieldValues.nodes
       | map(select(.field != null and .field.name != null))
       | map({ key: .field.name,
               value: (if .name != null then .name
                       elif .text != null then .text
                       elif .number != null then (.number|tostring)
                       else "" end) })
       | from_entries) as $f
    | ($it.content.number|tostring) as $n
    | (["T", $n, ($f.Lane // ""), ($f.Phase // ""), ($f.Status // ""), ($f.Order // ""),
        ($f["Blocked by"] // ""), ($it.content.url // ""),
        (($it.content.title // "") | gsub("[\t\n\r]"; " "))]),
      (["E", $n, "item_added", $it.createdAt, ""]),
      (if ($it.content.createdAt // "") != "" then ["E", $n, "issue_created", $it.content.createdAt, ""] else empty end),
      (if ($it.content.closedAt  // "") != "" then ["E", $n, "issue_closed",  $it.content.closedAt, ($it.content.stateReason // "")] else empty end),
      (if ($it.content.stateReason // "") == "REOPENED" then ["E", $n, "reopened", ($it.content.updatedAt // $it.content.createdAt), ""] else empty end)
    | @tsv' >> "$tmp/rec.tsv" 2>>"$tmp/err" || {
      unknown "the board item query failed; progress, lanes and scope dates are missing from this report"
      note "board query failed:"; sed -n '1,5p' "$tmp/err" >&2 || true
    }
else
  meta board_title "$milestone"
  gh issue list --repo "$repo" --milestone "$milestone" --state all --limit "$limit" \
     --json number,title,url,state,stateReason,createdAt,closedAt,updatedAt,labels --jq '
    .[] | . as $i | ($i.number|tostring) as $n
    | ([$i.labels[].name] | map(select(startswith("lane/")))  | (.[0] // "") | ltrimstr("lane/"))  as $lane
    | ([$i.labels[].name] | map(select(startswith("phase/"))) | (.[0] // "") | ltrimstr("phase/")) as $phase
    | ([$i.labels[].name] | any(. == "blocked")) as $blocked
    | (["T", $n, $lane, $phase, (if $blocked then "Blocked" else "" end), "", "",
        ($i.url // ""), (($i.title // "") | gsub("[\t\n\r]"; " "))]),
      (["E", $n, "issue_created", $i.createdAt, ""]),
      (["E", $n, "item_added",    $i.createdAt, ""]),
      (if ($i.closedAt // "") != "" then ["E", $n, "issue_closed", $i.closedAt, ($i.stateReason // "")] else empty end),
      (if ($i.stateReason // "") == "REOPENED" then ["E", $n, "reopened", ($i.updatedAt // $i.createdAt), ""] else empty end)
    | @tsv' >> "$tmp/rec.tsv" 2>>"$tmp/err" || unknown "the milestone issue query failed; the ticket list is incomplete"
  unknown "milestone mode: Order has no home on a GitHub milestone, so sequence is not reported"
fi

# =============================================================================================
# Source 2 — pull requests, with their commits.
#
# closingIssuesReferences is the join. It is the only link GitHub actually asserts; a ticket
# number scraped out of a branch name is a guess, and a guess that silently attributes work to
# the wrong ticket is worse than an unattributed PR.
# =============================================================================================
pr_fields=number,title,url,state,isDraft,createdAt,closedAt,mergedAt,headRefName,closingIssuesReferences,statusCheckRollup,commits
commits_source="batch"
if ! gh pr list --repo "$repo" --state all --limit "$limit" --json "$pr_fields" --jq '
    .[] | . as $p
    | ([ $p.statusCheckRollup[]? | (.conclusion // .state // "PENDING") ]) as $ci
    | (if   ($ci|length) == 0 then "ABSENT"
       elif ($ci | any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED"
                       or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE")) then "FAILURE"
       elif ($ci | any(. == "PENDING" or . == "EXPECTED" or . == "QUEUED"
                       or . == "IN_PROGRESS" or . == "WAITING" or . == "REQUESTED")) then "PENDING"
       else "SUCCESS" end) as $cistate
    | ([ $p.commits[]?.authoredDate ] | sort | (.[0] // "")) as $first
    | (if $p.mergedAt != null then "MERGED" elif $p.state == "CLOSED" then "CLOSED" else "OPEN" end) as $state
    | ($p.closingIssuesReferences // []) as $refs
    | (if ($refs|length) == 0 then empty else $refs[] end)
    | (.number|tostring) as $n
    | (["P", ($p.number|tostring), $n, $state, ($p.headRefName // ""), $cistate, ($p.url // ""),
        (($p.title // "") | gsub("[\t\n\r]"; " "))]),
      (["E", $n, "pr_created", $p.createdAt, ""]),
      (if $first != ""       then ["E", $n, "first_commit", $first, ""] else empty end),
      (if $p.mergedAt != null then ["E", $n, "pr_merged",   $p.mergedAt, ""] else empty end),
      (if (($p.title // "") | test("^Revert ")) and $p.mergedAt != null
         then ["E", $n, "revert", $p.mergedAt, "message-detected"] else empty end)
    | @tsv' > "$tmp/pr.tsv" 2>>"$tmp/err"; then
  # Commits are the heavy part of that call. Drop them rather than the whole source, and say so:
  # without them the queue and build stages become undetermined, which the report must not
  # silently render as zero.
  commits_source="none"
  : > "$tmp/pr.tsv"
  unknown "the pull-request query with commits failed; retried without commit dates, so the queue and build stages are undetermined"
  gh pr list --repo "$repo" --state all --limit "$limit" \
     --json number,title,url,state,createdAt,closedAt,mergedAt,headRefName,closingIssuesReferences,statusCheckRollup --jq '
    .[] | . as $p
    | ([ $p.statusCheckRollup[]? | (.conclusion // .state // "PENDING") ]) as $ci
    | (if   ($ci|length) == 0 then "ABSENT"
       elif ($ci | any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED")) then "FAILURE"
       elif ($ci | any(. == "PENDING" or . == "EXPECTED" or . == "QUEUED" or . == "IN_PROGRESS")) then "PENDING"
       else "SUCCESS" end) as $cistate
    | (if $p.mergedAt != null then "MERGED" elif $p.state == "CLOSED" then "CLOSED" else "OPEN" end) as $state
    | (($p.closingIssuesReferences // []) | if length == 0 then empty else .[] end)
    | (.number|tostring) as $n
    | (["P", ($p.number|tostring), $n, $state, ($p.headRefName // ""), $cistate, ($p.url // ""),
        (($p.title // "") | gsub("[\t\n\r]"; " "))]),
      (["E", $n, "pr_created", $p.createdAt, ""]),
      (if $p.mergedAt != null then ["E", $n, "pr_merged", $p.mergedAt, ""] else empty end)
    | @tsv' > "$tmp/pr.tsv" 2>>"$tmp/err" || unknown "the pull-request query failed entirely; throughput is not measurable"
fi
cat "$tmp/pr.tsv" >> "$tmp/rec.tsv"
meta commits_source "$commits_source"

# =============================================================================================
# Source 3 — branches with no pull request yet.
#
# Not a fallback: a required third source. Per lib/team-protocol.md the branch is the claim, so
# a pushed branch with no PR IS work in flight — and it is invisible to `gh pr list` entirely.
# Without this, a ticket somebody is actively working reads exactly like one nobody has touched.
# =============================================================================================
base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
if [ -z "$base" ]; then
  unknown "the default branch could not be resolved (try: git remote set-head origin -a); branches without a PR were not scanned"
else
  known_pr_branch="$(awk -F '\t' '$1 == "P" { print $5 }' "$tmp/rec.tsv" | sort -u)"
  git ls-remote --heads origin 2>/dev/null | awk '{ sub(/^refs\/heads\//, "", $2); print $2 }' |
  while IFS= read -r br; do
    [ -n "$br" ] || continue
    case "$br" in "${base#origin/}") continue ;; esac
    if printf '%s\n' "$known_pr_branch" | grep -qxF "$br"; then continue; fi
    # The ticket number comes from the branch name only here, where team-protocol.md requires it
    # to be present, and only for a branch that has no PR to assert the link properly.
    tnum="$(printf '%s\n' "$br" | sed -n 's/^[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -1)"
    [ -n "$tnum" ] || continue
    if ! awk -F '\t' -v n="$tnum" '$1 == "T" && $2 == n { f = 1 } END { exit !f }' "$tmp/rec.tsv"; then continue; fi
    first="$(git log --format=%aI "$base..origin/$br" 2>/dev/null | awk 'END { print }')"
    [ -n "$first" ] || continue
    printf 'E\t%s\tfirst_commit\t%s\t%s\n' "$tnum" "$first" "branch $br, no PR" >> "$tmp/rec.tsv"
  done
fi

# =============================================================================================
# Day 0. The ladder, resolved here so the report can name the rung it used and what it would
# have been one rung up — a board created three weeks after the first commit means the sprint
# ran before it was planned, and every rate measured from the board birthday is inflated.
# =============================================================================================
board_created="$(awk -F '\t' '$2 == "board_created" { print $3 }' "$tmp/meta.tsv" | head -1)"
awk -F '\t' -v board_created="$board_created" -v mode="$mode" '
function day(s) { return substr(s, 1, 10) }
$1 == "E" && $3 == "item_added"    { if (r2 == "" || $4 < r2) r2 = $4 }
$1 == "E" && $3 == "item_added"    { if ($4 > r2max) r2max = $4 }
$1 == "E" && $3 == "issue_created" { if (r3 == "" || $4 < r3) r3 = $4 }
$1 == "E" && $3 == "first_commit"  { if (r4 == "" || $4 < r4) { r4 = $4 }
                                   }
END {
    r1 = board_created
    # A board reused for a second sprint carries the date of the FIRST sprint, and every rate then
    # comes out low by about half with no visible symptom. If the board predates its own earliest
    # item by more than the span over which items were added, it is not the birthday of this sprint.
    reused = 0
    if (r1 != "" && r2 != "" && day(r1) < day(r2)) {
        gap  = daynum(day(r2)) - daynum(day(r1))
        span = daynum(day(r2max)) - daynum(day(r2))
        if (gap > span && gap > 14) reused = 1
    }
    if (r1 != "" && !reused)  { d = day(r1); rung = "R1"; srcs = "board createdAt" }
    else if (r2 != "")        { d = day(r2); rung = "R2"; srcs = "earliest item added to the board" }
    else if (r3 != "")        { d = day(r3); rung = "R3"; srcs = "earliest issue created" }
    else if (r4 != "")        { d = day(r4); rung = "R4"; srcs = "earliest commit across all tickets" }
    else                      { d = "";      rung = "R5"; srcs = "no basis" }
    if (reused) print "M\tunknown\tthe board predates its earliest item by more than the span of the additions, which is what a reused board looks like; day 0 fell back to the first item added"
    if (d == "") { print "M\tunknown\tno day 0 could be determined from any source; pass --since"; exit }
    printf "M\tday0\t%s\n", d
    printf "M\tday0_rung\t%s\n", rung
    printf "M\tday0_source\t%s\n", srcs
    # Name the neighbouring rung whenever it disagrees, because the disagreement is the finding.
    alt = ""
    if (rung == "R1" && r2 != "" && day(r2) != d) alt = "R2 " day(r2) " (earliest item added)"
    else if (rung != "R4" && r4 != "" && day(r4) != d) alt = "R4 " day(r4) " (earliest commit)"
    if (alt != "") printf "M\tday0_alt\t%s\n", alt
    if (r4 != "" && d != "" && daynum(d) - daynum(day(r4)) > 14)
        printf "M\tunknown\tthe earliest commit (%s) predates day 0 by more than a fortnight; a rebased or cherry-picked branch keeps its original author date, so it was not used to set the window\n", day(r4)
}
function daynum(s,   y, m, dd, era, yoe, doy, doe) {
    y = substr(s,1,4)+0; m = substr(s,6,2)+0; dd = substr(s,9,2)+0
    y -= (m <= 2); era = int((y >= 0 ? y : y - 399) / 400); yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + dd - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
}
' "$tmp/rec.tsv" >> "$tmp/meta.tsv"

meta gathered_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Board mode still cannot see a Status transition, and saying so here means the report says so
# without having to know how it was gathered.
unknown "no Status history exists on a GitHub project board, so every stage below is reconstructed from issue, commit and PR timestamps"

cat "$tmp/meta.tsv"
cat "$tmp/rec.tsv"
