#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Build a device tree from one of our board .dts files against a Linux source
# tree (only arch/arm64/boot/dts and include/ are needed, e.g. a sparse clone).
# Runs tools/dtb-compile.sh in a Fedora container, so the host only needs
# podman (CI runs dtb-compile.sh directly).
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
tools=$(cd "$(dirname "$0")" && pwd)

podman run --rm -v "$src:/linux:ro" -v "$(dirname "$dts"):/board:ro" \
    -v "$(dirname "$out"):/out" -v "$tools:/tools:ro" registry.fedoraproject.org/fedora:45 bash -euo pipefail -c '
        dnf5 -y -q install dtc cpp >/dev/null 2>&1
        /tools/dtb-compile.sh /linux "/board/$1" "/out/$2"
    ' _ "$(basename "$dts")" "$(basename "$out")"
