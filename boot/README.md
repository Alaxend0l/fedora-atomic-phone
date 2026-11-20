<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Boot methods

Each device picks one with `BOOT_METHOD` in its `device.env`. Each method is a
folder here; if it has a `build` script or `rootfs/`, it's applied as an image
layer between the desktop and the device (see the Containerfile).

| Method | Boot partition holds | Kernel updates | Needs | Status |
|---|---|---|---|---|
| [`uboot-android`](uboot-android/) | U-Boot as an Android boot image | normal (GRUB from ESP) | U-Boot support for the SoC + board DT; a partition for the ESP | builds; untested on a phone |
| [`android-bootimg`](android-bootimg/) | Linux kernel + initramfs + DTB | re-flashed by `fap-android-boot` at shutdown, A/B | stock bootloader that boots a mainline kernel | untested |
| [`lk2nd`](lk2nd/) | lk2nd | via extlinux | older Qualcomm phones | planned |

How to choose:
- Prefer **uboot-android** when U-Boot supports the SoC: updates are plain
  Fedora, and the boot partition is written once.
- Use **android-bootimg** when U-Boot doesn't (yet), or as a first step: if
  the stock bootloader can boot the kernel, you can start right away.
- Use **lk2nd** for old Qualcomm devices whose bootloader can't boot mainline.

Shared: `bootimg-args.sh` turns a device's `BOOTIMG_*` settings into
`mkbootimg` arguments. Both Android-boot-image methods use it.
