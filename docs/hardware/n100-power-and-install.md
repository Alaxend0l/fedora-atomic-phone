# N100: power management and the path to a real install

Research note, 2026-11-20. Nothing here has been run on the phone; it's a
plan for the maintainer to review. Labels: **[seen]** observed on this phone,
**[src]** read in source (path given), **[guess]** inference, untested.

Sources used throughout:
- mainline v7.3 `arch/arm64/boot/dts/qcom/sm6115.dtsi`, `sm4250-oneplus-billie2.dts`,
  `agatti.dtsi`, `qrb4210-rb2.dts` (`/Users/alecjakopin/Develop/fap-build/linux`)
- vendor DT: `UBports-N100/log/hw-inventory/20261120-134342/device-tree.dts`, `raw/thermal.txt`
- first mainline boot: `UBports-N100/log/first-linux-boot-20261120/{dmesg,round1,partitions,blkid}.txt`
- U-Boot master `c1958b5f` (`/Users/alecjakopin/Develop/fap-build/u-boot`)
- Fedora 45 kernel 7.3.4 config (`podman run quay.io/fedora/fedora-silverblue:45 grep … /usr/lib/modules/*/config`)
- Linux `drivers/clk/qcom/gcc-sm6115.c` (gh api, saved under `fap-build/research/power/`)

---------------------------------------------------------------------------

# Part A: power management

## A1. Status at a glance
| Area | Mainline state on SM6115 | On this N100 |
|---|---|---|
| PSCI | PSCI 1.0, OSI mode **[seen]** | `psci: [Firmware Bug]: failed to set PC mode: -3` at boot, then `CPUidle PSCI: Initialized CPU PM domain topology using OSI mode` **[seen]**. -3 is PSCI `DENIED`: firmware stays in OSI, which is what the DT's hierarchical domains want. Harmless **[guess, consistent with other QC SoCs]** |
| cpuidle | per-CPU "rail power collapse" + per-cluster GDHS and power collapse, OSI hierarchy (`sm6115.dtsi` l.207–370) **[src]** | probed; usage counters not yet read |
| System-level sleep | **missing**: no system/"CX" power domain above the clusters, no MPM node **[src]** | vendor has it (see A2) |
| s2idle | `CONFIG_SUSPEND=y`, `PM_SLEEP=y` (Fedora) | untested |
| RPM sleep stats | `qcom,rpm-stats` at 0x4690000 in `sm6115.dtsi` → `qcom_stats` (`=m`) **[src]** | module not loaded in RAM boots |
| RPM master stats | driver `QCOM_RPM_MASTER_STATS=m` exists, **no DT node** for SM6115 **[src]**; vendor has one at 0x45f0150 (APSS, MPSS, ADSP, CDSP, TZ) | — |
| cpufreq | `qcom-cpufreq-hw` (`=m`), schedutil default, EAS data (`capacity-dmips-mhz`, `dynamic-power-coefficient`) present | 0.3–1.8 GHz (cpu0–3), 0.3–1.61 GHz (cpu4–7) **[seen]** |
| LMh / hardware throttle IRQ | no `interrupts`/LMh on `cpufreq@f521000` **[src]** | — |
| Thermal | 16 tsens zones; **only `gpu-thermal` has a cooling map**; CPU zones: passive 90/95 °C with nothing attached, critical 110 °C **[src]** | 16 zones ~33 °C idle **[seen]** |
| PMIC temp | `pm6125-thermal`, `pmi632-thermal` (spmi-temp-alarm) via our DT | temp-alarm probes **[seen]** |
| Watchdog | `qcom,apss-wdt-sm6115` in DT, `QCOM_WDT=m` | not loaded/armed; systemd doesn't use it |
| Interconnect | `qnoc-sm6115` + `icc-smd-rpm`, in the boot path **[seen]** | works (UFS/USB up) |
| Wakeup sources | pwrkey (PON), Vol-Down `gpio-keys` with `wakeup-source` (our DT), RTC `rtc-pm8xxx` | keys verified with evtest; wake not tested |
| Crash logs | ramoops at 0xcbe00000 | mounted, empty **[seen]** |

