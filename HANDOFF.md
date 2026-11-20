<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Handoff: state of the project (2026-11-20, 23:30 CET)

Read this first, then `AGENTS.md` and `docs/status.md`. The phone-side lab
notebooks (not in git; contain unit data) are `~/Develop/OnePlus12/`
(`AGENTS.md` = safety rules, `log/2026-11-20-recon.md` = everything tested),
`~/Develop/Pixel8/` and `~/Develop/UBports-N100/`.

## Headline
**Fedora (Plasma Mobile, GPU-accelerated) is installed on the OnePlus 12
(waffle) and boots from storage**, as a dual boot that leaves LineageOS
untouched:

| What | Where |
|---|---|
| Fedora kernel (uniLoader boot image) | `boot_b` (sha256 `f870e95f…`) |
| Fedora root (ext4, label `fap-root`, 8 GiB) | logical partition `fap_root` in `super` (raw sha256 `cd29c50f…`) |
| LineageOS 23.2 (rooted: Magisk + KernelSU) | slot a, unchanged (all boot-chain hashes verified before the writes) |
| Active slot | **b** |

Install log with every command and hash: `~/Develop/OnePlus12/log/install-20261120/`.
Runbook and design: `devices/oneplus-waffle/INSTALL.md` (branch
`oneplus12-install`), `~/Develop/fap-build/waffle/install/INSTALL-RUNBOOK.md`.
LineageOS's Updater app is disabled (`pm disable-user`), because an OTA would
rewrite slot b. Re-enable: `adb shell pm enable org.lineageos.updater`.

### Switching / recovery
- To LineageOS: bootloader (`Power + Vol Down` or `fastboot`), then
  `fastboot --set-active=a && fastboot reboot`. Back: `--set-active=b`.
- The boot menu (3 s, volume keys) and `fap-switch-os` exist but `qbootctl`
  writes (`-s a`, `-m b`) are **untested** (W6 in the runbook).
- **Check first thing:** did `fap-boot-ok.service` mark slot b successful
  (`journalctl -b -u fap-boot-ok`, `qbootctl`)? If not, ABL decrements the
  retry counter each boot and falls back to slot a after ~7 boots (harmless:
  `fastboot --set-active=b`).
- Undo the whole install: `fastboot --set-active=a`; `fastboot flash boot_b
  ~/Develop/OnePlus12/backup/partitions-20261120/boot_b.img` (sha `5bc8c79d…`);
  in fastbootd (`adb reboot fastboot`) `fastboot delete-logical-partition fap_root`.

## OnePlus 12 feature status
| Feature | Status |
|---|---|
| Display (msm DSI, BOE AA545), touch, GPU (Adreno 750, freedreno) | works |
| Plasma Mobile on the GPU | works, "smooth and excellent" |
| 15 GB RAM, battery %, cpufreq | works |
| Wi‑Fi (ath12k WCN7850), Bluetooth, warm reboot keeps Wi‑Fi | works (RAM boot); join Wi‑Fi in Settings |
| Iris video, haptics, microphones | works (RAM boot) |
| Modem + ModemManager (QRTR), EFS served from RAM copies | works; auto-start only in the `oneplus12-tel` build |
| Brightness, flash LED, CPU thermal throttling at 90 °C | works in the `oneplus12-power` RAM build; not in the installed image yet |
| **USB gadget (SSH over USB) on the installed boot** | **not seen after the first storage boot**: first thing to debug (N100 lesson: RAM vs normal boot differences) |
| Speakers/earpiece (TFA9874) | driver in `oneplus12-hw`, never played. **Only with the owner's explicit OK, lowest gain** (`FAP_SPEAKER_APPROVED=yes fap-hw-speaker-test`) |
| Sensors (SSC via hexagonrpcd/libssc) | **starting them reset the phone**; debug with dmesg -w over Wi‑Fi, then pstore |
| Cameras, USB‑C headset | built in `oneplus12-hw`, untested |
| GPS | `qmicli --loc-start` → QMI GeneralError; untested via ModemManager |
| SMS, data, calls | need a SIM; call audio + VoLTE missing; never rely on it for emergency calls |
| Waydroid | **missing**: needs binder in the kernel + the `waydroid` package (below) |
| Suspend | disabled on purpose (`AllowSuspend=no`); staged test plan in POWER.md |
| Alert slider | needs a new driver (MXM1120 hall sensors), plan in POWER.md |
| Spontaneous resets | 2 tonight (sensors test; telephony build idle), cause unknown |

