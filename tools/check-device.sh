#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Validate a device folder before building. Runs on the host.
# Usage: tools/check-device.sh devices/<id>
set -euo pipefail

dir=${1:?usage: $0 devices/<id>}
dir=${dir%/}
fail=0
err() { echo "$dir: $*" >&2; fail=1; }

[ -d "$dir" ] || { echo "no such device folder: $dir" >&2; exit 1; }
[ -f "$dir/device.env" ] || { err "missing device.env"; exit 1; }
[ -x "$dir/build" ] || err "missing or non-executable build script"
[ -f "$dir/README.md" ] || err "missing README.md"
[ -f "$dir/features.yaml" ] || err "missing features.yaml (docs/features.md)"
[ -f "$dir/rootfs/usr/lib/image-builder/bootc/disk.yaml" ] || err "missing rootfs/usr/lib/image-builder/bootc/disk.yaml"

# shellcheck disable=SC1091
source "$dir/device.env"
for key in DEVICE_NAME DEVICE_CODENAME DEVICE_SOC DEVICE_STATUS KERNEL_PACKAGE \
           KERNEL_DTB BOOT_METHOD FLASH_ROOT_PARTITION DISK_SECTOR_SIZE; do
    [ -n "${!key:-}" ] || err "device.env: $key is empty"
done

case "$DEVICE_STATUS" in research|planned|boots|usable|daily|unmaintained) ;;
    *) err "DEVICE_STATUS must be research|planned|boots|usable|daily|unmaintained" ;; esac

# Optional keys (devices/_template/device.env documents them): check formats.
oneof() {  # oneof KEY allowed...
    local key=$1 v; shift
    [ -z "${!key:-}" ] && return 0
    for v; do [ "${!key}" = "$v" ] && return 0; done
    err "device.env: $key='${!key}' must be one of: $*"
}
oneof BOOTIMG_HEADER_VERSION 0 1 2 3 4
oneof DTBO_MODE erase stock overlay
oneof CMDLINE_IN bootimg dtb
oneof RAMDISK_IN boot vendor_boot init_boot
oneof VENDOR_KERNEL_BOOT true false
oneof FLASH_AB true false
oneof FLASH_SLOT a b
oneof RAMBOOT_INITRAMFS tiny dracut
case "${KERNEL_SOURCE:-fedora}" in
    fedora|git:*#*) ;;
    *) err "device.env: KERNEL_SOURCE must be 'fedora' or 'git:<url>#<branch>'" ;;
esac
for f in ${AVB_FOOTERS:-}; do
    [[ "$f" =~ ^[a-z_]+:(0x[0-9a-fA-F]+|[0-9]+)$ ]] || err "device.env: AVB_FOOTERS entry '$f' is not partition:size"
done
if [ "${DTBO_MODE:-}" = overlay ] && [ -z "${DTBO_BOARD_ID:-}" ]; then
    err "device.env: DTBO_MODE=overlay needs DTBO_BOARD_ID"
fi
if [ -n "${FIRMWARE_MANIFEST:-}" ] && [ ! -f "$dir/$FIRMWARE_MANIFEST" ]; then
    err "device.env: FIRMWARE_MANIFEST $FIRMWARE_MANIFEST doesn't exist"
fi
if grep -q '@[A-Z_]*@' "$dir/device.env"; then
    err "device.env: template placeholders left: $(grep -o '@[A-Z_]*@' "$dir/device.env" | sort -u | tr '\n' ' ')"
fi

# Each boot method is a folder under boot/ and has its own required keys.
root=$(cd "$(dirname "$0")/.." && pwd)
[ -d "$root/boot/$BOOT_METHOD" ] || err "unknown BOOT_METHOD '$BOOT_METHOD' (no boot/$BOOT_METHOD/)"
need() { for key; do [ -n "${!key:-}" ] || err "device.env: $key is required for BOOT_METHOD=$BOOT_METHOD"; done; }
bootimg_keys="BOOTIMG_HEADER_VERSION BOOTIMG_PAGESIZE BOOTIMG_BASE BOOTIMG_KERNEL_OFFSET BOOTIMG_RAMDISK_OFFSET BOOTIMG_TAGS_OFFSET"
case "$BOOT_METHOD" in
    uboot-android)
        # shellcheck disable=SC2086
        need UBOOT_DTB FLASH_BOOT_PARTITION $bootimg_keys ;;
    android-bootimg)
        # shellcheck disable=SC2086
        need FLASH_BOOT_PARTITION $bootimg_keys ;;
    lk2nd) ;;
esac
if [ "${BOOTIMG_HEADER_VERSION:-}" = 2 ] && [ -z "${BOOTIMG_DTB_OFFSET:-}" ]; then
    err "device.env: BOOTIMG_HEADER_VERSION=2 needs BOOTIMG_DTB_OFFSET"
fi

sector=$(sed -n 's/^ *sector_size: *\([0-9]*\).*/\1/p' "$dir/rootfs/usr/lib/image-builder/bootc/disk.yaml")
[ "$sector" = "$DISK_SECTOR_SIZE" ] || err "disk.yaml sector_size ($sector) != DISK_SECTOR_SIZE ($DISK_SECTOR_SIZE)"

[ "$fail" = 0 ] && echo "$dir: ok"
exit "$fail"