## A2. The main gap: no system-level sleep (MPM)
Vendor DT (`device-tree.dts` l.9414ff, `qcom,lpm-levels`) has three levels:
CPU (`wfi`, `pc`), cluster `pwr` (`l2-wfi`, `l2-gdhs`, `l2-pc`) and a
top-level **`system`** cluster with `system-pc` (psci-mode 3 at shift 8,
entry 10.8 ms, exit 4.5 ms, residency 15.3 ms, `qcom,notify-rpm`,
`qcom,is-reset`). That last level is what lets the RPM drop to XO shutdown /
VDD min ("vlow"/"vmin" in rpm-stats). It needs the **MPM** (`wake-gic` =
`qcom,mpm-gic-bengal` at msg-RAM 0x45f01b8, IPC register 0xf011008, IRQ SPI 197)
so wakeup interrupts still arrive while the GIC is off.

Mainline `sm6115.dtsi` has neither; the sibling **agatti (QCM2290)** has both
(`mpm: interrupt-controller` with `compatible = "qcom,mpm"`, msg-RAM 0x1b8,
SPI 197, mbox `apcs_glb 1`, `cluster_pd { power-domains = <&mpm>; }`,
`wakeup-parent = <&mpm>` on TLMM). The vendor numbers for bengal (msg-RAM
offset 0x1b8, SPI 197, 96 pins) match agatti's exactly **[src]**, so porting
the agatti pattern to `sm6115.dtsi` looks feasible **[guess]**: needs the
bengal MPM pin map (from the vendor `qcom,mpm-gic-bengal` driver table in the
4.19 kernel source, not in our dumps), a system-level PSCI domain state, and
`wakeup-parent` on `tlmm`. `QCOM_MPM=m` is already in Fedora's config.
I found no posted SM6115 MPM patch (web search; lore.kernel.org refuses
automated fetches, so not exhaustive). Related upstream history: Bhupesh
Sharma's "sm6115: Add CPU idle-states" (2023) and Stephan Gerhold's
"sm6115: Fix up cluster idle states" — https://lore.kernel.org/all/ZIjEEarBM93g8beB@gerhold.net/T/

Consequence **[guess]**: s2idle today should work functionally (CPUs and
clusters power-collapse, the GIC stays powered, so modem/RTC/key IRQs still
wake), but sleep current will be well above stock because the SoC never
reaches XO shutdown. Expect `vlow`/`vmin` counts in `qcom_stats` to stay 0.
Sibling devices (RB2, Pro1X, J606F) share the same dtsi, so the same applies to
them; I found no public suspend reports for them.

Also note: the Ubuntu Touch boot image's cmdline has
`lpm_levels.sleep_disabled=1` (read from `backup/boot-partitions-2026-11-20/boot_a.img`),
so UT never used deep sleep on this phone either. Not a baseline for battery life.

## A3. Thermal: vendor vs mainline
| Zone (vendor name) | Vendor policy | Mainline |
|---|---|---|
| CPU (`cpu-1-x-step`, `cpuss-x-step`) | step_wise at 110 °C → CPU cooling devices | passive 90/95 °C **with no cooling map**, critical 110 °C |
| `hepta-cpu-max-step` | 120/110 °C | — |
| GPU (`gpu-step`) | 95/100 °C → GPU freq | `gpu-thermal` 85/110 → `&gpu` (GPU not enabled yet) |
| skin `quiet-therm-step` (PM ADC thermistor) | 35/52/85 °C steps, 2 s polling | no zone (needs `adc-tm5` channels + thermistor) |
| `xo-therm`, `pa-therm0`, `camera-therm`, `chg-skin-therm` | userspace governor | no zones |
| `pm6125-tz`, `pmi632-tz` | 95/115/145 °C | same hardware via spmi-temp-alarm (our DT) |
| PMI632 BCL (`ibat`, `vbat`, `bcl-lvl*`) | battery current/voltage limits | not described |
| `*-lowf` / `*-lowc` | low-temperature floor | not described |

Gaps, in order:
1. **CPU cooling maps** (`cooling-maps { map0 { trip = <&cpu4_alert0>; cooling-device = <&CPU4 THERMAL_NO_LIMIT THERMAL_NO_LIMIT>; … } }`)
   for `cpu0123`, `cpu4..7`, `cpu45`, `cpu67`. Today a sustained load would
   run unthrottled until 110 °C and then power off. Small DT patch, good
   upstream candidate (affects all SM6115 boards).
