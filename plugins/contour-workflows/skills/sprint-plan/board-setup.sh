#!/usr/bin/env bash
# Create or repair the field and view schema of a sprint board.
#
# Idempotent by construction: every step reads what exists first and creates only what is
# missing, so re-running it after adding a phase or a lane is the supported way to amend a
# board. It never deletes a field, an option or a view — removing one is a decision with
# item data attached to it, and belongs to a human.
#
# Extending behaviour = adding a row to one of the tables below, never editing logic.
#
# Usage:
#   board-setup.sh --owner <owner> --number <n> \
#                  --lanes  "L core,N app,D ci,manager" \
#                  --phases "Phase 1 name,Phase 2 name,Deferred,Backlog" \
#                  [--current-phase "Phase 1 name"]
#
# Requires: gh >= 2.90 authenticated with the `project` scope.

# Every single-quoted string below is a GraphQL document, and the $-prefixed names in them
# are GraphQL variables bound by `gh api -F`, not shell expansions. Single quotes are exactly
# right there, so SC2016 is a false positive for this whole file.
# shellcheck disable=SC2016
set -euo pipefail

owner=""
number=""
lanes=""
phases=""
current_phase=""

die() { printf 'board-setup: %s\n' "$1" >&2; exit 1; }
note() { printf '  %s\n' "$1"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --owner)         owner="${2:-}";         shift 2 ;;
        --number)        number="${2:-}";        shift 2 ;;
        --lanes)         lanes="${2:-}";         shift 2 ;;
        --phases)        phases="${2:-}";        shift 2 ;;
        --current-phase) current_phase="${2:-}"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$owner" ]  || die "--owner is required"
[ -n "$number" ] || die "--number is required"
[ -n "$lanes" ]  || die "--lanes is required"
[ -n "$phases" ] || die "--phases is required"

# A double quote in an option name would break the GraphQL literals below, and a comma is
# already impossible because gh takes --single-select-options comma-separated. Refuse both by
# name rather than emitting a mutation that fails somewhere less legible.
case "$lanes$phases$current_phase" in
    *'"'*) die 'option names may not contain a double quote' ;;
esac

# ---------------------------------------------------------------------------------------------
# Preflight. A missing `project` scope and a missing project are different problems with
# different remedies, and the API failure reads the same for both.
# ---------------------------------------------------------------------------------------------

# `producer | grep -q` is a false negative under `set -o pipefail`, and it fails on the
# SUCCESS path: grep exits at the first match, the producer dies of SIGPIPE, and pipefail
# reports the producer's status -- so the pipeline says "absent" precisely BECAUSE the scope
# is there. Capture into a variable and match afterwards.
auth_status="$(gh auth status 2>&1 || true)"
case "$auth_status" in
    *"'project'"*) ;;
    *) die "the gh token has no 'project' scope. Run: gh auth refresh -s project" ;;
esac

project_id="$(gh project view "$number" --owner "$owner" --format json --jq '.id' 2>/dev/null)" \
    || die "cannot read project $number for owner $owner"
[ -n "$project_id" ] || die "cannot read project $number for owner $owner"

printf 'Board %s (owner %s), project id %s\n' "$number" "$owner" "$project_id"

# ---------------------------------------------------------------------------------------------
# Status. The built-in field cannot be created, only amended, and amending it means re-sending
# the FULL option list -- each existing option with its own id, or the items holding that value
# lose it. See lib/sprint-board.md "Board mechanics".
# ---------------------------------------------------------------------------------------------

# name|color|description -- the canonical Status vocabulary. Order here is the order shown.
status_rows='Blocked|RED|Waiting on something outside this ticket
Todo|GREEN|Sequenced, not started
In Progress|YELLOW|A branch exists and references it
In Review|BLUE|A PR is open and handed to the manager
Done|PURPLE|Closing PR merged with CI green'

# Read option ids by name without needing a JSON tool on PATH.
status_option_id() {
    gh api graphql -f query='
      query($p:ID!){ node(id:$p){ ... on ProjectV2 { field(name:"Status"){
        ... on ProjectV2SingleSelectField { options { id name } } } } } }' \
      -F p="$project_id" \
      --jq ".data.node.field.options[] | select(.name == \"$1\") | .id"
}

status_field_id="$(gh api graphql -f query='
  query($p:ID!){ node(id:$p){ ... on ProjectV2 { field(name:"Status"){
    ... on ProjectV2SingleSelectField { id } } } } }' -F p="$project_id" --jq '.data.node.field.id')"

[ -n "$status_field_id" ] || die "the project has no built-in Status field"

status_literal=""
while IFS='|' read -r name color description; do
    [ -n "$name" ] || continue
    # </dev/null: this runs inside a `while read` loop whose stdin is the heredoc below.
    existing="$(status_option_id "$name" </dev/null)"
    if [ -n "$existing" ]; then
        status_literal="$status_literal{id:\"$existing\", name:\"$name\", color:$color, description:\"$description\"},"
    else
        status_literal="$status_literal{name:\"$name\", color:$color, description:\"$description\"},"
        note "Status: adding option '$name'"
    fi
