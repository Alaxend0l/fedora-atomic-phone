# Boot method: `uboot-android`

Phones can't boot EFI directly: their Android bootloader (ABL) only loads an
Android boot image from the `boot` partition. We put U-Boot there, wrapped as
an Android boot image. U-Boot initializes enough hardware (UFS, USB, display
framebuffer) to act as an EFI firmware, then runs GRUB from the ESP like on a PC.

```
ABL ──loads──> boot_a: [ U-Boot | device tree ]  (Android boot image)
                  └─ EFI ──> ESP: GRUB ──> Fedora kernel + initramfs + DTB
```

Pros: bootc/Fedora updates work unchanged (new kernels land in /boot, GRUB
picks them); one U-Boot image per device, rarely updated.
Cons: needs U-Boot support for the SoC (clocks, pinctrl, storage) and the
board's device tree. Compare the other methods in [../README.md](../README.md).

## device.env keys
| Key | Example | Meaning |
|---|---|---|
| `UBOOT_DEFCONFIG` | `qcom_defconfig` | optional, default `qcom_defconfig` |
| `UBOOT_DTB` | `qcom/sm4250-oneplus-billie2` | path under U-Boot's `dts/upstream/src/arm64/`, no `.dtb` |
| `BOOTIMG_*` | see `boot/bootimg-args.sh` | Android boot image layout the stock bootloader expects |
| `FLASH_ESP_PARTITION` | | required: where the ESP goes |

## Upstream support for the N100
- `configs/qcom_defconfig`: generic Qualcomm target.
- `drivers/clk/qcom/clock-sm6115.c`, `drivers/pinctrl/qcom/pinctrl-sm6115.c`:
  SoC drivers present.
- `dts/upstream/src/arm64/qcom/sm4250-oneplus-billie2.dts`: our board.

## Building
`build.sh` builds U-Boot and wraps it with `mkbootimg` using the device's
`BOOTIMG_*` layout. `build-in-container.sh` runs it in a Fedora 44 container
(needs only podman):

```sh
git clone --depth 1 https://github.com/u-boot/u-boot.git ~/Develop/fap-build/u-boot
boot/uboot-android/build-in-container.sh ~/Develop/fap-build/u-boot \
    devices/oneplus-billie2 ~/Develop/fap-build/out
```

Pocketblue builds its U-Boot images the same general way
(`pocketblue/u-boot-builder`).

### Build log
| Date | U-Boot | Result |
|---|---|---|
| 2026-11-20 | master `c1958b5f` | `uboot.img` 630,784 bytes; header v2, kernel (gzipped U-Boot) 563,547 bytes at 0x8000, DTB 60,128 bytes at 0x01f00000. Not yet tried on the phone. |

Builds aren't byte-reproducible (U-Boot embeds the build time).

Gotcha: Fedora 45's OpenSSL 4.0 dropped the ENGINE API that U-Boot's host
tools need, and `TOOLS_LIBCRYPTO` can't be turned off because other options
select it. Hence Fedora 44 + `openssl-devel-engine`.

## Testing without flashing
`fastboot boot out/uboot.img` boots the image once from RAM without writing
anything.

Must be the **bootloader's** fastboot (`fastboot getvar is-userspace` → `no`).
Android's userspace fastbootd answers `Unrecognized command boot`. From
fastbootd: `fastboot reboot bootloader`. On Ubuntu Touch, `adb reboot
bootloader` is refused for the normal user; use
`sudo systemctl reboot --reboot-argument=bootloader`.

### N100 results (2026-11-20)
| Image | Result |
|---|---|
| our `uboot.img` (above) | ABL: `Booting OKAY`, screen stays on the OnePlus logo, ABL fastboot still answers afterwards → ABL most likely never jumped to U-Boot |
| stock/UBports `boot_a` (backup) | boots Ubuntu Touch from RAM in ~30 s → `fastboot boot` works on this phone |

So something in our image makes ABL refuse it. Candidates, cheapest test first:
1. `os_version`/`os_patch_level` unset in our header (stock: 10.0.0 / 2020-10).
2. ABL applies the `dtbo` partition's overlays (written for the vendor DT) to
   our mainline DT and aborts on failure. Pocketblue erases `dtbo` before
   flashing U-Boot; testing this needs `dtbo` erased (a write; backup exists).
3. DT selection: the stock image carries a 4.8 MB DTB table; ours one 60 KB DT
   without `qcom,pmic-id`.