2. Skin/XO thermistor zones via `pm6125_adc_tm` (channels and
   resistor/thermistor tables from the vendor DT). Needed before shipping a
   desktop; not needed for the first install.
3. BCL / battery limits: later, together with charging.

## A4. Test plan (RAM boot or first install; no writes to storage)
Run in this order; stop at the first failure and log it in docs/status.md.
1. **Inventory (read only):** `cat /sys/power/mem_sleep /sys/power/state`;
   `grep . /sys/devices/system/cpu/cpu*/cpuidle/state*/{name,usage,time}`;
   `cat /sys/kernel/debug/pm_genpd/pm_genpd_summary`; `modprobe qcom_stats` →
   `grep . /sys/kernel/debug/qcom_stats/*`. Expect only `s2idle` (Qualcomm TZ
   rarely implements PSCI SYSTEM_SUSPEND **[guess]**).
2. **Idle residency:** 60 s idle with the screen off (`echo 1 > /sys/class/backlight/*/bl_power`
   or DPMS off). Cluster power-collapse usage must grow; record per state.
3. **cpufreq:** `stress-ng --cpu 8 -t 60` (stop if any zone > 85 °C):
   `scaling_cur_freq` reaches max; after the stop, falls to 300 MHz.
4. **Thermal (after adding cooling maps):** same load 10 min, watch
   `cur_state` of `cooling_device*` change at 90 °C. **Abort at 100 °C**
   (`poweroff -f` from the host if needed). Never without the maps.
5. **s2idle, safest first:** `echo freezer > /sys/power/pm_test; echo freeze > /sys/power/state`,
   then `devices`, then the real thing with `rtcwake -m freeze -s 20`
   (set the RTC from the host first: it starts at 1970). Run the command via
   `systemd-run` and log to the journal; the USB network link drops during
   suspend. Read `/sys/power/suspend_stats` and `dmesg` after.
6. **Wake sources** (each separately): power key, Vol Down, RTC alarm, USB
   plug (expected **not** to wake: Type-C/charger nodes are disabled),
   incoming call/SMS (once the modem is set up; smp2p/glink IRQs).
   `cat /sys/kernel/debug/wakeup_sources` after each.
7. **Device behaviour across suspend:** display (panel module must redo its
   init sequence on resume; the LCDB supply isn't driven, so the panel stays
   powered **[guess]**), Wi-Fi (`ath10k_snoc` reassociation; WoWLAN not
   expected), USB gadget (re-enumeration on the host), modem (remoteproc
   state, `qrtr` still answers), UFS (no errors on resume).
8. **Sleep current:** unplugged, 1 h in s2idle, compare `vbat_sns` (ADC5)
   before/after; repeat with the screen merely off. Crude but needs no gauge.
   `vlow`/`vmin` from `qcom_stats` tells whether XO shutdown was ever reached.
9. **Stability:** 50 suspend/resume cycles by RTC alarm, then compare
   with the random-reset problem seen under Ubuntu Touch (log/resets.csv):
   pstore must be read after every unexpected reboot.

Upstream-worthy outcomes: CPU cooling maps; rpm-master-stats node
(`qcom,rpm-master-stats` at 0x45f0150 per vendor); MPM + system power domain
for sm6115.

---------------------------------------------------------------------------

# Part B: the first persistent install

## B1. Facts that shape the plan
1. **ABL only starts a mainline DT with `dtbo` erased** (tested, fresh
   session). With stock dtbo Ubuntu Touch boots, with it erased only our
   images do. One slot can't host both → use the **two slots as two OSes**.
2. **Slot b is not a copy of slot a [seen]:** `boot_b` holds a different
   kernel (15.7 MB, 872 KB ramdisk: stock OxygenOS-style) than `boot_a`
   (UT, 13.4 MB + 5.4 MB ramdisk), and `dtbo_b`/`vbmeta_b` hashes differ
   from `_a` (`backup/boot-partitions-2026-11-20/SHA256SUMS`). Slot b's boot
   chain (`xbl_b`, `abl_b`, `tz_b`, `rpm_b`, `hyp_b`, `modem_b`, …) may be an
   older firmware **[guess]**. Switching slots also switches which of these
   runs (Qualcomm switches the UFS boot LUN 1↔2 too **[guess]**). Must be
   checked read-only before any slot switch (B4, gate G3).
