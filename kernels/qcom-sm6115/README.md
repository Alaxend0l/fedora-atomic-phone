# Kernel: Qualcomm SM6115 family (SM6115, SM4250, QRB4210)

Devices: `oneplus-billie2`.

## Decision so far: use Fedora's kernel
Checked 2026-11-20 against `quay.io/fedora/fedora-silverblue:45`, kernel
**7.3.4-300.fc45.aarch64**. It has what a first boot needs, so no custom kernel
for now.

**Device trees shipped** (`/usr/lib/modules/<kver>/dtb/qcom/`):
`sm4250-oneplus-billie2.dtb`, `sm6115-fxtec-pro1x.dtb`,
`sm6115p-lenovo-j606f.dtb`, `qrb4210-rb2.dtb`.

**Boot path** (needed to mount root on UFS), all `=m` and all present in the
generic initramfs (`hostonly=no`): `gcc-sm6115`, `pinctrl-sm6115`,
`qnoc-sm6115`, `icc-smd-rpm`, `smd-rpm`, `clk-smd-rpm`, `qcom_smd-regulator`,
`qcom_spmi-regulator`, `ufs-qcom`, `phy-qcom-qmp-ufs`. Built in (`=y`):
`ARCH_QCOM`, `SPMI_MSM_PMIC_ARB`, `MFD_SPMI_PMIC`, `PINCTRL_QCOM_SPMI_PMIC`,
`QCOM_GENI_SE`, `I2C_QCOM_GENI`, `SERIAL_QCOM_GENI`, `DRM_SIMPLEDRM`,
`SYSFB_SIMPLEFB`, `PSTORE`.

**Not in the initramfs:** `rpmpd` (module only). UFS doesn't need it (its power
domain is `GCC_UFS_PHY_GDSC`), but sdhc_1/sdhc_2, GPU, display, venus, the
remoteprocs and geniqup do. The N100 device layer adds it via dracut anyway.

**Debug and later hardware** (`=m` unless noted):
| Area | Options | Note |
|---|---|---|
| USB networking | `USB_CONFIGFS_NCM=y`, `USB_F_NCM`, `USB_LIBCOMPOSITE` | loaded after root is mounted; fine for `fap-usb-gadget` |
| Crash logs | `PSTORE=y`, `PSTORE_RAM` (in initramfs) | billie2 DT reserves ramoops at 0xcbe00000 |
| USB | `USB_DWC3_QCOM`, `PHY_QCOM_USB_HS`, `PHY_QCOM_QMP_USB` | |
| SD card | `MMC_SDHCI_MSM` | needs rpmpd |
| Display/GPU | `DRM_MSM`, `DRM_MSM_DSI=y`, `SM_DISPCC_6115`, `SM_GPUCC_6115` | panel is ILI9882N; Fedora has `DRM_PANEL_ILITEK_ILI9882T` (different variant, to check) |
| Touch | `TOUCHSCREEN_ILITEK` | that driver is I2C; the N100's touch is on SPI, so probably not usable as-is |
| Wi‑Fi | `ATH10K_SNOC`, `QCOM_WCNSS_PIL` | to check which applies to this SoC |
| Remoteprocs | `QCOM_Q6V5_PAS`, `QCOM_SYSMON`, `QRTR`, `QRTR_SMD`, `QCOM_RMTFS_MEM` | |
| Audio | `SND_SOC_QCOM`, `SND_SOC_WCD937X`, `SOUNDWIRE_QCOM` | `SND_SOC_SM8250` is off; which machine driver SM6115 uses is to check |
| Charging | `CHARGER_QCOM_SMB2`, `QCOM_SPMI_ADC5` | PMI632 support to check |
| Power key | `INPUT_PM8941_PWRKEY` | |

Reproduce:
```sh
podman run --rm quay.io/fedora/fedora-silverblue:45 sh -c \
  'grep -E "SM6115|UFS_QCOM|PSTORE_RAM|CONFIGFS_NCM" /usr/lib/modules/*/config'
podman run --rm quay.io/fedora/fedora-silverblue:45 sh -c \
  'lsinitrd /usr/lib/modules/*/initramfs.img | grep -E "sm6115|ufs-qcom|rpmpd"'
```

## If Fedora's kernel stops being enough
Build our own kernel RPM in COPR (Fedora's spec and config plus a fragment, or
mainline plus device patches), name it `kernel-qcom-sm6115`, and point the
device's `KERNEL_PACKAGE` at it. Device-specific drivers (panel, touch) should
be upstreamed where possible; until then they live here as patches with their
upstream status noted.
