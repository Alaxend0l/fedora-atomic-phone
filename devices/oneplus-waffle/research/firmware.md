<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12 firmware: what mainline needs and where it lives

Desk research, 2026-11-20. File lists come from LineageOS's extraction lists
(LW/LC `proprietary-files*.txt`, which mirror the stock OxygenOS vendor/odm
images) and linux-firmware `a1ebb5a` (2026-11-20, clone
`fap-build/research/oneplus12/linux-firmware`). Partition contents not
listed by those files are marked **(guess)**. As with the N100: **never
commit or redistribute** any of these; tools extract them on the user's
phone (LICENSING.md "Not covered").

## Signing: why linux-firmware's SM8650 files mostly don't help
Retail SM8650 phones run Qualcomm secure boot with **OEM-signed** remoteproc
and zap images. linux-firmware's `qcom/sm8650/` contains only
`gen70900_zap.mbn` (QRD/HDK-signed) and ALSA topology files
(`SM8650-{HDK,MTP,QRD}-tplg.bin`, `ayaneo/ps2/SM8650-APS2-tplg.bin`). There
are **no adsp/cdsp/modem images** for SM8650 there at all. Everything that
runs on a Qualcomm-signed core must come from the phone. Unsigned, generic
files do work from linux-firmware: GPU SQE/GMU microcode, ath12k Wi‑Fi
(the WCN7850 has its own secure boot, not the SoC's), BT.

## Per function
| Function | Mainline consumer | Files needed | Source on the OnePlus 12 | linux-firmware? |
|---|---|---|---|---|
| GPU (A750) | drm/msm a7xx (`a7xx_catalog.c:419-432`) | `qcom/gen70900_sqe.fw`, `qcom/gmu_gen70900.bin` (+ `gen70900_aqe.fw`) | also in `/vendor/firmware/` (LW list) | **yes** (generic) |
| GPU zap shader | drm/msm, DT `firmware-name` | `gen70900_zap.mbn` (OnePlus-signed) | `/vendor/firmware/gen70900_zap.mbn` (LC list) | QRD-signed copy only: **won't load on retail** (guess, as on every retail QC phone; N100 needed the vendor zap too) |
| ADSP (audio, sensors, **charger/battery via pmic_glink**) | `qcom_q6v5_pas` `qcom,sm8650-adsp-pas` | `adsp.mbn` (+ `adsp_dtb.mbn`) | `modem` partition (vfat, mounted at `/vendor/firmware_mnt`, LC fstab) under `image/` **(guess for exact names; SM8550/8650 use `adsp.mbn` + `adsp_dtb.mbn`)** | no |
| CDSP (compute) | `qcom,sm8650-cdsp-pas` | `cdsp.mbn` + `cdsp_dtb.mbn` | `modem` partition `image/` (guess) | no |
| Modem | `qcom,sm8650-mpss-pas` | `modem.mbn` + `modem_dtb.mbn`, plus EFS via **rmtfs** (`modemst1/2`, `fsg`) and `tqftpserv` serving `/vendor/firmware_mnt` style files, `pd-mapper` | `modem` partition | no |
| IPA (modem data path) | `ipa` driver | `ipa_fws.mbn` | `modem` or `/vendor/firmware` (guess) | no |
| Wi‑Fi (WCN7850 "kiwi") | ath12k (PCI) | `ath12k/WCN7850/hw2.0/{amss.bin,m3.bin,board-2.bin}` | stock: qcacld blobs under `image/kiwi` in the modem partition + `/vendor/firmware/wlan/qca_cld/kiwi_v2` (`pineapple.dtsi:32-35`) | **yes** (`amss.bin`, `m3.bin`, `board-2.bin`). Board data: board-2.bin is matched by PCI id + `qmi-chip-id/board-id` + optional DT `qcom,calibration-variant`; OnePlus's `bdwlan*.elf` would need converting with ath12k-bdencoder if no generic entry fits (guess, as with the N100's ath10k) |
| Bluetooth (WCN7850) | `hci_qca` (`qcom,wcn7850-bt`) | `qca/hmtbtfw20.tlv`, `qca/hmtnv20.bin` (or board-specific `hmtnv20.bXXX`) | `bluetooth` partition (vfat, A/B) **(guess for names)** | **yes** |
| Video (Iris, VPU 3.x) | `qcom-iris` (`iris_platform_sm8650.h`) | `qcom/vpu/vpu33_p4.mbn` style (signed) | `/vendor/firmware/vpu33_4v.mbn` (+ `_unsigned`) (LW list) | upstream ships QRD-signed only (guess); use the phone's |
| Camera ICP / EVA | (not in mainline CAMSS) | `CAMERA_ICP.mbn`, `evass*.mdt` | `/vendor/firmware/` | n/a |
| Audio topology | ASoC `qcom,sm8650-sndcard` (sc8280xp.c) + AudioReach | `qcom/sm8650/<BOARD>-tplg.bin` (to write for waffle: TFA98xx on MI2S, WCD939x) | none (Android uses ACDB/AGM) | QRD/HDK/APS2 only; **we'd author our own** |
| Speaker amps | tfa98xx (not upstream for 9874) | `tfa98xx.cnt` (container with speaker calibration) | `/odm/firmware/tfa98xx.cnt`; also ADSP modules `libtfadsp_sb4_0_{rx,tx}.so` (speaker protection on the ADSP) | no |
| Touch | (no upstream driver) | `FW_S3910_{BOE,SAMSUNG,TIANMA}{,_HBP}{,_FAE}.img` (panel-vendor specific), `LIMIT_*` | `/odm/firmware/tp/22825/` (shared by both projects) | no. Note: the three panel vendors in this list (BOE, Samsung, Tianma) hint at the second-source panel's maker |
| Display coprocessor | (none) | `iris7.fw`, `iris7_ccf{1..4}.fw`, `pxlw_i7_panel_AA545_P_3_A0005_dsc_cmd.fw` | `/odm/firmware/` | no. Only needed if we drive Iris7 instead of bypassing it |
| Charging | ADSP firmware + `qcom_battmgr` | config tables `/odm/firmware/fastchg/22877/*.txt` (userspace policy, not needed by Linux) | `/odm/firmware/fastchg/` | n/a |
| Laser AF | (none) | `tof8801_firmware.bin` (ams TMF8801 ToF) | `/vendor/firmware/` | no |
| Sensors | SSC on the ADSP, userspace `hexagonrpcd` + `libssc` | sensor registry/config (`/vendor/etc/sensors/`, guess) and ADSP skel libs (`/vendor/lib/rfsa/adsp/`) | vendor/odm images | no |

