<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
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

## RAM-boot dev loop (`make-ramboot.sh`)
`boot/android-bootimg/make-ramboot.sh devices/<id> <outdir> [image]` builds a
boot image that `fastboot boot` runs once from RAM, writing nothing:
- the image's kernel, EFI zboot unwrapped to `Image.gz` (checked for the arm64
  `ARMd` header),
- a debug initramfs: dracut with only the device's `RAMBOOT_DRIVERS` (what's
  needed for UFS and USB device mode) plus `dracut/90fap-usb-debug`, which
  brings up a USB CDC-ACM gadget with a root shell (macOS `/dev/cu.usbmodem*`),
- the kernel's own DTB for the device,
- cmdline `console=tty0 loglevel=7 ignore_loglevel clk_ignore_unused
  pd_ignore_unused rd.shell rd.timeout=60` (kernel log on the screen; keep the
  bootloader's clocks/power domains so the framebuffer survives).

First N100 build (2026-11-20, Fedora 45 kernel 7.3.4): 89.5 MB image (Image.gz
21.8 MB, initramfs 67.7 MB, 109 modules). The `/root` errors from dracut are
harmless (bootc images make `/root` a symlink into `/var`). Not booted yet.

### Network root (`make-netroot.sh`)
For a full Fedora userspace without touching the phone's storage:
```sh
boot/android-bootimg/make-netroot.sh out/netroot          # Fedora 45 rootfs tarball
RAMBOOT_CMDLINE="fap.netroot=http://172.16.42.2:8000/netroot.tar.gz" \
  boot/android-bootimg/make-ramboot.sh devices/<id> out/ramboot
fastboot boot out/ramboot/ramboot.img
# once the USB network is up on the host (172.16.42.2):
python3 -m http.server --bind 172.16.42.2 --directory out/netroot 8000
ssh root@172.16.42.1
```
tiny-init downloads the tarball into a 2.5 GB tmpfs, moves /dev /proc /sys
/run across and `switch_root`s to systemd. The USB gadget (serial + network)
survives the switch. The rootfs (`netroot/Containerfile`) carries the booted
kernel's exact modules, sshd (your public key, added at build time) and
autologin root on the USB serial port and the screen. Development only.

Status of the on-device sync tool and make-bootimg.sh: untested.
