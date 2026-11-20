<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Boot method: `lk2nd` (planned)

[lk2nd](https://github.com/msm8916-mainline/lk2nd) is a bootloader for older
Qualcomm phones (MSM8916-era and similar) whose stock bootloader is too
limited or quirky to boot mainline Linux directly. It's flashed to `boot` and
then boots the real OS, for example from an `extlinux.conf` on the root
filesystem.

```
stock LK/aboot ──loads──> boot: lk2nd ──> extlinux.conf ──> Fedora kernel
```

Not implemented. `tools/check-device.sh` accepts the value so a port can
declare it; `tools/flash.sh` refuses until this folder has:
- a `build` layer (if the image needs anything for it),
- a way to get bootc/ostree to keep an `extlinux.conf` in sync
  (ostree can write one: `sysroot.bootloader=syslinux`),
- flash instructions.
