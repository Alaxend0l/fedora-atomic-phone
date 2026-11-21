<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12 (`oneplus-waffle`): port status and briefs for a local model

Written 2026-11-21 by Claude from a read-only pass over this repo at main
`948174e` (plus the unmerged branches named below). Nothing was run on the
phone. Audience: a local model (qwen via opencode, shell, **no web**) and the
owner. Line numbers drift: re-read a file before quoting it. Sibling file
`safety-audit.md` (another agent) covers safety in depth; this file does not
replace it.

**Source of truth, in order:** `HANDOFF.md` (2026-11-21) > the device docs
(`devices/oneplus-waffle/*.md`) > `features.yaml`, `README.md`, `TODO.md`,
`docs/status.md`, `docs/devices.md`, which are **stale** (they still say
"planned / nothing booted": `devices/oneplus-waffle/README.md:4`,
`features.yaml:301`, `device.env:24`). The lab notebooks the docs cite
(`~/Develop/OnePlus12/log/...`, `~/Develop/fap-build/...`) are on the
owner's Mac, **not on this workstation**: you cannot read them; don't guess
their contents.

Web note: every postmarketOS wiki URL tried (OnePlus 12 page, SM8650 page)
answered with a 301 to a third-party host (`wiki.nura.eco`); it was not
followed. No public OnePlus 12 port with sensors or cameras was found. Upstream
facts below come from the repo's own research notes (which cite lkml,
ModemManager MRs and rmtfs source) and kernel ABI docs.

---------------------------------------------------------------------------

## 0. STOP-LIST: what the local model must NEVER do

Each line is absolute. If a step seems to need one of these, stop and ask.

1. **No `fastboot`, `adb`, EDL/`edl`/QFIL, `qbootctl` (any write flag: `-s`,
   `-m`, `-u`), `bootctl`, `fap-switch-os lineage`, `dd`/`flash`/`mkfs`/
   `blkdiscard`/`sgdisk`/`parted`/`lptools`/`dmsetup` on any `/dev/sd*`,
   `/dev/block/*`, `/dev/mapper/*` or `/dev/disk/by-partlabel/*`.** These
   are S3 (owner only).
2. **Never run `boot/android-bootimg/rootfs/usr/libexec/fap-android-boot`**
   (`fap-android-boot:16-18,102-107`): its A/B logic flashes the *other* slot
   and switches to it. On this phone the other slot is LineageOS (`boot_a`).
3. **Never run `tools/flash.sh`, `tools/fap-dev ramboot`,
   `devices/oneplus-waffle/try-kernel.sh`** (it reboots into fastboot and
   swaps module trees: `try-kernel.sh:34-67`), `make-installroot.sh`,
   `move-flatpak-to-home.sh --apply`, or anything under `tools/recon/`.
4. **Never stop or restart the modem or its helpers**: no
   `echo stop > /sys/class/remoteproc/*/state`, no
   `systemctl stop|restart fap-rmtfs fap-efs-ram fap-tqftpserv`. Stopping the
   modem resets the whole phone (`installroot/usr/libexec/fap-modem-start:4-7`);
   restarting rmtfs under a running modem is fatal for the modem
   (`RESETS-GPS-RESEARCH.md:62-71`).
5. **No modem writes**: `qmicli --dms-set-*`, `--dms-activate-*`, `--pdc-*`,
   `--nas-set-*`, `--loc-set-*`, `--uim-*pin*`, `mmcli --factory-reset`,
   lpac `profile enable|disable|delete|download`, any DIAG/QPST tool. Never
   paste IMEI/ICCID/IMSI/phone numbers anywhere. Never dial an emergency
   number. (TELEPHONY.md on branch `oneplus12-tel`, "Safety rules".)
6. **Audio amps**: no speaker tests without the owner present and saying OK;
   never `i2cset`/`i2ctransfer`; never edit or disable
   `installroot/usr/share/wireplumber/wireplumber.conf.d/50-fap-waffle-speaker-dsp.conf`
   (speaker protection) or raise the UCM volume caps (`ucm/`); never play
   audio to an ALSA `hw:`/`plughw:` device (bypasses the protection filter).
