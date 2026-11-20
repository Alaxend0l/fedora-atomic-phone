#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Build a dev root: the netroot plus the image layers (base → desktop →
# opt-in layers → device), as one tarball for RAM boots (tiny-init's
# fap.netroot=) or, with --installroot, an ext4 root for fap.root=.
#
#   boot/android-bootimg/make-devroot.sh [--installroot] <device> <desktop> <outdir> [layer...]
#
#   <device>   folder under devices/ (its packages, rootfs/, build with
#              FAP_TARGET=devroot, and netroot/ overlay)
#   <desktop>  folder under desktops/
#   layer      opt-in layers under layers/, e.g. waydroid
#
# Writes <outdir>/netroot.tar.gz (what tiny-init fetches; gzip, busybox tar)
# or, with --installroot, <outdir>/installroot.tar.zst; plus SIZE (unpacked
# KiB, to size the tmpfs: tiny-init fap.netroot_size=; package count) and
# SHA256SUMS.
#
# Environment (passed to make-netroot.sh, which builds the base image
# localhost/fap-netroot-<device>:latest first):
#   NETROOT_EXTRA_MODULES, NETROOT_EXTRA_FIRMWARE  see make-netroot.sh
#   DEVROOT_SSH_KEY   public key for root (default ~/.ssh/id_ed25519.pub)
#   FAP_PINNED=1      exact versions: netroot from lock/netroot, the layers
#                     from lock/$DEVROOT_LOCK (default <device>-<desktop>-devroot)
#   DEVROOT_LOCK      lock target name (make-installroot.sh: installroot)
#
# Firmware or EFS data from a phone never goes into the repo; devices add it
# to the tarball outside this build (e.g. oneplus-waffle's
# build-env/fap-waffle-build.sh netroot with NETROOT_GENERIC=<this tarball>).
set -euo pipefail

installroot=
if [ "${1:-}" = --installroot ]; then installroot=1; shift; fi
usage="usage: $0 [--installroot] <device> <desktop> <outdir> [layer...]"
device=${1:?$usage}
desktop=${2:?$usage}
out=${3:?$usage}
shift 3
layers=("$@")

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
[ -d "$repo/devices/$device" ] || { echo "no such device: devices/$device" >&2; exit 1; }
[ -d "$repo/desktops/$desktop" ] || { echo "no such desktop: desktops/$desktop" >&2; exit 1; }
for l in ${layers[@]+"${layers[@]}"}; do
    [ -d "$repo/layers/$l" ] || { echo "no such layer: layers/$l" >&2; exit 1; }
done
mkdir -p "$out"
out=$(cd "$out" && pwd)

# 1. The netroot image for this device (Fedora + dev tools + kernel modules +
#    devices/<device>/netroot/).
netroot_image=localhost/fap-netroot-$device:latest
NETROOT_DEVICE=$device NETROOT_IMAGE=$netroot_image NETROOT_EXPORT=0 \
    "$here/make-netroot.sh" "$out" "${DEVROOT_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"

# 2. Build context: copies of exactly the layers this root is made of.
ctx=$(mktemp -d)
trap 'rm -rf "$ctx"' EXIT
mkdir -p "$ctx/layers/layers" "$ctx/pin"
cp -R "$repo/base" "$ctx/layers/base"
cp -R "$repo/desktops/$desktop" "$ctx/layers/desktop"
cp -R "$repo/devices/$device" "$ctx/layers/device"
cp -R "$repo/tools/image" "$ctx/layers/tools"
for l in ${layers[@]+"${layers[@]}"}; do cp -R "$repo/layers/$l" "$ctx/layers/layers/$l"; done
cp "$here/devroot/Containerfile" "$here/devroot/finalize" "$ctx/"
if [ -n "${FAP_PINNED:-}" ]; then
    lock=${DEVROOT_LOCK:-$device-$desktop-devroot}
    # Only the versionlock; the base is the (pinned) netroot image.
    "$repo/tools/update/pin-context.sh" "$lock" "$ctx/pin" >/dev/null
fi

tag=localhost/fap-devroot-$device-$desktop:latest
podman build \
    --build-arg NETROOT_IMAGE="$netroot_image" \
    --build-arg DEVICE="$device" \
    --build-arg DESKTOP="$desktop" \
    --build-arg LAYERS="${layers[*]+"${layers[*]}"}" \
    --build-arg INSTALLROOT="$installroot" \
    -t "$tag" "$ctx"

# 3. Export the filesystem (not the image layers) as one tarball.
cid=$(podman create "$tag" /bin/true)
if [ -n "$installroot" ]; then
    name=installroot.tar.zst
    podman export "$cid" | zstd -3 -T0 -q -c > "$out/$name"
else
    name=netroot.tar.gz
    podman export "$cid" | gzip -1 > "$out/$name"
fi
podman rm "$cid" >/dev/null
(cd "$out" && shasum -a 256 "$name" > SHA256SUMS)

# Disk usage of the root in KiB (tmpfs needs about this much, plus what the
# session writes at runtime) and the package count.
podman run --rm "$tag" sh -c 'echo "unpacked_kib=$(du -sxk / | cut -f1)"; echo "packages=$(rpm -qa | wc -l)"' > "$out/SIZE"
cat "$out/SIZE"
echo "$out/$name: $(du -h "$out/$name" | cut -f1) compressed"
