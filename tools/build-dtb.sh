#!/usr/bin/env bash
# Build a device tree from one of our board .dts files against a Linux source
# tree (only arch/arm64/boot/dts and include/ are needed, e.g. a sparse clone).
# Runs dtc in a Fedora container, so the host only needs podman.
#
#   tools/build-dtb.sh <linux-src> <board.dts> <out.dtb>
#   e.g. tools/build-dtb.sh ~/Develop/fap-build/linux \
#          devices/oneplus-billie2/dts/sm4250-oneplus-billie2-fap.dts out/billie2.dtb
#
# Use the Linux tag matching the kernel you boot (v7.3 for Fedora 45's 7.3.x).
set -euo pipefail

usage="usage: $0 <linux-src> <board.dts> <out.dtb>"
src=$(realpath "${1:?$usage}")
dts=$(realpath "${2:?$usage}")
out=${3:?$usage}
mkdir -p "$(dirname "$out")"
out="$(realpath "$(dirname "$out")")/$(basename "$out")"   # macOS realpath has no -m

podman run --rm -v "$src:/linux:ro" -v "$(dirname "$dts"):/board:ro" \
    -v "$(dirname "$out"):/out" registry.fedoraproject.org/fedora:45 bash -euo pipefail -c '
        dnf5 -y -q install dtc cpp >/dev/null 2>&1
        Q=/linux/arch/arm64/boot/dts/qcom
        cpp -nostdinc -undef -x assembler-with-cpp -D__DTS__ \
            -I /linux/include -I /linux/arch/arm64/boot/dts -I $Q \
            -I /linux/scripts/dtc/include-prefixes \
            "/board/$1" | grep -v "^#" > /tmp/board.dts
        dtc -q -I dts -O dtb -o "/out/$2" /tmp/board.dts
        echo "built /out/$2 ($(stat -c%s "/out/$2") bytes)"
    ' _ "$(basename "$dts")" "$(basename "$out")"
