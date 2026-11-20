# Status and handoff

Living document: update the "Where things stand" and "Next steps" sections
when you stop. Newest log entries at the top.

## Where things stand (2026-11-20, end of day 1)
- **🎉 First Linux boot on the N100 (16:22):** Fedora 45 kernel 7.3.4 + mainline
  billie2 DT, RAM-booted with `make-ramboot.sh` (tiny busybox initramfs).
  UFS (all LUNs, 108 partitions), USB device mode (serial shell on the Mac),
  8 CPUs, 3.6 GB RAM, simpledrm framebuffer. Nothing written to storage.
- **Framework:** scaffold, layered Containerfile, device format + validator,
  pluggable boot methods, flash guards. No image has been *built* yet
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
1. **Boot a real Fedora rootfs, still without writing UFS:** from a microSD
   card (sdhci works) or over the USB network (NBD/NFS from the Mac).
2. **Mainline DT gaps for billie2** (devices/oneplus-billie2/dt-modules.txt):
   no PMIC nodes (pm6125/pmi632 on SPMI) → no power key, battery, charger,
   PMIC ADC/thermal; no panel, touch, Wi‑Fi, audio nodes. DT work, ideally
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
| 2026-11-20 | **dtbo_a erased**, fresh session, `uboot.img` (mainline DT) | **ABL hands over**; U-Boot resets within seconds; phone returns to ABL fastboot |
| 2026-11-20 | no-op dtbo, fresh session, variant v3 | no handoff. dtbo_a restored, hash verified |
| 2026-11-20 | v2, v3 booted right after a failed boot in the same ABL session | `Load Error`, which turned out to be a session artifact (see Constraints) |
| 2026-11-20 | same vbmeta + `dtbo_a` erased + `uboot.img` | `Load Error` again: ABL needs a loadable dtbo regardless of AVB flags. vbmeta_a and dtbo_a restored, both hashes verified |
