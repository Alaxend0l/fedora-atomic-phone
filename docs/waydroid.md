<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Waydroid (Android apps) on the N100

Status: **branch `waydroid`, untested on the phone.** Researched and built
on 2026-11-20; the installroot image with Waydroid builds (`podman build`),
nothing has run on the N100 yet. Guesses are marked *(guess)*.

Waydroid runs a LineageOS 20 (Android 13) system in an LXC container and
shows it through Wayland. On our system it needs: binder (kernel), the
`waydroid` package (Fedora), ~1 GB of LineageOS images downloaded on the
phone, and Mesa freedreno inside the container for the GPU.

## What's on the branch
| File | What |
|---|---|
Waydroid is an **opt-in layer** (`layers/waydroid/`, decision 0003): never in
the default image. `just LAYERS=waydroid build`, or
`make-devroot.sh <device> <desktop> <out> waydroid`; the N100's
`installroot/make-installroot.sh` includes it.

| File | What |
|---|---|
| `layers/waydroid/packages` | `waydroid` (pulls `lxc`, `python3-gbinder`, `libgbinder`, `nftables`, `dnsmasq`) |
| `layers/waydroid/rootfs/usr/libexec/fap-waydroid-init` | on-phone setup: checks binderfs, `waydroid init`, writes our Android properties (density and Mesa options from the device's `/usr/lib/fap/waydroid.conf`), `waydroid upgrade -o` |
| `layers/waydroid/rootfs/usr/lib/systemd/system/waydroid-container.service.d/50-fap-binderfs.conf` | orders the container service after `dev-binderfs.mount` |
| `layers/waydroid/rootfs/usr/share/waydroid-extra/channels.cfg` | official OTA URLs (Fedora ships them empty) |
| `devices/oneplus-billie2/rootfs/usr/lib/fap/waydroid.conf` | N100 defaults: density 320, `noubwc` |

`waydroid-container.service` is enabled by the package's `%post` (Fedora
preset), so it starts at boot: it mounts binderfs, links
`/dev/{binder,hwbinder,vndbinder}` and idles (a Python process) until a
session asks for Android. It is also D-Bus-activatable (`id.waydro.Container`),
so `systemctl disable waydroid-container` saves that RAM if wanted; the first
`waydroid` call then starts it. The image build was checked:
`podman build` OK, `systemctl cat waydroid-container` shows our drop-in,
`load_channels()` returns our URLs.

## 1. Kernel: nothing to build
Checked in `quay.io/fedora/fedora-silverblue:45`
(`/usr/lib/modules/7.3.4-300.fc45.aarch64/config` + `modules.builtin`):

| Needs | Fedora 7.3.4 aarch64 | |
|---|---|---|
| binder | `# CONFIG_ANDROID_BINDER_IPC is not set`, **`CONFIG_ANDROID_BINDER_IPC_RUST=y`**; `modules.builtin` lists `kernel/drivers/android/binder/rust_binder.ko` | built in (Rust binder) |
| binderfs | part of Rust binder: `drivers/android/binder/Makefile` always links `rust_binderfs.o`; registers filesystem `binder` (`rust_binderfs.c` `init_rust_binderfs`) | built in. (`CONFIG_ANDROID_BINDERFS` depends on the C binder, hence absent) |
| default devices | `CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"`: each binderfs mount starts with these three plus `binder-control` | |
| ashmem | gone from mainline; Waydroid sets `sys.use_memfd=true` when `/dev/ashmem` is missing (`tools/helpers/lxc.py` make_base_props); `CONFIG_MEMFD_CREATE=y` | ok |
| PSI (Android lmkd) | `CONFIG_PSI=y`, not default-disabled | ok |
| namespaces, cgroups | `USER_NS PID_NS NET_NS IPC_NS UTS_NS`, cgroup v2 controllers =y | ok |
| network | `BRIDGE VETH NF_TABLES NFT_NAT NFT_MASQ NFT_CHAIN_NAT` =m, all present in our rootfs's module tree; `IP_NF_IPTABLES`/`XT_*` =m for Android's netd | ok |
| 32-bit apps | `CONFIG_COMPAT=y`, Kryo 260 (A73/A53) has AArch32, so Waydroid picks `arm64` (not `arm64_only`) images | ok |
| page size | `CONFIG_ARM64_4K_PAGES=y` | ok |

