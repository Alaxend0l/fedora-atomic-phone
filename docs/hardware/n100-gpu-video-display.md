<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# N100: GPU (Adreno 610), video codec (Venus), display leftovers

Bring-up plan for the OnePlus Nord N100 (`oneplus-billie2`, SM4250/SM6115
"bengal") on mainline Linux 7.3 (Fedora 45 kernel 7.3.4). Written 2026-11-20
from desk research only: **nothing here has been tested on the phone yet**.
Guesses are marked *(guess)*. The starting point for each section is what
we already have: MSM DRM drives the ILI9882N panel through our lmdpdg module, and
dmesg says `no GPU device was found` because `&gpu` is still disabled.

Sources used (paths are local unless they're URLs):
- Vendor DT and logs: `UBports-N100/log/hw-inventory/20261120-134342/`
  (`device-tree.dts`, `raw/dmesg.txt`, `raw/firmware.txt`, `raw/regulators.txt`)
- Mainline v7.3: `fap-build/linux` (sparse) and `torvalds/linux@v7.3` via the GitHub API
- Fedora 45 kernel config: `fap-build/netroot/netroot.tar.gz:usr/lib/modules/7.3.4-300.fc45.aarch64/config`
- Vendor LCDB driver: `OnePlusOSS/android_kernel_oneplus_sm4250@oneplus/SM4250_R_11.0:drivers/regulator/qpnp-lcdb-regulator.c`
- ROCKNIX PMI632 LCDB patch: `ROCKNIX/distribution:projects/ROCKNIX/devices/SM6115/patches/linux/0061-regulator-add-qcom-pmi632-lcdb-driver.patch`
- Mesa: `gitlab.freedesktop.org/mesa/mesa` main, `src/freedreno/common/freedreno_devices.py`
- Copies of the fetched files: `fap-build/research/gpu-video-display/`

## 1. Inventory

| Block | Vendor (Android 11 / UT) | Mainline 7.3 | Fedora 45 config |
|---|---|---|---|
| GPU Adreno 610 (chip id 0x06010000) | `5900000.qcom,kgsl-3d0`, OPPs 320–980 MHz, `kgsl-smmu` @59a0000 | `gpu: gpu@5900000` in `sm6115.dtsi` (`qcom,adreno-610.0`), **status disabled**; `gmu_wrapper`, `gpucc`, `adreno_smmu` present | `DRM_MSM=m`, `SM_GPUCC_6115=m`, `ARM_SMMU_QCOM=y`, `NVMEM_QCOM_QFPROM=m` |
| GPU zap shader | `qcom,kgsl-hyp` PIL, pas-id 13, `a610_zap`, region `gpu_region@56115000` (0x2000) | `gpu_zap_shader` → `pil_gpu_mem: memory@56115000` (same address/size) | `QCOM_MDT_LOADER=m` |
| Venus (AR50_LITE, VPU "6.0") | `5ab0000.qcom,venus`, `pil_video_region@51400000` (0x500000), state ONLINE | `venus: video-codec@5a00000`, `"qcom,sm6115-venus","qcom,qcm2290-venus"`, `pil_video_mem@51400000` (same), **disabled** | `VIDEO_QCOM_VENUS=m`, `VIDEO_QCOM_IRIS=m` |
| Panel | `qcom,mdss_dsi_ili9882n_90hz_video`, maker **BOE** (`oneplus,mdss-dsi-manufacture`), 720×1600, 4 lanes, video mode, DCS backlight 11-bit | our `kmod/panel-ili9882n` (out of tree) | `DRM_PANEL_ILITEK_ILI9882T=m` (not ours) |
| Panel supplies | `vddio` = PM6125 L9 1.8 V; `lab` = LCDB LDO +6.0 V; `ibb` = LCDB NCP −6.0 V (`dsi_panel_pwr_supply`, vendor DT line 17433) | L9A exists (`vreg_l9a` 1.8–2.0 V); **no LCDB driver** | `REGULATOR_QCOM_LABIBB=m` (wrong block, see §4.1) |
| LCDB | `pmi632_lcdb: qpnp-lcdb@ec00` on **PMI632 SID 3**, ldo/ncp 6000 mV, bst 6150 mV; dmesg: `lcdb_en=1 ldo_voltage=6000mV ncp_voltage=6000mV bst_voltage=6150mV` | nothing (FP3/FP4 use a `regulator-fixed` dummy "until PMI632 has LCDB VSP/VSN support") | – |

Second panel option in the vendor DT: `qcom,mdss_dsi_nt36525b_inx_video` (INX
NT36525B, PWM backlight). ABL picks one through `msm_drm.dsi_display0=` on the
cmdline; **this unit has the ILI9882N** (cmdline in vendor DT line 527). Other
N100 units may have the NT36525B *(guess, based on the DT listing both)*.

## 2. Firmware: names, and where the files are on the phone

| File(s) | On the phone | Accessible from our netroot? | Mainline name |
|---|---|---|---|
| `a610_zap.mdt` + `.b00 .b01 .b02` (also `a610_zap.elf`) | `/vendor/firmware/` = `vendor_a` logical partition inside **`super`** (sda10) | not yet: needs `super` unpacked read-only | `a610_zap.mdt` is the driver default (`a6xx_catalog.c`: `.zapfw = "a610_zap.mdt"`); DT `firmware-name` overrides it |
| `a630_sqe.fw` (32008 bytes) | `/vendor/firmware/` | same | `a630_sqe.fw` (catalog `[ADRENO_FW_SQE]`). Also in linux-firmware as `qcom/a630_sqe.fw`; use that copy |
| `venus.mdt` + `.b00`…`.b10`, `.b19` | `modem_a` (vfat) `image/` (`/vendor/firmware_mnt/image`) | **yes**: `fap-modem-ram` bind-mounts it at `/run/fap-firmware/qcom/sm6115/OnePlus/billie2/` | driver default `qcom/venus-6.0/venus.mbn` (QTI-signed for RB2, **won't authenticate** on a retail secure-boot phone *(guess, standard for OEM devices)*); use DT `firmware-name` |

- No GMU firmware is needed: A610 is "GMU-less" (`qcom,adreno-gmu-wrapper`,
  `.funcs = &a6xx_gmuwrapper_funcs`).
- The zap and Venus blobs are OnePlus-signed and **not redistributable**. Keep
  them out of the git repo and out of public images: copy them into the
  local netroot only, or extract them at runtime like `fap-modem-ram` does.
- Venus needs firmware ≥ 6.0.55 (`min_fw` in `venus/core.c`). The phone's
  version isn't known yet: `strings venus.b* | grep -m1 VIDEO.VE` on the modem
  mount will show it.
- Extracting `vendor_a` from `super` without writing anything: `lpunpack`
  (shipped in Fedora's `android-tools`? *(guess, check with `dnf provides '*/lpunpack'`)*)
  on an image of `/dev/disk/by-partlabel/super` read on the host, then
  `mount -o ro,loop` the ext4/erofs image. Simpler: the main agent pulls
  `/android/vendor/firmware/a610_zap.*` from Ubuntu Touch with `adb pull`
  (read-only; per AGENTS.md only the main agent touches the phone).

## 3. Mainline status

### 3.1 GPU
- DT: everything is in `sm6115.dtsi` (`gpu`, `gpu_opp_table` with 320–980 MHz
  and `opp-supported-hw` speed bins, `gmu_wrapper`, `gpucc`, `adreno_smmu`).
  Boards enable it with two nodes; see `qrb4210-rb2.dts:237`,
  `sm6115-fxtec-pro1x.dts:122`, `sm6115p-lenovo-j606f.dts:68`.
- Driver: `drivers/gpu/drm/msm/adreno/a6xx_catalog.c` (v7.3) has the A610 entry
  (`chip_ids 0x06010000`, gmem 132 KiB, `ADRENO_QUIRK_4GB_VA`, speed bins
  fuse 0→bin0, 206→1, 200→2, 157→3, 127→4). The vendor kernel offered 980 MHz,
  which only bins 0/1 allow, so this unit is probably bin 0 *(guess)*.
- Speed bin comes from `nvmem-cells = <&gpu_speed_bin>` (qfprom): needs
  `nvmem_qfprom` loaded, or the GPU defers.
- Userspace: Mesa main lists `GPUId(610)` in `freedreno_devices.py` (a6xx gen1
  low, `num_ccu = 1`). It has been in Mesa since 2023 *(from memory, ~23.1)*,
  so Fedora 45's Mesa has the freedreno Gallium driver (GLES/GL) and turnip
  (Vulkan) for it.

### 3.2 Venus
- DT node in `sm6115.dtsi:1856` (added 2026-07, "arm64: dts: qcom: sm6115: add
  venus device"), binding `media/qcom,qcm2290-venus.yaml` allows
  `qcom,sm6115-venus` + `qcom,qcm2290-venus`.
- Driver in 7.3: **Venus** handles it (`qcm2290_res`, `VPU_VERSION_AR50_LITE`,
  `HFI_VERSION_4XX`, decoder and encoder nodes, max load 352800 = 1080p30-ish).
  Iris in 7.3 doesn't list qcm2290.
- After 7.3: "media: venus: skip QCM2290 if Iris driver is enabled" (Dmitry
  Baryshkov) plus Iris support for QCM2290. That commit isn't in v7.3
  (`compare v7.3...<sha>` = diverged). Fedora builds Iris (`=m`), so **from
  that kernel on, Iris will drive this block**. The same DT should work, but
  the firmware requirements may differ. Recheck when Fedora moves past 7.3.
- Firmware is loaded at **probe**. With firmware from `modem_a`, Venus must
  probe *after* `fap-modem-ram` has run, or be re-probed
  (`modprobe -r venus_enc venus_dec venus_core; modprobe venus_core`).

### 3.3 Display leftovers
- LCDB: no mainline driver, and no lore posting found (lore returned 403 to
  scripted search; a web search found nothing). The **ROCKNIX** distribution
  carries `qcom-lcdb-regulator.c` (compatible `qcom,pmi632-lcdb`, author
  "Noxwell", 2026-09-27, 215 lines) for SM6115/SM6125 handhelds, in use on the
  Retroid Pocket (`vsp-supply = <&lcdb_ldo>; vsn-supply = <&lcdb_ncp>;`). It's
  the obvious base. Batocera/ROCKNIX also carry a PM8150L LCDB patch for SM8250.
- `qcom-labibb-regulator.c` in mainline is for the older LAB/IBB block
  (`qcom,pmi8998-lab-ibb`), a different register map, so it doesn't apply.
- Panel driver: see §6.

## 4. Missing pieces and how to fill them

### 4.1 LCDB regulator (PMI632 @ SID 3, base 0xec00)
Registers from the vendor driver (`qpnp-lcdb-regulator.c`) as used by the
ROCKNIX driver:

| Reg (offset) | Use |
|---|---|
| 0x10 INT_RT_STATUS | bit0 `VREG_OK`: poll after enable |
| 0x46 ENABLE_CTL1 | bit7 `MODULE_EN`: one enable for both rails (shared boost) |
| 0x71 LDO_OUTPUT_VOLTAGE | 5-bit selector: 4.0–4.9 V in 100 mV steps (0–9), 4.95–6.0 V in 50 mV steps (10–31) |
| 0x81 NCP_OUTPUT_VOLTAGE | same encoding, magnitude of the negative rail |
| 0x79 LDO_FORCE_PD_CTL | vendor's `FORCE_PD_ENABLE_WA` for PMI632/PM6150L: force pull-down around disable, wait 10 ms, release |
| 0x41 BST_OUTPUT_VOLTAGE | boost (6.15 V here); the vendor sets it from ldo/ncp, ROCKNIX doesn't touch it |

The minimal driver needs:
1. Two regulators `ldo` (VSP) and `ncp` (VSN) sharing a refcounted module
   enable. Read `ENABLE_CTL1` at probe so the bootloader-on state is adopted
   (ROCKNIX does this).
2. Linear-range voltage ops on 0x71/0x81. In our DT, pin both rails to exactly
   **6000000 µV** (vendor value) so the core can never pick anything else.
3. **Missing from ROCKNIX, needed for upstream:** the PMI632 force-pull-down
   workaround on disable; `reg = <0xec00>` in DT instead of a hard-coded base;
   `off-on-delay-us = 20000` (vendor `PMIC5_LCDB_OFF_ON_DELAY_US`); optionally
   the `sc-irq` short-circuit interrupt (`<0x3 0xec 0x1 IRQ_TYPE_EDGE_RISING>`
   from the vendor DT). TTW (touch-to-wake) mode isn't needed.
4. Binding `regulator/qcom,pmi632-lcdb.yaml` (ROCKNIX has a draft; add `reg`,
   `interrupts`, and a PM6150L fallback, since FP4 needs the same block).

### 4.2 Panel power-off and suspend
Today `unprepare` sends display-off + sleep-in and asserts reset, but every rail
stays on. Target sequence, taken from the vendor `dsi_panel_pwr_supply`
(`post-on-sleep` 20 ms on vddio and ibb) and `reset-sequence <1 10 0 10 1 10>`:

- **prepare:** enable vddio (L9A 1.8 V) → 20 ms → enable vsp (LCDB LDO) → enable
  vsn (NCP) → 20 ms → reset sequence → init commands.
- **unprepare:** display off, sleep in (120 ms) → assert reset → disable vsn →
  disable vsp → disable vddio.

Use `regulator_bulk_*` with names `vddio`, `vsp`, `vsn`. Until the LCDB driver
exists, `vsp`/`vsn` can point at a `regulator-fixed` dummy as FP3 does
(`sdm632-fairphone-fp3.dts:75`), so the panel driver and binding can go
upstream first.

Caveat: once the LCDB driver is loaded, the regulator core turns off unclaimed
rails ~30 s after boot. If the panel module isn't bound by then, the screen goes
dark. That's harmless, but it's confusing to debug.

### 4.3 The 90 Hz mode
The vendor has **one** timing (60 Hz, VFP 1348) plus
`qcom,dsi-supported-dfps-list = <90 60>` and `dfps_immediate_porch_mode_vfp`:
90 Hz is the same pixel clock with a shorter VFP. Check: 784 × 2968 × 60 =
139.61 MHz → ×24 bpp / 4 lanes = 837 688 320 bit/s, which is **exactly** the
first entry of `qcom,dsi-dyn-clk-list` (0x31ee1c00). For 90 Hz:
vtotal = 2968 × 60 / 90 ≈ 1979 → VFP = 1979 − 1600 − 2 − 18 = **359**
*(computed; the vendor computes it at runtime)*.

```c
/* untested: second mode, same htotal, VFP 359 */
static const struct drm_display_mode ili9882n_90hz_mode_90 = {
	.clock = (720 + 28 + 8 + 28) * (1600 + 359 + 2 + 18) * 90 / 1000, /* 139641 kHz */
	.hdisplay = 720, .hsync_start = 748, .hsync_end = 756, .htotal = 784,
	.vdisplay = 1600, .vsync_start = 1959, .vsync_end = 1961, .vtotal = 1979,
	.width_mm = 68, .height_mm = 151,
	.type = DRM_MODE_TYPE_DRIVER,
};
```
`get_modes` then adds both (a loop of `drm_mode_duplicate` +
`drm_mode_probed_add`), with 60 Hz marked `PREFERRED` until 90 Hz is proven.
MSM DSI recomputes byte/pixel clocks on every modeset, so a switch is a full
modeset (blank and re-init). That's acceptable, but not seamless like the vendor's
porch update.

### 4.4 Untested DT snippets (add to `devices/oneplus-billie2/dts/sm4250-oneplus-billie2-fap.dts`)

```dts
&gpu {
	status = "okay";
};

&gpu_zap_shader {
	/* a610_zap.mdt + .b00-.b02 from vendor_a:/firmware (OnePlus-signed) */
	firmware-name = "qcom/sm6115/OnePlus/billie2/a610_zap.mdt";
};

&venus {
	/* from modem_a:/image via fap-modem-ram */
	firmware-name = "qcom/sm6115/OnePlus/billie2/venus.mdt";
	status = "okay";
};

/* needs the out-of-tree qcom-lcdb-regulator (ROCKNIX-based); step 8 below */
&spmi_bus {
	pmic@3 {
		pmi632_lcdb: lcdb@ec00 {
			compatible = "qcom,pmi632-lcdb";
			reg = <0xec00>;		/* ROCKNIX driver ignores reg; ours shouldn't */

			lcdb_ldo: ldo {
				regulator-name = "lcdb_ldo";
				regulator-min-microvolt = <6000000>;
				regulator-max-microvolt = <6000000>;
			};

			lcdb_ncp: ncp {
				regulator-name = "lcdb_ncp";
				regulator-min-microvolt = <6000000>;
				regulator-max-microvolt = <6000000>;
			};
		};
	};
};

&mdss_dsi0 {
	panel@0 {
		compatible = "oneplus,billie2-boe-ili9882n";	/* see §6 */
		vddio-supply = <&vreg_l9a>;
		vsp-supply = <&lcdb_ldo>;
		vsn-supply = <&lcdb_ncp>;
		/* reset-gpios, port: unchanged */
	};
};
```
Firmware placement: zap blobs go in the rootfs as
`/usr/lib/firmware/qcom/sm6115/OnePlus/billie2/a610_zap.{mdt,b00,b01,b02}`.
The kernel tries `firmware_class.path` (`/run/fap-firmware`) first and the
standard directories after it, so the zap and modem_a's venus can sit in
different places. `a630_sqe.fw` comes from Fedora's linux-firmware (check which
subpackage with `dnf provides '/usr/lib/firmware/qcom/a630_sqe.fw*'`); it needs
to be in the initramfs only if `msm` loads from the initramfs *and* the GPU is
opened there *(guess: the a6xx GPU is loaded on first open of the DRM device,
so the rootfs copy is enough)*.

## 5. Test plan (least → most risky)

Everything is RAM-boot + netroot. Nothing is written to UFS. Only the main
agent runs adb/fastboot/ssh. Steps 9–10 write PMIC registers, which are
volatile (they reset on power-off), but they need the user's OK first.

1. **Offline:** add the GPU/Venus snippets, build with `tools/build-dtb.sh`, run
   `dt-validate`/`make dtbs_check` for the billie2 DTB. No phone.
2. **Firmware facts (read-only):** in the netroot after `fap-modem-ram`:
   `ls /run/fap-firmware/qcom/sm6115/OnePlus/billie2/venus.*`,
   `strings …/venus.b* | grep -m1 VIDEO.VE` (needs ≥ 6.0.55). Main agent pulls
   `/android/vendor/firmware/a610_zap.*` and `a630_sqe.fw` from Ubuntu Touch and
   records sha256 in `UBports-N100/log/`.
3. **LCDB state, read-only:** with the current DT, read PMI632 SID 3 registers
   0xec10, 0xec46, 0xec71, 0xec81 (regmap debugfs under
   `/sys/kernel/debug/regmap/` for the `pmic@3` device, or `spmi` debugfs if
   available). Expect 0xec46 bit7 = 1, 0xec71/0xec81 = 0x1f (6.0 V). This
   confirms the register map before anything writes to it.
4. **GPU:** boot with `&gpu` enabled + zap/sqe in the netroot. Check: dmesg for
   `a610`/zap load errors, `/dev/dri/renderD128`, `modprobe nvmem_qfprom`
   first if the GPU defers. Then run `kmscube`, `glmark2-es2-drm`, `eglinfo`,
   `vulkaninfo --summary` (turnip). Watch for SMMU faults and `hangcheck`.
   If it fails with `-ENOENT`, the firmware path is wrong. A zap auth failure
   shows up as a PAS error from `qcom_scm`.
5. **GPU load + resets:** run glmark2 for 10 min with `tools/capture.sh` from
   the UBports repo watching. Resets under GPU load would be a new data point
   for the unexplained PS_HOLD resets.
6. **Venus:** after `fap-modem-ram`, re-probe venus (§3.2). Then
   `v4l2-ctl --list-devices`; `v4l2-compliance -d /dev/videoN`; decode test
   `gst-launch-1.0 filesrc location=t.mp4 ! qtdemux ! h264parse ! v4l2h264dec ! fakesink`
   (or `ffmpeg -c:v h264_v4l2m2m`), then try an encoder with `v4l2h264enc`.
7. **Panel blank/unblank without LCDB (current module):** `modetest -M msm`
   to set DPMS off/on, or `echo 1 > /sys/class/graphics/fb0/blank` then `0`.
   This exercises unprepare/prepare (sleep-in, reset, full re-init) with rails
   still on. It must come back cleanly before any rail gets switched.
8. **90 Hz mode:** panel module with two modes; `modetest -M msm -c` lists
   both; set 90 Hz with `modetest -s <conn>@<crtc>:720x1600-90`, then measure
   with `kmscube` or vblank timestamps (`drm_info`, `/sys/kernel/debug/dri/*/`).
   Watch for underflow/flicker. Rollback: reboot (RAM-only).
9. **LCDB driver, adopt-only:** load the LCDB module with the panel *not*
   claiming the rails and `regulator-always-on` on both. Probe must report
   enabled at 6.0 V with no register writes. Ask the user first.
10. **LCDB switching:** panel module with `vddio/vsp/vsn`; DPMS off → LCDB
    `MODULE_EN` clears; DPMS on → VREG_OK and a clean image. Repeat 50×.
    Failure mode: black screen, recovered by forced restart
    (Power + Vol Up 15 s). Ask the user first.
11. **System suspend:** `systemctl suspend` (s2idle) with the panel off, then
    wake with the power key. This depends on PMIC/IRQ wake work beyond this doc.

## 6. Upstreaming the panel driver

### Does ILI9882N fit `panel-ilitek-ili9882t.c`?
Partly. It shares the page-switch command (`FF 98 82 <page>`, the driver's
`ili9882t_switch_page`), video mode, and 4 lanes. But that driver is built for
Chromebook tablets:
- supplies are hard-wired `pp3300`, `pp1800`, `avdd`, `avee` (N100: `vddio`,
  `vsp`, `vsn`), and the binding lives in `boe,tv101wum-nl6.yaml` (Chromebook
  panels).
- it uses `enable-gpios` with a Chromebook-specific reset dance, an
  external backlight (`drm_panel_of_backlight`; N100 uses DCS 11-bit
  brightness), and exactly one mode (`get_modes` returns 1).
- the IL79900A support that was added there got its own binding
  (`ilitek,il79900a.yaml`); the patch series history shows the maintainers
  pushing in that direction.

Recommendation *(judgment call)*: a **new driver `panel-ilitek-ili9882n.c`**
with a `struct panel_desc` (init sequence, modes, size), shaped like the
ili9881c multi-panel driver, so the NT36525B-style "same phone, other panel" and
other ILI9882N phones (Realme 7, Samsung A12/A32, Volla: many ILI9882N panels
in vendor trees) can be added. Fallback if the reviewers prefer it: add a desc
plus `dcs_backlight` / `supplies` / `modes[]` fields to ili9882t. Ask on
dri-devel in the cover letter.

### Checklist
1. Binding `Documentation/devicetree/bindings/display/panel/ilitek,ili9882n.yaml`:
   `compatible: items: [enum: [oneplus,billie2-boe-ili9882n], const: ilitek,ili9882n]`
   (precedent for this naming: `lenovo,j606f-boe-nt36523w`,
   `xiaomi,elish-boe-nt36523`); `reg`, `reset-gpios`, `vddio-supply`,
   `vsp-supply`, `vsn-supply`, `port`, `$ref: panel-common.yaml`. `oneplus` is
   already a vendor prefix. Validate with `make dt_binding_check`.
2. Driver: rename symbols from the generated `ili9882n_90hz_*`; decode the init
   table into a `{page, cmd, data}` array like ili9881c, or keep
   `mipi_dsi_dcs_write_seq_multi` with `ili9882n_switch_page()`; add
   `regulator_bulk`; both modes; DCS backlight (`BACKLIGHT_RAW`, max 2047)
   *without* the generated `get_brightness` TODO unless readback is confirmed.
   We saw readback 90/884/305 for 100/1000/345, which is the vendor's
   `oneplus,dsi-brightness-remapping`, so readback isn't 1:1: drop
   `get_brightness`. Use `devm_drm_panel_alloc`, `prepare_prev_first`,
   `mipi_dsi_multi_context`, and no `of_device.h`.
3. License and author: lmdpdg output is GPL-2.0-only, derived from the vendor DT
   (keep the "Generated with linux-mdss-dsi-panel-driver-generator" credit).
   Real name + `Signed-off-by` from the user.
4. Kconfig `DRM_PANEL_ILITEK_ILI9882N` (depends `OF`, `DRM_MIPI_DSI`,
   `BACKLIGHT_CLASS_DEVICE`), Makefile, MAINTAINERS entry.
5. Board DT patch for `sm4250-oneplus-billie2.dts`: `&mdss`, `&mdss_dsi0`
   (+ `vdda-supply = <&vreg_l18a>`), `&mdss_dsi0_phy`, panel node; until the LCDB
   driver lands, `vsp`/`vsn` use a `regulator-fixed` dummy as FP3 does.
   Separate series to qcom DT maintainers, after the binding is accepted.
6. Run `scripts/checkpatch.pl --strict`, `make W=1` on drivers/gpu/drm/panel,
   `dtbs_check`; test on 7.3 + drm-misc-next.
7. Send with `b4`: To dri-devel, panel maintainers (Neil Armstrong, Jessica
   Zhang), DT maintainers; cc linux-arm-msm. Cover letter: hardware, how the
   init sequence was obtained, what's tested (prepare/unprepare cycles, 60/90 Hz).
8. Then the LCDB series (regulator: Mark Brown; binding + driver + `pmi632.dtsi`
   node), credit ROCKNIX/Noxwell (`Co-developed-by` only with their consent;
   otherwise reference it in the cover letter).
9. Then GPU + Venus enablement in the board DT (`firmware-name` under
   `qcom/sm4250/OnePlus/billie2/` or `qcom/sm6115/OnePlus/billie2/`; check
   recent qcom board patches for the preferred path).

## 7. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| LCDB over-voltage (> 6 V) damages the panel | low with constraints | min = max = 6000000 µV in DT; read registers before the first write (step 3) |
| LCDB short circuit not handled (minimal driver ignores `sc-irq`) | low | add SC irq handling before upstream; watch for VREG_OK timeout |
| Missing PMI632 force-pull-down on disable → slow discharge, panel artifacts on re-enable | medium | implement vendor `FORCE_PD_ENABLE_WA` |
| Regulator late-cleanup turns LCDB off when the panel module isn't bound | medium | `regulator-always-on` during bring-up only |
| Zap shader doesn't authenticate / wrong path → no GPU (KMS still works) | medium | step 4 error triage; KMS is independent of the GPU |
| GPU load triggers the unexplained PS_HOLD resets | unknown | capture.sh during step 5; compare with UT reset rate |
| Venus firmware < 6.0.55, or Iris takes over in the next kernel | medium | step 2 version check; retest on each Fedora kernel bump |
| Venus probes before modem_a firmware is available | certain with current netroot | re-probe after `fap-modem-ram`, or a udev/systemd ordering unit |
| 90 Hz mode underflows/flickers (VFP 359 is computed, not vendor-provided) | medium | 60 Hz stays preferred; RAM boot = reboot to recover |
| Other N100 units have the NT36525B panel | plausible | upstream DT needs a way to pick the panel (ABL cmdline only); out of scope for now |
| Firmware redistribution (OnePlus-signed zap/venus) | certain | never commit or ship; extract on device |
