<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12 (`oneplus-waffle`)

Status: **planned** (2026-11-20). Nothing of ours has run on the phone yet.
First-light RAM-boot images are built (below); the next step is one
`fastboot boot`, which writes nothing. Feature status:
[features.yaml](features.yaml). Desk research (hardware, boot chain, ARB,
EDL, mainline status): the dossier on branch `oneplus12-research`,
`devices/oneplus-waffle/research/`.

Facts below come from the unit's read-only backup
(`OnePlus12/backup/partitions-20261120/`, 144 entries, SHA256SUMS; read with
`unpack_bootimg`/`avbtool`/`mkdtboimg` in the build container) and the
2026-11-20 recon (`OnePlus12/log/2026-11-20-recon.md`).

## The unit
CPH2583 (North America), project 22877, LineageOS 23.2-20260625 on
OxygenOS 16 CPH2573IN firmware, kernel 6.1.173, slot `_a`, bootloader
unlocked (orange), 16 GB RAM (ddr_info; verify). **Anti-rollback fuse is
1**: never flash any firmware or an older build.

## Hardware
| Part | Chip | Mainline status | Works here? |
|---|---|---|---|
| SoC | SM8650 "pineapple", msm-id 557 rev 2 | upstream since v6.8 | untested |
| RAM | 16 GB LPDDR5X (ABL fills `/memory`; DaDDevil's DT hard-codes a 16 GB map) | – | untested |
| Storage | UFS 4.0 at `1d84000` | upstream | untested |
| Display | BOE AA545 1440×3168 DSC cmd mode, behind a Pixelworks Iris7 | out of tree (DaDDevil `panel-boe-aa545`) | splash buffer at 0xd5100000 only |
| Touch | Synaptics S3910 (SPI4) | out of tree (DaDDevil) | untested |
| USB | DWC3 + SNPS eUSB2 + PM8550B repeater + QMP combo | upstream | untested |
| Wi‑Fi/BT | WCN7850 (PCIe0, UART14) | upstream (ath12k) + fallback patch | untested |
| Audio | WCD9395 + 2× TFA9874 | partly upstream | untested |
| Charging | ADSP (pmic-glink, OnePlus battmgr messages) | out-of-tree changes | untested |
| Modem | SM8650 MPSS | upstream PAS | untested |
| Other | haptics (PM8550B), alert slider, IR, NFC SN220, fingerprint | mostly not | untested |

## Boot chain (stock, measured from the backup)
XBL → UEFI → ABL. Header **v4** everywhere:
- `boot_a`: kernel only (35.5 MB uncompressed Image), cmdline empty,
  os 16.0.0 / 2026-06, AVB footer (LineageOS key, rollback index 1780272000),
  partition 192 MiB.
- `init_boot_a`: generic ramdisk, 8 MiB.
- `vendor_boot_a`: page 0x1000, base 0, kernel 0x8000, ramdisk 0x1000000,
  tags 0x100, dtb 0x1f00000; vendor cmdline
  `sysctl.kernel.firmware_config.force_sysfs_fallback=1 bootconfig`;
  **6 DTBs** (Cliffs ×2, Pineapple v1/v2, PineappleP v1/v2). ABL picks
  index 2 = "Pineapple v2 SoC" (`qcom,msm-id <557 0x20000>`, board-id 0 0).
- `dtbo_a`: 24 entries, all "Pineapple MTP,waffle", board-id 8 0; 0–11 are
  project 22825 (China), 12–23 project 22877. ABL applies entry 15
  (msm-id 557/577 rev 2, hw-id 0x28 0x19 0x20 0x21). Its
  `cont_splash_region` is 0xd5100000 + 0x2b00000.
- `vbmeta_a`: flags 3 (verification disabled), chains boot (RIL 4), dtbo
  (3), recovery (1), vbmeta_system (2), vbmeta_vendor (5).

So ABL builds its DT from vendor_boot + dtbo **from flash**, and is expected
to do the same for a `fastboot boot` of a v4 boot.img (AOSP semantics; not
yet observed). A plain mainline DTB therefore can't reach the kernel without
writing vendor_boot/dtbo, which we don't do. On the N100 the same kind of
ABL rejected mainline DTs unless dtbo was erased.

## How we RAM-boot: uniLoader
[uniLoader](https://github.com/ivoszbg/uniLoader) (GPL-2.0; board
`oneplus-waffle` by DaDDevil) is built with an arm64 Image header, so ABL
loads it as the kernel. It carries our kernel, DTB and initramfs, copies
the kernel to 0xa3200000 and the initramfs to 0xb6f95000 (it is linked at
0xa8010000; all three sit in the free bank 0xa3180000–0xd4e23000), patches
the initrd location into the DTB, and jumps. ABL's DT (stock base +
overlay) is ignored. Our DTB's `/chosen/bootargs` is the command line
(`CMDLINE_IN=dtb`). uniLoader also draws its log on the splash framebuffer.

