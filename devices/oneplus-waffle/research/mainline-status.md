<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Mainline status: SM8650 and the OnePlus 12

As of 2026-11-20. Checked locally in Linux v7.4-rc3 (`d0f871bf`, sparse clone
`fap-build/research/pixel8/linux`), linux-next next-20261120 (`909ef7a9a`),
U-Boot master `c1958b5f` (`fap-build/u-boot`), linux-firmware `a1ebb5a`, and
Fedora's kernel config (`kernel-aarch64-fedora.config` from
src.fedoraproject.org, rawhide/f45/f44, fetched 2026-11-20 into
`fap-build/research/oneplus12/fedora-config/`). First-release versions come
from a research subagent's GitHub compare against tags (commit ids given).
Raw notes: `fap-build/research/oneplus12/notes/community-mainline.md`.

## TL;DR
- **SM8650 is well supported upstream** (Linaro, Qualcomm; since v6.8):
  everything a phone needs at the SoC level is there, including GPU (A750),
  Wi‑Fi (WCN7850/ath12k), remoteprocs, audio framework, Iris video, CAMSS.
  Upstream boards: QRD, MTP, HDK, AYANEO Pocket S2 (v7.1), Valve Deckard
  (v7.4-rc1).
- **No OnePlus 12 DT upstream or posted** (not in v7.4-rc3, next-20261120,
  lkml searches).
- **But an active out-of-tree port exists**: **DaDDevil/linux, branch
  `waffle-voice`** (51 commits on v7.4-rc3, 2026-08-23 … 2026-10-25, pushed
  2026-11-20) with `sm8650-oneplus-waffle.dts` and new drivers for the
  panel, touch, haptics, cameras, plus OnePlus battmgr/ath12k fixes. It
  claims display at 60/90/120 Hz and voice calls. **This is our starting
  point**; it is to the OnePlus 12 what Omarchy's zuma tree is to the
  Pixel 8, but on a SoC that is already upstream.
- **Fedora's kernel can't boot SM8650 yet**: `CONFIG_PINCTRL_SM8650` and
  `CONFIG_INTERCONNECT_QCOM_SM8650` are **not set** in rawhide, f45 and f44
  (SM8550 neither); clocks (`SM_GCC_8650` etc.), DRM_MSM, ATH12K,
  WCD939X, WSA884X, IRIS, Q6V5_PAS, PMIC_GLINK are `=m`. Needs a Fedora
  config change (upstreamable request) or our own kernel build.

## 1. SoC support upstream
DT: `arch/arm64/boot/dts/qcom/sm8650.dtsi` (8675 lines in v7.4-rc3) + PMIC
dtsi (`pm8550.dtsi`, `pm8550b.dtsi`, `pm8550ve.dtsi`, `pm8550vs.dtsi`,
`pmk8550.dtsi`, `pm8010.dtsi`, `pmr735d_a.dtsi`): exactly the OnePlus 12's
PMIC set (hardware.md). CPUs 2× A520, 5× A720, 1× X4 (`sm8650.dtsi:74-374`).

