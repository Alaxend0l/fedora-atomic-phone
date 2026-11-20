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
case "$BOOT_METHOD" in uboot-android) ;; *) err "unknown BOOT_METHOD $BOOT_METHOD" ;; esac

sector=$(sed -n 's/^ *sector_size: *\([0-9]*\).*/\1/p' "$dir/rootfs/usr/lib/image-builder/bootc/disk.yaml")
[ "$sector" = "$DISK_SECTOR_SIZE" ] || err "disk.yaml sector_size ($sector) != DISK_SECTOR_SIZE ($DISK_SECTOR_SIZE)"

[ "$fail" = 0 ] && echo "$dir: ok"
exit "$fail"
