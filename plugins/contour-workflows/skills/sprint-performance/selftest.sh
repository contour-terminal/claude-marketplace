#!/usr/bin/env bash
#
# sprint-metrics self-test — run the fixtures through metrics.sh against a pinned clock and
# assert every number a rule in SKILL.md depends on.
#
# Usage:
#   bash selftest.sh [skill-dir]        # or: bash metrics.sh --self-test
#
# Pinning --now is what makes this possible at all: aging and the trailing rates are functions
# of "now", so without an injectable clock the expected values would change every day and the
# test would have to be deleted within a week.
#
# Every expected value below was computed by hand from fixtures/*.tsv, not captured from a run.
# A golden file captured from the code under test asserts only that it still does what it did.

set -euo pipefail

dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
M="bash $dir/metrics.sh"
F="$dir/fixtures"
NOW=2026-08-28T12:00:00Z
NOW_SMALL=2026-08-20T12:00:00Z

pass=0; fail=0

ok() { # ok <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3" >&2
  fi
}
has() { # has <description> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then pass=$((pass + 1))
  else fail=$((fail + 1)); printf 'FAIL  %s\n        missing: %s\n' "$1" "$2" >&2; fi
}
hasnt() {
  if grep -qF -- "$2" "$3"; then fail=$((fail + 1)); printf 'FAIL  %s\n        unexpected: %s\n' "$1" "$2" >&2
  else pass=$((pass + 1)); fi
}
# Pull one scalar out of the JSON without needing jq: the emitter is ours and its shape is fixed.
jget() { sed -n "s/.*\"$2\": *\"\{0,1\}\([^,\"}]*\)\"\{0,1\}.*/\1/p" "$1" | head -1 | tr -d ' '; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# =============================================================================================
# The sample sprint: 14 tickets, 3 lanes, day 0 2026-08-10, clock 2026-08-28.
# =============================================================================================
$M --format json --now "$NOW" "$F/sample-sprint.tsv" > "$tmp/s.json"
$M --format text --now "$NOW" "$F/sample-sprint.tsv" > "$tmp/s.txt"

ok "day 0 is taken from the board rung"        "2026-08-10" "$(jget "$tmp/s.json" day0)"
ok "the rung is reported"                      "R1"         "$(jget "$tmp/s.json" rung)"
ok "window length"                             "19"         "$(jget "$tmp/s.json" days)"
ok "ticket count"                              "14"         "$(jget "$tmp/s.json" tickets)"
ok "delivered = merged closing PR only"        "8"          "$(jget "$tmp/s.json" delivered)"
ok "open excludes the reopened-then-open one"  "4"          "$(jget "$tmp/s.json" open)"
ok "done by opinion is counted apart"          "1"          "$(jget "$tmp/s.json" by_opinion)"
ok "NOT_PLANNED is counted apart"              "1"          "$(jget "$tmp/s.json" not_planned)"
ok "lane count"                                "3"          "$(jget "$tmp/s.json" lanes)"

# The daily series must account for exactly the delivered tickets, or one of them is being
# dropped or double-counted somewhere between classification and bucketing.
sum=$(sed -n 's/.*"delivered_per_day": \[\([^]]*\)\].*/\1/p' "$tmp/s.json" | tr ',' '\n' | awk '{s+=$1} END{print s+0}')
ok "daily series sums to delivered"            "8"          "$sum"

# Burnup must never fall: a decreasing scope line would mean an item left the board unnoticed.
mono=$(sed -n 's/.*"cumulative_sequenced": \[\([^]]*\)\].*/\1/p' "$tmp/s.json" | tr ',' '\n' |
       awk 'NR>1 && $1<p {bad=1} {p=$1} END{print bad?"decreasing":"monotonic"}')
ok "cumulative sequenced is monotonic"         "monotonic"  "$mono"
last=$(sed -n 's/.*"cumulative_sequenced": \[\([^]]*\)\].*/\1/p' "$tmp/s.json" | tr ',' '\n' | tail -1)
ok "sequenced ends at the ticket count"        "14"         "$last"

# Stage n differs per stage by construction: #102 has a negative queue (commit predates the
# issue) and #114 has no commit at all, so pooling them would invent a denominator.
ok "queue n excludes the negative one"  "6" "$(sed -n 's/.*"key": "queue", "n": \([0-9]*\).*/\1/p' "$tmp/s.json")"
ok "build n excludes the commitless one" "7" "$(sed -n 's/.*"key": "build", "n": \([0-9]*\).*/\1/p' "$tmp/s.json")"
ok "review n covers every delivered PR"  "8" "$(sed -n 's/.*"key": "review", "n": \([0-9]*\).*/\1/p' "$tmp/s.json")"

# Hand-computed: queue sorted 1,1,2,3,3,4 -> median 2.5d = 216000s; nearest-rank p90 = 4d.
ok "queue median (2.5 d)"  "216000"  "$(sed -n 's/.*"key": "queue", "n": [0-9]*, "median_s": \([0-9-]*\).*/\1/p' "$tmp/s.json")"
ok "queue p90 (4 d)"       "345600"  "$(sed -n 's/.*"key": "queue".*"p90_s": \([0-9-]*\).*/\1/p' "$tmp/s.json")"
# build sorted 1,1,1,2,2,3,15 -> median 2d; p90 is the 15d outlier, which must survive as p90.
ok "build median (2 d)"    "172800"  "$(sed -n 's/.*"key": "build", "n": [0-9]*, "median_s": \([0-9-]*\).*/\1/p' "$tmp/s.json")"
ok "build p90 keeps the outlier (15 d)" "1296000" "$(sed -n 's/.*"key": "build".*"p90_s": \([0-9-]*\).*/\1/p' "$tmp/s.json")"

# Total cycle only counts tickets with all three stages present: 3,3,5.2,7,8,9 -> median 6.1d.
ok "total cycle n"         "6"       "$(sed -n 's/.*"cycle_total": { "n": \([0-9]*\).*/\1/p' "$tmp/s.json")"
ok "total cycle median (6.125 d)" "529200" "$(sed -n 's/.*"cycle_total".*"median_s": \([0-9-]*\).*/\1/p' "$tmp/s.json")"

# Each integrity check must fire exactly once — the fixture carries exactly one of each.
for k in reopened reverted done_by_opinion merged_ci_red merged_ci_absent not_planned no_lane no_order; do
  ok "integrity: $k fires once" "1" "$(sed -n "s/.*\"$k\": \([0-9]*\).*/\1/p" "$tmp/s.json" | tail -1)"
