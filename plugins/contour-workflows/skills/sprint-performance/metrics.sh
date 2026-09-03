#!/usr/bin/env bash
#
# sprint-metrics — turn a normalized sprint TSV event stream into a performance report.
#
# Usage:
#   metrics.sh [--format text|html|artifact|json] [--since YYYY-MM-DD]
#              [--now YYYY-MM-DDTHH:MM:SSZ] [--out FILE] [--ascii] [--full] [FILE]
#   metrics.sh --self-test
#
# FILE defaults to stdin. The input contract is produced by gather.sh:
#
#   M <TAB> key   <TAB> value
#   T <TAB> num   <TAB> lane <TAB> phase <TAB> status <TAB> order <TAB> blocked_by <TAB> url <TAB> title
#   E <TAB> num   <TAB> kind <TAB> iso8601 [<TAB> detail]
#   P <TAB> prnum <TAB> num  <TAB> state <TAB> headref <TAB> ci <TAB> url <TAB> title
#
# There is deliberately no author, assignee or merged-by column anywhere in that schema. Lanes are
# components, not people (lib/team-protocol.md), and a per-person breakdown is impossible here
# because the data was never collected — a guardrail implemented rather than asserted.
#
# This script is a PURE FUNCTION of (input, --now, --since, --ascii, --full). Same inputs give
# byte-identical output, which is what makes the golden test and week-to-week comparison possible.
# Everything that touches the network lives in gather.sh instead.
#
# Extending behaviour = adding a row to one of the tables below, never editing logic.
#
# Portability contract, because every one of these has bitten a report like this before:
#   * POSIX awk only. No mktime, no strftime, no gensub, no asort — mawk and BSD awk lack them.
#   * No `date -d` (GNU-only) and no `date -v` (BSD-only). All date maths is dfc()/cfd() in awk.
#   * No external `sort`: on Windows it may resolve to System32\sort.exe, a different program with
#     no -n, which would silently produce wrong percentiles. Sorting happens in awk.
#   * Never substr() into a UTF-8 glyph: awk is byte-oriented and would return half a character.
#     Glyph tables are arrays built with split(), never sliced strings.
#   * Markdown tables, never fixed-width: printf "%-*s" pads by BYTES, so a 10-glyph bar counts
#     as 30 columns and gets no padding at all.

set -euo pipefail

self="${BASH_SOURCE[0]}"
here="$(cd "$(dirname "$self")" && pwd)"

die() { printf 'sprint-metrics: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# Table 1 — the palettes, emitted as CSS custom properties. SVG references them through var(),
# which resolves for inline SVG and would not for an <img src="data:...">, which is exactly why
# the charts are inlined rather than embedded.
#   key|light|dark
# ---------------------------------------------------------------------------------------------
palette='bg|#ffffff|#15171b
surface|#f6f7f9|#1c1f25
ink|#1f2328|#e6e8eb
muted|#646b74|#9aa1ab
grid|#e7eaee|#282d35
axis|#c9ced5|#3a414b
accent|#3b6ea5|#6fa8dc
done|#2f7d5d|#5cbf95
review|#3b6ea5|#6fa8dc
build|#b07d33|#d8a75a
queue|#8a8f98|#7d8590
warn|#b4453a|#e0715f'

# ---------------------------------------------------------------------------------------------
# Table 2 — the reconstructed stages. Each is bounded by two timestamps that actually exist; a
# stage whose bounds are missing is undetermined for that ticket and is excluded from its sample,
# never imputed.
#   key|label|from|to|palette
# ---------------------------------------------------------------------------------------------
stages='queue|Queue|created|first_commit|queue
build|Build|first_commit|pr_created|build
review|Review|pr_created|pr_merged|review'

format=text
out=""
now=""
since=""
ascii=0
full=0
input=""

while [ $# -gt 0 ]; do
  case "$1" in
    --format)    format="${2:-}"; shift 2 ;;
    --out)       out="${2:-}";    shift 2 ;;
    --now)       now="${2:-}";    shift 2 ;;
    --since)     since="${2:-}";  shift 2 ;;
    --ascii)     ascii=1; shift ;;
    --full)      full=1;  shift ;;
    --self-test) exec bash "$here/selftest.sh" "$here" ;;
    -h|--help)   sed -n '2,30p' "$self"; exit 0 ;;
    --)          shift; break ;;
    -*)          die "unknown option: $1" ;;
    *)           input="$1"; shift ;;
  esac
done

case "$format" in
  text|html|artifact|json) ;;
  *) die "unknown --format: $format (want text, html, artifact or json)" ;;
esac

[ -n "$now" ] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The awk program lives in a quoted heredoc rather than a single-quoted argument so that emitted
# English prose may contain apostrophes. It is still inside this file, so `bash -n` and shellcheck
# still see the whole script.
awk_program() {
  cat <<'AWKEOF'
# =============================================================================================
# Date arithmetic — Hinnant days-from-civil and its inverse. Pure integer maths: no mktime, no
# strftime, no `date -d`. Verified against mawk for epoch 0, 2000-02-29, 2024-02-29 and year ends.
# =============================================================================================
function dfc(y, m, d,   era, yoe, doy, doe) {
    y -= (m <= 2)
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
}
function cfd(z,   era, doe, yoe, y, doy, mp, d, m) {
    z += 719468
    era = int((z >= 0 ? z : z - 146096) / 146097)
    doe = z - era * 146097
    yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
    y   = yoe + era * 400
    doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
    mp  = int((5 * doy + 2) / 153)
    d   = doy - int((153 * mp + 2) / 5) + 1
    m   = mp + (mp < 10 ? 3 : -9)
    y  += (m <= 2)
    return sprintf("%04d-%02d-%02d", y, m, d)
}
function dnum(ts)  { return dfc(substr(ts,1,4)+0, substr(ts,6,2)+0, substr(ts,9,2)+0) }
function epoch(ts) { if (ts == "") return -1
    return dnum(ts) * 86400 + substr(ts,12,2)*3600 + substr(ts,15,2)*60 + substr(ts,18,2) }
function dayidx(ts) { return dnum(ts) - D0 }
function clampd(d)  { if (d < 0) return 0; if (d >= NDAYS) return NDAYS - 1; return d }

# =============================================================================================
# Statistics. Insertion sort, because asort is a gawk extension and an external `sort` is a
# Windows landmine. Nearest-rank, because interpolating a p90 over eleven samples is a fiction.
# =============================================================================================
function isort(a, n,   i, j, k) {
    for (i = 2; i <= n; i++) { k = a[i]; j = i - 1
        while (j > 0 && a[j] > k) { a[j+1] = a[j]; j-- }
        a[j+1] = k }
}
function pctl(a, n, p,   r) {
    if (n < 1) return -1
    r = int(p * n / 100 + 0.9999); if (r < 1) r = 1; if (r > n) r = n
    return a[r]
}
function medn(a, n) {
    if (n < 1) return -1
    return (n % 2) ? a[int((n+1)/2)] : (a[n/2] + a[n/2+1]) / 2.0
}

# =============================================================================================
# Text helpers. Glyphs live in arrays: substr() into a UTF-8 string returns bytes, not characters.
# =============================================================================================
function spark(v, n, mx,   i, s, k) {
    s = ""
    for (i = 0; i < n; i++) {
        if (v[i] + 0 == 0) { s = s ZERO; continue }
        k = int((v[i] / mx) * (NG - 1) + 0.5) + 1
        if (k > NG) k = NG; if (k < 1) k = 1
        s = s GL[k]
    }
    return s
}
function bar(frac, w,   i, s, f) {
    if (frac < 0) frac = 0
    if (frac > 1) frac = 1
    f = int(frac * w + 0.5); s = ""
    for (i = 0; i < f; i++) s = s BF
    for (i = f; i < w; i++) s = s BE
    return s
}
function esc_h(s,   i, c, o) { o = ""
    for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
        if      (c == "&")  o = o "&amp;"
        else if (c == "<")  o = o "&lt;"
        else if (c == ">")  o = o "&gt;"
        else if (c == "\"") o = o "&quot;"
        else o = o c }
    return o }
function esc_j(s,   i, c, o) { o = ""
    for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
        if      (c == "\\") o = o "\\\\"
        else if (c == "\"") o = o "\\\""
        else if (c == "\t" || c == "\n" || c == "\r") o = o " "
        else o = o c }
    return o }
function esc_m(s,   i, c, o) { o = ""
    for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
        if (c == "|") o = o "\\|"
        else if (c == "\t" || c == "\n" || c == "\r") o = o " "
        else o = o c }
    return o }
