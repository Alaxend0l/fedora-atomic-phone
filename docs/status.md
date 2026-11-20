# Status and handoff

Living document: update the "Where things stand" and "Next steps" sections
when you stop. Newest log entries at the top.

## Where things stand (2026-11-20, end of day 1)
- **Framework:** scaffold, layered Containerfile, device format + validator,
  pluggable boot methods, flash guards. No image has been *built* yet
  (`just build`), none flashed.
- **N100 kernel:** Fedora 45's kernel (7.3.4) has every SM6115 driver needed
  to mount root on UFS and ships `sm4250-oneplus-billie2.dtb`. No custom kernel
  needed for a first boot.
- **N100 boot:** U-Boot builds (`uboot.img`). ABL accepts it via `fastboot boot`
  but doesn't hand over (or U-Boot dies before doing anything visible).
  Stock `boot_a` RAM-boots fine, so `fastboot boot` works on this phone.
- **Phone state:** Ubuntu Touch 24.04 build 697, stock `dtbo_a` (hash
  verified), slot `a`, bootloader unlocked. Nothing of ours is installed.

## Next steps
1. Bisect ABL vs U-Boot, RAM-only, stock dtbo: (a) stock kernel + our
   mainline DTB, (b) U-Boot + the stock DTB section. Whichever hands over
   (ABL fastboot disappears from USB) shows which half ABL rejects. Then
   rebuild U-Boot with `qcom-phone.config`. See boot/uboot-android/README.md.
2. If U-Boot still won't start: try header v0 with appended DTB; check the
   Image header; or fall back to `BOOT_METHOD=android-bootimg` (kernel +
   initramfs directly, same dtbo constraint applies).
3. Decide the ESP partition (devices/oneplus-billie2/README.md); extract
   `vendor` firmware first if it's `super`.
4. Get `just build` green for `oneplus-billie2` + `tty` (may need more
   podman machine memory).
5. Porting tooling from docs/roadmap.md, top three: no-flash dev loop,
   crash logs by default, inventory → draft device.

## Constraints discovered
- N100 ABL picks a `dtbo` overlay by hardware board id `0x1000b` + OnePlus
  `oem,project-id` 12 (stock entry 23 "Bengal OEM QRD") and applies it to any
  DT. With `dtbo` erased ABL refuses: "Failed to load/authenticate boot
  image: Load Error". A no-op dtbo (boot/noop-dtbo.sh) loads fine but didn't
  make U-Boot start.
- `fastboot boot` only works in the **bootloader** fastboot
  (`getvar is-userspace` = no), not Android's fastbootd. From Ubuntu Touch use
  `sudo systemctl reboot --reboot-argument=bootloader` (adb reboot is refused).
- In bootloader fastboot the N100 reports `product: bengal`; fastbootd says
  `billie2`.
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
| 2026-11-20 | same vbmeta + `dtbo_a` erased + `uboot.img` | `Load Error` again: ABL needs a loadable dtbo regardless of AVB flags. vbmeta_a and dtbo_a restored, both hashes verified |
