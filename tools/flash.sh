#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
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
# FLASH_DRY_RUN=1 prints the fastboot commands instead of running them (no
# phone needed). FASTBOOT overrides the fastboot binary (tests).
#
# Status: untested. Read it before running it.
set -euo pipefail

dev=${1:?usage: $0 devices/<id> <outdir>}
out=${2:?usage: $0 devices/<id> <outdir>}
# shellcheck disable=SC1091
source "$dev/device.env"

# Never written, whatever a device.env says (A/B suffixes included):
# - identity/calibration (IMEI, RF tuning); EDL restores don't bring them back
PROTECTED_IDENTITY="modemst1 modemst2 fsg fsc persist"
# - boot chain and secure firmware (Qualcomm); a bad write here can hard-brick
PROTECTED_BOOTCHAIN="xbl xbl_config abl tz hyp rpm devcfg aop keymaster cmnlib cmnlib64 qupfw uefisecapp imagefv storsec multiimgoem featenabler vbmeta vbmeta_system"
# - firmware the OS needs at runtime (extracted on the phone, never replaced)
PROTECTED_FIRMWARE="modem dsp bluetooth bt_firmware"
# - Google Tensor / Samsung Exynos boot chain, radio and identity. Pixels that
#   ever ran the May 2025+ bootloader have no BootROM rescue: a bad write here
#   is permanent.
PROTECTED_TENSOR="abl bl1 bl2 bl31 gcf gsa gsa_bl1 ldfw pbl tzsw bootloader radio modem efs efs_backup modem_userdata persist mfg_data devinfo avb_custom_key"
# - the device's own list (device.env PROTECTED_PARTITIONS, space-separated,
#   shell globs allowed, e.g. "oem_* cdt"); it adds to the lists above
PROTECTED="$PROTECTED_IDENTITY $PROTECTED_BOOTCHAIN $PROTECTED_FIRMWARE $PROTECTED_TENSOR ${PROTECTED_PARTITIONS:-}"

die() { echo "flash: $*" >&2; exit 1; }
guard() {
    local p
    # Globs in the lists are wanted here; no word splitting happens in case.
    set -f
    for p in $PROTECTED; do
        # shellcheck disable=SC2254
        case "$1" in $p|${p}_a|${p}_b) set +f; die "refusing to write protected partition $1 (matches '$p')" ;; esac
    done
    set +f
}

# Every fastboot call goes through here. Never relock: relocking with a
# non-stock OS installed can leave a phone unbootable (and on Pixels, locked
# with a broken OS means no way back). Slot switches need ALLOW_SET_ACTIVE=1:
# on phones whose boot chain is A/B (Pixel), the other slot may hold an older
# bootloader, and booting it trips anti-rollback.
FASTBOOT=${FASTBOOT:-fastboot}
fb() {
    local arg
    case "$*" in
        *"flashing lock"*|*"oem lock"*) die "refusing to relock the bootloader (fastboot $*)" ;;
    esac
    for arg; do
        case "$arg" in
            --set-active|--set-active=*|set_active)
                [ "${ALLOW_SET_ACTIVE:-0}" = 1 ] || die "refusing to switch slots (fastboot $*); set ALLOW_SET_ACTIVE=1 if you checked both slots' bootloader versions" ;;
        esac
    done
    if [ "${FLASH_DRY_RUN:-0}" = 1 ]; then
        echo "dry run: fastboot $*"
    else
        "$FASTBOOT" "$@"
    fi
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
[ "${FLASH_DRY_RUN:-0}" = 1 ] || command -v "$FASTBOOT" >/dev/null || die "fastboot not installed"

echo "Flashing $DEVICE_NAME ($DEVICE_CODENAME). Waiting for fastboot..."
if [ "${FLASH_DRY_RUN:-0}" = 1 ]; then
    product=$FASTBOOT_PRODUCT
else
    product=$(fb getvar product 2>&1 | sed -n 's/^product: *//p')
fi
case "$product" in
    *"$FASTBOOT_PRODUCT"*) ;;
    *) die "connected device reports product '$product', expected '$FASTBOOT_PRODUCT'" ;;
esac

slots=""
[ "$FLASH_AB" = "true" ] && slots="--slot=all"

for p in $FLASH_ERASE; do
    if [ "$FLASH_AB" = "true" ]; then
        fb erase "${p}_a"; fb erase "${p}_b"
    else
        fb erase "$p"
    fi
done
fb flash "$FLASH_BOOT_PARTITION" "$out/$boot_img" $slots
[ -n "$FLASH_ESP_PARTITION" ] && fb flash "$FLASH_ESP_PARTITION" "$out/esp.img"
fb flash "$FLASH_ROOT_PARTITION" "$out/rootfs.img"

echo "Done. Rebooting; don't disconnect until it's back up."
fb reboot
