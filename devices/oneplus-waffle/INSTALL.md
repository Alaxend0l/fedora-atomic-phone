<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12 (waffle): dual-boot install plan (LineageOS on slot a, Fedora on slot b)

Status: **plan only, 2026-11-20. Nothing in this file has been run on the
phone.** It was written at the desk from the read-only backup
(`~/Develop/OnePlus12/backup/partitions-20261120/`, 144 images +
SHA256SUMS), the recon log (`~/Develop/OnePlus12/log/2026-11-20-recon.md`),
the dossier (branch `oneplus12-research`:
`devices/oneplus-waffle/research/boot-and-flashing.md`, `unbrick-tools.md`),
the RAM-boot bisect log (`~/Develop/fap-build/waffle/bisect/BISECT.md`,
v1–v7), the LineageOS device trees in `fap-build/research/oneplus12/`, and the
N100 history (`docs/porting-cookbook.md`, `devices/oneplus-billie2/hidden-dependencies.md`,
`docs/hardware/n100-power-and-install.md`).
Labels: **[seen]** read from this unit's data, **[src]** a source says so
(named), **[guess]** inference, must be checked.

The user's choices: LineageOS stays on slot a, untouched. Fedora (Plasma
Mobile) boots from slot b. Switching OS = changing the active slot, and it
must work on the phone alone (no PC) once installed.

