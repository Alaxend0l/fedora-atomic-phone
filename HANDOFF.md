<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Handoff: state of the project (2026-11-20, 23:40 CET)

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
| Fedora kernel (uniLoader boot image; Rust binder + USB fix) | `boot_b` (sha256 `d01416bd…`, `fap-build/waffle/install-waydroid-net/boot_b/`; before: `c30a7be6…` `install-waydroid/`, `f870e95f…` `install/`; module backups in `/root/modules-*` on the phone) |
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
| Modem + ModemManager (QRTR), EFS served from RAM copies | works; auto-start only in the `oneplus12-tel` build |
| Brightness, flash LED, CPU thermal throttling at 90 °C | works in the `oneplus12-power` RAM build; not in the installed image yet |
| USB gadget (SSH over USB) on the installed boot | works since `qcom,select-utmi-as-pipe-clk` (same hidden dependency as the N100) |
| Wi‑Fi on the installed boot | works; Plasma's connection-details page stays blank (cosmetic) |
| Speakers/earpiece (TFA9874) | driver in `oneplus12-hw`, never played. **Only with the owner's explicit OK, lowest gain** (`FAP_SPEAKER_APPROVED=yes fap-hw-speaker-test`) |
| Sensors (SSC via hexagonrpcd/libssc) | **starting them reset the phone**; debug with dmesg -w over Wi‑Fi, then pstore |
| Cameras, USB‑C headset | built in `oneplus12-hw`, untested |
| GPS | `qmicli --loc-start` → QMI GeneralError; untested via ModemManager |
| SMS, data, calls | need a SIM; call audio + VoLTE missing; never rely on it for emergency calls |
| Waydroid | **works, with internet** (Rust binder; policy routing + legacy xtables for netd, oneplus12-dualboot 1616cdb; boot_b sha `d01416bd…` from `fap-build/waffle/install-waydroid-net/`) |
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
0. **Leave the slim kernel config** (owner's request, 2026-11-20): the slim
   config cost three rounds in one evening (binder → Rust, then Waydroid
   networking: policy routing + legacy iptables). Build with Fedora's full
   config (`fap-waffle-build.sh --full kernel …`, background, expect > 1 h),
   check `image_size` against uniLoader's 78 MiB limit (if too big: keep
   Fedora's config but move large built-ins to modules), then update the
   installed system (boot_b + all modules).
1. **Merge** `oneplus12-dualboot` (install + USB fix + Rust binder) with
   `-power` and `-tel`, rebuild, and update the installed system (boot_b +
   modules, as done on 2026-11-20 for Waydroid).
2. **Waydroid polish**: first-run checks, `fap-waydroid-init`, network (nftables NAT), GPU in the container.
3. userdata alignment (mkfs warned 80 KiB offset): measure I/O; repartitioning only with a plan.
4. Plasma Wi‑Fi details page blank; lm_sensors.service fails (harmless).
6. **No sound card on the installed boot** (works in RAM boot): sndcard
   deferred, "snd-sc8280xp: WCD Playback: codec dai not found" → WCD9395 didn't
   probe from flash. Suspects: pmic_glink altmode / USB‑C mux ("failed to
   acquire mode-switch"), SoundWire/LPASS clocks left on by ABL fastboot.
   Third RAM-vs-flash difference after USB pipe clock and the RTC.
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
