<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# fedora-atomic-phone

Fedora Atomic (bootc) images for phones, built so that adding a new phone means
adding one folder under `devices/`.

Status: **scaffold**. Nothing boots yet. First target: OnePlus Nord N100
(`oneplus-billie2`, Snapdragon 460 / SM4250).

## How it fits together

```
 Fedora Atomic base image (e.g. quay.io/fedora/fedora-silverblue:45)
   └─ base/       things every phone gets (USB networking, zram, tweaks)
      └─ desktops/<ui>/      phone UI: phosh, plasma-mobile, tty
         └─ devices/<id>/    kernel, firmware, boot quirks for one phone
              = one bootable OCI image per (device, desktop)
                  └─ image-builder → disk images → flashed with fastboot
```

Each layer is a folder with a `build` script that runs inside the container
build. Details: [docs/architecture.md](docs/architecture.md).

## Layout

| Path | What's there |
|---|---|
| `Containerfile` | Stacks base → desktop → device into one image |
| `Justfile` | Entry points: `just build`, `just disk`, `just flash` |
| `base/` | Shared image changes |
| `desktops/` | One folder per UI |
| `devices/` | One folder per phone. Start from `devices/_template/` |
| `kernels/` | Kernel packaging notes/specs per SoC family |
| `boot/` | U-Boot (chainloaded from the Android bootloader) |
| `tools/` | Build and flash helpers |
| `docs/` | Architecture, porting guide, decisions, dev setup |

## Quick start (once there's something to build)

```sh
just DEVICE=oneplus-billie2 DESKTOP=phosh build
just DEVICE=oneplus-billie2 DESKTOP=phosh disk
```

See [docs/dev-environment.md](docs/dev-environment.md) for setting up a build
machine (an aarch64 Fedora VM on Apple Silicon works natively).

## Related work

- [Pocketblue](https://github.com/pocketblue/pocketblue): Fedora Atomic for
  mobile devices. We use it as a reference, not as a code base; see
  [docs/decisions/0001-own-framework.md](docs/decisions/0001-own-framework.md).
- [postmarketOS](https://postmarketos.org): the model for per-device packaging.
- Device research for the N100 lives in a separate repo (UBports-N100 notes).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md), including the policy on AI-assisted work.
