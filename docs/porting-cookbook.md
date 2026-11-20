<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Porting cookbook

Problems we hit bringing up phones, as recipes: **symptom → cause → how to
check → fix → where it was solved**. Most come from the OnePlus Nord N100
(`oneplus-billie2`, SM4250, 2026-11-20); the Pixel/Tensor section comes
from the Pixel 8 desk research (branch `pixel8-research`,
`devices/google-shiba/research/`) and from Omarchy Mobile's measured Pixel 8
Pro (husky) bring-up. Commit hashes are on `main`. Read
[porting.md](porting.md) first for the overall flow.

Safety rules still apply to every recipe: RAM boot (`fastboot boot`) before
any write, backups before writes, never touch identity/boot-chain
partitions (AGENTS.md).

Contents
- Bootloader and boot images: [ABL session artifact](#abl-load-error-after-a-second-fastboot-boot) ·
  [dtbo](#abl-wont-start-a-mainline-dt-dtbo-overlays) ·
  [big kernels and header v2](#header-v2-offsets-for-big-kernels) ·
  [initramfs size](#abl-refuses-a-big-ramdisk-tiny-busybox-initramfs)
- First boot: [deferred probe from a photo](#nothing-comes-up-deferred-probe-debugging-from-a-photo) ·
  [missing PMIC nodes](#no-keys-adc-rtc-missing-pmic-nodes)
- Display and input: [lmdpdg panel drivers](#panel-driver-generate-it-with-lmdpdg) ·
  [TDDI touch](#tddi-touch-firmware-runs-but-no-touches)
- Modem and Wi‑Fi: [RAM-only rmtfs + full firmware dir](#modem-without-writing-efs-ram-only-rmtfs-and-the-full-firmware-directory) ·
  [early-boot stall](#modem-stalls-when-started-early-at-boot) ·
  [ath10k board data and MAC](#wi-fi-board-data-and-mac-address)
- Things the bootloader left on: [GPU interconnect votes](#gpu-slow-no-interconnect-votes-in-the-mainline-dt) ·
  [USB pipe clock](#usb-only-works-after-fastboot-hs-only-pipe-clock) ·
  [clk_ignore_unused audit](#the-clk_ignore_unused-audit) ·
  [UBWC tiles](#gpu-renders-tile-garbage-ubwc)
- Userspace: [Plasma on a minimal base](#plasma-mobile-on-a-minimal-fedora-root) ·
  [no sound card](#apps-crash-with-no-sound-card-pipewire-null-sink) ·
  [Waydroid on Rust binder](#waydroid-on-fedoras-rust-binder)
- Pixel/Tensor: [AVB footers](#abl-refuses-images-without-avb-footers-pixel) ·
  [/soc_compatible](#abl-doesnt-pick-our-dtb-soc_compatible-pixel) ·
  [vendor cmdline ignored](#kernel-arguments-ignored-use-dtb-bootargs-pixel) ·
  [fastboot boot and the active slot](#fastboot-boot-uses-the-active-slots-vendor-images-pixel) ·
  [ARB and slots](#anti-rollback-never-switch-slots-blindly-pixel)

---

## Bootloader and boot images

### ABL "Load Error" after a second fastboot boot
- **Symptom:** `fastboot boot img` answers `Failed to load/authenticate boot
  image: Load Error`, for an image (or a dtbo change) that you think should
  work. Tests contradict each other.
- **Cause:** after a `fastboot boot` that doesn't hand over, Qualcomm ABL
  stays in a state where the *next* `fastboot boot` in the same session
  fails. Two "dtbo erased → Load Error" results on the N100 were artifacts of
  this; the same test from a fresh session worked.
- **Check:** did anything run in this ABL session before? Repeat after
  `fastboot reboot bootloader`.
- **Fix:** one `fastboot boot` per ABL session: always `fastboot reboot
  bootloader` between attempts. Record "fresh session: yes/no" with every
  result.
- **Where:** `065e292`, boot/uboot-android/README.md ("session artifact"),
  docs/status.md "Constraints discovered".

### ABL won't start a mainline DT (dtbo overlays)
- **Symptom:** `Booting OKAY`, then nothing: the ABL fastboot keeps answering,
  the screen stays on the logo. With the *stock* DTB the same kernel/U-Boot
  starts.
- **Cause:** ABL picks a `dtbo` entry by the *hardware* board id (CDT; N100:
  `0x1000b` + OnePlus `oem,project-id`) and applies it to whatever DT is in
  the boot image. The overlay references vendor-only labels, fails on a
  mainline DT, and ABL gives up. Changing ids in our DT doesn't help
  (selection uses the hardware id). A no-op dtbo (one empty overlay with the
  right ids) did **not** help on the N100 either.
- **Check:** bisect: U-Boot/kernel + stock DTB section hands over, stock
  kernel + mainline DTB doesn't → it's the DT. `mkdtboimg dump dtbo.img`
  lists the entries and ids.
- **Fix:** `DTBO_MODE="erase"` (`fastboot erase dtbo_a`, backup first; the
  stock OS won't boot until it's restored). Test from a fresh session (see
  above). `boot/noop-dtbo.sh` builds the no-op variant if a phone refuses an
  empty dtbo.
- **Where:** `6e0fc3e`, `7c727da`, `09de521`, `7a1dfd4`;
  boot/uboot-android/README.md "Open leads" 5-8; devices/oneplus-billie2/README.md
  Partitions.

### Header v2 offsets for big kernels
- **Symptom:** ABL accepts the image but nothing starts (or random crashes),
  with a distro kernel; a small vendor kernel works with the same offsets.
- **Cause:** Fedora's arm64 `Image` is ~77 MB uncompressed (`image_size`
  0x4c70000 in the arm64 header). Stock offsets (ramdisk 0x01000000, DTB
  0x01f00000) sit *inside* the decompressed kernel, which overwrites them.
- **Check:** `image_size` is the little-endian u64 at offset 16 of the
  decompressed Image; kernel_offset + image_size must be below both the
  ramdisk and DTB offsets.
- **Fix:** move ramdisk and DTB above it: N100 `BOOTIMG_DTB_OFFSET=0x05800000`,
  `BOOTIMG_RAMDISK_OFFSET=0x06000000`. Also: Fedora's vmlinuz is EFI zboot
  (zstd); ABL needs plain `Image.gz` (make-ramboot.sh unwraps it).
- **Where:** `05dab21`, devices/oneplus-billie2/device.env (comment),
  boot/android-bootimg/make-ramboot.sh.

### ABL refuses a big ramdisk: tiny busybox initramfs
- **Symptom:** a Fedora kernel boots with no ramdisk (panics on no root),
  but with dracut's initramfs (68 MB) ABL never hands over.
- **Cause:** the N100's ABL refuses large ramdisks (limit unknown; 1.7 MB
  works, 67.7 MB doesn't).
- **Check:** same image without the ramdisk hands over → size.
- **Fix:** `RAMBOOT_INITRAMFS=tiny` (default): static busybox + only
  `RAMBOOT_DRIVERS` (decompressed, in dependency order) + `tiny-init`; a few
  MB. tiny-init then fetches a full root over USB (`fap.netroot=`) or mounts
  the installed one (`fap.root=`).
- **Where:** `05dab21`, `ffe8443`, `842c274`; boot/android-bootimg/tiny-init,
  make-ramboot.sh.

## First boot

### Nothing comes up: deferred-probe debugging from a photo
- **Symptom:** the kernel log scrolls on screen, but no USB gadget, no
  storage; no way to type anything.
- **Cause:** usually one missing provider driver: everything that needs a
  clock/regulator/interconnect defers forever. N100: without
  `qcom_apcs_ipc_mailbox` + `rpm_proc` the RPM link never came up, so UFS,
  USB and the SMMU all waited; then the legacy dwc3 layout needed
  `dwc3_qcom_legacy`.
- **Check:** tiny-init prints `/sys/kernel/debug/devices_deferred` and the
  USB state to the screen (`fap-init: deferred: ...`) when the gadget
  doesn't come up. Take a photo; the first supplier in the chain is the
  missing driver (`modinfo -F alias`, or grep the compatible in the Fedora
  kernel's `modules.alias`).
- **Fix:** add the module to `RAMBOOT_DRIVERS`, rebuild with make-ramboot.sh,
  fresh ABL session, boot again. Iterate until nothing is deferred.
- **Where:** `05dab21`; boot/android-bootimg/tiny-init (deferred print);
  docs/status.md experiment log (RPM, dwc3_qcom_legacy rows).

### No keys, ADC, RTC: missing PMIC nodes
- **Symptom:** the power/volume keys do nothing in Linux, no battery voltage,
  no RTC; nothing in dmesg about PMICs.
- **Cause:** the mainline board DT doesn't include the PMIC `.dtsi` files
  (N100: PM6125 and PMI632), so their SPMI functions (pon/keys, ADC5, RTC,
  GPIOs, temp-alarm) never probe.
- **Check:** `ls /sys/bus/spmi/devices/`; compare with the vendor DT's PMIC
  list (`log/hw-inventory`).
- **Fix:** in our board DT (`dts/*-fap.dts`): include the PMIC dtsi, enable
  `pon_pwrkey`/`pon_resin` and add `gpio-keys` for the key on a PMIC GPIO
  (N100: resin = volume up, PM6125 GPIO 5 = volume down; vendor labels can
  be wrong, trust the key codes Android used). Verify with `evtest`.
- **Where:** `343b854`, `18f3bc9`;
  devices/oneplus-billie2/dts/sm4250-oneplus-billie2-fap.dts.

## Display and input

### Panel driver: generate it with lmdpdg
- **Symptom:** only simpledrm/simple-framebuffer (the bootloader's buffer):
  no brightness, no blanking, no GPU-backed DRM.
- **Cause:** no mainline driver for the panel. Vendor kernels describe the
  init sequence and timings in DT (`qcom,mdss_dsi_*`).
- **Check:** panel name from the vendor cmdline/DT
  (`msm_drm.dsi_display0=` or `/proc/device-tree/...`).
- **Fix:** run [linux-mdss-dsi-panel-driver-generator](https://github.com/msm8916-mainline/linux-mdss-dsi-panel-driver-generator)
  on the vendor DTB node; use `--dumb-dcs` when the init writes reuse DCS
  opcodes in vendor pages (ILI). Build it as a kmod in `devices/<id>/kmod/`,
  add MDSS/DSI + panel nodes to the board DT. Leave supplies the bootloader
  enabled alone until you have a regulator driver (N100: LCDB), and say so.
- **Where:** `8505e57`; devices/oneplus-billie2/kmod/panel-ili9882n/README.md.

### TDDI touch: firmware runs but no touches
- **Symptom:** touch controller answers commands (firmware version reads
  fine) but never reports touches; INT pulses every few seconds; reads
  return ACK 0xff.
- **Cause:** TDDI chips (touch and display driver in one; ILI9882N, NT36525)
  run touch firmware from RAM and depend on the display: it must be
  uploaded *after* the panel is initialised and its DSI video stream runs,
  and *without* pulsing the touch reset (the panel reset already reset it).
- **Check:** does touch work after a screen off/on cycle but not at boot?
  Ordering problem.
- **Fix:** make the touch driver a **DRM panel follower** (`panel` phandle in
  the touch node) and upload ~200 ms after `panel_prepared()`. Firmware
  comes from the phone/vendor source, never the repo.
- **Where:** `1770b22`; kmod/ili9882n-ts/README.md ("Things that matter").

## Modem and Wi‑Fi

### Modem without writing EFS: RAM-only rmtfs and the full firmware directory
- **Symptom (1):** you want modem/Wi‑Fi but Fedora's `rmtfs.service` would
  serve (and write) the real `modemst1/2`, `fsg`, `fsc` partitions: IMEI and
  RF calibration.
- **Fix (1):** read those partitions into `/run`, run `rmtfs -r -o <dir>`
  (writes stay in memory), mask `rmtfs.service`. Mount `modem_a` read-only.
- **Symptom (2):** modem starts, then crashes: "DOG detects stalled
  initialization".
- **Cause (2):** only `modem.*` was served; the modem also fetches files
  (e.g. `modem_pr/` configs) over TFTP via tqftpserv.
- **Fix (2):** bind-mount the *whole* `image/` directory of `modem_a` at the
  `firmware-name` directory and point the firmware search path there.
- **Check:** `cat /sys/class/remoteproc/*/state`, `journalctl -u fap-tqftpserv`
  (which files the modem asked for).
- **Where:** `409bb00`; boot/android-bootimg/netroot/rootfs/usr/libexec/fap-modem-ram.

### Modem stalls when started early at boot
- **Symptom:** at boot, sometimes no Wi‑Fi; the modem's watchdog fires
  ~65 s in. Restarting rmtfs/tqftpserv later works.
- **Cause (likely):** `qrtr: failed to announce new service` at 25 s:
  rmtfs/tqftpserv announce before the modem's QRTR node exists, so the modem
  never learns of them.
- **Check:** `journalctl -k | grep -E 'qrtr|remoteproc|DOG'`; `qrtr-lookup`
  shows whether node 0's services are there.
- **Fix:** today: retry (fap-modem-ram starts the services, waits 60 s for
  `wlan0`, retries up to 3×). Proper fix idea: wait for the modem's QRTR node,
  then (re)start the services.
- **Where:** `ec70634`, `104f1ff`; devices/oneplus-billie2/hidden-dependencies.md.

### Wi‑Fi board data and MAC address
- **Symptom:** ath10k works but logs a generic board file, and `invalid MAC
  address`: a new random MAC every boot (new DHCP lease each time; on Ubuntu
  Touch the random MAC was sometimes multicast and Wi‑Fi failed).
- **Cause:** board data: the phone reports board_id 0xff and linux-firmware's
  `board-2.bin` has no entry for the variant, so ath10k takes the generic
  one. MAC: the vendor stack sets it from `persist` at run time; mainline
  needs it in the DT.
- **Check:** `dmesg | grep -i 'ath10k.*board'`; `ip link show wlan0`
  across two boots.
- **Fix:** set `qcom,calibration-variant` in the `&wifi` node (done:
  `OnePlus_billie2`) and pack the vendor `bdwlan.*` into a `board-2.bin`
  entry for it (open); add `local-mac-address` from the factory value (open,
  read it without writing `persist`).
- **Where:** devices/oneplus-billie2/dts/ (`&wifi`), TODO.md Connectivity,
  docs/hardware/n100-telephony-bt-gnss.md.

## Things the bootloader left on

### GPU slow: no interconnect votes in the mainline DT
- **Symptom:** UI stutters with the GPU pegged at its top clock; DDR
  bandwidth stays at the display's level.
- **Cause:** mainline `sm6115.dtsi` gives the GPU no `interconnects` and the
  OPPs no `opp-peak-kBps`, so it never votes DDR bandwidth.
- **Check:** `/sys/kernel/debug/interconnect/interconnect_summary` has no
  GPU line; EBI peak ~0.8 GB/s under GPU load.
- **Fix:** add `interconnects`/`interconnect-names = "gfx-mem"` and per-OPP
  peaks, copied from a sibling SoC with the same GPU (agatti / QCM2290).
  Upstream it.
- **Where:** `0e22680`, `02fa6df`; board DT (`&gpu`), hidden-dependencies.md.

### USB only works after fastboot: HS-only pipe clock
- **Symptom:** USB gadget works when RAM-booted from fastboot, but after a
  normal boot: `dwc3: failed to enable ep0out`, no USB.
- **Cause:** the board wires USB 2.0 only, but DWC3 still needs a PIPE clock.
  Fastboot mode leaves the USB3 PHY's pipe clock running; a normal boot
  doesn't.
- **Check:** `clk_summary`: `gcc_usb3_prim_phy_pipe_clk` on in hardware but
  unclaimed (after fastboot), off after a normal boot.
- **Fix:** `qcom,select-utmi-as-pipe-clk;` in the `&usb` node (honoured by
  dwc3-qcom-legacy).
- **Where:** `0e22680`, `02fa6df`; board DT (`&usb`).

### The clk_ignore_unused audit
- **Symptom:** things work in one boot mode but not the other, or only with
  `clk_ignore_unused pd_ignore_unused` on the cmdline.
- **Cause:** the DT never claims a clock, power domain, supply or vote; it
  works because the bootloader left it on. Those two arguments hide it.
- **Check:** the commands in `devices/_template/hidden-dependencies.md`
  (unclaimed clocks, interconnect summary, genpd summary, dummy regulators,
  deferred devices), after a normal boot *and* after `fastboot boot`; diff.
  `fap-boot-state.service` records a snapshot per boot.
- **Fix:** one row per finding in the device's hidden-dependencies.md; fix in
  the DT; finally boot (RAM only) without the two arguments.
- **Where:** `0e22680`, `79c7191`; devices/oneplus-billie2/hidden-dependencies.md.

### GPU renders tile garbage: UBWC
- **Symptom:** with GPU acceleration, the desktop is blocky tile garbage;
  software rendering is fine.
- **Cause:** UBWC (bandwidth compression) parameters differ between the
  kernel's display/`ubwc_config` and Mesa's freedreno values for the SoC
  (SM6115 open).
- **Check:** `FD_MESA_DEBUG=noubwc` makes it render correctly.
- **Fix:** workaround: `FD_MESA_DEBUG=noubwc` in `/etc/environment` (and
  `debug.mesa...` properties for Waydroid). Real fix: align the kernel's
  ubwc_config with Mesa's a610 parameters (costs bandwidth until then).
- **Where:** `2c68e81`; installroot/Containerfile; TODO.md Display.

## Userspace

### Plasma Mobile on a minimal Fedora root
- **Symptom:** KWin crashes / no session; a setup wizard replaces autologin;
  the host gets no address on the USB network after Plasma comes up.
- **Cause:** a minimal root lacks `systemd-pam` (no logind session → KWin
  can't get DRM); `plasma-setup` (first-run wizard) takes over; NetworkManager
  deliberately ignores USB gadget interfaces, so nobody serves DHCP on `usb0`.
- **Fix:** install `systemd-pam`; mask `plasma-setup.service`; SDDM with a
  plain autologin config; a small dnsmasq unit for `usb0` (no DNS/gateway).
- **Where:** `842c274`, `2c68e81`; boot/android-bootimg/installroot/Containerfile,
  `rootfs/usr/lib/systemd/system/fap-usb-dhcp.service`.

### Apps crash with no sound card: PipeWire null sink
- **Symptom:** some apps segfault when opening audio (VLC in `MuteSet`).
- **Cause:** no ALSA card at all → PipeWire has no sink.
- **Fix:** a `support.null-audio-sink` in `pipewire.conf.d/`; remove it once
  the sound card exists.
- **Where:** `74bc5ce`; installroot/rootfs/etc/pipewire/pipewire.conf.d/50-fap-null-sink.conf.

### Waydroid on Fedora's Rust binder
- **Symptom:** "no binder" worries: Fedora doesn't build the C binder.
- **Cause / facts:** Fedora 45 has `CONFIG_ANDROID_BINDER_IPC_RUST=y` with
  binderfs built in; Waydroid ≥ 1.6 mounts binderfs itself; Fedora's package
  adds `dev-binderfs.mount` and the `/dev/*binder` links.
- **Fix:** order `waydroid-container.service` after `dev-binderfs.mount`
  (drop-in), fill the OTA `channels.cfg`, set `noubwc` via debug.mesa
  properties where UBWC is broken. Watch the Rust binder ENOSPC bug
  (waydroid#2422).
- **Where:** `fb92266`, `7b7c46e`; docs/waydroid.md.

## Pixel / Tensor (header v4, Exynos-derived ABL)

Desk research plus Omarchy Mobile's measured husky (Pixel 8 Pro) notes; on
our shiba only "`fastboot boot` of the stock boot.img works" is verified.
Not supported by our tooling yet: `device.env` has the keys
(`BOOT_IMAGES`, `AVB_FOOTERS`, `SOC_COMPATIBLE`, `DTBO_BOARD_ID/REV`,
`VENDOR_KERNEL_BOOT`, `CMDLINE_IN`, `FLASH_SLOT`) so the facts are recorded.

### ABL refuses images without AVB footers (Pixel)
- **Symptom:** an unlocked Pixel 8 still won't boot our `boot`/`init_boot`.
- **Cause:** zuma's ABL requires an AVB hash footer on chained partitions
  even when unlocked (husky, BRINGUP-M1 tests 6-8).
- **Fix:** `avbtool add_hash_footer --partition_name boot --partition_size
  <getvar partition-size:boot_b>` (+ stock rollback index / security patch);
  record as `AVB_FOOTERS="boot:0x4000000 init_boot:0x800000"`.
- **Where:** google-shiba research boot-and-flashing.md §4-5; Omarchy
  `device/husky/device.conf`.

### ABL doesn't pick our DTB: /soc_compatible (Pixel)
- **Symptom:** our DTB in `vendor_kernel_boot` is ignored or the boot fails.
- **Cause:** zuma's ABL matches base DTBs on a `/soc_compatible` node (one
  child per silicon revision + package: product_id, major, minor, pkg_mode),
  not qcom,msm-id; retail husky is B0/B1 FOPLP. It also wants an `/ect` node
  and a matching dtbo entry (board_id/rev).
- **Fix:** add `/soc_compatible` children for all plausible revisions
  (`SOC_COMPATIBLE`), `/ect`, and either a dtbo overlay with
  `DTBO_BOARD_ID/REV` (shiba MP: 0x40306 / 0x010000) or erase dtbo
  (Linaro's flow).
- **Where:** research boot-and-flashing.md §3-4, device.env.draft.

### Kernel arguments ignored: use DTB bootargs (Pixel)
- **Symptom:** `earlycon`, `console=` or our own arguments in the
  vendor_boot cmdline have no effect.
- **Cause:** husky's ABL ignores the vendor cmdline; the kernel takes
  `/chosen/bootargs` from the DTB, and ABL replaces any `console=` with
  `console=null`.
- **Fix:** `CMDLINE_IN="dtb"`: put arguments in `/chosen/bootargs` (or a
  DT overlay); use `reboot=warm` so `reboot bootloader` works (a cold PSCI
  reset clears the reboot-mode register).
- **Where:** Omarchy `device/husky/BRINGUP-M1.md` tests 9-10 and 22.

### fastboot boot uses the active slot's vendor images (Pixel)
- **Symptom:** `fastboot boot boot.img` boots our kernel with the stock DTB
  and stock ramdisk.
- **Cause:** with header v4, `fastboot boot` sends only `boot`; ABL takes
  `vendor_boot`, `vendor_kernel_boot` (DTB) and `dtbo` from the **active
  slot** on flash, and a ramdisk in boot.img may be ignored for init_boot's.
- **Fix:** test `fastboot stage vendor_boot.img` + `fastboot boot` first
  (Linaro, untested on shiba); otherwise write the test slot's
  `vendor_kernel_boot_b`/`dtbo_b`/`init_boot_b` (with `FLASH_SLOT="b"`) and
  keep slot a stock.
- **Where:** Pixel8 recon log 2026-11-20 (stock boot.img RAM-boots on shiba);
  research boot-and-flashing.md §4.

### Anti-rollback: never switch slots blindly (Pixel)
- **Symptom:** a phone that only shows up as USB `18d1:4f00` ("Pixel ROM
  Recovery"): a hard brick with no public recovery on post-May-2025 units.
- **Cause:** activating a slot whose bootloader is older than the fused
  anti-rollback level (e.g. after an OTA updated only one slot).
- **Check:** `fastboot getvar all`: bootloader version per slot,
  `slot-unbootable`.
- **Fix (rule):** never flash bootloader/radio ourselves; bring both slots to
  the same current bootloader with a factory image before any slot switch;
  `FLASH_SLOT` pins our writes; `PROTECTED_PARTITIONS` lists the boot chain.
  On shiba, slot b is marked unbootable: don't switch.
- **Where:** research boot-and-flashing.md §6 + checklist,
  unbrick-tools.md.