7. **Never** use battmgr/pmic-glink debugfs charge controls; never
   `echo 1 > /sys/bus/pci/devices/*/remove` (hung the kernel); never
   `gpioset` (eSIM switch pins are on PMIC GPIOs: TELEPHONY.md "SIM/eSIM").
8. **Never start DSP sensor/audio experiments** (`hexagonrpcd`, `ssccli`,
   `fap-hw-sensors`, `fap-hw-speaker-test`, `aplay` of test tones): three
   hard resets so far came from such loads (`RESETS-GPS-RESEARCH.md:14-18`).
9. **No `sudo`** (the owner types the password himself), no `dnf install|
   upgrade|remove` on the phone, no `dnf install kernel*` ever (our kernel is
   not a Fedora package), no edits under `/etc`, `/usr` on the phone.
10. **No `git commit`, `git push`, branch merges or rebases** unless the
    owner asks in that session. Nothing goes to upstream projects.
11. Only one actor on the phone at a time: before any ssh, check that no
    other agent holds the `oneplus12` runner (atl-harness `HANDOFF.md`,
    "Runner use"). Anything that needs physical access (buttons, cables,
    listening, looking at the screen) = ask the owner.

Allowed for the local model on the phone (read-only, as user `phone`, via
`ssh atl-oneplus12` or atl-harness `scripts/rig -r oneplus12 ...`):
`cat`/`ls`/`grep` under `/sys`, `/proc`, `/run`; `dmesg` and
`journalctl -b [-k]` (if "permission denied": stop, ask the owner, don't
sudo); `systemctl status|is-active|--failed`; `ip -br addr`, `nmcli -t
device`; `mmcli -L`, `mmcli -m any` (redact ids); `qrtr-lookup`;
`bluetoothctl show|devices`; `pactl list short sinks`, `wpctl status`;
`df -h`, `findmnt`, `uptime`, `upower -d`. Bound every command with
`timeout 30`.

---------------------------------------------------------------------------

## 1. Risk classes and the real rollback story

| Class | Means | Who may do it |
|---|---|---|
| S0 | docs, repo config files, on-phone user-level reads; on-phone `/etc` drop-ins only when the owner applies them and a copy of the old file exists | local model (repo + reads), owner applies |
| S1 | kernel config, patches, DT, modules, initramfs: **source + build only** | Claude designs/debugs; local model may edit text it is told to; owner builds, RAM-tests, flashes |
| S2 | firmware files (`/usr/lib/firmware/...`, topology `.bin`, sensor configs), anything that starts/feeds a DSP or the modem (QMI sessions, hexagonrpcd, GNSS) | Claude plans, owner runs with `dmesg -w` streamed off the phone |
| S3 | `boot_b`/any partition, slots, `super`/LP metadata, vbmeta, userdata/`/home` layout, LineageOS | **owner only** |

**There is no ostree/bootc and no automatic A/B update on this phone.**
What exists (cited):
- Root = plain ext4 in logical partition `fap_root` inside `super` (8 GiB),
  `/home` = ext4 on the former userdata (`HANDOFF.md:46-52`,
  `installroot/etc/fstab`). Packages change with `dnf` in place: **no
  snapshot, no rollback** for userspace. A bad `dnf upgrade` is repaired by
  hand or by re-installing the root (S3). bootc on this phone is a future
  plan (`INSTALL.md:574-603`, "Later (bootc)"; decisions D1-D7 open,
  `HANDOFF.md:38-39`).
- Kernel+DTB+initramfs = one uniLoader image on `boot_b`; only one kernel
  slot (`INSTALL.md` §7: "we have only `boot_b`"). Updating it =
  `fastboot flash boot_b` from a PC (W4/W9). Previous images are kept on
  the Mac (`HANDOFF.md:13-14,71-73`).
- Safe pre-test: `try-kernel.sh` RAM-boots a candidate with `fastboot boot`
  (nothing flashed; modules go to a spare tree that `fap-modules-guard`
  swaps at boot: `installroot/usr/libexec/fap-modules-guard`). Needs PC,
  USB 2.0 cable (`HANDOFF.md:167`), owner.
