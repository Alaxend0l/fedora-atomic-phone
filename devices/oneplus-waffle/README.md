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
| Audio | WCD9395 (headphone path, AMIC1-5) + 2× TFA9874 speaker amps | WCD9395/LPASS/AudioReach upstream; TFA9874 no driver | v6: WCD path built, untested; speakers blocked |
| Charging | ADSP (pmic-glink, OnePlus battmgr messages) | out-of-tree changes | untested |
| Modem | SM8650 MPSS | upstream PAS | untested |
| GPU | Adreno 750 | upstream msm (zap is OnePlus-signed) | v7: built, untested |
| Other | haptics (PM8550B), alert slider, IR, NFC SN220, fingerprint | mostly not | haptics v7: built, untested |

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

Verified on the unit (2026-11-20): `fastboot boot` of the stock `boot_a.img`
(192 MiB) RAM-boots LineageOS; product `pineapple`, max-download-size
768 MiB, unlocked, slot a, version-bootloader empty. **ABL's fastboot
crashes into crashdump (05c6:900e) on a USB 3 / Thunderbolt link: use a
USB 2.0 cable for fastboot.**

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
  OnePlus 12 board DT and drivers), **slim** config for first light (arm64
  defconfig, non-Qualcomm platforms off) +
  `kernels/qcom-sm8650/fap.config` (+ `build-env/waffle.config`,
  `build-env/build.config`). `kernel --full` uses Fedora's whole aarch64
  config instead; Fedora's own 7.3.4 tree with the same fragment is the
  long-term path ([kernels/qcom-sm8650/README.md](../../kernels/qcom-sm8650/README.md)).
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
# optional: generic netroot + this kernel's modules (+ the unit's firmware: local only)
NETROOT_GENERIC=~/Develop/fap-build/netroot-shiba/netroot.tar.gz \
  PHONE_BACKUP=~/Develop/OnePlus12/backup/partitions-20261120 \
  VENDOR_FILES=~/Develop/OnePlus12/backup/vendor-files-20261120 \
  devices/oneplus-waffle/build-env/fap-waffle-build.sh netroot