Images (from `build-env/fap-waffle-build.sh images`, in
`~/Develop/fap-build/waffle/ramboot/`):
| Image | What | Use |
|---|---|---|
| `waffle-uniloader-v4.img` | header v4, stock os_version/patch level, kernel = uniLoader with the plain DTB (memory below 4 GiB only, debug shell) | **first attempt** |
| `waffle-uniloader-v4-netroot.img` | same, netroot DTB (full 16 GB map, `fap.netroot=`) | after the first one works |
| `waffle-uniloader-v2-stockdtb*.img` | header v2 with the stock DTBs in its DTB section (only built with `STOCK_BACKUP=`; contains OnePlus's DTBs: keep local) | fallback if ABL mishandles the v4 one |

## Kernel and DT
- Kernel: DaDDevil/linux `waffle-voice` @ `9359fc74` (v7.4-rc3 + the
  OnePlus 12 board DT and drivers) with Fedora's aarch64 config +
  `kernels/qcom-sm8650/fap.config` (+ `build-env/waffle.config`,
  `build-env/build.config`). Fedora's own 7.3.4 tree with the same fragment
  is the long-term path ([kernels/qcom-sm8650/README.md](../../kernels/qcom-sm8650/README.md)).
- DT: [dts/](dts/) has **our** first-light wrapper, which `#include`s
  DaDDevil's `sm8650-oneplus-waffle.dts` from the pinned tree at build time.
  **His DTS has no licence line.** It is never copied into this repository
  or into anything we publish. Before we upstream or commit it, or anything
  derived from it, we must ask the author to license it (mainline convention:
  BSD-3-Clause or `(GPL-2.0+ OR BSD-3-Clause)`). The built DTBs stay in
  `fap-build/`.
- First-light DT: simple-framebuffer on the splash buffer, UFS, USB
  peripheral at high speed, keys, ramoops at 0x85000000. Off: ADSP, MPSS,
  IPA, MDSS, GPU, video, PCIe/Wi‑Fi, BT, cameras, audio, touch, IR, flash LED,
  haptics, pmic-glink. Command line keeps the bootloader's state:
  `clk_ignore_unused pd_ignore_unused regulator_ignore_unused`.

## Build
```sh
devices/oneplus-waffle/build-env/fap-waffle-build.sh all
# optional: header v2 fallback from the stock backup (read-only mount)
STOCK_BACKUP=~/Develop/OnePlus12/backup/partitions-20261120 devices/oneplus-waffle/build-env/fap-waffle-build.sh images
# optional: generic netroot + this kernel's modules
NETROOT_GENERIC=~/Develop/fap-build/netroot-shiba/netroot.tar.gz devices/oneplus-waffle/build-env/fap-waffle-build.sh netroot
```
podman image `localhost/fap-waffle-build` ([build-env/Containerfile](build-env/Containerfile)),
case-sensitive volume `waffle-build`, outputs in `~/Develop/fap-build/waffle/`.
(`build-env/`, not `build/`: `build` is this device's image-layer script.)

## First RAM boot (proposed; nothing is written)
Exact commands, sha256s and stop conditions:
`~/Develop/fap-build/waffle/README.md`. In short: bootloader fastboot
(not fastbootd), then
`tools/fap-dev ramboot ~/Develop/fap-build/waffle/ramboot/waffle-uniloader-v4.img --no-ssh`.
Rollback: it's RAM only. Hold Power (+ Vol Up) to restart; LineageOS boots
from the untouched slot a.

## Partitions
| Partition | Size | Plan |
|---|---|---|
| `boot_a/b` | 192 MiB | untouched; RAM boots only |
| `init_boot_a/b`, `vendor_boot_a/b` | 8 / 192 MiB | untouched |
| `dtbo_a/b` | 24 MiB | untouched (`DTBO_MODE=stock`) |
| `userdata` | rest | later (Android data) |

## Recovery
- Way back: RAM boots change nothing; LineageOS is on slot a. Beyond that:
  OPLUS-locked EDL with leaked VIP loaders (dossier `unbrick-tools.md`),
  **untested**.
- Backups: `OnePlus12/backup/partitions-20261120/` (all partitions except
  userdata/super, both slots, identity/calibration incl. persist, ocdt,
  modemst1/2, fsg, fsc), with SHA256SUMS.
- **Never write**: `PROTECTED_PARTITIONS` in [device.env](device.env) (boot
  chain, firmware, identity). Never relock. Never `--slot=all`.

## Notes
- Open questions: does ABL's `fastboot boot` of a v4 image use the flashed
  vendor_boot (expected)? Does uniLoader's address layout hold on this ABL
  version (it's DaDDevil's, from his unit)? Does the splash survive the
  interconnect sync_state with MDSS off? See [TODO.md](TODO.md) and
  [hidden-dependencies.md](hidden-dependencies.md).
