<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12 downstream kernel (OnePlusOSS, LineageOS)

Desk research, 2026-11-20; nothing built yet. What it's for: the downstream
kernel is our **reference for every board detail** (GPIOs, regulators,
panel init sequences, touch protocol). We don't intend to ship it (see
"Halium-style fallback" at the end). Raw notes:
`fap-build/research/oneplus12/notes/downstream-and-hw.md`.

## Repositories
OnePlus publishes three repos for SM8650, each with OnePlus 12 branches
`oneplus/sm8650_u_14.0.0_oneplus12`, `oneplus/sm8650_v_15.0.0_oneplus12`
(default) and `oneplus/sm8650_b_16.0.0_oneplus12`. The same repos carry
branches for other SM8650 OPLUS devices (Ace 3 Pro, Ace 5, 13R, Pad Pro, Pad 2).

| Repo | Contents | Version (pinned) |
|---|---|---|
| <https://github.com/OnePlusOSS/android_kernel_oneplus_sm8650> | Qualcomm "msm-kernel" (GKI 6.1 + msm drivers): `build.config.msm.pineapple`, `pineapple.bzl`, `msm_kernel_la.bzl`, `modules.list.msm.pineapple` | 6.1.118 on v_15 (`e39bf703`), 6.1.141 on b_16 |
| <https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8650> | Android common kernel (ACK, the GKI `Image`) | 6.1.118 (`d4ebeebd`) |
| <https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8650> | `kernel_platform/` (Kleaf build, `oplus/build/` scripts, `qcom/proprietary/devicetree/`) + `vendor/` (Qualcomm techpacks: display, camera, audio, video, wlan; `oplus/` drivers; `nxp/opensource` NFC) | `38d50357` (2025-09-25) |

LineageOS (all branches `lineage-22.2` … `lineage-24.0`; maintainer chandu078, WIKI waffle.yml:25):

| Repo | Use |
|---|---|
| <https://github.com/LineageOS/android_kernel_oneplus_sm8650> | merged kernel, 6.1.182 on lineage-24.0 (most up to date LTS) |
| <https://github.com/LineageOS/android_kernel_oneplus_sm8650-modules> | techpacks + oplus modules as external modules |
| <https://github.com/LineageOS/android_kernel_oneplus_sm8650-devicetrees> | same `oplus/waffle-*` DTs (`efac9372`) |
| <https://github.com/LineageOS/android_device_oneplus_sm8650-common> | BoardConfig, fstab, init, HALs |
| <https://github.com/LineageOS/android_device_oneplus_waffle> | device bits, props per region, firmware list |

## Build
- **OnePlus way**: Qualcomm Kleaf/Bazel via
  `kernel_platform/build/android/prepare_vendor.sh` with LTO=thin
  (`kernel_platform/oplus/build/oplus_build_kernel.sh:10`; `oplus_setup.sh`
  selects platform `pineapple`, variants `gki`/`consolidate`). Needs the full
  Qualcomm "kernel_platform" layout (prebuilts, clang); heavy, Linux x86_64 host.
- **LineageOS way** (simpler, in-tree Kbuild; LC `BoardConfigCommon.mk:80-154`):
  ```
  defconfig fragments: gki_defconfig + vendor/pineapple_GKI.config + vendor/oplus/pineapple_GKI.config
  extra flags:         CONFIG_OPLUS_DEVICE_DTBS=y (LC), CONFIG_WAFFLE_DTB=y (LW BoardConfig.mk:21)
  image:               Image (uncompressed), base 0x0, pagesize 4096, header v4
  cmdline:             sysctl.kernel.firmware_config.force_sysfs_fallback=1
  module lists:        modules.{vendor_boot,vendor_dlkm,system_dlkm,recovery}.list.{msm,oplus}.pineapple
  ext modules:         qcom/opensource/{display-drivers,audio-kernel,camera-kernel,video-driver,
                       graphics-kernel,wlan/qcacld-3.0/.kiwi_v2,bt-kernel,dsp-kernel,...},
                       nxp/opensource/driver, oplus/kernel/{touchpanel/synaptics_hbp,
                       device_info/tri_state_key,...}, oplus/sensor/kernel/oplus_consumer_ir
  ```
- For our purposes we only need to **compile the DTs** (to read the merged
  board DT) and sometimes **build single modules** to compare behaviour; a
  full Android kernel build isn't needed. A cheap way to get the merged DT:
  extract `dtb` from a stock `vendor_boot` (header v4 vendor_boot carries the
  DTB) and `dtbo.img` from the OTA (`payload-dumper-go`), then `fdtoverlay`
  base + waffle overlay, then `dtc -I dtb -O dts` (guess: works as on other
  QC devices; check `mkdtimg dump` for the overlay id table).

