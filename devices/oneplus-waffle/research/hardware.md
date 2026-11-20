<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12 ("waffle") hardware inventory

Desk research, 2026-11-20. No OnePlus 12 was in hand. The main source is
OnePlus's own downstream device tree (GPL, on GitHub), so buses, addresses,
GPIOs and supplies below are facts about the shipping board DT. Part numbers
known only from press or blob names are marked **(press)** or **(blob)**,
inferences **(guess)**.

## Sources
| Tag | Source |
|---|---|
| OPDT | <https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8650>, branch `oneplus/sm8650_v_15.0.0_oneplus12` @ `38d50357` (2025-09-25). `DT/` = `kernel_platform/qcom/proprietary/devicetree/`, `VQ/` = `vendor/qcom/proprietary/` |
| LW | <https://github.com/LineageOS/android_device_oneplus_waffle> `lineage-24.0` @ `0b070287` |
| LC | <https://github.com/LineageOS/android_device_oneplus_sm8650-common> `lineage-24.0` @ `03f70bdd` |
| WIKI | <https://github.com/LineageOS/lineage_wiki> @ `14a36a07`, `_data/devices/waffle.yml` (source of wiki.lineageos.org/devices/waffle) |
| ML | Linux v7.4-rc3 (`d0f871bf`), sparse clone `fap-build/research/pixel8/linux` |

Local clones (not committed): `fap-build/research/oneplus12/{oplus-dt,lineage-waffle,lineage-sm8650-common}`.
Raw notes with every file:line: `fap-build/research/oneplus12/notes/downstream-and-hw.md`.

## Identity and variants
- Codename **waffle**, Qualcomm platform **pineapple** (SM8650)
  (WIKI waffle.yml:11; LW `lineage_waffle.mk:17`; LC `BoardConfigCommon.mk:56`).
- Two OPLUS hardware "projects", i.e. two board DTs (`DT/oplus/waffle-{22825,22877}-pineapple-overlay.dts`):

| Project | Market | Models | `ro.product` device | Notes |
|---|---|---|---|---|
| 22825 | China | **PJD110** (ColorOS) | OP5929L1 | LW `properties/22825/build.default.prop:2-5` |
| 22877 | global, region chosen at runtime by `oplus_region=` on the kernel cmdline (27 IN, 68 EU, 151 CN, 161 NA, 167 ROW; LC `init/init_oplus.cpp:29-35`) | **CPH2573** (India), **CPH2581** (EU, "CPH2581EEA"), **CPH2583** (North America) | OP595DL1 | adds USB PD PPS (`oplus-chg-22877-pps.dtsi`); LW `properties/22877/build.{IN,EU,NA}.prop` |

- The two board DTs differ only in small things (haptics vmax 2400 vs 1720 mV,
  PPS charging). Hardware revisions in the DT: EVB, EVT1, EVT2/DVT1/DVT2/PVT1
  (production = the overlay without suffix).
- RAM / storage: **12 / 16 / 24 GB LPDDR5X; 256 / 512 GB / 1 TB UFS 4.0**
  (WIKI waffle.yml:30,36). Which SKU sells where is not in these sources;
  24 GB / 1 TB is China-only **(press, unverified)**.
- Region-relevant: there is **no US carrier variant** with a locked
  bootloader known to us; CPH2583 is sold unlocked (see boot-and-flashing.md).
- `android-info`: `require board=pineapple|OP5929L1|OP595DL1` (LW `board-info.txt:1`),
  `TARGET_BOOTLOADER_BOARD_NAME := pineapple` → `fastboot getvar product`
  most likely says **pineapple** (guess; check on hardware).

