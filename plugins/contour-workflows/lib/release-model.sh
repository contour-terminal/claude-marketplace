#! /usr/bin/env bash
#
# Detect a repository's release model and print it as JSON on stdout.
#
# The contour-terminal projects do not share one release procedure — each grew its own.
# Rather than special-casing repositories by name (which would rot the moment a fifth repo
# appears), this probes for the *mechanism* each project actually uses and reports it.
#
# Usage: release-model.sh [repo-path]        # defaults to the enclosing git worktree
#
# Every field is always present in the output, so consumers can use `jq -r .field`
# unconditionally. Unknown/absent values are reported as "none" or [] rather than omitted.
#
# An optional .github/release.json is merged over the detected values, for the cases where
# detection is genuinely ambiguous or a project wants to pin the answer explicitly.

set -uo pipefail

readonly SELF="${0##*/}"

die() {
    echo "${SELF}: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

# ---------------------------------------------------------------------------- repo root

repo_path="${1:-.}"
[[ -d "$repo_path" ]] || die "not a directory: $repo_path"

root="$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git worktree: $repo_path"

cd "$root" || die "cannot enter $root"

# True if the path is tracked by git. Matters for version.txt: contour *generates* one during
# CI and gitignores it, while tuidu commits one as its source of truth. Only the committed
# kind is a version source.
tracked() {
    git ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------- xml helpers

# Strip XML comments so a commented-out <release> template is never mistaken for the real
# thing. contour keeps exactly such a template above its unreleased block.
strip_xml_comments() {
    awk '
    {
        line = $0; out = ""
        while (length(line) > 0) {
            if (incomment) {
                p = index(line, "-->")
                if (p == 0) { line = "" } else { line = substr(line, p + 3); incomment = 0 }
            } else {
                p = index(line, "<!--")
                if (p == 0) { out = out line; line = "" }
                else { out = out substr(line, 1, p - 1); line = substr(line, p + 4); incomment = 1 }
            }
        }
        print out
    }' "$1"
}

# Echoes the first real <release ...> open tag of an AppStream file.
first_release_tag() {
    strip_xml_comments "$1" | tr '\n' ' ' | grep -oE '<release[[:space:]][^>]*>' | head -n1
}

attr_of() { # attr_of <tag-text> <attribute-name>
    printf '%s' "$1" | grep -oE "$2=\"[^\"]*\"" | head -n1 | cut -d'"' -f2
}

# ---------------------------------------------------------------- version source detection

version_source="unknown"
version_file="none"
current_version=""
unreleased="false"      # metainfo only: top <release> still carries type="development"
release_date="none"

metainfo_file=""
for candidate in metainfo.xml ./*.metainfo.xml ./*.appdata.xml; do
    [[ -f "$candidate" ]] || continue
    grep -q '<releases>' "$candidate" 2>/dev/null || continue
    metainfo_file="${candidate#./}"
    break
done

if [[ -n "$metainfo_file" ]]; then
    version_source="metainfo"
    version_file="$metainfo_file"
    tag_text="$(first_release_tag "$metainfo_file")"
    current_version="$(attr_of "$tag_text" version)"
    release_date="$(attr_of "$tag_text" date)"
    [[ -z "$release_date" ]] && release_date="none"
    [[ "$(attr_of "$tag_text" type)" == "development" ]] && unreleased="true"

elif tracked version.txt && [[ -f version.txt ]]; then
    version_source="pinned"
    version_file="version.txt"
    current_version="$(tr -d '[:space:]' <version.txt)"

elif [[ -f cmake/Version.cmake ]]; then
    # The version is derived from `git describe` at configure time; nothing to edit in-tree.
    version_source="git-tag"
    version_file="none"
    current_version="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')"

elif [[ -f CMakeLists.txt ]]; then
    literal="$(grep -oE 'project\([^)]*VERSION[[:space:]]+"?[0-9]+\.[0-9]+\.[0-9]+"?' CMakeLists.txt | head -n1)"
    if [[ -n "$literal" ]]; then
        version_source="cmake-literal"
        version_file="CMakeLists.txt"
        current_version="$(printf '%s' "$literal" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    fi
fi

[[ -z "$current_version" ]] && current_version="unknown"

# -------------------------------------------------------------------- changelog detection

changelog="none"
for candidate in "$metainfo_file" CHANGELOG.md CHANGES.md Changelog.md docs/releases.md NEWS.md NEWS; do
    [[ -n "$candidate" && -f "$candidate" ]] || continue
    changelog="$candidate"
    break
done

# ---------------------------------------------------------------------- trigger detection
#
# release-branch-pr : a job gated on `github.head_ref == 'release'` (contour)
# tag-push          : `on: push: tags:` (endo, and libunicode/tuidu once converted)
# publish-first     : `on: release: types: [published]` — CI builds only *after* publishing,
#                     so artifacts cannot be verified beforehand. Callers treat this as fatal.

trigger="none"
trigger_workflow="none"

wf_dir=".github/workflows"
if [[ -d "$wf_dir" ]]; then
    for wf in "$wf_dir"/*.yml "$wf_dir"/*.yaml; do
        [[ -f "$wf" ]] || continue
        if grep -qE "head_ref[[:space:]]*==[[:space:]]*'release'" "$wf"; then
            trigger="release-branch-pr"; trigger_workflow="$wf"; break
        fi
    done
    if [[ "$trigger" == "none" ]]; then
        for wf in "$wf_dir"/*.yml "$wf_dir"/*.yaml; do
            [[ -f "$wf" ]] || continue
            # `tags:` appearing anywhere in the top-level `on:` block is a tag trigger.
            if awk '/^on:/{inon=1; next} /^[^[:space:]#]/{inon=0} inon' "$wf" | grep -qE '^\s+tags:'; then
                trigger="tag-push"; trigger_workflow="$wf"; break
            fi
        done
    fi
    if [[ "$trigger" == "none" ]]; then
        for wf in "$wf_dir"/*.yml "$wf_dir"/*.yaml; do
            [[ -f "$wf" ]] || continue
            if awk '/^on:/{inon=1; next} /^[^[:space:]#]/{inon=0} inon' "$wf" | grep -qE 'published'; then
                trigger="publish-first"; trigger_workflow="$wf"; break
            fi
        done
    fi
fi

# --------------------------------------------------------------------- artifact detection
#
# Only softprops/action-gh-release declares its asset globs statically (a `files:` block).
# Workflows that shell out to `gh release upload` name their files at runtime, so nothing
# reliable can be read out of the YAML. In that case emit [] and let the caller fall back to
# comparing against the previous release's asset set — which is self-maintaining and does not
# need to be updated when the artifact list changes.

artifacts_json="[]"
if [[ "$trigger_workflow" != "none" ]] && grep -q 'softprops/action-gh-release' "$trigger_workflow"; then
    artifacts_json="$(
        awk '
            /files:[[:space:]]*\|/ { collecting = 1; next }
            collecting {
                if ($0 ~ /^[[:space:]]*#/) next            # commented-out asset
                if ($0 !~ /^[[:space:]]*[*a-zA-Z0-9._-]+/) { collecting = 0; next }
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                if (length($0)) print
            }
        ' "$trigger_workflow" | jq -R . | jq -s .
    )"
    [[ -z "$artifacts_json" ]] && artifacts_json="[]"
fi

# ------------------------------------------------------- secondary manifests to keep in sync

sync_json="$(
    {
        if [[ -f vcpkg.json ]] && jq -e 'has("version") or has("version-string") or has("version-semver")' vcpkg.json >/dev/null 2>&1; then
            echo vcpkg.json
        fi
        # Any tracked package.json carrying a version (e.g. endo's VS Code extension).
        git ls-files '*package.json' 2>/dev/null | while read -r pkg; do
            [[ -f "$pkg" ]] || continue
            jq -e 'has("version")' "$pkg" >/dev/null 2>&1 && echo "$pkg"
        done
    } | jq -R . | jq -s 'map(select(length > 0))'
)"
[[ -z "$sync_json" ]] && sync_json="[]"

# ------------------------------------------------------------------------------ tag prefix

tag_prefix="v"
last_tag="$(git tag --list --sort=-v:refname | head -n1)"
[[ -n "$last_tag" && "$last_tag" != v* ]] && tag_prefix=""

# ---------------------------------------------------------------------------------- output

detected="$(jq -n \
    --arg root            "$root" \
    --arg versionSource   "$version_source" \
    --arg versionFile     "$version_file" \
    --arg currentVersion  "$current_version" \
    --arg changelog       "$changelog" \
    --arg trigger         "$trigger" \
    --arg triggerWorkflow "$trigger_workflow" \
    --arg releaseDate     "$release_date" \
    --arg tagPrefix       "$tag_prefix" \
    --arg lastTag         "${last_tag:-none}" \
    --argjson unreleased  "$unreleased" \
    --argjson artifacts   "$artifacts_json" \
    --argjson syncVersion "$sync_json" \
    '{
        root: $root,
        versionSource: $versionSource,
        versionFile: $versionFile,
        currentVersion: $currentVersion,
        unreleased: $unreleased,
        releaseDate: $releaseDate,
        changelog: $changelog,
        trigger: $trigger,
        triggerWorkflow: $triggerWorkflow,
        artifacts: $artifacts,
        syncVersion: $syncVersion,
        tagPrefix: $tagPrefix,
        lastTag: $lastTag,
        override: false
    }')"

if [[ -f .github/release.json ]]; then
    if jq -e . .github/release.json >/dev/null 2>&1; then
        printf '%s' "$detected" | jq --slurpfile o .github/release.json '. * $o[0] | .override = true'
    else
        die ".github/release.json is present but is not valid JSON"
    fi
else
    printf '%s\n' "$detected"
fi
