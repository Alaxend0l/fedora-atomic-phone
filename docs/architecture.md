<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Architecture

## The short version
The OS is a container image. `podman build` turns this repo into one bootable
OCI image per (device, desktop). Phones run that image through **bootc**, so
updates are "pull a new image, reboot into it", with rollback, exactly like
Fedora Silverblue on a laptop.

## Concepts you need
- **Fedora Atomic / bootc.** The root filesystem is an image, read-only at
  runtime. `/etc` is merged on update, `/var` is per-machine state and never
  comes from the image. `bootc upgrade` stages a new image; the next boot uses
  it; `bootc rollback` goes back. Upstream docs: https://bootc-dev.github.io/bootc/
- **Containerfile as OS definition.** Everything that changes the OS (packages,
  config files, enabled services) happens in a `RUN` step at build time.
- **image-builder** turns a bootc image into a disk image with a partition
  table. The layout comes from `/usr/lib/image-builder/bootc/disk.yaml` inside
  the image, which each device ships.
- **Android bootloader (ABL).** Every Qualcomm phone has one. It only boots
  Android boot images from `boot_a`/`boot_b`. We don't replace it; we give it
  U-Boot or a kernel to load (see `boot/README.md` for the boot methods).

## Build flow
```
just build ──> podman build (Containerfile)
                 FROM quay.io/fedora-ostree-desktops/base-atomic:45   (every desktop)
                 run-layer base/
                 run-layer desktops/$DESKTOP/
                 run-layer boot/$BOOT_METHOD/     (BOOT_METHOD from device.env)
                 run-layer layers/$L/             (opt-in, LAYERS="waydroid")
                 run-layer devices/$DEVICE/
                 finalize
                 bootc container lint
               = localhost/fap-$DEVICE-$DESKTOP:45

just disk  ──> tools/make-disk.sh: image-builder → disk.raw → esp.img + rootfs.img
                 (+ boot.img for BOOT_METHOD=android-bootimg)
just uboot <src> ──> uboot.img          (BOOT_METHOD=uboot-android)
just flash ──> tools/flash.sh: fastboot flash boot/ESP/userdata per device.env

make-devroot.sh <device> <desktop> <out> [layer...]   (RAM-boot dev root)
               ──> make-netroot.sh: fedora:45 + dev tools + kernel modules
                     + devices/<device>/netroot/      = localhost/fap-netroot-<device>
                   devroot/Containerfile FROM that, FAP_TARGET=devroot:
                     run-layer base/, desktops/<desktop>/, layers/<l>/, devices/<device>/
                     devroot/finalize (user phone, hostname, tty1)
               = <out>/netroot.tar.gz (tiny-init fap.netroot=) or, with
                 --installroot, installroot.tar.zst (ext4 root, fap.root=)
```
Device-specific data that can't be in git (firmware and EFS copies from
the phone) is added to the dev-root tarball afterwards, locally; e.g.
`devices/oneplus-waffle/build-env/fap-waffle-build.sh netroot` with
`NETROOT_GENERIC=<dev root>` and `PHONE_BACKUP=`. Such tarballs are
sensitive and stay in `fap-build/`.

## Layers
Images are minimal and layered (docs/decisions/0003): **base** (every
phone: systemd, NetworkManager, ModemManager, PipeWire, SSH over the USB
gadget) → **desktop** (one per UI: the shell and its core apps) → **device**
(kernel, boot, firmware, quirks), plus opt-in **layers/** (Waydroid, ...)
that are never in the default image. The bootc image and the dev roots are
built from the same layer folders; nothing generic lives in `devices/`, and
anything two devices need moves down a layer.

Every layer folder has the same shape, applied by `tools/image/run-layer`
in this order:

| Item | Meaning |
|---|---|
| `packages` | explicit package list, one per line with a `#` reason; installed with `install_weak_deps=False` (no comps groups) |
| `packages.image`, `packages.devroot` | packages for one target only (e.g. Discover's rpm-ostree backend in the bootc image) |
| `rootfs/usr/...`, `rootfs/etc/...` | copied in as-is |
| `build` | script run with the folder as working directory: configuration (services, config edits); `FAP_TARGET` is `image` or `devroot` |

Packages go in the lists, not in `build` (tools/update/lock.py pins the
lists); the one exception is a device's kernel swap, which is image-only.
Order matters: base → desktop → boot method → opt-in layers → device. A
device can override anything a desktop did (e.g. a tablet forcing
landscape).

Only `/usr` and `/etc` may be shipped. `run-layer` refuses anything else, and
`finalize` empties `/var`. Both are bootc rules, not ours.

## Device folders
`devices/<vendor>-<codename>/`:

| File | Read by | Purpose |
|---|---|---|
| `device.env` | `build`, `check-device.sh`, `flash.sh` | identity, kernel, boot method, flash plan |
| `packages` | image + dev root | device packages (Qualcomm remoteproc tools, firmware) |
| `build` | image + dev root | device config (`FAP_TARGET`), kernel swap and dracut (image only) |
| `rootfs/` | image + dev root | device config files, incl. `disk.yaml` |
| `netroot/` | netroot, dev roots | RAM-boot-only files (e.g. `fap-modem-ram` serving EFS copies) |
| `README.md` | humans | hardware table, partitions, recovery, status |

`device.env` is plain `KEY=value` so both shell scripts and humans can read it
without a parser. `tools/check-device.sh` validates it.

## Where things live on the phone
| Partition | Contents |
|---|---|
| `boot_a`/`boot_b` | U-Boot (Android boot image) |
| ESP (device-specific choice) | GRUB, device trees |
| `userdata` | btrfs: `/`, `/boot`, `/var`, `/var/home` |
| everything else | untouched (modem firmware, identity partitions, …) |

## What's deliberately not here yet
Signing/registry publishing, CI images, an installer, OTA channels. They come
after one device boots.
