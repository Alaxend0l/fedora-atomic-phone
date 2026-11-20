<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12 boot chain, flashing and recovery

Desk research, 2026-11-20. Nothing here is tested on a OnePlus 12 by us.
**[src]** = a source states it; **[guess]** = inference. Main sources: LC =
LineageOS `android_device_oneplus_sm8650-common` (`lineage-24.0` @ `03f70bdd`),
LW = `android_device_oneplus_waffle` (@ `0b070287`), the LineageOS wiki
(<https://wiki.lineageos.org/devices/waffle/install/>, `/fw_update/`), XDA
threads (IDs below, `https://xdaforums.com/t/….<id>/`), and
**ios-waffle** (<https://github.com/qarzis/ios-waffle>, branch
`waffle/gpu-bringup`, an experimental XNU port that RAM-boots a UEFI on a
real PJD110: the only hands-on low-level OnePlus 12 bring-up log we found).
Raw notes: `fap-build/research/oneplus12/notes/boot-unbrick.md`.

## 1. Boot chain
```
PBL (ROM) ─> XBL (xbl, xbl_config: DDR, ARB check) ─> UEFI (uefi partition, Qualcomm edk2)
          ─> ABL (abl partition, "LinuxLoader" UEFI app: fastboot, AVB, DT selection) ─> Linux at EL1
side images: tz (QTEE), hyp (Gunyah hypervisor), aop/aop_config, cpucp(+_dtb), shrm, devcfg,
             qupfw, uefisecapp, keymaster, imagefv, featenabler, oplus_sec, oplusstanvbk, splash, engineering_cdt
```
- Partition names are the 27 A/B firmware images LineageOS ships
  [src: LW `proprietary-firmware.txt`; wiki fw_update page]. Stage roles:
  standard for SM8550/SM8650 [guess, consistent with Qualcomm docs].
- Linux runs at **EL1** under Gunyah (ios-waffle's loader validates EL1
  [src: ios-waffle `docs/waffle-bringup.md`]); no KVM, as on all retail
  Snapdragon 8 Gen 3 phones [guess].
- Hardware facts measured on a PJD110 by ios-waffle [src]: SoC id 557,
  revisions 0x10000/0x20000, 8 CPUs MPIDR 0x000…0x700, PSCI via SMC, GIC
  distributor 0x17100000, redistributors 0x17180000 (stride 0x40000), arch
  timer 19.2 MHz, **UEFI display reservation 0xD5100000–0xD7C00000 with a
  1440×3168 GOP framebuffer**, TrustZone reservation at 0x82700000.

## 2. Partitions (UFS, `1d84000.ufshc`)
| Group | Partitions | Notes |
|---|---|---|
| Boot chain (A/B) | xbl, xbl_config, xbl_ramdump, uefi, abl, tz, hyp, aop, aop_config, cpucp, cpucp_dtb, devcfg, shrm, qupfw, uefisecapp, keymaster, imagefv, featenabler, oplus_sec, oplusstanvbk, engineering_cdt, splash | **never write**. Carry the hardware ARB value |
| Kernel (A/B) | `boot` 192 MiB (GKI kernel), `init_boot` 8 MiB (generic ramdisk), `vendor_boot` 192 MiB (vendor ramdisk + **DTBs**), `dtbo` 24 MiB, `recovery` 100 MiB (ramdisk only, no kernel) | LC `BoardConfigCommon.mk:162-166,196` |
| AVB (A/B) | vbmeta, vbmeta_system, vbmeta_vendor | LC :214-242 |
| Dynamic | `super` **16 GiB** (system, system_ext, product, vendor, vendor_dlkm, system_dlkm, odm, plus OPLUS `my_*`) | LW `BoardConfig.mk:7`; my_* [src: XDA 4776403] |
| Firmware (A/B) | modem (vfat), dsp (ext4), bluetooth (vfat) | LC `init/fstab.qcom:38-61` |
| **Identity / calibration** | `persist`, `ocdt`, `modemst1`, `modemst2`, `fsg`, `fsc` | **never write; back up first** (PJD110 IMEI loss, XDA 4790901) |
| Misc single | metadata, oplusreserve2, misc, qmcs, spunvm, userdata (rest of UFS, f2fs + hardware-wrapped-key FBE) | |

## 3. Boot images and DTB selection
- **Header v4** for boot and init_boot, page size 4096, base 0, kernel
  `Image` (uncompressed), cmdline `sysctl.kernel.firmware_config.force_sysfs_fallback=1`,
  the rest via bootconfig (`androidboot.hardware=qcom`,
  `androidboot.usbcontroller=a600000.dwc3`, …) [src: LC :51-84]. Stock root
  is patched in **init_boot** (Magisk) [src: XDA 4662553].
- **Base DTBs live in `vendor_boot`** (header v4 rule; ios-waffle extracted
  `vendor_boot.img-2.dtb` and `-3.dtb`, the two SoC revisions) [src];
  board overlays live in `dtbo`.
- Selection ids (OPDT, see downstream-kernel.md): `qcom,msm-id = <557 0x10000>,
  <557 0x20000>, <577 …>`, `qcom,board-id = <8 0>`; overlay adds
  `oplus,project-id = <22825|22877>` and `oplus,hw-id`. ABL picks base DTB
  by msm-id/board-id, then the overlay; whether ABL also matches
  `oplus,project-id` is [guess] (likely, OPLUS ABL).
- Consequence for us, by analogy with the N100 (where ABL forced the stock
  overlay onto any DT): expect to need either (a) a DTB carrying
  msm-id 557 + board-id <8 0> **and** an erased or matching dtbo, or (b) a
  boot path that doesn't use ABL's DT at all (U-Boot or UEFI chainload,
  section 5). [guess; first thing to test]

## 4. `fastboot boot` (RAM boot) on SM8650 OnePlus
- **Works on an unlocked OnePlus 12 (PJD110)**: ios-waffle RAM-boots its
  UEFI image with `fastboot boot HackiOS-waffle-PJD110-….img` repeatedly
  and lists "unlocked bootloader supporting `fastboot boot`" as a
  requirement [src: ios-waffle README, `docs/waffle-bringup.md`].
  Export models: same ABL family [guess]; not confirmed by a source.
- Not available from **fastbootd** (userspace) [src: droidwin mirror
  guides]; use bootloader fastboot.
- Which DTB a RAM-booted image gets: with a header v4 boot.img, ABL takes
  vendor ramdisk + DTB from the **flashed `vendor_boot`** [guess, AOSP
  semantics]. Mainline-on-Qualcomm practice for SM8550/SM8650 dev boards is
  a **header v2** image with kernel + `--dtb` (Linaro docs, see
  mainline-status.md); Mu-Silicium UEFI images for OnePlus SM8550/SM8650
  devices are also booted with `fastboot boot` [src: ios-waffle]. **To test
  first**: does waffle's ABL accept a v2 image with its own DTB via
  `fastboot boot`? (Same experiment we did on the N100; there ABL also
  required dtbo erased.)
- Our N100 lesson to carry over: start each `fastboot boot` from a fresh
  bootloader session (`fastboot reboot bootloader`); ABL state differs
  between fastboot mode and normal boot (hidden-dependencies.md).

### Two proven ways around ABL's DT handling on SM8650
1. **uniLoader as the "kernel"** (the OnePlus 12 mainline port's way):
   <https://github.com/ivoszbg/uniLoader> has board `oneplus-waffle`
   (`board/oneplus/board-waffle.c`, commit `f14ee108c9`, 2026-09-21, by
   DaDDevil). uniLoader is built with `CONFIG_LINUX_KRNL_HEADER_IMG=y` so
   ABL treats it as an arm64 `Image`; it carries our real kernel, DTB and
   ramdisk and jumps to them, so **ABL's DT selection/overlay only
   touches the stock DTB, which uniLoader ignores**. `waffle_defconfig`:
   `CONFIG_SM8650=y`, `TEXT_BASE=0xa8010000`, `PAYLOAD_ENTRY=0xa3200000`,
   `RAMDISK_ENTRY=0xb6f95000`; simplefb 1440×3168 ARGB8888 at **0xd5100000**
   (the stock splash buffer; matches ios-waffle's UEFI reservation)
   [src: uniLoader repo]. It can be `fastboot boot`-ed inside a stock-shaped
   boot.img (guess: header v4 boot.img with the stock vendor_boot left in
   place; how DaDDevil packs it is not documented in the repos we read).
2. **Header v4 split images with a no-op dtbo** (Xiaomi 14 "houji",
   SM8650, stock unlocked ABL; Fedora-bootc-based Armada fork
   <https://github.com/yoni13/armada-houji>, `ports/houji/README.md:186-220`):
   `boot_b` = Linux kernel, `init_boot_b` = early ramdisk, `vendor_boot_b`
   = **mainline device tree**, `dtbo_b` = "Xiaomi's selection fields with a
   no-op overlay", `vbmeta_b` = verification disabled; images **keep the
   stock os_version/patch-level values because ABL requires nonzero
   metadata even when unlocked**; all on slot b, nothing in the boot chain
   flashed [src]. Different OEM ABL, same Qualcomm base: the best
   template for a flashed (non-RAM) install on the OnePlus 12 [guess].
   Note the contrast with the N100 (SM4250), where a no-op dtbo did *not*
   work and dtbo had to be erased.

## 5. Boot-path options for Fedora
| Option | How | Pros | Cons / unknowns |
|---|---|---|---|
| **android-bootimg + uniLoader (RAM) first** | uniLoader(waffle) + our kernel + DTB + initramfs as a boot image, `fastboot boot` | no writes; ABL's DT handling bypassed; a working recipe exists for exactly this phone | uniLoader is a new boot component for us (`boot/uniloader/`?); packing details to work out; Fedora kernel lacks SM8650 pinctrl/interconnect (mainline-status.md) |
| android-bootimg, plain | v2 `--dtb` image or v4 + our DTB in vendor_boot (houji recipe) | no extra loader | DT selection rules unknown (§3); v4 needs a vendor_boot mode in `make-ramboot.sh` |
| **uboot-android** (later) | U-Boot `qcom_defconfig` + `qcom-phone.config` (SM8650 clocks/pinctrl/interconnect upstream in U-Boot) as boot image, ideally behind uniLoader or with the houji layout | Fedora-normal updates (GRUB/ESP) | U-Boot needs a waffle DTB with a `cont_splash`-labelled framebuffer; U-Boot fastboot has no UFS backend; RedMagic 9 Pro (SM8650) boots Debian's u-boot-qcom behind a BootShim, so it's feasible [src: FrontMage/ubuntu-nx769j-build-ci] |
| UEFI chainload (Mu-Silicium style) | a Mu UEFI port for waffle exists only in ios-waffle's work tree (PJD110); upstream Mu-Silicium has giulia/aston/dodge, not waffle | real UEFI + GOP, systemd-boot/GRUB direct (the OnePlus Ace 5 "giulia" mainline port boots this way) | out of tree; bundles Qualcomm UEFI blobs; ACPI-oriented |

## 6. AVB
- LineageOS ships `vbmeta` with **flags 3** (verification disabled) and
  test-key-signed chained partitions (boot RIL 4, dtbo 3, recovery 1,
  vbmeta_system 2, vbmeta_vendor 5) [src: LC :214-242]. On an unlocked
  phone ABL boots unsigned images (orange state) [src: LineageOS install
  works this way].
- For `fastboot boot` no vbmeta change is needed [guess, common QC ABL
  behaviour; ios-waffle needed none].
- If we ever flash a kernel: flash a vbmeta with flags 3 the LineageOS way
  (`fastboot flash vbmeta vbmeta.img` from LineageOS), never relock.

## 7. Anti-rollback (ARB) — read this before flashing anything
- OnePlus 12 **hardware ARB went 0 → 1 at OxygenOS/ColorOS 16.0.3.500 in
  every region** [src: Bartixxx32/Oneplus-antirollchecker README; XDA
  4778602, 4790901]. Last ARB=0 builds: CPH2581 16.0.0.201, CPH2573
  16.0.2.400, CPH2583 16.0.0.202, PJD110 16.0.1.300. Everything from
  16.0.3.500 (incl. 16.0.10.601 and IN 17.0.0.100) is ARB 1 ("Major 3,
  Minor 0").
- Mechanism: the value is in the signed `xbl_config` (hash segment OEM
  record `<major, minor, arb>`); XBL compares with QFPROM fuses; newer
  value blows the fuse, older images refuse to boot → **9008 brick**
  [src: XDA 4776403; checker's `arb_parser.py`].
- `fastboot getvar anti` / `oem device-info` / `getvar all` **don't show
  it** on recent OPLUS builds [src: XDA 4776403]. Infer it from the
  installed build number.
- Recovery from an ARB brick: EDL flash of a build ≥ 16.0.3.500
  (unbrick-tools.md) [src: XDA 4777032].
- Early press (9to5google, 2026-01-20) said only the 13/13T/15 were
  affected; outdated for the 12.
- Our rule: we never write boot-chain partitions anyway; if a LineageOS
  or stock firmware install is ever needed, only from a build ≥ the
  phone's ARB (LineageOS currently pins CPH2573_16.0.10.601, ARB 1).
  Kernel-side partitions (boot, init_boot, vendor_boot, dtbo, super) carry
  no hardware ARB [src/inference: XDA 4776403].

## 8. Unlocking
| Region / model | Procedure | Caveats |
|---|---|---|
| EU CPH2581, IN CPH2573, NA CPH2583 | Developer options → OEM unlocking; bootloader fastboot; `fastboot flashing unlock`; confirm on screen (wipes data) [src: LineageOS wiki] | **OxygenOS 15.0.0.863 broke bootloader fastboot** (exits after 1–2 s, "Unrecognized command flashing unlock"); updating to OxygenOS 16 fixed it [src: e.foundation thread 79130; bkerler/edl PR #829] |
| US | CPH2583 is sold carrier-unlocked; OnePlus's unlock-token page covers only "T-Mobile Edition" devices, and no T-Mobile/Verizon OnePlus 12 edition was found [src: oneplus.com/us/unlock_token; Best Buy listing] | no token needed [guess] |
| China PJD110 (ColorOS) | ColorOS 16+ requires the "Deep Testing" application (quota, real-name + face verification, 14-day window, max 4 devices/yr since July 2026), **except devices launched on ColorOS ≤ 15**, which keep the normal procedure [src: Notebookcheck; 9to5google 2025-08-14; bootloader-unlock wall of shame] | PJD110 launched on ColorOS 14 → should be exempt [guess; no source names the OnePlus 12] |
| Future | OxygenOS 17 reportedly cancelled; global units on ColorOS 17 might fall under Deep Testing [src: wall of shame, flagged unconfirmed] | **unlock before updating to a 17.x build** [guess, prudent] |

## 9. Restoring stock without EDL
- Full OTA zips: Oxygen Updater, XDA "Repo of ColorOS/OxygenOS builds",
  OPLUS CDN (`dfs-serverauto-*.allawnofs.com`) [src: XDA 4786217]. OnePlus
  reportedly pulled rollback packages for the 13 [src: 9to5google]; the 12
  may follow [guess].
- `payload-dumper-go` → images; flash kernel-side images from bootloader
  fastboot, firmware from **fastbootd** `--slot=all` (LineageOS fw_update
  procedure) [src].
- Region conversion CN ↔ global via fastboot works [src: XDA 4653255]; a
  failed one ended in crashdump. Not our business.

## 10. Brick-avoidance checklist (OnePlus 12)
1. Record build number → ARB level (≥ 16.0.3.500 ⇒ ARB 1). Keep the phone
   on an ARB-1 build; never install anything that carries older firmware
   (old LineageOS zips, "hybrid ROM" A14/A15 packages: XDA 4673058).
2. Unlock on OxygenOS 16 (not 15.0.0.863); don't update to 17.x before
   unlocking.
3. Back up identity partitions (`persist`, `ocdt`, `modemst1/2`, `fsg`,
   `fsc`) and both slots of `boot`, `init_boot`, `vendor_boot`, `dtbo`,
   `vbmeta*`, plus the full OTA of the installed build, with SHA256SUMS
   (unbrick-tools.md pre-flight).
4. Prepare and test (read-only) the EDL path: `bkerler/edl` + PR #829 +
   updated loader set.
5. Develop only with `fastboot boot` from bootloader fastboot. No
   `fastboot flash` until a RAM-boot of the same image worked.
6. When something must be written: only `boot`/`vendor_boot`/`dtbo` of the
   **inactive** slot first, keep the active slot stock; never `xbl*`,
   `abl`, `uefi`, `tz`, `hyp`, `aop*`, `devcfg`, `keymaster`, `modem`,
   `bluetooth`, `dsp`, `persist`, `ocdt`, EFS. Never `--slot=all`.
7. **Never relock** (a relock with modified images → 9008 brick, XDA 4790901).
8. Extend `tools/flash.sh`'s deny list with the OPLUS names above
   (device.env.draft `NEW_FLASH_DENY`).