- Fallbacks if `boot_b` is bad: (a) the 3 s boot menu in tiny-init (Vol Down
  = LineageOS, `INSTALL.md:399-420`, `fap.menu=3` in
  `dts/sm8650-oneplus-waffle-fap-install.dts:30`), but its `qbootctl` write
  is **untested** (`HANDOFF.md:67-68`); (b) ABL's retry counter: an unmarked
  slot b falls back to slot a after ≤ 7 boots (`INSTALL.md:422-462`); only
  the "mark successful" half is verified (`fap-boot-ok`, `HANDOFF.md:69-70`),
  the countdown is not; (c) bootloader `fastboot --set-active=a` or re-flash
  the last good `boot_b` (`HANDOFF.md:65-76`). **(c) needs a PC + fastboot.
  A hang in crashdump (05c6:900e) needs a 15 s Power+Vol Up hold. A bricked
  boot chain would need EDL, for which no tested tool exists
  (`devices/oneplus-waffle/README.md:240-246`): never risk it.**
- Never accept LineageOS recovery's "format data" (wipes Fedora `/home`,
  `HANDOFF.md:60-62`); LineageOS Updater is disabled on purpose
  (`HANDOFF.md:57-58`).

Consequence: on this phone, **every S1 change ends in an S3 step** (flash
`boot_b`). The local model never gets past "edited + reviewed + built".
Also note: main's install DT already includes the **untested** front-camera
DT (`dts/sm8650-oneplus-waffle-fap-install.dts:19-20`, commit `aa182d4`),
while the phone runs kernel #20 from `b7af6a7` (`HANDOFF.md:12-14`). The next
`boot_b` built from main is therefore not "the same plus a fix": RAM-test it.

---------------------------------------------------------------------------

## 2. Subsystems

Status words: **works** (owner/agent saw it on the installed system),
**partial**, **missing**. "RAM boot" = seen only in a `fastboot boot` test.

### 2.1 Display, brightness, touch, GPU, video
- Status: **works.** Panel (BOE AA545 via msm DSI), touch (S3910), Adreno
  750 (freedreno), Plasma Mobile "smooth" (`HANDOFF.md:81-82`); brightness
  and screen off/on installed and owner-tested (`HANDOFF.md:87`, patch
  `kernels/qcom-sm8650/patches/0010-*`). Iris video: works in RAM boot
  (`HANDOFF.md:85`). Open: touch inhibited while blanked? (`TODO.md:39`);
  60 Hz default for power (`TODO.md:44`); notch/rounded corners: **missing**,
  nothing in the repo handles the punch-hole or corners.
- Risk: notch/corners S0 (Plasma/KWin config); touch-while-off S0 to
  investigate, S1 if it needs a driver change.
- Next steps (local model, S0):
  1. Read-only: `cat /sys/class/drm/card*-DSI-1/status`,
     `cat /sys/class/backlight/*/brightness /sys/class/backlight/*/max_brightness`.
     Verify: `connected`, numbers present.
  2. Research (no web: use `man`, `/usr/share/doc`, `kwin` docs on the
     phone) whether Plasma Mobile 6.8 has a setting for a display cutout /
     top panel padding. Write findings in this file's §4 log. Stop: if it
     needs a KWin plugin or patch → Claude.
  3. Touch while blanked: owner turns the screen off and taps; the model
     reads `journalctl -b --since -2min` for wakeups. Stop: anything beyond
     reading logs.
- Who: local model (1-3 reads/docs), owner (physical), Claude (driver).

