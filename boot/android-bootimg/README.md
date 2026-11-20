# Boot method: `android-bootimg`

The Linux kernel, device tree and initramfs go straight into the `boot`
partition as an Android boot image. No second bootloader. This is how
postmarketOS boots most phones, and it works anywhere the stock bootloader can
load a kernel.

```
ABL ──loads──> boot_a/boot_b: [ Image.gz | initramfs | DTB | cmdline ] ──> Fedora
```

The cost: the boot partition holds a copy of the kernel, so every bootc update
that changes the kernel or its arguments needs a re-flash.

## How updates stay in sync
1. `bootc upgrade` stages a new deployment.
2. At shutdown, ostree writes its Boot Loader Spec entry
   (`/boot/loader/entries/*.conf`: `linux`, `initrd`, `options` incl. `ostree=`).
3. `fap-android-boot.service` (ExecStop, ordered to run after that) builds a
   boot image from the entry and flashes it into the **inactive** A/B slot,
   then makes that slot active with `qbootctl`.
4. Next boot runs the new deployment from the new slot. The old slot still
   holds the previous kernel; `bootc rollback` plus switching back with
   `qbootctl` restores it.

Why not a `kernel-install` hook (as Pocketblue's Xiaomi Pad 6 uses)? On an
Atomic system the kernel arrives with the image; `kernel-install` doesn't run
on the phone during updates, and the `ostree=` argument only exists once a
deployment is staged.

## Kernel format gotcha
Fedora's aarch64 `vmlinuz` is an **EFI zboot** image (`MZ`, `zimg`, zstd
payload; `CONFIG_EFI_ZBOOT=y`, checked on Fedora 45). ABL can't boot it.
`fap-android-boot` extracts the payload and re-compresses it as `Image.gz`.

## device.env keys
| Key | Meaning |
|---|---|
| `KERNEL_DTB` | DTB path under the kernel's `dtb/` directory |
| `BOOTIMG_*` | boot image layout, see `boot/bootimg-args.sh` |
| `BOOTIMG_CMDLINE` | extra kernel arguments appended to the BLS `options` |
| `FLASH_BOOT_PARTITION`, `FLASH_AB` | where the image goes |
| `FLASH_ESP_PARTITION` | optional: bootc still creates an ESP in the disk image, but nothing on the phone reads it |

## Files
- `build`: image layer; installs the tool, `mkbootimg` (android-tools),
  `qbootctl`, and the device's `device.env`.
- `rootfs/usr/libexec/fap-android-boot`: build / sync / record.
- `rootfs/usr/lib/systemd/system/fap-android-boot.service`.
- `make-bootimg.sh`: builds the first `boot.img` from a disk image, using the
  image's own tool.

Status: untested.
