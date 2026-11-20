#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Build a dtbo partition image holding one no-op overlay, for phones whose
# bootloader insists on a valid dtbo but whose stock overlays break mainline
# device trees. Runs in a Fedora container (needs only podman).
#
#   boot/noop-dtbo.sh devices/<id>/dtbo/noop-overlay.dts <base.dtb> <outdir>
#
# <base.dtb> is the mainline DT the phone will boot; the script checks that the
# overlay applies to it cleanly and leaves it byte-identical.
# Writes <outdir>/dtbo-noop.img and prints its table and sha256.
set -euo pipefail

usage="usage: $0 <overlay.dts> <base.dtb> <outdir>"
dts=$(realpath "${1:?$usage}")
base=$(realpath "${2:?$usage}")
out=${3:?$usage}
mkdir -p "$out"
out=$(realpath "$out")

podman run --rm -v "$dts:/in/overlay.dts:ro" -v "$base:/in/base.dtb:ro" -v "$out:/out" \
    registry.fedoraproject.org/fedora:44 bash -euc '
        dnf -y -q install dtc android-tools diffutils >/dev/null 2>&1
        dtc -q -@ -I dts -O dtb -o /tmp/overlay.dtbo /in/overlay.dts

        # The overlay must have no fragments, and applying it must not change
        # the base DT at all.
        if dtc -q -I dtb -O dts /tmp/overlay.dtbo | grep -q fragment@; then
            echo "overlay has fragments; refusing" >&2; exit 1
        fi
        fdtoverlay -i /in/base.dtb -o /tmp/applied.dtb /tmp/overlay.dtbo
        dtc -q -I dtb -O dts /in/base.dtb > /tmp/base.dts
        dtc -q -I dtb -O dts /tmp/applied.dtb > /tmp/applied.dts
        if ! diff -u /tmp/base.dts /tmp/applied.dts; then
            echo "applying the overlay changed the base DT; refusing" >&2; exit 1
        fi
        echo "applies cleanly: no change to the base DT"

        # Page size 4096 like the stock table on the N100.
        mkdtboimg create /out/dtbo-noop.img --page_size=4096 /tmp/overlay.dtbo
        mkdtboimg dump /out/dtbo-noop.img
        sha256sum /out/dtbo-noop.img
    '
