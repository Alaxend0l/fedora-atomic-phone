# Source this after a device.env to get the mkbootimg layout arguments.
# Shared by every boot method that produces an Android boot image
# (uboot-android wraps U-Boot in one, android-bootimg wraps the Linux kernel).
#
#   source devices/<id>/device.env
#   source boot/bootimg-args.sh
#   mkbootimg $(bootimg_layout_args) --kernel ... -o boot.img
#
# The values must match what the phone's stock bootloader expects. Read them
# from a stock boot image with `unpack_bootimg --boot_img boot.img`.

bootimg_layout_args() {
    local v
    for v in BOOTIMG_HEADER_VERSION BOOTIMG_PAGESIZE BOOTIMG_BASE \
             BOOTIMG_KERNEL_OFFSET BOOTIMG_RAMDISK_OFFSET BOOTIMG_TAGS_OFFSET; do
        [ -n "${!v:-}" ] || { echo "bootimg: $v not set in device.env" >&2; return 1; }
    done
    echo --header_version "$BOOTIMG_HEADER_VERSION" \
         --pagesize "$BOOTIMG_PAGESIZE" \
         --base "$BOOTIMG_BASE" \
         --kernel_offset "$BOOTIMG_KERNEL_OFFSET" \
         --ramdisk_offset "$BOOTIMG_RAMDISK_OFFSET" \
         --tags_offset "$BOOTIMG_TAGS_OFFSET"
    # Header v2 carries the DTB as its own section, at a fixed address.
    if [ "$BOOTIMG_HEADER_VERSION" = 2 ]; then
        [ -n "${BOOTIMG_DTB_OFFSET:-}" ] || { echo "bootimg: v2 needs BOOTIMG_DTB_OFFSET" >&2; return 1; }
        echo --dtb_offset "$BOOTIMG_DTB_OFFSET"
    fi
}