function dur(sec,   d, h, m) {
    if (sec < 0) return "n/a"
    d = int(sec / 86400); h = int((sec % 86400) / 3600); m = int((sec % 3600) / 60)
    if (d > 0) return (h > 0) ? sprintf("%dd %dh", d, h) : sprintf("%dd", d)
    if (h > 0) return sprintf("%dh", h)
    return sprintf("%dm", m)
}
function dayf(sec) { return (sec < 0) ? "n/a" : sprintf("%.1f", sec / 86400.0) }
function nice_max(v,   e, f) {
    if (v <= 0) return 1
    e = 1; while (v / e >= 10) e = e * 10
    f = v / e
    if      (f <= 1)   f = 1
    else if (f <= 1.5) f = 1.5
    else if (f <= 2)   f = 2
    else if (f <= 3)   f = 3
    else if (f <= 5)   f = 5
    else               f = 10
    return f * e
}
function stamp(n, which) {
    if (which == "created")      return ev_created[n]
    if (which == "first_commit") return ev_fc[n]
    if (which == "pr_created")   return ev_pr[n]
    if (which == "pr_merged")    return ev_merged[n]
    return ""
}

# =============================================================================================
BEGIN {
    NG = split("\342\226\201|\342\226\202|\342\226\203|\342\226\204|\342\226\205|\342\226\206|\342\226\207|\342\226\210", GL, "|")
    BF = "\342\226\210"; BE = "\342\226\221"; ZERO = "\302\267"
    if (ASCII + 0 == 1) {
        NG = split(".|:|-|=|+|*|#|%", GL, "|")
        BF = "#"; BE = "."; ZERO = " "
    }
    NPAL = split(PALETTE, PR_, "\n")
    for (i = 1; i <= NPAL; i++) { split(PR_[i], f, "|"); PK[i] = f[1]; PL[i] = f[2]; PD[i] = f[3] }
    NST = split(STAGES, SR, "\n")
    for (i = 1; i <= NST; i++) { split(SR[i], f, "|")
        ST_KEY[i] = f[1]; ST_LAB[i] = f[2]; ST_FROM[i] = f[3]; ST_TO[i] = f[4]; ST_PAL[i] = f[5] }
}

$1 == "M" { if ($2 == "unknown") UNK[++nunk] = $3; else meta[$2] = $3; next }

$1 == "T" {
    n = $2
    if (!(n in seen)) { seen[n] = 1; NUMS[++nt] = n }
    tk_lane[n] = $3; tk_phase[n] = $4; tk_status[n] = $5
    tk_order[n] = $6; tk_block[n] = $7; tk_url[n] = $8; tk_title[n] = $9
    next
}

$1 == "E" {
    n = $2; k = $3; ts = $4; dt = $5
    if      (k == "issue_created") ev_created[n] = ts
    else if (k == "item_added")    ev_added[n]   = ts
    else if (k == "first_commit")  ev_fc[n]      = ts
    else if (k == "pr_created")    ev_pr[n]      = ts
    else if (k == "pr_merged")     ev_merged[n]  = ts
    else if (k == "issue_closed")  { ev_closed[n] = ts; ev_reason[n] = dt }
    else if (k == "reopened")      ev_reopen[n]  = ts
    else if (k == "revert")        ev_revert[n]  = ts
    next
}

$1 == "P" {
    p = $2; n = $3
    pr_state[p] = $4; pr_ci[p] = $6; pr_url[p] = $7; pr_title[p] = $8
    npr++
    if ($4 == "MERGED") { tk_pr[n] = p; tk_ci[n] = $6 }
    next
}

# =============================================================================================
END {
    day0 = (SINCE != "") ? SINCE : meta["day0"]
    rung = (SINCE != "") ? "R0" : meta["day0_rung"]
    src  = (SINCE != "") ? "--since, given on the command line" : meta["day0_source"]
    if (day0 == "") {
        print "sprint-metrics: no day 0 in the input and no --since given" > "/dev/stderr"
        exit 2
    }

    D0 = dnum(day0); TODAY = substr(NOWTS, 1, 10); DT = dnum(TODAY)
    NDAYS = DT - D0 + 1; if (NDAYS < 1) NDAYS = 1
    NOWE = epoch(NOWTS)

    # ---- classify ---------------------------------------------------------------------------
    for (i = 1; i <= nt; i++) {
        n = NUMS[i]
        reop = (ev_reopen[n] != "" && (ev_closed[n] == "" || ev_reopen[n] > ev_closed[n]))
        if      (ev_merged[n] != "")                 { cls[n] = "delivered"; ndelivered++ }
        else if (ev_reason[n] == "NOT_PLANNED")      { cls[n] = "notplanned"; nnotplanned++ }
        else if (ev_closed[n] != "" && !reop)        { cls[n] = "byopinion";  nbyopinion++ }
        else                                         { cls[n] = "open";       nopen++ }
        if (tk_lane[n] != "") {
            if (!(tk_lane[n] in laneseen)) { laneseen[tk_lane[n]] = 1; LANES[++nlanes] = tk_lane[n] }
        } else nolane++
        if (tk_order[n] == "") noorder++
        if (ev_fc[n] != "" && ev_fc[n] < day0) EARLY[++nearly] = n
    }

    # ---- daily series -------------------------------------------------------------------------
    for (d = 0; d < NDAYS; d++) { mday[d] = 0; sday[d] = 0; wip[d] = 0 }
    maxm = 0
    for (i = 1; i <= nt; i++) {
        n = NUMS[i]
        if (cls[n] == "delivered") {
            d = clampd(dayidx(ev_merged[n])); mday[d]++
            if (mday[d] > maxm) maxm = mday[d]
            lane_wk[tk_lane[n] SUBSEP int(d / 7)]++
            lane_tot[tk_lane[n]]++
        }
        if (ev_added[n] != "") {
            d = clampd(dayidx(ev_added[n])); sday[d]++
            if (d > 0) { scope_n[d]++; scope_who[d] = scope_who[d] (scope_who[d] == "" ? "" : " ") "#" n }
        }
        if (ev_fc[n] != "") {
            a = clampd(dayidx(ev_fc[n]))
            b = (cls[n] == "delivered") ? clampd(dayidx(ev_merged[n])) : NDAYS - 1
            for (d = a; d <= b; d++) wip[d]++
        }
    }
    cum = 0; cums = 0; maxw = 0; wsum = 0
    for (d = 0; d < NDAYS; d++) {
        cum  += mday[d]; cmday[d] = cum
        cums += sday[d]; csday[d] = cums
        if (wip[d] > maxw) maxw = wip[d]
        wsum += wip[d]
        t7 = 0; c7 = 0
        for (j = d - 6; j <= d; j++) if (j >= 0) { t7 += mday[j]; c7++ }
        trail[d] = (c7 > 0) ? t7 / c7 : 0
    }
    meanwip = (NDAYS > 0) ? wsum / NDAYS : 0
    nweeks = int((NDAYS + 6) / 7)

    # ---- stages -------------------------------------------------------------------------------
    for (s = 1; s <= NST; s++) scount[s] = 0
    for (i = 1; i <= nt; i++) {
        n = NUMS[i]
        if (cls[n] != "delivered") continue
        DELIV[++ndl] = n
        tot = 0; havetot = 1
        for (s = 1; s <= NST; s++) {
            a = stamp(n, ST_FROM[s]); b = stamp(n, ST_TO[s])
            if (a == "" || b == "") { sv[n, s] = -1; havetot = 0
                MISSING[++nmissing] = n "|" ST_LAB[s] "|no " ST_FROM[s] ; continue }
            v = epoch(b) - epoch(a)
            if (v < 0) { sv[n, s] = -2; havetot = 0
                NEG[++nneg] = n "|" ST_LAB[s]; continue }
            sv[n, s] = v; SS[s, ++scount[s]] = v; tot += v
        }
        totv[n] = havetot ? tot : -1
        if (havetot) TOT[++ntot] = tot
    }
    for (s = 1; s <= NST; s++) {
        cnt = scount[s]
        for (j = 1; j <= cnt; j++) tmp[j] = SS[s, j]
        isort(tmp, cnt)
        for (j = 1; j <= cnt; j++) SORTED[s, j] = tmp[j]
        smed[s] = medn(tmp, cnt); sp90[s] = pctl(tmp, cnt, 90)
        ssum[s] = 0
        for (j = 1; j <= cnt; j++) ssum[s] += tmp[j]
        split("", tmp)
    }
    isort(TOT, ntot)
    tmed = medn(TOT, ntot); tp90 = pctl(TOT, ntot, 90)
    bottleneck = ""; bmax = -1; bsecond = -1
    for (s = 1; s <= NST; s++) if (scount[s] > 0 && smed[s] > bmax) { bmax = smed[s]; bottleneck = ST_LAB[s] }
    for (s = 1; s <= NST; s++) if (scount[s] > 0 && ST_LAB[s] != bottleneck && smed[s] > bsecond) bsecond = smed[s]
    # A stage that only ties for the lead is not a bottleneck. Naming one anyway would invent a
    # finding out of a rounding difference, which is the failure this whole report exists against.
    btie = (bmax > 0 && bsecond >= 0 && (bmax - bsecond) / bmax < 0.15)

    # ---- aging WIP ----------------------------------------------------------------------------
    nage = 0
    for (i = 1; i <= nt; i++) {
        n = NUMS[i]
        if (cls[n] != "open") continue
        if      (ev_fc[n] != "")      { agev[n] = NOWE - epoch(ev_fc[n]);      agest[n] = "in flight" }
        else if (ev_created[n] != "") { agev[n] = NOWE - epoch(ev_created[n]); agest[n] = "not started" }
        else continue
        AGE[++nage] = n
    }
    for (i = 1; i < nage; i++) for (j = 1; j <= nage - i; j++)
        if (agev[AGE[j]] < agev[AGE[j+1]]) { sw = AGE[j]; AGE[j] = AGE[j+1]; AGE[j+1] = sw }

    # ---- trailing rates and forecast ------------------------------------------------------------
    remaining = nopen + nbyopinion
    split("7 14 28", WINS, " ")
    anyrate = 0
    for (w = 1; w <= 3; w++) {
        span = WINS[w] + 0; if (span > NDAYS) span = NDAYS
        c = 0
        for (d = NDAYS - span; d < NDAYS; d++) if (d >= 0) c += mday[d]
        rspan[w] = span; rcount[w] = c; rate[w] = (span > 0) ? c / span : 0
        if (rate[w] > 0) { anyrate = 1
            fdays[w] = int(remaining / rate[w] + 0.9999); fdate[w] = cfd(DT + fdays[w]) }
        else { fdays[w] = -1; fdate[w] = "" }
    }
    littles = (meanwip > 0 && rate[3] > 0) ? meanwip / rate[3] : -1

    if      (FORMAT == "text") render_text()
    else if (FORMAT == "json") render_json()
    else                       render_html()
}

