# 0002: Pluggable boot methods

Date: 2026-11-20. Status: accepted.

## Context
The scaffold assumed one boot path: U-Boot in the boot partition, then EFI and
GRUB. That only works where U-Boot supports the SoC and board. Many phones
(early Tensor work, SoCs without U-Boot support) can only be booted the way
postmarketOS does it: kernel, initramfs and DTB in an Android boot image.
Older Qualcomm phones often need lk2nd.

## Decision
`BOOT_METHOD` in `device.env` selects a folder under `boot/`. Each method:
- may add an image layer (`build`, `rootfs/`), run between desktop and device;
- declares its required `device.env` keys (checked by `tools/check-device.sh`);
- has its own branch in `tools/flash.sh` / `tools/make-disk.sh`.

Methods: `uboot-android` (default), `android-bootimg`, `lk2nd` (planned).
The Android boot image layout (`BOOTIMG_*`) is shared via
`boot/bootimg-args.sh`.

## android-bootimg on an Atomic system
A `kernel-install` hook (as Pocketblue's Xiaomi Pad 6 uses) doesn't fit:
kernels arrive with images, not via `kernel-install` on the phone, and the
`ostree=` argument exists only after a deployment is staged. Instead
`fap-android-boot.service` builds the boot image from ostree's next Boot
Loader Spec entry at shutdown (after `ostree-finalize-staged`), flashes the
inactive A/B slot and switches to it with `qbootctl`, keeping the previous
slot as a fallback that mirrors `bootc rollback`.

Fedora's aarch64 kernel is an EFI zboot image; the tool unwraps it to
`Image.gz` because Android bootloaders can't boot zboot.

## Consequences
- Adding a boot method touches `boot/<method>/`, `check-device.sh`,
  `flash.sh`, `make-disk.sh`. Adding a phone still touches only its folder.
- `android-bootimg` writes the boot partition on every kernel/cmdline change;
  a failure mid-write is covered by A/B, not on single-slot phones.
