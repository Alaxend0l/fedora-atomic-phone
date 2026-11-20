<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12 ("waffle", Snapdragon 8 Gen 3 / SM8650 "pineapple"): research dossier

Desk research for a future port of our Fedora Atomic phone images to the
OnePlus 12. Written 2026-11-20 with no OnePlus 12 in hand: nothing here is
tested by us. Claims carry sources (URL or repo file:line); guesses are
marked. Codename **waffle** confirmed (LineageOS wiki `waffle.yml:11`,
`lineage_waffle.mk:17`); the Qualcomm platform name is **pineapple**.

## Verified on the user's unit (2026-11-20)
- CPH2583 (NA), 512 GB, LineageOS 23.2 on OxygenOS 16 CPH2573IN firmware; unlocked.
- **`fastboot boot` of the stock boot.img works** (RAM boot into LineageOS).
- **Use a USB 2.0 cable for bootloader fastboot**: on a USB 3/Thunderbolt link ABL's fastboot crashes into crashdump (05c6:900e).
- Vol Up+Down+Power with the cable attached enters EDL (9008), not fastboot.
- Notes and verified full-partition backup: ~/Develop/OnePlus12/.

## Documents
| File | Contents |
|---|---|
| [hardware.md](hardware.md) | inventory from OnePlus's GPL device tree: variants (22877 = CPH2581/2583/2573, 22825 = PJD110), PMICs, BOE AA545 panel + Pixelworks Iris7, Synaptics S3910 touch, WCN7850, WCD9395 + TFA9874, cameras, charging (ADSP + HL7227 + P9415), haptics, alert slider, NFC, IR |
| [boot-and-flashing.md](boot-and-flashing.md) | boot chain (XBL → UEFI → ABL, Gunyah, EL1), partitions, header v4 / vendor_boot DTBs / dtbo ids, `fastboot boot`, two proven ways around ABL's DT handling (uniLoader; Xiaomi-14 v4 layout), AVB, **anti-rollback (ARB 1 since 16.0.3.500)**, unlock per region, **brick-avoidance checklist** |
| [unbrick-tools.md](unbrick-tools.md) | brick levels, EDL 9008 entry, no public MSM tool, leaked OPLUS loader + "VIP" handshake, bkerler/edl PR #829 (Mac-native), qdl limits, Windows tools, pre-flight checklist |
| [mainline-status.md](mainline-status.md) | SM8650 upstream by component and version, **DaDDevil/linux `waffle-voice` (out-of-tree OnePlus 12 port)**, sibling ports (OnePlus Ace 5, Xiaomi 14 on Fedora bootc, Pad 2, RedMagic 9 Pro), U-Boot, **Fedora kernel config gaps** |
| [downstream-kernel.md](downstream-kernel.md) | OnePlusOSS 6.1 repos and branches, Kleaf vs LineageOS build, DT layout and selection ids, where to look per porting task |
| [firmware.md](firmware.md) | blobs per function, signing (linux-firmware has no usable SM8650 DSP firmware), where each lives on the phone, extraction plan |
| [porting-plan.md](porting-plan.md) | phases 0–5, risks, what to verify first, tooling changes, device-folder proposal |
| [device.env.draft](device.env.draft) | proposed `device.env` (not a live device folder) |

Scratch (not committed): `/Users/alecjakopin/Develop/fap-build/research/oneplus12/`
(`oplus-dt` OnePlusOSS DT sparse clone, `lineage-waffle`, `lineage-sm8650-common`,
`lineage/`, `daddevil-linux` (waffle-voice sparse), `linux-next`, `linux-firmware`,
`lf-community`, `fedora-config`, `ios-waffle` docs, `arbchk` (read only, not run),
`raw/` fetched XDA/LineageOS pages, `notes/` raw research notes with every source).

## Verdict (one page)

**Feasible, and the most promising of our three candidates.** Unlike the
Pixel 8, the SoC is fully upstream, and unlike the N100 it has a modern GPU,
Wi‑Fi 7 and 16 GB RAM, but the board itself isn't upstream yet:
- **SM8650 is mainline since v6.8** (Linaro/Qualcomm): GPU (A750, v6.9),
  remoteprocs (v6.9), ath12k WCN7850, sound card + WCD939x, Iris video
  (v6.17), CAMSS (v6.19), U-Boot clocks/pinctrl. The OnePlus 12 uses the
  QRD's exact PMIC set.
- **An out-of-tree OnePlus 12 port exists and is active**: DaDDevil/linux
  `waffle-voice` (v7.4-rc3 + 51 commits, last push 2026-11-20) with
  `sm8650-oneplus-waffle.dts`, a BOE AA545 DSC panel driver (60/90/120 Hz
  claimed), Synaptics S3910 touch, PM8550B haptics, OnePlus `qcom_battmgr`
  and ath12k fixes, audio and voice-call patches, camera sensor drivers;
  plus a uniLoader board that boots it with stock ABL.
- **Sister device proof**: the OnePlus Ace 5 (SM8650, same OEM) runs
  mainline with display, touch, GPU, Wi‑Fi/BT, audio, charging, sensors
  (SSC), SMS and mobile data; the Xiaomi 14 (SM8650) runs a **Fedora-bootc**
  distro (Armada fork) from internal storage on stock ABL.
