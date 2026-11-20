# Licensing

Unless a file says otherwise, everything in this repository (scripts, tools,
Containerfiles, configuration, documentation) is licensed under the
**GNU Affero General Public License v3.0 or later** (`AGPL-3.0-or-later`),
full text in [LICENSE](LICENSE).

Copyright © 2026 the fedora-atomic-phone contributors.

## Exceptions (per-file `SPDX-License-Identifier` wins)

| Files | License | Why |
|---|---|---|
| Linux kernel modules: `kmod/**`, `devices/*/kmod/**` | `GPL-2.0-only` | Derived from GPL-2.0 kernel and vendor kernel code; kernel modules must be GPL-2.0-compatible, which AGPL-3.0 is not. |
| Device trees: `devices/*/dts/**` | `(GPL-2.0+ OR BSD-3-Clause)` (or whatever the file states) | Mainline Linux convention for DTs; keeps them upstreamable and compatible with the mainline `.dtsi` files they include. |
| Files taken from other projects | their original license, stated in the file | e.g. device trees or patches from other Linux-on-phones projects. |

New files: add an `SPDX-License-Identifier` line. Use `AGPL-3.0-or-later`
for project code, `GPL-2.0-only` for kernel code, and
`(GPL-2.0+ OR BSD-3-Clause)` for device trees.

## Not covered
- Built images contain Fedora and other packages under their own licenses
  (mere aggregation).
- Firmware and other files extracted from a user's own phone (touch
  firmware, GPU zap shader, modem/Wi-Fi firmware, ...) are the vendors'
  property: never commit or redistribute them; the tools extract them on
  the user's device.