## Extraction plan (proposal, for the device folder)
Mirror the N100 approach (firmware read from the phone's own partitions at
run time or once at install):
1. From a RAM-booted Linux (or from an OTA payload on the Mac):
   `modem_a` (vfat) → `image/{adsp,cdsp,modem}*.mbn`, `*_dtb.mbn`, `ipa_fws.*`,
   `image/kiwi/*` (reference only); `bluetooth_a` (vfat) → BT nvm (reference);
   `vendor_a`/`odm_a` (erofs, inside `super`) → `firmware/gen70900_zap.mbn`,
   `vpu33_4v.mbn`, `tfa98xx.cnt`, `tp/22825/FW_S3910_BOE.img`.
   erofs needs `erofs-utils`/kernel `EROFS_FS` (Fedora has it, guess) and
   `super` needs `lpunpack` or dm-linear tables.
2. Install into `/usr/lib/firmware/updates/qcom/sm8650/OnePlus/waffle/`
   (naming convention used by upstream DTs: `qcom/<soc>/<vendor>/<codename>/`),
   referenced from our board DT's `firmware-name`.
3. Desk alternative (no phone needed): OxygenOS full OTA → `payload-dumper-go`
   → `modem.img`, `bluetooth.img`, `vendor.img`, `odm.img` → mount/extract on
   the Mac with `7z`/`fsck.erofs --extract`. Lets us prepare firmware before the
   first boot. Firmware version must match the bootloader's (same OTA as
   installed), especially modem/ADSP (guess, prudent).

## Licensing note
Qualcomm/OnePlus firmware is proprietary. linux-firmware's WCN7850 and A750
microcode are redistributable (linux-firmware WHENCE), so they ship in Fedora's
`linux-firmware`/`qcom-firmware`/`atheros-firmware` packages already
(package split: guess, check `rpm -qf` on Fedora).
