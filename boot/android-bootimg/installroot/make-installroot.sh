#!/usr/bin/env bash
# Build the development install root (netroot + Plasma Mobile) as a tarball.
#   boot/android-bootimg/installroot/make-installroot.sh <outdir>
# Needs localhost/fap-netroot:latest (make-netroot.sh) first. Writes
# <outdir>/installroot.tar.zst. Install it from a RAM boot, see the README.
set -euo pipefail
out=${1:?usage: $0 <outdir>}
mkdir -p "$out"; out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
podman build -t localhost/fap-installroot:latest "$here"
cid=$(podman create localhost/fap-installroot:latest /bin/true)
podman export "$cid" | zstd -3 -T0 -q -c > "$out/installroot.tar.zst"
podman rm "$cid" >/dev/null
ls -lh "$out/installroot.tar.zst"
