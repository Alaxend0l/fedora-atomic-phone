<!-- SPDX-License-Identifier: (GPL-2.0+ OR BSD-3-Clause) -->
# Device tree additions for OnePlus 12

| File | What |
|---|---|
| `sm8650-oneplus-waffle-fap.dtsi` | first-light trim: simple-framebuffer on the splash buffer, USB peripheral (high speed), DSPs/MDSS/GPU/PCIe/audio/cameras/peripheral buses off |
| `sm8650-oneplus-waffle-fap.dts` | plain variant: memory below 4 GiB only, debug shell |
| `sm8650-oneplus-waffle-fap-netroot.dts` | netroot variant: full 16 GB map, `fap.netroot=` in bootargs |

They `#include "sm8650-oneplus-waffle.dts"`, the board DT from
DaDDevil/linux `waffle-voice` (pinned in `../build-env/fap-waffle-build.sh`),
which `fap-waffle-build.sh dtb` builds them against. **That file has no
licence line: don't copy it (or the DTBs built from it) into this repo or
anything we publish**; ask the author to license it first. Our files only
add and override nodes.

Build: `devices/oneplus-waffle/build-env/fap-waffle-build.sh dtb` (outputs
in the build volume, copied to `~/Develop/fap-build/waffle/parts/` by
`images`). `tools/build-dtb.sh` and CI can't build these yet (they need the
waffle-voice tree, not a Fedora/mainline tag).

Rules (as for every device): regulator/boost/amp/charger values only from
the vendor DT, named in a comment; one comment per block; say what's
verified. Nothing here is verified on hardware yet.
