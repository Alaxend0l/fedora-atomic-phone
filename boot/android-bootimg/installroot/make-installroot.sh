#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# The N100's installed development root (ext4, label fap-root, booted by
# tiny-init's fap.root=): the OnePlus Nord N100 Plasma Mobile dev root with
# the opt-in Waydroid layer, built by make-devroot.sh --installroot.
#   boot/android-bootimg/installroot/make-installroot.sh <outdir>
# Same environment as make-devroot.sh (NETROOT_EXTRA_MODULES/FIRMWARE for
# the N100's panel/touch modules and touch firmware, FAP_PINNED=1 → lock/installroot).
# Writes <outdir>/installroot.tar.zst. Install it from a RAM boot, see the README.
set -euo pipefail
out=${1:?usage: $0 <outdir>}
here=$(cd "$(dirname "$0")" && pwd)
DEVROOT_LOCK=installroot exec "$here/../make-devroot.sh" --installroot \
    oneplus-billie2 plasma-mobile "$out" waydroid
