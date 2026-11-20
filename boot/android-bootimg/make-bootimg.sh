#!/usr/bin/env bash
# Build the first boot.img for flashing, from a disk image made by
# tools/make-disk.sh. Runs on an aarch64 Linux host as root.
#
#   boot/android-bootimg/make-bootimg.sh <image> <outdir>
#
# Uses the image's own fap-android-boot tool, so the first boot image is built
# exactly like the ones the phone builds for itself on updates.
# Status: untested.
set -euo pipefail

image=${1:?usage: $0 <image> <outdir>}
out=$(realpath "${2:?usage: $0 <image> <outdir>}")
[ -f "$out/disk.raw" ] || { echo "no $out/disk.raw; run tools/make-disk.sh first" >&2; exit 1; }

loop=$(losetup --find --show --partscan "$out/disk.raw")
trap 'umount -R "$out/mnt" 2>/dev/null || true; losetup -d "$loop"' EXIT
mkdir -p "$out/mnt"
# Partition 2 is the btrfs root (see the device's disk.yaml); /boot is a subvolume.
mount -o ro,subvol=boot "${loop}p2" "$out/mnt"

podman run --rm -v "$out/mnt:/boot:ro" -v "$out:/out" "$image" \
    /usr/libexec/fap-android-boot build /boot /out/boot.img
