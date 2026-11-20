<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Status and handoff

Living document: update the "Where things stand" and "Next steps" sections
when you stop. Newest log entries at the top.

## Where things stand (2026-11-20, end of day 1)
- **Fedora 45 userspace runs on the N100** (RAM only): `make-ramboot.sh` with
  `RAMBOOT_CMDLINE=fap.netroot=http://172.16.42.2:8000/netroot.tar.gz`, the
  tarball from `make-netroot.sh` served by `python3 -m http.server --bind
  172.16.42.2`. `ssh root@172.16.42.1`.
- **🎉 First Linux boot on the N100 (16:22):** Fedora 45 kernel 7.3.4 + mainline
  billie2 DT, RAM-booted with `make-ramboot.sh` (tiny busybox initramfs).
  UFS (all LUNs, 108 partitions), USB device mode (serial shell on the Mac),
  8 CPUs, 3.6 GB RAM, simpledrm framebuffer. Nothing written to storage.
- **Framework:** scaffold, layered Containerfile, device format + validator,
  pluggable boot methods, flash guards. Device template + `tools/new-device.sh`,
  per-device `features.yaml`/`firmware.yaml` with a generated support matrix
  (docs/devices.md), porting cookbook, CI workflow (ci.yml, not run yet). No image has been *built* yet
  (`just build`), none flashed.
- **N100 kernel:** Fedora 45's kernel (7.3.4) has every SM6115 driver needed
  to mount root on UFS and ships `sm4250-oneplus-billie2.dtb`. No custom kernel
  needed for a first boot.
- **N100 boot:** with `dtbo` erased, ABL starts U-Boot with the **mainline**
  DT. With `qcom-phone.config` + our `uboot.env`, **U-Boot runs, draws on the
  screen and offers USB fastboot** (`oem console`, `oem run:`). But U-Boot
  doesn't probe UFS or the PMIC yet, so it can't boot from internal storage.
  Stock `boot_a` RAM-boots fine, so `fastboot boot` works on this phone.
- **Phone state:** Ubuntu Touch 24.04 build 697, stock `dtbo_a` (hash
  verified), slot `a`, bootloader unlocked. Nothing of ours is installed.

## Next steps
1. **Fedora userspace boots over the USB network (done 2026-11-20):** next,
   use it to bring up hardware (PMIC DT nodes, display, touch, Wi‑Fi), then a
   microSD-based root, then the real bootc install.
2. **Mainline DT gaps for billie2:** PMIC + keys done in our DT
   (`devices/oneplus-billie2/dts/`, built with `tools/build-dtb.sh`, used via
   `RAMBOOT_DTB=`). Display, modem + Wi‑Fi, touch and battery percentage done. Next per
   docs/hardware/: GPU (DT-only), USB OTG, vibrator, Bluetooth, audio,
   charger driver, cameras, sensors; Wi‑Fi board data and MAC. DT work, ideally
   upstream. U-Boot UFS/PMIC support for SM6115 is upstream work too.
3. Consider restoring stock OxygenOS (EU 10.5.2 MSM, needs Windows) for a day
   to tell whether the random resets are hardware or Ubuntu Touch.
4. Decide the ESP partition (devices/oneplus-billie2/README.md); extract
   `vendor` firmware first if it's `super`.
5. Get `just build` green for `oneplus-billie2` + `tty` (may need more
   podman machine memory).
6. Porting tooling from docs/roadmap.md, top three: no-flash dev loop,
   crash logs by default, inventory → draft device.

## Constraints discovered
- N100 ABL picks a `dtbo` overlay by hardware board id `0x1000b` + OnePlus
  `oem,project-id` 12 (stock entry 23 "Bengal OEM QRD") and applies it to any
  DT. A no-op dtbo (boot/noop-dtbo.sh) didn't make U-Boot start (tested in a
  fresh session? yes: flashed, then first boot).
