<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# @DEVICE_NAME@: feature checklist

Status as of @DATE@. The plan, in order of priority. What works today is in
[features.yaml](features.yaml) (one status per feature); this file is the
work list: each line says what's next and where its plan or evidence lives.
Priorities: **P1** daily use, **P2** nice to have, **P3** later / blocked.

Legend: [x] done · [~] partly / workaround · [ ] not started

## Core system
- [ ] **P1** First RAM boot: our kernel + mainline DT via `fastboot boot`, nothing written
- [ ] **P1** USB serial/network shell from the tiny initramfs (RAMBOOT_DRIVERS)
- [ ] **P1** Crash logs: ramoops in the DT, pstore read after a crash
- [ ] P1 Keys: power, volume
- [ ] P1 Boot from storage
- [ ] P2 Reboot to bootloader from Linux
- [ ] P2 Boot without `clk_ignore_unused pd_ignore_unused` ([hidden-dependencies.md](hidden-dependencies.md))
- [ ] P2 Suspend, thermal (cooling maps), cpufreq

## Display and graphics
- [ ] P1 Panel driver (lmdpdg from the vendor DT), backlight
- [ ] P1 GPU (zap shader, interconnect votes)
- [ ] P3 Video decode/encode

## Touch and input
- [ ] P1 Touchscreen

## Connectivity
- [ ] P1 Wi‑Fi (board data, stable MAC)
- [ ] P2 Bluetooth
- [ ] P2 USB host/OTG

## Audio
- [ ] P1 Sound card, speaker, headphones, microphones, earpiece

## Power and charging
- [ ] P1 Battery level
- [ ] P1 Charging status (never enable charger control without vendor values)

## Sensors and peripherals
- [ ] P2 Vibrator, sensors (accelerometer, proximity, light), microSD

## Cameras
- [ ] P3 Rear, front, flash

## Telephony
- [ ] P3 Modem (QMI/ModemManager), SIM, SMS, mobile data, calls, GNSS
