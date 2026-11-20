#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Fill a build context's pin/ directory for a pinned build of a dev image
# (make-netroot.sh, make-installroot.sh with FAP_PINNED=1; docs/updates.md).
# The Containerfile does `COPY pin/ /`, so this installs dnf5's versionlock
# for lock/<target> and Fedora's updates-archive repo (superseded versions
# live only there), and prints the build args that pin the images by digest.
#   tools/update/pin-context.sh <target> <ctx>/pin  -> prints --build-arg lines
set -euo pipefail
target=${1:?usage: $0 <lock target> <pin dir>}
pin=${2:?usage: $0 <lock target> <pin dir>}
repo=$(cd "$(dirname "$0")/../.." && pwd)
lock=$repo/lock/$target.versionlock.toml
env=$repo/lock/$target.images.env
for f in "$lock" "$env"; do
    [ -f "$f" ] || { echo "pin-context: no $f (tools/update/lock.py --target $target)" >&2; exit 1; }
done
# mkdir + cp: macOS's install(1) has no GNU -D.
mkdir -p "$pin/etc/dnf" "$pin/etc/yum.repos.d"
cp "$lock" "$pin/etc/dnf/versionlock.toml"
cp "$repo/tools/image/fap-updates-archive.repo" "$pin/etc/yum.repos.d/fap-updates-archive.repo"
chmod 644 "$pin/etc/dnf/versionlock.toml" "$pin/etc/yum.repos.d/fap-updates-archive.repo"
# BASE_IMAGE is the Containerfile's FEDORA_IMAGE.
sed -n -e 's/^BASE_IMAGE=/FEDORA_IMAGE=/p' -e 's/^KERNEL_IMAGE=/KERNEL_IMAGE=/p' "$env"
echo "pin-context: $target pinned ($(grep -c '^\[\[packages\]\]' "$lock") packages)" >&2
