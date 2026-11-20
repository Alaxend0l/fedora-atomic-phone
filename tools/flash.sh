#!/usr/bin/env bash
# Flash a built image onto a phone in fastboot mode, following the device's
# device.env. Runs on the host (macOS or Linux) with `fastboot` installed.
#
#   tools/flash.sh devices/<id> <outdir>
#
# Expects in <outdir>, depending on BOOT_METHOD:
#   uboot-android:   uboot.img (just uboot), esp.img, rootfs.img (just disk)
#   android-bootimg: boot.img, rootfs.img (just disk); esp.img only if
#                    FLASH_ESP_PARTITION is set
#
# Status: untested. Read it before running it.
set -euo pipefail

dev=${1:?usage: $0 devices/<id> <outdir>}
out=${2:?usage: $0 devices/<id> <outdir>}
# shellcheck disable=SC1091
source "$dev/device.env"

# Partitions that hold per-device identity/calibration (IMEI, RF tuning).
# A full restore from EDL does not bring them back. Never write them.
PROTECTED="modemst1 modemst2 fsg fsc persist"

die() { echo "flash: $*" >&2; exit 1; }
guard() {
    for p in $PROTECTED; do
        case "$1" in "$p"|"${p}_a"|"${p}_b") die "refusing to write protected partition $1" ;; esac
    done
}

case "$BOOT_METHOD" in
    uboot-android)
        [ -n "$FLASH_ESP_PARTITION" ] || die "$dev: FLASH_ESP_PARTITION is not set (see its README)"
        boot_img=uboot.img; need="uboot.img esp.img rootfs.img" ;;
    android-bootimg)
        boot_img=boot.img; need="boot.img rootfs.img"
        [ -n "$FLASH_ESP_PARTITION" ] && need="$need esp.img" ;;
    *) die "BOOT_METHOD=$BOOT_METHOD has no flash support yet (see boot/$BOOT_METHOD/)" ;;
esac
for f in $need; do
    [ -f "$out/$f" ] || die "missing $out/$f"
done
for p in $FLASH_BOOT_PARTITION $FLASH_ESP_PARTITION $FLASH_ROOT_PARTITION $FLASH_ERASE; do
    guard "$p"
done
command -v fastboot >/dev/null || die "fastboot not installed"

echo "Flashing $DEVICE_NAME ($DEVICE_CODENAME). Waiting for fastboot..."
product=$(fastboot getvar product 2>&1 | sed -n 's/^product: *//p')
case "$product" in
    *"$FASTBOOT_PRODUCT"*) ;;
    *) die "connected device reports product '$product', expected '$FASTBOOT_PRODUCT'" ;;
esac

slots=""
[ "$FLASH_AB" = "true" ] && slots="--slot=all"

for p in $FLASH_ERASE; do
    if [ "$FLASH_AB" = "true" ]; then
        fastboot erase "${p}_a"; fastboot erase "${p}_b"
    else
        fastboot erase "$p"
    fi
done
fastboot flash "$FLASH_BOOT_PARTITION" "$out/$boot_img" $slots
[ -n "$FLASH_ESP_PARTITION" ] && fastboot flash "$FLASH_ESP_PARTITION" "$out/esp.img"
fastboot flash "$FLASH_ROOT_PARTITION" "$out/rootfs.img"

echo "Done. Rebooting; don't disconnect until it's back up."
fastboot reboot
