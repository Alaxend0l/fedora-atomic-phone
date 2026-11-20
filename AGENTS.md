<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Notes for agents working in this repo

Read this first, then [docs/status.md](docs/status.md) (where things stand,
what was tried, what's next). Keep both up to date when you finish a piece of
work; the next agent starts from them.

## What this is
Fedora Atomic (bootc) images for phones, with adding a phone = one folder under
`devices/`. Modeled on postmarketOS's per-device packaging; Pocketblue is a
reference (not a code base, see docs/decisions/0001). First device: OnePlus
Nord N100 (`oneplus-billie2`, SM4250 "bengal").

Companion repo with the N100 research, phone tools and backups:
`/Users/alecjakopin/Develop/UBports-N100` (its own AGENTS.md). Build scratch
space outside both repos: `/Users/alecjakopin/Develop/fap-build/` (U-Boot
checkout, built images). Pocketblue reference clones:
`/Users/alecjakopin/Develop/pocketblue-upstream/` (read-only reference).

## Orientation
| Read | For |
|---|---|
| docs/architecture.md | how images are built and layered |
| boot/README.md | boot methods (`uboot-android`, `android-bootimg`, `lk2nd`) |
| docs/porting.md | adding a device: `tools/new-device.sh` from `devices/_template/` (every device.env key documented) |
| docs/porting-cookbook.md | symptom → cause → fix recipes from the N100 and Pixel 8 work |
| docs/features.md, docs/devices.md | per-device `features.yaml`/`firmware.yaml` format; generated support matrix (`tools/support-matrix.py`) |
| .github/workflows/ci.yml | lint, tests, SPDX, DTBs + kmods vs. newest Fedora kernel (scripts in tools/ci/) |
| docs/roadmap.md | milestones + porting-tooling plan |
| docs/updates.md | package pinning (`lock/`, `just PINNED=1 build`), weekly update PRs, local-LLM risk review (`tools/update/`) |
| docs/re-tooling.md | ranked reverse-engineering tool ideas |
| docs/decisions/ | why things are the way they are |
| devices/oneplus-billie2/README.md | N100 hardware, partitions, recovery |
| devices/oneplus-billie2/TODO.md, features.yaml | N100 work list; feature status (source of truth for docs/devices.md) |
| kernels/qcom-sm6115/README.md | Fedora kernel coverage for the SoC |
| boot/uboot-android/README.md | U-Boot build + the N100 boot experiments |
| boot/android-bootimg/README.md | the RAM-boot dev loop (`fastboot boot` + netroot over USB) |
| docs/hardware/ | per-area bring-up plans for the N100's remaining hardware |
| docs/waydroid.md | Android apps via Waydroid: kernel check, setup, test plan |
| tools/README.md | every host tool: `fap-dev` (RAM-boot loop, ssh, audit), `flash.sh` guards, `recon/` (Android survey, `super` extraction, Linux inventory) |
| kmod/, devices/*/kmod/ | out-of-tree modules (touch, battery, panel); each README has its lessons |

## Reproducing the current N100 state (all RAM-only, nothing written)
1. `tools/build-dtb.sh <linux v7.3 tree> devices/oneplus-billie2/dts/sm4250-oneplus-billie2-fap.dts <out.dtb>`
2. `tools/build-kmod.sh <module dir> 7.3.4-300.fc45.aarch64 <kmod-out>` for
   kmod/ili9882n-ts, kmod/adc-ocv-battery, devices/oneplus-billie2/kmod/panel-ili9882n
3. Firmware from the phone (never commit): touch ILI image at
   `<fw-dir>/ilitek/oneplus-billie2-ili9882n-txd.bin` (kmod/ili9882n-ts/README.md).
4. `NETROOT_EXTRA_MODULES="<kmod-out> <kver>" NETROOT_EXTRA_FIRMWARE=<fw-dir> boot/android-bootimg/make-netroot.sh <netroot-dir>`
5. `RAMBOOT_DTB=<out.dtb> RAMBOOT_CMDLINE="fap.netroot=http://172.16.42.2:8000/netroot.tar.gz" boot/android-bootimg/make-ramboot.sh devices/oneplus-billie2 <img-dir>`
6. Phone in bootloader fastboot. Terminal 1: `tools/fap-dev serve <netroot-dir>`
   (waits for the USB network, then serves on 172.16.42.2:8000). Terminal 2:
   `tools/fap-dev ramboot <img-dir>/ramboot.img` (fresh ABL session,
   `fastboot boot`, waits for the gadget and SSH). Then `tools/fap-dev clock`
   (the RTC is unset), `tools/fap-dev ssh`. Modem/Wi‑Fi:
   `tools/fap-dev ssh /usr/libexec/fap-modem-ram`. Check what the bootloader
   left on: `tools/fap-dev audit`. By hand, without fap-dev: see
   tools/README.md (same steps).
Needs `dtbo_a` erased (it is, as of 2026-11-20; backup in UBports-N100/backup/).

## The installed system (since 2026-11-20)
The N100 boots on its own: `boot_a` holds our boot image, `userdata` is an
ext4 root labelled `fap-root` (Fedora 45 + Plasma Mobile, user `phone`).
- Rebuild the root: `make-netroot.sh` (with the extra modules/firmware), then
  `boot/android-bootimg/installroot/make-installroot.sh <dir>`; install from a
  RAM boot: `mkfs.ext4 -L fap-root` on userdata, stream the tarball in, add
  the zap shader (`qcom/sm6115/OnePlus/billie2/a610_zap.*` from vendor_a).
- Boot image: `RAMBOOT_CMDLINE="fap.root=LABEL=fap-root selinux=0" make-ramboot.sh …`;
  `fastboot boot` it for tests (nothing written), `fastboot flash boot_a` it to keep.
- Risky kernel/DT work: keep using `fastboot boot` (RAM); it can mount the
  installed root via `fap.root=`, or use the netroot instead.
- Bootloader: hold Vol Down while powering on (Power + Vol Up forces a restart).

## Rules
**Safety (the phone is real hardware):**
- Never write `modemst1/2`, `fsg`, `fsc`, `persist`, boot-chain partitions
  (`xbl`, `abl`, `tz`, `hyp`, `rpm`, `aop`, `vbmeta`, …) or firmware
  partitions (`modem`, `dsp`, `bluetooth`). `tools/flash.sh` enforces this
  (plus a Google Tensor list and a device's `PROTECTED_PARTITIONS`, refuses
  relocking and, without `ALLOW_SET_ACTIVE=1`, slot switches); don't work
  around it.
- Never relock the bootloader. Never automate EDL writes.
- Prefer `fastboot boot` (RAM only) over flashing. Before any write, have a
  verified backup and a tested restore command, and ask the user.
- Only one actor talks to the phone at a time. If you delegate research to
  subagents, tell them not to run adb/fastboot.
- A wrong regulator/boost/amp value can damage hardware: pin to vendor values.

**Work style:**
- The maintainer is an experienced developer who reviews everything; write
  code they can follow, and document as you go (docs/, READMEs, decision
  records). Say what's tested and what isn't.
- Commits: one logical change, message says why, end with the
  `Co-Authored-By: Claude …` trailer (see CONTRIBUTING.md AI policy).
  Commit when a step is done; push only when the user asks.
- Don't copy Pocketblue's code (AGPL main repo; `packages` repo unlicensed).
- Images: minimal and layered (base → desktop → device → opt-in extras); see
  docs/decisions/0003-minimal-layered-images.md.
- Licensing: repo default AGPL-3.0-or-later; kernel modules GPL-2.0-only;
  device trees (GPL-2.0+ OR BSD-3-Clause). Every new file gets an
  `SPDX-License-Identifier` line. See LICENSING.md.
  Read it for lessons.

## Build environment (verified 2026-11-20)
- macOS on Apple Silicon; `podman machine` (arm64, libkrun, 6 CPU, 2 GiB,
  rootless). `just` from Homebrew.
- U-Boot builds in a **Fedora 44** container (Fedora 45's OpenSSL 4.0 lacks the
  ENGINE API U-Boot's host tools need): `just uboot <u-boot-src>` or
  `boot/uboot-android/build-in-container.sh`.
- `just DEVICE=… DESKTOP=… build` hasn't been run yet (2 GiB may be tight).
- Override `just` variables *before* the recipe: `just DEVICE=x check`.

## Phone access
Our Linux on the phone (RAM boot or installed): `tools/fap-dev` (ssh, scp,
ramboot, state, audit; read-only/RAM-only by design) and `tools/recon/`.
Android/Ubuntu Touch on the N100: the UBports-N100 repo's `tools/` (adb
wrappers, root helper `psudo.sh` needs `PHONE_PIN` in the environment; ask
the user for it, never commit it). A new phone on Android:
`tools/recon/android-recon.sh`, then `tools/fap-dev state` in the bootloader. Fastboot rules learned the hard way are in
boot/uboot-android/README.md ("Testing without flashing").