# =============================================================================================
# Renderer — terminal. Markdown tables, because printf pads by bytes and a Unicode bar would
# destroy every fixed-width column. Sparklines carry the texture; the tables carry the numbers.
# =============================================================================================
function hdr(t) { printf "\n## %s\n\n", t }
function kv(k, v) { printf "| %s | %s |\n", k, v }
function nn(v) { return (v == "" || v + 0 != v) ? "0" : v }

function render_text(   i, n, s, d, w, c, lab, line, k, tot, sh, any) {
    printf "# Sprint performance — %s\n", (meta["board_title"] != "" ? meta["board_title"] : "sprint")
    printf "\n_%s → %s · %d days · reconstructed from timestamps, not from board history._\n",
           day0, TODAY, NDAYS

    hdr("The window")
    print "| | |"; print "|---|---|"
    kv("Day 0", sprintf("%s — %s (%s)", day0, src, rung))
    if (meta["day0_alt"] != "") kv("One rung up", meta["day0_alt"])
    kv("Elapsed", sprintf("%d days · %.1f weeks", NDAYS, NDAYS / 7.0))
    kv("Tickets", sprintf("%d — %d delivered, %d open, %d done by opinion, %d not planned",
                          nt, ndelivered, nopen, nbyopinion, nnotplanned))
    kv("Pull requests", npr + 0)
    kv("Lanes", nlanes + 0)
    kv("Mode", (meta["mode"] != "" ? meta["mode"] : "unknown"))
    if (meta["commits_source"] != "") kv("Commit dates from", meta["commits_source"])
    print ""
    print "Every rate below carries the n it was computed from. A window this short is a handful of"
    print "events, not a trend — read the counts, not the slope."

    # ---- throughput -------------------------------------------------------------------------
    hdr("Throughput")
    printf "Delivered per day (%s = none):\n\n", ZERO
    printf "    %s\n", spark(mday, NDAYS, (maxm > 0 ? maxm : 1))
    printf "    one cell per day, %s to %s, tallest = %d\n", day0, TODAY, maxm
    printf "\n| Week | Days | Delivered | Cumulative | Rate/day |\n|---|---|---:|---:|---:|\n"
    for (w = 0; w < nweeks; w++) {
        c = 0; dcount = 0
        for (d = w * 7; d < (w + 1) * 7 && d < NDAYS; d++) { c += mday[d]; dcount++ }
        lab = sprintf("W%d", w + 1)
        if (dcount < 7) lab = lab " *"
        printf "| %s | %s → %s | %d | %d | %.2f |\n", lab,
               cfd(D0 + w * 7), cfd(D0 + (w * 7 + dcount - 1)), c, cmday[clampd((w+1)*7 - 1)],
               (dcount > 0 ? c / dcount : 0)
    }
    print ""
    print "`*` marks a partial week. Weeks are sprint-relative (W1 starts on day 0), not calendar"
    print "weeks — a calendar week that starts mid-sprint gives a short first bucket that reads as"
    print "a slow start."

    if (nlanes > 0) {
        printf "\n| Lane | Delivered |"
        for (w = 0; w < nweeks; w++) printf " W%d |", w + 1
        printf "\n|---|---:|"
        for (w = 0; w < nweeks; w++) printf "---:|"
        printf "\n"
        for (i = 1; i <= nlanes; i++) {
            printf "| %s | %d |", esc_m(LANES[i]), lane_tot[LANES[i]] + 0
            for (w = 0; w < nweeks; w++) printf " %d |", lane_wk[LANES[i], w] + 0
            printf "\n"
        }
        print ""
        print "A lane is a **component**, not a person. A slow lane means that component's tickets sit"
        print "in review or land late; the data to read it any other way was never collected."
    }

    # ---- burnup -----------------------------------------------------------------------------
    hdr("Burnup and scope")
    printf "| Day | Date | Delivered | Sequenced | |\n|---|---|---:|---:|---|\n"
    step = int(NDAYS / 12); if (step < 1) step = 1
    for (d = 0; d < NDAYS; d += step) {
        printf "| %d | %s | %d | %d | `%s` |\n", d, cfd(D0 + d), cmday[d], csday[d],
               bar((csday[d] > 0 ? cmday[d] / csday[d] : 0), 16)
    }
    if ((NDAYS - 1) % step != 0) {
        d = NDAYS - 1
        printf "| %d | %s | %d | %d | `%s` |\n", d, cfd(D0 + d), cmday[d], csday[d],
               bar((csday[d] > 0 ? cmday[d] / csday[d] : 0), 16)
    }
    print ""
    print "This is a **burnup**, not a burndown: the sequenced total is its own column, so scope"
    print "growth shows up as a rising denominator instead of being laundered into the percentage."
    any = 0
    for (d = 1; d < NDAYS; d++) if (scope_n[d] > 0) {
        if (!any) { printf "\nScope moved after day 0:\n\n| Date | Added | Tickets |\n|---|---:|---|\n"; any = 1 }
        printf "| %s | +%d | %s |\n", cfd(D0 + d), scope_n[d], scope_who[d]
    }
    if (!any) print "\nScope did not move after day 0 — checked, none."

    # ---- flow -------------------------------------------------------------------------------
    hdr("Work in flight")
    printf "Concurrent tickets between first commit and merge (peak %d):\n\n", maxw
    printf "    %s\n\n", spark(wip, NDAYS, (maxw > 0 ? maxw : 1))
    print "| | |"; print "|---|---|"
    kv("Mean WIP", sprintf("%.1f", meanwip))
    kv("Peak WIP", maxw + 0)
    if (littles >= 0 && tmed >= 0) {
        kv("WIP ÷ throughput (whole window)", sprintf("%.1f days", littles))
        kv("Measured median cycle time", dayf(tmed) " days")
        if (tmed > 0 && (littles / (tmed / 86400.0) > 2 || (tmed / 86400.0) / littles > 2))
            kv("**Disagreement**", "the two differ by more than 2× — usually unmerged work piling up")
    } else {
        kv("WIP ÷ throughput", "no basis — throughput is zero over the window")
    }

    # ---- stages -----------------------------------------------------------------------------
    hdr("Where the time goes")
    printf "| Stage | n | Median | p90 | Longest | Share of median total |\n|---|---:|---:|---:|---:|---|\n"
    sh = 0
    for (s = 1; s <= NST; s++) if (smed[s] >= 0) sh += smed[s]
    for (s = 1; s <= NST; s++) {
        if (scount[s] < 1) { printf "| %s | 0 | undetermined | undetermined | undetermined | |\n", ST_LAB[s]; continue }
        printf "| %s | %d | %s d | %s | %s d | `%s` |\n", ST_LAB[s], scount[s],
               dayf(smed[s]), (scount[s] < 5 ? "n<5" : dayf(sp90[s]) " d"),
               dayf(SORTED[s, scount[s]]), bar((sh > 0 ? smed[s] / sh : 0), 12)
    }
    if (ntot > 0) printf "| **Total** | %d | %s d | %s | %s d | |\n", ntot, dayf(tmed),
                         (ntot < 5 ? "n<5" : dayf(tp90) " d"), dayf(TOT[ntot])
    print ""
    small = 0
    for (s = 1; s <= NST; s++) if (scount[s] > 0 && scount[s] < 5) small = 1
    if (small) {
        print "With n<5 there is no ninetieth percentile, only a sorted list:"
        print ""
        for (s = 1; s <= NST; s++) {
            if (scount[s] < 1 || scount[s] >= 5) continue
            line = ""
            for (j = 1; j <= scount[s]; j++) line = line (j > 1 ? ", " : "") dayf(SORTED[s, j])
            printf "- **%s** (n=%d): %s\n", ST_LAB[s], scount[s], line
        }
        print ""
    }
    if (bottleneck != "" && !btie)
        printf "The largest median share is **%s** — that is where the sprint is slow.\n", bottleneck
    else if (bottleneck != "")
        print "No single stage dominates — the medians are within 15% of each other, which is a tie, not a bottleneck."
    print "Medians and p90, never a mean: one long ticket moves a mean of ten and moves the median by"
    print "nothing. Each stage carries its own n, because a ticket with no commit has no build stage"
    print "and pooling them would invent a denominator."
    if (ntot > 0) {
        printf "\n| Ticket | Queue | Build | Review | Total | Lane |\n|---|---:|---:|---:|---:|---|\n"
        for (i = 1; i <= ndl; i++) {
            n = DELIV[i]
            printf "| [#%s](%s) %s |", n, tk_url[n], esc_m(trunc_t(tk_title[n]))
            for (s = 1; s <= NST; s++) printf " %s |", (sv[n, s] >= 0 ? dayf(sv[n, s]) : "—")
            printf " %s | %s |\n", (totv[n] >= 0 ? dayf(totv[n]) : "—"), esc_m(tk_lane[n])
        }
    }

    # ---- aging ------------------------------------------------------------------------------
    hdr("Aging work in progress")
    if (nage == 0) print "No open tickets — checked, none."
    else {
        printf "| Ticket | State | Age | vs p90 | Lane |\n|---|---|---:|---|---|\n"
        for (i = 1; i <= nage; i++) {
            n = AGE[i]
            flag = (tp90 > 0 && agev[n] > tp90) ? "**past p90**" : (tp90 > 0 ? "within" : "no p90 yet")
            printf "| [#%s](%s) %s | %s | %s | %s | %s |\n", n, tk_url[n], esc_m(trunc_t(tk_title[n])),
                   agest[n], dur(agev[n]), flag, lanename(tk_lane[n])
        }
        print ""
        print "Cycle time of finished work is a lagging indicator by construction — it can only"
        print "describe tickets that already landed. The item past p90 is the one going wrong now."
    }

    # ---- blocked ----------------------------------------------------------------------------
    hdr("Blocked")
    any = 0
    for (i = 1; i <= nt; i++) {
        n = NUMS[i]
        if (tk_status[n] != "Blocked" && tk_block[n] == "") continue
        if (!any) { printf "| Ticket | Blocked by | Blocker landed? | Blocked since |\n|---|---|---|---|\n"; any = 1 }
        bl = tk_block[n]; bnum = bl; gsub(/[^0-9]/, "", bnum)
        landed = (bnum != "" && cls[bnum] == "delivered") ? "**yes — stale**" : "no"
        printf "| [#%s](%s) %s | %s | %s | not recorded |\n", n, tk_url[n], esc_m(trunc_t(tk_title[n])),
               (bl != "" ? esc_m(bl) : "—"), landed
    }
    if (!any) print "Nothing is marked blocked — checked, none."
    else {
        print ""
        print "`Blocked by` carries no timestamp, so blocked-since is **not recorded** anywhere. A"
        print "blocker that already landed is the most common piece of stale board state there is."
    }

    # ---- integrity --------------------------------------------------------------------------
    hdr("Integrity")
    printf "| Check | Count | Tickets |\n|---|---:|---|\n"
    icheck("Reopened", "reopen")
    icheck("Reverted", "revert")
    icheck("Done by opinion (no merged closing PR)", "byopinion")
    icheck("Merged with CI red", "cired")
    icheck("Merged with no CI result at all", "ciabsent")
    icheck("Closed as not planned (excluded from throughput)", "notplanned")
    icheck("No lane — nobody will pick these up", "nolane")
    icheck("No order", "noorder")
    print ""
    print "Absent, pending, skipped, failed and passed are five CI states and they are kept apart. A"
    print "repository on legacy commit statuses reports `state` rather than `conclusion`, and a"
    print "reader that knows only the latter calls a healthy project unchecked."

    # ---- forecast ---------------------------------------------------------------------------
    hdr("Forecast")
    if (!anyrate) {
        printf "**No basis for a forecast.** Nothing was delivered in the trailing window, so there is\n"
        printf "no rate to divide %d remaining tickets by. That is the finding, not a distant date.\n", remaining
    } else {
        printf "%d tickets remain (%d open, %d closed without a merged PR).\n\n", remaining, nopen, nbyopinion
        printf "| Trailing window | Delivered | Rate/day | Days left | Finish |\n|---|---:|---:|---:|---|\n"
        for (w = 1; w <= 3; w++) {
            if (rate[w] > 0)
                printf "| last %d days | %d | %.2f | %d | %s |\n", rspan[w], rcount[w], rate[w], fdays[w], fdate[w]
            else
                printf "| last %d days | %d | 0.00 | — | no basis |\n", rspan[w], rcount[w]
        }
        print ""
        print "Three rates, three dates, and **the spread between them is the finding** — not any one"
        print "of them. A single date would be a forecast the data cannot support."
    }

    # ---- unknowns ---------------------------------------------------------------------------
    hdr("What could not be determined")
    any = 0
    for (i = 1; i <= nunk; i++) { printf "- %s\n", UNK[i]; any = 1 }
    for (i = 1; i <= nneg; i++) {
        split(NEG[i], f, "|")
        printf "- #%s — %s is negative: the first commit predates the issue, so the ticket was filed after the work started. Excluded from the %s sample rather than counted as zero.\n", f[1], f[2], f[2]
        any = 1
    }
    for (i = 1; i <= nearly; i++) {
        printf "- #%s — its first commit predates day 0. A rebased or long-lived branch keeps its original author date, so this may be real history rather than sprint work.\n", EARLY[i]
        any = 1
    }
    if (nmissing > 0) {
        c = 0
        for (i = 1; i <= nmissing; i++) { split(MISSING[i], f, "|"); c++ }
        printf "- %d stage measurements are missing a bound (a ticket with no commit has no build stage). Excluded from that stage's n, never imputed.\n", c
        any = 1
    }
    print "- Every `Status` transition. The board stores the current value and no history, so"
    print "  \"how long was this In Progress\" has no answer here — only the commit and PR proxies above."
    print "- Blocked duration. `Blocked by` has no timestamp."
    print "- Uncommitted work in a worktree. That is `/sprint-status` §*Quiet lanes*."
    if (!any) print "- Nothing else — checked, none."
}