- **After a `fastboot boot` that doesn't hand over, the next `fastboot boot` in
  the same ABL session fails with `Load Error`.** Always `fastboot reboot
  bootloader` between attempts. Consequence: both "dtbo erased → Load Error"
  results were second attempts in a session, so **whether ABL boots with dtbo
  erased is still unknown** and must be retested from a fresh session.
- `fastboot boot` only works in the **bootloader** fastboot
  (`getvar is-userspace` = no), not Android's fastbootd. From Ubuntu Touch use
  `sudo systemctl reboot --reboot-argument=bootloader` (adb reboot is refused).
- In bootloader fastboot the N100 reports `product: bengal`; fastbootd says
  `billie2`.
- systemd-logind powers the phone off on KEY_POWER by default; for tests,
  `HandlePowerKey=ignore` in /run/systemd/logind.conf.d/.
- Without D-Bus, `systemctl reboot` fails; use `reboot -f`.
- The RTC is unset (1970): RPM signatures then fail as "not live yet" (looks
  like `BAD`). Set the clock first: `date -u -s <time from the host>`.
- Modem/Wi‑Fi: run `/usr/libexec/fap-modem-ram` in the netroot. Never enable
  Fedora's `rmtfs.service` (it serves the real modemst/fsg partitions; masked).
- Forced restart: **Power + Volume Up** ~15 s (Power alone does nothing).
- Fedora's kernel `Image` needs 76.5 MB from 0x8000; ramdisk/DTB offsets must
  sit above it (billie2: 0x06000000 / 0x05800000).
- ABL won't start an image with a ~68 MB ramdisk; a 1.7 MB one works.
- The billie2 DT uses the legacy nested dwc3 layout: needs `dwc3_qcom_legacy`.
- The RPM link needs `qcom_apcs_ipc_mailbox` + `rpm_proc`; without them every
  clock/regulator consumer (UFS, USB, SMMU) defers forever.
- After a reboot Ubuntu Touch sometimes brings USB up as file transfer only
  (`05c6:0afe`) even with Developer Mode on; unplug and replug the cable to get
  ADB (`05c6:9039`).
- Fedora's aarch64 vmlinuz is EFI zboot (zstd); Android bootloaders need
  `Image.gz` (handled in boot/android-bootimg).
- Both vbmeta slots have AVB verification enabled (flags 0); postmarketOS's
  (downstream) billie2 port flashes its own vbmeta. Disabling verification
  (flags 2) didn't change anything for our image, and dtbo still can't be erased.
- Backups of the N100's boot/dtbo/vbmeta (both slots) and identity
  partitions are in the UBports-N100 repo under `backup/` (git-ignored).

