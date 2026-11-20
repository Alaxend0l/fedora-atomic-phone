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

Follow-up tests the same day:

| Test | Result |
|---|---|
| set `os_version` 10.0.0 / `os_patch_level` 2020-10 (as stock) | no change: accepted, never started |
| `fastboot erase dtbo_a`, then boot | ABL: `Failed to load/authenticate boot image: Load Error` (dtbo_a restored from backup afterwards, hash verified) |

**Diagnosis.** ABL picks a `dtbo` overlay by the phone's *hardware* board id
(CDT), `0x1000b` (QRD): entries 5 "Bengal QRD" and 23 "Bengal OEM QRD" in this
phone's 33-entry dtbo table. It applies it to whatever DT the boot image holds;
the overlay references vendor-only labels, so on the mainline DT it fails and
ABL doesn't start the image. Changing our DT's ids can't avoid it (selection
uses the hardware id). And unlike e.g. the OnePlus 6, this ABL refuses to boot
with `dtbo` erased.

**Fix to try next:** a minimal valid dtbo (`mkdtboimg`): one empty overlay for
board-id `0x1000b` and msm-id `0x1a1`/`0x1bc`, so ABL loads it and applies a
no-op. Applies to `android-bootimg` as well. Flashing it means Ubuntu Touch
won't boot until the stock dtbo is restored.

### No-op dtbo (built 2026-11-20, not flashed yet)
`boot/noop-dtbo.sh devices/oneplus-billie2/dtbo/noop-overlay.dts <billie2.dtb> <out>`
builds a one-entry DT table (page size 4096, like stock). The overlay copies
the selection properties of stock entry 23 (`qcom,board-id <0x1000b 0>`,
`oem,project-id <0x0c>` = this phone's `prj_version` 12, `oem,hw-id`) and has
no fragments. The script refuses unless `fdtoverlay` leaves the mainline
billie2 DT byte-identical.

Result: `dtbo-noop.img`, 4096 bytes, sha256 `0bee5680…c22e72dd`.
Flashing it to `dtbo_a` means Ubuntu Touch won't boot until the stock dtbo
backup is restored.

**Tested 2026-11-20:** flashed `dtbo-noop.img` to `dtbo_a`, `fastboot boot`
the U-Boot image (with os_version fields): ABL `Booting OKAY`, but ABL's
fastboot (product `bengal`) keeps answering for 30 s+ → still no handoff (or an
immediate return we can't see). Stock dtbo restored, hash verified,
Ubuntu Touch boots. So the stock overlay wasn't the only blocker.

### Open leads (next experiments)
1. **`qcom-phone.config`.** U-Boot's `doc/board/qualcomm/board.rst` builds
   phones with `make qcom_defconfig qcom-phone.config`; we built
   `qcom_defconfig` only. Probably needed for display/buttons; may or may not
   affect the handoff. Cheap: rebuild, RAM-boot (with stock or no-op dtbo).
2. **Tell "ABL refused" from "U-Boot died instantly".** ABL's fastboot staying
   up suggests the former, but a crash + reset back into fastboot would look
   similar. A build that shows something on the framebuffer (lead 1) answers it.
3. **Header v0 with appended DTB** (`u-boot-nodtb.bin.gz` + DTB concatenated,
   as in U-Boot's docs for older boards) instead of v2's separate DTB section.
4. **Kernel image header:** some ABLs check the arm64 Image header of the
   decompressed kernel; check `u-boot-nodtb.bin` has one
   (`LINUX_KERNEL_IMAGE_HEADER`).
5. **postmarketOS's billie2 port** boots mainline via ABL and would show what
   works; its pmaports URLs currently redirect to `gitlab.nura.eco` (404), so
   that config wasn't readable on 2026-11-20.
