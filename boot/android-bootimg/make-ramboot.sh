#!/usr/bin/env bash
# Build a RAM-bootable Android boot image from a Fedora (bootc) image, for the
# no-flash development loop: `fastboot boot <image>` runs it once from RAM and
# writes nothing to the phone.
#
#   boot/android-bootimg/make-ramboot.sh devices/<id> <outdir> [image]
#   image defaults to quay.io/fedora/fedora-silverblue:45
#
# Contents: the image's kernel (EFI zboot unwrapped to Image.gz), a small
# debug initramfs (dracut with only the device's boot drivers plus
# fap-usb-debug: a root shell over USB serial), and the kernel's own DTB for
# the device. The command line asks for the kernel log on the screen.
set -euo pipefail

usage="usage: $0 devices/<id> <outdir> [image]"
dev=$(realpath "${1:?$usage}")
out=${2:?$usage}
image=${3:-quay.io/fedora/fedora-silverblue:45}
mkdir -p "$out"
out=$(realpath "$out")
boot=$(cd "$(dirname "$0")/.." && pwd)

podman run --rm -v "$dev:/device:ro" -v "$boot:/boot-methods:ro" -v "$out:/out" "$image" bash -euc '
    source /device/device.env
    source /boot-methods/bootimg-args.sh
    dnf5 -y -q install android-tools zstd >/dev/null 2>&1

    kver=$(ls /usr/lib/modules | sort -V | tail -1)
    vmlinuz=/usr/lib/modules/$kver/vmlinuz
    dtb=/usr/lib/modules/$kver/dtb/$KERNEL_DTB
    [ -f "$dtb" ] || { echo "no $KERNEL_DTB in $kver" >&2; exit 1; }

    # Fedora aarch64 vmlinuz is EFI zboot: MZ stub + compressed Image.
    if [ "$(dd if=$vmlinuz bs=1 skip=4 count=4 status=none)" = zimg ]; then
        off=$(od -An -t u4 -j 8 -N 4 $vmlinuz | tr -d " ")
        size=$(od -An -t u4 -j 12 -N 4 $vmlinuz | tr -d " ")
        comp=$(dd if=$vmlinuz bs=1 skip=24 count=8 status=none | tr -d "\0")
        tail -c +$((off + 1)) $vmlinuz | head -c $size | \
            { [ "$comp" = zstd ] && zstd -dc || gzip -dc; } > /tmp/Image
    else
        cp $vmlinuz /tmp/Image
    fi
    # Sanity: arm64 Image header magic "ARMd" at offset 0x38.
    [ "$(dd if=/tmp/Image bs=1 skip=56 count=4 status=none)" = "ARMd" ] \
        || { echo "kernel is not an arm64 Image" >&2; exit 1; }
    gzip -9nc /tmp/Image > /out/Image.gz

    # Debug initramfs: only the drivers to reach UFS and the USB gadget.
    cp -r /boot-methods/android-bootimg/dracut/90fap-usb-debug /usr/lib/dracut/modules.d/
    dracut --force --no-hostonly --kver "$kver" \
        --drivers "${RAMBOOT_DRIVERS:?set RAMBOOT_DRIVERS in device.env}" \
        --add fap-usb-debug \
        --omit "plymouth ostree bootc network network-manager ifcfg nfs iscsi lvm dm mdraid crypt multipath nvdimm fcoe tpm2-tss nss-softokn i18n" \
        --gzip /out/initramfs.img

    cmdline="console=tty0 loglevel=7 ignore_loglevel clk_ignore_unused pd_ignore_unused rd.shell rd.timeout=60 ${BOOTIMG_CMDLINE:-}"
    args=(--kernel /out/Image.gz --ramdisk /out/initramfs.img --cmdline "$cmdline")
    if [ "$BOOTIMG_HEADER_VERSION" = 2 ]; then
        args+=(--dtb "$dtb")
    else
        cat /out/Image.gz "$dtb" > /out/Image.gz-dtb
        args[1]=/out/Image.gz-dtb
    fi
    # shellcheck disable=SC2046
    mkbootimg $(bootimg_layout_args) "${args[@]}" -o /out/ramboot.img
    cp "$dtb" /out/
    echo "kernel $kver"
    unpack_bootimg --boot_img /out/ramboot.img --out /tmp/chk | grep -E "header version|kernel_size|ramdisk size|dtb size|command line args"
    ls -la /out
'