Contents:
1. [Slot-b safety gate (done offline)](#1-slot-b-safety-gate-done-offline)
2. [Where Fedora's root lives](#2-where-fedoras-root-lives)
3. [Boot: what goes on slot b and how the root is found](#3-boot-what-goes-on-slot-b-and-how-the-root-is-found)
4. [Boot-mode matrix (before and after any write)](#4-boot-mode-matrix)
5. [Switching OS without a PC, and the automatic fallback](#5-switching-os-without-a-pc-and-the-automatic-fallback)
6. [Every write (W1–W9) with backup, restore and go/no-go](#6-every-write)
7. [Updates and rollback](#7-updates-and-rollback)
8. [Measurements the main session must take first](#8-measurements-the-main-session-must-take-first)

---------------------------------------------------------------------------

## 1. Slot-b safety gate (done offline)

Setting slot b active makes the phone run **every** `_b` image from the
primary boot loader on: on UFS the active slot also selects the boot LUN
(LUN 1 = `xbl_a`, LUN 2 = `xbl_b`), so `xbl_b`, `xbl_config_b` (which carries
the anti-rollback value), `abl_b`, `tz_b`, `hyp_b`… would run. If any of them
were older than slot a's, a slot switch could hit the ARB fuse (ARB = 1 on this
unit) and end in EDL (9008), for which there is no safe tool
(`unbrick-tools.md`). So the gate is: every boot-chain and firmware pair must
be byte-identical.

### Method
Compared the `_a`/`_b` image pairs of the 2026-11-20 backup three ways:
entries in `SHA256SUMS`, `cmp` of the files, and for the boot LUNs the
partition areas of the whole-LUN images `sdb.img` (LUN 1) and `sdc.img`
(LUN 2) after parsing their GPTs. Kernel-side images were also parsed
(boot header v4, vendor_boot v4, AVB footers, `vbmeta` descriptors). Scripts:
throwaway (`/tmp/op12ab/{parse,avb,gpt}.py`), not kept.

### Result: **PASS** [seen]
| Group | Pairs | a vs b |
|---|---|---|
| Boot chain | xbl, xbl_config, xbl_ramdump, uefi, abl, tz, hyp, devcfg, aop, aop_config, keymaster, uefisecapp, cpucp, cpucp_dtb, shrm, qupfw, imagefv, featenabler, multiimgoem, multiimgqti, oplus_sec, oplusstanvbk, engineering_cdt, splash, vm-bootsys, pvmfw, rticmpdata, spuservice, qweslicstore, mdtp, mdtpsecapp | **all identical** |
| Boot LUNs | LUN 1 vs LUN 2, sectors 6–1696 (xbl, xbl_config, multiimgqti/oem, apdp/apdpb) | **identical** (only the GPTs differ, as they must) |
| Firmware | modem, dsp, bluetooth | **identical** |
| AVB | vbmeta, vbmeta_system, vbmeta_vendor | **identical**; `vbmeta` flags = 3 (hashtree + verification disabled) on both |
| Kernel side | dtbo, recovery | **identical** |
| Kernel side | **boot, init_boot, vendor_boot** | **differ** (explained below; not boot chain) |

Why the three kernel-side pairs differ: **slot a is root-patched, slot b is
pristine LineageOS** [seen]:
- `boot_a` has a 360 KB ramdisk with Magisk (`overlay.d/sbin/magisk.xz`,
  `.backup/.magisk`); `boot_b` has no ramdisk. Same kernel in both
  (6.1.173-g84220fe763ed, built 2026-06-25).
- `init_boot_a` is Magisk-patched (`.backup/init.xz`); `init_boot_b` is stock.
- `vendor_boot_a`'s ramdisk has two extra files, `init` and `kernelsu.ko`
  (KernelSU, LKM mode); `vendor_boot_b` is stock.
- Proof that b is the pristine build: `init_boot_b` and `vendor_boot_b` match
  the hash descriptors in `vbmeta_b` (LineageOS
  `OnePlus/lineage_waffle/waffle:16/BP4A.251205.006/0524f183d2`, patch
  2026-06-01); `init_boot_a`/`vendor_boot_a` don't. `boot_b`'s AVB footer
  digest equals the one `boot_a`'s footer carries (Magisk kept the original
  footer).

Consequences:
1. Switching to slot b runs exactly the same boot chain and firmware as slot
   a. **set_active b is allowed** (after the per-write checks in W5).
2. The backup's `boot_b.img`, `init_boot_b.img`, `vendor_boot_b.img` are the
   only pristine LineageOS 20260625 kernel images we have (that nightly is
   likely gone from the download server). Keep them; they're also the way to
   un-root slot a if ever wanted (not part of this plan).
3. Someone installed Magisk **and** KernelSU on slot a. Both apps offer
   "Install to inactive slot (after OTA)", which would overwrite `boot_b` /
   `vendor_boot_b`. **Never use that** while Fedora lives on b (M12 checks
   which root apps are present).
4. GPT slot attributes at backup time (LUN 4 = `sde`, byte 6 of the attribute
   field, Qualcomm layout: bits 0–1 priority, bit 2 active, bits 3–5 retry
   count, bit 6 successful, bit 7 unbootable) [seen]:
   | Partition | Attr byte | Meaning |
   |---|---|---|
   | `boot_a` | `0x77` | priority 3, **active**, retry 6, successful |
   | `boot_b` | `0x7b` | priority 3, inactive, retry 7, successful, bootable |
   | other `_a` (e.g. `abl_a`) | `0x7f` | priority 3, active, retry 7, successful |
   | other `_b` | `0x7b` | as `boot_b` |
   | `xbl_a` (LUN 1) / `xbl_b` (LUN 2) | `0xc4` / `0xc0` (+ bit 60) | active bit tracks the slot on the boot LUNs too |
   Slot state is mirrored into every `_a`/`_b` entry on LUNs 1, 2, 3 (sdd:
   `engineering_cdt`), 4 and 5 (sdf: `oplusstanvbk`); ABL reads `boot_x`.

If a future backup shows **any** boot-chain/firmware pair differing (e.g.
after an OxygenOS firmware update that only reached one slot): **do not set
slot b active.** Safe alternatives, in order: (1) bring both slots to the
same firmware the LineageOS way (`fw_update`, from fastbootd with
`--slot=all`, only from a build ≥ ARB 1; needs its own plan); (2) keep
Fedora RAM-booted only (`fastboot boot` of the same image, root on the phone
as in section 2), which never touches slot flags; (3) Fedora on slot a and
LineageOS on b is *not* an alternative (it moves the risk, doesn't remove it).

---------------------------------------------------------------------------

## 2. Where Fedora's root lives

Facts about LineageOS's storage [seen in `getprop.txt` + src LineageOS
`sm8650-common/init/fstab.qcom`, `BoardConfigCommon.mk`, `common.mk`]:
- LUN 0 (`sda`, ~483 GB) holds `persist` (sda2, **identity**), `metadata`
  (sda10), `super` (sda13, 16 GiB) and `userdata` (sda14).
- `/data` is f2fs with **file-based encryption v2 + `metadata_encryption=aes-256-xts:wrappedkey_v0`**,
  hardware-wrapped keys (`inlinecrypt_optimized+wrappedkey_v0`), key directory
  `/metadata/vold/metadata_encryption`, `checkpoint=fs`.
  `ro.crypto.metadata.enabled=true`, `ro.crypto.type=file`.
- `super`: one group `qti_dynamic_partitions` (size = super − 4 MiB) with
  odm, product, system, system_dlkm, system_ext, vendor, vendor_dlkm.
  **Virtual A/B** (`virtual_ab_ota/launch_with_vendor_ramdisk.mk`,
  `ro.virtual_ab.enabled=true`): slot b's logical partitions normally don't
  exist; OTAs build them as snapshots (in super free space, else as COW files
  in `/data`).
- `AB_OTA_PARTITIONS` includes boot, init_boot, vendor_boot, dtbo, recovery,
  vbmeta, vbmeta_system, vbmeta_vendor: **a LineageOS OTA rewrites all of
  slot b's kernel-side images and switches to b.**

### Options
**(a) ext4 image file in an unencrypted directory of `/data`** (Ubuntu Touch
style). **Rejected: not possible on this phone.**
- Metadata encryption puts all of `userdata` behind dm-default-key with a key
  that only KeyMint (a Qualcomm TEE app) can unwrap. Mainline Linux has no
  client for it, so our kernel can't read *any* block of `/data`, encrypted
  directory or not. An "unencrypted dir" only escapes FBE (the per-file
  layer), not the metadata layer below it.
- Even without that: our kernel has `F2FS_FS`, `FS_ENCRYPTION` and `UNICODE`
  (casefold) all unset (`fap-build/waffle/parts/kernel.config`) [seen], f2fs
  `checkpoint=fs` would need care, and init/vold set an encryption policy on
  top-level `/data` dirs created by init (a dir created later by root keeps
  none [guess]). M4/M5 below confirm the dm-default-key target and the f2fs
  feature list, for the record.

**(b) A logical partition `fap_root` in `super`'s free space. Recommended.**
- How: from LineageOS recovery's **fastbootd** (stock AOSP tool):
  `fastboot create-logical-partition fap_root <bytes>` then
  `fastboot flash fap_root fap-root.simg`. fastbootd adds the partition to the
  `default` group with no slot suffix and writes the LP metadata to all
  metadata slots [src: AOSP `fastboot/device/commands.cpp` +
  `utility.cpp` `UpdateAllPartitionMetadata`, from memory: verify with
  `lpdump --slot=0/1` after W1].
- Fedora maps it with dm-linear from the LP metadata (section 3), so writes
  can never leave the partition's extents.
- LineageOS keeps `/data`, its encryption and all its data. LineageOS's first
  stage init will create `/dev/block/mapper/fap_root` (it maps every logical
  partition of the slot) and otherwise ignore it [guess].
- Size: free space in super = 16 GiB − LineageOS's partitions − metadata;
  expected 8–11 GiB [guess: Lineage builds are small; M2 measures it]. The
  Plasma Mobile root is ~1 GB compressed, ~3–4 GB unpacked [seen:
  `plasma-netroot-gpu` 1.2 GB tarball]; 8 GiB is enough for one deployment
  plus some apps, tight for bootc with two deployments. **Go only if
  `fap_root` can get ≥ 8 GiB** while leaving 256 MiB free.
- Risks:
  1. **LineageOS OTA.** update_engine rebuilds slot b's metadata. It removes
     and recreates the `qti_dynamic_partitions_b` group; a partition in the
     `default` group should survive and its extents count as used, so COW goes
     to `/data` [guess from AOSP liblp/libsnapshot, not verified]. And the OTA
     overwrites Fedora's `boot_b` in any case. Rule: **LineageOS OTAs are off
     while Fedora is installed** (W0 disables the Updater; section 7 has the
     update procedure).
  2. **Writing LP metadata.** A bad metadata write makes LineageOS unbootable
     (level 2, not a brick). Mitigations: done by Android's own fastbootd, full
     `super` image and the LP metadata area backed up first (W0), restore =
     `fastboot delete-logical-partition fap_root` or writing the saved metadata
     area back.
  3. Anything that reflashes super (a LineageOS clean install, `fastboot
     flash super`) deletes `fap_root`. Back up Fedora's home first.

**(c) Others considered**
| Option | Verdict |
|---|---|
| c1. Shrink `userdata` in LUN 0's GPT and add a `fap_root` partition at the end | Fallback if (b) gives < 8 GiB. Costs a **wipe of LineageOS's data** (userdata must be re-formatted; f2fs can't shrink, metadata encryption regenerates keys), and a GPT write on the LUN that also holds `persist`. Any size possible. Needs the LUN 0 GPT backed up (missing today: M8) |
| c2. Unused slot partitions (`recovery_b` 100 MiB, `vm-bootsys_b` 537 MiB, `logdump` 512 MiB) | too small; `vm-bootsys` is firmware |
| c3. USB-C SSD | tethered; not a phone |
| c4. netroot / RAM | development only (what we have now) |
| c5. Fedora on `userdata`, LineageOS gone | not what the user chose |

**Recommendation: (b) `fap_root` in super, ext4, label `fap-root`, created
and flashed from LineageOS recovery's fastbootd.** Fall back to (c1) only with
the user's explicit OK to lose LineageOS's data.

---------------------------------------------------------------------------

## 3. Boot: what goes on slot b and how the root is found

### Images on slot b
| Partition | Change | Why |
|---|---|---|
| `boot_b` | **our image** (W4) | header v4, kernel = uniLoader (relocation-safe, as v2–v7) carrying our Image + DTB + initramfs; os_version 16.0.0, patch level 2026-06 (ABL wants non-zero values) |
| `vendor_boot_b` | none | ABL still loads it and builds the *stock* DT from it + `dtbo_b`; uniLoader throws that DT away. It must stay a valid stock image: it is (pristine LineageOS, §1) |
| `init_boot_b` | none | ABL loads its ramdisk; uniLoader ignores it |
| `dtbo_b` | none | same as `dtbo_a`; `DTBO_MODE=stock` (no erase, unlike the N100) |
| `vbmeta_b` | none | already flags 3 (verification disabled), same as `vbmeta_a`. With flags 3, libavb loads `boot` as a whole partition and ignores footers [src: libavb `avb_slot_verify.c`, from memory] |
| `recovery_b`, `vbmeta_system_b`, `vbmeta_vendor_b` | none | |

Boot image file: build `fap-boot_b.img` = the boot image **zero-padded to the
full partition size, 201326592 bytes**. Then (1) no stale bytes of LineageOS's
`boot_b` (including its old AVB footer at the end) survive the write, (2) the
read-back hash of the whole partition must equal the file's hash, and
(3) the *same 192 MiB file* is what the RAM-boot matrix tests (`fastboot boot`
takes it: max-download-size is 768 MiB [seen]). Optionally add an AVB hash
footer (`avbtool add_hash_footer --partition_name boot --partition_size 201326592
--rollback_index 1780272000`, test key) the way LineageOS does; not needed with
vbmeta flags 3 [guess], but harmless.

AVB/orange state: the bootloader is unlocked (`oplusboot.verifiedbootstate=orange`
[seen]). A normal boot of slot b shows the same "unlocked" warning screen
LineageOS shows today, then boots. Nothing to change; **never relock**.

### Kernel command line
uniLoader passes our DTB, so `/chosen/bootargs` is the command line
(`CMDLINE_IN=dtb`); ABL's cmdline/bootconfig never reach our kernel. For the
installed image:
```
console=tty0 loglevel=4 fbcon=font:TER16x32 clk_ignore_unused pd_ignore_unused regulator_ignore_unused nokaslr fap.root=lp:fap_root fap.menu=3
```
(`*_ignore_unused` stay until the hidden-dependency audit in §4 says they can
go; dropping them is a separate, RAM-only experiment.)

### Initramfs: `fap.root=lp:<name>` (tiny-init extension)
Today tiny-init understands `fap.root=LABEL=…|/dev/…` (ext4) and
`fap.netroot=`. New form, `fap.root=lp:fap_root`:
1. Find super: scan `/sys/class/block/*/uevent` for `PARTNAME=super`
   (busybox `findfs` doesn't do PARTLABEL).
2. `fap-lpmap super-dev fap_root` (new, small static C helper in
   `boot/android-bootimg/`, our own code, AGPL): reads the LP geometry (offset
   4096) and metadata slot 0 **and** slot 1, finds `fap_root` in both, refuses
   unless both list identical extents, refuses non-linear extents, then creates
   `/dev/mapper/fap_root` (DM_DEV_CREATE / DM_TABLE_LOAD / DM_DEV_SUSPEND
   ioctls; LP sectors and dm sectors are both 512 bytes). Read-write.
   Reference for the idea (not code): postmarketOS `make-dynpart-mappings`.
3. Check before mounting: ext4 superblock label must be `fap-root`
   (`blkid`), else stay in the initramfs.
4. Mount `-t ext4 -o rw,noatime`, switch_root to systemd (as now).

Kernel config: `CONFIG_BLK_DEV_DM=y` (now `=m`; dm-linear is in dm-mod) in
`build-env/waffle.config`. Keep `BLK_DEV_LOOP=y`. No f2fs needed.
Robustness: if `fap_root` is missing, mismatched or not ext4, tiny-init shows
the reason on screen and falls into the boot menu's failure branch
(§5.3: LineageOS / debug shell), never into a write.

A user-space cross-check: `fap-lpcheck.service` (Fedora) re-reads the LP
metadata of super with a short Python script and logs an error if the mapping
in use differs (e.g. after a LineageOS OTA touched super).

---------------------------------------------------------------------------

## 4. Boot-mode matrix

The N100 lesson: what worked under `fastboot boot` failed or was slow after a
normal boot from flash, because ABL leaves different state on in fastboot mode
(USB3 PHY pipe clock: USB dead; GPU had no bandwidth vote: slow) and because
an installed root starts services earlier than a netroot does (modem
stalled). Rules that make this impossible to repeat here:
1. **One file.** The matrix runs `fap-boot_b.img` (192 MiB, padded), the very
   file W4 writes, identified by its sha256. After W4 the partition is read
   back and must hash to the same value.
2. **One root.** All modes boot the installed `fap_root` (`fap.root=lp:fap_root`),
   not the netroot, so service ordering is the installed one.
3. **Every mode, every check, diffed.** A difference between modes is a
   finding to explain before the next step, even if every feature "works".
4. **A strict proxy before writing.** Mode S is the same image with
   `clk_ignore_unused pd_ignore_unused regulator_ignore_unused` removed (a
   separate test image, RAM only): anything the kernel doesn't claim gets
   switched off, which approximates "ABL didn't leave it on".

### Modes
| Mode | How | When |
|---|---|---|
| i. RAM, from LineageOS | `adb reboot bootloader` → `tools/fap-dev ramboot fap-boot_b.img` | before W4 (and after, as a regression) |
| ii. RAM, warm from our Linux | from mode i: `systemctl reboot --reboot-argument=bootloader` → `fap-dev ramboot` | before W4 |
| S. RAM, strict | as i with the strict image (diagnostic; failures are findings, not blockers) | before W4 |
| iii. Normal boot of slot b | after W5: `fastboot reboot` (from bootloader) and `systemctl reboot` (from Fedora) | after W5 |
| iv. Cold boot | `systemctl poweroff`, unplug USB, wait 30 s, Power key | after W5 |
| v. Off-mode charging | phone off, plug charger: ABL boots the kernel in charger mode; ours will start Fedora fully [guess] | after W5, note behaviour only |
| vi. Fallback | slot b with a deliberately broken root (`fap.root=lp:nonexistent`, RAM boot only) → boot menu failure branch; and the retry-count test (§5.4) | after W5 |

USB 2.0 cable for every fastboot step (USB 3 crashes ABL's fastboot [seen]).

### Checks per mode (all as root over `tools/fap-dev ssh`)
| Feature | Pass | Command |
|---|---|---|
| Kernel/image identity | same `uname -a`, same `/proc/cmdline` | `uname -a; cat /proc/cmdline` |
| Memory | MemTotal ≈ 14.9 GB (14935 MB in v3) | `free -m` |
| Display (msm) | `card*-DSI-1` connected, fbcon/Plasma on msm, not simpledrm | `ls /sys/class/drm; cat /sys/class/drm/card*-DSI-1/status` |
| GPU FD750 | renderer FD750, glmark2 score within 10 % of mode i | `eglinfo -B \| grep -i renderer; glmark2-es2-drm -b build:duration=5` |
| Touch | S3910 events | `evtest` on the Synaptics node, 5 s of touches |
| USB gadget + DHCP | host gets 172.16.42.2 from `fap-usb-dhcp`, SSH works, link speed noted | host: `ifconfig`; phone: `systemctl status fap-usb-dhcp`; `cat /sys/class/udc/*/current_speed` |
| Wi-Fi | `wlp1s0` present, joins, DHCP, ping | `iw dev; nmcli dev wifi list; ping -c3 1.1.1.1` |
| Bluetooth | hci0 up, scan finds devices | `bluetoothctl show; bluetoothctl --timeout 15 scan on` |
| Modem | remoteproc modem running, QRTR node up, **started by the installed unit, no "stalled initialization"** | `grep . /sys/class/remoteproc/*/{name,state}; qrtr-lookup; journalctl -b \| grep -iE 'DOG\|stall\|rmtfs'` |
| Battery | capacity/status sane | `cat /sys/class/power_supply/qcom-battmgr-bat/{capacity,status}` |
| Audio card | card "OnePlus 12", Mic1 record has signal | `aplay -l; arecord -l` + the v6 Mic1 test |
| Haptics | short buzz at stock vmax | `fftest` (built-in effect only) |
| Storage | UFS sequential read within 10 % of mode i | `dd if=/dev/mapper/fap_root of=/dev/null bs=4M count=256 iflag=direct` |
| Boot | `systemctl --failed` empty, `systemd-analyze` | |
| Keys | Power, Vol Up, Vol Down events (needed by the boot menu) | `evtest` |

### Hidden-dependency audit (per mode, then diffed)
`tools/fap-dev audit > audit-<mode>.md` (tools/recon/hidden-deps-audit.sh)
plus raw copies of:
- `/sys/kernel/debug/clk/clk_summary` (enabled clocks without a consumer:
  the `clk_ignore_unused` suspects),
- `/sys/kernel/debug/interconnect/interconnect_summary` (GPU, display, UFS,
  USB votes must be identical across modes),
- `/sys/kernel/debug/pm_genpd/pm_genpd_summary`,
  `/sys/kernel/debug/regulator/regulator_summary`,
- `/sys/kernel/debug/devices_deferred` (must be empty except DP's
  `aux_bridge`, known),
- `dmesg | grep -iE 'dummy regulator|deferred|timeout|fail|error'`.
`diff -u audit-i.md audit-iii.md`, `audit-ii` vs `audit-iv`. Expected
differences: none in claimed resources. An enabled-but-unclaimed clock or a
vote present only in RAM modes = a missing DT consumer: fix the DT (RAM boot),
rebuild, restart the matrix from mode i.

### Gates
- **G-pre (before W4):** modes i and ii pass every row on the installed root;
  mode S result recorded; audits i and ii identical in claimed resources.
- **G-post (after W5):** modes iii and iv pass every row; audits iii/iv vs i/ii
  diffed and explained; mode vi works. Only then is the install "done".

---------------------------------------------------------------------------

## 5. Switching OS without a PC, and the automatic fallback

All slot changes are GPT attribute writes (on LUNs 1–5, plus the UFS
`bBootLunEn` attribute). They are reversible and covered by W5–W8, and they
are gated by §1 (both slots carry identical firmware, so either slot is safe
to run). The riskiest part is not the slot choice but **the code that writes
the GPTs**: LUN 4's GPT also describes `abl`, `uefi`, `tz`. Hence the order:
ABL's own `fastboot --set-active` first (W5), qbootctl only after a read-back
test (W6), the Android HAL's `bootctl` from LineageOS (W8) as a third,
vendor-maintained writer.

### 5.1 From Fedora: `fap-switch-os` and "Restart into LineageOS"
- **qbootctl**: Fedora 45 packages it (`qbootctl-0.2.2-3.fc45`, upstream
  linux-msm/qbootctl, only libc) [seen: `dnf5 info` in a Fedora 45
  container]. No packaging needed for the root; pin the version in the device
  layer. For the initramfs, build a static copy from the same tag (v0.2.2) in
  the build container (meson, `-Dc_link_args=-static`), sha256 recorded.
  It finds partitions via `/dev/disk/by-partlabel` (it failed in a container
  with "Failed to open bootdev dir") [seen], so the initramfs must create
  those links (a few lines of sh over `/sys/class/block/*/uevent`).
- **Fedora's `qbootctl.service` must be masked**: it marks the slot good as
  soon as `boot-complete.target` is reached, too early for our health check
  (5.4). The generic `boot/android-bootimg/build` enables it today: override
  in the device layer.
- `/usr/libexec/fap-switch-os` (new, root, via a polkit rule for the `phone`
  user):
  ```sh
  fap-switch-os lineage   # qbootctl -s a && sync && systemctl reboot
  fap-switch-os status    # qbootctl -c, slot info, last fallback
  ```
  Refuses if `qbootctl -c` doesn't report slot b as current (never act on a
  wrong assumption), logs to the journal.
- Plasma Mobile: `/usr/share/applications/fap-restart-lineageos.desktop`
  ("Restart into LineageOS", `Exec=pkexec /usr/libexec/fap-switch-os lineage`,
  confirmation dialog via `kdialog --yesno`). Optional: a quick-settings
  tile later.

### 5.2 From LineageOS
- Root shell: `bootctl set-active-boot-slot 1 && reboot` (slot 1 = b). bootctl
  talks to LineageOS's boot-control HAL (the QTI one, which also switches the
  boot LUN) [src: AOSP `bootctl`; HAL behaviour from qbootctl's README, which
  is a port of it]. Check first: `bootctl get-current-slot` → 0.
- What root LineageOS gives **without Magisk**: "Rooted debugging" in
  Developer options = `adb root` only (USB, or Wireless debugging); no `su` for
  apps. So without Magisk a one-tap switch needs adb:
  1. **Wireless debugging + a local adb client** (e.g. Termux with
     `android-tools`: `adb connect localhost:<port>; adb root; adb shell
     bootctl set-active-boot-slot 1; adb reboot`), wrapped in a
     Termux:Widget home-screen shortcut. Needs Wi-Fi up and a one-time pairing.
  2. **With this unit's existing Magisk/KernelSU** (slot a is patched, §1):
     Termux:Widget script `su -c 'bootctl set-active-boot-slot 1 && svc power reboot'`.
     Simplest one-tap; depends on keeping that root, which the user may not
     want.
  3. Without any of these: bootloader `fastboot --set-active=b` (needs a PC).
  LineageOS recovery: no slot switch documented [guess; check its "Advanced"
  menu once, read-only].
- Option, not default: "Fedora menu always first" = LineageOS sets slot b
  active again on every boot (Magisk `service.d` script), so the initramfs menu
  (5.3) becomes the chooser for both systems. Doubles GPT writes per boot and
  makes every LineageOS boot "unconfirmed" until it re-marks; decide after a
  month of use.

### 5.3 Boot menu in tiny-init (`fap.menu=<seconds>`)
Runs first thing after modules are loaded, **before** the root is touched, so
it works with a broken or missing root.
```
 Fedora      (Vol Up / wait 3 s)
 LineageOS   (Vol Down)
```
- Drawn with `printf` to `/dev/tty0` (fbcon on msm, TER16x32; msm/panel are
  built in, so the console is up by then [seen v4+]); clear screen, big text.
- Keys: read `/dev/input/event*` of gpio-keys/pon (resin) with busybox
  `timeout 3 dd bs=24 count=1` and decode code/value with `od` (arm64
  `input_event` = 24 bytes; `KEY_VOLUMEUP` 115, `KEY_VOLUMEDOWN` 114).
  Which node carries which key is a phone test (M14). Ignore a key that is
  already held at menu start (stuck key / user still holding Vol from ABL).
- LineageOS chosen: `qbootctl -s a` (static copy), print "Restarting into
  LineageOS", `sync; reboot -f`. If qbootctl fails: show the error, boot
  Fedora (no retry loops).
- Timeout or Vol Up: continue to `fap.root=`.
- **Failure branch**: root not mountable or `fap-lpmap` refused → menu again
  without timeout: "Fedora root not usable: <reason>. Vol Down: LineageOS. Vol
  Up: debug shell (USB)". Never marks the slot good.
- Development: `fap.menu=0` skips it (RAM boots in the dev loop).

### 5.4 Automatic fallback (ABL retry counter)
Qualcomm A/B as implemented in ABL and the boot-control HAL [src:
CodeAurora `PartitionTableUpdate.c` / qbootctl; details per this ABL are the
phone tests below]:
- `set_active b`: b active, priority max (3), retry count 7, unbootable
  cleared, successful cleared; a: inactive, lower priority.
- Each boot of b with successful = 0: ABL decrements the retry count. At 0
  with successful still 0: b marked unbootable, ABL switches to a (if a is
  bootable/successful; it is [seen 0x77]).
- Linux marks the slot good with `qbootctl -m` (sets successful).

Our unit `fap-boot-ok.service`: `After=graphical.target`, `Wants=graphical.target`,
runs a health check (msm DSI connector connected, `systemctl is-system-running`
not `degraded` for the essential units: display manager, NetworkManager,
fap-usb-dhcp, modem unit), waits 60 s of uptime, then `qbootctl -m`. On
failure it does nothing (the counter keeps running down). So 7 bad boots of b
land in LineageOS by themselves; one good boot re-arms everything.

What happens on a failure, by type:
| Failure | Result |
|---|---|
| kernel panics / reboots | each reboot counts; after ≤ 7 ABL boots LineageOS |
| kernel hangs or ends in **crashdump (05c6:900e)** | doesn't reboot by itself: hold Power + Vol Up ~15 s; each attempt counts |
| root broken | boot menu failure branch → Vol Down = LineageOS now |
| Fedora up but unhealthy (no display) | not marked; after ≤ 7 reboots → LineageOS; or `fap-switch-os lineage` over USB SSH |

Read from the backup [seen]: `boot_a = 0x77` shows retry 6 with successful
set (ABL decremented once on a boot before LineageOS marked it), consistent
with the scheme above. Not visible in the data, **phone tests (W5/W6)**:
1. Exact attribute bytes after `fastboot --set-active=b` (`getvar
   slot-retry-count:b`, `slot-successful:b`, `slot-unbootable:b`, and a GPT
   dump from Linux) — does ABL clear "successful"?
2. Does ABL decrement on each unmarked boot and fall back at 0 (count down
   once: boot b with `fap-boot-ok.service` masked, reboot to the bootloader,
   read `getvar slot-retry-count:b`)?
   Only the first decrement needs testing; don't run all 7.
3. Does qbootctl write the same bytes as ABL (diff GPT dumps after
   `fastboot --set-active=a` vs `qbootctl -s a`), on all five LUNs, and does
   it switch `bBootLunEn`?
4. Does LineageOS's HAL (`bootctl`) produce the same bytes?
5. Does LineageOS on slot a mark itself successful and leave b's flags alone?

---------------------------------------------------------------------------

## 6. Every write

Conventions: commands run on the Mac by the main session, **one write per user
OK**, phone serial pinned (`-s <serial>`), USB 2.0 cable for bootloader
fastboot. `B=~/Develop/OnePlus12/backup/partitions-20261120`. Never written
by anything in this plan: boot chain (`xbl*`, `abl`, `uefi`, `tz`, `hyp`,
`devcfg`, `aop*`, `keymaster`, `cpucp*`, `shrm`, `qupfw`, `uefisecapp`,
`imagefv`, `featenabler`, `oplus_sec`, `oplusstanvbk`, `engineering_cdt`,
`splash`, `multiimg*`), firmware (`modem`, `dsp`, `bluetooth`), identity
(`persist`, `ocdt`, `modemst1/2`, `fsg`, `fsc`, `oplusreserve*`), `vbmeta*`,
`userdata`, `metadata`, `misc`, any `_a` partition. Never `--slot=all`,
never relock, no EDL writes.

`tools/flash.sh` (device.env `PROTECTED_PARTITIONS`) already refuses most of
these but also lists `super`; W1/W2 go through fastbootd directly (by the
human, or a dedicated, reviewed script), not by weakening flash.sh. Add
`boot_a init_boot_a vendor_boot_a dtbo_a recovery_a userdata metadata` to the
device's protected list before W4, and set `FLASH_ROOT_PARTITION="fap_root"`.

### W0. Preparation (no phone writes except the Updater toggle)
- Read-only backups (M8, M9): full `super` image + sha256 (phone side and Mac
  side), LUN 0 GPT (`sda` first 6 and last 5 sectors), LP metadata area
  (first 1 MiB of super, covers geometry + all metadata slots; size confirmed
  by `lpdump`'s geometry).
- LineageOS Updater off: Settings → System → Updater → auto-check off (UI;
  reversible). Optional with adb root: `pm disable-user org.lineageos.updater`
  (restore: `pm enable`).
- Do not use Magisk's/KernelSU's "install to inactive slot".

### W1. Create `fap_root` in super (LP metadata)
| | |
|---|---|
| Command | `adb reboot fastboot` (LineageOS recovery's fastbootd; check `fastboot getvar is-userspace` = yes, `snapshot-update-status` = none, `current-slot` = a); `fastboot create-logical-partition fap_root <SIZE>`; `fastboot getvar partition-size:fap_root`; `fastboot getvar is-logical:fap_root` |
| Changes | LP metadata at the start of `super` (all metadata slots); no data extents of LineageOS move |
| Backup | full `super.img` + `super-lpmeta-1MiB.img` with sha256 (W0); `lpdump` text before |
| Restore | `fastboot delete-logical-partition fap_root` (fastbootd). Second line: from a RAM-booted Fedora, `dd if=super-lpmeta-1MiB.img of=/dev/<super> bs=4096 conv=fsync` then read back and compare sha256 |
| Go | §1 gate passed; M2 shows free ≥ 8 GiB + 256 MiB; no pending snapshot merge; super backup verified; user OK |
| Check after | `fastboot reboot` → LineageOS boots normally, `lpdump --slot=0` and `--slot=1` both list `fap_root`, LineageOS partitions' extents unchanged (diff against the before-dump) |
| No-go | anything other than the new entry changed in `lpdump` → restore immediately |

### W2. Fill `fap_root` (Fedora root filesystem)
| | |
|---|---|
| Command | build `fap-root.img` (ext4, label `fap-root`, exactly `<SIZE>` bytes) from the installroot; `img2simg fap-root.img fap-root.simg`; in fastbootd: `fastboot flash fap_root fap-root.simg` |
| Changes | only the extents of `fap_root` |
| Backup | none needed (new space) |
| Restore | re-flash, or W1's restore (delete) |
| Go | W1 checks passed; image sha256 recorded; user OK |
| Check after | LineageOS boots; `adb root; adb shell sha256sum /dev/block/mapper/fap_root` equals `shasum -a 256 fap-root.img` |

(Alternative to W2: mkfs + tar stream from a RAM-booted Fedora through
`fap-lpmap`, as on the N100; it exercises the mapper, but fastbootd is simpler
and uses Android's own tooling.)

Then: **matrix modes i, ii, S** with `fap-boot_b.img` (root = `fap_root`).
**G-pre** must pass.

### W3. (none: vendor_boot_b, init_boot_b, dtbo_b, vbmeta_b stay as they are)
Listed so nobody "fixes" them: their current hashes must still equal the
backup right before W4 (M11).

### W4. Write `boot_b`
| | |
|---|---|
| Command | bootloader fastboot (fresh session, `fap-dev state`: slot a, unlocked): `tools/flash.sh` → `fastboot flash boot_b fap-boot_b.img` |
| Changes | `boot_b` only (LUN 4) |
| Backup | `$B/boot_b.img`, sha256 `5bc8c79d858440c7a78241a1baa9736d9b841fbfbca9450d1e96f1825b615eaf` (pristine LineageOS) |
| Restore | `fastboot flash boot_b $B/boot_b.img` |
| Go | G-pre passed with this exact file (sha256 matches the matrix log); M11 hashes unchanged; user OK |
| Check after | `fastboot reboot` → LineageOS still boots (slot a untouched); `adb shell sha256sum /dev/block/by-name/boot_b` = `shasum -a 256 fap-boot_b.img` |

### W5. First switch to slot b, by ABL itself
| | |
|---|---|
| Command | `fastboot getvar all > getvar-before-W5.txt`; `ALLOW_SET_ACTIVE=1 tools/flash.sh --set-active=b`; `fastboot getvar all > getvar-after-W5.txt`; `fastboot reboot` |
| Changes | slot attributes in the GPTs of LUNs 1–5 + boot LUN selection |
| Backup | GPTs at backup time (whole-LUN images `sdb`–`sdf`), `getvar` dumps |
| Restore | `fastboot --set-active=a` (bootloader fastboot) — plus the automatic fallback (§5.4) |
| Go | §1 gate PASS re-confirmed on a **fresh** read of both slots' boot-chain hashes (M11 covers boot chain too); W4 checks passed; user OK |
| Check after | matrix modes iii, iv, v, vi; **G-post**; phone tests §5.4 items 1, 2, 5 |

### W6. qbootctl from Fedora (first use)
| | |
|---|---|
| Command | in Fedora on slot b: dump GPT headers+entries of LUNs 1–5 (`dd` of the first 6 and last 5 sectors of each) → `qbootctl -c` (read) → `qbootctl -m` → dump again → diff (only attribute bytes of `_b` entries + CRCs may change) |
| Then | `qbootctl -s a`, dump, diff against `getvar-before-W5` state; reboot → LineageOS |
| Restore | `fastboot --set-active=b` / `=a` via ABL; worst case GPT restore of a LUN from the whole-LUN backup image *only* from a RAM boot and only with the user present (sdb–sdf: `dd` of sectors 0–5 and the last 5 sectors from `$B/sdX.img`) |
| Go | W5 done and G-post passed; user OK |
| No-go | any GPT byte outside the attribute fields changes, or a CRC is invalid → stop, switch back with ABL, don't enable fap-switch-os / the menu |

### W7. Enable the on-phone switching
`fap-boot-ok.service` (marks good), `fap-switch-os`, the Plasma launcher and
`fap.menu=3` ship in the image; enabling them = image update (W9 path).
Writes made by them are W6-type writes, already proven.

### W8. `bootctl` from LineageOS (first use)
`adb root; adb shell bootctl get-current-slot` (expect 0);
`adb shell bootctl set-active-boot-slot 1`; `adb reboot bootloader`;
`fastboot getvar all` and compare with `getvar-after-W5.txt`; `fastboot
reboot` → Fedora. Restore: `fastboot --set-active=a`. Go: W5/W6 done, user OK.
Then set up one of the 5.2 one-tap options.

### W9. Later updates of `boot_b` (kernel/initramfs updates)
Same as W4 each time, with matrix mode i on the new file first. After bootc:
written by `fap-android-boot` from Fedora (section 7).

---------------------------------------------------------------------------

## 7. Updates and rollback

Short term (ext4 root, no bootc): kernel/DTB/initramfs updates = new
`fap-boot_b.img` → RAM-boot it (mode i) → W4 again. Rootfs updates = `dnf`
inside Fedora. Keep the last good `fap-boot_b.img` on the Mac
(`boot-lastgood.img`) and on the phone (`/var/lib/fap/boot-lastgood.img`).

Later (bootc):
- Root in `fap_root` becomes the ostree/composefs root (ext4 is fine for
  ostree; btrfs not required). Size permitting, two deployments.
- `fap-android-boot` turns the default BLS entry into a uniLoader boot image.
  Its A/B mode (write the *other* slot, then `qbootctl -s`) **would overwrite
  LineageOS's `boot_a`**: before the first bootc image runs here, add a device
  setting (e.g. `ANDROID_BOOT_SLOTS="b"`: fixed slot, write in place, keep
  `boot-lastgood.img`) and make the tool refuse any `_a` target on this
  device. The generic `boot/android-bootimg/build` enables
  `qbootctl.service`: mask it (5.1).
- Rollback: `bootc rollback` + rebuild/write `boot_b` at shutdown. If the new
  kernel doesn't boot: boot menu → LineageOS (or fallback after 7 tries), then
  `fastboot boot boot-lastgood.img` from a PC. PC-less, with root in
  LineageOS: `dd` the last good image from `fap_root`
  (`/dev/block/mapper/fap_root` is ext4, mountable read-only by LineageOS
  [guess]) to `boot_b`. A second kernel slot would be cleaner; we have only
  `boot_b`. Idea for later: put the previous image into `recovery_b`
  and boot it with the recovery key combo, if ABL starts a uniLoader image
  from `recovery_b` (untested; recovery images carry no kernel in stock).
- LineageOS updates while Fedora is installed (procedure, untested):
  back up Fedora's `/home` → in LineageOS enable the Updater, install →
  LineageOS now runs on **slot b** with its new images; Fedora's `boot_b` is
  gone → check `lpdump` that `fap_root` survived → Fedora now goes on slot a
  (`boot_a` = our image) with the slot roles swapped in every script
  (`ANDROID_BOOT_SLOTS`, fap-switch-os, menu). Firmware is identical in both
  slots (the LineageOS OTA carries no firmware for waffle [src: LineageOS
  wiki fw_update page via the dossier]) so the gate stays valid. Because this
  is error-prone, the default stance is: **LineageOS stays on its 20260625
  build** while Fedora is installed.

---------------------------------------------------------------------------

## 8. Measurements the main session must take first

All read-only, LineageOS booted, "Rooted debugging" on, `adb -s <serial>`.
Save outputs under `~/Develop/OnePlus12/log/install-recon-<date>/` (sensitive
ones under `backup/`).

| # | Command | Answers |
|---|---|---|
| M1 | `adb shell getprop \| grep -E 'ro.lineage.version\|ro.build.version.incremental\|ro.virtual_ab\|ro.boot.slot_suffix\|ro.crypto'` | build, VAB (compression?), slot |
| M2 | `adb root; adb shell lpdump > lpdump-slot0.txt; adb shell lpdump --slot=1 > lpdump-slot1.txt` | super size, groups, metadata slot count/max size, every extent, **free space** (decides §2) |
| M3 | `adb shell 'ls -l /dev/block/by-name/super /dev/block/by-name/userdata; blockdev --getsize64 /dev/block/by-name/super; cat /sys/block/sda/queue/logical_block_size; cat /proc/partitions'` | super device/size, LUN 0 layout |
| M4 | `adb shell 'grep -E " /data \| /metadata " /proc/mounts; dmctl list devices; dmctl table userdata'` | confirms dm-default-key under /data (rules out 2a for the record) |
| M5 | `adb shell 'ls /sys/fs/f2fs/; cat /sys/fs/f2fs/*/features'` | f2fs features (casefold, compression, encrypt, …) |
| M6 | `adb shell 'snapshotctl dump'` and in fastbootd `fastboot getvar snapshot-update-status` | no pending VAB merge |
| M7 | `adb shell 'ls -la /metadata/vold/metadata_encryption'` | key directory present (no contents copied) |
| M8 | `adb exec-out 'dd if=/dev/block/sda bs=4096 count=6' > sda-gpt-primary.img`; last 5 sectors likewise (`skip=$(( size/4096 - 5 ))`); sha256 both sides | **LUN 0 GPT backup (missing today)** |
| M9 | `adb exec-out 'dd if=/dev/block/by-name/super bs=4M' > super.img` + `adb shell sha256sum /dev/block/by-name/super` vs `shasum -a 256 super.img`; also the first 1 MiB as `super-lpmeta-1MiB.img` | super backup (only copy of LineageOS 20260625's system) |
| M10 | bootloader: `fastboot getvar all` (current-slot, slot-retry-count/-successful/-unbootable for a and b, has-slot:boot, partition-size:boot_b) | slot state before any write |
| M11 | right before W4/W5: `adb shell sha256sum /dev/block/by-name/{boot,init_boot,vendor_boot,dtbo,vbmeta,xbl,xbl_config,abl,tz,hyp,uefi,aop,devcfg}_{a,b}` vs `$B/SHA256SUMS` | nothing changed since the backup; gate still holds |
| M12 | `adb shell pm list packages \| grep -iE 'magisk\|kernelsu\|ksu\|apatch\|updater'` | which root/updater apps can touch slot b |
| M13 | `adb shell bootctl get-current-slot; adb shell bootctl get-suffix 1; adb shell bootctl is-slot-marked-successful 1` | HAL view of the slots (read-only verbs) |
| M14 | in a RAM boot of Fedora: `grep -A6 -iE 'gpio-keys\|pon\|resin' /proc/bus/input/devices` + `evtest` on each, press Power / Vol Up / Vol Down | key → event node map for the boot menu |
| M15 | in a RAM boot of Fedora: `qbootctl -c` and GPT dumps of `sdb`–`sdf` (read-only) vs the backup | qbootctl reads this layout correctly (before W6) |

---------------------------------------------------------------------------

## Implementation status (branch oneplus12-dualboot, 2026-11-20)
Built, not run on the phone: `CONFIG_BLK_DEV_DM=y` (+ `SCSI_UFS_BSG`);
`boot/android-bootimg/helpers/fap-lpmap.c` (tested offline against this
unit's super metadata: **metadata slots 1 and 2 hold a stale, empty table**,
so fap-lpmap takes slot 0 and requires other slots to agree only if they list
the partition; it also refuses overlaps with other partitions) and
`fap-keywait.c`; tiny-init `fap.root=lp:`, `fap.menu=`, `fap.menu_dry=`;
DTBs `-install` (boot_b) and `-lptest` (RAM-only menu test);
`fap-waffle-build.sh helpers` / `installroot` and the padded
`boot_b/fap-boot_b.img`; root overlay `devices/oneplus-waffle/installroot/`
(fap-boot-ok, fap-switch-os, launcher, polkit, qbootctl.service masked).
Deviations: qbootctl in the initramfs is Fedora's binary with its libc
bundled, not a static build; `fap-lpcheck.service` and the modem ordering
fix are not done. Runbook: `fap-build/waffle/install/INSTALL-RUNBOOK.md`.

## Work list before W1 (desk/RAM only)
1. `fap-lpmap` helper + tiny-init `fap.root=lp:` + `fap.menu=` (boot menu) +
   by-partlabel links + static qbootctl v0.2.2 in the initramfs.
2. `CONFIG_BLK_DEV_DM=y` in `build-env/waffle.config`.
3. Installed root: modem start as a unit with the N100 ordering fix (start
   rmtfs/tqftpserv after the modem's QRTR node is up), `fap-usb-dhcp`,
   `fap-boot-ok.service`, `fap-switch-os`, Plasma launcher,
   `qbootctl.service` masked, `fap-lpcheck.service`.
4. `fap-boot_b.img` builder (padded to 201326592 bytes, sha256 recorded).
5. device.env: `FLASH_ROOT_PARTITION="fap_root"`, `_a` kernel partitions +
   `userdata metadata` added to `PROTECTED_PARTITIONS`; `fap-android-boot`
   fixed-slot mode.
6. Test the menu and `fap.root=lp:` failure branch in RAM boots (mode vi uses
   `fap.root=lp:nonexistent`, nothing written).
