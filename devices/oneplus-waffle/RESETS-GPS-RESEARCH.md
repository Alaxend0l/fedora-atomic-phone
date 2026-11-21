<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12 (waffle): research on the hard resets and GPS (2026-11-21)

This is desk research only: nobody touched the phone and nothing was built.
The observations come from `OnePlus12/log/2026-11-20-recon.md` (sections
"v8 hardware test", "Telephony build test", "~22:59 spontaneous reset",
"speaker v9 test"). Tags: **[fact]** = checked in source or a cited
document, **[guess]** = hypothesis to test.

## A. Hard resets

### What we know
| # | When | Build | Load | After the reset |
|---|---|---|---|---|
| R1 | 2026-11-20 ~22:50 | v8 RAM boot | `fap-hw-sensors` (hexagonrpcd/libssc on SDSP/ADSP) | LineageOS, pstore not read |
| R2 | ~22:59 | telephony RAM boot | idle: modem running, Wi‑Fi up but not joined | LineageOS, pstore empty |
| R3 | 2026-11-21 ~00:40 | v9 RAM boot | speaker test, SECONDARY_MI2S at 32 bit | installed system, pstore empty |

The installed system has run the same modem stack (fap-efs-ram, rmtfs,
tqftpserv, ModemManager) since ~23:22 without a reported reset. A modem that
is running and idle therefore does not reset the phone on its own every time.

### Why pstore has been empty so far [fact]
1. **LineageOS clobbers the region.** Stock reports `84a00000-86afffff :
   System RAM` (`log/stock-memory-map.txt`), so LineageOS uses 0x85000000 as
   normal RAM. After R1 and R2 the phone booted LineageOS (active slot a), and
   that wiped the region before Linux could read it. Now that slot b (Fedora)
   is active, a reset lands back in Fedora (R3 did), so pstore can survive.
2. **No room for panic/oops dumps.** DaDDevil's node
   (`sm8650-oneplus-waffle.dts:357`) is `reg 0x240000, pmsg-size 0x200000,
   console-size 0x40000`, with **no `record-size`**. With that layout,
   ramoops stores no dmesg/panic records, only the console and pmsg.
   `console-ramoops-0` survives only a warm reset that keeps DDR contents and
   only when the kernel lived long enough to write it.
3. **An empty pstore after a reset into Fedora (R3)** means one of two things
   [guess]. Either the reset was not a Linux panic (watchdog bite, PMIC/PS_HOLD,
   or a hypervisor/TZ reset after an XPU/SMMU fault from a DSP), or ABL/XBL
   cleared or retrained DDR on that path. The second case also wipes the
   console log.

### Candidate causes, most likely first
1. **A DSP fatal error escalates to a system reset** [guess, fits R1 and R3].
   R1 used the SDSP/ADSP (FastRPC) and R3 the ADSP audio graph. On mainline,
   `qcom_q6v5_pas` takes fatal/watchdog IRQs as `rproc_report_crash()`
   (`drivers/remoteproc/qcom_q6v5.c:145,166`). Recovery is on by default, so a
   pure DSP crash should give SSR, not a reboot. A full reset instead points
   to TZ/hyp: an XPU violation (DSP touching memory not assigned to it) or
   Qualcomm "download mode / SSR → full reset" policy set by the firmware.
   Earlier the bootloader went into crashdump (05c6:900e), so download mode
   can be active on this unit.
