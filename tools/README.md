<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# tools/

Host-side tools for building, flashing and exploring phones. They run on
macOS or Linux; the build tools need `podman`, the phone tools need
`fastboot`/`adb` (android-tools) and OpenSSH.

**Safety model.** Only `flash.sh` writes to a phone, and it refuses the
partitions that can brick it (see below). Everything else is read-only or
RAM-only (`fastboot boot`). Tools that go over SSH read; the only things they
create on the phone are temporary directories in `/tmp`, a read-only loop
device (`extract-from-super.sh`) and the system clock (`fap-dev clock`).
One actor talks to the phone at a time: agents delegating work must tell
subagents not to run these tools.

| Tool | What it does | Writes to the phone? |
|---|---|---|
| [`fap-dev`](#fap-dev-the-dev-loop) | RAM-boot dev loop: fresh fastboot session, `fastboot boot`, find the phone, ssh/scp, serve a netroot, set the clock, audit, getvar summary | no (RAM boot, clock) |
| [`flash.sh`](#flashsh) | flash a built image following `device.env` | **yes**, guarded |
| [`recon/android-recon.sh`](#recon-surveying-a-phone) | adb survey of a phone running Android | no |
| [`recon/lp-parse.py`](#recon-surveying-a-phone) | parse a dynamic `super` partition's LP metadata | no (host only) |
| [`recon/extract-from-super.sh`](#recon-surveying-a-phone) | copy files out of `vendor_a` etc. inside `super` | no (read-only loop + mount) |
| [`recon/linux-hw-inventory.sh`](#recon-surveying-a-phone) | hardware inventory of a phone running our Linux | no |
| [`recon/hidden-deps-audit.sh`](#fap-dev-the-dev-loop) | phone-side half of `fap-dev audit` | no |
| `check-device.sh` | validate a `devices/<id>/` folder | – |
| `build-dtb.sh` | build a board DTB against a Linux tree (container) | – |
| `build-kmod.sh` | build an out-of-tree module against a Fedora kernel-devel (container) | – |
| `dt-modules.py` | which kernel modules drive a DT's enabled nodes | – |
| `make-disk.sh` | bootc image → flashable disk images | – |
| `serial-shell.py` | run commands on the ramboot USB serial shell (no pyserial) | as you type |
| [`update/`](#update-package-pinning-and-update-review) | lockfiles (`lock.py`), weekly update diff (`check-updates.py`), local-LLM risk review of update PRs (`review.py`, `review-pr.sh`) | – |
| `tests/run.sh` | tests for the tools above, with fakes (no phone) | – |

## fap-dev: the dev loop
`tools/fap-dev <command>`; `tools/fap-dev help` lists everything.

```sh
# Boot an image from RAM (nothing written): fresh ABL session, fastboot boot,
# wait for the USB gadget, then for SSH.
tools/fap-dev ramboot out/ramboot/ramboot.img
# In a second terminal, before or right after the boot: serve the netroot.
# Waits until the host has its 172.16.42.x address, then serves (foreground).
tools/fap-dev serve out/netroot
# Then:
tools/fap-dev ssh                    # interactive root shell
tools/fap-dev ssh 'dmesg | tail'     # one command (quote it as one argument)
tools/fap-dev clock                  # set the phone's clock from the host
tools/fap-dev scp-to kmod/x.ko /tmp/ ; tools/fap-dev scp-from /var/log/fap-boot-state .
tools/fap-dev audit > audit.md       # hidden-dependency audit
tools/fap-dev state                  # phone in fastboot: getvar summary
```

| Command | Notes |
|---|---|
| `wait-fastboot [s]` | prints the serial; refuses if several phones are attached (set `FAP_SERIAL`) |
| `fresh-fastboot` | `fastboot reboot bootloader`, waits for the phone to leave and come back, checks `is-userspace: no`. Needed because after a `fastboot boot` that didn't hand over, the next one in the same ABL session fails with `Load Error` (N100), and fastbootd has no `boot` command |
| `ramboot <img> [--reuse-session] [--no-ssh]` | `--reuse-session` only reboots if the phone is in fastbootd; `--no-ssh` stops once the gadget is up (tiny-init without a netroot has telnet and USB serial, not SSH) |
| `state [-o raw.txt]` | product, slot, unlocked, bootloader/baseband versions, per-slot successful/unbootable/retry, anti-rollback counters (`ap-ar-*`, `*-ar`, `anti*`, `rollback*`), with warnings (locked, unbootable slot, fastbootd). The raw file has the serial |
| `addr` | `172.16.42.1` if the host got a `172.16.42.x` lease from the phone; otherwise pings `ff02::1` on every host interface with a 169.254.x/172.16.42.x address and prints the neighbour that isn't the host, as `fe80::…%IF` |
| `ssh`, `scp-to`, `scp-from` | user `root`, `StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null` (every RAM boot has new host keys); IPv6 addresses are bracketed for scp |
| `serve <dir> [port]` | `python3 -m http.server --bind 172.16.42.2`, port 8000; `FAP_SERVE_BIND` to bind elsewhere |
| `clock` | `date -u -s` with the host's UTC time. The RTC is not written. An unset clock (1970) makes RPM/firmware signature checks fail ("not live yet", looks like `BAD`) |
| `audit` | unclaimed-but-on clocks, non-zero interconnect votes per consumer, `pm_genpd_summary`, dummy regulators, deferred devices; see devices/oneplus-billie2/hidden-dependencies.md for how to read it |

Environment: `FAP_SERIAL`, `FAP_PHONE` (skip discovery), `FAP_IF` (search
one interface), `FAP_USER`, `FAP_SSH_OPTS`, `FAP_GADGET_PRODUCT` (default
`ramboot debug shell`, set by boot/android-bootimg/tiny-init), `FAP_TIMEOUT`
(default 120 s). Gadget detection: macOS `ioreg -p IOUSB`, Linux
`/sys/bus/usb/devices/*/product`.

Not tested against a phone yet (2026-11-20): written from the commands used
by hand on the N100 and Pixel 8 that day, tested with fakes.

## flash.sh
`tools/flash.sh devices/<id> <outdir>` (or `just flash`) flashes `boot.img`/
`uboot.img`, `esp.img` and `rootfs.img` per `device.env` (`FLASH_*`).
`FLASH_DRY_RUN=1` prints the fastboot commands without running them.

Refuses, whatever `device.env` says (with `_a`/`_b` suffixes):
- Qualcomm identity (`modemst1/2 fsg fsc persist`), boot chain (`xbl abl tz
  hyp rpm aop devcfg keymaster vbmeta …`) and firmware (`modem dsp bluetooth`)
- Google Tensor / Exynos: `abl bl1 bl2 bl31 gcf gsa gsa_bl1 ldfw pbl tzsw
  bootloader radio modem efs efs_backup modem_userdata persist mfg_data
  devinfo avb_custom_key`
- the device's own `PROTECTED_PARTITIONS` (space-separated, shell globs:
  `PROTECTED_PARTITIONS="oem_* cdt"`)
- `fastboot flashing lock*` / `oem lock`: never relock
- slot switches (`--set-active`, `set_active`) unless `ALLOW_SET_ACTIVE=1`:
  on phones with an A/B boot chain the other slot may hold an older
  bootloader (anti-rollback). Check both slots first (`fap-dev state`).

## recon: surveying a phone
Raw outputs hold serial numbers, MACs and vendor files: keep them out of git
(the N100 notebook keeps them in `UBports-N100/log/…/raw/`, git-ignored).

**A new phone, still on Android** (USB debugging on):
```sh
tools/recon/android-recon.sh ~/notes/<phone>/recon-$(date +%Y%m%d)
# -> raw/getprop.txt etc. + summary.md (model, SoC, slot, lock, AVB,
#    dynamic partitions, A/B boot-chain warning). Then, in the bootloader:
tools/fap-dev state -o ~/notes/<phone>/getvar-all.txt
```
`ADB_SERIAL` picks a phone. `--summary <dir>` rebuilds summary.md from raw/.

**Files from `vendor`/`odm` inside a dynamic `super`**, from our Linux
running on the phone (RAM boot is enough):
```sh
tools/recon/extract-from-super.sh --list                     # LP table
tools/recon/extract-from-super.sh vendor_a out/vendor-fw /firmware /etc/acdbdata
```
It dumps super's first MiB, finds the byte range with `lp-parse.py`, then on
the phone `losetup -r -o <off> --sizelimit <size>`, `mount -o ro,noload`
(ext4: no journal replay; erofs falls back to `ro`), tars the paths back, and
always unmounts and detaches. `--super <dev>` if it isn't
`/dev/disk/by-partlabel/super`. Partitions with several extents are refused
(use `lp-parse.py --json` and dmsetup by hand).

`lp-parse.py` alone, on any dump (`dd if=…/super bs=1M count=1`):
```sh
tools/recon/lp-parse.py super-head.bin                       # table
tools/recon/lp-parse.py super-head.bin --partition vendor_a  # "<offset> <size>" in bytes
tools/recon/lp-parse.py super-head.bin --json --slot 1
```

**Inventory of a phone running our Linux** (what probed, what's waiting):
```sh
tools/recon/linux-hw-inventory.sh out/inventory-$(date +%Y%m%d)
```
raw/ gets dmesg, the live DTB (decompiled to device-tree.dts if `dtc` is
installed), clk/interconnect/genpd/regulator summaries, deferred devices,
platform drivers, i2c/spi, input, drm, net, iio, power supplies, thermal,
remoteprocs, firmware-load messages; summary.md pulls out the porting-relevant
parts. The collector (`linux-hw-collect.sh`) also runs on the phone by hand:
`sh linux-hw-collect.sh > inv.tar`.

## update: package pinning and update review
Full description: [docs/updates.md](../docs/updates.md). Needs podman (lock,
changelogs) and PyYAML (`uv run --with pyyaml …` works too).
```sh
tools/update/lock.py --list-steps            # which dnf steps each image has
tools/update/lock.py --target netroot        # re-lock one image into lock/
just update-check                            # re-lock into a temp dir, show the diff
just update-check --write --changelogs       # update lock/ in place, with changelogs
just PINNED=1 DESKTOP=tty build              # build exactly lock/oneplus-billie2-tty
FAP_PINNED=1 boot/android-bootimg/make-netroot.sh <out>   # pinned netroot
just update-review <pr> --dry-run            # local-LLM review of an update PR, printed
```

## Tests
`tools/tests/run.sh` runs everything (bash tests + `test_lp_parse.py` +
`test_update.py`; CI runs the Python ones via `unittest discover`).
Inside the tests `adb`, `fastboot`, `ssh`, `scp` and `telnet` on `PATH` are
shims that fail, so a test can't reach a connected phone; the tools are
pointed at fakes through `FASTBOOT`, `ADB`, `SSH`, `SCP`, `FAP_DEV`,
`FAP_SYSROOT`, `FAP_DMESG`. Lint: `shellcheck -x tools/fap-dev tools/*.sh
tools/recon/*.sh tools/tests/*.sh` (clean with ShellCheck from Fedora 45).
