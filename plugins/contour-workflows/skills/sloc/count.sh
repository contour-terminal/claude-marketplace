#!/usr/bin/env bash
#
# sloc/count.sh — Source-lines-of-code counter.
#
# Counts physical lines of tracked source code, broken down per module and
# split into project code vs. test code. Zero external dependencies beyond
# git + awk + wc (falls back to `find` outside a git repo).
#
# Usage:
#   count.sh [PATH ...]        # optional path prefixes to scope the count
#
# Everything that classifies a file lives in one of the three data tables
# below. Extending behaviour = adding a row, never editing logic.

set -euo pipefail

# ── Data table 1: what counts as source code (by extension) ──────────────────
# One source of truth: drives both the git/find filter and the language table.
CODE_EXTS="
  c cc cpp cxx c++ h hh hpp hxx h++ inl inc ipp tpp
  m mm
  cu cuh
  cs java kt kts scala groovy
  go rs swift d zig nim
  py pyi rb pl pm lua tcl r jl
  js jsx mjs cjs ts tsx vue svelte
  qml
  vert frag geom comp tese tesc glsl hlsl wgsl metal
  sh bash zsh fish
  sql
  php
"

# ── Data table 2: how to recognise test code (awk regexes over the path) ─────
# Applied in count_awk() below; kept adjacent for discoverability.
#   * any component named test(s)/spec(s)/__tests__/testing
#   * basename ending _test / _spec / Test / Spec before the extension
#   * basename starting test_/spec_  or  *.test.* / *.spec.*

# ── Data table 3: directories to prune in the non-git fallback ───────────────
PRUNE_DIRS=".git node_modules build out _build cmake-build-debug cmake-build-release
           dist vendor third_party 3rdparty external .venv venv target .cache"

# ── Optional scope prefixes (from CLI args) ──────────────────────────────────
SCOPES=("$@")

# Move to the repo root when inside a git work tree, so paths are stable.
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  ROOT="$(git rev-parse --show-toplevel)"
  cd "$ROOT"
  IN_GIT=1
else
  ROOT="$(pwd)"
  IN_GIT=0
fi

# Build the extension list into a shell array. CODE_EXTS spans several lines,
# so word-split it (read -a would stop at the first newline). Globbing is
# disabled around the split because the array is unquoted; the tokens contain
# no glob metacharacters, but set -f makes that guarantee explicit.
set -f
# shellcheck disable=SC2206
_exts=( $CODE_EXTS )
set +f

# ── Produce a NUL-delimited list of candidate source files ───────────────────
list_files() {
  if [[ "$IN_GIT" -eq 1 ]]; then
    local specs=()
    local e
    for e in "${_exts[@]}"; do specs+=("*.$e"); done
    # Tracked files only → respects .gitignore, excludes generated/vendored.
    git ls-files -z -- "${specs[@]}"
  else
    local prune_expr=() first=1 d
    for d in $PRUNE_DIRS; do
      if [[ $first -eq 1 ]]; then prune_expr+=(-name "$d"); first=0
      else prune_expr+=(-o -name "$d"); fi
    done
    local name_expr=() nfirst=1 e
    for e in "${_exts[@]}"; do
      if [[ $nfirst -eq 1 ]]; then name_expr+=(-name "*.$e"); nfirst=0
      else name_expr+=(-o -name "*.$e"); fi
    done
    find . \( -type d \( "${prune_expr[@]}" \) -prune \) -o \
         \( -type f \( "${name_expr[@]}" \) -print0 \) \
      | sed -z 's|^\./||'
  fi
}

