# Roadmap

## Framework
- [x] Scaffold: layered Containerfile, device folder format, validation
- [x] Build environment: podman machine (libkrun, arm64, 6 CPU, 2 GiB) on the Mac
- [ ] Get `just build` green for
      `oneplus-billie2` + `tty`
- [ ] `just disk` produces esp.img + rootfs.img
- [ ] CI: build images on push (manual trigger for now)
- [ ] Firmware extraction at first boot (modeled on droid-juicer)
- [ ] Publish images to a registry; `bootc upgrade` from a phone
- [x] Pluggable boot methods: uboot-android, android-bootimg, lk2nd (planned)

## Maintenance and releases
Phones update like Silverblue: `bootc upgrade` (or its timer) pulls the new
image per device+desktop from a registry, stages it, switches on reboot;
`bootc rollback` goes back. `android-bootimg` devices keep the boot partition
in step via `fap-android-boot` (inactive A/B slot); `uboot-android` needs
nothing extra.

1. [ ] **Scheduled CI rebuilds**: nightly/weekly plus on every push (today the
       workflow is manual-only).
2. [ ] **Registry publishing** (ghcr.io or quay.io), one OCI image per device
       and desktop.
3. [ ] **Image signing** with cosign; phones verify signatures before
       installing (Pocketblue does this).
4. [ ] **Channels:** publish to `testing`, promote to `stable` after tests.
5. [ ] **Fedora release upgrades** (~every 6 months, ~13 months support):
       bump `FAP_FEDORA`, rebuild, test, publish; keep the previous release
       available as a fallback.
6. [ ] **Kernel guard:** per-device test before publishing a new kernel, and
       a way to pin/hold a kernel for one device.
7. [ ] **Out-of-tree pieces rebuilt per kernel** (panel module, DT additions):
       automate in CI, e.g. kmod RPMs in COPR. Long term: **upstream them to
       mainline Linux**, the biggest maintenance win.
8. [ ] **Boot components:** U-Boot pinned per device, rebuilt deliberately.
9. [ ] Firmware is extracted on each phone; nothing to update.
10. [ ] **Testing before release:** RAM-boot loop, `fap-hwtest`, then
        real-device CI.
11. [ ] **People/process:** each device names `DEVICE_MAINTAINER` and a
        status; no active maintainer → status "unmaintained". Keep
        docs/status.md, decision records and release notes current.

## Porting tooling
More ideas, ranked per subsystem: [re-tooling.md](re-tooling.md).
What slows ports down is per-device bring-up (device tree, panel, touch,
firmware), not the distro layer. These make that loop fast and the dangerous
things impossible. Top three first.

1. [ ] **No-flash dev loop (top).** `fastboot boot` a kernel + initramfs from RAM,
       root filesystem over USB networking (NBD/NFS) from the build host.
       Rebuild kernel/DT → boot → test, nothing written to the phone. Flash only
       once a device works. Make this the default porting path in docs/porting.md.
2. [ ] **Crash logs on by default (top).**
   - [ ] ramoops required in every device tree (`check-device.sh` warns if the
         kernel DTB has no `ramoops` node)
   - [ ] next-boot crash report service: pstore + PMIC power-off/power-on reasons
         + last journal lines → one report (what UBports-N100's capture.sh /
         reset-report.sh did from the host, built into the OS)
   - [ ] netconsole over the USB network link, so the last kernel lines reach
         the host even on a hard reset
   - [ ] read the bootloader log region (`bootloader_log_mem` in the billie2 DT)
3. [ ] **Hardware inventory → draft device (top).** Generalize hw-inventory.sh
       (from the UBports-N100 notes repo); run it on stock/Halium and generate a
       draft device folder plus a skeleton mainline DT from the vendor tree:
       panel name and timings, touch bus/address, GPIOs, regulators, partition
       table, firmware locations. Partial is fine; it saves days of reading.
4. [ ] **Brick-proofing in the tools.**
   - [x] `flash.sh` refuses identity, boot-chain and firmware partitions and
         never relocks the bootloader
   - [ ] automatic first-flash backups (identity partitions, stock boot, dtbo,
         vbmeta)
   - [ ] gate the first flash on a passed recovery check (EDL detected, verified
         restore package for the exact model)
   - [x] never write the slot we booted from (`fap-android-boot` writes the
         inactive slot; fallback via the bootloader's failed-boot counter)
5. [ ] **ABI mismatch check** for Halium-style vendor modules: compare
       modversions and key header constants (e.g. `__GFP_BITS_SHIFT`) at build
       time. Would have caught the UBports N100 audio bug immediately.
6. [ ] **One kernel per chip family, devices as data:** a new phone = DT +
       panel + touch driver. The device folder format is shaped for this.
7. [ ] **Device feature test suite (`fap-hwtest`).** One command that checks
       every feature a phone should have and writes a feature matrix:
       display (resolution, refresh, backlight), touch (evdev events, slots),
       buttons, Wi‑Fi (scan/connect), Bluetooth, modem (ModemManager: SIM,
       registration, SMS, call audio), audio (playback/capture loopback per
       UCM verb), sensors (iio), charging/battery (power_supply), cameras,
       GPS, USB gadget, suspend/resume, reboot/uptime stability, crash-log
       collection. Runs on the phone (over SSH from the host), uses each
       device's declared features, never writes hardware state outside
       safe limits, and regenerates the hardware table in the device README.
       Same suite for vendor (Halium/stock) and mainline, so results diff.
8. [ ] **Real-device CI:** phones on USB-controlled power with automated EDL
       recovery, booting every build (LAVA-style, as Linaro does).

Runtime-swappable drivers: modules and DT overlays already load at runtime and
help when trying panel/touch settings, but many Qualcomm drivers don't unload
cleanly (`rmmod` was risky on the N100). Use the RAM-boot loop for anything
serious.

## OnePlus Nord N100 (`oneplus-billie2`)
- [ ] Wi‑Fi board data: pick the right vendor `bdwlan.*` (board_id reads
      0xff), pack a `board-2.bin` entry for variant `OnePlus_billie2`.
- [ ] Stable Wi‑Fi MAC (DT `local-mac-address` from the vendor-programmed
      value; the random-MAC bug UT had).
- [ ] Modem/Wi‑Fi startup as proper units for the real image (firmware from
      the modem partition, EFS policy: RAM-only vs real partitions, decided
      with the user).
- [ ] Clock at boot (RTC unset; timesyncd once Wi‑Fi is up).
Each step is reversible via fastboot or EDL.
1. [x] Check Fedora's kernel config for SM6115 drivers: all present in 7.3.4 (fc45), incl. the billie2 DTB (kernels/qcom-sm6115)
2. [x] Build U-Boot (`just uboot`, boot/uboot-android/): uboot.img built 2026-11-20
2b. [x] `fastboot boot uboot.img` (RAM only) shows U-Boot on screen: works with dtbo erased + qcom-phone.config (2026-11-20). U-Boot USB fastboot works; UFS/PMIC not yet in U-Boot.
3. [ ] Decide the ESP partition; extract `vendor` firmware first if it's `super`
4. [ ] First flash: Fedora tty image boots to the framebuffer console
5. [ ] SSH over USB; pstore collects crash logs
6. [ ] Phosh on the simple framebuffer (no GPU acceleration yet)
7. [ ] Touch (Ilitek SPI)
8. [ ] Wi‑Fi
9. [ ] Charging / battery reporting (PMI632, SMB1355)
10. [ ] Proper display driver (ILI9882N panel), GPU (Adreno 610)
11. [ ] Audio (WCD937x), modem, sensors
