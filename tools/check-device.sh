#!/usr/bin/env bash
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
[ -f "$dir/rootfs/usr/lib/image-builder/bootc/disk.yaml" ] || err "missing rootfs/usr/lib/image-builder/bootc/disk.yaml"

# shellcheck disable=SC1091
source "$dir/device.env"
for key in DEVICE_NAME DEVICE_CODENAME DEVICE_SOC DEVICE_STATUS KERNEL_PACKAGE \
           KERNEL_DTB BOOT_METHOD FLASH_ROOT_PARTITION DISK_SECTOR_SIZE; do
    [ -n "${!key:-}" ] || err "device.env: $key is empty"
done

case "$DEVICE_STATUS" in planned|boots|usable|daily) ;; *) err "DEVICE_STATUS must be planned|boots|usable|daily" ;; esac

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
