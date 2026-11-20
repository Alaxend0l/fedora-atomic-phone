<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Porting a new phone

Goal: one folder under `devices/`, no changes elsewhere. If your phone needs a
change outside its folder, that's a sign something should become a shared
option; open an issue.

| Read / run | For |
|---|---|
| `tools/new-device.sh` | creates the device folder from `devices/_template/` |
| `devices/_template/device.env` | every device key, documented in place |
| [porting-cookbook.md](porting-cookbook.md) | symptom → cause → fix recipes from earlier ports |
| [features.md](features.md) | `features.yaml` / `firmware.yaml` format |
| [devices.md](devices.md) | generated support matrix across devices |
| `devices/oneplus-billie2/` | a complete worked example |

## Before you start
- **Unlockable bootloader** (`fastboot flashing unlock` or the vendor's method).
- **A way back.** Know how to restore stock (EDL + vendor tool, factory
  images) and test it before flashing anything. Some phones have no
  low-level recovery once the boot chain is wrong (Pixel 6+: anti-rollback);
  read the cookbook's Pixel section if yours is one.
- **Back up identity partitions** (Qualcomm: `modemst1`, `modemst2`, `fsg`,
  `fsc`, `persist`; Pixel: `efs`, `efs_backup`, `modem_userdata`, `persist`,
  `mfg_data`). They hold IMEI/calibration and full restores don't bring them
  back. List them in `BACKUP_PARTITIONS`.
- **Mainline status.** Is there a device tree for your phone (or its SoC) in
  `arch/arm64/boot/dts/`? If not, porting means writing one first, maybe on
  an out-of-Fedora kernel (`KERNEL_SOURCE=git:...`). That's real kernel work.
- **Inventory the stock system** before wiping it: vendor DT, cmdline, dmesg,
  firmware listing, partitions (UBports-N100's `hw-inventory.sh`; generalised
  recon tooling: `tools/recon/`, see the `tooling` branch).

## Steps
1. `tools/new-device.sh --soc <soc> <vendor>-<codename> "<Name>"`
   (e.g. `--soc qcom-sm6115 oneplus-billie2 "OnePlus Nord N100"`).
2. Fill in `device.env` from the stock boot image (`unpack_bootimg`),
   `fastboot getvar all` and the vendor DT. `just DEVICE=<id> check`
   (tools/check-device.sh) tells you what's missing or malformed.
3. `README.md`: hardware table, boot chain, partitions, recovery.
   `firmware.yaml`: every blob, where it lives on the phone.
4. **First boot from RAM**, nothing written: build a kernel + tiny initramfs
   with `boot/android-bootimg/make-ramboot.sh devices/<id> out/`, then
   `fastboot boot out/ramboot.img` (fresh bootloader session each time).
   Aim for a USB serial/network shell (172.16.42.1). `tools/fap-dev` wraps
   this loop (see the `tooling` branch). When it doesn't come up, the
   cookbook's "First boot" recipes apply.
5. Bring up hardware with the RAM loop: board DT additions in `dts/`
   (`tools/build-dtb.sh`, `RAMBOOT_DTB=`), out-of-tree drivers in `kmod/`
   (`tools/build-kmod.sh`), a Fedora root over USB (`make-netroot.sh`,
   `fap.netroot=`). Record each feature in `features.yaml` as you go and
   regenerate `docs/devices.md` (`tools/support-matrix.py`).
6. Audit what the bootloader left on (`hidden-dependencies.md`, cookbook).
7. Pick partitions for the ESP and root filesystem; write down why in the
   README. Pick a `BOOT_METHOD` (boot/README.md).
8. Only now write to the phone: `just build`, `just disk`, `just flash`
   (verified backup + tested restore first).

## Debugging a phone with no screen
- USB networking + ssh comes from `base/` (`fap-usb-gadget.service`) and
  from tiny-init in RAM boots.
- tiny-init prints deferred devices to the screen: a photo is enough.
- Crash logs: enable ramoops in the device tree; read `/sys/fs/pstore/` after
  a crash.
- Keep a stock-restore path at hand and use it early rather than late.