function trunc_t(s) { return (length(s) > 46) ? substr(s, 1, 45) "\342\200\246" : s }
function lanename(l) { return (l == "") ? "*(no lane)*" : esc_m(l) }

function icheck(label, kind,   i, n, c, lst) {
    c = 0; lst = ""
    for (i = 1; i <= nt; i++) {
        n = NUMS[i]; hit = 0
        if      (kind == "reopen")     hit = (ev_reopen[n] != "")
        else if (kind == "revert")     hit = (ev_revert[n] != "")
        else if (kind == "byopinion")  hit = (cls[n] == "byopinion")
        else if (kind == "cired")      hit = (cls[n] == "delivered" && tk_ci[n] == "FAILURE")
        else if (kind == "ciabsent")   hit = (cls[n] == "delivered" && tk_ci[n] == "ABSENT")
        else if (kind == "notplanned") hit = (cls[n] == "notplanned")
        else if (kind == "nolane")     hit = (tk_lane[n] == "")
        else if (kind == "noorder")    hit = (tk_order[n] == "")
        if (hit) { c++; lst = lst (lst == "" ? "" : " ") "#" n }
    }
    printf "| %s | %d | %s |\n", label, c, (c > 0 ? lst : "checked, none")
}

# =============================================================================================
# Renderer — JSON. The series and the aggregates, so a caller can diff two runs. Floats are
# fixed to one decimal and durations stay integer seconds, so output is byte-stable across
# awk flavours rather than merely close.
# =============================================================================================
function render_json(   i, s, n, d, first) {
    printf "{\n"
    printf "  \"window\": { \"day0\": \"%s\", \"rung\": \"%s\", \"source\": \"%s\", \"today\": \"%s\", \"days\": %d, \"weeks\": \"%.1f\" },\n",
           esc_j(day0), esc_j(rung), esc_j(src), TODAY, NDAYS, NDAYS / 7.0
    printf "  \"counts\": { \"tickets\": %d, \"delivered\": %d, \"open\": %d, \"by_opinion\": %d, \"not_planned\": %d, \"prs\": %d, \"lanes\": %d },\n",
           nt, ndelivered + 0, nopen + 0, nbyopinion + 0, nnotplanned + 0, npr + 0, nlanes + 0
    printf "  \"series\": {\n"
    jarr("delivered_per_day", mday, NDAYS, 1)
    jarr("cumulative_delivered", cmday, NDAYS, 1)
    jarr("cumulative_sequenced", csday, NDAYS, 1)
    jarr("wip", wip, NDAYS, 0)
    printf "  },\n"
    printf "  \"stages\": [\n"
    for (s = 1; s <= NST; s++) {
        printf "    { \"key\": \"%s\", \"n\": %d, \"median_s\": %d, \"p90_s\": %d, \"sum_s\": %d }%s\n",
               ST_KEY[s], scount[s] + 0, smed[s], sp90[s], ssum[s] + 0, (s < NST ? "," : "")
    }
    printf "  ],\n"
    printf "  \"cycle_total\": { \"n\": %d, \"median_s\": %d, \"p90_s\": %d },\n", ntot + 0, tmed, tp90
    printf "  \"flow\": { \"mean_wip\": \"%.1f\", \"peak_wip\": %d, \"littles_days\": \"%.1f\" },\n",
           meanwip, maxw + 0, littles
    printf "  \"forecast\": { \"remaining\": %d, \"basis\": %s, \"windows\": [\n", remaining, (anyrate ? "true" : "false")
    for (i = 1; i <= 3; i++)
        printf "    { \"span_days\": %d, \"delivered\": %d, \"rate_per_day\": \"%.2f\", \"finish\": \"%s\" }%s\n",
               rspan[i], rcount[i], rate[i], fdate[i], (i < 3 ? "," : "")
    printf "  ] },\n"
    printf "  \"integrity\": {\n"
    jint("reopened", "reopen");        jint("reverted", "revert")
    jint("done_by_opinion", "byopinion"); jint("merged_ci_red", "cired")
    jint("merged_ci_absent", "ciabsent"); jint("not_planned", "notplanned")
    jint("no_lane", "nolane");         jintlast("no_order", "noorder")
    printf "  },\n"
    printf "  \"undetermined\": [\n"
    first = 1
    for (i = 1; i <= nunk; i++) { printf "%s    \"%s\"", (first ? "" : ",\n"), esc_j(UNK[i]); first = 0 }
    for (i = 1; i <= nneg; i++) { split(NEG[i], f, "|")
        printf "%s    \"#%s %s is negative\"", (first ? "" : ",\n"), f[1], esc_j(f[2]); first = 0 }
    for (i = 1; i <= nearly; i++) {
        printf "%s    \"#%s first commit predates day 0\"", (first ? "" : ",\n"), EARLY[i]; first = 0 }
    printf "%s  ]\n}\n", (first ? "" : "\n")
}
function jarr(name, a, n, comma,   i) {
    printf "    \"%s\": [", name
    for (i = 0; i < n; i++) printf "%s%d", (i ? "," : ""), a[i] + 0
    printf "]%s\n", (comma ? "," : "")
}
function jint(name, kind) { printf "    \"%s\": %d,\n", name, icount(kind) }
function jintlast(name, kind) { printf "    \"%s\": %d\n", name, icount(kind) }
function icount(kind,   i, n, c) {
    c = 0
    for (i = 1; i <= nt; i++) { n = NUMS[i]
        if      (kind == "reopen")     c += (ev_reopen[n] != "")
        else if (kind == "revert")     c += (ev_revert[n] != "")
        else if (kind == "byopinion")  c += (cls[n] == "byopinion")
        else if (kind == "cired")      c += (cls[n] == "delivered" && tk_ci[n] == "FAILURE")
        else if (kind == "ciabsent")   c += (cls[n] == "delivered" && tk_ci[n] == "ABSENT")
        else if (kind == "notplanned") c += (cls[n] == "notplanned")
        else if (kind == "nolane")     c += (tk_lane[n] == "")
        else if (kind == "noorder")    c += (tk_order[n] == "") }
    return c
}

