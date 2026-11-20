#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Tests for tools/flash.sh's guards, with FLASH_DRY_RUN=1 and a fake fastboot.
# No phone involved.
# shellcheck disable=SC2016,SC2001
# shellcheck source=tools/tests/lib.sh
source "$(dirname "$0")/lib.sh"
set +e
ROOT=$(cd "$TOOLS/.." && pwd)

printf '#!/bin/sh\necho "FAKE fastboot $*" >> "%s/fb.log"\n' "$T" > "$T/fake-fastboot"
chmod +x "$T/fake-fastboot"
export FASTBOOT="$T/fake-fastboot" FLASH_DRY_RUN=1

# A device folder: billie2's device.env plus overrides.
mkdev() {
    rm -rf "${T:?}/dev"; mkdir -p "$T/dev"
    { cat "$ROOT/devices/oneplus-billie2/device.env"; printf '%s\n' "$@"; } > "$T/dev/device.env"
}
mkdir -p "$T/out"; touch "$T/out/boot.img" "$T/out/rootfs.img" "$T/out/uboot.img" "$T/out/esp.img"
flash() { "$TOOLS/flash.sh" "$T/dev" "$T/out" 2>&1; }

# billie2 as it is: uboot-android with no ESP chosen -> refuses, as before.
mkdev
out=$(flash); check "billie2 (uboot-android, no ESP) still refuses" contains "$out" "FLASH_ESP_PARTITION is not set"

# billie2 with android-bootimg: the existing plan runs unchanged.
mkdev 'BOOT_METHOD="android-bootimg"'
out=$(flash); rc=$?
check "billie2 android-bootimg plan runs" [ $rc -eq 0 ]
check "erases dtbo on both slots" contains "$out" "dry run: fastboot erase dtbo_a"
check "flashes boot to all slots" contains "$out" "dry run: fastboot flash boot $T/out/boot.img --slot=all"
check "flashes userdata" contains "$out" "dry run: fastboot flash userdata $T/out/rootfs.img"
check "dry run never calls fastboot" [ ! -e "$T/fb.log" ]

refuse() {   # refuse <description> <expected message> <device.env lines...>
    local d=$1 msg=$2; shift 2
    mkdev 'BOOT_METHOD="android-bootimg"' "$@"
    out=$(flash); rc=$?
    if [ $rc -ne 0 ] && contains "$out" "$msg" && lacks "$out" "dry run: fastboot flash"; then ok "$d"; else nok "$d"; echo "$out" | sed 's/^/    /'; fi
}
refuse "Qualcomm boot chain (abl_b)" "protected partition abl_b" 'FLASH_BOOT_PARTITION="abl_b"'
refuse "identity (persist)" "protected partition persist" 'FLASH_ROOT_PARTITION="persist"'
refuse "Tensor bl1" "protected partition bl1" 'FLASH_BOOT_PARTITION="bl1"'
refuse "Tensor gsa_bl1_a" "protected partition gsa_bl1_a" 'FLASH_BOOT_PARTITION="gsa_bl1_a"'
refuse "Tensor efs_backup" "protected partition efs_backup" 'FLASH_ROOT_PARTITION="efs_backup"'
refuse "Tensor avb_custom_key erase" "protected partition avb_custom_key" 'FLASH_ERASE="dtbo avb_custom_key"'
refuse "Tensor radio" "protected partition radio" 'FLASH_ROOT_PARTITION="radio"'
refuse "device.env PROTECTED_PARTITIONS exact" "protected partition cdt" 'PROTECTED_PARTITIONS="cdt"' 'FLASH_ROOT_PARTITION="cdt"'
refuse "device.env PROTECTED_PARTITIONS glob" "matches 'oem_*'" 'PROTECTED_PARTITIONS="oem_*"' 'FLASH_ROOT_PARTITION="oem_stanvbk"'
refuse "device.env glob + slot suffix" "protected partition oem_x_b" 'PROTECTED_PARTITIONS="oem_*"' 'FLASH_ROOT_PARTITION="oem_x_b"'

# Partitions that only look similar are allowed.
mkdev 'BOOT_METHOD="android-bootimg"' 'PROTECTED_PARTITIONS="oem_*"' 'FLASH_ROOT_PARTITION="userdata"'
out=$(flash); check "globs don't match unrelated names" [ $? -eq 0 ]

# The fastboot wrapper itself (sourced in a subshell with a stub device).
wrapper() {
    mkdev 'BOOT_METHOD="android-bootimg"'
    # Run only up to the fb() definition, then call it.
    local args=("$@")
    # flash.sh's own positional arguments, for the eval
    set -- "$T/dev" "$T/out"
    ( eval "$(sed -n '/^set -euo/,/^case "\$BOOT_METHOD"/p' "$TOOLS/flash.sh" | sed '$d')"; fb "${args[@]}" ) 2>&1
}
out=$(wrapper flashing lock); check "fb refuses flashing lock" contains "$out" "refusing to relock"
out=$(wrapper flashing lock_critical); check "fb refuses flashing lock_critical" contains "$out" "refusing to relock"
out=$(wrapper oem lock); check "fb refuses oem lock" contains "$out" "refusing to relock"
out=$(wrapper --set-active=b); check "fb refuses --set-active=b" contains "$out" "refusing to switch slots"
out=$(wrapper set_active b); check "fb refuses set_active b" contains "$out" "refusing to switch slots"
out=$(wrapper flash boot x --set-active); check "fb refuses flash ... --set-active" contains "$out" "refusing to switch slots"
out=$(ALLOW_SET_ACTIVE=1 wrapper --set-active=b); check "ALLOW_SET_ACTIVE=1 allows it" contains "$out" "dry run: fastboot --set-active=b"
out=$(wrapper flashing unlock); check "fb doesn't confuse unlock with lock" contains "$out" "dry run: fastboot flashing unlock"

finish
