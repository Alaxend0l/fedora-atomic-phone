# OnePlus Nord N100: feature checklist

Status as of 2026-11-20. The phone runs Fedora 45 + Plasma Mobile from its
own storage (boot_a + userdata). Each line: status, then where the plan or
evidence lives. Priorities: **P1** daily use, **P2** nice to have,
**P3** later / blocked. Details for most items are in
[docs/hardware/](../../docs/hardware/) and
[hidden-dependencies.md](hidden-dependencies.md).

Legend: [x] done · [~] partly / workaround · [ ] not started

## Core system
- [x] Boot from storage (ABL normal-boots boot_a with dtbo_a erased)
- [x] RAM-boot dev loop (`fastboot boot`) incl. the installed root (`fap.root=`)
- [x] Keys: power, volume up/down
- [x] Battery % (read-only `adc-ocv-battery`, OCV table)
- [~] **P1 Performance**: GPU had no DDR bandwidth vote → fixed in board DT (v2 image, testing); UBWC off (`FD_MESA_DEBUG=noubwc`), fix properly
- [ ] **P1 USB on normal boot** (no gadget after a non-fastboot boot) → `qcom,select-utmi-as-pipe-clk` in v2 image, testing
- [ ] **P1 Reboot to bootloader** from Linux (`reboot bootloader` doesn't reach fastboot; needs the PON reboot-mode for "bootloader")
- [ ] P2 Boot without `clk_ignore_unused pd_ignore_unused` (hidden-dependencies.md)
- [ ] P2 Quiet kernel console in the installed boot (drop `loglevel=7 ignore_loglevel`, add a splash?)
- [ ] P2 Move from plain ext4 root to the bootc/ostree image with `fap-android-boot` updates
- [ ] P2 Suspend (s2idle) + MPM / system sleep state (n100-power-and-install.md A2)
- [ ] P2 Thermal: CPU cooling maps, skin/XO zones (n100-power-and-install.md A3)
- [ ] P3 U-Boot boot path (UFS GDSC + PMIC in U-Boot)
- [ ] P3 Random hard resets seen on Ubuntu Touch: watch for them under Fedora (UBports-N100 tools/capture.sh)

## Display and graphics
- [x] Panel (our ILI9882N driver), brightness
- [x] GPU Adreno 610 (freedreno, zap shader from vendor)
- [ ] **P1 UBWC fix** (GPU vs DPU parameters for SM6115) → drop `noubwc`
- [ ] P2 Auto-brightness (needs the light sensor, see Sensors)
- [ ] P2 Panel power-off/suspend path; LCDB regulator driver (n100-gpu-video-display.md)
- [ ] P3 90 Hz mode (timings computed in n100-gpu-video-display.md)
- [ ] P3 Upstream the panel driver

## Touch and input
- [x] Touchscreen (our ili9882n-ts SPI driver, panel follower)
- [ ] P2 Touch suspend/resume across screen off/on (follower path exists; test with suspend)
- [ ] P3 Gestures (double-tap to wake) — vendor firmware supports it
- [ ] P3 Hex→ILI firmware converter (use the phone's own /vendor touch firmware)
- [ ] P3 Upstream the touch driver + binding

## Connectivity
- [x] Wi‑Fi (ath10k via modem; RAM-only rmtfs)
- [~] P1 Wi‑Fi startup reliability (fap-modem-ram retries; root cause of the early-boot stall unknown)
- [ ] **P1 Bluetooth** (WCN3988 on UART SE3, hci_qca; n100-telephony-bt-gnss.md)
- [ ] P2 Stable Wi‑Fi MAC (DT `local-mac-address`)
- [ ] P2 Wi‑Fi board data (vendor `bdwlan.*`, variant OnePlus_billie2; current: generic)
- [ ] P2 USB host/OTG (PMI632 Type-C + VBUS, DT-only; n100-charging-usb.md)
- [ ] P2 Wi‑Fi hotspot / USB tethering
- [ ] P3 NFC — not present on the N100 (verify)

## Audio
- [ ] **P1 Sound card**: ADSP + LPASS macros + WCD937x + sound card (n100-audio.md)
- [ ] P1 Speaker (AW87529 amp; can damage the speaker: follow the plan)
- [ ] P1 Headphone jack + headset mic + button
- [ ] P2 Earpiece (AW87359)
- [ ] P2 Microphones
- [ ] P2 ALSA UCM config for sm4250

## Power and charging
- [~] Battery %: voltage-based estimate, approximate
- [ ] **P1 Charging status that's correct** (PMI632 charger read-only status driver)
- [ ] P2 Real fuel gauge (QGauge coulomb counting)
- [ ] P2 Charger control (never bind qcom_smbx to PMI632: 4.87 V; n100-charging-usb.md SAFETY)
- [ ] P2 Battery temperature (ADC channel 0x2a, needs an adc5 patch)
- [ ] P3 Fast charging

## Sensors and peripherals
- [ ] P1 Vibrator (PMI632 vib, DT-only; keep ≤ ~73 % strength)
- [ ] P2 Sensors on the ADSP: accelerometer/gyro (rotation!), proximity, light, compass (libssc + hexagonrpcd + iio-sensor-proxy; n100-sensors-misc.md)
- [ ] P2 microSD card (controller up; test a card)
- [ ] P3 Notification LED (probably not fitted)
- [ ] P3 Fingerprint (Egis ET520 on a TrustZone-owned SPI bus: likely not feasible)

## Cameras
- [ ] P2 CAMSS + CCI nodes for SM6115 (n100-cameras.md)
- [ ] P2 Front OV8856 (driver exists), rear main OV13B10 (needs DT match patch)
- [ ] P3 Depth GC02M1B, macro GC02K0 (new drivers)
- [ ] P3 Flash LED (PMI632 flash; not in leds-qcom-flash)
- [ ] P3 libcamera tuning

## Video
- [ ] P2 Venus hardware video decode/encode (firmware on modem_a; n100-gpu-video-display.md)

## Apps and integration
- [~] P2 Waydroid (branch `waydroid`, untested; docs/waydroid.md)
- [ ] P2 Timezone / locale set up, Plasma Mobile settings polish
- [ ] P2 On-screen keyboard check (Maliit) everywhere
- [ ] P3 Plasma Login vs SDDM on mobile

## Telephony (no SIM yet — backseat)
- [ ] P3 Modem QMI via ModemManager (works without SIM for status queries)
- [ ] P3 SIM detect, SMS
- [ ] P3 Mobile data (IPA v4.2 node from agatti, rmnet)
- [ ] P3 Calls (call audio needs q6voice + working audio; VoLTE is a research project)
- [ ] P3 GNSS via QMI LOC + geoclue
