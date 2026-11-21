<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Safety audit for agents (2026-11-21)

Read this before doing **anything** in this repo, especially if you are a
small local model working through opencode. It lists every place found
in the repo (main branch, 2026-11-21) that can write to a phone's storage,
change what boots, or damage hardware, and which work is safe.

How the audit was done: read-only review of AGENTS.md, CLAUDE.md, HANDOFF.md,
README.md, CONTRIBUTING.md, Justfile, Containerfile, `docs/`, `devices/`,
`boot/`, `tools/`, `kernels/`, `layers/`, plus greps across the whole tree
for fastboot, adb, dd, `of=`, `/dev/`, mkfs, qbootctl, bootctl,
set-active, logical-partition, losetup, rm -rf, rmtfs, EDL tools and
friends. Nothing was run. Every `file:line` below was read. When the audit
was unsure, it marked the item as dangerous. Branches other than `main`
were not audited.

## 0. What is on the OnePlus 12 right now (why the old examples are dangerous)

The OnePlus 12 (`oneplus-waffle`, SM8650, fastboot product `pineapple`,
serial in HANDOFF.md:166) dual-boots. Source: HANDOFF.md:41-76.

| Partition | Holds today | If overwritten |
|---|---|---|
| `boot_b` | **Fedora's kernel** (our uniLoader image) | Fedora doesn't boot; back with a re-flash |
| `boot_a`, `init_boot_a`, `vendor_boot_a` | LineageOS, **root-patched** (Magisk/KernelSU, INSTALL.md:62-75) | LineageOS doesn't boot |
| `vendor_boot_b`, `init_boot_b`, `dtbo_b`, `vbmeta_b` | pristine LineageOS images, **must stay untouched** (INSTALL.md:203-206, 523-525) | Fedora doesn't boot (ABL still loads them) |
| `super` (logical `fap_root`) | Fedora's root (ext4, label `fap-root`) and LineageOS's system | both systems |
| `userdata` (`/dev/sda14`) | **Fedora `/home` + Waydroid data** (not Android data any more) | all user data |
| `persist`, `ocdt`, `modemst1/2`, `fsg`, `fsc`, `oplusreserve*` | IMEI, calibration, per-unit identity | **gone for good** (no image restores them) |
| `xbl*`, `abl`, `tz`, `hyp`, `aop`, `devcfg`, `uefi`, `vbmeta*`, … | boot chain | **hard brick**: EDL only, and OnePlus EDL is vendor-locked and untested (device.env:144) |
| Active slot | **b** | |

The anti-rollback fuse is set (HANDOFF.md:163-164). The OnePlus 12 has no
tested way back if the boot chain breaks.