# =============================================================================================
# Renderer — HTML. Inline SVG, no JavaScript, no external request of any kind. Two wrappers over
# one body: a standalone document for a browser, and a bare fragment for the Artifact tool, which
# supplies its own doctype/head/body and would nest a second one.
# =============================================================================================
function render_html(   i) {
    if (FORMAT == "html") {
        print "<!doctype html>"
        print "<html lang=\"en\">"
        print "<head>"
        print "<meta charset=\"utf-8\">"
        print "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        print "<meta name=\"color-scheme\" content=\"light dark\">"
        emit_title(); emit_style()
        print "</head>"
        print "<body>"
    } else {
        emit_title(); emit_style()
    }
    emit_body()
    if (FORMAT == "html") { print "</body>"; print "</html>" }
}
function emit_title() {
    printf "<title>%s</title>\n", esc_h(meta["board_title"] != "" ? meta["board_title"] " — performance" : "Sprint performance")
}
function emit_style(   i) {
    print "<style>"
    printf ":root{"
    for (i = 1; i <= NPAL; i++) printf "--c-%s:%s;", PK[i], PL[i]
    printf "}\n"
    printf "@media (prefers-color-scheme:dark){:root:not([data-theme=\"light\"]){"
    for (i = 1; i <= NPAL; i++) printf "--c-%s:%s;", PK[i], PD[i]
    printf "}}\n"
    printf ":root[data-theme=\"dark\"]{"
    for (i = 1; i <= NPAL; i++) printf "--c-%s:%s;", PK[i], PD[i]
    printf "}\n"
    print "*{box-sizing:border-box}"
    print "body{margin:0;background:var(--c-bg);color:var(--c-ink);"
    print "font:15px/1.55 ui-sans-serif,-apple-system,\"Segoe UI\",Roboto,Helvetica,Arial,sans-serif}"
    print ".wrap{max-width:900px;margin:0 auto;padding:32px 20px 72px}"
    print "h1{font-size:25px;letter-spacing:-.015em;margin:0 0 4px}"
    print "h2{font-size:17px;letter-spacing:-.01em;margin:38px 0 10px;padding-bottom:6px;border-bottom:1px solid var(--c-grid)}"
    print ".sub{color:var(--c-muted);font-size:13.5px;margin:0 0 26px}"
    print "p{margin:10px 0}"
    print ".note{color:var(--c-muted);font-size:13px;margin:8px 0 0}"
    print ".cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin:16px 0}"
    print ".card{background:var(--c-surface);border:1px solid var(--c-grid);border-radius:9px;padding:11px 13px}"
    print ".card .k{color:var(--c-muted);font-size:11.5px;text-transform:uppercase;letter-spacing:.055em}"
    print ".card .v{font-size:19px;font-variant-numeric:tabular-nums;margin-top:3px}"
    print ".card .s{color:var(--c-muted);font-size:12px;margin-top:2px}"
    print ".fig{background:var(--c-surface);border:1px solid var(--c-grid);border-radius:9px;padding:14px 12px 8px;margin:14px 0}"
    print "svg{display:block;width:100%;height:auto}"
    print ".legend{display:flex;flex-wrap:wrap;gap:14px;margin:8px 2px 2px;font-size:12.5px;color:var(--c-muted)}"
    print ".legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px}"
    print ".scroll{overflow-x:auto}"
    print "table{border-collapse:collapse;width:100%;font-size:13.5px;margin:12px 0}"
    print "th,td{text-align:left;padding:6px 9px;border-bottom:1px solid var(--c-grid);white-space:nowrap}"
    print "th{color:var(--c-muted);font-weight:600;font-size:11.5px;text-transform:uppercase;letter-spacing:.05em}"
    print "td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}"
    print "td.t{white-space:normal;min-width:210px}"
    print "a{color:var(--c-accent);text-decoration:none}a:hover{text-decoration:underline}"
    print "code{font:12.5px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:var(--c-grid);padding:1px 5px;border-radius:4px}"
    print ".flag{color:var(--c-warn);font-weight:600}"
    print "details{margin:6px 0 2px}summary{cursor:pointer;color:var(--c-muted);font-size:12.5px}"
    print "ul{margin:8px 0;padding-left:20px}li{margin:5px 0}"
    print "</style>"
}

function card(k, v, s) {
    printf "<div class=\"card\"><div class=\"k\">%s</div><div class=\"v\">%s</div>", esc_h(k), esc_h(v)
    if (s != "") printf "<div class=\"s\">%s</div>", esc_h(s)
    print "</div>"
}
function fig(title, legend) {
    printf "<div class=\"fig\">"
}
function endfig(legend) {
    if (legend != "") printf "<div class=\"legend\">%s</div>", legend
    print "</div>"
}
function lg(pal, label) {
    return sprintf("<span><i style=\"background:var(--c-%s)\"></i>%s</span>", pal, esc_h(label))
}

# --- chart primitives -------------------------------------------------------------------------
function ax_step(   k) { k = int((NDAYS + 7) / 8); if (k < 1) k = 1; return k }

