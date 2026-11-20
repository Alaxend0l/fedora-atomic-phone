<!-- SPDX-License-Identifier: (GPL-2.0+ OR BSD-3-Clause) -->
# Device tree additions for OnePlus 12

Our board DT, until its contents are upstream. It `#include`s the mainline
board file and adds or overrides nodes (PMICs, panel, touch, remoteprocs,
bandwidth votes). Start from `board.dts.example`: rename it to
`<mainline-board-name>-fap.dts` (e.g. `sm4250-oneplus-billie2-fap.dts`).

Build (needs podman; the Linux tag must match the kernel you boot):
```sh
tools/build-dtb.sh <linux-src> devices/oneplus-waffle/dts/<board>-fap.dts out/board.dtb
RAMBOOT_DTB=out/board.dtb boot/android-bootimg/make-ramboot.sh devices/oneplus-waffle out/ramboot
```
CI builds every `*.dts` here against the Linux tag of the newest Fedora
kernel (or `KERNEL_SOURCE` if it isn't `fedora`).

Rules:
- Every value that drives a regulator, boost, amp or charger is copied from
  the vendor DT, with the vendor node named in a comment. Wrong values can
  damage hardware.
- One comment per block: why it's needed, where the values come from, and
  how it was verified (or "untested").
- Example to read first: devices/oneplus-billie2/dts/sm4250-oneplus-billie2-fap.dts.