done <<EOF
$status_rows
EOF
status_literal="${status_literal%,}"

gh api graphql -f query="
  mutation(\$f:ID!){ updateProjectV2Field(input:{fieldId:\$f, singleSelectOptions:[$status_literal]}){
    projectV2Field { ... on ProjectV2SingleSelectField { id } } } }" \
  -F f="$status_field_id" --jq '.data.updateProjectV2Field.projectV2Field.id' >/dev/null
note "Status: 5 options in place"

# ---------------------------------------------------------------------------------------------
# The remaining fields. gh project field-create is NOT idempotent -- a repeat fails with
# "Name has already been taken" -- so read the field list first and create only what is missing.
# ---------------------------------------------------------------------------------------------

existing_fields="$(gh project field-list "$number" --owner "$owner" --limit 100 \
    --format json --jq '.fields[].name')"

has_field() { printf '%s\n' "$existing_fields" | grep -Fxq "$1"; }

ensure_select_field() {
    if has_field "$1"; then note "$1: already present"; return 0; fi
    gh project field-create "$number" --owner "$owner" --name "$1" \
        --data-type SINGLE_SELECT --single-select-options "$2" --format json --jq '.id' >/dev/null
    note "$1: created"
}

ensure_plain_field() {
    if has_field "$1"; then note "$1: already present"; return 0; fi
    gh project field-create "$number" --owner "$owner" --name "$1" \
        --data-type "$2" --format json --jq '.id' >/dev/null
    note "$1: created"
}

ensure_select_field "Lane"     "$lanes"
ensure_select_field "Phase"    "$phases"
ensure_select_field "Priority" "Critical,High,Medium,Low"
ensure_plain_field  "Order"      NUMBER
ensure_plain_field  "Blocked by" TEXT

# ---------------------------------------------------------------------------------------------
# Views. `gh project` has no view-create, and createProjectV2View takes no filter -- the filter
# only goes on with updateProjectV2View. Two mutations per view.
#
# name|layout|filter -- the seven standing questions. See lib/sprint-board.md "Views".
# ---------------------------------------------------------------------------------------------

view_rows='1 - Progress through the plan|BOARD_LAYOUT|-phase:"Backlog"
2 - Who has what|TABLE_LAYOUT|-status:Done
3 - Up next, in Order|TABLE_LAYOUT|-status:Done,Blocked
4 - Blocked, and on what|TABLE_LAYOUT|status:Blocked
5 - Needs triage (no lane yet)|TABLE_LAYOUT|no:lane
7 - Shipped|BOARD_LAYOUT|status:Done'

existing_views="$(gh api graphql -f query='
  query($p:ID!){ node(id:$p){ ... on ProjectV2 { views(first:50){ nodes { name } } } } }' \
  -F p="$project_id" --jq '.data.node.views.nodes[].name')"

view_id_by_name() {
    gh api graphql -f query='
      query($p:ID!){ node(id:$p){ ... on ProjectV2 { views(first:50){ nodes { id name } } } } }' \
      -F p="$project_id" --jq ".data.node.views.nodes[] | select(.name == \"$1\") | .id"
}

ensure_view() {
    view_name="$1"; view_layout="$2"; view_filter="$3"
    if printf '%s\n' "$existing_views" | grep -Fxq "$view_name"; then
        note "view '$view_name': already present"
        vid="$(view_id_by_name "$view_name")"
    else
        vid="$(gh api graphql -f query="
          mutation(\$p:ID!,\$n:String!){ createProjectV2View(input:{projectId:\$p, name:\$n,
            layout:$view_layout}){ projectV2View { id } } }" \
          -F p="$project_id" -f n="$view_name" --jq '.data.createProjectV2View.projectV2View.id')"
        note "view '$view_name': created"
    fi
    [ -n "$vid" ] || die "could not resolve a view id for '$view_name'"
    gh api graphql -f query='
      mutation($v:ID!,$f:String!){ updateProjectV2View(input:{viewId:$v, filter:$f}){
        projectV2View { id } } }' \
      -F v="$vid" -f f="$view_filter" --jq '.data.updateProjectV2View.projectV2View.id' >/dev/null
}

while IFS='|' read -r vname vlayout vfilter; do
    [ -n "$vname" ] || continue
    ensure_view "$vname" "$vlayout" "$vfilter"
done <<EOF
$view_rows
EOF

# View 6 tracks whichever phase is current, so it is re-pointed rather than accumulated.
if [ -n "$current_phase" ]; then
    ensure_view "6 - $current_phase" TABLE_LAYOUT "phase:\"$current_phase\""
fi

printf '\nSchema in place. Grouping and sorting are not settable through the API and remain\n'
printf 'manual: group view 1 by Phase, view 2 by Lane, and sort views 3 and 6 by Order.\n'
