<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Opt-in layers

Quality-of-life extras that are never in the default image
(docs/decisions/0003, layer 4). Same shape as every layer (`packages`,
`rootfs/`, `build`; tools/image/run-layer), applied after the desktop and
before the device:

- bootc image: `just LAYERS="waydroid" build`
- dev root: `boot/android-bootimg/make-devroot.sh <device> <desktop> <outdir> waydroid`

| Layer | What |
|---|---|
| `waydroid/` | Waydroid (docs/waydroid.md), `fap-waydroid-init`, the binderfs ordering fix |

Device-specific settings for a layer live in the device folder, e.g.
`devices/oneplus-billie2/rootfs/usr/lib/fap/waydroid.conf`.