done

# Three windows, three dates. 2 in 7d, 7 in 14d, 8 in 19d against 5 remaining.
ok "forecast remaining"     "5"           "$(jget "$tmp/s.json" remaining)"
ok "forecast has a basis"   "true"        "$(jget "$tmp/s.json" basis)"
ok "7-day finish"  "2026-09-15" "$(sed -n 's/.*"span_days": 7,.*"finish": "\([0-9-]*\)".*/\1/p' "$tmp/s.json")"
ok "14-day finish" "2026-09-07" "$(sed -n 's/.*"span_days": 14,.*"finish": "\([0-9-]*\)".*/\1/p' "$tmp/s.json")"
ok "19-day finish" "2026-09-09" "$(sed -n 's/.*"span_days": 19,.*"finish": "\([0-9-]*\)".*/\1/p' "$tmp/s.json")"

has   "the negative queue is reported, not zeroed" "Queue is negative" "$tmp/s.txt"
has   "the pre-day-0 commit is reported"           "predates day 0"    "$tmp/s.txt"
has   "a stale blocker is named"                   "yes — stale"       "$tmp/s.txt"
has   "the lane caption refuses a per-person read" "not a person"      "$tmp/s.txt"

# =============================================================================================
# The empty sprint: a window exists, but nothing has been delivered.
# =============================================================================================
$M --format text --now "$NOW" "$F/empty-sprint.tsv" > "$tmp/e.txt"
has   "no throughput forecasts nothing"    "No basis for a forecast"  "$tmp/e.txt"
hasnt "no throughput invents no date"      "Finish"                   "$tmp/e.txt"
has   "an empty stage is undetermined"     "undetermined"             "$tmp/e.txt"
has   "checked-none is said out loud"      "checked, none"            "$tmp/e.txt"

# =============================================================================================
# The small sprint: every stage has n=3, so no percentile may be claimed.
# =============================================================================================
$M --format text --now "$NOW_SMALL" "$F/small-sprint.tsv" > "$tmp/m.txt"
has   "n<5 prints no p90"                  "n<5"                       "$tmp/m.txt"
has   "n<5 prints the sorted list instead" "**Queue** (n=3): 1.0, 1.0, 2.0" "$tmp/m.txt"
has   "a tie is not called a bottleneck"   "No single stage dominates" "$tmp/m.txt"

# =============================================================================================
# Rendering contracts.
# =============================================================================================
$M --format html     --now "$NOW" "$F/sample-sprint.tsv" > "$tmp/r.html"
$M --format artifact --now "$NOW" "$F/sample-sprint.tsv" > "$tmp/r.frag"

ok "html is a whole document"   "1" "$(grep -c '^<!doctype html>' "$tmp/r.html")"
ok "artifact carries no doctype/html/head/body" "0" "$(grep -ciE '<!doctype|<html|<head|<body' "$tmp/r.frag")"
ok "artifact opens with its title" "1" "$(head -1 "$tmp/r.frag" | grep -c '^<title>')"
ok "five charts are drawn"      "5" "$(grep -c '<svg ' "$tmp/r.html")"
ok "divs balance"               "$(grep -o '<div' "$tmp/r.html" | wc -l)" "$(grep -o '</div>' "$tmp/r.html" | wc -l)"
# A stylesheet, script, image or font from anywhere would break the offline and Artifact cases.
ok "no external resource is referenced" "0" \
   "$(grep -ocE '(src=|@import|<link |url\()' "$tmp/r.html" | head -1)"
ok "both themes are defined"    "1" "$(grep -c 'prefers-color-scheme:dark' "$tmp/r.html")"
ok "an explicit dark override exists" "1" "$(grep -c 'data-theme=\"dark\"' "$tmp/r.html")"

# Purity: the same input and the same clock must give the same bytes, or week-to-week
# comparison compares the renderer with itself rather than the sprint with last week.
$M --format json --now "$NOW" "$F/sample-sprint.tsv" > "$tmp/s2.json"
if cmp -s "$tmp/s.json" "$tmp/s2.json"; then pass=$((pass + 1))
else fail=$((fail + 1)); echo "FAIL  output is not deterministic across runs" >&2; fi

# --ascii must not change a single number, only the glyphs.
$M --format json --now "$NOW" --ascii "$F/sample-sprint.tsv" > "$tmp/s3.json"
if cmp -s "$tmp/s.json" "$tmp/s3.json"; then pass=$((pass + 1))
else fail=$((fail + 1)); echo "FAIL  --ascii changed the numbers, not just the glyphs" >&2; fi
$M --format text --now "$NOW" --ascii "$F/sample-sprint.tsv" > "$tmp/a.txt"
hasnt "--ascii emits no U+2581 block glyphs" "▁" "$tmp/a.txt"
hasnt "--ascii emits no U+2588 bar glyphs"   "█" "$tmp/a.txt"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