function svg_head(w, h, label) {
    printf "<svg viewBox=\"0 0 %d %d\" width=\"100%%\" height=\"%d\" role=\"img\" aria-label=\"%s\" preserveAspectRatio=\"xMidYMid meet\">\n",
           w, h, h, esc_h(label)
}
function grid_steps(ymax,   c) {
    for (c = 5; c >= 2; c--) if (ymax / c == int(ymax / c)) return c
    return (ymax <= 5) ? ymax : 4
}
function grid_y(x0, x1, y0, y1, ymax, steps,   i, y, v) {
    steps = grid_steps(ymax)
    for (i = 0; i <= steps; i++) {
        y = y1 - (y1 - y0) * i / steps
        v = ymax * i / steps
        printf "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"var(--c-grid)\" stroke-width=\"1\"/>\n", x0, y, x1, y
        printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" font-size=\"10.5\" fill=\"var(--c-muted)\">%s</text>\n",
               x0 - 7, y + 3.5, (v == int(v) ? sprintf("%d", v) : sprintf("%.1f", v))
    }
}
function axis_x(x0, x1, y1, pw,   d, k, x) {
    printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"var(--c-axis)\" stroke-width=\"1\"/>\n", x0, y1, x1, y1
    k = ax_step()
    for (d = 0; d < NDAYS; d += k) {
        x = x0 + (NDAYS > 1 ? pw * d / (NDAYS - 1) : 0)
        printf "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\" font-size=\"10.5\" fill=\"var(--c-muted)\">%s</text>\n",
               x, y1 + 15, substr(cfd(D0 + d), 6)
    }
}
function poly(a, n, x0, y0, y1, pw, ymax, pal, dash,   d, s, x, y) {
    s = ""
    for (d = 0; d < n; d++) {
        x = x0 + (n > 1 ? pw * d / (n - 1) : 0)
        y = y1 - (ymax > 0 ? (y1 - y0) * a[d] / ymax : 0)
        s = s sprintf("%s%.1f,%.1f", (d ? " " : ""), x, y)
    }
    printf "<polyline points=\"%s\" fill=\"none\" stroke=\"var(--c-%s)\" stroke-width=\"2\" stroke-linejoin=\"round\" stroke-linecap=\"round\"%s/>\n",
           s, pal, (dash != "" ? " stroke-dasharray=\"" dash "\"" : "")
}

function chart_throughput(   W, H, ML, MR, MT, MB, x0, x1, y0, y1, pw, ph, ymax, d, bw, x, y, h) {
    W = 760; H = 210; ML = 42; MR = 14; MT = 14; MB = 30
    x0 = ML; x1 = W - MR; y0 = MT; y1 = H - MB; pw = x1 - x0; ph = y1 - y0
    ymax = nice_max(maxm)
    svg_head(W, H, "Tickets delivered per day")
    grid_y(x0, x1, y0, y1, ymax)
    bw = pw / NDAYS - 1.5; if (bw < 1.5) bw = 1.5; if (bw > 26) bw = 26
    for (d = 0; d < NDAYS; d++) {
        if (mday[d] + 0 == 0) continue
        x = x0 + (NDAYS > 1 ? pw * d / (NDAYS - 1) : 0)
        h = ph * mday[d] / ymax
        printf "<rect x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\" rx=\"2\" fill=\"var(--c-done)\"/>\n",
               x - bw / 2, y1 - h, bw, h
    }
    poly(trail, NDAYS, x0, y0, y1, pw, ymax, "accent", "")
    axis_x(x0, x1, y1, pw)
    print "</svg>"
}

function chart_burnup(   W, H, ML, MR, MT, MB, x0, x1, y0, y1, pw, ymax, d, x) {
    W = 760; H = 210; ML = 42; MR = 14; MT = 14; MB = 30
    x0 = ML; x1 = W - MR; y0 = MT; y1 = H - MB; pw = x1 - x0
    ymax = nice_max(csday[NDAYS - 1])
    svg_head(W, H, "Burnup: delivered against sequenced")
    grid_y(x0, x1, y0, y1, ymax)
    poly(csday, NDAYS, x0, y0, y1, pw, ymax, "muted", "5 4")
    poly(cmday, NDAYS, x0, y0, y1, pw, ymax, "done", "")
    for (d = 1; d < NDAYS; d++) if (scope_n[d] > 0) {
        x = x0 + (NDAYS > 1 ? pw * d / (NDAYS - 1) : 0)
        printf "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3.2\" fill=\"var(--c-warn)\"/>\n",
               x, y1 - (ymax > 0 ? (y1 - y0) * csday[d] / ymax : 0)
    }
    axis_x(x0, x1, y1, pw)
    print "</svg>"
}

function chart_wip(   W, H, ML, MR, MT, MB, x0, x1, y0, y1, pw, ymax) {
    W = 760; H = 180; ML = 42; MR = 14; MT = 14; MB = 30
    x0 = ML; x1 = W - MR; y0 = MT; y1 = H - MB; pw = x1 - x0
    ymax = nice_max(maxw)
    svg_head(W, H, "Work in flight per day")
    grid_y(x0, x1, y0, y1, ymax)
    poly(wip, NDAYS, x0, y0, y1, pw, ymax, "accent", "")
    axis_x(x0, x1, y1, pw)
    print "</svg>"
}

function chart_cycle(   W, ML, MR, MT, RH, H, i, j, n, ord, x0, pw, xmax, x, wd, s, y, lbl, tmpn) {
    if (ndl < 1) return
    for (i = 1; i <= ndl; i++) {
        n = DELIV[i]; ORD[i] = n; rowsum[n] = 0
        for (s = 1; s <= NST; s++) if (sv[n, s] >= 0) rowsum[n] += sv[n, s]
    }
    for (i = 1; i < ndl; i++) for (j = 1; j <= ndl - i; j++)
        if (rowsum[ORD[j]] < rowsum[ORD[j+1]]) { tmpn = ORD[j]; ORD[j] = ORD[j+1]; ORD[j+1] = tmpn }
    W = 760; ML = 178; MR = 66; MT = 12; RH = 21
    H = MT + ndl * RH + 30
    x0 = ML; pw = W - ML - MR
    xmax = 0
    for (i = 1; i <= ndl; i++) if (rowsum[ORD[i]] > xmax) xmax = rowsum[ORD[i]]
    if (xmax <= 0) xmax = 1
    svg_head(W, H, "Cycle time per delivered ticket, split by stage")
    for (i = 1; i <= ndl; i++) {
        n = ORD[i]; y = MT + (i - 1) * RH
        lbl = "#" n " " tk_title[n]
        if (length(lbl) > 30) lbl = substr(lbl, 1, 29) "\342\200\246"
        printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" font-size=\"11\" fill=\"var(--c-muted)\">%s</text>\n",
               ML - 9, y + 12, esc_h(lbl)
        x = x0
        for (s = 1; s <= NST; s++) {
            if (sv[n, s] < 0) continue
            wd = pw * sv[n, s] / xmax
            if (wd < 0.6) wd = 0.6
            printf "<rect x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"13\" fill=\"var(--c-%s)\"/>\n",
                   x, y + 2, wd, ST_PAL[s]
            x += wd
        }
        if (totv[n] < 0)
            printf "<text x=\"%.1f\" y=\"%.1f\" font-size=\"10.5\" fill=\"var(--c-muted)\">incomplete</text>\n", x + 5, y + 12
    }
    if (tp90 > 0 && tp90 <= xmax) {
        x = x0 + pw * tp90 / xmax
        printf "<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"var(--c-warn)\" stroke-width=\"1.4\" stroke-dasharray=\"4 3\"/>\n",
               x, MT - 4, x, MT + ndl * RH + 2
        printf "<text x=\"%.1f\" y=\"%.1f\" text-anchor=\"middle\" font-size=\"10.5\" fill=\"var(--c-warn)\">p90 %s d</text>\n",
               x, MT + ndl * RH + 17, dayf(tp90)
    }
    print "</svg>"
}

function chart_aging(   W, ML, MR, MT, RH, H, i, n, x0, pw, xmax, wd, y, lbl, col) {
    if (nage < 1) return
    W = 760; ML = 178; MR = 66; MT = 12; RH = 21
    H = MT + nage * RH + 18
    x0 = ML; pw = W - ML - MR
    xmax = agev[AGE[1]]; if (xmax <= 0) xmax = 1
    if (tp90 > xmax) xmax = tp90
    svg_head(W, H, "Age of open work against the p90 of finished work")
    for (i = 1; i <= nage; i++) {
        n = AGE[i]; y = MT + (i - 1) * RH
        lbl = "#" n " " tk_title[n]
        if (length(lbl) > 30) lbl = substr(lbl, 1, 29) "\342\200\246"
        printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" font-size=\"11\" fill=\"var(--c-muted)\">%s</text>\n",
               ML - 9, y + 12, esc_h(lbl)
        wd = pw * agev[n] / xmax; if (wd < 0.6) wd = 0.6
        col = (tp90 > 0 && agev[n] > tp90) ? "warn" : ((agest[n] == "in flight") ? "review" : "queue")
        printf "<rect x=\"%d\" y=\"%.1f\" width=\"%.1f\" height=\"13\" rx=\"2\" fill=\"var(--c-%s)\"/>\n", x0, y + 2, wd, col
        printf "<text x=\"%.1f\" y=\"%.1f\" font-size=\"10.5\" fill=\"var(--c-muted)\">%s</text>\n",
               x0 + wd + 6, y + 12, dur(agev[n])
    }
    if (tp90 > 0) {
        wd = x0 + pw * tp90 / xmax
        printf "<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"var(--c-warn)\" stroke-width=\"1.4\" stroke-dasharray=\"4 3\"/>\n",
               wd, MT - 4, wd, MT + nage * RH + 2
    }
    print "</svg>"
}

