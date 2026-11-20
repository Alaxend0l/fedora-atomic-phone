# U-Boot

Phones can't boot EFI directly: their Android bootloader (ABL) only loads an
Android boot image from the `boot` partition. We put U-Boot there, wrapped as
an Android boot image. U-Boot initializes enough hardware (UFS, USB, display
framebuffer) to act as an EFI firmware, then runs GRUB from the ESP like on a PC.

```
ABL ──loads──> boot_a: [ U-Boot | device tree ]  (Android boot image v2)
                  └─ EFI ──> ESP: GRUB ──> Fedora kernel + initramfs + DTB
```

Why this instead of putting the Linux kernel in `boot` directly:
- bootc/Fedora updates work unchanged (new kernels land in /boot, GRUB picks
  them). No custom "flash the kernel into boot_a on every update" hook.
- One U-Boot image per device, rarely updated.

## Upstream support for the N100
- `configs/qcom_defconfig`: generic Qualcomm target.
- `drivers/clk/qcom/clock-sm6115.c`, `drivers/pinctrl/qcom/pinctrl-sm6115.c`:
  SoC drivers present.
- `dts/upstream/src/arm64/qcom/sm4250-oneplus-billie2.dts`: our board.

(Checked against U-Boot master on 2026-11-20; not built yet.)

## Building
`build.sh` builds U-Boot and wraps it with `mkbootimg`. Pocketblue builds its
U-Boot images the same general way (`pocketblue/u-boot-builder`).

## Testing without flashing
`fastboot boot output/uboot.img` boots the image once from RAM without writing
anything, if ABL allows it on this phone. That's the first experiment.
