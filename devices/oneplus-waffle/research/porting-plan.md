<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12 porting plan

A phased plan to get our Fedora Atomic images onto a OnePlus 12. Each phase
ends in something we can show, says what it writes to the phone, and lists
risks. Desk research only so far; every "expect" is a guess until a device
confirms it. Read boot-and-flashing.md §7 (ARB) and §10 (checklist) before
phase 1.

## Guiding decisions
1. **Mainline, not Halium** (docs/decisions/0001). The OnePlus kernel is a
   reference only (downstream-kernel.md).
2. **Start from DaDDevil/linux `waffle-voice`** (mainline-status.md §2):
   it already has the board DT, panel, touch, haptics, OnePlus battmgr and
   ath12k fixes on v7.4-rc3. Pin a commit; contribute fixes back. Get the
   DTS licence sorted before copying it (it has no SPDX line).
3. **Kernel**: our own build (`kernels/qcom-sm8650/`, Fedora config +
   the waffle patches) until Fedora enables `PINCTRL_SM8650` /
   `INTERCONNECT_QCOM_SM8650` and the panel/touch drivers land upstream.
   In parallel: file the Fedora config request (cheap).
4. **Boot**: `android-bootimg` via **uniLoader** for RAM boots (bypasses
   ABL's DT selection, proven on this phone); for the installed system,
   either the same, or the Xiaomi-14 header-v4 layout (kernel in `boot`,
   DT in `vendor_boot`, no-op `dtbo`) on the **inactive slot**. U-Boot
   later (phase 4).
5. **Never touch the boot chain** (ARB fuses, OPLUS-only EDL). Only
   `fastboot boot` until phase 3.

## Phase 0: desk work, no phone (≈1 week of evenings, guess)
- [ ] Choose/buy a unit: **CPH2581 / CPH2583 / CPH2573** (global ABL, plain
      `fastboot flashing unlock`); avoid China PJD110 unless already
      unlocked (Deep Testing risk). 16 GB RAM matches DaDDevil's memory map.
- [ ] Download the full OTA of the build the phone will run (Oxygen
      Updater / XDA repo); `payload-dumper-go`; record sha256. Extract
      `boot`, `init_boot`, `vendor_boot`, `dtbo`, `vbmeta`, `modem`,
      `bluetooth`, `vendor`, `odm` (scratch only, never commit).
- [ ] `unpack_bootimg` boot/vendor_boot: confirm header v4, os_version,
      patch level, vendor cmdline, DTB count (expect 2: msm-id 557 revs
      0x10000/0x20000), page size. `mkdtimg dump dtbo.img`: overlay ids.
- [ ] Merge stock base DTB + waffle overlay with `fdtoverlay`; decompile;
      keep as `fap-build/research/oneplus12/stock-merged.dts` (reference
      for regulators/GPIOs, cross-check with DaDDevil's DTS).
- [ ] Check ARB of that OTA (Bartixxx32 checker method, read-only on
      `xbl_config`): expect ARB 1.
- [ ] Build DaDDevil's tree with `waffle_defconfig` (cross, in the Fedora
      44 container like U-Boot) and with a Fedora-config-based
      `kernels/qcom-sm8650` config; compare.
- [ ] Build uniLoader `waffle_defconfig` with our kernel + DTB + debug
      initramfs; work out how it is packed into a boot image (read
      uniLoader's `Makefile`/linker script; ask DaDDevil if unclear).
- [ ] Prepare the EDL kit (bkerler/edl + PR #829, updated SM8650 loader set,
      EDL ROM ≥ 16.0.3.500 for the region), hashes recorded.

## Phase 1: reconnaissance (phone in hand; writes: unlock only)
- [ ] OxygenOS ≥ 16.0.3.500 (ARB 1) **and not 15.0.0.863** (broken
      fastboot). Don't install a 17.x build before unlocking.
- [ ] `fastboot getvar all` (product: expect `pineapple`; slot; unlocked;
      bootloader version). Save.
- [ ] Unlock (`fastboot flashing unlock`, wipes data).
- [ ] RAM-boot a known-good image to learn the rules without risk:
      first the **stock boot.img** via `fastboot boot` (expect Android),
      then LineageOS's or TWRP's boot image.
- [ ] Backups need root or a RAM-booted Linux. Stock root means a
      Magisk-patched `init_boot` (a flash, not RAM-bootable); prefer doing
      the backups from our RAM-booted Linux in phase 2 instead.
- [ ] Test the EDL path read-only (enter 9008, `edl printgpt` with the
      VIP patch), then exit.

## Phase 2: first light (RAM only)
Goal: `ssh root@172.16.42.1` into our debug initramfs on the phone, panel
showing a console via simple-framebuffer.
- [ ] uniLoader + kernel (DaDDevil `waffle-voice` + our config) + our DTB
      (`devices/oneplus-waffle/dts/sm8650-oneplus-waffle-fap.dts`, initially
      DaDDevil's with ramoops, simple-framebuffer at 0xd5100000, no
      remoteprocs) + `make-ramboot.sh` initramfs; `fastboot boot`.
- [ ] If it hangs: ramoops at 0x85000000 (read after warm reboot via the
      next RAM boot), crashdump 900E means a fatal error; bisect by
      dropping nodes (U-Boot phones.rst method).
- [ ] **Back up identity partitions** (`persist`, `ocdt`, `modemst1/2`,
      `fsg`, `fsc`) and both slots of boot-side partitions over USB to
      `backup/` with SHA256SUMS (as on the N100).
- [ ] Measure: UFS LUNs and partition names, memory map ABL passes (for the
      12/24 GB variants), `clk_ignore_unused`/`pd_ignore_unused` needs.

## Phase 3: Fedora userspace (netroot, then userdata)
- [ ] Netroot over USB (`make-netroot.sh`) with panel driver, touch, battery.
- [ ] Decide the root: `userdata` (~220 GB on 256 GB units, guess; f2fs on
      stock → we'd mkfs ext4/xfs) and the ESP location (no spare partition;
      same open question as the N100; houji puts an EROFS image + overlay
      inside an ext4 `userdata`).
- [ ] Install: our boot image to the **inactive** slot only (`boot_b` +
      no-op `dtbo_b` + `vendor_boot_b` per the houji recipe, or uniLoader
      image in `boot_b`), stock Android stays on slot a. Restore =
      `fastboot --set-active=a`.

## Phase 4: bootc integration
- [ ] `fap-android-boot` for header v4 / uniLoader; A/B kernel updates.
- [ ] U-Boot (`qcom_defconfig` + `qcom-phone.config` + waffle DTB) as an
      option once the DTB is stable; GRUB from an ESP.

## Phase 5: hardware enablement
| Area | Starting point | Effort (guess) |
|---|---|---|
| GPU (A750) | upstream drm/msm + Mesa freedreno/turnip; OnePlus-signed `gen70900_zap.mbn` from vendor | small: works for siblings |
| Wi‑Fi / BT | ath12k + DaDDevil's 0x1107 fallback; linux-firmware; board data | small–medium |
| Charging / battery | pmic_glink + DaDDevil's battmgr changes; ADSP firmware from the phone | medium (safety: never set charger values ourselves) |
| Audio | WCD9395 upstream, TFA9874 on MI2S (DaDDevil, giulia port); write our topology | medium–large |
| Modem / data / SMS | mpss + IPA + rmtfs/tqftpserv/pd-mapper + ModemManager; giulia reports SMS/IMS + data | medium |
| Sensors | SSC via hexagonrpcd + libssc (giulia works) | medium |
| Alert slider | 2× MXM1120 hall sensors; small input driver | small |
| Cameras | DaDDevil's sensor drivers + CAMSS + libcamera | large |
| Fingerprint, NFC (SN220), IR | low priority | — |
| Suspend (s2idle) | houji: experimental | medium |

## Risks
1. **ARB / boot chain**: a firmware downgrade bricks to EDL; EDL needs
   leaked OPLUS loaders that a future ARB bump may revoke; the OnePlus Pad 2
   porter bricked a unit this way. Mitigation: never write boot-chain
   partitions, RAM-boot only until phase 3, keep EDL kit tested.
2. **Single-maintainer out-of-tree base** (DaDDevil): may stall; DTS
   licence unclear. Mitigation: upstreaming the DT ourselves is realistic
   (SoC is upstream; only board DT + panel + touch drivers).
3. **Fedora kernel gap** (pinctrl/interconnect): own kernel package until
   fixed.
4. **Unlock policy drift** (ColorOS/OxygenOS 17, Deep Testing): unlock
   early, keep the unit off 17.x until clarified.
5. **Iris7**: works in bootloader-left bypass per DaDDevil/ios-waffle; if a
   later firmware changes that, display needs an Iris7 driver.
6. **Memory map** varies by RAM size; DaDDevil hard-codes one.

## What to verify first on a real device (ordered)
1. `fastboot getvar product` / unlock works on the installed OxygenOS build.
2. `fastboot boot` of stock boot.img returns to Android (RAM boot works on
   the export ABL).
3. uniLoader(waffle) + mainline kernel reaches simple-framebuffer at
   0xd5100000 (display output from our kernel).
4. USB gadget networking → ssh.
5. UFS readable; identity partitions backed up.
6. Panel driver takes over from simplefb (DSI + Iris7 bypass).

## Tooling changes this needs in our repo
- `boot/uniloader/` (new boot method or a `make-ramboot.sh` mode): build
  uniLoader with a board defconfig, embed Image + DTB + initramfs, wrap in
  an Android boot image with stock-like header values.
- `make-ramboot.sh`: header v4 + vendor_boot mode (houji recipe), keeping
  stock os_version/patch level.
- `tools/flash.sh` deny list: OPLUS/SM8650 names (device.env.draft
  `NEW_FLASH_DENY`); refuse `--slot=all`; refuse writes to the active slot.
- `kernels/qcom-sm8650/`: Fedora config + `PINCTRL_SM8650`,
  `INTERCONNECT_QCOM_SM8650`, `PINCTRL_SM8650_LPASS_LPI`,
  `TYPEC_MUX_WCD939X_USBSS` + waffle drivers.
- Firmware extraction script for `qcom/sm8650/oneplus/waffle/` (firmware.md).

## Proposed device folder (when phase 2 starts)
```
devices/oneplus-waffle/
  README.md, TODO.md, hidden-dependencies.md   (as billie2)
  device.env                                   (from research/device.env.draft)
  dts/sm8650-oneplus-waffle-fap.dts            ((GPL-2.0+ OR BSD-3-Clause))
  research/                                    (this dossier)
```
