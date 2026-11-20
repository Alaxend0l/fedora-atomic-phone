#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Build an out-of-tree kernel module directory (Makefile with obj-m) against a
# Fedora kernel's kernel-devel, in a container. Copies the .ko files to outdir.
#
#   tools/build-kmod.sh <module-dir> <kver> <outdir>
#   e.g. tools/build-kmod.sh kmod/adc-ocv-battery 7.3.4-300.fc45.aarch64 out/kmod
set -euo pipefail
usage="usage: $0 <module-dir> <kver> <outdir>"
src=$(cd "${1:?$usage}" && pwd)
kver=${2:?$usage}
out=${3:?$usage}
mkdir -p "$out"; out=$(cd "$out" && pwd)
podman run --rm -v "$src:/src:ro" -v "$out:/out" registry.fedoraproject.org/fedora:45 bash -euo pipefail -c '
    dnf5 -y -q install gcc make "kernel-devel-$1" >/dev/null 2>&1
    cp -r /src /tmp/build && cd /tmp/build
    make -C "/usr/src/kernels/$1" M=/tmp/build W=1 modules
    cp *.ko /out/
    ls -l /out/*.ko
' _ "$kver"
