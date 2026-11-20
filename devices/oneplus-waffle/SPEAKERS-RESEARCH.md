<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12 speakers (TFA9874 on SECONDARY_MI2S): why v9 reset the phone, and what to test next

Desk research, 2026-11-21. Nobody touched the phone for this. The sources were
this branch (0b8c7c2), the kernel tree in the podman volume `waffle-build-hw`
(DaDDevil waffle-voice 9359fc74 + patches 0001-0003), the v8/v9 notes in
`~/Develop/fap-build/waffle/hw{,-v9}/HW.md`, the decoded topology in
`~/Develop/fap-build/waffle/hw/work/tplg/sec.conf`, the OnePlus12 recon log
(the 2026-11-21 ~00:40 entry) and upstream linux-msm/audioreach-topology.
Vendor data (tfa98xx.cnt) and the DaDDevil board DT are described here, not
copied.

## What happened
- v8: BE forced to S16_LE (2 x 16 bit, bclk 1.536 MHz). The amp reached its
  operating state with TDMERR + TDM LUT error and played nothing. The phone
  did not reset.
- v9: patch 0003 forces S32_LE on SECONDARY_MI2S_RX, while the FE stays S16
  (`aplay` of a 16-bit WAV on hw:0,1 / MultiMedia2). The phone reset straight
  into the installed system, before any sound. Nothing was captured.

## Findings (with evidence)

### F1. Nothing in the graph converts 16-bit to 32-bit (confirmed)
- Decoded topology (`sec.conf`): the device graph `device18` (the patched
  former `device16`) holds only `logger1 -> i2s_rx1`. The codec-DMA device
  graphs (`device105`, `device113`) are `logger1 -> mfc1 -> codec_dma_rx1`.
  The stream graph for MultiMedia2 is `wrsh_ep -> pcm_decoder -> pcm_converter -> vol -> mfc -> logger`.
- Upstream audioreach-topology matches this:
  `audioreach/subgraph-device-i2s-playback.m4` instantiates only
  `AR_MODULE_LOG` and `AR_MODULE_I2S_RX` (no MFC, no PCM converter), and
  `subgraph-device-codec-dma-playback.m4` has `LOG -> MFC -> CODEC_DMA_RX`.
  The only upstream I2S playback example,
  `Google-SC7180-WSA-Speakers-SEC-I2S-VA-DMIC-WCD-TX3.m4`, declares
  SECONDARY_MI2S_RX as `S16_LE`, 48 kHz, 2 ch,
  `I2S_INTF_TYPE_SECONDARY, SD_LINE_IDX_I2S_SD0`. Upstream I2S graphs
  therefore rely on FE format == BE format.
- Kernel: q6apm-dai sets every stream-graph module (PCM converter output, MFC)
  from the **FE** cfg (`q6apm-dai.c` ~l.373, `bit_width = prtd->bits_per_sample`).
  q6apm-lpass-dais sets the device graph from the **BE** cfg.
  `audioreach_i2s_set_media_format()` (audioreach.c ~l.1624) sends
  `PARAM_ID_I2S_INTF_CFG` (lpaif type, intf_idx from the topology = 1,
  sd_line, ws_src INTERNAL because the machine driver sets the CPU DAI to
  BP_FP) plus `PARAM_ID_HW_EP_MF_CFG` with `bit_width = params_width(BE)`
  = 32, and `FRAME_SIZE_FACTOR 1`.
- Result in v9: the stream graph emits 16-bit PCM, and the I2S hardware
  endpoint is configured for 32-bit. On Android the vendor device graph does
  this conversion; here nothing does. In v8 both sides were 16, so nothing
  mismatched.
- The front end cannot simply be switched to S32 either. q6apm-dai advertises
  only `S16_LE | S24_LE` (l.208/228) and `hw_params` rejects anything else
  (l.760-768). A 32-bit WAV would need a kernel patch (S32_LE ->
  `bits_per_sample = 32`; audioreach sets `q_factor = bit_width - 1`, so 32
  is representable). S24_LE would not help: `params_width` = 24, so the I2S
  endpoint would get bit_width 24 and the machine driver would compute bclk
  as 48k x 2 x 24.

### F2. Clocks and pinctrl are probably fine (ruled out as the primary cause)
- The base DT (DaDDevil) has a `q6apmbedai` child for SECONDARY_MI2S_RX with
  only a `bclk` clock = q6prmcc `LPASS_CLK_ID_SEC_MI2S_IBIT`, attribute
  COUPLE_NO, and no `mclk`. The machine driver uses `sm8650_priv_data`
  (`mi2s_mclk_enable`, `mi2s_bclk_enable`, codec fmt `BC_FC|NB_NF|I2S`).
  In `sc8280xp_snd_hw_params` the CPU DAI is set to BP_FP, mclk is skipped
  (NULL clock), and bclk = rate x ch x width goes through `clk_set_rate` +
  `clk_prepare_enable` on the q6prm clock. That is 1.536 MHz in v8 and
  3.072 MHz in v9. Both are standard IBIT rates, and in v8 the amp reported
  PLL + clocks, so the vote path works. This is the same pattern as upstream
  `qcs8550-ayntec-common.dtsi` (AudioReach, PRIMARY_MI2S_RX ->
  `dai@16` with `LPASS_CLK_ID_PRI_MI2S_IBIT` "bclk" + `LPASS_CLK_ID_MCLK_1`
  "mclk"). Other upstream AudioReach MI2S users: monaco-evk (PRIMARY_MI2S_RX ->
  max98357a, SECONDARY_MI2S_TX -> dmic), lemans-evk, talos-evk.