- Bootloader unlocks with plain `fastboot flashing unlock` on global models;
  `fastboot boot` RAM-boots work (ios-waffle on a PJD110).

**Comparison**
| | N100 (billie2, SM4250) | Pixel 8 (shiba, Tensor G3) | **OnePlus 12 (waffle, SM8650)** |
|---|---|---|---|
| SoC upstream | yes (2021) | **no** (only gs101) | **yes (v6.8+)** |
| Board DT | upstream | none (husky out of tree) | out of tree (DaDDevil), not upstream |
| Fedora's kernel | boots it | years away | **no**: `PINCTRL_SM8650`, `INTERCONNECT_QCOM_SM8650` unset (one config request away) |
| Display | simplefb → our panel kmod | Omarchy DECON/DSIM | simplefb at 0xd5100000 → out-of-tree panel driver, Iris7 bypass |
| GPU | A610, our DT fixes | panthor (Mali) | A750 upstream + Turnip |
| Wi‑Fi | ath10k, works | BCM4398, **no driver** | ath12k upstream (+0x1107 board fallback) |
| Audio | blocked | AoC, nothing upstream | WCD9395 upstream + TFA9874 out of tree |
| Modem | works (our tools) | Exynos 5300, no | mpss/IPA upstream; Ace 5 does SMS + data |
| Recovery | EDL + MSM tool (ours, tested) | fastboot only, BootROM risky | fastboot + **OPLUS-locked EDL** (leaked loaders, bkerler/edl PR #829) |
| Rollback risk | low | ARB May 2025 | **ARB fuse 1 since 16.0.3.500**; downgrade = 9008 brick |

**Effort estimate (guess, one experienced person, evenings):**
- Phase 0–1 (desk prep, unlock, recon, EDL kit): 1–3 weeks.
- Phase 2 (first light: DaDDevil kernel + our DTB via uniLoader,
  `fastboot boot`, USB ssh, framebuffer): **1–3 weeks**.
- Phase 3 (Fedora + Plasma Mobile, panel + touch, installed on slot b):
  +1–2 months.
- GPU, Wi‑Fi/BT, battery: weeks each (siblings work). Audio, modem,
  sensors: 1–3 months each. Cameras: open-ended.
  Overall: clearly **less than the Pixel 8**, somewhat more than the N100
  (own kernel package; board not upstream).

**Top blockers**
1. **Unforgiving recovery + anti-rollback**: hardware ARB 1 since
   16.0.3.500; any older firmware → EDL-only brick; EDL needs leaked
   OPLUS-signed loaders + VIP handshake (no official tool), and a future
   ARB bump may revoke them. A OnePlus Pad 2 porter bricked a unit via ARB.
2. **Kernel not consumable from Fedora**: Fedora lacks SM8650
   pinctrl/interconnect; panel, touch, haptics, TFA amps, battmgr changes
   are out of tree in one person's branch (DTS without a licence line) →
   we need `kernels/qcom-sm8650/` and should help upstream the board.
3. **Unlock-policy drift**: ColorOS 16 "Deep Testing" restrictions in China
   and talk of OxygenOS 17 becoming ColorOS 17 globally; plus OxygenOS
   15.0.0.863 broke fastboot. Buy a global unit, unlock early on OxygenOS 16.

**Recommended first milestone:** *"RAM first light via uniLoader"*: with
stock OxygenOS (≥ 16.0.3.500, ARB 1) untouched, `fastboot boot` a boot
image containing uniLoader (board `oneplus-waffle`) + a kernel built from
DaDDevil's `waffle-voice` + our trimmed DT (simplefb at 0xd5100000,
ramoops at 0x85000000, UFS, USB gadget; no remoteprocs) + our debug
initramfs; reach `ssh root@172.16.42.1`, then back up `persist`, `ocdt`,
`modemst1/2`, `fsg`, `fsc` over USB. Before that, prove the RAM-boot loop
with the stock `boot.img` via `fastboot boot`. Nothing is written to the
phone except the unlock.

## Key facts at a glance
| | |
|---|---|
| SoC | SM8650, msm-id 557 (revs 0x10000/0x20000), 2× A520 + 5× A720 + 1× X4, Adreno 750 |
| Variants | CPH2581 (EU), CPH2583 (NA), CPH2573 (IN) = project 22877; PJD110 (CN) = 22825; 12/16/24 GB, 256 GB–1 TB UFS 4.0 |
| Display | BOE AA545, 1440×3168 DSC command mode, via Pixelworks Iris7 (bypass); splash FB 0xd5100000 |
| Boot | XBL → UEFI → ABL; header v4: boot 192M / init_boot 8M / vendor_boot 192M (DTBs) / dtbo 24M / recovery 100M, A/B; super 16 GiB |
| DT ids | `qcom,msm-id <557 …>`, `qcom,board-id <8 0>`, `oplus,project-id <22877|22825>` |
| fastboot | product `pineapple` (guess); keys Vol Up + Vol Down + Power |
| EDL | off + Vol Up + Vol Down + USB → 05c6:9008; OPLUS VIP loader needed |
| ARB | 1 since 16.0.3.500 (all regions); never flash older firmware |
| Downstream kernel | OnePlusOSS `oneplus/sm8650_{u,v,b}_*_oneplus12`, Linux 6.1 GKI |
| Mainline port | DaDDevil/linux `waffle-voice` @ `9359fc74`; uniLoader board `oneplus-waffle` |