## Summary table
| Block | Part | Bus / where (downstream) | Downstream driver | Mainline (v7.4-rc3) |
|---|---|---|---|---|
| SoC | Snapdragon 8 Gen 3, **SM8650** "pineapple", msm-id 557 (577 also listed) | `DT/qcom/pineapple.dtsi`, `pineapple-mtp.dtsi:6-9` (board-id `<8 0>` = MTP) | | `sm8650.dtsi` (8675 lines), boards QRD, MTP, HDK, AYANEO Pocket S2, Valve Deckard. **No OnePlus 12** |
| CPU | 2× A520, 5× A720 (3 + 2), 1× X4 3.3 GHz | | | generic; cpufreq-hw, PSCI cpuidle upstream |
| GPU | **Adreno 750** (chip id 0x43051401 "C520v2") | | kgsl | **drm/msm supports A750** (`a7xx_catalog.c:419-432`: `gen70900_sqe.fw`, `gmu_gen70900.bin`, `gen70900_zap.mbn`) |
| RAM | 12/16/24 GB LPDDR5X | | | ABL fills `/memory` |
| Storage | UFS 4.0 at `1d84000` (fstab `1d84000.ufshc`) | | ufshcd-qcom | upstream (`ufs_mem_hc`) |
| PMICs | **PMK8550, PM8550, PM8550B, PM8550VE, PM8550VS ×4 (c/d/e/g), PM8010, PMR735D** | SPMI; `DT/qcom/pineapple-pmic-overlay.dtsi:3-9` | | all have `.dtsi` upstream and are used by the QRD DT (`pm8550*.dtsi`, `pmk8550.dtsi`, `pm8010.dtsi`; PMR735D: `pmr735d_a.dtsi` exists for SM8550/8650 boards) |
| Display | **BOE "AA545 P_3 A0005"**, 6.82" LTPO AMOLED, **1440×3168**, 60/90/120 Hz, **DSI command mode, DSC v1.1** (10 bpc, 8 bpp, 2 encoders, slice 720×22), 4 lanes on DSI0 | reset GPIO 133, TE GPIO 86, vout GPIO 91, vddio 1.8 V, vci 3.2 V (L13B), DCS backlight max 4094; `VQ/display-devicetree/oplus/panel/dsi-panel-AC545-P-3-A0005*.dtsi` | msm display techpack | DPU/DSI/DSC for SM8650 upstream (`dpu_10_0_sm8650.h`). **No panel driver upstream**; out of tree: `panel-boe-aa545.c` in DaDDevil/linux `waffle-voice` (mainline-status.md). Second-source panel "AA545 P_1 A0006" (vendor unknown) also listed |
| Display coprocessor | **Pixelworks Iris7** (X7) between SoC and panel | I2C/I3C on `qupv3_hub_i2c4` @0x22/0x26, reset GPIO 97, wakeup PM8550VE GPIO4, vdd PM8550VE GPIO7, abyp-ready GPIO 174, uses DSI1 as a second path; `pxlw-iris7-pineapple-common.dtsi:113-140` | proprietary `pxlw` in display techpack | **nothing upstream**. Needs to stay in analog bypass ("abyp") so DSI0 reaches the panel. Evidence it does: DaDDevil's mainline panel driver never touches Iris7 and claims 60/90/120 Hz working; ios-waffle draws on the GOP framebuffer |
| Touch | **Synaptics S3910** (TouchComm/TCM), 17×38 | SPI `qupv3_se4_spi` 19 MHz, IRQ GPIO 162, reset 161, enable GPIO 108, vdd L4B; `tp/waffle-oplus-tp-22825.dtsi:306-331` (node `synaptics,tcm-spi-hbp`) | oplus `synaptics_hbp` (syna_tcm2, TouchComm v1/v2) | **no TCM driver upstream** (rmi4 is a different protocol); needs a port of the GPL vendor driver. The IC defaults to on-chip processing (LBP), so no userspace frame daemon is needed (see downstream-kernel.md) |
| Alert slider | 2× MagnaChip **MXM1120** hall sensors | `qupv3_hub_i2c8` @0x0D (IRQ GPIO 112) and @0x0C (IRQ GPIO 99), vdd L2B 3.0 V, vio L1B; same file :8-57 | oplus `tri_state_key` | none (not in DaDDevil's DTS either); small hall-sensor input driver needed (guess) |
| Fingerprint | under-display, vendor not named in DT (Goodix optical **(press)**) | `oplus,fp_spi`, IRQ GPIO 92, reset GPIO 89, L14B; `oplus_fp/oplus_fp_22825.dtsi:3-23` | TEE-backed | no (TEE/TA-bound; ignore) |
| NFC | **NXP SN220** (blob: `sn220tu_fw_01_01_45`) | DT node **not found** in OPDT (guess: I2C + `nxp/opensource` driver) | nxp nfc | `nxp-nci` knows PN547/553/557; SN220 not listed. Low priority |
| IR blaster | `oplus,kookong_ir_spi` | `qupv3_se11_spi` 5 MHz, vdd L9B 3.1 V; `sensor/waffle-sensor-22825.dtsi:41-84` | oplus | none (`ir-spi` upstream might fit, guess) |
| Haptics | **PM8550B PMIC haptics**, LRA ~130 Hz (lra-period 7692 µs) | `&pm8550b_haptics`, `oplus_misc/oplus-misc-22825.dtsi:1-11` | qcom-hv-haptics | binding `qcom,spmi-haptics.yaml` exists (pmih0108 only); **no driver in v7.4-rc3** |
| Sensors | accel/gyro/mag/ALS/prox in the **ADSP sensor hub (SSC)** | `waffle-sensor-22825.dtsi:13-40` | SSC via FastRPC | not in Linux; needs hexagonrpcd + libssc (as on sdm845 phones) |
| Charging | ADSP-managed (`battery_charger` over glink, "oplus,hal_sm8350"), **dual-cell 5400 mAh** (`oplus,batt_num = <2>`), ADSP **voocphy**, 100 W SUPERVOOC, 50 W wireless, UFCS; PPS on 22877 | `oplus_chg/oplus-chg-22825.dtsi:16-20,367-397,536-564,917` | oplus_chg v2 | `pmic_glink` + `qcom_battmgr` upstream (SM8650 QRD uses them) **but** OnePlus's ADSP firmware speaks oplus extensions; whether stock battmgr messages work is unknown |
| Charge pump | **HL7227** (Halo) | `qupv3_hub_i2c3` @0x51, en PM8550VE GPIO8, IRQ GPIO 181 | oplus | none (ADSP may drive it, guess) |
| Wireless RX | **IDT/Renesas P9415** | `qupv3_hub_i2c3` @0x3b, IRQ GPIO 182 | oplus | none |
| Fuel gauge | PM8550B **QBG**, read by ADSP | `oplus-chg-22825.dtsi:347` | ADSP | via battmgr only |
| USB | dwc3 @`a600000`, super-speed, PM8550B eUSB2 repeater (tuned params), `wcd_usbss` (WCD939x USB-SS switch), DP alt-mode | `oplus-misc-22825.dtsi:19-34` | | all upstream (`phy-snps-eusb2`, `phy-qcom-eusb2-repeater`, `wcd939x-usbss`, pmic_glink altmode) |
| Audio codec | **WCD939x** (WCD9395 likely) on SoundWire, USB-C headset | `VQ/audio-devicetree/oplus/waffle-22825-audio-pineapple-overlay.dtsi:127-150` | audio-kernel | `wcd939x`, `wcd939x-sdw` upstream; SM8650 machine driver = `sc8280xp.c` (`qcom,sm8650-sndcard`) |
| Speaker amps | **2× NXP TFA98xx** (supply named `tfa9874_vdd` → TFA9874 family, guess), **not WSA** (`qcom,wsa-max-devs = <0>`) | `qupv3_hub_i2c7` @0x34 (reset GPIO 173) and @0x35 (reset GPIO 178), L15B, **MI2S** (sec, i2s1); same file :70,87-125 | tfa98xx | upstream `tfa989x` covers TFA9890/95/97 only; TFA9874 needs work. Also needs LPASS MI2S path, which the upstream SM8650 card doesn't use |
| Cameras | main **Sony LYT-808** 50 MP (CCI0 m1, CSIPHY1, AK7316 AF); ultrawide **IMX581** 48 MP (CCI0 m0, CSIPHY2); 3× periscope **OV64B40** 64 MP (CCI1, CSIPHY0, SEM1217S OIS); front **IMX615** 32 MP (QUP `qupv3_se9_i2c` @0x20, CSIPHY4) | `VQ/camera-devicetree/oplus/waffle_camera_overlay_common.dtsi:139-530`; names from LW `proprietary-files.txt:571-575` (blob) | Spectra camera techpack | CAMSS has SM8650 CSIPHY/CSID data (`camss.c:3321+`); no sensor drivers for LYT-808/IMX581/OV64B40/IMX615 upstream. Far future |
| Wi‑Fi / BT | Qualcomm **"kiwi" = WCN7850 / FastConnect 7800**, Wi‑Fi 7, BT 5.4, on **PCIe0** | `DT/qcom/pineapple-pcie.dtsi:5`, firmware path `image/kiwi` (`pineapple.dtsi:32-35`) | qcacld-3.0 `kiwi_v2`, cnss2 | **ath12k + `qcom,wcn7850-pmu` + `qcom,wcn7850-bt` upstream** (used by QRD/HDK/AYANEO DTs); firmware `ath12k/WCN7850/hw2.0` + `qca/hmtbtfw20.tlv` in linux-firmware. Needs device-specific `board-2.bin` entry or the phone's `bdwlan` (see firmware.md) |
| Modem | X75-class in SM8650 (MPSS), 5G | `modem` partition | | `qcom,sm8650-mpss-pas` upstream; needs the phone's signed `modem.mbn`, rmtfs, tqftpserv, pd-mapper |
| Misc | RF cable detect GPIO 98; eSIM detect PM8550 GPIO11 / enable PM8550VS_G GPIO6; SIM2 detect PM8550VS_C GPIO5 | `waffle-22825-pineapple-overlay.dts:20-120` | | |

## What this means for a port (short)
- **Good**: the SoC, PMICs, UFS, USB (eUSB2), GPU, Wi‑Fi/BT chip, WCD939x
  codec, remoteprocs are all used by upstream SM8650 boards; the QRD and
  AYANEO Pocket S2 DTs are close templates.
- **New drivers needed for a usable phone** (not upstream): BOE AA545 panel,
  Synaptics S3910 touch, PM8550B haptics, TFA9874 amps (all four exist out of
  tree in DaDDevil/linux `waffle-voice`), alert-slider hall sensors (none yet).
- **Remaining unknowns**: Iris7 (works in bypass per the out-of-tree port);
  OnePlus's ADSP charger messages (DaDDevil extends `qcom_battmgr`); sensors
  only via SSC (works on the OnePlus Ace 5 port).
- Compared with the N100: every downstream source is newer and better
  structured, but the panel/touch/amp chips are less common upstream.