- Pins gpio121-124 (`i2s1_sck/data0/ws/data1`) are **TLMM** functions
  (`pinctrl-sm8650.c` `i2s1_sck_groups = gpio121`, ...), not LPASS LPI.
  `sm8650-oneplus-waffle-fap-hw.dtsi` puts `sec_mi2s_active` back on `/sound`.
  An LPI mux problem can be ruled out, and the same pins worked in v8.
- The topology patch (`tplg-sec-mi2s.py`) changes the DAI index 16 -> 18 in
  the logger, i2s and mixer tuples, `HW_IF_IDX` 0 -> 1, and names and block
  indexes. Module IIDs are untouched, and every graph has its own. v8 used
  the same patched file without a crash, so a broken patch would have shown
  up then. This is unlikely to be the cause.
- The other v9 change also runs at 16 bit: the tfa9874 driver now writes
  TDM CFG1 SLOTS/BRMG. That is I2C to the amp, which cannot reset the SoC by
  itself. Boost is off and the level is -40 dBFS, so a battery brownout is
  very unlikely.

### F3. What kind of reset was it
- `CONFIG_PANIC_TIMEOUT=0` (v9 kernel.config) and no `panic=` in bootargs, so
  a Linux panic (an SError from an unclocked access included) **hangs**; it
  does not reboot. A hang turns into a reset only if a hardware watchdog is
  armed. `CONFIG_QCOM_WDT=m`; check whether it is loaded or whether ABL left
  the watchdog running.
- An immediate reboot into the installed system looks like a reset done
  outside Linux: TZ handling a NoC/XPU error, a secure or APSS watchdog bite,
  or the PMIC.
- An ADSP fatal error on its own normally does not reset the SoC on mainline.
  `qcom_q6v5_pas` recovery is enabled by default and restarts the ADSP.
  A known Qualcomm failure fits better: when the ADSP dies, the LPASS
  clocks and votes it held go with it. Any Linux MMIO access to the LPASS
  register space (rx/tx/va macros, SoundWire controllers, their IRQ
  handlers, DAPM teardown during the crash) then hits an unclocked block,
  the NoC error goes to TZ, and TZ resets the whole SoC. In this boot
  `clk_ignore_unused pd_ignore_unused` are set, but those clocks belong to
  the ADSP and die with it.
- **"pstore empty" is not evidence yet.** The phone came back up in the
  *installed* system (a different kernel and ramoops layout; ABL/Android may
  reuse 0x85000000), and our own ramoops at 0x85000000 has never been
  verified (TODO.md P1 still open). `CONFIG_NETCONSOLE` is off, so nothing
  can leave the phone at the moment of the crash.

## Most likely cause (ranked)
1. **The DSP rejects or crashes on a 16-bit stream feeding a 32-bit I2S
   endpoint** (F1). Media-format propagation reaches the I2S sink, which is
   configured for 32 bit with no MFC in between. Then a secondary failure
   turns the ADSP crash into a SoC reset (F3: Linux touching unclocked LPASS,
   or the SSR path itself).
2. The DSP rejects a 64-fs I2S configuration on this interface for another
   reason (for example the frame-size factor or an SD-line/ws setting
   differing from what the vendor uses) and faults the same way. This can't
   be separated from 1 without logs.
3. Unlikely: clocks or pinctrl (F2), the topology patch (worked in v8), amp
   current (no boost, -40 dBFS).

## How to fix the format mismatch (pick one)
- **A. MFC in the SECONDARY_MI2S device graph.** Build the topology from
  linux-msm/audioreach-topology m4 with a board file for
  SECONDARY_MI2S_RX that copies the codec-DMA playback subgraph's
  `LOG -> MFC -> I2S_RX` pattern. A new
  `subgraph-device-i2s-playback-mfc.m4`: use `AR_MODULE_MFC` from
  `module_mfc.m4` and the BE format `S32_LE`. The kernel already configures
  device-graph MFCs from the BE cfg (`MODULE_ID_MFC` case in
  `audioreach_set_media_format`), so no kernel change is needed. This is the
  upstream-shaped answer. It replaces the binary patcher with a real
  topology build (alsatplg from Fedora is in `fap-build/waffle/audio-pkgs/`).
