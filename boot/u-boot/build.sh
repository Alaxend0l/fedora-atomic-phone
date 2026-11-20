#!/usr/bin/env bash
# Build U-Boot as an Android boot image, so the phone's own bootloader (ABL)
# loads it from the boot partition. U-Boot then provides EFI, and the rest of
# the boot is the normal Fedora path (GRUB from the ESP).
#
#   boot/u-boot/build.sh <u-boot-src> <dtb-name> <outdir>
#   e.g. boot/u-boot/build.sh ~/src/u-boot qcom/sm4250-oneplus-billie2 output
#
# Needs: aarch64 gcc (or a cross compiler via CROSS_COMPILE), make, mkbootimg.
# Status: untested.
set -euo pipefail

src=${1:?usage: $0 <u-boot-src> <dtb-name> <outdir>}
dtb=${2:?usage: $0 <u-boot-src> <dtb-name> <outdir>}
out=$(realpath -m "${3:?usage: $0 <u-boot-src> <dtb-name> <outdir>}")
mkdir -p "$out"

# qcom_defconfig is U-Boot's generic Qualcomm build; the board comes from the
# device tree, which U-Boot carries a copy of under dts/upstream/.
make -C "$src" qcom_defconfig
make -C "$src" -j "$(nproc)" DEVICE_TREE="$dtb"
gzip -c "$src/u-boot-nodtb.bin" > "$out/u-boot-nodtb.bin.gz"

# Header v2 with a separate DTB, at the offsets the N100's ABL expects (same
# as its stock/UBports boot images: kernel 0x8000, dtb 0x01f00000).
mkbootimg \
    --header_version 2 \
    --kernel "$out/u-boot-nodtb.bin.gz" \
    --dtb "$src/dts/upstream/src/arm64/$dtb.dtb" \
    --pagesize 4096 --base 0x0 \
    --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
    --tags_offset 0x100 --dtb_offset 0x1f00000 \
    -o "$out/uboot.img"
echo "wrote $out/uboot.img"
