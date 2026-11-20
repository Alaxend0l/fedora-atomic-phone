#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Build every out-of-tree module (kmod/*/, devices/*/kmod/*/: directories with
# a Makefile) against an installed kernel-devel, as tools/build-kmod.sh does.
#   tools/ci/kmods.sh <kver>     e.g. 7.3.4-300.fc45.aarch64
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
kver=${1:?usage: $0 <kver>}
kdir=/usr/src/kernels/$kver
[ -d "$kdir" ] || { echo "kmods: no $kdir (install kernel-devel-$kver)" >&2; exit 1; }
fail=0
for m in "$root"/kmod/*/ "$root"/devices/*/kmod/*/; do
    [ -f "$m/Makefile" ] || continue
    case "$m" in "$root"/devices/_*) continue ;; esac
    rel=${m#"$root"/}
    echo "::group::$rel"
    tmp=$(mktemp -d)
    cp -r "$m". "$tmp/"
    if make -C "$kdir" M="$tmp" W=1 modules; then
        ls -l "$tmp"/*.ko
    else
        echo "::error file=${rel}Makefile::module failed to build against $kver" >&2
        fail=1
    fi
    rm -rf "$tmp"
    echo "::endgroup::"
done
exit "$fail"
