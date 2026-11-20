#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Build every devices/*/dts/*.dts with tools/dtb-compile.sh. Devices with
# KERNEL_SOURCE=fedora build against <fedora-linux-src> (the Linux tag of the
# newest Fedora kernel); others against their own tree (KERNEL_SOURCE=
# git:<url>#<ref>, sparse-cloned). Needs cpp, dtc, git.
#   tools/ci/dtbs.sh <fedora-linux-src> <outdir>
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
fedora_src=${1:?usage: $0 <fedora-linux-src> <outdir>}
out=${2:?usage: $0 <fedora-linux-src> <outdir>}
fail=0
for dts in "$root"/devices/*/dts/*.dts; do
    [ -e "$dts" ] || continue
    dev=$(basename "$(dirname "$(dirname "$dts")")")
    case "$dev" in _*) continue ;; esac
    ks=$(sed -n 's/^KERNEL_SOURCE="\(.*\)".*/\1/p' "$root/devices/$dev/device.env")
    src=$fedora_src
    if [ -n "$ks" ] && [ "$ks" != fedora ]; then
        spec=${ks#git:}
        src=$out/src-$dev
        [ -d "$src" ] || "$root/tools/ci/sparse-linux.sh" "${spec%#*}" "${spec##*#}" "$src"
    fi
    if ! "$root/tools/dtb-compile.sh" "$src" "$dts" "$out/$dev/$(basename "${dts%.dts}").dtb"; then
        echo "::error file=${dts#"$root"/}::device tree failed to build" >&2
        fail=1
    fi
done
exit "$fail"
