#!/usr/bin/env bash
# Build U-Boot as an Android boot image, so the phone's own bootloader (ABL)
# loads it from the boot partition. U-Boot then provides EFI, and the rest of
# the boot is the normal Fedora path (GRUB from the ESP).
#
#   boot/uboot-android/build.sh <u-boot-src> devices/<id> <outdir>
#
# Reads UBOOT_DEFCONFIG, UBOOT_DTB and the BOOTIMG_* layout from device.env.
# Needs: aarch64 gcc, make, mkbootimg. Use build-in-container.sh on macOS.
set -euo pipefail

src=${1:?usage: $0 <u-boot-src> devices/<id> <outdir>}
dev=${2:?usage: $0 <u-boot-src> devices/<id> <outdir>}
out=$(realpath -m "${3:?usage: $0 <u-boot-src> devices/<id> <outdir>}")
mkdir -p "$out"
here=$(cd "$(dirname "$0")" && pwd)

# shellcheck disable=SC1091
source "$dev/device.env"
# shellcheck disable=SC1091
source "$here/../bootimg-args.sh"

# qcom_defconfig is U-Boot's generic Qualcomm build; the board comes from the
# device tree, which U-Boot carries a copy of under dts/upstream/.
# Config fragments (e.g. qcom-phone.config) are merged on top of the defconfig.
# shellcheck disable=SC2086
make -C "$src" "${UBOOT_DEFCONFIG:-qcom_defconfig}" ${UBOOT_CONFIG_FRAGMENTS:-}
# A device can ship its own default environment (e.g. to boot into fastboot
# when its buttons don't work in U-Boot).
if [ -n "${UBOOT_ENV_FILE:-}" ]; then
    "$src/scripts/config" --file "$src/.config" \
        --enable ENV_USE_DEFAULT_ENV_TEXT_FILE \
        --set-str ENV_DEFAULT_ENV_TEXT_FILE "$(realpath "$dev/$UBOOT_ENV_FILE")"
    make -C "$src" olddefconfig
fi
make -C "$src" -j "$(nproc)" DEVICE_TREE="$UBOOT_DTB"
gzip -c "$src/u-boot-nodtb.bin" > "$out/u-boot-nodtb.bin.gz"

dtb="$src/dts/upstream/src/arm64/$UBOOT_DTB.dtb"
if [ "$BOOTIMG_HEADER_VERSION" = 2 ]; then
    kernel="$out/u-boot-nodtb.bin.gz"
    extra=(--dtb "$dtb")
else
    # Header v0/v1: the bootloader finds the DTB appended to the kernel.
    cat "$out/u-boot-nodtb.bin.gz" "$dtb" > "$out/u-boot-dtb"
    kernel="$out/u-boot-dtb"
    extra=()
fi

# shellcheck disable=SC2046
mkbootimg $(bootimg_layout_args) --kernel "$kernel" "${extra[@]}" -o "$out/uboot.img"
echo "wrote $out/uboot.img"
