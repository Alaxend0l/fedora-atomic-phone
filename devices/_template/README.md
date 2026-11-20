<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# @DEVICE_NAME@ (`@DEVICE_ID@`)

Status: **research** (@DATE@). One paragraph: what boots, how (RAM boot or
installed), what works. Keep it in step with `device.env` (`DEVICE_STATUS`)
and [features.yaml](features.yaml), which is the source of truth for
features ([docs/devices.md](../../docs/devices.md) is generated from it).

Hardware facts below come from: (stock/Halium inventory, live DT, vendor
kernel source; say where and when).

## Hardware
| Part | Chip | Mainline status | Works here? |
|---|---|---|---|
| SoC | | | |
| RAM | | | |
| Storage | | | |
| Display | | | |
| Touch | | | |
| USB | | | |
| Wi‑Fi/BT | | | |
| Audio | | | |
| Charging | | | |
| Modem | | | |
| Other | | | |

## Boot chain
Bootloader → which partitions it reads (`BOOT_IMAGES`) → our kernel. Header
version, DTB selection (msm-id/board-id, `/soc_compatible`, dtbo), AVB
footers, whether `fastboot boot` works and from which fastboot (bootloader,
not fastbootd). See boot/README.md and docs/porting-cookbook.md.

## Partitions
| Partition | Size | Plan |
|---|---|---|
| `boot_a`, `boot_b` | | kernel or U-Boot image |
| `dtbo_a`, `dtbo_b` | | (erase / stock / our overlay: `DTBO_MODE`) |
| `userdata` | | root filesystem |
| ESP | | where, and why |

## Firmware
Which blobs, where they live on the phone, how we get them without
redistributing: [firmware.yaml](firmware.yaml).

## Recovery
- Way back to stock (EDL + vendor tool, factory images, Pixel ROM recovery),
  tested on: (date).
- Identity partitions backed up (`BACKUP_PARTITIONS`): (where, sha256).
- **Never write**: (device-specific list; `PROTECTED_PARTITIONS`).
- Anti-rollback and slot rules, if any.

## Notes
- Unit specifics (model number, carrier, firmware version).
- Open questions; see [TODO.md](TODO.md) and
  [hidden-dependencies.md](hidden-dependencies.md).
