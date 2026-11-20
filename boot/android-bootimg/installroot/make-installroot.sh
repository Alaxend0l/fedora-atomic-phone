#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Build the development install root (netroot + Plasma Mobile) as a tarball.
#   boot/android-bootimg/installroot/make-installroot.sh <outdir>
# Needs localhost/fap-netroot:latest (make-netroot.sh) first. Writes
# <outdir>/installroot.tar.zst. Install it from a RAM boot, see the README.
set -euo pipefail
out=${1:?usage: $0 <outdir>}
mkdir -p "$out"; out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
# Build context = this folder + pin/ (FAP_PINNED=1: exact versions from
# lock/installroot.*, docs/updates.md; empty otherwise).
ctx=$(mktemp -d)
trap 'rm -rf "$ctx"' EXIT
cp -R "$here/." "$ctx/"
mkdir -p "$ctx/pin"
if [ -n "${FAP_PINNED:-}" ]; then
    # Only the versionlock; the base is the (pinned) netroot image.
    "$here/../../../tools/update/pin-context.sh" installroot "$ctx/pin" >/dev/null
fi
podman build -t localhost/fap-installroot:latest "$ctx"
cid=$(podman create localhost/fap-installroot:latest /bin/true)
podman export "$cid" | zstd -3 -T0 -q -c > "$out/installroot.tar.zst"
podman rm "$cid" >/dev/null
ls -lh "$out/installroot.tar.zst"