# --- the page body ----------------------------------------------------------------------------
function emit_body(   i, j, s, n, d, w, c, dcount, sh, any, bl, bnum, landed, flag, line) {
    print "<div class=\"wrap\">"
    printf "<h1>%s</h1>\n", esc_h(meta["board_title"] != "" ? meta["board_title"] : "Sprint performance")
    printf "<p class=\"sub\">%s &rarr; %s &middot; %d days &middot; reconstructed from issue, commit and PR timestamps &mdash; the board stores no history.",
           day0, TODAY, NDAYS
    if (meta["board_url"] != "") printf " <a href=\"%s\">Board</a>.", esc_h(meta["board_url"])
    print "</p>"

    print "<div class=\"cards\">"
    card("Delivered", sprintf("%d / %d", ndelivered + 0, nt), sprintf("%.0f%% of sequenced", (nt > 0 ? 100.0 * ndelivered / nt : 0)))
    card("Throughput", sprintf("%.2f / day", rate[2]), sprintf("last %d days, n=%d", rspan[2], rcount[2]))
    card("Median cycle", (tmed >= 0 ? dayf(tmed) " d" : "n/a"), sprintf("p90 %s d, n=%d", dayf(tp90), ntot + 0))
    card("Mean WIP", sprintf("%.1f", meanwip), sprintf("peak %d", maxw + 0))
    card("Open", sprintf("%d", nopen + 0), sprintf("%d aging past p90", npast()))
    card("Day 0", day0, rung " — " src)
    print "</div>"

    # ---- throughput --------------------------------------------------------------------------
    print "<h2>Throughput</h2>"
    print "<div class=\"fig\">"; chart_throughput()
    endfig(lg("done", "delivered that day") lg("accent", "7-day trailing rate"))
    print "<p class=\"note\">Daily counts on a small sprint are mostly zeros and ones, so the bars are"
    print "texture and the trailing line is the signal.</p>"
    print "<div class=\"scroll\"><table><thead><tr><th>Week</th><th>Days</th><th class=\"n\">Delivered</th><th class=\"n\">Cumulative</th><th class=\"n\">Rate/day</th></tr></thead><tbody>"
    for (w = 0; w < nweeks; w++) {
        c = 0; dcount = 0
        for (d = w * 7; d < (w + 1) * 7 && d < NDAYS; d++) { c += mday[d]; dcount++ }
        printf "<tr><td>W%d%s</td><td>%s &rarr; %s</td><td class=\"n\">%d</td><td class=\"n\">%d</td><td class=\"n\">%.2f</td></tr>\n",
               w + 1, (dcount < 7 ? " *" : ""), cfd(D0 + w * 7), cfd(D0 + w * 7 + dcount - 1),
               c, cmday[clampd((w + 1) * 7 - 1)], (dcount > 0 ? c / dcount : 0)
    }
    print "</tbody></table></div>"
    print "<p class=\"note\">* partial week. Weeks are sprint-relative, not calendar weeks.</p>"

    if (nlanes > 0) {
        print "<div class=\"scroll\"><table><thead><tr><th>Lane (component)</th><th class=\"n\">Delivered</th>"
        for (w = 0; w < nweeks; w++) printf "<th class=\"n\">W%d</th>", w + 1
        print "</tr></thead><tbody>"
        for (i = 1; i <= nlanes; i++) {
            printf "<tr><td>%s</td><td class=\"n\">%d</td>", esc_h(LANES[i]), lane_tot[LANES[i]] + 0
            for (w = 0; w < nweeks; w++) printf "<td class=\"n\">%d</td>", lane_wk[LANES[i], w] + 0
            print "</tr>"
        }
        print "</tbody></table></div>"
        print "<p class=\"note\">A lane is a <strong>component</strong>, not a person. A slow lane means that"
        print "component&rsquo;s tickets sit in review or land late. No author, assignee or merged-by was"
        print "collected anywhere in this pipeline, so there is nothing here to read as individual output.</p>"
    }

    # ---- burnup ------------------------------------------------------------------------------
    print "<h2>Burnup and scope</h2>"
    print "<div class=\"fig\">"; chart_burnup()
    endfig(lg("done", "delivered") lg("muted", "sequenced (scope)") lg("warn", "scope added"))
    print "<p class=\"note\">A burnup, not a burndown: scope is its own line, so growth shows as a rising"
    print "ceiling instead of being laundered into the percentage and read as the team slowing down.</p>"
    any = 0
    for (d = 1; d < NDAYS; d++) if (scope_n[d] > 0) {
        if (!any) { print "<div class=\"scroll\"><table><thead><tr><th>Date</th><th class=\"n\">Added</th><th>Tickets</th></tr></thead><tbody>"; any = 1 }
        printf "<tr><td>%s</td><td class=\"n\">+%d</td><td>%s</td></tr>\n", cfd(D0 + d), scope_n[d], esc_h(scope_who[d])
    }
    if (any) print "</tbody></table></div>"
    else print "<p class=\"note\">Scope did not move after day 0 &mdash; checked, none.</p>"

    # ---- flow --------------------------------------------------------------------------------
    print "<h2>Work in flight</h2>"
    print "<div class=\"fig\">"; chart_wip(); endfig(lg("accent", "tickets between first commit and merge"))
    if (littles >= 0 && tmed >= 0) {
        printf "<p>Mean WIP %.1f &divide; whole-window throughput %.2f/day implies a cycle time of <strong>%.1f days</strong>; the measured median is <strong>%s days</strong>.",
               meanwip, rate[3], littles, dayf(tmed)
        if (tmed > 0 && (littles / (tmed / 86400.0) > 2 || (tmed / 86400.0) / littles > 2))
            print " They disagree by more than 2&times;, which usually means finished work is not being merged."
        print "</p>"
    } else {
        print "<p class=\"note\">No throughput over the window, so there is no flow ratio to compute.</p>"
    }

    # ---- stages ------------------------------------------------------------------------------
    print "<h2>Where the time goes</h2>"
    sh = 0
    for (s = 1; s <= NST; s++) if (smed[s] >= 0) sh += smed[s]
    print "<div class=\"scroll\"><table><thead><tr><th>Stage</th><th class=\"n\">n</th><th class=\"n\">Median</th><th class=\"n\">p90</th><th class=\"n\">Longest</th><th>Share</th></tr></thead><tbody>"
    for (s = 1; s <= NST; s++) {
        if (scount[s] < 1) { printf "<tr><td>%s</td><td class=\"n\">0</td><td colspan=\"4\" class=\"flag\">undetermined</td></tr>\n", ST_LAB[s]; continue }
        printf "<tr><td>%s</td><td class=\"n\">%d</td><td class=\"n\">%s d</td><td class=\"n\">%s</td><td class=\"n\">%s d</td><td>%s</td></tr>\n",
               ST_LAB[s], scount[s], dayf(smed[s]),
               (scount[s] < 5 ? "n&lt;5" : dayf(sp90[s]) " d"), dayf(SORTED[s, scount[s]]),
               sharebar(smed[s], sh, ST_PAL[s])
    }
    if (ntot > 0)
        printf "<tr><td><strong>Total</strong></td><td class=\"n\">%d</td><td class=\"n\">%s d</td><td class=\"n\">%s</td><td class=\"n\">%s d</td><td></td></tr>\n",
               ntot, dayf(tmed), (ntot < 5 ? "n&lt;5" : dayf(tp90) " d"), dayf(TOT[ntot])
    print "</tbody></table></div>"
    small = 0
    for (s = 1; s <= NST; s++) if (scount[s] > 0 && scount[s] < 5) small = 1
    if (small) {
        print "<p class=\"note\">With n&lt;5 there is no ninetieth percentile, only a sorted list:"
        for (s = 1; s <= NST; s++) {
            if (scount[s] < 1 || scount[s] >= 5) continue
            line = ""
            for (j = 1; j <= scount[s]; j++) line = line (j > 1 ? ", " : "") dayf(SORTED[s, j])
            printf " <strong>%s</strong> (n=%d) %s.", ST_LAB[s], scount[s], line
        }
        print "</p>"
    }
    if (bottleneck != "" && !btie)
        printf "<p>The largest median share is <strong>%s</strong> &mdash; that is where the sprint is slow.</p>\n", esc_h(bottleneck)
    else if (bottleneck != "")
        print "<p>No single stage dominates &mdash; the medians are within 15% of each other, which is a tie, not a bottleneck.</p>"
    print "<p class=\"note\">Medians and p90, never a mean: one long ticket moves a mean of ten and moves the"
    print "median by nothing. Each stage carries its own n &mdash; a ticket with no commit has no build"
    print "stage, and pooling them would invent a denominator.</p>"
    if (ndl > 0) {
        print "<div class=\"fig\">"; chart_cycle()
        endfig(lg("queue", "queue: filed \342\206\222 first commit") lg("build", "build: first commit \342\206\222 PR") lg("review", "review: PR \342\206\222 merged"))
    }

    # ---- aging -------------------------------------------------------------------------------
    print "<h2>Aging work in progress</h2>"
    if (nage == 0) print "<p>No open tickets &mdash; checked, none.</p>"
    else {
        print "<div class=\"fig\">"; chart_aging()
        endfig(lg("review", "in flight") lg("queue", "not started") lg("warn", "past the p90 of finished work"))
        print "<div class=\"scroll\"><table><thead><tr><th>Ticket</th><th>State</th><th class=\"n\">Age</th><th>vs p90</th><th>Lane</th></tr></thead><tbody>"
        for (i = 1; i <= nage; i++) {
            n = AGE[i]
            flag = (tp90 > 0 && agev[n] > tp90) ? "<span class=\"flag\">past p90</span>" : (tp90 > 0 ? "within" : "no p90 yet")
            printf "<tr><td class=\"t\"><a href=\"%s\">#%s</a> %s</td><td>%s</td><td class=\"n\">%s</td><td>%s</td><td>%s</td></tr>\n",
                   esc_h(tk_url[n]), n, esc_h(tk_title[n]), agest[n], dur(agev[n]), flag, esc_h(tk_lane[n])
        }
        print "</tbody></table></div>"
        print "<p class=\"note\">Cycle time of finished work is a lagging indicator by construction &mdash; it can"
        print "only describe tickets that already landed. The item past p90 is the one going wrong now.</p>"
    }

    # ---- blocked -----------------------------------------------------------------------------
    print "<h2>Blocked</h2>"
    any = 0
    for (i = 1; i <= nt; i++) {
        n = NUMS[i]
        if (tk_status[n] != "Blocked" && tk_block[n] == "") continue
        if (!any) { print "<div class=\"scroll\"><table><thead><tr><th>Ticket</th><th>Blocked by</th><th>Blocker landed?</th><th>Blocked since</th></tr></thead><tbody>"; any = 1 }
        bl = tk_block[n]; bnum = bl; gsub(/[^0-9]/, "", bnum)
        landed = (bnum != "" && cls[bnum] == "delivered") ? "<span class=\"flag\">yes &mdash; stale</span>" : "no"
        printf "<tr><td class=\"t\"><a href=\"%s\">#%s</a> %s</td><td>%s</td><td>%s</td><td>not recorded</td></tr>\n",
               esc_h(tk_url[n]), n, esc_h(tk_title[n]), (bl != "" ? esc_h(bl) : "&mdash;"), landed
    }
    if (any) {
        print "</tbody></table></div>"
        print "<p class=\"note\"><code>Blocked by</code> carries no timestamp, so blocked-since is not recorded"
        print "anywhere. A blocker that already landed is the most common piece of stale board state there is.</p>"
    } else print "<p>Nothing is marked blocked &mdash; checked, none.</p>"

    # ---- integrity ---------------------------------------------------------------------------
    print "<h2>Integrity</h2>"
    print "<div class=\"scroll\"><table><thead><tr><th>Check</th><th class=\"n\">Count</th><th>Tickets</th></tr></thead><tbody>"
    hcheck("Reopened", "reopen");  hcheck("Reverted", "revert")
    hcheck("Done by opinion (no merged closing PR)", "byopinion")
    hcheck("Merged with CI red", "cired")
    hcheck("Merged with no CI result at all", "ciabsent")
    hcheck("Closed as not planned (excluded from throughput)", "notplanned")
    hcheck("No lane &mdash; nobody will pick these up", "nolane")
    hcheck("No order", "noorder")
    print "</tbody></table></div>"
    print "<p class=\"note\">Absent, pending, skipped, failed and passed are five CI states and they are kept"
    print "apart. A repository on legacy commit statuses reports <code>state</code> rather than"
    print "<code>conclusion</code>, and a reader that knows only the latter calls a healthy project unchecked.</p>"

    # ---- forecast ----------------------------------------------------------------------------
    print "<h2>Forecast</h2>"
    if (!anyrate) {
        printf "<p><strong>No basis for a forecast.</strong> Nothing was delivered in the trailing window, so there is no rate to divide %d remaining tickets by. That is the finding, not a distant date.</p>\n", remaining
    } else {
        printf "<p>%d tickets remain (%d open, %d closed without a merged PR).</p>\n", remaining, nopen + 0, nbyopinion + 0
        print "<div class=\"scroll\"><table><thead><tr><th>Trailing window</th><th class=\"n\">Delivered</th><th class=\"n\">Rate/day</th><th class=\"n\">Days left</th><th>Finish</th></tr></thead><tbody>"
        for (w = 1; w <= 3; w++) {
            if (rate[w] > 0)
                printf "<tr><td>last %d days</td><td class=\"n\">%d</td><td class=\"n\">%.2f</td><td class=\"n\">%d</td><td>%s</td></tr>\n",
                       rspan[w], rcount[w], rate[w], fdays[w], fdate[w]
            else
                printf "<tr><td>last %d days</td><td class=\"n\">%d</td><td class=\"n\">0.00</td><td class=\"n\">&mdash;</td><td>no basis</td></tr>\n",
                       rspan[w], rcount[w]
        }
        print "</tbody></table></div>"
        print "<p class=\"note\">Three rates, three dates, and the spread between them is the finding &mdash; not"
        print "any one of them. A single date would be a forecast the data cannot support.</p>"
    }

    # ---- unknowns ----------------------------------------------------------------------------
    print "<h2>What could not be determined</h2>"
    print "<ul>"
    for (i = 1; i <= nunk; i++) printf "<li>%s</li>\n", esc_h(UNK[i])
    for (i = 1; i <= nneg; i++) { split(NEG[i], f, "|")
        printf "<li>#%s &mdash; %s is negative: the first commit predates the issue, so the ticket was filed after the work began. Excluded from that sample rather than counted as zero.</li>\n", f[1], esc_h(f[2]) }
    for (i = 1; i <= nearly; i++)
        printf "<li>#%s &mdash; its first commit predates day 0. A rebased or long-lived branch keeps its original author date, so this may be older history rather than sprint work.</li>\n", EARLY[i]
    if (nmissing > 0)
        printf "<li>%d stage measurements are missing a bound (a ticket with no commit has no build stage). Excluded from that stage&rsquo;s n, never imputed.</li>\n", nmissing
    print "<li>Every <code>Status</code> transition. The board stores the current value and no history, so &ldquo;how long was this In Progress&rdquo; has no answer here &mdash; only the commit and PR proxies above.</li>"
    print "<li>Blocked duration. <code>Blocked by</code> has no timestamp.</li>"
    print "<li>Uncommitted work in a worktree. That is <code>/sprint-status</code> &sect;<em>Quiet lanes</em>.</li>"
    print "</ul>"
    printf "<p class=\"note\">Generated %s from %d tickets and %d pull requests. Mode: %s.</p>\n",
           esc_h(NOWTS), nt, npr + 0, esc_h(meta["mode"] != "" ? meta["mode"] : "unknown")
    print "</div>"
}

