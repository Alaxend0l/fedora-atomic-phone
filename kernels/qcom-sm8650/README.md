<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Kernel: Qualcomm SM8650 (Snapdragon 8 Gen 3)

Devices: `oneplus-waffle` (OnePlus 12). Nothing here has booted yet.

## Why not Fedora's kernel (checked 2026-11-20)
Fedora 45's `kernel-7.3.4-300.fc45` has the SM8650 clock drivers as modules
but **`PINCTRL_SM8650` and `INTERCONNECT_QCOM_SM8650` unset**. Without TLMM
pins and the interconnect provider nothing on the SoC probes (UFS, USB,
display all wait), so it can't boot an SM8650 phone. Also:
- `SM_DISPCC_8650=m` in Fedora's config is a **stale symbol**: the SM8650
  display clock controller is driven by `dispcc-sm8550.c`
  (`SM_DISPCC_8550`), which Fedora leaves unset. Same for video
  (`SM_VIDEOCC_8550`).
- `PHY_QCOM_SNPS_EUSB2` (Fedora config) was renamed `PHY_SNPS_EUSB2` (Fedora
  has that one too, =m).
- `PINCTRL_SM8650_LPASS_LPI`, `TYPEC_MUX_WCD939X_USBSS` unset (audio, USB-C).

Worth a Fedora config request (`PINCTRL_SM8650`, `INTERCONNECT_QCOM_SM8650`,
`SM_DISPCC_8550`, `SM_VIDEOCC_8550`, `PINCTRL_SM8650_LPASS_LPI`,
`TYPEC_MUX_WCD939X_USBSS`; precedent: SM6115 is enabled). Not filed yet.

## What we build: a base config + [fap.config](fap.config)
`fap.config` is a fragment applied on top of a base config. It turns on the missing SoC pieces, builds in
what the debug initramfs needs to reach UFS and USB device mode without
loading modules (pins, interconnect, GCC/TCSR clocks, UFS + QMP UFS PHY,
DWC3 + SNPS eUSB2 PHY + PM8550B repeater, USB gadget configfs ACM/NCM,
simpledrm, ramoops) and leaves everything else as Fedora has it or as a
module. Every symbol was checked to exist in both trees below; the build
script fails if any line doesn't survive `olddefconfig`.

Two base configs (`fap-waffle-build.sh [--full]`):
- **slim** (default, first light): arm64 `defconfig` with every SoC platform
  but `ARCH_QCOM` off, + the fragments. Builds in minutes.
- **full** (`--full`): Fedora's whole `kernel-aarch64-fedora.config` (from
  the kernel src.rpm) + the fragments: what a packaged kernel would use.
  Several hours in a 6-CPU/2 GiB podman VM (first attempt aborted there,
  2026-11-20); not built yet.

Two source trees
(`devices/oneplus-waffle/build-env/fap-waffle-build.sh`, `KERNEL_TREE=`):

| Tier | Tree | Use | State |
|---|---|---|---|
| first light | DaDDevil/linux `waffle-voice` @ `9359fc74` (v7.4-rc3 + OnePlus 12 board DT, BOE AA545 panel, Synaptics S3910 touch, haptics, battmgr/ath12k fixes) | RAM boots now (slim config); adds `build-env/waffle.config` for its drivers | slim: built 2026-11-20; full: config-check passes |
| tier 2 (long term) | Fedora's `kernel-7.3.4-300.fc45.src.rpm`: `linux-7.3.4.tar.xz` + `patch-7.3-redhat.patch` | the kernel we'd package (`kernel-qcom-sm8650`, full config) once the board DT and drivers are upstream or carried as patches | `config-check --full` passes; not built; no OnePlus 12 DT in it |

`build-env/build.config` holds build-only changes (no debug info/BTF, no
Rust, unsigned uncompressed modules, `-fap-waffle` local version). With
other SoC platforms off they keep the build quick and the Image small
enough for uniLoader's memory layout (kernel at 0xa3200000, uniLoader at
0xa8010000: under 78 MiB including BSS); a packaged kernel would drop them.

## Reproduce
```sh
devices/oneplus-waffle/build-env/fap-waffle-build.sh kernel                 # waffle-voice, slim
devices/oneplus-waffle/build-env/fap-waffle-build.sh kernel --full          # Fedora's whole config
KERNEL_TREE=fedora devices/oneplus-waffle/build-env/fap-waffle-build.sh config-check --full
```