| Area | Upstream | Since | Ref |
|---|---|---|---|
| SoC base DT, QRD, MTP; GCC, TCSR, pinctrl (TLMM), interconnect (RPMh), RPMh regulators, UFS, USB (SNPS eUSB2 + PM8550B repeater + QMP combo) | yes | v6.8 | `drivers/clk/qcom/gcc-sm8650.c`, `drivers/interconnect/qcom/sm8650.c` |
| HDK board | yes | v6.10 | 01061441029e |
| **Adreno 750** (drm/msm a7xx) | yes | driver v6.9 (d2bcca0ccccf), DT v6.10 (db33633b05c0), IFPC v6.18 (6341516bc25c) | `a7xx_catalog.c:419-432` chip id 0x43051401, `gen70900_sqe.fw`, `gmu_gen70900.bin`, zap `gen70900_zap.mbn` |
| Display DPU 10.0 / DSI / DSC / DP | yes | v6.8+ | `dpu_10_0_sm8650.h`; DP audio DAI v7.1 (557226acef41) |
| **Remoteproc PAS** (adsp, cdsp, mpss) | yes | v6.9 (a3dd84d308c5) | `qcom_q6v5_pas.c:2072-2073` (`qcom,sm8650-{adsp,cdsp}-pas`), mpss data :1857 |
| PCIe (+ WCN7850 bridge node) | yes | v6.8–v6.10 (cf3e010d7f4c) | `pcie-qcom` |
| **Wi‑Fi WCN7850** (ath12k PCI) + pwrseq `qcom,wcn7850-pmu` + BT `qcom,wcn7850-bt` | yes | ath12k v6.3; SM8650 boards v6.10 | used by QRD/HDK/AYANEO DTs |
| Sound card (`qcom,sm8650-sndcard` in `sc8280xp.c`), WCD939x codec + `wcd939x-usbss`, WSA884x, SoundWire, LPASS macros | yes | v6.8 (2f2998895cc2) | |
| **Iris video** (VPU 3.3) | yes | binding v6.16 (f0a0a2388f44), DT v6.17 (56cf5ad39a55) | `iris_platform_vpu3x.c` (sm8650 data), default fw `qcom/vpu/vpu33_p4.mbn` |
| CAMSS (CSIPHY 2.2.0, CSID, VFE) + camcc | yes | driver v6.19 (6a0b9d3f111e), DT v7.0 (e8560ac937d9) | `camss.c:3321+` |
| pmic_glink + `qcom_battmgr` + UCSI + altmode | yes | (SM8550 era) | QRD uses `qcom,sm8650-pmic-glink` |
| LLCC, PD mapper, UBWC config | yes | | `llcc-qcom.c:5855`, `qcom_pd_mapper.c:664`, `ubwc_config.c:177` |
| Thermal (3× tsens, ~44 zones), cpufreq EPSS, PSCI OSI idle | yes | | `sm8650.dtsi` |
| IPA | no `qcom,sm8650-ipa` compatible (guess: v5.5 data reused; the Ace 5 port reports mobile data working) | | |
| PMIC haptics | binding `qcom,spmi-haptics.yaml` (pmih0108 only), **no driver** in v7.4-rc3 | | |
| bwmon | no sm8650 compatible found | | |