## Experiment log
| Date | Experiment | Result |
|---|---|---|
| 2026-11-20 | **Waydroid (branch `waydroid`, untested)**: installroot layer `dnf5 install waydroid` + `fap-waydroid-init` + binderfs ordering drop-in + OTA channels; see docs/waydroid.md | `podman build` of the installroot OK; nothing run on the phone. Kernel needs nothing: Fedora 7.3.4 has Rust binder + binderfs built in (`CONFIG_ANDROID_BINDER_IPC_RUST=y`), PSI=y, memfd. Waydroid's vendor image has Mesa 26.0.8 freedreno (FD610); UBWC off via `debug.mesa.fd.mesa.debug=noubwc` |
| 2026-11-20 | RAM-boot `uboot.img` (stock dtbo, from fastbootd) | `Unrecognized command boot`: fastbootd can't `boot` |
| 2026-11-20 | RAM-boot `uboot.img` (stock dtbo, bootloader fastboot) | `Booting OKAY`, logo, ABL fastboot stays |
| 2026-11-20 | RAM-boot stock `boot_a` | Ubuntu Touch boots from RAM (~30 s) |
| 2026-11-20 | `uboot.img` with stock os_version/patch level | no change |
| 2026-11-20 | `dtbo_a` erased + `uboot.img` | `Load Error`; dtbo restored, verified |
| 2026-11-20 | `dtbo_a` = no-op dtbo + `uboot.img` | no handoff; dtbo restored, verified |
| 2026-11-20 | `vbmeta_a` flags 0→2 (verification disabled) + stock dtbo + `uboot.img` | no handoff |
| 2026-11-20 | swap B: U-Boot + **stock** DTB section, stock dtbo | **ABL hands over** (fastboot gone in <3 s); U-Boot resets the phone almost at once (user: "restarted right after the OnePlus logo"); Ubuntu Touch then boots normally. First proof U-Boot runs. |
| 2026-11-20 | swap A: **stock kernel** + mainline DTB, stock dtbo | no handoff: ABL rejects the mainline DT itself |
| 2026-11-20 | U-Boot + mainline DT variants v1 (+`__symbols__`), v2 (`/memory`, `/soc` renamed), v3 (both); stock dtbo; each from a fresh bootloader | no handoff for any |
| 2026-11-20 | dtbo_a erased + U-Boot with `qcom-phone.config` | **U-Boot screen** (user photo): runs with the mainline DT; no button works |
| 2026-11-20 | dtbo_a erased + U-Boot with `qcom-phone.config` + N100 `uboot.env` | **U-Boot USB fastboot** (`U-Boot 2027.01-rc2`, product `oneplus-billie2`); log read via `oem console`; UFS and SPMI not probed. dtbo_a restored, verified |
| 2026-11-20 | Fedora kernel + 67.7 MB dracut initramfs (stock or high offsets) | no handoff: ABL refuses the big ramdisk |
| 2026-11-20 | Fedora kernel, no ramdisk, ramdisk/dtb offsets above the 76.5 MB kernel | **Linux boots**, kernel log on screen, panics (no root fs) as expected |
| 2026-11-20 | Fedora kernel + tiny busybox initramfs (1.7 MB) | boots; `/init` runs; USB not up; deferred list shows everything waiting on the RPM link |
| 2026-11-20 | + `qcom_apcs_ipc_mailbox`, `rpm_proc` | RPM up: **UFS works** (sda–sdf); USB still missing |
| 2026-11-20 | + `dwc3_qcom_legacy` (legacy nested DT layout) | **USB serial shell** (`/dev/cu.usbmodem101`); nothing deferred |
| 2026-11-20 | round 1: + ramoops, tsens, cpufreq-hw, sdhci-msm, rng, NCM | **USB networking** (Mac gets 172.16.42.2 via DHCP, telnet root shell on 172.16.42.1), 16 thermal zones (~33 °C), cpufreq 0.3–1.8 GHz, SD controller up (no card), pstore mounted (empty). Reboot from the shell (`reboot -f`) lands in ABL fastboot in ~6 s: no buttons needed while Linux runs |
| 2026-11-20 | **netroot**: tiny-init downloads a 278 MB Fedora 45 rootfs (make-netroot.sh) over USB HTTP into tmpfs, `switch_root` to systemd | **Fedora 45 userspace on the N100**, SSH as root over USB (key auth) ~35 s after boot; udev loads 66 modules; only `a7c0000.pinctrl` (LPASS, audio) deferred; logind failed (no D-Bus in the rootfs, fixed for next build) |
| 2026-11-20 | netroot + our DT (`devices/oneplus-billie2/dts/…-fap.dts`: PM6125 + PMI632 + keys) | systemd `running` (D-Bus fixed); **all three buttons verified with evtest**; PMIC ADC5 (battery 4.009 V, USB in 5.13 V, bat_id, charger/die/XO temps), temp-alarm, GPIO, RTC (`rtc-pm8xxx`, unset) |
| 2026-11-20 | display: lmdpdg ILI9882N panel module (`devices/oneplus-billie2/kmod/panel-ili9882n`) + MDSS/DSI nodes, no supply handling (LCDB left on by the bootloader) | **MSM DRM drives the panel**: `card1-DSI-1` connected 720×1600, DPU rev 0x60030000, console on msmdrmfb; DCS backlight 345/2047, stepped 100→1000→345 (panel readback 90/884/305) |
| 2026-11-20 | modem + Wi‑Fi: DT `remoteproc_mpss` + `wifi`; `fap-modem-ram` (firmware from `modem_a` read-only, EFS read into RAM, `rmtfs -r -o`) | modem up (first try crashed: "DOG detects stalled initialization" because only `modem.*` was served; serving all of `image/` incl. `modem_pr/` fixed it). ath10k WCN3990 up, WLAN.HL.3.2.4; scan 2.4+5 GHz; **joined a WPA2 hotspot, DHCP, ping, HTTPS 200**. Board data: linux-firmware generic (board_id 0xff); MAC random |
| 2026-11-20 | battery: `kmod/adc-ocv-battery` + `simple-battery` (vendor Desay OCV table, 25 °C) | `/sys/class/power_supply/battery`: capacity 65 %, Charging (USB in), 4.05 V. Read-only, no charger control |
| 2026-11-20 | touch: `kmod/ili9882n-ts` (our SPI driver, protocol from the OnePlus GPL kernel) + spi0/QUP/GPI nodes | **works from cold boot**, 10-finger MT (1–3 fingers tested), full screen range. Key: upload after the panel is on (DRM panel follower + 200 ms), no touch reset; see kmod/ili9882n-ts/README.md |
| 2026-11-20 | image v3 flashed to `boot_a` (GPU interconnect + per-OPP DDR votes, USB `qcom,select-utmi-as-pipe-clk`, PMI632 vibrator) | normal boot: **USB gadget enumerates** (12 s); GPU votes up to 3.88 GB/s, EBI ~4 GB/s, smoother UI; **vibrator works** (FF rumble 31 %/400 ms). Audit of bootloader-left state: devices/oneplus-billie2/hidden-dependencies.md |
| 2026-11-20 | Waydroid on the installed system (branch waydroid merged): `dnf5 install waydroid` + fap-waydroid-init (LineageOS 20 VANILLA) | **works**: Rust binder/binderfs, SurfaceFlinger on freedreno (Mesa in the vendor image), `noubwc` via debug.mesa properties. First start takes ~1 min (package setup); the window may bounce back to the home screen before Android is ready |
| 2026-11-20 | **installed**: `userdata` → ext4 `fap-root` with boot/android-bootimg/installroot (Plasma Mobile); `boot_a` ← installboot (tiny-init `fap.root=LABEL=fap-root selinux=0`, GPU DT). UT userdata backed up (file-level, UBports-N100/backup/userdata-ut-2026-11-20) | **boots standalone** (ABL normal-boots with dtbo_a erased) into Plasma Mobile; Wi‑Fi via Plasma settings; GPU (Adreno 610, freedreno) renders correctly with `FD_MESA_DEBUG=noubwc` (UBWC on = tile garbage). Fixes found: systemd-pam (else no logind session, KWin crash), plasma-setup masked, dnsmasq for usb0 |
| 2026-11-20 | **dtbo_a erased**, fresh session, `uboot.img` (mainline DT) | **ABL hands over**; U-Boot resets within seconds; phone returns to ABL fastboot |
| 2026-11-20 | no-op dtbo, fresh session, variant v3 | no handoff. dtbo_a restored, hash verified |
| 2026-11-20 | v2, v3 booted right after a failed boot in the same ABL session | `Load Error`, which turned out to be a session artifact (see Constraints) |
| 2026-11-20 | same vbmeta + `dtbo_a` erased + `uboot.img` | `Load Error` again: ABL needs a loadable dtbo regardless of AVB flags. vbmeta_a and dtbo_a restored, both hashes verified |