3. **Initramfs size.** ABL refused a 67.7 MB dracut ramdisk and accepted
   1.7 MB [seen]; the limit in between is unknown. Fedora Silverblue 45's
   stock `initramfs.img` is **269 MB** [seen in the image] and the boot
   partitions are 96 MiB. A real install needs a **slim, device-specific
   initramfs** rebuilt in the device layer (e.g. `hostonly=no` but
   `omit_dracutmodules+=" plymouth …"`, no firmware, `add_drivers` = the
   `RAMBOOT_DRIVERS` list + btrfs + `rpmpd` + `sdhci_msm`). Target: below the
   tested limit; find the limit by RAM-booting 8/16/32/48 MB images.
4. **ABL appends `rootwait ro init=/init`** and `androidboot.*` to our cmdline
   [seen in dmesg]. `init=/init` reaches dracut/systemd in the initrd, which
   may try `/sysroot/init` and fall back, or fail **[guess, test first]**.
   Mitigation if needed: our own `init=/usr/lib/systemd/systemd` can't win
   (ABL's comes last); use a dracut hook or a `/init` symlink in the image.
5. **ESP is not needed for `android-bootimg`.** Nothing on the phone reads
   it. But `disk.yaml` puts `/boot/efi` in the generated mount units; if the
   partition doesn't exist, boot waits for the device and lands in the
   emergency shell **[guess]**. Either keep an ESP on the SD card (Phase 1),
   or mark it `nofail` / drop it for android-bootimg devices (Phase 2).
   bootupd (`bootloader-update.service`) should be masked for android-bootimg.
6. **Ubuntu Touch lives in `userdata` [guess, check]:** `sda16` is ext4,
   UUID 18837951…; mount it `ro,noload` from the RAM boot and `ls` to
   confirm (rootfs image vs user data only). Writing `userdata` ends UT.
7. **U-Boot can't read UFS or SD yet** (B6), so `uboot-android` and the ESP
   decision (`op1`) can wait. **First install uses `android-bootimg`.**
8. The bootloader is unlocked, AVB state `orange`; flashing `boot_b` doesn't
   need a vbmeta change (`fastboot boot` of unsigned images already works) **[guess for flash; true for RAM boot]**.

## B2. Strategy: phased, each phase reversible
| Phase | Root | Boot | Phone writes | UT still boots? |
|---|---|---|---|---|
| 0 tethered | microSD | `fastboot boot boot.img` from the Mac each time | only the dtbo_a erase/restore already used for RAM boots | yes (after dtbo_a restore) |
| 1 dual boot | microSD | `boot_b`, `dtbo_b` erased, slot b active | `dtbo_b`, `boot_b`, slot flags | yes: `fastboot --set-active=a` |
| 2 internal | `userdata` (btrfs) | `boot_b` | + `userdata` | no (UT data gone; restore B5) |
| 3 A/B updates | `userdata` | `boot_a`/`boot_b` alternating (`fap-android-boot`) | + `dtbo_a`, `boot_a` | no |
| 4 U-Boot | `userdata` | U-Boot in `boot_x`, ESP | + ESP partition | no |

Why microSD first: the whole root is written **from the Mac**, never through
fastboot; UFS stays untouched apart from two 96/24 MiB partitions of the
inactive slot. The SD controller already probes [seen]; `rpmpd` is in the
initramfs (device dracut conf). Needs a card (ask the user; ≥16 GB, A1/A2).
Phase 0 proves kernel cmdline, initramfs size, ostree root, `init=` handling
and first-boot services **without writing anything new** to the phone.

## B3. How bootc/ostree map onto the boot partition
- ostree keeps kernels and initramfs per deployment under
  `/boot/ostree/<os>-<sha>/` (btrfs subvolume `boot` on the root disk) and a
  Boot Loader Spec entry per deployment in `/boot/loader/entries/` with
  `options … ostree=/ostree/boot.N/…`.
- `fap-android-boot` (`boot/android-bootimg/rootfs/usr/libexec/`) turns the
  highest-version entry into an Android boot image (Image.gz from the EFI
  zboot, initramfs, DTB, cmdline) at shutdown after `ostree-finalize-staged`.
- **Phases 1–2 (dual boot):** slot a is UT, so the A/B scheme in
  `fap-android-boot sync` (write the *other* slot, `qbootctl -s`) **would
  overwrite UT's `boot_a`**. Needed change before Phase 1: a device setting,
  e.g. `ANDROID_BOOT_SLOTS="b"` (fixed slot, write in place), with A/B only
  in Phase 3. Fallback for a bad in-place write: `fastboot boot` the last good
  image from the host (kept as `out/boot-lastgood.img`) or ABL's slot fallback.
- **Mark success:** ABL decrements a retry counter on slot b; if Linux never
  marks the slot successful, ABL eventually falls back to slot a (UT) **[guess:
  standard QC A/B, typically 7 tries]**. Run `qbootctl -m` from a unit after
  `boot-complete.target`. This also gives a free "fall back to UT" path.
- **DTB:** ship our `sm4250-oneplus-billie2-fap.dtb` (PMIC, keys, display)
  next to the kernel and point `KERNEL_DTB` at it; the panel kmod must be
  built for each kernel (roadmap item 7).
- **Rollback:** `bootc rollback` reorders the BLS entries; the next shutdown
  rebuilds the boot image for the old deployment. If the new kernel doesn't
  boot at all: `fastboot boot out/boot-lastgood.img` from the host, then
  `bootc rollback`. In Phase 3 the previous slot already holds the old image:
  `fastboot --set-active=<other>`.
- Pitfall **[guess]**: a boot image whose `ostree=` points to a garbage-
  collected deployment won't boot; `sync` must run whenever deployments change
  (it does, at shutdown; check that `bootc upgrade --apply` paths also hit it).
- Kernel cmdline for the first install: `root=UUID=<btrfs> rootflags=subvol=root rw`
  + ostree's `ostree=` + `clk_ignore_unused pd_ignore_unused` (until the
  panel/LCDB and rpmpd consumers are complete) + `console=tty0`.
