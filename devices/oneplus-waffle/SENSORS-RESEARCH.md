<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12 (waffle) sensors: why `fap-hw-sensors` reset the phone

Desk research, 2026-11-21, after the v8 test (OnePlus12/log/2026-11-20-recon.md,
"v8 hardware test"). This was a time-boxed session (~15 min). No phone access.
Statements marked **[src]** were read in our kernel or userspace trees
(`waffle-build-hw` volume: linux-waffle 9359fc74, hexagonrpc da7a3742,
libssc 033e2a32). Statements marked **[web]** come from public issue trackers.
Statements marked **[guess]** are inference.

## What we ran
`fap-hexagonrpcd-sensorspd.service`:
`hexagonrpcd -f /dev/fastrpc-adsp -d adsp -s -R /usr/share/qcom/sm8650/OnePlus/waffle`,
then iio-sensor-proxy and `monitor-sensor`. Shortly after, the USB link dropped
and the phone came back up in LineageOS. Nobody read pstore before Android booted.

## Facts from the source
- **SM8650 has no separate SLPI/SDSP.** The SSC runs in the ADSP's
  `msm/adsp/sensor_pd` **[src]**:
  - The DT has only `remoteproc_adsp` (`qcom,sm8650-adsp-pas`), with memory
    `adspslpi_mem` (the combined ADSP+SLPI carveout).
  - The in-kernel `qcom_pd_mapper` maps `qcom,sm8650` to `sm8550_domains`:
    audio_pd, root_pd, charger_pd, sensor_pd, cdsp root, mpss gps.
  - So `-d adsp` and `/dev/fastrpc-adsp` are correct. There is no
    "adsprpc-sensors" or sdsp channel to choose instead.
- **ADSP fastrpc node** (sm8650.dtsi) **[src]**:
  - `qcom,glink-channels = "fastrpcglink-apps-dsp"`, `label = "adsp"` and
    `qcom,non-secure-domain`. This creates both `/dev/fastrpc-adsp` and
    `-adsp-secure`.
  - It has compute-cb 3 to 7 with SMMU SIDs 0x1003 to 0x1007.
  - It has **no `qcom,vmids` and no `memory-region` (remote heap)**.
- **The missing remote heap does not affect `-s`.**
  - `-s` issues `FASTRPC_IOCTL_INIT_ATTACH_SNS`, which is
    `fastrpc_init_attach(fl, SENSORS_PD)` **[src]**. That is a plain attach to
    an already-running static PD.
  - Only `INIT_CREATE_STATIC` (the audio PD) needs `remote_heap_addr`, and that
    path returns an error if the heap is missing. It does not crash.
  - Missing vmids means that buffers are not SCM-assigned. That is the same
    setup that works on sdm845/sm8250 attach-only users **[guess]**.
- **The board DT (DaDDevil) grows `adspslpi_mem`** from 0x4080000 to 0x5280000
  (to 0xa3180000) to match stock **[src]**. That is plausible for the stock
  ADSP image, and the ADSP already boots and runs audio and charger with it.
- **hexagonrpcd's file tree** (rpcd_builder.c) **[src]**:
  - It serves `<R>/sensors/config` as `/vendor/etc/sensors/config`.
  - It serves `<R>/sensors/sns_reg.conf` as `.../sns_reg_config`.
  - It serves `<R>/sensors/registry` as `/mnt/vendor/persist/sensors/registry/registry`
    (and `/persist/...`).
  - It serves `<R>/dsp/adsp` as `/usr/lib/qcom/adsp`, and `<R>/socinfo` as
    `/sys/devices/soc0`.
  - The served tree is **read-only**: the DSP's registry writes and
    `sns_reg_version` writes are refused.
  - Our layout matches this. The one gap is that `socinfo/` is **not** served,
    so the DSP gets an empty `soc0`.
- **The ADSP also hosts the charger PD.** pmic_glink handles battery,
  USB Type-C, altmode and UCSI. Any ADSP root-PD crash therefore takes USB down,
  which by itself explains "USB link dropped" **[src+guess]**.
- **ramoops is already configured** in the board DT at `0x85000000`
  (0x240000, with a console of 0x40000) **[src]**. pstore is usable *if* the
  next kernel to boot is ours and that region was not reused.

## Evidence from others
- **No public report of hexagonrpcd/libssc on SM8550/SM8650 working or
  rebooting** **[web]**.
- **The nearest case is sensh issue #3 (SM8550, mainline)** **[web]**:
  - The command was `hexagonrpcd -f /dev/fastrpc-adsp-secure -s`.
  - The DSP requested `oemconfig.so`, `/sys/devices/soc0/*`, `json.lst` and
    `/mnt/vendor/persist/sensors/registry/registry/../sns_reg_version`, and
    tried to write it.
  - Then it **stalled**, and SSC (QMI service 400) never appeared in
    `qrtr-lookup`. The issue has no resolution.
  - So on 8550-class SoCs the DSP asks for files outside the classic sdm845
    set. The registry *parent* directory (`sns_reg_version`) and `soc0` matter.
- **libssc #135** (OnePlus, compass) shows hexagonrpcd complaining about
  missing persist registry paths **[web]**.
- **postmarketOS SSC support (pmaports MR 4050) is SDM845-only.** The known
  remaining issue there is mount matrices **[web]**.