The C binder can't be built out of tree as a fallback: `ANDROID_BINDER_IPC`
is a `bool` and `ANDROID_BINDER_IPC_RUST` depends on `!ANDROID_BINDER_IPC`
(`drivers/android/Kconfig` in v7.3). We don't need it.

Waydroid with the Rust binder: works since Waydroid 1.6 on binderfs-only
kernels (`tools/helpers/drivers.py`: mounts `binder` at `/dev/binderfs`,
allocates nodes via `binder-control`), and Fedora's package adds
`dev-binderfs.mount` plus symlinks `/dev/{binder,hwbinder,vndbinder}`.
Known Rust-binder bugs reported against Waydroid:
- spinlock deadlock under memory pressure, broken audio
  ([#2157](https://github.com/waydroid/waydroid/issues/2157),
  [#2163](https://github.com/waydroid/waydroid/issues/2163)): fixed in
  6.18.6 / 6.19 (torvalds/linux 361e0ff4, 8f589c9c), so in 7.3.
- NULL dereference from a bindgen 0.73.0/.1 miscompile
  ([#2411](https://github.com/waydroid/waydroid/issues/2411)): Fedora 45 has
  `bindgen-cli-0.72.1`, so very likely not us *(guess: checked the repo, not
  the kernel's koji buildroot)*.
- **open:** `rust_binder: Failed to allocate buffer ... ENOSPC` for
  transactions over ~1 MB, crashing HALs/surfaceflinger
  ([#2422](https://github.com/waydroid/waydroid/issues/2422), linux 7.2.x).
  May hit us; watch `dmesg | grep rust_binder`.
- The anbox-binder trap (#2422 comments): if Waydroid probes before binderfs
  is mounted, it creates `anbox-*` nodes and stores those names in
  `waydroid.cfg`, which break after a reboot. Our drop-in
  (`After=/Requires=dev-binderfs.mount`) avoids the race.

## 2. Packaging (Fedora `waydroid-1.6.3-2.fc45`)
From `waydroid.spec` on src.fedoraproject.org (rpms/waydroid) and the RPM
contents:
- `USE_NFTABLES=1`: `waydroid-net.sh` uses nft (`table inet lxc`, `ip lxc`
  NAT) on bridge `waydroid0`, 192.168.240.1/24, and sets
  `net.ipv4.ip_forward=1` while running.
- `setup-firewalld.patch`: puts `waydroid0` in firewalld's `trusted` zone at
  runtime. Our image runs firewalld (pulled in by Plasma), so this matters.
- `mount-secontext.patch`: every Waydroid mount gets
  `-o context="system_u:object_r:waydroid_rootfs_t:s0"`. We boot with
  `selinux=0`; libmount drops SELinux mount options when SELinux is disabled
  (util-linux `libmount/src/hook_selinux.c`, `is_selinux_enabled()` → remove),
  so the mounts should still work *(reasoned from source, untested)*.
- OTA channels blanked in `tools/config/__init__.py`; our `channels.cfg`
  restores `https://ota.waydro.id/{system,vendor}`.
- `waydroid-selinux` is pulled in only if `selinux-policy-targeted` is
  installed; harmless with `selinux=0`.

### dnsmasq: two instances, no conflict
Ours (`fap-usb-dhcp.service`): `--port=0` (no DNS) `--interface=usb0
--bind-dynamic`. Waydroid's (`waydroid-net.sh`): `--bind-interfaces
--listen-address 192.168.240.1 --interface=waydroid0 --except-interface=lo
--conf-file=/dev/null`. DNS: only Waydroid's listens on :53, on
192.168.240.1. DHCP: with `--bind-interfaces`/`--bind-dynamic` dnsmasq sets
`SO_REUSEADDR|SO_REUSEPORT` on its :67 socket "so that more than one instance
can bind port 67" (dnsmasq `src/dhcp.c` make_fd), and with exactly one
`--interface` it `SO_BINDTODEVICE`s to it (`src/dhcp-common.c` whichdevice).
Both are true for both instances, so each only sees its own interface. This
is the libvirt/OpenStack pattern *(from source; to be confirmed in test 6)*.
Fedora's own `dnsmasq.service` stays disabled.

## 3. Images and GPU
**Images** are downloaded on the phone, not baked into the root: the
2026-10 arm64 builds are `lineage-20.0-…-VANILLA-waydroid_arm64-system.zip`
912 MB (GAPPS 1326 MB) + `…-MAINLINE-waydroid_arm64-vendor.zip` 148 MB
(ota.waydro.id JSON, files on SourceForge). They'd triple the installroot
tarball and change on their own schedule. Offline alternative: unzip both on
the Mac and copy `system.img` + `vendor.img` to `/etc/waydroid-extra/images/`
on the phone; `waydroid init` then uses them without downloading
(`preinstalled_images_paths` in `tools/config/__init__.py`).

**GPU path.** Waydroid passes the first `/dev/dri/renderD*` whose driver
isn't nvidia (`tools/helpers/gpu.py` getDriNode; override with
`drm_device = /dev/dri/renderDxxx` in `[waydroid]` of waydroid.cfg). With no
host gralloc HAL (we have none) it sets `ro.hardware.gralloc=gbm`,
`ro.hardware.egl=mesa`, `gralloc.gbm.device=<node>` and, for driver `msm`,
`ro.hardware.vulkan=freedreno` (`lxc.py` make_base_props). On the N100 that
should be `renderD128`, driver msm (Adreno 610) *(guess: one render node;
fap-waydroid-init prints it)*.

I inspected the current vendor image (lineage-20.0-20261022 MAINLINE arm64,
ext4): it ships **Mesa 26.0.8** (`lib64/libgallium_dri.so`,
`lib64/hw/vulkan.freedreno.so`, `gralloc.minigbm_gbm_mesa.so`), both
containing the `FD610` GPU id and the `noubwc` debug flag, and the
Android property lookup with `debug.`/`vendor.`/`mesa.` prefixes. So
freedreno for the A610 is there, and UBWC can be switched off with a
property: Mesa maps `FD_MESA_DEBUG` → `debug.mesa.fd.mesa.debug` (Mesa
`src/util/os_misc.c` os_get_android_option; plain `mesa.*` only before API
33, and LineageOS 20 is API 33). `fap-waydroid-init` writes into
`[properties]`:
```
debug.mesa.fd.mesa.debug = noubwc   # GL (freedreno), as /etc/environment on the host
debug.mesa.tu.debug = noubwc        # Vulkan (turnip)
ro.sf.lcd_density = 320             # OxygenOS's value on this phone
```
Why UBWC off inside too: Android's buffers are shared with KWin, which may
scan them out directly; the host's UBWC problem is GPU vs display
disagreeing, so a UBWC buffer from Android would likely show the same tile
garbage *(guess)*.

**Software fallback** (if the GPU path misrenders or crashes):
`sudo /usr/libexec/fap-waydroid-init --software` sets
`ro.hardware.gralloc=default`, `ro.hardware.egl=swiftshader` (Waydroid's
documented no-GPU setup, docs.waydro.id "Get Waydroid to work through a VM")
and runs `waydroid upgrade -o`. `--hardware` switches back. Slow on 8 small
cores, but usable for simple apps.

## 4. Plasma Mobile integration
- **Launchers:** the package ships `Waydroid.desktop` (Exec `waydroid`,
  actions "Stop Waydroid", "Initialize Waydroid"). Once a session runs,
  Waydroid writes one `~/.local/share/applications/waydroid.<package>.desktop`
  per Android app, which Plasma Mobile's app drawer should list *(guess:
  KSycoca picks up new files in that directory; if not, `kbuildsycoca6`)*.
- **Full UI vs multi-window:** default is full UI (`waydroid show-full-ui`,
  one window with the whole Android desktop). Plasma Mobile maximizes every
  window, so multi-window (`waydroid prop set persist.waydroid.multi_windows
  true`, then restart the session) makes each Android app its own entry in the
  task switcher; worth trying after full UI works.
- **Screen size:** Waydroid sizes Android to the Wayland output; Plasma
  Mobile's status bar and navigation panel may cover parts of it. Tune with
  `waydroid prop set persist.waydroid.height <px>` / `width`, or
  `height_padding`/`width_padding` (docs.waydro.id
  usage/waydroid-prop-options), then restart the session. KWin's output
  scale on this phone may make Android see logical (scaled) pixels *(guess,
  check in test 7)*. Density: 320 from the N100's stock
  `ro.sf.lcd_density` (UBports-N100
  `log/hw-inventory/20261120-134342/raw/android-props.txt`); smaller (e.g.
  280) shows more; change with `fap-waydroid-init --density 280`.
- **Input:** touch goes through KWin as Wayland touch events, so our
  `ili9882n-ts` driver needs nothing extra. On-screen keyboard: Android's own
  (LineageOS AOSP keyboard) inside the container.
- **Audio:** the N100 has no sound card yet (docs/hardware/n100-audio.md).
  Waydroid's audio HAL talks to PipeWire's pulse socket; with no real sink
  Android plays into nothing. Not a blocker.
- **Sensors, camera, telephony:** stubbed (`waydroid.stub_sensors_hal=1`
  without `waydroid-sensord`); no camera; no SMS/calls.

## 5. Install on the already-installed phone (no reflash)
Nothing below touches a partition other than the root filesystem's files.
Needs Wi‑Fi up on the phone and the USB link (`ssh root@172.16.42.1`).
From this repo's checkout on the Mac:
```sh
# 1. our files (the layer's, plus the device's defaults)
tar -C layers/waydroid/rootfs -cf - \
    usr/libexec/fap-waydroid-init \
    usr/lib/systemd/system/waydroid-container.service.d \
    usr/share/waydroid-extra \
  | ssh root@172.16.42.1 'tar -C / -xvf - && systemctl daemon-reload'
tar -C devices/oneplus-billie2/rootfs -cf - usr/lib/fap/waydroid.conf \
  | ssh root@172.16.42.1 'tar -C / -xvf -'
# 2. the package (clock must be set: `date`; chronyd does it once online)
ssh root@172.16.42.1 'dnf5 -y install --setopt=install_weak_deps=False waydroid'
# 3. images + properties (downloads ~1.06 GB; --gapps for Play Store)
ssh root@172.16.42.1 /usr/libexec/fap-waydroid-init
```
Then on the phone: app drawer → **Waydroid**. Fresh installs from a rebuilt
installroot already have steps 1–2.

## 6. Test plan (least → most risky)
Run `journalctl -f` and `dmesg -w` in a second SSH session throughout; a
hard reset during a test is data (compare with the reset history in
UBports-N100/log/).
1. **Read-only checks:** `grep binder /proc/filesystems` (expect `nodev
   binder`); `ls -l /dev/dri`; `cat /sys/class/drm/renderD128/device/uevent`
   (expect `DRIVER=msm`); `free -m`; `df -h /`; `date`.
2. **binderfs alone:** `mkdir -p /tmp/bfs && mount -t binder binder /tmp/bfs
   && ls -l /tmp/bfs && umount /tmp/bfs` (expect `binder`, `binder-control`,
   `hwbinder`, `vndbinder` and a `features` dir); `dmesg | tail`.
3. **Install** (section 5, steps 1–2). `systemctl cat waydroid-container`
   shows our drop-in. Reversible with `dnf remove`.
4. **Container service:** `systemctl start waydroid-container; systemctl
   status waydroid-container dev-binderfs.mount`; `ls -l /dev/binder
   /dev/hwbinder /dev/vndbinder` (symlinks into /dev/binderfs).
5. **Images:** `/usr/libexec/fap-waydroid-init` (starts the container
   service first, so `/dev/binder` exists before `waydroid init` probes it); check it printed
   `gralloc=gbm`, `egl=mesa`, `gralloc.gbm.device=/dev/dri/renderD128`, the
   two `debug.mesa.*` lines and `sys.use_memfd=true`; `grep -i binder
   /var/lib/waydroid/waydroid.cfg` must show `binder = binder` (not
   `anbox-binder`).
6. **Session from SSH** (before the GUI, easier to see errors):
   `sudo -u phone XDG_RUNTIME_DIR=/run/user/$(id -u phone)
   WAYLAND_DISPLAY=wayland-0 waydroid session start` (check the socket name
   with `ls /run/user/*/wayland-*`). Expect "Android with user 0 is ready".
   Then: `waydroid status`; `ip addr show waydroid0` (192.168.240.1);
   `nft list table ip lxc`; `sudo waydroid shell -- getprop
   ro.hardware.egl`; `sudo waydroid shell -- ping -c1 1.1.1.1`;
   `sudo waydroid logcat -d | grep -iE 'mesa|freedreno|gralloc|surfaceflinger' | head`;
   `dmesg | grep rust_binder` (ENOSPC = #2422).
   **USB DHCP still works:** on the Mac, renew the USB interface's lease
   (`sudo ipconfig set <if> DHCP`) and `ssh` again.
7. **Display:** `sudo -u phone … waydroid show-full-ui` (or tap the
   Waydroid icon). Look for: correct colors/no tile garbage (else UBWC: check
   the `debug.mesa` props reached `getprop`), the whole Android screen visible
   (else persist.waydroid.height/width), touch hitting the right spot.
   If the screen is garbage or black: `fap-waydroid-init --software`, retest,
   note the result.
8. **Apps:** download an F-Droid APK on the Mac, `scp` it to the phone,
   `sudo -u phone waydroid app install F-Droid.apk`; check the app appears in
   the Plasma Mobile drawer; launch from there; install one app through
   F-Droid (Android's networking via waydroid0 NAT + Wi‑Fi).
9. **Memory:** with Android and one app open: `free -m`,
   `cat /proc/pressure/memory`, `zramctl`; open a Plasma app alongside.
   `waydroid session stop` must give the memory back.
10. **Reboot persistence:** reboot, then tap Waydroid again: binder names
    still `binder`, session starts without re-running init.
11. **Multi-window:** `waydroid prop set persist.waydroid.multi_windows
    true`, restart the session, launch two apps from the drawer.

## 7. Known limitations
- **RAM:** 4 GB total (3.6 GB visible). Android 13 idles at ~1–1.5 GB
  *(guess, typical Waydroid numbers)* on top of Plasma Mobile. zram is on
  (Fedora's `zram-generator-defaults`, size = RAM). Stop the session
  (`waydroid session stop` or the "Stop Waydroid" action) when not in use.
  Waydroid's `suspend_action = freeze` freezes the container when idle.
- **No audio** (no sound card on the N100 yet).
- **UBWC off** (host and container) costs memory bandwidth; fixed together
  with the host issue (docs/roadmap.md).
- **Rust binder** open bug #2422 (large transactions), see section 1.
- **GAPPS:** the device isn't Play-certified; Play Store needs the manual
  registration at google.com/android/uncertified (docs.waydro.id FAQ).
  Many banking/DRM apps refuse to run in Waydroid anyway.
- No camera, telephony, GPS, sensors inside Android. Android's clock and
  network come from the host.
- Waydroid's state (`/var/lib/waydroid`, ~3–4 GB with images) lives on the
  root fs; fine on the plain ext4 root. On the future bootc/ostree system it
  is in `/var`, which persists across updates.

## 8. Roll back
On the phone (as root), nothing outside the root fs is involved:
```sh
waydroid session stop || true
systemctl stop waydroid-container dev-binderfs.mount
dnf5 -y remove waydroid            # leaves lxc etc.; add them if wanted
rm -rf /var/lib/waydroid /etc/waydroid-extra /usr/share/waydroid-extra \
       /usr/libexec/fap-waydroid-init \
       /usr/lib/systemd/system/waydroid-container.service.d
rm -rf /home/phone/.local/share/waydroid \
       /home/phone/.local/share/applications/waydroid.*.desktop
systemctl daemon-reload
```
Only `waydroid-net.sh` changes the network at runtime (bridge, nft tables,
`ip_forward`, firewalld runtime zone); a reboot clears all of it. Worst case
(the root fs gets into a bad state): reinstall the installroot tarball from a
RAM boot as in AGENTS.md "The installed system".

## Sources
- Waydroid source (v1.6.3 as packaged; github.com/waydroid/waydroid):
  `tools/helpers/drivers.py`, `gpu.py`, `lxc.py` (make_base_props),
  `images.py` (make_prop), `tools/config/__init__.py`, `data/scripts/waydroid-net.sh`.
- Fedora package: src.fedoraproject.org/rpms/waydroid (`waydroid.spec`,
  `dev-binderfs.mount`, `setup-firewalld.patch`, `mount-secontext.patch`,
  `no-apparmor.patch`); `dnf5 repoquery` in `fedora:45`.
- Kernel: Fedora 7.3.4-300.fc45 config + modules.builtin; v7.3
  `drivers/android/{Kconfig,binder/Makefile,binder/rust_binderfs.c}`.
- Mesa main `src/util/os_misc.c`; util-linux `libmount/src/hook_selinux.c`;
  dnsmasq `src/dhcp.c`, `src/dhcp-common.c` (GitHub mirror imp/dnsmasq).
- docs.waydro.id (github.com/waydroid/docs): usage/waydroid-prop-options.md,
  usage/install-on-desktops.md, faq/get-waydroid-to-work-through-a-vm.md.
- Scratch work (vendor image inspection, RPM contents):
  `/Users/alecjakopin/Develop/fap-build/research/waydroid/`.
