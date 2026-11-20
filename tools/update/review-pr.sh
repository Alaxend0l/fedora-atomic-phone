#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Review an update PR with the local LLM and post the result as a PR comment
# (docs/updates.md). Runs on the Mac, because GitHub can't reach Ollama.
#   tools/update/review-pr.sh <pr-number> [--dry-run] [review.py options]
#   tools/update/review-pr.sh --latest [--dry-run]   newest open update PR
# --dry-run prints the review instead of commenting.
# Needs: gh (logged in), git, python3 + PyYAML (or uv), podman for changelogs
# (skipped without it), Ollama running for the AI part (evidence only
# otherwise). Env: FAP_LLM_URL, FAP_LLM_MODEL, FAP_LLM_TIMEOUT (review.py).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
UPDATE_BRANCH=${FAP_UPDATE_BRANCH:-update/fedora-packages}

pr=${1:?usage: $0 <pr-number>|--latest [--dry-run] [review.py options]}
shift
dry=
args=()
for a in "$@"; do
    case "$a" in --dry-run) dry=1 ;; *) args+=("$a") ;; esac
done

if [ "$pr" = --latest ]; then
    pr=$(gh pr list --head "$UPDATE_BRANCH" --state open --json number --jq '.[0].number')
    [ -n "$pr" ] || { echo "review-pr: no open PR from $UPDATE_BRANCH"; exit 0; }
fi

# python3 with PyYAML, else uv with PyYAML (as tools/support-matrix.py).
if python3 -c 'import yaml' 2>/dev/null; then
    py=(python3)
elif command -v uv >/dev/null; then
    py=(uv run -q --with pyyaml python3)
else
    echo "review-pr: needs PyYAML (pip install --user pyyaml) or uv" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$repo"
read -r base head < <(gh pr view "$pr" --json baseRefOid,headRefOid --jq '"\(.baseRefOid) \(.headRefOid)"')
git fetch -q origin "$base" "pull/$pr/head"
mkdir -p "$work/old" "$work/new"
git archive "$base" lock | tar -x -C "$work/old"
git archive "$head" lock | tar -x -C "$work/new"

cl=()
if command -v podman >/dev/null && podman info >/dev/null 2>&1; then
    cl=(--changelogs)
else
    echo "review-pr: podman not available, no changelogs" >&2
fi
"${py[@]}" "$here/check-updates.py" --old "$work/old/lock" --new "$work/new/lock" \
    ${cl[@]+"${cl[@]}"} --json "$work/updates.json" --markdown "$work/updates.md"
"${py[@]}" "$here/review.py" "$work/updates.json" --out "$work/review.md" ${args[@]+"${args[@]}"}

if [ -n "$dry" ]; then
    cat "$work/review.md"
    exit 0
fi
# One review comment per PR (marked by review.py), updated on later runs.
cid=$(gh api --paginate "repos/{owner}/{repo}/issues/$pr/comments" \
        --jq '.[] | select(.body | contains("<!-- fap-update-review -->")) | .id' | tail -n 1)
if [ -n "$cid" ]; then
    gh api -X PATCH "repos/{owner}/{repo}/issues/comments/$cid" -F body=@"$work/review.md" >/dev/null
else
    gh pr comment "$pr" --body-file "$work/review.md"
fi
echo "review-pr: commented on PR #$pr"