function npast(   i, n, c) {
    c = 0
    for (i = 1; i <= nage; i++) { n = AGE[i]; if (tp90 > 0 && agev[n] > tp90) c++ }
    return c
}
function sharebar(v, tot, pal,   pc) {
    pc = (tot > 0) ? 100.0 * v / tot : 0
    return sprintf("<span style=\"display:inline-block;width:%.0f%%;max-width:100%%;height:9px;border-radius:2px;background:var(--c-%s)\"></span> <span style=\"color:var(--c-muted);font-size:11.5px\">%.0f%%</span>", pc, pal, pc)
}
function hcheck(label, kind,   i, n, c, lst, hit) {
    c = 0; lst = ""
    for (i = 1; i <= nt; i++) {
        n = NUMS[i]; hit = 0
        if      (kind == "reopen")     hit = (ev_reopen[n] != "")
        else if (kind == "revert")     hit = (ev_revert[n] != "")
        else if (kind == "byopinion")  hit = (cls[n] == "byopinion")
        else if (kind == "cired")      hit = (cls[n] == "delivered" && tk_ci[n] == "FAILURE")
        else if (kind == "ciabsent")   hit = (cls[n] == "delivered" && tk_ci[n] == "ABSENT")
        else if (kind == "notplanned") hit = (cls[n] == "notplanned")
        else if (kind == "nolane")     hit = (tk_lane[n] == "")
        else if (kind == "noorder")    hit = (tk_order[n] == "")
        if (hit) { c++; lst = lst (lst == "" ? "" : " ") "<a href=\"" esc_h(tk_url[n]) "\">#" n "</a>" }
    }
    printf "<tr><td>%s</td><td class=\"n\">%d</td><td class=\"t\">%s</td></tr>\n", label, c, (c > 0 ? lst : "checked, none")
}
AWKEOF
}

if [ -n "$input" ]; then
  [ -r "$input" ] || die "cannot read input: $input"
  set -- "$input"
else
  set --
fi

emit() {
  awk -F '\t' \
      -v FORMAT="$format" -v NOWTS="$now" -v SINCE="$since" \
      -v ASCII="$ascii" -v FULL="$full" \
      -v PALETTE="$palette" -v STAGES="$stages" \
      -- "$(awk_program)" "$@"
}

if [ -n "$out" ]; then
  emit "$@" > "$out"
else
  emit "$@"
fi
