# Kernel: Qualcomm SM6115 family (SM6115, SM4250, QRB4210)

Devices: `oneplus-billie2`.

## Plan
1. **Try Fedora's kernel first.** Fedora's aarch64 kernel enables `ARCH_QCOM`
   and builds all upstream DTBs, including `qcom/sm4250-oneplus-billie2.dtb`.
   To check: whether these are enabled (`=y` or `=m`) in Fedora's config:
   - `CONFIG_SM_GCC_6115`, `CONFIG_PINCTRL_SM6115`, `CONFIG_INTERCONNECT_QCOM_SM6115`
   - `CONFIG_SCSI_UFS_QCOM`, `CONFIG_PHY_QCOM_QMP_UFS`, `CONFIG_USB_DWC3_QCOM`
   - `CONFIG_QCOM_RPMPD`, `CONFIG_REGULATOR_QCOM_SMD_RPM`
   - `CONFIG_PSTORE_RAM` (ramoops: crash logs)
   - `CONFIG_USB_CONFIGFS_NCM` (debug networking, see base/)
   Check: `podman run --rm quay.io/fedora/fedora-silverblue:45 sh -c 'grep -E "SM6115|SM_GCC_6115|UFS_QCOM|PSTORE_RAM|CONFIGFS_NCM" /usr/lib/modules/*/config'`
2. **If something's missing,** build our own kernel RPM in COPR: Fedora's spec
   and config plus a config fragment, or mainline plus device patches. Name it
   `kernel-qcom-sm6115` and point `KERNEL_PACKAGE` at it.
3. Device-specific drivers (panel, touch) get upstreamed where possible;
   until then they live here as patches with a note on their upstream status.

## References
- Mainline DT: `arch/arm64/boot/dts/qcom/sm4250-oneplus-billie2.dts`
- postmarketOS has SM6115-family devices and kernels worth reading.
