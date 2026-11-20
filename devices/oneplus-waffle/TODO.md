<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12: feature checklist

Status as of 2026-11-20. What works lives in [features.yaml](features.yaml);
this is the work list. **P1** daily use, **P2** nice to have, **P3** later.
Legend: [x] done · [~] partly / workaround · [ ] not started

## First light (RAM only, nothing written)
- [x] Read-only backup of all partitions except userdata/super (144 entries)
- [x] Stock boot layout read from the backup (README.md "Boot chain")
- [x] Kernel (waffle-voice + Fedora config + fap.config), first-light DT, initramfs, uniLoader images built
- [x] **P1** `fastboot boot` the stock boot_a.img once (works, 2026-11-20; USB 2.0 cable needed, USB 3 crashes ABL fastboot)
- [ ] **P1** `fastboot boot ramboot/waffle-uniloader-v4.img`: uniLoader log on screen, kernel log, USB gadget
- [ ] **P1** Crash logs: ramoops at 0x85000000, read from the next RAM boot
- [ ] **P1** netroot variant, `ssh root@172.16.42.1`
- [ ] P1 Ask DaDDevil to license `sm8650-oneplus-waffle.dts` (needed before we commit or upstream anything derived)
- [ ] P1 File the Fedora config request (PINCTRL_SM8650, INTERCONNECT_QCOM_SM8650, SM_DISPCC_8550, ...)
- [ ] P2 Boot without `clk_ignore_unused pd_ignore_unused regulator_ignore_unused` ([hidden-dependencies.md](hidden-dependencies.md))
- [ ] P2 USB SuperSpeed (QMP combo PHY needs TYPEC built in or a module in the initramfs)
- [ ] P2 Use ABL's `/memory` instead of the hard-coded 16 GB map (uniLoader passes only its own DTB)

## Then (dossier porting-plan.md, phases 3-5)
- [ ] P1 Panel (panel-boe-aa545, MDSS on; Iris7 left in bypass), touch (S3910)
- [ ] P1 Battery/charging via ADSP + pmic-glink (never set charger values ourselves)
- [~] P1 Wi‑Fi (ath12k): works from a cold path (v5); warm-reboot fix (pwrseq shutdown patch) in v7, untested
- [~] P1 GPU (Adreno 750, OnePlus-signed zap): v7 built, untested
- [~] P2 Bluetooth (hci_qca on UART14, bluetooth_a firmware): v7 built, untested
- [~] P2 Video codec (Iris, vpu33_4v.mbn): v7 built, untested
- [~] P2 Audio: v6 enables the WCD9395 path (sound card, SoundWire, LPASS macros, Fedora AudioReach topology, ucm/); mics testable, HPH not routed to USB-C yet
- [~] P2 Speakers/earpiece: v8 (oneplus12-hw): conservative tfa9874 driver (no boost, vendor gain, off by default) + SECONDARY_MI2S topology; untested, test only at -40 dBFS after the user's OK (fap-build/waffle/hw/HW.md). Later: speaker protection (no host-DSP SpeakerBoost), datasheet for gain scales
- [~] P2 USB-C analog headset: v8: i2c3 wcd939x-usbss + codec graph link (QRD style); untested (fap-hw-headset-watch)
- [~] P2 Haptics (v7: stock 1.72 V vmax, untested), [ ] alert slider
- [ ] P3 Modem
- [~] P3 Sensors (SSC): v8: hexagonrpcd + libssc + iio-sensor-proxy (SSC) with the unit's config/registry; untested (fap-hw-sensors)
- [~] P3 Cameras: v8: CAMSS + 4 sensor drivers + libcamera simple/softISP; untested (fap-hw-camera)