2. **Modem/rmtfs memory permissions** [guess, low]. sm8650.dtsi maps
   `rmtfs@d7c00000` (4 MiB) only to `QCOM_SCM_VMID_MSS_MSA` [fact]. sc7280,
   qcm6490 (FP5), sm6115 and sm6375 need `QCOM_SCM_VMID_NAV` as well,
   otherwise "the whole platform crashes, hard reboot within ~2 s" when the
   modem starts ([lkml 2023-01 rmtfs NAV series](https://lkml.rescloud.iu.edu/2301.1/01074.html),
   [qcs6490-rb3gen2 2026](https://lkml.iu.edu/2605.2/07859.html)).
   Upstream SM8650 QRD/HDK work with MSS_MSA only, and here the modem ran for
   minutes and runs for hours on the installed system, so this probably does
   not explain R2. It could matter for the first GNSS session (NAV = GNSS
   engine VM), and **that ties to topic B**. Do not add NAV blindly, because a
   wrong VMID assignment can itself crash.
3. **The read-only rmtfs makes the modem assert: ruled out** [fact]. In
   `rmtfs -r`, `storage_pwrite()` copies writes into an in-memory shadow buffer
   and returns success, and `storage_sync()` returns 0
   ([rmtfs storage.c](https://github.com/linux-msm/rmtfs/blob/master/storage.c)).
   The modem never sees a write error. The only failure is a write at or above
   16 MiB or an out-of-memory error. One real risk remains: if rmtfs or
   fap-efs-ram restarts while the modem runs, the open handles are lost, and
   upstream calls that fatal for the modem. Make sure the units never restart
   on their own, with `Restart=no`, or add `PartOf=` so the modem is stopped
   first.
4. **The Gunyah watchdog** [guess]. SM8650 runs Linux as a Gunyah VM. The
   "Gunyah Watchdog" driver (SMC-based) was still being merged in 2026, and a
   Qualcomm reviewer said it "should work on 8550 and 8650 too" when the
   bootloader applies the hyp overlay
   ([v8 thread](https://lkml.iu.edu/2605.0/04266.html),
   [v1](https://patchew.org/linux/20250903-gunyah._5Fwatchdog-v1-0-3ae690530e4b@oss.qualcomm.com)).
   If ABL arms a VM watchdog that nobody pets, the reset period would be
   fixed. In that case R2 (idle) would recur after the same uptime. The
   installed system's long uptime argues against this, so check the uptime at
   reset next time.
5. **PCIe/ath12k (audit F1)** [guess]. Wi‑Fi was up but not joined in R2.
   ath12k firmware crashes normally recover through MHI, but an AER/link-down
   fault on PCIe can give an SError, which is a panic. A panic would leave a
   console record if pstore worked, so check this first once ramoops is
   fixed.
6. **IPA/rmnet and tqftpserv** [guess, low]. A missing tqftpserv file only
   logs an error. IPA was never exercised (no data session) and is idle.

### How to capture the cause next time
Set this up before the next risky test. Each item is a kernel/DT/userspace
change and needs the owner's OK before flashing.
1. **ramoops with panic records:** in the waffle DT, set
   `record-size = <0x40000>; console-size = <0x80000>; pmsg-size = <0x100000>;
   ecc-size = <16>;` (total ≤ 0x240000). Boot with `ramoops.mem_type=2`
   (write-combine/uncached, more reliable after a warm reset) and
   `printk.always_kmsg_dump=1`.
2. **Reboot on panic** so the dump is complete and the phone comes back to
   Fedora: `panic=5 oops=panic` on the kernel cmdline, or sysctl
   `kernel.panic=5`.
3. **Always reset into Fedora:** keep slot b active. Never let LineageOS boot
   between a reset and reading pstore. RAM-boot tests (`fastboot boot`) reset
   into the active slot, which is now Fedora, so that is fine.
4. **Collect right after boot** (a systemd unit, `Before=` anything heavy):
   `mkdir -p /var/lib/fap-pstore/$(date +%s) && cp -a /sys/fs/pstore/* $_ ;
   journalctl -b -1 -o short-monotonic | tail -300`. Persistent journald
   (`Storage=persistent`) + `SyncIntervalSec=5s` catches the last seconds in
   R2-type idle resets.
5. **remoteproc evidence:**
   `grep . /sys/class/remoteproc/*/{name,state,recovery,coredump}`. Leave
   `recovery` = `enabled`, and set
   `echo enabled > /sys/class/remoteproc/remoteprocN/coredump` (devcoredump)
   for adsp/cdsp/mpss. Crash reasons are printed by `qcom_q6v5` as
   `fatal error received: <smem text>` / `watchdog received:` in dmesg. Stream
   it off the phone: `ssh phone 'dmesg -w' | tee r-$(date +%s).log`, or
   journald → `systemd-journal-remote` on the Mac.
6. **Live stream during tests:** the console never reaches the screen, so run
   `dmesg -w` over Wi‑Fi/USB-net for every risky test (R1/R3-type). The last
   line before the link drops is the best clue we can get without pstore.
7. **Bisect R2:** boot the telephony build idle with
   (a) the modem only, no Wi‑Fi;
   (b) Wi‑Fi only, `fap-*modem*` masked.
   Note the uptime at reset.

## B. GPS / GNSS

### What we know
`qmicli -d qrtr://0 --loc-start` → QMI protocol error 46 `GeneralError`.
There was no SIM, the phone was indoors, and ModemManager 1.24.2 owned the
modem (state failed / sim-missing).

### Facts
- **The PD is served:** the in-kernel `qcom_pd_mapper` uses `sm8550_domains`
  for `qcom,sm8650`, which includes `mpss_root_pd_gps` with
  `gps/gps_service` (`drivers/soc/qcom/qcom_pd_mapper.c:599-605,664`). The
  "gnss" PD should not be missing. Still, check that the LOC service is
  listed: `qrtr-lookup | grep -i -E 'loc|16 '` (QMI LOC = service 16).
- **There is no `gnss` kernel subsystem on these phones.** Mainline
  Qualcomm phones get GNSS from the modem through QMI LOC, either via
  ModemManager (`mm-shared-qmi` location: gps-nmea/gps-raw) or via qmicli.
  pmOS sdm845/sdm670 get NMEA this way: `mmcli -m any --location-status`
  shows `gps-raw, gps-nmea, agps-msa, agps-msb`, plus XTRA servers
  ([sdm670-mainline#4](https://gitlab.com/sdm670-mainline/linux/-/issues/4)).
- **No SIM:** older ModemManager refused location in the `failed/sim-missing`
  state. ModemManager added "allow enabling [location] without SIM"
  ([MM !1022](https://gitlab.freedesktop.org/mobile-broadband/ModemManager/-/merge_requests/1022),
  [MM !1080](https://gitlab.freedesktop.org/mobile-broadband/ModemManager/-/merge_requests/1080)).
  [MM #839](https://gitlab.freedesktop.org/mobile-broadband/ModemManager/-/issues/839)
  shows that gps-nmea can be enabled without a SIM, but agps-msb cannot
  (WrongState). With MM 1.24.2, gps-nmea should work without a SIM [likely;
  verify]. A SIM is not needed by the GNSS engine itself, only for A-GPS.
- **qmicli client semantics:** a plain `--loc-start` releases its client
  CID on exit, and releasing the client stops the session. The working
  pattern on other Qualcomm modems is
  `-p --loc-start --client-no-release-cid`, then `--loc-follow-nmea` /
  `--loc-stop` with `--client-cid=N`
  ([Quectel forum](https://forums.quectel.com/t/rg520n-la-gps-with-qmicli-is-not-working/52714)).
  A GeneralError on Start is also reported for "Couldn't start GPS engine" in
  ([RHEL-14323](https://issues.redhat.com/browse/RHEL-14323)).
- **qmicli has the controls we need:** `--loc-get-engine-lock`,
  `--loc-set-engine-lock=[none|mi|mt|all]`,
  `--loc-get/set-operation-mode=[default|msb|msa|standalone|cellid|wwan]`,
  `--loc-get/set-nmea-types`, `--loc-inject-time`, `--loc-follow-nmea`,
  `--loc-get-predicted-orbits-data-validity`
  ([qmicli(1)](https://man.archlinux.org/man/qmicli.1.en)).

### Most likely causes of error 46, in order [guess]
1. **The engine is locked for mobile-initiated sessions.** Carrier/OEM NV
   ("GPS lock") is often MI or all. Android's location HAL sets it at boot;
   we don't. A Start under an MI lock fails generically.
2. **No event registration / two clients.** ModemManager already holds a LOC
   client, and an ad-hoc qmicli Start (without `-p`) competes with it or is
   torn down immediately.
3. **Operation mode `msb`/`msa` (A-GPS) without a data/SIM context.** Set
   `standalone`.
4. **GNSS needs the NAV VM to own its memory (see A2).** If NAV is missing,
   the session fails, or in the worst case triggers a reset. If (1) to (3)
   don't help, compare with the downstream DT. Do not test this blindly.

### Next commands (on the phone, by the main agent, owner's OK)
Read-only first (if `-p`/qmi-proxy rejects `qrtr://` URIs, drop `-p` and run one client at a time):
```sh
qrtr-lookup | grep -iE 'loc|^ *16 '
mmcli -m any --location-status
qmicli -p -d qrtr://0 --loc-get-engine-lock
qmicli -p -d qrtr://0 --loc-get-operation-mode
qmicli -p -d qrtr://0 --loc-get-nmea-types
qmicli -p -d qrtr://0 --loc-get-predicted-orbits-data-validity
```
Then the ModemManager path (preferred, it does register-events/start
correctly). Go outdoors or near a window, and allow 5–15 min for a cold start
without XTRA:
```sh
mmcli -m any --location-enable-gps-nmea --location-enable-gps-raw
mmcli -m any --location-set-gps-refresh-rate=1
watch -n2 'mmcli -m any --location-get'
```
If that fails with GeneralError, use the qmicli path with ModemManager
stopped. Note: the engine lock and operation mode are NV items. With
`rmtfs -r` the write stays in RAM only and is gone after a reboot, which is
harmless for a test. It also means a fixed value must be applied on every
boot by a unit.
```sh
systemctl stop ModemManager
qmicli -p -d qrtr://0 --loc-set-engine-lock=none
qmicli -p -d qrtr://0 --loc-set-operation-mode=standalone
qmicli -p -d qrtr://0 --loc-set-nmea-types='gga|rmc|gsv|gsa|vtg'
qmicli -p -d qrtr://0 --loc-start --client-no-release-cid   # note CID
qmicli -p -d qrtr://0 --client-cid=N --client-no-release-cid --loc-follow-nmea
qmicli -p -d qrtr://0 --client-cid=N --loc-stop
```
Run `dmesg -w` alongside this (A step 5), in case the first GNSS session
crashes the modem or the phone.

Later: XTRA (`mmcli --location-inject-assistance-data`, URLs from
`--location-status`) and geoclue with the ModemManager source for apps.

## Phone measurements, 2026-11-21 00:52 (installed system, read-only + one runtime session)
- `qrtr-lookup`: service 16 "Location service (~ PDS v2)" registered.
- `qmicli --loc-get-engine-lock` → **mt** (only network-initiated locked;
  mobile-initiated allowed), `--loc-get-operation-mode` → **standalone**,
  `--loc-get-nmea-types` → QMI error 94 NotSupported. So the engine-lock and
  operation-mode theories are ruled out.
- ModemManager location capabilities: only `3gpp-lac-ci` (no gps-nmea/gps-raw);
  modem state `failed / sim-missing`, so MM never sets up GNSS without a SIM.
- `qmicli --loc-start --client-no-release-cid` → QMI error 46 GeneralError again;
  `--loc-follow-nmea` → "could not register location tracking events:
  QMI protocol error (48) InvalidArgument" (event mask not accepted by this
  modem firmware). Next: register a minimal event mask first (position report
  + NMEA only, via libqmi API or a newer qmicli), then start with an explicit
  session id/fix-recurrence; check whether a NAV-VM mapping of the rmtfs
  region is required (see Topic A, don't add blindly).
