# OnePlus Nord N100 (`oneplus-billie2`)

Status: **planned**. Nothing has been flashed.

Hardware facts below come from a running UBports system (Halium, vendor kernel
4.19), collected with `tools/hw-inventory.sh` in the UBports-N100 notes repo
(`log/hw-inventory/20261120-134342/`).

## Hardware
| Part | Chip | Mainline status | Works here? |
|---|---|---|---|
| SoC | Snapdragon 460, SM4250 "bengal" (soc_id 417) | `sm4250.dtsi` / `sm6115.dtsi` upstream | — |
| RAM | 4 GB (3.7 GB usable) | | |
| Storage | UFS, Micron MT064GASAO2U21; microSD | in `sm4250-oneplus-billie2.dts` | — |
| Display | ILI9882N, 720×1600 @ 90 Hz, DSI video | only `simple-framebuffer` (the bootloader's) in the mainline DT; no panel driver known | — |
| Touch | Ilitek on SPI (Novatek NT36525B on some units) | not in mainline DT | — |
| USB | dwc3, USB-C with FSA4480 switch | in mainline DT | — |
| Wi‑Fi/BT | WCNSS/`qca_cld3` on stock; board files `wlan_eu.bin`, `wlan_usa.bin` | ath10k-snoc support for this SoC: to check | — |
| Audio | WCD937x codec on SoundWire; AW87529, AW87359, SIA8109 amps | to check | — |
| Charging | PMI632 + SMB1355, 5058 mAh | to check | — |
| Modem | MPSS.HA.1.0 | via qrtr/rmtfs on mainline, to check | — |
| Other | NXP NFC (nq-nci), Egis fingerprint, SAR sensor | — | — |

The mainline DT (`arch/arm64/boot/dts/qcom/sm4250-oneplus-billie2.dts`) enables
simple-framebuffer, UFS, SD card, USB, PM6125 regulators and **ramoops**
(pstore at 0xcbe00000), which gives crash logs the Halium build lacks.

## Boot chain (planned)
Android bootloader (ABL) → `boot_a`/`boot_b` holds U-Boot (`qcom_defconfig` +
the mainline billie2 DTB, Android boot image header v2) → U-Boot's EFI →
GRUB from the ESP → Fedora kernel + DTB. See `boot/uboot-android/`; `android-bootimg` is the fallback.

## Partitions
A/B device with Android dynamic partitions: `system`/`vendor` are logical
volumes inside `super` (10 GiB).

| Partition | Size | Plan |
|---|---|---|
| `boot_a`, `boot_b` | 96 MiB each | U-Boot image |
| `dtbo_a`, `dtbo_b` | 24 MiB each | erased (ABL would otherwise apply overlays) |
| `userdata` | 44.8 GiB | root filesystem |
| ESP | 64–256 MiB | **open**, see below |

**Open: where the ESP goes.** Candidates:
1. `recovery_b` (96 MiB): unused slot copy. ESP would have to shrink to ~90 MiB.
2. `super` (10 GiB): plenty of room, but holds `vendor`, which contains
   firmware we need (see below). Only after that firmware is extracted.
3. `op1` (300 MiB): OnePlus-specific, contents unknown. Not until identified.
4. An ESP inside `userdata`, with U-Boot reading a GPT there. Avoids touching
   any other Android partition, but needs U-Boot to handle a nested table.

## Firmware
Needed blobs are spread over `modem_a` (vfat: modem, adsp, cdsp, wlan,
`bdwlan.*`), `dsp_a`, `bt_firmware`, and `vendor/firmware` inside `super`.
Plan: extract at first boot from the phone's own partitions (as postmarketOS
and Pocketblue's `droid-juicer` do), never redistribute. `vendor` must be
copied off **before** anything overwrites `super`.

## Recovery
- EDL works (05c6:9008, Vol Up + Vol Down while plugging in), tested 2026-11-20.
- MSM packages verified: EU `bengal_14_E.05_201031` (OxygenOS 10.5.2, matches
  the current vendor) and Metro `bengalm_14_O.04_201221` (10.5.8, factory).
- Identity partitions (modemst1/2, fsg, fsc, persist) backed up.
- **Never write** `modemst1`, `modemst2`, `fsg`, `fsc`, `persist`.
  `tools/flash.sh` refuses to.

## Notes
- This unit is a BE2015 (Metro by T-Mobile) converted to EU firmware.
- The UBports kernel and the stock vendor modules disagree on the GFP flag
  layout (that's why UBports has no sound card). Irrelevant for a mainline
  kernel, but a reminder not to mix vendor modules with a different kernel.