- The btrfs is built at 6 GiB; grow it on first boot (`growpart` on SD,
  `btrfs filesystem resize max /`), e.g. a oneshot unit or systemd-repart.

## B4. Every partition write, with backup and restore
All `fastboot` commands run on the Mac, by the human or with their explicit
approval per step. Backups live in `UBports-N100/backup/` (git-ignored).
`flash.sh` already refuses identity, boot-chain and firmware partitions.

| # | Phase | Write | Command | Backup (exists?) | Restore |
|---|---|---|---|---|---|
| W0 | 0 | microSD card (host) | `diskutil list` → `sudo dd if=disk.raw of=/dev/rdiskN bs=4m` | none needed (card only) | rewrite the card |
| W1 | 0 | `dtbo_a` erase (as for every RAM boot) | `fastboot erase dtbo_a` | `dtbo_a.img`, sha256 `c4dcb0f0…` **yes** | `fastboot flash dtbo_a backup/boot-partitions-2026-11-20/dtbo_a.img`, verify hash by reading back from the RAM boot |
| W2 | 1 | `dtbo_b` erase | `fastboot erase dtbo_b` | `dtbo_b.img`, sha256 `0b134a8b…` **yes** | `fastboot flash dtbo_b backup/boot-partitions-2026-11-20/dtbo_b.img` |
| W3 | 1 | `boot_b` | `fastboot flash boot_b out/boot.img` | `boot_b.img`, sha256 `d3df9c65…` **yes** | `fastboot flash boot_b backup/boot-partitions-2026-11-20/boot_b.img` |
| W4 | 1 | slot flags (GPT attributes of the `_a/_b` entries; possibly UFS boot LUN) | `fastboot --set-active=b` | `fastboot getvar all` output saved (current-slot, slot-retry-count/-successful/-unbootable) | `fastboot --set-active=a` |
| W5 | 2 | `userdata` (45 GiB, UT) | `fastboot flash userdata out/rootfs.img` | **to make**: full image from the RAM boot, `ssh root@172.16.42.1 'dd if=/dev/disk/by-partlabel/userdata bs=4M' > userdata.img` + sha256 (≈45 GB on the Mac; or `e2image -ra` of used blocks only) | `img2simg userdata.img u.simg && fastboot flash userdata u.simg`, or reinstall UT with the UBports Installer |
| W6 | 3 | `dtbo_a` erase | `fastboot erase dtbo_a` | yes (W1) | as W1 |
| W7 | 3 | `boot_a` | written by `fap-android-boot` | `boot_a.img`, sha256 `d6d3c2f7…` **yes** | `fastboot flash boot_a backup/…/boot_a.img`; `fastboot boot backup/…/boot_a.img` RAM-boots UT (proven) |
| W8 | 4 | ESP → `op1` (300 MiB, ext4, only `info.txt`) | `fastboot flash op1 out/esp.img` | **to make**: `dd` of `/dev/disk/by-partlabel/op1` from the RAM boot + sha256 | `fastboot flash op1 op1.img` |
| W9 | 4 | `boot_a`/`boot_b` ← `uboot.img` | `fastboot flash boot_x out/uboot.img` | yes | as W3/W7 |