## Q1: most likely cause (ranked)
1. **The ADSP crashed and the platform did a full reset instead of ADSP
   SSR [guess, most likely].**
   - Attaching makes the sensor PD read our config and registry. A firmware or
     config mismatch, a missing `soc0`, refused writes, or OnePlus-specific
     (oplus) sensor drivers can fault the PD.
   - On SM8650 a sensor-PD fatal often escalates to the root PD, which takes
     down pmic_glink (USB and charger) and audio.
   - Whether this ends in a full reset depends on two things:
     - Remoteproc recovery. The default is enabled, but check
       `/sys/class/remoteproc/*/recovery`.
     - Whether a Linux client (pmic_glink/battmgr, q6apm/gpr, fastrpc) panics
       or hangs during teardown.
   - A watchdog bite that the ADSP does not handle in time can also be turned
     into a system reset by TZ.
2. **A kernel bug in fastrpc teardown or invoke paths when the DSP dies with an
   attached session**, panicking Linux **[guess]**. A pstore console would
   show this immediately.
3. **Baseline instability, not sensors.**
   - The telephony build **reset by itself** at about 22:59 the same evening
     with no sensors running (same log).
   - So the sensors run may be coincidence, or it may share the cause, for
     example the PMIC/charger over pmic_glink or a thermal/PS_HOLD event.
   - Do not conclude anything from one event.
4. **Ruled out or unlikely:**
   - Wrong domain or channel (there is only adsp).
   - Missing remote heap (not used by ATTACH_SNS).
   - The pd-mapper table (sm8650 includes sensor_pd). This assumes
     `CONFIG_QCOM_PD_MAPPER` is enabled and no userspace pd-mapper also runs.
     Verify both.

## Q2: what working ports do
- **sdm845 (pmOS, the reference):**
  - The command is `hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R /usr/share/qcom/sdm845/<Vendor>/<device>`.
    It uses a separate SLPI there.
  - The files are `sensors/config` (json), `sensors/registry`,
    `sensors/sns_reg.conf` and `dsp/sdsp`.
  - The DT needs nothing beyond the upstream fastrpc node.
- **SM8250/SM8350/SM8550-class (no SLPI): the same command with
  `-f /dev/fastrpc-adsp -d adsp -s`.** This is what we already do.
  - Some users use `-adsp-secure`. Our DT exposes both nodes, so try
    `-secure` only if the non-secure attach fails.
- **No known SM8650 port with working sensors exists.** We would be first.
- **libssc** is Dylan Van Assche's (codeberg). iio-sensor-proxy needs
  `-Dssc-support=enabled`. Our pins match current upstream.

## Q3: staged safe test plan (next session, RAM boot only, no writes)
0. **Prepare the build (desk):**
   - Add `<R>/socinfo/` as a copy of `/sys/devices/soc0` taken at runtime. A
     bind-mount or tmpfs copy in the script is enough.
   - Optionally serve a **writable** tmpfs copy of `sensors/registry` plus a
     `sns_reg_version` in its parent directory. Do this by pointing `-R` at a
     tmpfs overlay of the read-only tree.
   - Make sure `CONFIG_PSTORE_RAM=y`, `CONFIG_PANIC_TIMEOUT` is non-zero, and
     `CONFIG_QCOM_PD_MAPPER` is enabled.
1. **Boot v8 (or later) and get Wi-Fi up.** From the laptop, over Wi-Fi rather
   than USB (USB dies with the ADSP), run:
   `ssh … 'dmesg -w' | tee dmesg-sensors.log` and
   `ssh … 'journalctl -f' | tee journal-sensors.log`.
2. **Check state before starting anything:**
   - `grep . /sys/class/remoteproc/*/{name,state,recovery}`
   - `cat /sys/kernel/debug/remoteproc/*/crash_reason` if it exists
   - `qrtr-lookup`. If service 400 is already listed, the sensor PD is up
     without hexagonrpcd.
   - `ls /sys/fs/pstore`
3. **Enable ADSP recovery explicitly:**
   - `echo enabled > /sys/class/remoteproc/remoteprocN/recovery`, where N is
     the one named `adsp`.
   - Optionally set `coredump` to `disabled` so a crash does not stall on a
     devcoredump.
4. **Start hexagonrpcd alone in the foreground, under ssh:**
   `hexagonrpcd -f /dev/fastrpc-adsp -d adsp -s -R … 2>&1 | tee rpcd.log`.
   Watch which files the DSP requests and whether it writes.
   - **Do not start iio-sensor-proxy yet.**
   - Wait 60 s, then run `qrtr-lookup` again.
5. **If it is stable and service 400 is listed,** run
   `ssccli --sensor accelerometer` (libssc CLI) for a single read, then light,
   then proximity. Only after that, start iio-sensor-proxy and `monitor-sensor`.
6. **If it resets:**
   - Hold Vol-Down during the reboot to land in **fastboot**, not Android.
   - RAM-boot our kernel again (`fastboot boot`).
   - Read `/sys/fs/pstore/console-ramoops*` and `dmesg-ramoops*`, and save the
     Wi-Fi `dmesg -w` tail.
   - If Android does boot first, check `/sys/fs/pstore` from `adb root` in
     LineageOS. This is read-only, but the ramoops region may be reused or
     cleared.
7. **Bisect the trigger by running the plain attach without `-s`**
   (`INIT_ATTACH`, root PD, with the same `-R`). If the root-PD attach alone
   resets, the problem is fastrpc/DT (SMMU SIDs, vmids), not the sensor
   config.
8. **Before blaming sensors, check the evening's other reset.** Repeat a
   30-minute idle run of the same build *without* sensors and with pstore
   enabled. Two resets in one evening suggest a baseline problem.

## Open questions
- Does the OnePlus sensor PD need `oemconfig.so` or OPlus-specific files from
  `/vendor/lib/rfsa` or `/odm`? The hexagonrpcd log in step 4 will name them.
- Is SSC service 400 announced *before* attach? If it is, the PD is alive and
  the crash comes from serving files.
