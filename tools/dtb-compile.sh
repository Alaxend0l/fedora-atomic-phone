#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Compile one of our board .dts files against a Linux source tree with cpp +
# dtc, on this machine. Needs cpp and dtc; tools/build-dtb.sh runs this in a
# Fedora container for hosts without them (macOS), CI runs it directly.
#
#   tools/dtb-compile.sh <linux-src> <board.dts> <out.dtb>
#
# Only arch/arm64/boot/dts, include/ and scripts/dtc/include-prefixes of the
# Linux tree are needed (a sparse checkout is enough).
set -euo pipefail

usage="usage: $0 <linux-src> <board.dts> <out.dtb>"
src=${1:?$usage}
dts=${2:?$usage}
out=${3:?$usage}
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Qualcomm board files include mainline files by bare name
# ("sm4250-oneplus-billie2.dts"), hence qcom/ on the include path; other
# vendors include them relative to arch/arm64/boot/dts ("exynos/google/...").
inc=(-I "$src/include" -I "$src/arch/arm64/boot/dts" -I "$src/scripts/dtc/include-prefixes"
     -I "$(dirname "$dts")" -I "$src/arch/arm64/boot/dts/qcom")

cpp -nostdinc -undef -x assembler-with-cpp -D__DTS__ "${inc[@]}" "$dts" | grep -v '^#' > "$tmp"
mkdir -p "$(dirname "$out")"
dtc -q -I dts -O dtb -o "$out" "$tmp"
echo "built $out ($(wc -c < "$out" | tr -d ' ') bytes)"
