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
`build.sh` builds U-Boot and wraps it with `mkbootimg`.
`build-in-container.sh` runs it in a Fedora 44 container (needs only podman):

```sh
git clone --depth 1 https://github.com/u-boot/u-boot.git ~/Develop/fap-build/u-boot
boot/u-boot/build-in-container.sh ~/Develop/fap-build/u-boot \
    qcom/sm4250-oneplus-billie2 ~/Develop/fap-build/out
```

Pocketblue builds its U-Boot images the same general way
(`pocketblue/u-boot-builder`).

### Build log
| Date | U-Boot | Result |
|---|---|---|
| 2026-11-20 | master `c1958b5f` | `uboot.img` 630,784 bytes; header v2, kernel (gzipped U-Boot) 563,547 bytes at 0x8000, DTB 60,128 bytes at 0x01f00000. Not yet tried on the phone. |

Gotcha: Fedora 45's OpenSSL 4.0 dropped the ENGINE API that U-Boot's host
tools need, and `TOOLS_LIBCRYPTO` can't be turned off because other options
select it. Hence Fedora 44 + `openssl-devel-engine`.

## Testing without flashing
`fastboot boot output/uboot.img` boots the image once from RAM without writing
anything, if ABL allows it on this phone. That's the first experiment.
