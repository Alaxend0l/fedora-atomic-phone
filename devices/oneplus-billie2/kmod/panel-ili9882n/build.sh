#!/usr/bin/env bash
# Build panel-ili9882n.ko for a Fedora kernel, in a container.
#   devices/oneplus-billie2/kmod/panel-ili9882n/build.sh <kver> <outdir>
#   e.g. build.sh 7.3.4-300.fc45.aarch64 ~/Develop/fap-build/kmod
set -euo pipefail
kver=${1:?usage: $0 <kver> <outdir>}
out=${2:?usage: $0 <kver> <outdir>}
mkdir -p "$out"; out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
podman run --rm -v "$here:/src:ro" -v "$out:/out" registry.fedoraproject.org/fedora:45 bash -euo pipefail -c '
    dnf5 -y -q install gcc make "kernel-devel-$1" >/dev/null 2>&1
    cp -r /src /tmp/build && cd /tmp/build
    make -C "/usr/src/kernels/$1" M=/tmp/build modules
    cp panel-ili9882n.ko /out/
    modinfo /out/panel-ili9882n.ko | grep -E "^(filename|vermagic|alias)"
' _ "$kver"