Never written in any phase: `modemst1`, `modemst2`, `fsg`, `fsc`, `persist`
(identity), the boot chain (`xbl*`, `abl*`, `tz*`, `hyp*`, `rpm*`, `devcfg*`,
`keymaster*`, `cmnlib*`, `qupfw*`, `uefisecapp*`, `imagefv*`, `storsec*`,
`vbmeta*`), firmware (`modem*`, `dsp*`, `bluetooth*`), `op2`, `super`,
`metadata`, `misc`, `devinfo`, `recovery_*`, `logo_*`, `splash`. Modem EFS
stays served read-only from RAM copies (`fap-modem-ram`); `rmtfs.service`
stays masked.

Not used: `recovery_b` / `super` as ESP (not needed while booting
android-bootimg). Idea for later, untested: Fedora in `recovery_a` while
`boot_a` stays UT (boot via the recovery key combo) — depends on whether ABL
applies the `dtbo` partition to recovery images; not worth the risk now.

## B5. Getting back
| From | To Ubuntu Touch | To stock |
|---|---|---|
| Phase 0 | restore `dtbo_a` (W1 restore) | MSM |
| Phase 1 | `fastboot --set-active=a` (UT untouched); optional: restore `boot_b`, `dtbo_b` | MSM |
| Phase 2–3 | restore `boot_a`, `dtbo_a`; restore `userdata` image or run the UBports Installer (it may also flash firmware partitions; read what it writes first); `--set-active=a` | MSM |
| Phase 4 | as Phase 2 + restore `op1` | MSM |
| No fastboot at all | EDL (Vol Up + Vol Down while plugging in, 05c6:9008) | MSM package `orig/bengal_14_E.05_201031.zip` (EU 10.5.2, matches the vendor build) with Windows MSM Tool; restores everything except identity data, which wasn't touched |

Forced restart at any point: Power + Volume Up ~15 s. From a running Fedora:
`systemctl reboot --reboot-argument=bootloader` (ABL fastboot) or `reboot -f`.

## B6. U-Boot: what upstream needs (for Phase 4)
Findings in U-Boot `c1958b5f`:
1. **UFS GDSC missing [src, likely the cause of "UFS bound, never probed"]:**
   `drivers/clk/qcom/clock-sm6115.c` has
   `sm6115_gdscs[] = { [GCC_USB30_PRIM_GDSC] = { 0x1a004 } }` only, so
   `GCC_UFS_PHY_GDSC` (index 1) is a zero entry. Linux's gcc-sm6115 uses
   `gdscr = 0x45004` for `gcc_ufs_phy_gdsc`. Add it (and `GCC_CAMSS_TOP`,
   `VCODEC0`, … for completeness). Also no `set_rate` cases for the UFS
   RCGs (axi, unipro, ice, phy-aux); ABL leaves them configured, so this may
   be fine at first.
2. UFS regulators: `ufs-qcom.c` only warns when `vcc/vccq` can't be found and
   `phy-qcom-qmp-ufs.c` skips regulators ("voted at boot time already"); U-Boot
   has no SMD-RPM regulator/rpmpd driver (only RPMh, stubs for `qcom,rpm-proc`
   and `qcom,rpmcc`). Probably fine because ABL left UFS powered **[guess]**.