## 2. OnePlus 12 peripherals vs upstream drivers
| Part | Upstream? | In DaDDevil's tree |
|---|---|---|
| BOE AA545 panel (DSC cmd mode) | no | `drivers/gpu/drm/panel/panel-boe-aa545.c` (GPL-2.0-only, 681 lines) + binding `boe,aa545-p-3-a0005.yaml`; 60/90/120 Hz claimed tested |
| Pixelworks Iris7 | no | **not touched** by the panel driver or DT → the display works with Iris7 left as the bootloader leaves it (bypass) [inference from the code; matches ios-waffle's GOP framebuffer working] |
| Synaptics S3910 TouchComm (SPI) | no | `drivers/input/touchscreen/synaptics-s3910.c` (`CONFIG_TOUCHSCREEN_SYNAPTICS_S3910`, "from oboev") |
| PM8550B haptics | no driver | `drivers/input/misc/qcom-spmi-haptics.c` |
| TFA9874 amps | no (`tfa989x` covers 9890/95/97) | `nxp,tfa98xx` nodes on `i2c_hub_7`, secondary MI2S; AudioReach/q6apm voice-call patches |
| WCD9395, WCD USB-SS, NB7VPQ904M redriver | yes | used |
| WCN7850 with OnePlus subsystem id 0x1107 | partly | ath12k fallback 0x1107 → 0x3378 for board data, QDSS config fallback, MHI fixes |
| charger/battery (ADSP + OnePlus messages) | battmgr yes | `qcom_battmgr` +1329 lines for OnePlus charge events/OTG; `oneplus,waffle-pmic-glink` compatible |
| Cameras IMX581, LYT-808, OV64B40, IMX615, AK7316/AK7377/SEM1217S VCM | no | new sensor drivers (~8.6k lines); "full resolution and AF/OIS unvalidated" |
| IR blaster | `ir-spi` yes | `ir-spi-led` on SPI11 |
| Alert slider (2× MXM1120) | no | not found in the DTS [to check] |
| Fingerprint, NFC (SN220) | no | not in the DTS |

### DaDDevil/linux `waffle-voice` details
- <https://github.com/DaDDevil/linux/tree/waffle-voice>, HEAD `9359fc74`
  ("usb: typec: mux: wcd939x: preserve USB2 in four-lane DP modes", author
  date 2026-10-25). Sparse clone: `fap-build/research/oneplus12/daddevil-linux/`.
- `arch/arm64/boot/dts/qcom/sm8650-oneplus-waffle.dts` (1418 non-empty
  lines): `compatible = "oneplus,waffle", "qcom,sm8650"`, `model = "OnePlus 12"`.
  Hard-coded `/memory` (13 ranges incl. the splash region at 0xd5100000;
  top bank 0xa_0000_0000 + 8 GiB, i.e. a 16 GB unit [guess]; a 12/24 GB
  unit needs other ranges or ABL-filled memory), ramoops at 0x85000000
  (0x240000), `chosen/bootargs` with root on an f2fs partition by PARTUUID,
  UART15 console, UART14 BT, PCIe0 Wi‑Fi, pmic-glink USB-C with OTG
  regulators, GPU (zap at the QRD path `qcom/sm8650/gen70900_zap.mbn`),
  Iris (`qcom/sm8650/oneplus/waffle/vpu33_4v.mbn`), ADSP
  (`qcom/sm8650/oneplus/waffle/adsp.mdt` + `adsp_dtb.mdt`), MPSS, IPA;
  **CDSP not enabled**; keys: vol-down = PM8550 GPIO6, vol-up = PON RESIN
  (swapped vs the HDK; ios-waffle confirms).
- Build: `arch/arm64/configs/waffle_defconfig` (has
  `INTERCONNECT_QCOM_SM8650=y`, `DRM_PANEL_BOE_AA545=m`,
  `TOUCHSCREEN_SYNAPTICS_S3910=y`, `INPUT_QCOM_SPMI_HAPTICS=m`); CI in
  <https://github.com/DaDDevil/mainline_kernel_builder> builds
  `Image modules qcom/sm8650-oneplus-waffle.dtb` with LLVM.
- Boot: uniLoader board `oneplus-waffle` (boot-and-flashing.md §4).
- **Licensing caveat**: the DTS has **no SPDX/licence line**; the panel
  driver is GPL-2.0-only. Before we copy the DTS into
  `devices/oneplus-waffle/dts/` (which needs `(GPL-2.0+ OR BSD-3-Clause)` per
  LICENSING.md), ask the author to add a licence (mainline convention:
  BSD-3-Clause like other qcom board DTs), or write our own from the
  OnePlus GPL sources and only use theirs as a reference.
- Not upstreamed, single author, no issue tracker activity found; treat as
  a moving target and pin commits.

## 3. Sibling devices worth reading (all out of tree)
| Device | Repo | Why |
|---|---|---|
| **OnePlus Ace 5 / 13R "giulia"** (SM8650, same OEM) | <https://github.com/DianKuang0120/OnePlus-Ace5-Mainline-Kernel-Patchs> (Linux 7.3.3), oboev/oneplus-giulia | most complete OPLUS SM8650 port: display (HDR), touch, GPU, Wi‑Fi/BT, speakers + mics, charging/PD, **sensors via SSC/libssc**, NFC, SMS/IMS, mobile data; calls' audio and fingerprint don't work. Boots Mu-Silicium UEFI → fdt-merge.efi → systemd-boot |
| **Xiaomi 14 "houji"** (SM8650) | <https://github.com/yoni13/armada-houji> (fork of armada-os/armada, **Fedora bootc**) | stock ABL, header v4 split images on slot b, Plasma, CDSP/FastRPC, s2idle experimental. **Closest to our architecture** |
| OnePlus Pad 2 "caihong" (SM8650) | RubyLegend/opd2403-postmarketos; inferno0230/pmaports `device-oneplus-caihong` | GPU (Vulkan), ADSP+CDSP, Wi‑Fi; README: unit was **"bricked previously by OnePlus ARB bit"** |
| RedMagic 9 Pro (SM8650) | FrontMage/ubuntu-nx769j-build-ci | BootShim + Debian u-boot-qcom + bootefi; Turnip with stock zap/GMU |
| Nubia Z60 Ultra (SM8650) | ycrrongos/SM8650-mainline_linux-cerro | cameras via libcamera, DP 4K60, modem |
| OnePlus 12R "aston" (SM8550) | jiganomegsdfdf/ubuntu-oneplus-aston (EOL) | OPLUS ABL + `fastboot boot` of a mainline boot.img works |
| OnePlus 13 "dodge" (SM8750) | dianqk/nixos-android-devices (has U-Boot for dodge), derekross/omarchy-mobile | newer OPLUS ABL behaviour |

No waffle in the pmaports GitHub mirror (`external-mirrors/pmaports`; its
only SM8650 device is the AYANEO Pocket S2), no Ubuntu Touch / Droidian /
Sailfish / Mobian port, no XDA mainline thread.

## 4. U-Boot
- Upstream U-Boot has SM8650 clocks (`drivers/clk/qcom/clock-sm8650.c`,
  Neil Armstrong, 2024), pinctrl (`pinctrl-sm8650.c`), interconnect
  (`drivers/interconnect/qcom/sm8650.c`); `qcom_defconfig` enables them;
  `configs/qcom_sm8650_defconfig` is for dev boards' `uefi` partition
  (default DT `qcom/sm8650-hdk`, TEXT_BASE 0xa7000000) and
  `board/qualcomm/debug-sm8650.config` adds the GENI debug UART at 0x89c000
  (local clone `c1958b5f`). U-Boot uses Linux's DTs (`dts/upstream`), so
  a waffle U-Boot needs the waffle DTS upstream or carried by us.
- Phones: `doc/board/qualcomm/phones.rst` (`qcom_defconfig qcom-phone.config`,
  `fastboot boot u-boot.img`; DT needs simple-framebuffer and, on newer
  devices, a `cont_splash`-labelled reserved-memory region; U-Boot fastboot
  has no UFS backend). `exit-gunyah.config` exists for Dragonwing boards
  (retail Gunyah likely doesn't allow it [guess]).
- No OnePlus 12 U-Boot found. RedMagic 9 Pro (SM8650) runs Debian's
  `u-boot-qcom` behind a BootShim, so U-Boot on retail SM8650 ABL is
  demonstrated.

## 5. Fedora kernel coverage (aarch64, rawhide = f45 = f44 for these)
| Needed | Fedora |
|---|---|
| `PINCTRL_SM8650` (TLMM) | **not set** |
| `INTERCONNECT_QCOM_SM8650` | **not set** |
| `PINCTRL_SM8650_LPASS_LPI` | not set |
| `SM_GCC_8650`, `SM_GPUCC_8650`, `SM_DISPCC_8650`, `SM_TCSRCC_8650`, `SM_CAMCC_8650` | m |
| `SCSI_UFS_QCOM`, `PHY_QCOM_QMP_UFS`, `USB_DWC3_QCOM`, `PHY_QCOM_SNPS_EUSB2`, `PHY_QCOM_EUSB2_REPEATER`, `PHY_QCOM_QMP_COMBO` | m |
| `QCOM_RPMH`, `QCOM_RPMHPD`, `REGULATOR_QCOM_RPMH`, `ARM_SMMU_QCOM`, `QCOM_SCM`, `SPMI_MSM_PMIC_ARB`, `PCIE_QCOM`, `DRM_MSM_DSI` | y |
| `DRM_MSM`, `ATH12K`, `QCOM_Q6V5_PAS`, `QCOM_PMIC_GLINK`, `BATTERY_QCOM_BATTMGR`, `SND_SOC_SC8280XP`, `SND_SOC_WCD939X_SDW`, `SND_SOC_WSA884X`, `VIDEO_QCOM_IRIS`, `QCOM_LLCC`, `QCOM_PD_MAPPER`, `PSTORE_RAM`, `ARM_QCOM_CPUFREQ_HW`, `QCOM_SPMI_ADC5_GEN3` | m |
| `TYPEC_MUX_WCD939X_USBSS`, `INPUT_AW86927`, `TOUCHSCREEN_GOODIX_BERLIN_*` | not set |

Without TLMM pinctrl nothing on the SoC gets pins and without the
interconnect provider UFS/USB/display can't vote bandwidth, so Fedora's
kernel can't reach UFS on SM8650 today. Options: (a) ask Fedora to enable
the two symbols (+ SM8550 ones; precedent: SM6115 is enabled) — cheap,
slow; (b) `kernels/qcom-sm8650/` with our own build of DaDDevil's tree for
the first milestones (this is needed anyway for the panel/touch drivers).
