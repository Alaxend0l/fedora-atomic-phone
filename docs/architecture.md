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
  U-Boot to load (see `boot/u-boot/README.md`).

## Build flow
```
just build ──> podman build (Containerfile)
                 FROM quay.io/fedora/fedora-silverblue:45 (or kinoite, base-atomic)
                 run-layer base/
                 run-layer desktops/$DESKTOP/
                 run-layer devices/$DEVICE/
                 finalize
                 bootc container lint
               = localhost/fap-$DEVICE-$DESKTOP:45

just disk  ──> tools/make-disk.sh: image-builder → disk.raw → esp.img + rootfs.img
boot/u-boot/build.sh ──> uboot.img
just flash ──> tools/flash.sh: fastboot flash boot/ESP/userdata per device.env
```

## Layers
Every layer folder has the same shape, applied by `tools/image/run-layer`:

| Item | Meaning |
|---|---|
| `rootfs/usr/...`, `rootfs/etc/...` | copied into the image as-is |
| `build` | script run inside the build with the folder as working directory |

Order matters: base → desktop → device. A device can override anything a
desktop did (e.g. a tablet forcing landscape).

Only `/usr` and `/etc` may be shipped. `run-layer` refuses anything else, and
`finalize` empties `/var`. Both are bootc rules, not ours.

## Device folders
`devices/<vendor>-<codename>/`:

| File | Read by | Purpose |
|---|---|---|
| `device.env` | `build`, `check-device.sh`, `flash.sh` | identity, kernel, boot method, flash plan |
| `build` | image build | device packages, services, kernel swap |
| `rootfs/` | image build | device config files, incl. `disk.yaml` |
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
