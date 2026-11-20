<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Reverse-engineering tooling: ideas, ranked

Brainstormed 2026-11-20 by four research passes (firmware/remoteprocs, audio,
display/touch/input, cross-cutting infrastructure), grounded in the N100's
hardware inventory (UBports-N100 `log/hw-inventory/20261120-134342/`). Ideas
already in [roadmap.md](roadmap.md) "Porting tooling" aren't repeated here.
Claims marked *unverified* still need checking.

Guiding rule: extract knowledge from the stock/Halium system **before wiping**,
read-only; then diff vendor vs mainline behaviour through the RAM-boot loop.

## Do first (cheap, high value, near-zero risk)

| # | Tool | What it does | Effort |
|---|---|---|---|
| 1 | **phonectl** (access broker) | One wrapper for all phone access: a lock naming the experiment that owns the phone, policy rules (deny `rmmod` of non-unloadable modules, writes to regulator/charger sysfs, `/dev/mem`, persist; require battery > 50 %, temp limit), every call logged. Extends `flash.sh`'s refusals to runtime commands. | S–M |
| 2 | **Device knowledge base** | `devices/<id>/kb/*.yaml`: one fact per entry with source (DT path, trace, disassembly offset, log line), confidence (hypothesis/observed/confirmed) and date. Tools read and write it; CI rejects facts without a source. | S |
| 3 | **fw-manifest** | Parse every `.mdt`/`.bNN` (ELF headers, hash segment, `QC_IMAGE_VERSION_STRING`), check load addresses against DT carveouts, squash to `.mbn` (pil-squasher), lay out `qcom/sm6115/oneplus/billie2/`, keep `*.jsn` for pd-mapper, write a sha256 manifest. | 1 day |
| 4 | **panelgen** | Run [lmdpdg](https://github.com/msm8916-mainline/linux-mdss-dsi-panel-driver-generator) on the vendor `fdt.dtb`; add the derived 90 Hz mode and ESD check; diff the init table against mainline `panel-ilitek-ili9882t.c`. Paper run: every property it needs is present (40-command on-sequence parses cleanly). | 1–2 days |
| 5 | **railguard** | Resolve panel/amp/charger supplies to real regulators and emit mainline nodes pinned to vendor min = max; fail if any supply is wider than vendor or unconstrained. A wrong regulator limit is the main way software damages hardware. | 1 day |
| 6 | **Bring-up trace recorder** | ftrace tracepoints (no kprobes needed): i2c, spi, regmap, gpio, regulator, clk, enabled from the kernel cmdline so probe-time activity is caught; normalized to one JSONL schema. Records the *sequence* the vendor stack performs. | S–M |
| 7 | **State snapshot + diff** | Read-only dumps of `regulator_summary`, `clk_summary`, gpio, pinmux, fdt and **allowlisted** regmap debugfs, before/after or vendor/mainline. Never `/dev/mem`; never read unclocked blocks (can bus-error and reset Qualcomm SoCs; *unverified* link to today's resets). | S |
| 8 | **qrtr-census** | AF_QIPCRTR lookups to `qrtr-ns` list every QMI service the modem/ADSP/CDSP export; run on stock and on mainline and diff. Lookups only, no requests. | ½ day |
| 9 | **rproc-dt-diff** | Compare vendor remoteproc/smp2p/glink/carveout nodes (pas-id, sysmon/ssctl ids, regions) with mainline `sm6115.dtsi`. Carveout mismatches are a classic cause of remoteproc failures and resets. | 1 day |

## Per subsystem

### Audio
- **dt2mainline-audio:** map bolero/swr/wcd937x/bengal-asoc-snd nodes to
  mainline lpass macros + `qcom,soundwire` + wcd937x + a `qrb4210-rb2`-style card.
  RB2 (same silicon) audio series: [Klimov v3](https://patchew.org/linux/20250522-rb2._5Faudio._5Fv3-v3-0-9eeb08cab9dc@linaro.org),
  [Kandagatla sm6115](https://patchew.org/linux/20251031120703.590201-1-srinivas.kandagatla@oss.qualcomm.com) (merge status *unverified*).
- **mixer2ucm:** vendor `mixer_paths.xml` + `audio_platform_info.xml` → ALSA
  UCM with a vendor→mainline control rename table; volumes clamped to vendor
  values; amp enables kept out of UCM. Prior art: [xml2ucm](https://github.com/ford-prefect/xml2ucm).
- **amp-seq-extract + amp-guard:** pull AW87529/AW87359 register tables and the
  SIA8109 one-wire pulse mode from the vendor `.ko`s; an allow-list write
  firewall for amp I2C (writes outside vendor values need a dummy load; reset
  GPIO low on exit). Protects speakers.
- **regmap-snap, swr-enum-log, pathwalk:** codec/macro register snapshots per
  use case; SoundWire enumeration vendor vs mainline (today's TX-slave bug);
  DAPM route graph showing why a path is unpowered.
- **acdb-dump, apr-trace:** calibration (incl. speaker-protection limits) and
  ADSP packet decoding; larger efforts.
- **ko-abi-scan:** scan vendor `.ko` `.data` for kernel-header constants
  (IDR markers, GFP masks) vs the target kernel; would have flagged the
  `audio_swr.ko` bug automatically.

### Display, touch, input
- **variant-pick:** units ship ILI9882N + Ilitek or NT36525B + Novatek; read the
  ABL `dsi_display0` cmdline and DCS ID registers, refuse mismatched init.
- **incell-seq:** model panel↔touch coupling (shared LCD reset GPIO 82; touch
  reset 71, IRQ 80) to drive DT/driver ordering.
- **tp-sniff:** ftrace `spi:*` + the vendor `ili_*` driver to capture the TDDI
  firmware upload (`noflash`, LCD-triggered) and report format. No mainline
  Ilitek/Novatek SPI driver exists yet (I2C only).
- **dsi-observe, dt-input-translate, evcompare, bl-cap, overlay-loop:**
  confirm the live DSI sequence; translate gpio-keys/fingerprint/boost nodes;
  diff evdev capabilities; cap backlight during bring-up; iterate panel/touch
  via U-Boot `fdt apply` in the RAM-boot loop.
- **Blocker to check first:** mainline support for the PMI632 **LCDB** panel
  supply (`qpnp-lcdb@ec00`); `qcom-labibb-regulator` targets a different block.

### Firmware and remote processors
- **modem-fs-trace:** strace the vendor tftp_server/rmt_storage to learn the
  file tree tqftpserv must serve; first mainline modem boots on RAM copies of
  the backed-up EFS partitions.
- **wlan-bdf:** pack `bdwlan.*` into `board-2.bin` for ath10k_snoc; MAC as DT
  `local-mac-address` (no persist writes; the UBports MAC bug can't recur).
- **qmi-sniff, ipc-timeline, diag-log:** userspace QMI capture to pcap; a boot
  timeline from `ipc_logging` + tracepoints; DSP F3 logs via `/dev/diag` with an
  allowlist of mask commands only (diag can write NV/EFS).
- **qcom-spy.ko, idl-miner:** a read-only observer module (SMEM, tracepoints)
  built against matching headers; reconstruct QMI IDL from vendor libraries.

### Cross-cutting
- **Vendor vs mainline behaviour diff** on the trace recorder's schema.
- **Experiment runner + lab notebook:** `experiment.yaml` (hypothesis, hashes,
  steps, expected), holds the phonectl lock, keeps capture running, records the
  verdict in the KB. Detects and alerts on EDL/fastboot; never writes via EDL
  automatically. USB power-cycling doesn't reset a phone with a battery.
- **Last-gasp tracing:** ramoops sized for the trace buffer, `ftrace_dump_on_oops`,
  `tp_printk` over netconsole. An empty pstore after a reset is itself evidence
  the reset path doesn't preserve RAM.
- **Vendor .ko analysis pipeline:** headless Ghidra: strings, consumed DT
  property names, const init tables, and diffs against CAF/LineageOS builds
  ([ghidriff](https://clearbluejar.github.io/posts/ghidriff-ghidra-binary-diffing-engine/), [BinDiff](https://github.com/google/bindiff)).
- **LLM-assisted vendor DT → mainline,** gated: provenance comment per node,
  `dtbs_check`, trace diff, human sign-off on regulator/charger/thermal/backlight.
- **Vendor userspace audit:** parse `init*.rc` for writes/truncations touching
  persist, sysfs or firmware (the UBports MAC bug came from one).
- **Bus sniffing hardware:** last resort, only for traffic the kernel can't see.

## Safety themes across all four passes
- Read-only by default; every write path has an allow-list and a log.
- Hardware damage comes from rails, boost converters and amps: pin to vendor
  values, never wider.
- Capture stock knowledge before the first wipe.
- Never automate EDL writes.
