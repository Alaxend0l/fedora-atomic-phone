<!-- SPDX-License-Identifier: (GPL-2.0+ OR BSD-3-Clause) -->
# Device tree additions for OnePlus 12

| File | What |
|---|---|
| `sm8650-oneplus-waffle-fap.dtsi` | first-light trim: simple-framebuffer on the splash buffer until msm (MDSS + DSI0 + panel) takes over, USB peripheral (high speed); v5/v6: DSPs, pmic-glink, PCIe Wi-Fi, touch, WCD9395 audio on; DP/GPU/speaker amps/cameras/other peripheral buses off |
| `sm8650-oneplus-waffle-fap.dts` | plain variant: full memory map, debug shell |
| `sm8650-oneplus-waffle-fap-netroot.dts` | netroot variant: full 16 GB map, `fap.netroot=` in bootargs; v8: + `-fap-hw.dtsi` |
| `sm8650-oneplus-waffle-fap-hw.dtsi` | v8 (branch oneplus12-hw): TFA9874 speaker link on SECONDARY_MI2S + i2c_hub_7, WCD9395 ↔ USB-C audio switch link + i2c3, CAMSS/CCI/i2c9 (EEPROM read-only) |
| `sm8650-oneplus-waffle-fap-netroot-safe.dts` | v8 fallback: netroot without `-fap-hw.dtsi` (= v7 hardware set) |

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