# ── Aggregate wc output into the module / test / language tables ─────────────
count_awk() {
  # $1.. = scope prefixes, passed to awk as a NUL-free, tab-joined string.
  local scope_joined=""
  local s
  for s in "${SCOPES[@]:-}"; do
    [[ -z "$s" ]] && continue
    s="${s%/}"
    scope_joined+="${s}"$'\t'
  done

  awk -v scopes="$scope_joined" '
    function basename(p,   b){ b=p; sub(/.*\//,"",b); return b }
    function extof(p,   b){ b=basename(p); if (b !~ /\./) return "(none)";
                            sub(/.*\./,"",b); return tolower(b) }
    function in_scope(p,   i){
      if (nscope==0) return 1
      for (i=1;i<=nscope;i++){
        if (index(p, scopearr[i]"/")==1 || p==scopearr[i]) return 1
      }
      return 0
    }
    function is_test(p,   b){
      b=basename(p)
      if (p ~ /(^|\/)(tests?|specs?|__tests__|testing)\//) return 1
      if (b ~ /(_test|_tests|_spec|_specs)\.[^.]+$/)      return 1
      if (b ~ /(Test|Tests|Spec|Specs)\.[^.]+$/)          return 1
      if (b ~ /^(test|spec)[_-]/)                          return 1
      if (b ~ /\.(test|spec)\.[^.]+$/)                     return 1
      return 0
    }
    function module_of(p,   a,n){
      n=split(p,a,"/")
      if (n==1) return "(root)"
      if (a[1] ~ /^(src|lib|libs|source|sources)$/){ return (n>=3)?a[2]:a[1] }
      return a[1]
    }
    BEGIN{ nscope=split(scopes, scopearr, "\t");
           # split leaves a trailing empty field from the last tab
           while (nscope>0 && scopearr[nscope]=="") nscope-- }
    {
      n=$1
      $1=""; sub(/^[ \t]+/,""); p=$0
      if (p=="total") next
      if (n !~ /^[0-9]+$/) next
      if (!in_scope(p)) next

      m=module_of(p); e=extof(p); t=is_test(p)
      modseen[m]=1; files[m]++; nf++
      if (t){ tcode[m]+=n; ttot+=n; langT[e]+=n }
      else  { code[m]+=n;  ptot+=n; langP[e]+=n }
      langseen[e]=1; langAll[e]+=n
    }
    END{
      if (nf==0){ print "No source files matched."; exit 0 }

      # ---- module table, sorted by total desc (portable selection sort) ----
      nm=0
      for (m in modseen){ mods[++nm]=m; tot[m]=code[m]+tcode[m] }
      for (i=1;i<=nm;i++){
        best=i
        for (j=i+1;j<=nm;j++)
          if (tot[mods[j]]>tot[mods[best]] ||
             (tot[mods[j]]==tot[mods[best]] && mods[j]<mods[best])) best=j
        t2=mods[i]; mods[i]=mods[best]; mods[best]=t2
      }
      w=length("Module")
      for (i=1;i<=nm;i++) if (length(mods[i])>w) w=length(mods[i])

      printf "%-*s  %10s  %10s  %10s  %6s  %5s\n", w,"Module","Code","Test","Total","Files","Test%"
      sepw=w+2+10+2+10+2+10+2+6+2+5
      s=""; for(i=0;i<sepw;i++) s=s"-"; print s
      for (i=1;i<=nm;i++){
        m=mods[i]; tt=tot[m]
        pct=(tt>0)? (100.0*tcode[m]/tt) : 0
        printf "%-*s  %10d  %10d  %10d  %6d  %4.1f%%\n", w,m,code[m]+0,tcode[m]+0,tt,files[m]+0,pct
      }
      print s
      gtot=ptot+ttot
      gpct=(gtot>0)? (100.0*ttot/gtot):0
      printf "%-*s  %10d  %10d  %10d  %6d  %4.1f%%\n", w,"TOTAL",ptot+0,ttot+0,gtot,nf+0,gpct

      # ---- language table, sorted by total lines desc ----
      nl=0
      for (e in langseen){ langs[++nl]=e }
      for (i=1;i<=nl;i++){
        best=i
        for (j=i+1;j<=nl;j++)
          if (langAll[langs[j]]>langAll[langs[best]] ||
             (langAll[langs[j]]==langAll[langs[best]] && langs[j]<langs[best])) best=j
        t2=langs[i]; langs[i]=langs[best]; langs[best]=t2
      }
      lw=length("Language")
      for (i=1;i<=nl;i++) if (length(langs[i])>lw) lw=length(langs[i])
      print ""
      printf "%-*s  %10s  %10s  %10s\n", lw,"Language","Code","Test","Total"
      lsepw=lw+2+10+2+10+2+10
      s=""; for(i=0;i<lsepw;i++) s=s"-"; print s
      for (i=1;i<=nl;i++){
        e=langs[i]
        printf "%-*s  %10d  %10d  %10d\n", lw,e,langP[e]+0,langT[e]+0,langAll[e]+0
      }
    }
  '
}

# ── Report header ────────────────────────────────────────────────────────────
project="$(basename "$ROOT")"
ref=""
if [[ "$IN_GIT" -eq 1 ]]; then
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  short="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
  ref=" @ ${branch} (${short})"
fi
echo "SLOC — ${project}${ref}"
if [[ "${#SCOPES[@]}" -gt 0 ]]; then echo "Scope: ${SCOPES[*]}"; fi
echo

# ── Pipe: file list → per-file line counts → aggregation ─────────────────────
list_files | xargs -0 -r wc -l 2>/dev/null | count_awk