- **B. S32_LE front end.** Patch q6apm-dai to accept `SNDRV_PCM_FMTBIT_S32_LE`
  (bits_per_sample 32), then play a 32-bit WAV. FE == BE, so no conversion is
  needed and the topology stays as it is. This is the quickest experiment;
  PipeWire/ALSA plug can supply S32 later.
- **C. Fall back to 16-bit I2S and make the amp accept 32 fs.** v8 showed
  TDMERR at 2 x 16. The 16 << n NBCK encoding is a guess (no datasheet), so
  this is weaker than A or B.

## Staged test plan for the next session (each stage needs the user's OK)
All tests are RAM boots of v9 or later. Run the logging stage (0) first,
always. If a stage resets the phone, hold Vol-Down during the reboot to land
in fastboot, then RAM-boot the same image again and read
`/sys/fs/pstore` before anything else.

0. **Logging that survives a reset.**
   a. Verify ramoops once: `echo fap-pstore-test > /dev/pmsg0;
      systemctl reboot --reboot-argument=bootloader`, RAM-boot again, then
      `ls /sys/fs/pstore` (expect `pmsg-ramoops-0`). If it is empty, ramoops
      is useless here, so fix it first (region/ABL) or rely on (b).
   b. Next build: `CONFIG_NETCONSOLE=m`. During tests,
      `modprobe netconsole netconsole=@/<usb-or-wlan-if>,6666@<host-ip>/<host-mac>`
      on the phone and `nc -ul 6666` on the Mac. This catches the last
      kernel lines up to the reset.
   c. Second ssh session: `dmesg -w`. Before the test:
      `echo 'module snd_q6apm +p; module q6apm_lpass_dais +p; module snd_q6dsp_common +p; module q6prm +p' > /proc/dynamic_debug/control`
      (the module names may differ, check `lsmod | grep -i q6`).
   d. Record `grep . /sys/class/remoteproc/*/{name,state,recovery}`
      (recovery should say `enabled`) and `lsmod | grep qcom_wdt`.
1. **Is an ADSP restart alone enough to reset the phone?** With no stream
   running: `echo fatal > /sys/kernel/debug/remoteproc/remoteprocN/crash`
   (N = adsp). This runs Linux's crash-recovery path (shutdown + restart of
   the ADSP, LPASS clients torn down) without an audio graph. If the phone
   resets here, the problem is SSR on this board (LPASS MMIO after ADSP
   loss) and has to be fixed before any audio experiment. If it survives,
   note the dmesg.
2. **16-bit regression on v9** (`echo 16 > /sys/module/snd_soc_sc8280xp/parameters/waffle_sec_mi2s_bits`,
   bottom speaker, -40 dBFS). Expect the v8 behaviour (TDMERR, no reset).
   A reset here means the v9 driver change is involved, not the I2S width.
3. **32-bit I2S with both amps disabled.** Set param 32, both `Amp Enable`
   switches off (amps stay powered down), and play a 16-bit WAV. This
   reproduces the DSP path without the amps. A reset confirms F1 (the DSP
   side); ideally netconsole shows a `q6apm`/`graph` error or a
   `remoteproc ... crash detected` line first.
4. **Fix B (S32 FE), amps still off:** a 32-bit WAV with the patched
   q6apm-dai. No reset means the mismatch was the trigger. Then repeat with
   the bottom amp on at -40 dBFS and expect `on:` without TDMERR/TDMLUTERR.
5. **Fix A (MFC topology)** for normal S16 playback (PipeWire). Repeat
   stage 4 with a 16-bit WAV.

Stop at any reset and do not retry blindly. Collect the logs (pstore and
netconsole) first.

## References
- Kernel (volume `waffle-build-hw`, `/work/linux-waffle`):
  `sound/soc/qcom/sc8280xp.c` (hw_params MI2S branch, `sm8650_priv_data`,
  fixup + patch 0003), `sound/soc/qcom/qdsp6/q6apm-lpass-dais.c`
  (`of_q6apm_parse_dai_data` mclk/bclk, `q6i2s_set_sysclk`),
  `audioreach.c` (`audioreach_i2s_set_media_format`,
  `audioreach_mfc_set_media_format`), `q6apm-dai.c` (formats),
  `q6prm-clocks.c` (`LPASS_CLK_ID_SEC_MI2S_IBIT`).
- Upstream DT examples in the same tree: `qcs8550-ayntec-common.dtsi`
  (AudioReach PRIMARY_MI2S speakers with bclk+mclk on q6prmcc),
  `monaco-evk.dts`, `lemans-evk.dts`, `talos-evk.dts`.
- https://github.com/linux-msm/audioreach-topology: `audioreach/subgraph-device-i2s-playback.m4`,
  `audioreach/subgraph-device-codec-dma-playback.m4`, `audioreach/module_mfc.m4`,
  `Google-SC7180-WSA-Speakers-SEC-I2S-VA-DMIC-WCD-TX3.m4`, `ar-sm8250-rb5-i2s.m4`.