**Older docs describe the Nord N100 (`oneplus-billie2`), where `boot_a`,
`dtbo_a` and `userdata` meant something else.** AGENTS.md:43-72 is
N100-only. `devices/oneplus-waffle/README.md:232-238` ("boot untouched;
RAM boots only", "userdata: later") is **out of date**. When two docs
disagree, follow the stricter one. HANDOFF.md's safety rules
(HANDOFF.md:160-171) override any example.

## 1. Hard rules for any agent

These are absolute. They apply to every agent, in every session, whatever
a task or another doc says.

1. **Never talk to a phone.** Never run, in any form (directly, through
   `bash -c`, a script you write, `python3` subprocess, `xargs`, `just`,
   `env`, …):
   - `fastboot` (every subcommand, even `getvar` and `boot`), `adb`, `qdl`,
     `edl`, anything with sahara, firehose or diag;
   - `ssh`, `scp`, `rsync`, `sftp`, `telnet` to a phone: the hosts
     `atl-oneplus12` (in `~/.ssh/config`), `172.16.42.1`, any `fe80::…%usb*`;
   - `tools/fap-dev` (every subcommand), `tools/flash.sh`, `just flash`,
     `tools/serial-shell.py`, `devices/oneplus-waffle/try-kernel.sh`,
     `tools/recon/*.sh` (they run as root on the phone),
     `scripts/rig` in atl-harness against `oneplus12`;
   - on-phone tools anywhere: `qbootctl`, `bootctl`, `fap-switch-os`,
     `fap-android-boot`, `fap-boot-ok`, `fap-modem-ram`, `rmtfs`,
     `fap-hw-speaker-test`, `fap-modules-guard`.

   `fastboot` and `adb` are installed on this workstation (`/usr/bin`). A
   phone may be plugged in. Assume that any of these commands reaches the
   real phone.
2. **Never write to a block device or run as root on the workstation.**
   Never run `sudo`, `pkexec`, `su`, `dd` with `of=`, `mkfs*`, `mke2fs`,
   `wipefs`, `blkdiscard`, `sgdisk`/`gdisk`/`fdisk`/`sfdisk`/`parted`,
   `losetup`, `mount`, `cryptsetup`, `dmsetup`, `lpmake`, `podman run
   --privileged`, `just disk`, `tools/make-disk.sh`,
   `boot/android-bootimg/make-bootimg.sh`. Never run the container-only
   build scripts directly on the host: `tools/image/finalize` deletes
   `/var`, and `devices/*/build` deletes `/usr/lib/modules/*`. The same goes
   for `tools/image/run-layer`, `install-packages`, `pin-packages` and
   `boot/*/build`. Never `rm -rf` anything outside the repo.
3. **Never edit these files without the owner reviewing the diff before
   anything is built from it.** A mistake in them reaches the phone's
   storage or hardware later:
   - `tools/flash.sh`, `tools/fap-dev`, `tools/tests/test-flash.sh`,
     `tools/tests/test-fap-dev.sh`, `Justfile`, `Containerfile`;
   - `boot/**`: `tiny-init`, `fap-android-boot`, `boot/android-bootimg/build`,
     `helpers/fap-lpmap.c`, `helpers/fap-keywait.c`, `make-ramboot.sh`;
   - `devices/*/device.env`, `devices/*/build`, `devices/*/installroot/**`,
     `devices/*/netroot/**`, `devices/*/rootfs/**`, `devices/*/dts/**`,
     `devices/*/build-env/**`, `devices/*/ucm/**`, `devices/*/tplg/**`,
     `devices/*/try-kernel.sh`, `devices/_template/**`;
   - `kernels/**`, `kmod/**` (drivers and device-tree values: wrong
     regulator, amp or charger values damage hardware, AGENTS.md:87);
   - the safety text in `AGENTS.md`, `CLAUDE.md`, `HANDOFF.md`, this file,
     and any opencode or agent config.
4. **Never read, copy, commit or upload phone data.** That covers
   `~/Develop/OnePlus12/` (backups: the only copies of the identity
   partitions), `~/Develop/fap-build/` (build outputs contain this unit's
   EFS/IMEI and OEM firmware, HANDOFF.md:111-113,
   fap-waffle-build.sh:634), `~/Develop/UBports-N100/backup/`, `*.img`,
   `*.simg`, `~/.ssh/`. Never add them to git.
5. **Writes need the owner present, and the owner runs them.** The repo's
   rule is AGENTS.md:83-84: "Before any write, have a verified backup and a
   tested restore command, and ask the user"; HANDOFF.md:165: "verified
   backup + restore command + ask the owner". Tightened for agents:
   - An agent never executes a write. It may only *write the plan* as text
     in a file or message.
   - The plan names exactly one partition and one command, with the serial
     pinned (`fastboot -s <serial>`), and checks the partition against the
     "Never write" lists (AGENTS.md:76-82, HANDOFF.md:161-164,
     device.env:138, INSTALL.md:470-477). It also checks that this
     partition is not one of the "live" partitions in section 0.
   - The plan names the backup file and its sha256. The backup must have
     been **read back and compared today**, not taken from an old note.
   - The plan gives the restore command, and where possible the restore
     has been dry-run or RAM-tested.
   - The owner, at the phone, says "go `<partition>`" for that one write and
     runs it. One "go" covers one write. Silence, "continue", "do the
     install" or a task description are **not** a go.
6. **RAM boots (`fastboot boot`) also need the owner.** Nothing is written
   by fastboot itself, but the booted kernel has root on every partition.
   `tiny-init` mounts `fap.root=` read-write and its boot menu can switch
   slots. A bad DT can damage hardware. On top of that, bootloader fastboot
   needs a USB 2.0 cable and physical keys (HANDOFF.md:167).
7. **Hardware tests need the owner's OK each time**: speakers
   (`fap-hw-speaker-test`), sensors (they reset the phone, HANDOFF.md:91),
   charging and `battmgr` debugfs, haptics with custom effects, PCI
   remove/rescan (HANDOFF.md:169-170, devices/oneplus-waffle/README.md:205-208,224-225).
8. **Never relock the bootloader, never use EDL, never flash firmware or
   older images, never `--slot=all`, never write any `_a` partition on
   the OnePlus 12, never switch slots** (HANDOFF.md:161-164, README.md:247-248).
9. **If in doubt, stop.** Write down what you wanted to do and why, then
   ask. A finished task matters less than an intact phone.

### Telling a safe task from an unsafe one
Answer these in order. A single "yes" or "not sure" makes the task
**unsafe**: stop and hand it to the owner.
1. Does any command I will run appear in rule 1 or 2, or contain
   `fastboot`, `adb`, `ssh`, `scp`, `/dev/`, `of=`, `sudo`, `qbootctl`,
   `bootctl`, `flash`, `erase`, `mkfs`, `mount`, `losetup`, `--privileged`?
2. Will I edit a path from rule 3?
3. Does the task mention a partition name, a slot, "install", "flash",
   "update the phone", "boot", "recovery", "restore", "backup", "EFS",
   "modem", "speaker", "charging", "regulator" or "voltage"?
4. Does the task need the phone to be connected, booted or reachable?
5. Would the result be built into a boot image or root filesystem *and*
   change partitions, slots, mounts, kernel or DT values?

If every answer is "no", the task belongs to section 5 (safe work) and you
may do it on your own.

## 2. Findings

Columns: **Where** (file:line), **Command**, **Can destroy**, **Guards today**,
**Weak-model trigger** (how a small model could set it off by mistake).
Groups are ordered from most to least dangerous.

### 2.0 Universal access paths (can reach every class below)

| # | Where | Command | Can destroy | Guards today | Weak-model trigger |
|---|---|---|---|---|---|
| U1 | tools/fap-dev:332-338 | `tools/fap-dev ssh [cmd]`, `scp-to` | **anything**: root shell on the phone (`FAP_USER` defaults to root, :44), host keys not checked (:52-53) | the docs only ("read-only by design", AGENTS.md:116). The script itself doesn't limit commands | **high**: AGENTS.md:55-56 and tools/README.md:45-48 present it as the normal way to look at the phone |
| U2 | `~/.ssh/config` host `atl-oneplus12` (user `phone`) | `ssh atl-oneplus12 …` | anything the `phone` user can do with sudo (polkit lets `phone` switch slots, see B3) | none | **high**: the alias is in the workstation's ssh config and atl-harness `rig` uses it |
| U3 | boot/android-bootimg/tiny-init:106, 208 | `telnetd -l /bin/sh`, root shell on USB serial `/dev/ttyGS0` | anything (unauthenticated root while RAM-booted) | only reachable over the USB cable | medium: `tools/serial-shell.py` and `telnet 172.16.42.1` are documented (tools/README.md:30) |
| U4 | `/usr/bin/fastboot`, `/usr/bin/adb` on this workstation | any | anything | none | **high**: a phone on USB is reachable from any shell |

### 2.1 IDENTITY / CALIBRATION (irreplaceable, per unit)

| # | Where | Command | Can destroy | Guards today | Weak-model trigger |
|---|---|---|---|---|---|
| I1 | devices/oneplus-waffle/INSTALL.md:501 | `dd if=super-lpmeta-1MiB.img of=/dev/<super> bs=4096 conv=fsync` | the placeholder `<super>` filled in wrongly (e.g. `/dev/sda` = LUN 0, which holds `persist` as sda2, INSTALL.md:116) wipes the GPT of LUN 0 plus `persist` and `userdata` | none (a doc line) | **high**: copy-paste with a guessed device node |
| I2 | devices/_template/build:18-19; rmtfs in devices/oneplus-waffle/packages:8, devices/oneplus-billie2/packages:7 | `# systemctl enable rmtfs.service` (commented example) | Fedora's `rmtfs.service` serves the **real** `modemst1/2`, `fsg`, `fsc` read-write (docs/status.md:128-129, fap-rmtfs.service:11) and the modem writes to them | docs say "masked" (status.md:129), but **no code on main masks it** in the bootc image path. Only `qbootctl.service` is masked (installroot overlay; fap-waffle-build.sh:613). Whether the RPM preset enables it is unverified | **high**: `tools/new-device.sh` copies the template; "enable the modem" invites uncommenting it |
| I3 | boot/android-bootimg/tiny-init:148, 155 | `fap.root=/dev/<node>`: mounts that node `-t ext4 -o rw` | a wrong node that happens to be ext4 (`persist` is ext4 on Qualcomm phones [guess for this unit]) is mounted read-write, so the journal is replayed and the superblock written | `lp:` roots check the label (`fap-lpmap -l fap-root`, :142). `/dev/*` and `LABEL=` roots get **no label or device check** | medium: editing a `RAMBOOT_CMDLINE` / DT bootargs with a guessed `/dev/sdaN` |
| I4 | devices/oneplus-billie2/netroot/usr/libexec/fap-modem-ram:36 | `dd if=/dev/disk/by-partlabel/<modemst1…> of=/run/fap-efs/…` | reads EFS today. With `if`/`of` swapped it **overwrites EFS** | correct code only | low-medium: "refactoring" this file |
| I5 | docs/re-tooling.md:71-73 | diag-log idea: `/dev/diag` with mask commands | diag can write NV/EFS (the doc says so) | idea only, no code | low: implementing that idea |
| I6 | devices/oneplus-waffle/build-env/fap-waffle-build.sh:640-658, 634; README.md:175 | EFS copies baked into netroots/installroots | **leak** of IMEI/EFS data if an output is committed, uploaded or shared | `.gitignore` covers `*.img`, `*.simg`, `/out/`. A `SENSITIVE` readme is written next to the outputs. `*.tar.gz`/`*.tar.zst` are **not** ignored | medium: "add the built netroot to the repo/release" |

The shared deny list in tools/flash.sh:26 (`modemst1 modemst2 fsg fsc persist`)
and the device's list at device.env:138 (adds `ocdt`, `oplusreserve2`, …)
do protect identity partitions **inside flash.sh**. Nothing protects them
from raw `fastboot`, `dd` or `ssh`.

### 2.2 BOOT CHAIN and slot switching (hard brick, or EDL needed)

| # | Where | Command | Can destroy | Guards today | Weak-model trigger |
|---|---|---|---|---|---|
| B1 | devices/oneplus-waffle/INSTALL.md:552 | GPT restore: `dd` sectors 0-5 and the last 5 sectors of `$B/sdX.img` onto `sdb`-`sdf` | LUNs 1-2 are the **boot LUNs** (`xbl_a`/`xbl_b`, INSTALL.md:36-38); LUN 4's GPT describes `abl`, `tz`, `uefi` (INSTALL.md:342-343). A wrong `X` or sector count = **hard brick** | the text says "only from a RAM boot and only with the user present" | **high**: placeholder `sdX`, the restore looks routine |
| B2 | Justfile:67-68 → tools/flash.sh:103-115 with devices/oneplus-waffle/device.env:127-134 | `just DEVICE=oneplus-waffle flash` = `fastboot flash boot output/boot.img --slot=all`, then `fastboot flash userdata output/rootfs.img`, `fastboot reboot` | `boot_a` **and** `boot_b` (LineageOS's rooted boot and Fedora's kernel), then **wipes `userdata` = Fedora `/home` + Waydroid** | product check `pineapple` (:96-101); shared + device protected lists (:24-49); refuses relock (:60) and slot switch (:64-65); `FLASH_DRY_RUN=1`; needs `output/boot.img` and `rootfs.img`. **Missing:** `FLASH_SLOT="b"` (device.env:130) is **never read by flash.sh** (grep: no reference); `--slot=all` is hard-coded (:104) and expected by the test (tests/test-flash.sh:32); no `-s <serial>`; no confirmation; no backup check; `boot_a`, `userdata`, `vendor_boot`, `init_boot`, `dtbo`, `metadata`, `misc` are not protected. INSTALL.md:479-483 and 663-664 ask for these protections and `FLASH_ROOT_PARTITION="fap_root"`. **Not done** | **high**: innocent recipe name; `set dotenv-load` (Justfile:6) lets a `.env` with `FAP_DEVICE=oneplus-waffle` change the target silently (Justfile:9); README.md:24 lists `just flash` as an entry point |
| B3 | devices/oneplus-waffle/installroot/usr/libexec/fap-switch-os:19; …/applications/fap-restart-lineageos.desktop:7; …/polkit-1/rules.d/50-fap-switch-os.rules:4-8 | `qbootctl -s a` then reboot | slot attributes in the GPTs of LUNs 1-5, the same tables that describe `xbl`, `abl`, `tz` (INSTALL.md:339-346); UFS boot-LUN switch. **qbootctl writes are untested on this phone** (HANDOFF.md:67-68, INSTALL.md W6) | must be root; refuses unless `fap.slot=b` is on the cmdline (:17); the launcher asks via kdialog; the polkit rule gives the `phone` user this action **without a password** (local, active sessions) | medium: anyone with a shell on the phone; "test the OS switcher" |
| B4 | devices/oneplus-waffle/installroot/usr/libexec/fap-boot-ok:19; fap-boot-ok.service (enabled through graphical.target.wants) | `qbootctl -m b` at every healthy boot | GPT attribute writes (as B3); runs **on the phone now** | `ConditionKernelCommandLine=fap.slot=b`; health check (:11-14); 60 s delay. Verified twice (HANDOFF.md:69-70) | low unless edited (rule 3) |
| B5 | boot/android-bootimg/tiny-init:40-52, 63-64, 76 | boot menu: Vol Down runs `qbootctl -s a; reboot -f` | as B3, from the initramfs | needs a physical key press; `fap.menu_dry=1` prints instead (:42-44); a qbootctl failure boots Fedora | low unless edited |
| B6 | boot/android-bootimg/rootfs/usr/libexec/fap-android-boot:92-115; fap-android-boot.service (ExecStop) enabled by boot/android-bootimg/build:11, which every android-bootimg **bootc** image runs (Containerfile:57-59) | `sync` at every shutdown: `dd if=<img> of=/dev/disk/by-partlabel/boot_<other slot>`, then `qbootctl -s <other>`. Without qbootctl: `dd` onto `boot_a` in place (:109-111) | on the OnePlus 12 booted from slot b: **overwrites LineageOS's `boot_a` and switches to slot a**. Also enables Fedora's `qbootctl.service`, which marks slots too early (INSTALL.md:357-360) | none: no protected list, no `_a` refusal, no device check. Marked "Status: untested" (:20). INSTALL.md:584-590 says it must get a fixed-slot mode first: **not done** | medium: `just DEVICE=oneplus-waffle build` produces such an image today; a model "working on the bootc migration" (HANDOFF.md:38) would ship it |
| B7 | HANDOFF.md:65-66, 74; INSTALL.md:390, 543, 565 | `fastboot --set-active=a && fastboot reboot` (and `=b`) | slot switch: the active slot selects the whole boot chain (INSTALL.md:35-42). Safe only while every boot-chain pair is identical, which was checked against the 2026-11-20 backup (INSTALL.md:52-60). Booting slot a can show LineageOS recovery's "format data" prompt, which **wipes Fedora's `/home`** (HANDOFF.md:60-62) | flash.sh's `ALLOW_SET_ACTIVE` gate (:64-65) doesn't apply to raw fastboot | **high**: plain copy-paste lines in the first doc an agent reads |
| B8 | INSTALL.md:540 | `ALLOW_SET_ACTIVE=1 tools/flash.sh --set-active=b` | slot switch | as written it fails (flash.sh takes `devices/<id> <outdir>`, :19-22), but it teaches the bypass variable | medium |
| B9 | INSTALL.md:102-105 | `fw_update` from fastbootd with `--slot=all` | firmware and boot chain on both slots | "needs its own plan" | low (prose) |
| B10 | INSTALL.md:375-390, 562-563 | `bootctl set-active-boot-slot 1`, Termux `su -c 'bootctl …'` | slot switch from LineageOS | "user OK" in the plan | low-medium |
| B11 | docs/porting-cookbook.md:393-396 | `fastboot stage vendor_boot.img`; write `vendor_kernel_boot_b`/`dtbo_b`/`init_boot_b` | on the OnePlus 12 these must stay pristine (INSTALL.md:203-205): Fedora stops booting | none | medium: a "fix" suggested by a cookbook recipe |
| B12 | AGENTS.md:59, 68-69; docs/porting-cookbook.md:74; boot/uboot-android/README.md:79 | `fastboot erase dtbo_a`; "`fastboot flash boot_a` it to keep" | N100 instructions. On the OnePlus 12, `boot_a`/`dtbo_a` belong to LineageOS (never write `_a`, HANDOFF.md:162) | text only | **high**: AGENTS.md is the first file read and doesn't say "N100 only" on these lines |
| B13 | HANDOFF.md:71, 74-75; INSTALL.md:530, 533; devices/oneplus-waffle/try-kernel.sh:93 | `fastboot flash boot_b <img>` | Fedora's kernel (recoverable by re-flashing while ABL works; the fallback to slot a after 7 failed tries was only partly tested, INSTALL.md:457) | backups named with sha256 | medium: "install the new kernel" |
| B14 | docs/hardware/n100-power-and-install.md:237-245 | N100: `fastboot erase dtbo_a/_b`, `flash boot_b`, `--set-active=b`, `flash userdata`, `flash op1` | on the N100 as described; on the **OnePlus 12** (if run against it) the boot images and `/home` | product check exists only inside flash.sh, not in these raw lines | medium |
| B15 | boot/uboot-android/README.md:157-158; devices/oneplus-billie2/uboot.env:9-10 | `fastboot oem run:<cmd>` | any U-Boot command, including storage writes (N100 with U-Boot only) | none | low |
| B16 | tools/fap-dev:259-285 (`ramboot`); devices/oneplus-waffle/try-kernel.sh:61-67 | `fastboot boot <img>` (RAM) | nothing by itself; the booted kernel/initramfs can do any of the above (I3, B5) and hardware damage (section 2.6). A USB 3 cable crashes ABL into 900E (HANDOFF.md:167) | allow-list in fap-dev's `fb()` (:67-78: devices, getvar, boot, reboot); several-phones check (:98); try-kernel pins `-s` | medium: AGENTS.md:51-58 calls the RAM-boot loop "nothing written" |

### 2.3 ANDROID DATA (`super`, `userdata`, `metadata`)

| # | Where | Command | Can destroy | Guards today | Weak-model trigger |
|---|---|---|---|---|---|
| A1 | INSTALL.md:148-150, 498, 509; fap-waffle-build.sh:628 | fastbootd: `fastboot create-logical-partition fap_root <bytes>`, `fastboot flash fap_root fap-root.simg` | LP metadata at the start of `super`; a bad write makes LineageOS unbootable (INSTALL.md:174-178). Re-flashing `fap_root` wipes Fedora's root | done once; super backup (INSTALL.md M9). flash.sh lists `super` as protected but not `fap_root` | medium: the build script prints the exact command |
| A2 | HANDOFF.md:76; INSTALL.md:177, 501 | `fastboot delete-logical-partition fap_root` | **deletes Fedora's root** and rewrites `super`'s metadata | none | **high**: it sits under "Undo the whole install" in HANDOFF.md |
| A3 | docs/porting.md:18; tools/flash.sh:59-61 (only `lock` refused); tools/tests/test-flash.sh:73 (asserts `flashing unlock` passes) | `fastboot flashing unlock` | unlocking factory-resets: wipes `userdata` (= Fedora `/home` here) [standard Android behaviour; the phone is already unlocked] | flash.sh passes every verb except lock and set-active: `erase`, `format`, `-w`, `oem *`, `update`, `flashall`, `*-logical-partition`, `snapshot-update cancel` all go through | medium |
| A4 | HANDOFF.md:57-58; INSTALL.md:84-87, 490-493 | `adb shell pm enable org.lineageos.updater`; Magisk/KernelSU "Install to inactive slot" | an OTA rewrites slot b (Fedora's `boot_b`) and switches slots; the root apps overwrite `boot_b`/`vendor_boot_b` | Updater disabled | low-medium |
| A5 | HANDOFF.md:60-62 | LineageOS recovery "factory reset / format data" | formats `userdata` = Fedora `/home` + Waydroid | warning text | the owner's own tap; a model can't press it, but it may suggest it |
| A6 | INSTALL.md:185 | option c1: shrink `userdata` in LUN 0's GPT | LineageOS data, and a GPT write on the LUN that holds `persist` | "only with the user's explicit OK" | low (rejected option) |
| A7 | AGENTS.md:65-67 | from a RAM boot: `mkfs.ext4 -L fap-root` on userdata, stream the tarball in | N100 text. On the OnePlus 12 `userdata` is Fedora `/home` + Waydroid: **all user data** | none | **high**: written as a general "rebuild the root" step |

### 2.4 FEDORA ONLY (Fedora's own partitions and files; the phone still boots something)

| # | Where | Command | Can destroy | Guards today | Weak-model trigger |
|---|---|---|---|---|---|
| F1 | devices/oneplus-waffle/try-kernel.sh:34-58, 61 | scp modules + guard unit, `systemctl enable fap-modules-guard`, reboot to the bootloader | Fedora's `/usr/lib/modules` tree on `fap_root` | SHA256SUMS check (:32), sha check on the phone (:44); `-s $FAP_SERIAL`; checks `is-userspace: no` (:64) | medium: "test the new kernel" |
| F2 | devices/oneplus-waffle/installroot/usr/libexec/fap-modules-guard:21-26 | `mv` of module trees + `depmod` at every boot | Fedora's module trees (wrong swap = no drivers, no USB/Wi-Fi) | exits if there's no spare tree (:14) | low unless edited |
| F3 | docs/waydroid.md:280-288 | `rm -rf /var/lib/waydroid … /home/phone/.local/share/waydroid` | Waydroid images and **Android app data** in Waydroid | "on the phone (as root)" | medium: a roll-back recipe that looks routine |
| F4 | tools/fap-dev:311-319 | `fap-dev clock`: `date -u -s` on the phone | nothing lasting (system clock only) | — | low |
| F5 | devices/oneplus-waffle/installroot/usr/libexec/fap-waydroid-omx-fix:15-28 | writes Waydroid's vendor overlay manifest | the Waydroid overlay file | read-only loop mount of `vendor.img` | low |

### 2.5 HOST ONLY (the developer machine)

| # | Where | Command | Can destroy | Guards today | Weak-model trigger |
|---|---|---|---|---|---|
| H1 | docs/hardware/n100-power-and-install.md:236 | `sudo dd if=disk.raw of=/dev/rdiskN bs=4m` | a wrong `N` **wipes a workstation disk** | "`diskutil list`" first (macOS) | **high**: placeholder plus sudo |
| H2 | tools/image/finalize:18 | `find /var -mindepth 1 -maxdepth 1 ! -name cache ! -name tmp -exec rm -rf {} +` | the host's `/var` if run outside the container as root | the header says "Runs inside the container build" (:3) | medium: "run the finalize step to test it" |
| H3 | devices/_template/build:11-14, devices/oneplus-waffle/build:25-28 | `dnf5 -y remove kernel …; rm -rf /usr/lib/modules/*` | the host's kernels/modules (unbootable workstation) | runs only when `KERNEL_PACKAGE` isn't `fedora`; container-only by convention | low-medium |
| H4 | tools/make-disk.sh:28-32; Justfile:59-60 | `podman run --rm --privileged -v /var/lib/containers/storage:…` (`just disk`, needs root) | a privileged container with the host's container storage | none | medium: innocent recipe name |
| H5 | boot/android-bootimg/make-bootimg.sh:17-20 | `losetup --find --show --partscan`, `mount` on the host as root | host loop devices and mounts | `ro` mount | low |
| H6 | tools/update/review-pr.sh; Justfile `update-review` | posts comments on GitHub PRs | nothing on the phone; an outward action in the owner's name | `--dry-run` | low (no network for the local model anyway) |

### 2.6 HARDWARE (physical damage; outside the storage classes, listed because it is just as permanent)

| # | Where | Command / change | Can destroy | Guards today | Weak-model trigger |
|---|---|---|---|---|---|
| X1 | devices/oneplus-waffle/netroot/usr/libexec/fap-hw-speaker-test:17-18 | `FAP_SPEAKER_APPROVED=yes fap-hw-speaker-test bot` | speaker/amp (the v9 test hard-reset the phone, HANDOFF.md:90) | an environment variable, trivial for a model to set | medium |
| X2 | devices/oneplus-waffle/dts/*, kernels/qcom-sm8650/patches/0002-0004, kmod/* | regulator, boost, amp, charger, haptics values | PMIC rails, speakers, battery | the rule in AGENTS.md:87 and dts/README.md:23-25 ("vendor values only") | medium: "fix the DT warning" |
| X3 | devices/oneplus-waffle/installroot/usr/share/wireplumber/wireplumber.conf.d/50-fap-waffle-speaker-dsp.conf; ucm/OnePlus/waffle/*; tplg/* | speaker protection (HPF, limiter, -12 dB cap, HANDOFF.md:22-25) | speakers if loosened | review only | medium: "audio too quiet" |
| X4 | HANDOFF.md:169-170; devices/oneplus-waffle/README.md:205-208, 224-225 | battmgr debugfs charge controls; PCI remove/rescan; custom FF haptic vmax | battery, Wi-Fi chip (hung kernel), haptic motor | text rules | low-medium |

## 3. Guards that exist today (and where they stop)

- tools/flash.sh: the only writer meant for agents. It denies identity, boot
  chain, firmware, Tensor and per-device partitions, refuses relock, gates
  slot switches behind `ALLOW_SET_ACTIVE=1`, checks `getvar product`, and
  offers `FLASH_DRY_RUN=1`. It is a **deny list**: anything not named
  (`boot_a`, `userdata`, `vendor_boot`, `dtbo`, `metadata`, `fap_root`, …)
  can be written, and every fastboot verb except lock and set-active
  passes. It also ignores `FLASH_SLOT` (B2). "Status: untested" (:16).
- tools/fap-dev: allow-list of fastboot verbs (good), but `ssh`/`scp-to`
  give an unrestricted root shell (U1).
- The OnePlus 12 scripts on the phone check `fap.slot=b` before slot
  writes (fap-switch-os:17, fap-boot-ok:7).
- `fap-lpmap` refuses mismatched or overlapping LP extents and checks the
  ext4 label (INSTALL.md:642-645; tiny-init:142).
- tools/tests: fakes for `adb`, `fastboot`, `ssh` on PATH make the tests
  phone-safe (tools/README.md:152-154).
- Nothing checks the device model on the phone side, nothing asks for
  confirmation, nothing verifies a backup before writing, and nothing
  stops an agent from running `fastboot`/`ssh` directly.

## 4. Gaps and fixes, ranked

1. **Take the phone out of the agent's reach (most effective; the
   permission rules below can be bypassed with `bash -c`, a script file or
   Python).** Run opencode as a separate Linux user, or in a toolbox/bwrap
   sandbox, that has:
   - no `~/.ssh` keys and no `atl-oneplus12` alias;
   - no access to USB devices (not in `plugdev`/`wheel`, no android udev
     rule for that user);
   - no `fastboot`/`adb` on PATH;
   - no sudo;
   - a firewall rule rejecting the phone's LAN address and 172.16.42.0/24.

   Keep the phone unplugged while a weak agent runs.
2. **Fix tools/flash.sh before it is ever pointed at the OnePlus 12:**
   - honour `FLASH_SLOT` (write `<part>_<slot>`, never `--slot=all` when it
     is set);
   - switch from a deny list to a per-device **allow list** (e.g.
     `FLASH_ALLOW="boot_b fap_root"`) and refuse everything else;
   - refuse every `_a` partition on devices with `FLASH_SLOT="b"`;
   - allow only the verbs `flash`, `getvar`, `reboot`; refuse `erase`,
     `format`, `-w`, `flashing *`, `oem *`, `update`, `flashall`,
     `*-logical-partition`, `snapshot-update`;
   - require `FAP_SERIAL` and pass `-s` on every call;
   - require `CONFIRM=<partition>` matching each target, and refuse when
     stdin is not a TTY (agents usually have none);
   - require `BACKUP_DIR` with a `SHA256SUMS` entry for each target.

   Then do INSTALL.md:482-483 / 663-664 in device.env:
   `FLASH_ROOT_PARTITION="fap_root"`, and add `boot_a init_boot_a
   vendor_boot_a dtbo_a recovery_a vendor_boot_b init_boot_b dtbo_b
   vbmeta_b userdata metadata misc` to `PROTECTED_PARTITIONS`. Update
   tools/tests/test-flash.sh:31-33 and :73 so they assert the new refusals.
3. **One on-phone write gate, `tools/guard` (installed as
   `/usr/libexec/fap-guard`).** Every on-device writer (`fap-android-boot`,
   `fap-switch-os`, `fap-boot-ok`, tiny-init's `to_lineage`) calls it before
   it writes. It checks:
   - the device model (`/sys/firmware/devicetree/base/compatible` contains
     the device's compatible, e.g. `oneplus,waffle`);
   - the partition against the device's allow list;
   - `_a` targets and whole-disk nodes (`/dev/sd[a-z]`), which it refuses;
   - and it logs every write to the journal.
4. **fap-android-boot**: add the fixed-slot mode INSTALL.md:584-590 asks
   for (`ANDROID_BOOT_SLOTS="b"`, write in place, keep
   `boot-lastgood.img`). Make it refuse `_a` on this device, and drop its
   "no qbootctl → write `boot_a`" fallback (:108-111). Don't enable
   `qbootctl.service` for dual-boot devices. Until then, have
   `just DEVICE=oneplus-waffle build` fail.
5. **Justfile**: rename `flash` to `danger-flash`, give it just's
   `[confirm("…")]` attribute plus a required `CONFIRM` variable, and have
   it print the resolved `DEVICE` (which `.env` can change). Same for
   `disk`.
6. **Mask Fedora's `rmtfs.service`** in every device layer
   (`systemctl mask rmtfs.service`) and assert it at build time, as
   fap-waffle-build.sh:613 does for qbootctl. Delete the commented
   `systemctl enable rmtfs.service` from devices/_template/build:19.
7. **tiny-init `fap.root=/dev/*` and `LABEL=`**: require the ext4 label
   `fap-root` (as the `lp:` path does) before the read-write mount, or mount
   read-only first, check, then remount.
8. **Docs: remove copy-pasteable dangerous lines** or put them under an
   "OWNER ONLY, do not run" fence with placeholders that fail if pasted
   (e.g. `<OWNER-TYPES-THIS>`):
   - AGENTS.md:59, 65-69 (mark them N100-only);
   - HANDOFF.md:65-66, 71-76;
   - INSTALL.md:501, 540, 552;
   - porting-cookbook.md:74, 393-396;
   - porting.md:18;
   - n100-power-and-install.md:236-245.

   Fix the stale table in devices/oneplus-waffle/README.md:232-238. Add a
   first line to AGENTS.md pointing here.
9. **Hardware test gates**: replace `FAP_SPEAKER_APPROVED=yes` with an
   interactive prompt on a TTY (the owner types the amp name).
10. **CI check** (tools/ci/): fail when a new `of=/dev`, `fastboot flash`,
    `qbootctl -s`, `--slot=all`, `--set-active`, `mkfs` or
    `rmtfs.service` enable appears outside an allow-listed set of files.
11. **opencode permissions** for this repo, as a second line of defence
    behind gap 1. Agent file `.opencode/agent/fap-safe.md` (or
    `~/.config/opencode/agents/fap-safe.md`). Rules are checked in order and
    **the last match wins**, so the broad allows come first and the
    denials last:

```yaml
---
description: fedora-atomic-phone, safe work only (docs, packaging, host tests). Never touches a phone.
mode: primary
permissions:
  # 1. Default: nothing.
  - action: "*"
    resource: "*"
    effect: deny

  # 2. Read and search inside the repo.
  - action: read
    resource: "*"
    effect: allow
  - action: glob
    resource: "*"
    effect: allow
  - action: grep
    resource: "*"
    effect: allow

  # 3. Edit inside the repo (dangerous paths are denied again below).
  - action: edit
    resource: "*"
    effect: allow

  # 4. Shell: a short allow list of host-only, read-only or test commands.
  - action: shell
    resource: "git status*"
    effect: allow
  - action: shell
    resource: "git diff*"
    effect: allow
  - action: shell
    resource: "git log*"
    effect: allow
  - action: shell
    resource: "git show*"
    effect: allow
  - action: shell
    resource: "git add *"
    effect: allow
  - action: shell
    resource: "git commit *"
    effect: allow
  - action: shell
    resource: "ls*"
    effect: allow
  - action: shell
    resource: "cat *"
    effect: allow
  - action: shell
    resource: "head *"
    effect: allow
  - action: shell
    resource: "tail *"
    effect: allow
  - action: shell
    resource: "wc *"
    effect: allow
  - action: shell
    resource: "grep *"
    effect: allow
  - action: shell
    resource: "rg *"
    effect: allow
  - action: shell
    resource: "diff *"
    effect: allow
  - action: shell
    resource: "sha256sum *"
    effect: allow
  - action: shell
    resource: "shellcheck *"
    effect: allow
  - action: shell
    resource: "python3 -m unittest*"
    effect: allow
  - action: shell
    resource: "tools/tests/run.sh*"
    effect: allow
  - action: shell
    resource: "tools/check-spdx.sh*"
    effect: allow
  - action: shell
    resource: "tools/check-device.sh *"
    effect: allow
  - action: shell
    resource: "tools/support-matrix.py*"
    effect: allow
  - action: shell
    resource: "tools/recon/lp-parse.py *"
    effect: allow
  - action: shell
    resource: "just --list"
    effect: allow
  - action: shell
    resource: "just *info"
    effect: allow
  - action: shell
    resource: "just *check"
    effect: allow

  # 5. Shell denials (last, so they beat the allows above).
  #    Phone access:
  - action: shell
    resource: "*fastboot*"
    effect: deny
  - action: shell
    resource: "*adb*"
    effect: deny
  - action: shell
    resource: "*qdl*"
    effect: deny
  - action: shell
    resource: "*edl*"
    effect: deny
  - action: shell
    resource: "*sahara*"
    effect: deny
  - action: shell
    resource: "*firehose*"
    effect: deny
  - action: shell
    resource: "*ssh*"
    effect: deny
  - action: shell
    resource: "*scp*"
    effect: deny
  - action: shell
    resource: "*rsync*"
    effect: deny
  - action: shell
    resource: "*telnet*"
    effect: deny
  - action: shell
    resource: "*oneplus12*"
    effect: deny
  - action: shell
    resource: "*172.16.42.*"
    effect: deny
  - action: shell
    resource: "*fap-dev*"
    effect: deny
  - action: shell
    resource: "*flash*"
    effect: deny
  - action: shell
    resource: "*serial-shell*"
    effect: deny
  - action: shell
    resource: "*try-kernel*"
    effect: deny
  - action: shell
    resource: "*tools/recon/*.sh*"
    effect: deny
  - action: shell
    resource: "*scripts/rig*"
    effect: deny
  #    On-phone tools:
  - action: shell
    resource: "*bootctl*"
    effect: deny
  - action: shell
    resource: "*fap-switch-os*"
    effect: deny
  - action: shell
    resource: "*fap-android-boot*"
    effect: deny
  - action: shell
    resource: "*fap-boot-ok*"
    effect: deny
  - action: shell
    resource: "*fap-modem*"
    effect: deny
  - action: shell
    resource: "*fap-hw-*"
    effect: deny
  - action: shell
    resource: "*rmtfs*"
    effect: deny
  #    Block devices, root, disks:
  - action: shell
    resource: "dd *"
    effect: deny
  - action: shell
    resource: "*of=*"
    effect: deny
  - action: shell
    resource: "*/dev/*"
    effect: deny
  - action: shell
    resource: "*sudo*"
    effect: deny
  - action: shell
    resource: "*pkexec*"
    effect: deny
  - action: shell
    resource: "*su -*"
    effect: deny
  - action: shell
    resource: "*mkfs*"
    effect: deny
  - action: shell
    resource: "*mke2fs*"
    effect: deny
  - action: shell
    resource: "*wipefs*"
    effect: deny
  - action: shell
    resource: "*blkdiscard*"
    effect: deny
  - action: shell
    resource: "*fdisk*"
    effect: deny
  - action: shell
    resource: "*gdisk*"
    effect: deny
  - action: shell
    resource: "*parted*"
    effect: deny
  - action: shell
    resource: "*losetup*"
    effect: deny
  - action: shell
    resource: "*mount*"
    effect: deny
  - action: shell
    resource: "*cryptsetup*"
    effect: deny
  - action: shell
    resource: "*dmsetup*"
    effect: deny
  - action: shell
    resource: "*lpmake*"
    effect: deny
  - action: shell
    resource: "*logical-partition*"
    effect: deny
  - action: shell
    resource: "*--privileged*"
    effect: deny
  - action: shell
    resource: "*make-disk*"
    effect: deny
  - action: shell
    resource: "*make-bootimg*"
    effect: deny
  - action: shell
    resource: "*just*disk*"
    effect: deny
  #    Boot config and services, host or phone:
  - action: shell
    resource: "*rpm-ostree*"
    effect: deny
  - action: shell
    resource: "*ostree admin*"
    effect: deny
  - action: shell
    resource: "*bootc *"
    effect: deny
  - action: shell
    resource: "*efibootmgr*"
    effect: deny
  - action: shell
    resource: "*kernel-install*"
    effect: deny
  - action: shell
    resource: "*grub2-*"
    effect: deny
  - action: shell
    resource: "*systemctl*"
    effect: deny
  - action: shell
    resource: "*reboot*"
    effect: deny
  - action: shell
    resource: "*poweroff*"
    effect: deny
  #    Container-only build scripts, run by hand:
  - action: shell
    resource: "*tools/image/*"
    effect: deny
  - action: shell
    resource: "*run-layer*"
    effect: deny
  - action: shell
    resource: "*devices/*/build*"
    effect: deny
  - action: shell
    resource: "*boot/*/build*"
    effect: deny
  #    Deletion and escape hatches:
  - action: shell
    resource: "*rm -r*"
    effect: deny
  - action: shell
    resource: "*rm -f*"
    effect: deny
  - action: shell
    resource: "*-delete*"
    effect: deny
  - action: shell
    resource: "*-exec*"
    effect: deny
  - action: shell
    resource: "*xargs*"
    effect: deny
  - action: shell
    resource: "*bash -c*"
    effect: deny
  - action: shell
    resource: "*sh -c*"
    effect: deny
  - action: shell
    resource: "*eval *"
    effect: deny
  - action: shell
    resource: "*python3 -c*"
    effect: deny
  - action: shell
    resource: "*perl -e*"
    effect: deny
  - action: shell
    resource: "*git push*"
    effect: deny
  - action: shell
    resource: "*review-pr*"
    effect: deny
  - action: shell
    resource: "*update-review*"
    effect: deny
  - action: shell
    resource: "*OnePlus12*"
    effect: deny
  - action: shell
    resource: "*fap-build*"
    effect: deny
  - action: shell
    resource: "*backup*"
    effect: deny

  # 6. Edit denials: files whose mistakes reach the phone (rule 3).
  - action: edit
    resource: "tools/flash.sh"
    effect: deny
  - action: edit
    resource: "tools/fap-dev"
    effect: deny
  - action: edit
    resource: "tools/tests/test-flash.sh"
    effect: deny
  - action: edit
    resource: "tools/tests/test-fap-dev.sh"
    effect: deny
  - action: edit
    resource: "tools/recon/*"
    effect: deny
  - action: edit
    resource: "Justfile"
    effect: deny
  - action: edit
    resource: "Containerfile"
    effect: deny
  - action: edit
    resource: "boot/*"
    effect: deny
  - action: edit
    resource: "kernels/*"
    effect: deny
  - action: edit
    resource: "kmod/*"
    effect: deny
  - action: edit
    resource: "devices/*/device.env"
    effect: deny
  - action: edit
    resource: "devices/*/build"
    effect: deny
  - action: edit
    resource: "devices/*/installroot/*"
    effect: deny
  - action: edit
    resource: "devices/*/netroot/*"
    effect: deny
  - action: edit
    resource: "devices/*/rootfs/*"
    effect: deny
  - action: edit
    resource: "devices/*/dts/*"
    effect: deny
  - action: edit
    resource: "devices/*/build-env/*"
    effect: deny
  - action: edit
    resource: "devices/*/ucm/*"
    effect: deny
  - action: edit
    resource: "devices/*/tplg/*"
    effect: deny
  - action: edit
    resource: "devices/*/kmod/*"
    effect: deny
  - action: edit
    resource: "devices/*/*.sh"
    effect: deny
  - action: edit
    resource: "devices/_template/*"
    effect: deny
  - action: edit
    resource: "AGENTS.md"
    effect: deny
  - action: edit
    resource: "CLAUDE.md"
    effect: deny
  - action: edit
    resource: "HANDOFF.md"
    effect: deny
  - action: edit
    resource: "docs/agent-tasks/safety-audit.md"
    effect: deny
  - action: edit
    resource: ".opencode/*"
    effect: deny
  - action: edit
    resource: "opencode.json"
    effect: deny
  - action: edit
    resource: ".github/*"
    effect: deny

  # 7. Never read secrets or phone data, never leave the repo.
  - action: read
    resource: "*.img"
    effect: deny
  - action: read
    resource: "*.simg"
    effect: deny
  - action: read
    resource: "*/.ssh/*"
    effect: deny
  - action: read
    resource: "*secrets*"
    effect: deny
  - action: external_directory
    resource: "*"
    effect: deny
---
Work only on the safe catalogue in docs/agent-tasks/safety-audit.md section 5.
Never run fastboot, adb, ssh, dd, sudo or anything that touches a phone or a
block device. If a task needs any of that, stop and write the plan for the
owner instead.
```

Notes on the block:
- Several patterns are deliberately broad (`*adb*`, `*flash*`, `*mount*`,
  `*/dev/*`, `*backup*`, `*ssh*`). They also block harmless commands
  whose text happens to contain those letters (for example
  `grep flash tools/README.md`). For a weak model, that is the right
  trade-off. Use the `grep` tool instead of shell `grep` for such searches.
- `just *build` (podman, host only, slow) is left out on purpose. Allow it
  only once gap 4 is fixed, because today a OnePlus 12 bootc image carries
  the unsafe `fap-android-boot` (B6).
- If HANDOFF.md must stay editable by the agent (AGENTS.md:4-6 asks agents
  to keep status docs current), let the agent edit `docs/status.md` and
  keep the HANDOFF.md denial. The owner moves the notes over.

## 5. Safe work catalogue (an agent may work here freely)

None of these can write to a phone, change what boots or damage hardware,
as long as rules 1-2 are kept while doing them.

| Area | Paths | Checks you may run |
|---|---|---|
| Documentation (not the safety sections, not runbook commands) | `docs/*.md` (not this file), `docs/decisions/`, `docs/hardware/*` prose, `README.md`, `CONTRIBUTING.md`, `LICENSING.md`, device `README.md`/`TODO.md`/`hidden-dependencies.md` prose | `tools/check-spdx.sh` |
| Feature/support data | `devices/*/features.yaml`, `devices/*/firmware.yaml` (data only), generated `docs/devices.md` | `tools/support-matrix.py`, `python3 -m unittest discover -s tools/tests -p 'test_*.py'` |
| Package lists (userspace only) | `desktops/*/packages*`, `layers/*/packages`, `base/packages` (not kernel, rmtfs, qbootctl or firmware packages) | `just DEVICE=… check` |
| Userspace config in the image | `desktops/*/rootfs/` (e.g. SDDM), `desktops/*/build` | review; no phone needed |
| Waydroid layer | `layers/waydroid/**` (nothing in it writes partitions; `fap-waydroid-init` only sets up Waydroid as root) | shellcheck |
| Update/pinning tooling | `tools/update/*.py`, `tools/update/*.yaml`, `tools/tests/test_update.py`, fixtures | `python3 -m unittest`, `tools/tests/run.sh` |
| Host-only parsers and tests | `tools/recon/lp-parse.py` (reads dump files), `tools/support-matrix.py`, `tools/dt-modules.py`, `tools/tests/*` except test-flash/test-fap-dev | `tools/tests/run.sh` (fakes replace adb/fastboot/ssh) |
| Lint | any shell script, read-only | `shellcheck -x …` |
| Research notes | new `.md` files under `docs/` or `docs/agent-tasks/` | none |
| Reading phone logs | **only copies the owner has placed in the repo or a scratch folder.** A live `ssh` is a root/sudo shell (U1, U2) and is **not** read-only. If the owner wants live log reading, they set up a non-root account with an ssh key restricted by `command="journalctl -b --no-pager",restrict` in `authorized_keys`; only that key may be given to an agent | `grep`, `less` on the copies |

Everything else (boot images, kernels, DTs, initramfs, device layers,
installroot overlays, flashing, RAM boots, hardware tests) is **owner
work**. An agent may write a plan or a diff for review, but never builds,
installs or runs it on its own.