## Device-tree layout (OPDT)
```
kernel_platform/qcom/proprietary/devicetree/
  qcom/pineapple.dtsi, pineapple-v2.dtsi        SoC (downstream naming)
  qcom/pineapple-mtp-overlay.dts                board base: msm-id <557 0x10000>,<557 0x20000>,<577 ...>, board-id <8 0>
  qcom/pineapple-pmic-overlay.dtsi:3-9          PMIC list
  oplus/Makefile:4-9                            which waffle overlays are built
  oplus/waffle-22825-pineapple-overlay.dts      China board  (+ -EVB, -EVT1)
  oplus/waffle-22877-pineapple-overlay.dts      global board (+ -EVB, -EVT1)
    includes: pineapple-mtp-overlay.dts, pineapple_overlay_common.dtsi, waffle_overlay_common.dtsi,
              oplus_chg/oplus-chg-22825.dtsi, oplus_misc/oplus-misc-22825.dtsi,
              sensor/waffle-sensor-22825.dtsi, tp/waffle-oplus-tp-22825.dtsi, oplus_fp/oplus_fp_22825.dtsi
    model = "Qualcomm Technologies, Inc. Pineapple MTP,waffle"
vendor/qcom/proprietary/
  display-devicetree/oplus/waffle-22825-display-pineapple-overlay.dts{,i}, panel/, pxlw-waffle/
  audio-devicetree/oplus/waffle-22825-audio-pineapple-overlay.dts{,i}
  camera-devicetree/oplus/waffle-camera-overlay.dts, waffle_camera_overlay_common.dtsi
```
DT selection is the usual Qualcomm scheme plus OPLUS ids. The waffle
overlay root carries (OPDT `oplus/waffle-22877-pineapple-overlay.dts:1-19`,
`qcom/pineapple-mtp-overlay.dts:7-10`):
```
compatible     = "qcom,pineapple-mtp", "qcom,pineapple", "qcom,pineapplep-mtp", "qcom,pineapplep", "qcom,mtp";
qcom,msm-id    = <557 0x10000>, <557 0x20000>, <577 0x10000>, <577 0x20000>;
qcom,board-id  = <8 0>;                 /* MTP */
oplus,project-id = <22877>;             /* 22825 on the China board */
oplus,hw-id    = <OPLUS_EVT2 OPLUS_DVT1 OPLUS_DVT2 OPLUS_PVT1>;  /* dt-bindings/oplus/hw-id.h */
```
ABL picks the base DTB (from vendor_boot) by msm-id/board-id and the dtbo
entry by the same ids plus (guess, OPLUS ABL patch) `oplus,project-id` /
`oplus,hw-id`. A mainline DTB must therefore carry at least
`qcom,msm-id = <557 0x20000>` (guess: v2 silicon on retail) and
`qcom,board-id = <8 0>` to be accepted, unless dtbo is erased and ABL falls
back. See boot-and-flashing.md.

## Where to look for each porting task
| Task | Downstream file |
|---|---|
| panel init/off sequences, DSC params, timings | `VQ/display-devicetree/oplus/panel/dsi-panel-AC545-P-3-A0005*.dtsi` (`qcom,mdss-dsi-on-command` etc.); driver logic in `vendor/qcom/opensource/display-drivers/msm/dsi/` + `oplus/` panel features |
| Iris7 bypass | `VQ/display-devicetree/oplus/pxlw-waffle/`, display-drivers `pxlw/` (to check: what the bootloader/kernel writes in abyp mode) |
| touch protocol | `vendor/oplus/kernel/touchpanel/synaptics_hbp/syna_tcm2.c` + `tcm/synaptics_touchcom_core_v{1,2}.c` (Synaptics TouchComm). "HBP" = **host-based processing**: the IC can stream raw frames to a userspace daemon (`REPORT_HBP_ACTIVE_FRAME 0x23`), but it also has an on-chip **LBP mode (DC_CONTROL_LBP_HBP = 2, the default)** in which the kernel driver reports coordinates itself (`input_mt_slot` at syna_tcm2.c:699,855; "points report by daemon only" only when the cdev is open, :839). So a plain kernel driver in LBP mode should work (sourced from code; untested). Alternative tree: `vendor/oplus/kernel/tp/hbp/hbp/chips/synaptics/Syna_tcm_S3910/` |
| alert slider | `vendor/oplus/kernel/device_info/tri_state_key/` |
| charger / battery | `DT/oplus/oplus_chg/`, `vendor/oplus/kernel/charger/` (oplus_chg v2), ADSP glink messages |
| amps | audio overlay dtsi :87-125, `vendor/.../audio-kernel` + tfa98xx driver |
| regulators per rail | `pineapple-regulators.dtsi` + waffle overrides (`waffle_overlay_common.dtsi:21-24` raises L13B to 3.2 V for the panel) |

## Halium-style fallback (downstream kernel + our userspace)
Possible in principle (GKI 6.1, all sources public, LineageOS proves it
builds), and it would give working modem/audio/camera via Android vendor
blobs, as UBports does on the N100. **Not recommended** for this project:
our images are built around Fedora's mainline kernel and bootc; a 6.1
Android kernel can't run Fedora's userspace expectations well (no
upstream DRM/KMS for the panel path without the techpack, SELinux/Android
init assumptions) and the N100 experience (Ubuntu Touch resets, Wi‑Fi,
audio ABI mismatch) shows the maintenance cost. Keep it as a reference
and as an emergency "does the hardware work" check (boot LineageOS).
