#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Reproduce an Unsloth mix build as a real, tagged commit in this fork.
#
# Unsloth's CI (unsloth-prebuilt.yml, "resolve" job) merges the PRs pinned in
# scripts/unsloth/pr-set.json onto an upstream bNNNN tag and ships the result
# only as prebuilt binaries: the merged source is never pushed. This script runs
# the same merge locally and tags it, so the tree can be cloned at a pinned SHA
# and built from source (Metal on macOS) instead of downloading a prebuilt.
#
# The tag name matches Unsloth's release for the same inputs:
#   <base>-mix-<first 7 hex of sha256 over "repo#number:sha" lines, in order>
# so b11160-mix-a6922cc here is the same source Unsloth built b11160-mix-a6922cc
# from (merge commits differ, trees match).
#
# Usage:
#   scripts/unsloth/make_mix_tag.sh [bNNNN]    # default: newest upstream tag
#
# Needs remotes: `upstream` = ggml-org/llama.cpp, `unsloth` = unslothai/llama.cpp.
# Run from a clean work tree on a branch that carries scripts/unsloth/ (e.g.
# unsloth-tools, kept in sync with unsloth/master). The script returns to that
# branch when done. Push the tag yourself: git push origin <tag>

set -euo pipefail

die() { echo "make_mix_tag: $*" >&2; exit 1; }

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
[ -f scripts/unsloth/pr-set.json ] || die "scripts/unsloth/pr-set.json not found; run from the tools branch"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "work tree has uncommitted changes"
git remote get-url upstream >/dev/null 2>&1 || die "missing remote 'upstream' (ggml-org/llama.cpp)"
git remote get-url unsloth >/dev/null 2>&1 || die "missing remote 'unsloth' (unslothai/llama.cpp)"

ORIG_REF="$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)"
TOOLS="$(mktemp -d)"
trap 'git merge --abort >/dev/null 2>&1 || true; git checkout -q "$ORIG_REF" 2>/dev/null || true; rm -rf "$TOOLS"' EXIT
# The base checkout removes scripts/unsloth/, so work from a copy.
cp -r scripts/unsloth "$TOOLS/"

BASE="${1:-latest}"
if [ "$BASE" = "latest" ]; then
    BASE="$(git ls-remote --tags --refs upstream 'refs/tags/b*' | sed 's|.*refs/tags/||' \
            | grep -E '^b[0-9]+$' | sort -V | tail -1)"
    [ -n "$BASE" ] || die "could not resolve the newest upstream tag"
fi
[[ "$BASE" =~ ^b[0-9]+$ ]] || die "base must look like bNNNN, got '$BASE'"

# Pins as "repo number sha required", in listed order. Same validation as the
# CI resolve step: a url string, or {url, required}.
PINS="$(python3 - "$TOOLS/unsloth/pr-set.json" <<'PY'
import json, re, sys
rx = re.compile(r"^https://github\.com/(ggml-org/llama\.cpp|unslothai/llama\.cpp)/pull/(\d+)/commits/([0-9a-f]{40})$")
for entry in json.load(open(sys.argv[1]))["prs"]:
    url, required = (entry, True) if isinstance(entry, str) else (entry["url"], entry.get("required", True))
    m = rx.match(url)
    if not m:
        sys.exit(f"pr-set.json: not a pinned PR commit url: {url}")
    print(m[1], m[2], m[3], "true" if required else "false")
PY
)"

[ -n "$PINS" ] || die "pr-set.json is empty: build the upstream tag $BASE directly"
SETHASH="$(awk '{print $1 "#" $2 ":" $3}' <<<"$PINS" | shasum -a 256 | cut -c1-7)"
TAG="${BASE}-mix-${SETHASH}"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "$TAG already exists at $(git rev-parse "$TAG^{commit}")"
    exit 0
fi

echo "base $BASE, $(grep -c . <<<"$PINS" || true) pin(s) -> $TAG"
git fetch -q --no-tags upstream "refs/tags/${BASE}:refs/tags/${BASE}"
git checkout -q --detach "refs/tags/${BASE}"

SKIPPED=""
while read -r SRC NUM SHA REQUIRED; do
    [ -n "$SRC" ] || continue
    if [ "$REQUIRED" = "false" ]; then
        # Optional pins are skipped once their PR is no longer open (CI semantics).
        STATE="$(curl -fsS "https://api.github.com/repos/${SRC}/pulls/${NUM}" 2>/dev/null \
                 | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null || true)"
        if [ -n "$STATE" ] && [ "$STATE" != "open" ]; then
            echo "  skip ${SRC}#${NUM} (optional, ${STATE})"
            SKIPPED="${SKIPPED}${SRC}#${NUM} "
            continue
        fi
    fi
    # The PR's own repo first, then Unsloth's refs/pins mirror, which keeps
    # commits an author force-pushed out of the PR.
    git fetch -q --no-tags "https://github.com/${SRC}.git" "$SHA" 2>/dev/null \
        || git fetch -q --no-tags unsloth "refs/pins/${SHA}" 2>/dev/null \
        || die "could not fetch ${SHA} for ${SRC}#${NUM}"
    git rev-parse -q --verify "${SHA}^{commit}" >/dev/null || die "${SHA} missing after fetch"
    echo "  merge ${SRC}#${NUM} @ ${SHA:0:9}"
    if ! git -c merge.conflictStyle=diff3 merge -q --no-ff --no-edit \
            -m "Merge ${SRC}#${NUM} @ ${SHA}" "$SHA" >/dev/null 2>&1; then
        # Only pure add/add conflicts are resolved; anything else stops here.
        if python3 "$TOOLS/unsloth/additive_merge.py" >/dev/null \
                && [ -z "$(git diff --name-only --diff-filter=U)" ]; then
            git commit -q --no-edit
            echo "    (additive merge: kept both sides of add/add conflicts)"
        else
            die "${SRC}#${NUM} does not merge onto ${BASE} + the pins before it; fix pr-set.json"
        fi
    fi
done <<<"$PINS"

# With .git present, cmake/build-info.cmake reports `git rev-list --count HEAD`
# as the build number: 1 in a shallow clone, and not the base number in a
# merged tree. Studio compares llama-server --version against bNNNN, so report
# the upstream base, as Unsloth's CI does for its source tarball.
COUNT="${BASE#b}"
printf '\n# Mix build: report the upstream base build, not this tree'"'"'s commit count.\nset(BUILD_NUMBER %s)\n' \
    "$COUNT" >> cmake/build-info.cmake
git add cmake/build-info.cmake
git commit -q -m "Report build number ${COUNT} for the ${TAG} mix"

{
    echo "Unsloth mix: upstream ${BASE} + pinned PRs from scripts/unsloth/pr-set.json"
    echo
    while read -r SRC NUM SHA REQUIRED; do
        [ -n "$SRC" ] || continue
        case " $SKIPPED " in *" ${SRC}#${NUM} "*) continue ;; esac
        echo "${SRC}#${NUM} @ ${SHA}"
    done <<<"$PINS"
} | git tag -a "$TAG" -F -

echo
echo "tagged $TAG at $(git rev-parse "$TAG^{commit}")"
echo "push with: git push origin $TAG"