3. Nobody has exercised UFS on SM6115 in U-Boot: the reference board RB2 boots
   from eMMC (`qrb4210-rb2.dts` enables `sdhc_1`, no UFS) **[src]**.
4. **Buttons:** U-Boot uses the mainline billie2 DT from `dts/upstream`,
   which **doesn't include PM6125/PMI632 at all** — our PMIC/keys live only
   in `devices/oneplus-billie2/dts/…-fap.dts`. `spmi-msm.c` already supports
   arbiter v5 (this phone reports `v5 (0x50010000)`). Upstreaming our PMIC +
   `pon_pwrkey`/`pon_resin` + Vol-Down `gpio-keys` to the kernel DT fixes the
   kernel and (after the next dts/upstream sync) U-Boot.
5. SD (`sdhc_2`): needs an rpmpd power-domain driver or a stub for
   `qcom,sm6115-rpmpd`.
Quick check from U-Boot fastboot once 1 is patched: `fastboot oem run:"scsi scan"`,
`oem run:"part list scsi 0"`, `oem run:"dm tree"`, then `oem console` once.

## B7. Go/no-go checklist (before Phase 1; every write needs a human "go")
- [ ] G1 Battery > 50 % (ADC `vbat_sns` ≥ 3.9 V) and on USB power.
- [ ] G2 Backups present and hashes re-verified on the Mac:
      `shasum -a 256 -c backup/boot-partitions-2026-11-20/SHA256SUMS`,
      same for `backup/identity-2026-11-20/` (and a second off-device copy).
- [ ] G3 **Slot-b boot chain check (read-only, RAM boot):** sha256 of each
      `_a`/`_b` pair of `xbl`, `xbl_config`, `abl`, `tz`, `hyp`, `rpm`,
      `devcfg`, `keymaster`, `cmnlib`, `cmnlib64`, `qupfw`, `uefisecapp`,
      `imagefv`, `featenabler`, `storsec`, `modem`, `dsp`, `bluetooth`;
      `fastboot getvar all` for slot flags. **No-go if slot b's chain differs
      and the difference isn't understood** (fallback: single-slot plan on
      slot a, swapping `boot_a`/`dtbo_a` with the backups; no boot-chain copies,
      ever).
- [ ] G4 EDL tested recently (05c6:9008 seen) and MSM package in `orig/` verified.
- [ ] G5 Phase 0 passed: tethered `fastboot boot` of the **exact** `boot.img`
      (slim initramfs, final cmdline) reaches the SD root, ostree deployment,
      SSH and our first-boot units; `init=/init` handled; size under ABL's
      limit; `/boot/efi` doesn't block boot.
- [ ] G6 `fap-android-boot` changed to fixed-slot mode for b (no writes to
      slot a), `qbootctl -m` unit present, `bootloader-update.service` masked,
      `rmtfs.service` masked — all verified in the built image.
- [ ] G7 `out/boot-lastgood.img` kept on the Mac; restore commands of B4 W2–W4
      printed next to the terminal.
- [ ] G8 Ubuntu Touch confirmed booting on slot a right before starting.
- [ ] G9 One actor on the phone; capture running (`tools/capture.sh`) to
      record resets.
Before Phase 2 additionally: userdata image saved and hash-checked (W5);
UT's role in `userdata` confirmed (B1.6); user agrees UT is gone until restored.
Before Phase 4: U-Boot reads UFS from RAM boot; `op1` backup made; decide
whether anything checks `op1` (MSM restores it anyway).

## B8. Open questions
1. ABL's ramdisk/boot-image size limit (1.7 MB works, 67.7 MB doesn't).
2. Does ABL *normal-boot* (not `fastboot boot`) a slot whose dtbo is erased?
   Earlier "phone came back in fastboot" hints it might not **[unknown]**;
   Phase 1 answers it, with slot a as fallback.
3. Is slot b's firmware the EU 10.5.2 set or older (G3)?
4. Does a microSD card exist for this work?
5. Off-mode charging: plugging in a powered-off phone makes ABL boot with
   `androidboot.mode=charger` — Fedora would boot fully; harmless but odd.
