# Porting a new phone

Goal: one folder under `devices/`, no changes elsewhere. If your phone needs a
change outside its folder, that's a sign something should become a shared
option; open an issue.

## Before you start
- **Unlockable bootloader** (`fastboot flashing unlock` or the vendor's method).
- **A way back.** Know how to restore stock (EDL + vendor tool, fastboot
  images). Test it before flashing anything.
- **Back up identity partitions** (`modemst1`, `modemst2`, `fsg`, `fsc`,
  `persist` on Qualcomm). They hold IMEI/calibration and full restores don't
  bring them back.
- **Mainline status.** Is there a device tree for your phone in
  `arch/arm64/boot/dts/` of the mainline kernel? If not, porting means writing
  one first. That's real kernel work, separate from this repo.

## Steps
1. `cp -r devices/_template devices/<vendor>-<codename>`
2. Fill in `device.env`. `just DEVICE=<id> check` tells you what's missing.
3. Pick partitions for the ESP and root filesystem. Write down why in the
   device README (sizes, what you're overwriting).
4. Build U-Boot for it (`boot/u-boot/`). Try `fastboot boot uboot.img` first:
   it boots from RAM without writing anything.
5. `just build`, `just disk`, `just flash`.
6. First boot: use `DESKTOP=tty`. Reach it over USB at 172.16.42.1 (ssh).
7. Fill in the hardware table in the device README as things start working.

## Debugging a phone with no screen
- USB networking + ssh comes from `base/` (`fap-usb-gadget.service`).
- Crash logs: enable ramoops in the device tree; read `/sys/fs/pstore/` after
  a crash.
- Keep a stock-restore path at hand and use it early rather than late.
