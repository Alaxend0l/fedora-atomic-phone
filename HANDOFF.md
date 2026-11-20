<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Handoff: state of the project (2026-11-21, 00:40 CET)

Read this first, then `AGENTS.md` and `docs/status.md`. The phone-side lab
notebooks (not in git; contain unit data) are `~/Develop/OnePlus12/`
(`AGENTS.md` = safety rules, `log/2026-11-20-recon.md` = everything tested),
`~/Develop/Pixel8/` and `~/Develop/UBports-N100/`.

## Headline
**Fedora (Plasma Mobile, GPU-accelerated) is installed on the OnePlus 12
(waffle) and boots from storage**, with Waydroid. LineageOS's system is
still on slot a, but its data was given up for Fedora (owner's choice):

| What | Where |
|---|---|
| Fedora kernel (uniLoader boot image; **full Fedora config + power patches** since 2026-11-21, sha `dde4b84b…`, `install-full-power/`) | `boot_b` (sha256 `d01416bd…`, `fap-build/waffle/install-waydroid-net/boot_b/`; before: `c30a7be6…` `install-waydroid/`, `f870e95f…` `install/`; module backups in `/root/modules-*` on the phone) |
| Fedora root (ext4, label `fap-root`, 8 GiB) | logical partition `fap_root` in `super` (raw sha256 `cd29c50f…`) |
| Fedora `/home` + Waydroid images (`/home/.waydroid-images`) | ext4 `fap-home` on the former **userdata** (`/dev/sda14`, 447 GiB), fstab `nofail` |
| LineageOS 23.2 (rooted: Magisk + KernelSU) | slot a system unchanged; **its userdata is gone** |
| Active slot | **b** |

Install log with every command and hash: `~/Develop/OnePlus12/log/install-20261120/`.
Runbook and design: `devices/oneplus-waffle/INSTALL.md` (branch
`oneplus12-install`), `~/Develop/fap-build/waffle/install/INSTALL-RUNBOOK.md`.
LineageOS's Updater app is disabled (`pm disable-user`), because an OTA would
rewrite slot b. Re-enable: `adb shell pm enable org.lineageos.updater`.

**Never accept LineageOS recovery's "factory reset / format data" prompt**
(shown if the phone ever boots slot a now): it reformats userdata = Fedora's
`/home` and Waydroid data.

### Switching / recovery
- To LineageOS: bootloader (`Power + Vol Down` or `fastboot`), then
  `fastboot --set-active=a && fastboot reboot`. Back: `--set-active=b`.
- The boot menu (3 s, volume keys) and `fap-switch-os` exist but `qbootctl`
  writes (`-s a`, `-m b`) are **untested** (W6 in the runbook).
- `fap-boot-ok.service` marks slot b successful ~60 s after a healthy boot
  (verified twice). Flashing boot_b resets the flag until the next healthy boot.
- Previous kernel: `fastboot flash boot_b ~/Develop/fap-build/waffle/install/boot_b/fap-boot_b.img`
  plus the old modules (`/root/modules-7.4.0-rc3-fap-waffle+.old-20261120` →
  `/usr/lib/modules/7.4.0-rc3-fap-waffle+`; same release string).
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
| Modem + ModemManager (QRTR), EFS served from RAM copies | **starts at boot on the installed system** (fap-rmtfs etc.); no SIM to test SMS/data |
| Brightness, screen off/on, flash LED, CPU thermal throttling at 90 °C | **installed** (owner tested brightness + screen off/on); suspend still disabled on purpose |
| USB gadget (SSH over USB) on the installed boot | works since `qcom,select-utmi-as-pipe-clk` (same hidden dependency as the N100) |
| Wi‑Fi on the installed boot | works; Plasma's connection-details page stays blank (cosmetic) |
| Speakers/earpiece (TFA9874) | first test 2026-11-20 (owner's OK, -40 dBFS, bottom): amp on/off fine, **TDMERR** → silent; OVERTEMP/UNDERVOLTAGE already latched while off. v9 (oneplus12-hw 0b8c7c2) runs SECONDARY_MI2S at 2x32 bit as OnePlus does → **phone hard-reset during the first tone** (no pstore; likely ADSP fatal). Next: A/B with `waffle_sec_mi2s_bits=16`, add a format converter to the topology graph, watch remoteproc crash reason. Flags OTDS/UVDS are OK-flags (old decoding was wrong) |
| Sensors (SSC via hexagonrpcd/libssc) | **starting them reset the phone**; debug with dmesg -w over Wi‑Fi, then pstore |
| Cameras, USB‑C headset | built in `oneplus12-hw`, untested |
| GPS | `qmicli --loc-start` → QMI GeneralError; untested via ModemManager |
| SMS, data, calls | need a SIM; call audio + VoLTE missing; never rely on it for emergency calls |
| Waydroid | **runs, with internet**; density 480 (`waydroid_base.prop`); "Stop Waydroid" launcher. Android storage **fixed** (waydroid#2453, OMX HAL removed via the vendor overlay, `fap-waydroid-omx-fix` before each container start, b1b1dac). History: (MediaProvider's ExternalStorageService times out in StorageUserConnection; browser downloads crash, Files hangs). Tried: session/container restarts (worked once briefly), `persist.sys.fuse=false` (Android 13 ignores it), `persist.sys.fuse.passthrough.enable=false` (no change). Next: MediaProvider/FuseDaemon logcat with `-v threadtime` from session start, compare FUSE ioctls (Android passthrough vs mainline backing-file API), try the Waydroid image's newer build. Earlier: (Rust binder; policy routing + legacy xtables for netd, oneplus12-dualboot 1616cdb; boot_b sha `d01416bd…` from `fap-build/waffle/install-waydroid-net/`) |
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
0. **Done 2026-11-21: the installed kernel uses Fedora's full config**
   (`--full`, 17 min build, image_size 65 of 78 MiB; boot_b sha `7feeffad…`).
   Kernels sharing a release string share one module tree, so
   `fap-modules-guard` (early boot) swaps in the tree whose `.fap-kver` matches
   `uname -v`; `devices/oneplus-waffle/try-kernel.sh` RAM-tests a candidate
   with a 9-point feature check (oneplus12-dualboot e0d7956). Slim kernel
   rollback: flash `install-waydroid-net/boot_b/fap-boot_b.img`.
1. Done 2026-11-21: `oneplus12-power` merged into `oneplus12-dualboot` and installed;
   clock save/restore (`fap-clock`), modem at boot (from `oneplus12-tel`).
   Still to merge: `oneplus12-hw` (speakers/sensors/cameras) and the branches into main.
2. **Waydroid polish**: first-run checks, `fap-waydroid-init`, network (nftables NAT), GPU in the container.
3. userdata alignment (mkfs warned 80 KiB offset): measure I/O; repartitioning only with a plan.
4. Plasma Wi‑Fi details page blank; lm_sensors.service fails (harmless).
6. Fixed on the phone and in `oneplus12-dualboot` (installroot overlay):
   no sound card (soundwire-qcom + LPASS macros never loaded →
   `etc/modules-load.d/fap-audio.conf`, 2326ce6) and Bluetooth unusable
   (WCN7850 "unconfigured": no local-bd-address in our DT → `fap-bt-addr.service`,
   2fb4fbc). Speakers still need the TFA9874 driver (oneplus12-hw) + owner's OK.
7. p11-kit-server was missing (Flatpak CA trust; fixed, dualboot 7329700).
5. Clock: PMIC RTC reads 1970 (not writable for us; Android keeps an offset), so
   time starts ~1 month behind until chrony syncs → TLS errors in Firefox right
   after boot. Fix: keep `/var/lib/systemd/timesync/clock` fresh (PID 1 uses its
   mtime as the minimum time), or the rtc-pm8xxx offset from nvmem/SDAM.
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