# GPU firmware only, for another root (e.g. Plasma): unpack at / of that root
VENDOR_FILES=~/Develop/OnePlus12/backup/vendor-files-20261120 devices/oneplus-waffle/build-env/fap-waffle-build.sh gpu-firmware
```
The kernel tree gets our patches from
[kernels/qcom-sm8650/patches/](../../kernels/qcom-sm8650/patches/) (`series`,
each with an `Upstream-Status:` line) on every `kernel`/`dtb` run.
podman image `localhost/fap-waffle-build` ([build-env/Containerfile](build-env/Containerfile)),
case-sensitive volume `waffle-build`, outputs in `~/Develop/fap-build/waffle/`.
(`build-env/`, not `build/`: `build` is this device's image-layer script.)

## First RAM boot (proposed; nothing is written)
Exact commands, sha256s and stop conditions:
`~/Develop/fap-build/waffle/README.md`. In short: **USB 2.0 cable**,
bootloader fastboot (not fastbootd), then one
`tools/fap-dev ramboot ~/Develop/fap-build/waffle/ramboot/waffle-uniloader-v4.img --no-ssh`.
Rollback: it's RAM only. Hold Power (+ Vol Up) to restart; LineageOS boots
from the untouched slot a.

## Audio (v6, RAM boot + netroot)
**Test at low volume first.** Speaker amplifiers (smart amps with a boost
converter) can be damaged by wrong gains or boost settings; we never set
those ourselves.
- On: the board DT's `qcom,sm8650-sndcard` "OnePlus 12" with its two WCD9395
  links (RX_CODEC_DMA_RX_0 → RX macro → SoundWire RX → HPH; AMIC1-5 →
  SoundWire TX → TX macro → TX_CODEC_DMA_TX_3), AudioReach on the ADSP.
  Drivers are modules (arm64 defconfig has them; listed in
  `build-env/waffle.config`), loaded by udev in the netroot.
- Topology: Fedora qcom-firmware's generic AudioReach file (what
  `SM8650-QRD-tplg.bin` links to), installed as
  `qcom/sm8650/OnePlus 12-tplg.bin.xz`. No ACDB/calibration needed for it.
- UCM: [ucm/](ucm/) (based on alsa-ucm-conf's SM8650-QRD; HP PA at -9 dB).
- **Speakers / earpiece: blocked in v6/v7 (v8: see below).** Two NXP TFA9874 on `i2c_hub_7` (0x34
  bottom, 0x35 top; the top one is most likely the earpiece/second
  speaker). No TFA9874 driver exists in the kernel (tfa989x: 9890/95/97) and
  they need OnePlus's tuning container (`tfa98xx.cnt`-style, vendor/odm in
  `super`, not backed up; not in `modem_a` or `dsp_a`). The board DT's
  SECONDARY_MI2S link to a `max98357a` placeholder is deleted and
  `i2c_hub_7` stays off, so the amps are never touched. The generic
  topology also has no SECONDARY_MI2S back end.
- **USB-C analog headset: not yet in v6/v7 (v8: see below).** Needs `i2c3` (wcd939x-usbss switch),
  pmic-glink altmode and a codec ↔ usbss graph link the board DT lacks; and
  the USB port is the RAM boot's only link.
- Physical mic mapping (which AMIC is bottom/top/back) unknown.

## GPU, Bluetooth, video, haptics (v7, built 2026-11-20, untested)
- **GPU:** Adreno 750 (`qcom,adreno-43051401`, msm "gen70900") on, with
  gpucc built in (the GPU is a component of the msm DRM device, so a
  modular gpucc would hold back the display). Firmware at first open of the
  DRM device: `qcom/gen70900_sqe.fw.xz`, `qcom/gmu_gen70900.bin.xz` (Fedora
  qcom-firmware) and `qcom/sm8650/oneplus/waffle/gen70900_zap.mbn` (unit
  /vendor; linux-firmware's `qcom/sm8650/gen70900_zap.mbn` is QRD-signed).
  Userspace: Fedora mesa (freedreno, turnip). Any root can take the firmware
  from `fap-waffle-build.sh gpu-firmware`; with it, drop
  `LIBGL_ALWAYS_SOFTWARE`.
- **Bluetooth:** WCN7850 on UART14 (`qcom,wcn7850-bt`, hci_qca, 3.2 Mbaud),
  powered by the same PMU as Wi‑Fi. Firmware from the unit's `bluetooth_a`
  (`hmtbtfw20.tlv`, board-specific `hmtnv20.*`) in
  `/usr/lib/firmware/updates/qca` (searched before Fedora's generic copies).
- **Video:** Iris (vpu33) with the unit's `vpu33_4v.mbn`.
- **Haptics:** PM8550B LRA via DaDDevil's `qcom-spmi-haptics` (input FF). We
  use OnePlus's own vmax (1720 mV, dtbo entry 15) instead of the board DT's
  2.4 V. Custom FF effects can carry their own vmax (driver clamps at 10 V):
  test with `fftest`'s built-in effects only.

## Speakers, USB-C headset, sensors, cameras (v8, branch oneplus12-hw, built 2026-11-20, untested)
Test procedure, stop conditions and sha256s: `~/Develop/fap-build/waffle/hw/HW.md`.
Two netroot DTs: `-netroot` (everything below) and `-netroot-safe` (the v7
hardware set with the v8 kernel), as a fallback.
- **Speakers / earpiece:** two NXP TFA9874 on `i2c_hub_7` (0x34 bottom,
  reset GPIO 173; 0x35 top/earpiece, GPIO 178; L15B), fed by LPASS
  SECONDARY_MI2S (I2S1, gpio121-124), as OnePlus's audio DT
  (`waffle-22825-audio-pineapple-overlay.dtsi`) describes them. Driver: our
  `tfa9874` (kernel patch 0002): no boost converter ever (output bounded
  by VBAT), analog gain fixed to the vendor's tuning (TDMSPKG 5, AMPGAIN
  190, from the unit's `tfa98xx.cnt`), documented user registers only (no
  key/MTP/FAIM/hidden trim writes), and the amplifier stays powered down
  unless a stream plays **and** its `Amp Enable` switch (default off) is
  on. The container's "patch" is a dummy (TFA9874 has no DSP); its
  SpeakerBoost messages are for a host-DSP module we don't have, so there
  is **no speaker protection**: low levels and short tones only. Topology:
  Fedora's generic AudioReach file with its PRIMARY_MI2S_RX graph moved to
  SECONDARY_MI2S_RX (`build-env/tplg-sec-mi2s.py`, in-place binary patch,
  203 bytes; MultiMedia1/2/5 can feed it). No UCM device on purpose (no
  automatic routing to the speakers). Test: `fap-hw-speaker-test`.
- **USB-C analog headset:** the WCD9395 codec linked to the WCD USB-C
  audio switch (`typec-mux@e` on i2c3) as on SM8650-QRD (`mode-switch`,
  `orientation-switch`, port@1 graph); UCSI/pmic-glink report
  audio-accessory mode, the switch routes HPH/mic/ground, the codec's MBHC
  reports the jack. When the switch driver probes it briefly re-programs
  the USB D+/D- switches (USB link may blip); during the test the USB
  cable is replaced by the headset adapter, so the test runs unattended
  (`fap-hw-headset-watch`) or over Wi-Fi.
- **Sensors:** SSC on the ADSP via FastRPC: `hexagonrpcd` (sensors PD),
  `libssc`, `iio-sensor-proxy` with SSC support, built from source at
  pinned commits in the netroot; served files: `/vendor/etc/sensors`
  config + `sns_reg_config` (vendor copy), the persist sensor registry
  (calibration) and `/vendor/dsp` (dsp_a), under
  `/usr/share/qcom/sm8650/OnePlus/waffle`. Not started automatically:
  `fap-hw-sensors`.
- **Cameras:** CAMSS, CCI0/1, i2c9 and DaDDevil's sensor drivers (imx581
  main, lyt808 tele, ov64b, imx615 front; ak7377/ak7316/sem1217s lenses)
  as modules; front-camera EEPROM read-only in the DT; Fedora libcamera
  (simple pipeline + software ISP). CAMERA_ICP firmware isn't needed for
  raw capture through CAMSS. Test: `fap-hw-camera`.

## Known issues (v5/v6 live tests, 2026-11-20)
- **Wi‑Fi after a warm reboot from our Linux** (v7 carries a fix, untested:
  `kernels/qcom-sm8650/patches/0001-*` gives pwrseq-qcom-wcn a `.shutdown`
  that drives WLAN_EN/BT_EN low and drops its rail votes). Before: ath12k works (joined a
  network, HTTPS OK) only when the previous boot was LineageOS. After
  `systemctl reboot --reboot-argument=bootloader` + `fastboot boot` the
  WCN7850 firmware sits in its secondary bootloader ("Current EE: SECONDARY
  BOOTLOADER", qcom_mhi_qrtr probe -107, no wlp1s0). ath12k's own
  `.shutdown` already does the MHI power-down; what is missing is the WCN
  power sequencer dropping WLAN_EN (GPIO 16) and its rails: neither
  `pci-pwrctrl-pwrseq` nor `pwrseq-qcom-wcn` has a shutdown hook, and the
  GPIO belongs to the kernel, so userspace can't do it. Fix = a kernel patch
  (pwrctrl `.shutdown` → `pwrseq_disable`), not done yet. Workaround: boot
  LineageOS once (or a full power-off, Power + Vol Up) before testing Wi‑Fi.
  **Don't** `echo 1 > /sys/bus/pci/devices/*/remove` + rescan: it hung the
  kernel.
- Modem: v5's `fap-modem-ram` asked for `qcom_rmtfs_mem`, but the module is
  `rmtfs_mem`; v6 builds it in (`CONFIG_QCOM_RMTFS_MEM=y`, reserved memory
  `rmtfs@d7c00000`, client-id 1 from sm8650.dtsi).
- USB network: the host lost its DHCP lease after boot; v6 runs dnsmasq on
  usb0 (`fap-usb-dhcp.service`). Clock: v6 enables chronyd.

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