### 2.2 Audio: speakers, earpiece, mics, headset, Bluetooth audio
- Status: speakers + earpiece **works** (TFA9874 x2, SD1, MFC topology,
  `-12 dB` UCM cap, WirePlumber protection stage 0: `HANDOFF.md:22-25`,
  commits `a5e7a93`, `469dad4`, `99c7c7a`); topology override lives in
  `/usr/lib/firmware` on the phone (`HANDOFF.md:23`). Mics **works**
  (Mic1 bottom, Mic2 top, Mic3 both, `HANDOFF.md:27-28`, `2cc2252`). An ADSP
  crash leaves no sound card until reboot (`HANDOFF.md:20-21`). USB-C analog
  headset **missing** (needs i2c3 wcd939x-usbss, pmic-glink altmode, codec
  graph link; `dts/sm8650-oneplus-waffle-fap.dtsi:163-174`; attempt on
  unmerged `oneplus12-hw` `055c3ab`). Bluetooth audio: **untested** (BT
  itself works). Call audio: **missing** (TELEPHONY.md "Calls: audio and
  VoLTE"). Speaker protection stages 1+ open (`HANDOFF.md:39`).
- Risk: BT audio check S0. Protection tuning S2 (wrong values can damage
  amps). Headset S1 + loses nothing obvious but touches USB-C role logic: treat
  as S1 with USB risk (see 2.11). Call audio S2 (voice topology on ADSP).
- Next steps:
  1. (local model, S0) Read-only: `wpctl status`; check that the sink list
     shows "Speakers" (the filter) and **no** raw
     `alsa_output.platform-sound.HiFi__Speaker__sink` visible to clients.
     Stop: raw sink visible → tell the owner at once (protection bypassed).
  2. (local model, S0) After *any* pipewire/wireplumber package change on
     the phone, repeat step 1 (the filter config uses `node.software-dsp`;
     a WirePlumber upgrade can change it).
  3. (owner + local model, S0) BT audio: owner pairs headphones in Plasma;
     model reads `wpctl status`, `bluetoothctl info <MAC>` (redact MAC),
     `journalctl -b -u bluetooth`. Verify: a `bluez_output.*` sink, A2DP
     profile. Stop: errors about codecs/firmware → Claude.
  4. (Claude) headset and call audio designs. Not for the local model.
- Who: local model 1-3; owner listens; Claude 4.

### 2.3 Suspend, resume, battery life
- Status: **partial.** s2idle allowed via logind
  (`installroot/etc/systemd/sleep.conf.d/50-fap-waffle-sleep.conf`,
  `e90eb05`), RTC and power-key wake OK, DDR self-refresh works, **CX
  collapse blocked by the PCIe0 CESTA vote** (patch attempt reset the SoC),
  calls/SMS can't wake the phone, charging events end s2idle
  (`HANDOFF.md:29-34`, sleep conf comments). Owner set auto-suspend
  "never" (`HANDOFF.md:34`), so battery life is today's screen-off idle.
  `features.yaml:322` still says untested.
- Risk: measuring S0. CESTA/PCIe work S1 (and it reset the SoC once).
- Next steps (local model, S0):
  1. Battery drain log: every 10 min for a few hours, append
     `date; cat /sys/class/power_supply/*/capacity; cat /sys/class/power_supply/*/status`
     to a file in `/home/phone` (user-writable). Owner leaves the phone idle,
     screen off, unplugged. Verify: %/hour figure.
  2. Read-only after a manual suspend by the owner:
     `cat /sys/power/suspend_stats/*` (or `/sys/kernel/debug/suspend_stats`
     if readable), `journalctl -b | grep -i -E 'suspend|resume|PM:'`.
  3. Stop: any reset during suspend → go to 2.13 (crash capture), don't
     retry.
- Who: local model (logging, reading), owner (enable suspend, physical),
  Claude (CESTA, wake sources).

### 2.4 Charging and battery reporting
- Status: battery % **works** (`HANDOFF.md:83`), via ADSP + pmic-glink;
  charging happens (battery-manager events while charging,
  sleep conf note). Charge status, fast charging, charge limits: **not
  verified** (`features.yaml:345-347`).
- Risk: reading S0. Anything that sets a charger value: **forbidden**
  (`HANDOFF.md:169`, `TODO.md:22` "never set charger values ourselves").
- Next steps (local model, S0): `upower -d`; `grep . /sys/class/power_supply/*/{status,online,current_now,voltage_now,charge_type} 2>/dev/null`
  while the owner plugs/unplugs. Record to §4. Stop: values that look wrong
  (e.g. negative while charging) → report only; never write to these files.
- Who: local model + owner.

### 2.5 Wi‑Fi
- Status: **works** installed; Plasma connection-details page blank
  (cosmetic) (`HANDOFF.md:84,89,147`). Warm-reboot fix is patch 0001.
- Risk: S0 for the details page.
- Next: (local model) read-only `nmcli -t -f all device show wlp1s0`
  vs what Plasma shows; search plasma-nm logs
  (`journalctl --user -b | grep -i plasma-nm`). Stop at "cause found";
  propose, don't change.

### 2.6 Bluetooth
- Status: **works** (`HANDOFF.md:84`); address from `fap-bt-addr.service`
  (`2fb4fbc`); BlueDevil on at login (`2cc2252`).
- Next: BT audio (2.2 step 3). Nothing else open.

### 2.7 Modem: data, SMS, calls (rmtfs, qrtr, pd-mapper, tqftpserv, MM)
- Status: modem **starts at boot** and ModemManager sees it
  (`HANDOFF.md:86`; units `fap-efs-ram` → `fap-tqftpserv` → `fap-rmtfs`
  (`rmtfs -r`, read-only RAM copies of EFS) → `fap-modem-start` → MM;
  `installroot/usr/lib/systemd/system/fap-rmtfs.service`). pd-mapper is the
  in-kernel `qcom_pd_mapper`. MM kept off the GLINK AT ports
  (`installroot/usr/lib/udev/rules.d/78-fap-waffle-mm-ignore-wwan-at.rules`,
  `97e0c47`). SMS/data/calls: **untested, no SIM** (`HANDOFF.md:94`); VoLTE
  and call audio **missing**; calls/SMS can't wake from suspend. Spacebar,
  plasma-dialer packages are on unmerged `oneplus12-tel` (`03a59de`).
  Note: modem NV writes vanish at reboot (rmtfs `-r`), which is a safety
  feature, not a bug. For ATL, Fossify Messages/Phone wait on a telephony
  backend decision (atl-harness `HANDOFF.md`, "Waiting on the owner").
- Risk: reading S0; SIM tests S2 (owner's SIM, modem); anything EFS/NV S3.
- Next steps (local model, S0, read-only):
  1. `mmcli -L`; `mmcli -m any | grep -E 'state|power|primary port|ports'`;
     `qrtr-lookup | head -40`; `cat /sys/class/remoteproc/*/name /sys/class/remoteproc/*/state`.
     Verify: modem `running`, MM lists a modem, state `failed/sim-missing`
     without SIM. Redact equipment ids.
  2. Stop: modem `crashed`, MM restarting in a loop, or anything that seems
     to need a write → owner/Claude. Never "fix" by restarting units (§0.4).
- Who: owner (SIM, carrier tests per TELEPHONY.md), Claude (call audio,
  wake), local model (reads).

### 2.8 GPS (GNSS through the modem, QMI LOC)
- Status: **missing.** LOC service 16 registered; engine lock `mt`, mode
  `standalone` (not the cause); `--loc-start` → QMI error 46 GeneralError;
  event registration → error 48 InvalidArgument; MM offers only
  `3gpp-lac-ci` without a SIM (`RESETS-GPS-RESEARCH.md:218-232`).
  Hypothesis: needs a minimal event mask, or the rmtfs region also mapped to
  the NAV VM (`RESETS-GPS-RESEARCH.md:52-61`: "Do not add NAV blindly, because
  a wrong VMID assignment can itself crash").
- Risk: S2 (modem sessions; possible reset), NAV mapping S1+S2.
- Next: Claude writes a small libqmi client (register position-report+NMEA
  mask, then start); owner runs it outdoors with `dmesg -w` streamed. Local
  model: none beyond `qrtr-lookup | grep -i loc` (read-only). Stop: any
  modem crash → stop all GNSS work, capture per 2.13.

### 2.9 Sensors (accel/gyro/proximity/light via ADSP sensor PD)
- Status: **missing; dangerous.** Starting hexagonrpcd reset the phone
  (R1, `HANDOFF.md:91`). SM8650 has no SLPI: sensors live in the ADSP
  `sensor_pd`, the same DSP that runs charging/USB-C and audio, so a crash
  takes USB down (SENSORS-RESEARCH.md on unmerged `oneplus12-hw`, `399c633`).
  Staged plan exists there (serve `socinfo`, writable registry copy,
  recovery on, attach without `-s` first).
- Risk: **S2**, reset-prone. Not local-model work.
- Who: Claude + owner, after 2.13 crash capture is in place.

### 2.10 Cameras
- Status: **missing.** Stage 1 (front IMX615, D-PHY, csiphy4, i2c9; rear
  sensors and CCI off, EEPROM read-only) is in main's install DT, not built,
  not tested; libcamera not installed (`dts/sm8650-oneplus-waffle-fap-cameras.dtsi`,
  `aa182d4`, `HANDOFF.md:36-38`). Fossify Camera under ATL needs this.
- Risk: S1 (DT/kernel) → S3 to apply.
- Who: Claude (bring-up), owner (build, try-kernel RAM test, flash).
  Local model: none.

### 2.11 USB modes
- Status: **partial.** Gadget (SSH/USB networking) **works**: it is the ATL
  runner link (`atl-harness/runners.toml`, `oneplus12`). DT forces
  `dr_mode = "peripheral"`, `maximum-speed = "high-speed"`, no USB3 PHY, no
  role switch (`dts/sm8650-oneplus-waffle-fap.dtsi:80-108`). Host/OTG,
  SuperSpeed, DP alt mode, USB-C headset: **missing**.
- Risk: S1, **and a mistake removes the owner's USB link** (and the rig's).
  Claude-only design; RAM test first.

### 2.12 Thermal
- Status: **partial.** CPU passive trips at 90 °C with cpufreq cooling
  installed (`dts/sm8650-oneplus-waffle-fap-power.dtsi:27-176`,
  `HANDOFF.md:87`). Skin-temperature zone missing (`TODO.md:43`); GPU
  cooling not mentioned anywhere.
- Next (local model, S0): `grep . /sys/class/thermal/thermal_zone*/type`,
  `.../temp` during an ATL build on the phone (`make_jobs = 6`). Record max
  temps. Stop: any zone ≥ 95 °C → tell the owner, lower job counts.

### 2.13 Stability: spontaneous resets and crash capture
- Status: **partial.** Three resets R1-R3 (`RESETS-GPS-RESEARCH.md:14-18`);
  pstore now has panic records (`dts/sm8650-oneplus-waffle-fap.dtsi:201-214`),
  `panic=5 oops=panic` on the install cmdline (`...-install.dts:30`,
  `912f608`); GLINK and pm_clk fixes (`HANDOFF.md:18-21`).
- Risk: reading S0.
- Next steps (local model, S0, after every unexpected reboot):
  1. `uptime`; `ls -la /sys/fs/pstore`; `ls /var/lib/systemd/pstore`
     (Fedora's `systemd-pstore.service` archives pstore there: check
     `systemctl status systemd-pstore`); `journalctl --list-boots | tail -3`;
     `journalctl -b -1 -n 200 -o short-monotonic` (if readable).
  2. `grep . /sys/class/remoteproc/*/{name,state,recovery}`.
  3. Write a dated note (§4) with what was running (atl jobs? audio?
     modem?). Stop: none needed; never try to reproduce.
- Who: local model (collect), Claude (analysis), owner (sudo-only reads).

### 2.14 Clock (RTC)
- Status: **partial.** PMIC RTC reads 1970; `fap-clock` saves/restores time
  (`7d6f738`, `installroot/usr/libexec/fap-clock`), but time may lag until
  chrony syncs → TLS errors right after boot (`HANDOFF.md:154-157`).
- Next (local model, S0): after a reboot, `timedatectl`;
  `journalctl -b -u fap-clock-restore -u chronyd`. Verify: time correct
  before network. Stop at a written diagnosis.

### 2.15 Haptics, torch, LEDs, alert slider, fingerprint, NFC, IR
- Haptics: **works** (RAM boot, `HANDOFF.md:85`), stock 1.72 V vmax
  (`dts/...-fap.dtsi:142-148`). Use only built-in `fftest` effects.
- Torch: **works** installed, capped 100 mA/1 A (`...-power.dtsi:179-190`,
  `HANDOFF.md:87`). Do not raise caps.
- Notification LED: the repo lists none for this phone; treat as n/a
  [unverified].
- Alert slider: **missing**, needs a new MXM1120 hall-sensor driver on
  i2c_hub_8 (`TODO.md:42`). S1, Claude.
- Fingerprint, NFC (SN220), IR (SPI11, disabled `...-fap.dtsi:171`):
  **missing**, no plan, low value. S1+.

### 2.16 Storage, updates, Waydroid, repo hygiene
- Root 8 GiB was 97% full; Flatpak moved to `/home` (branch
  `oneplus12-flatpak-home` `122b9e3`, applied on the phone by hand, root
  52%: atl-harness `HANDOFF.md` "Done by the owner"). Branches
  `oneplus12-flatpak-home`, `plasma-mobile-spectacle`, `oneplus12-tel`,
  `oneplus12-hw` are **not merged** into main. Lockfiles need regenerating
  (`HANDOFF.md:102`). userdata alignment warning unmeasured
  (`HANDOFF.md:146`). Waydroid runs with internet and storage
  (`HANDOFF.md:95`).
- Risk: docs S0; merges = owner decision; repartitioning S3.
- Next (local model, S0):
  1. `df -h / /home`, `du -sh /var/cache/libdnf5 2>/dev/null` weekly. Stop:
     root > 85% → tell the owner (don't clean anything yourself).
  2. Docs refresh (repo only, no commit): update
     `devices/oneplus-waffle/features.yaml` statuses from §2 of this file and
     `HANDOFF.md`, with evidence = commit hashes; then
     `python3 tools/support-matrix.py --check` (pure doc generator/validator)
     and show the diff to the owner. Update `README.md:4` and
     `device.env:24` (`DEVICE_STATUS`) only if the owner agrees on the word
     (`usable` per `device.env:17-23`).

---------------------------------------------------------------------------

## 3. The five most valuable next tasks (daily use, ATL first)

The owner runs Android apps through ATL on this phone (atl-harness runner
`oneplus12`, rootfs `~/atl-root` in bwrap; 13/16 Fossify apps work; Camera,
Phone, Launcher don't). Ranked by value to that, then to daily use.

1. **ATL audio goes through PipeWire, never `hw:` (S0, local model + owner
   listens).** atl-harness task #1 (Music is silent;
   `atl-harness/docs/agent-tasks/audiotrack.md`, "Also found on the phone").
   Phone-side checks: `ls ~/atl-root/usr/lib64/alsa-lib | grep -i pipewire`;
   while an ATL app plays, `wpctl status` shows its stream feeding the
   "Speakers" filter node. **Safety link:** an ATL build that opens
   `hw:0,*` would bypass the speaker protection (§0.6): stop and report if
   `pactl list short sinks` or the ATL log shows a `hw:` device. Stop: no
   sound with a correct graph → Claude.
2. **Crash capture routine (S0, local model).** §2.13 after every reset;
   long ATL builds/gates on the phone are the main load now, so record what
   ran. Stability is what decides if the phone can be a runner and a daily
   driver at once.
3. **Front camera stage 1 (S1→S3, Claude + owner).** §2.10; unblocks
   Fossify Camera under ATL (and video calls later). RAM-test with
   `try-kernel.sh` first; the next `boot_b` from main includes it anyway.
4. **Root/space and update hygiene (S0 local model; merges by owner).**
   §2.16: keep root below 85%, re-check speaker protection after any
   pipewire/wireplumber update (§2.2 step 2), merge the two branches already
   applied by hand, regenerate lockfiles. Prevents silent breakage of the
   rig rootfs and Flatpaks.
5. **Battery/suspend baseline + clock (S0 local model, owner enables
   suspend).** §2.3 drain log and §2.14 clock diagnosis: daily-driver
   comfort and TLS for apps with internet right after boot.

Next in line: Bluetooth audio check (§2.2.3, S0); GPS (§2.8, S2, Claude);
telephony backend for Messages/Phone (owner decision, needs a SIM); sensors
(§2.9, S2, only after task 2 is routine).

---------------------------------------------------------------------------

## 4. Log (append findings here, newest first; no ids, no locations)

| Date | Who | Section | Finding |
|---|---|---|---|
| 2026-11-21 | Claude | all | file created from a desk read of main `948174e`; nothing run |