## Branches (none merged to main yet; merge order suggestion)
1. `minimal-layers`: layered images (decision 0003), phone-essentials apps,
   `layers/apps-extra`, `fap-wifi`, libglvnd-gles fix. Lockfiles need regenerating.
2. `oneplus12-build` → `oneplus12-install` (INSTALL.md) → `oneplus12-dualboot`
   (fap-lpmap, boot menu, installroot, `fap.root=lp:`, Waydroid config attempt).
3. `oneplus12-power`, `oneplus12-tel`, `oneplus12-hw`: each adds
   `FAP_WAFFLE_VOLUME` to `fap-waffle-build.sh` (same name, expect trivial
   conflicts) plus their feature work; per-feature test docs are
   `POWER.md` / `TEL.md` / `HW.md` in `~/Develop/fap-build/waffle/{power,tel,hw}/`.
4. `pixel8-research`: Pixel 8 build paused by the owner; research continues.

Build outputs (local only, several are SENSITIVE: they contain the phone's
EFS/IMEI copies and OEM firmware; never commit or upload):
`~/Develop/fap-build/waffle/{bisect,plasma-netroot-gpu,hw,power,tel,install}/`.

## Next steps, in order
1. **USB on the installed boot**: why no gadget? Compare with RAM boot
   (`devices_deferred`, dwc3/eUSB2 repeater, pmic-glink role). Reach the phone
   over Wi‑Fi (`ssh root@<phone-ip>`) meanwhile.
2. **Verify slot b marked successful** (above).
3. **Update the installed system** with the power + telephony work: build a
   boot_b + root update from a merge of `oneplus12-dualboot`, `-power`,
   `-tel`; flash only `boot_b` / `fap_root` (runbook W9), never slot a.
4. **Waydroid**: root cause found (`oneplus12-dualboot` 7496467): DaDDevil's
   7.4-rc tree has **only the Rust binder** (`ANDROID_BINDER_IPC_RUST`,
   `depends on RUST`, binderfs built in; the C binder and
   `ANDROID_BINDERFS` are gone), and the build container had no Rust.
   Fixed: `CONFIG_RUST=y` + `CONFIG_ANDROID_BINDER_IPC_RUST=y` in
   `waffle.config`, `rust rust-src bindgen-cli clang-libs` in the build
   Containerfile (rebuild the image: `podman build -t
   localhost/fap-waffle-build -f Containerfile .`). Build:
   `FAP_WAFFLE_VOLUME=waffle-build-inst OUT=~/Develop/fap-build/waffle/install-waydroid
   devices/oneplus-waffle/build-env/fap-waffle-build.sh kernel dtb initramfs images`
   (if `make rustavailable` complains, the Fedora rustc/bindgen versions vs
   this tree's minimums are the suspect). Then: flash the new
   `boot_b/fap-boot_b.img` to `boot_b` only, copy the new
   `parts/modules-*.tar.gz` into the installed root's `/usr/lib/modules`,
   `dnf install waydroid` on the phone, `waydroid init` (see `docs/waydroid.md`).
5. Sensors reset, speakers (with OK), cameras, headset, GPS, alert slider.

## Safety rules (summary; full list in the notebooks' AGENTS.md)
- Never write identity partitions (modemst1/2, fsg, fsc, persist, oplus
  reserve/calibration), the boot chain (xbl*, abl, tz, hyp, …), any `_a`
  partition, vbmeta*, or `super` as a whole. Never relock. Never flash older
  firmware (anti-rollback fuse is set).
- Before any write: verified backup + restore command + ask the owner.
- One actor on the phone; always `adb -s` / `fastboot -s 74f53f80`.
- **USB 2.0 cable for bootloader fastboot** (USB3/Thunderbolt crashes ABL into 900E).
- Serve netroots only on the USB link (`--bind 172.16.42.2`), never 0.0.0.0.
- Never use battmgr debugfs charge controls; no speaker tests without OK;
  never PCI remove/rescan the Wi‑Fi chip.
- No passwords in files, the repo or memory.
