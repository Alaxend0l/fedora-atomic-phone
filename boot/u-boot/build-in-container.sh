#!/usr/bin/env bash
# Build U-Boot for a device inside a Fedora container, so the host only needs
# podman (works from macOS via podman machine).
#
#   boot/u-boot/build-in-container.sh <u-boot-src> <dtb-name> <outdir>
#   e.g. boot/u-boot/build-in-container.sh ~/Develop/fap-build/u-boot \
#            qcom/sm4250-oneplus-billie2 ~/Develop/fap-build/out
#
# Fedora 44, not 45: U-Boot's host tools use OpenSSL's ENGINE API, which
# OpenSSL 4.0 (Fedora 45) removed and which can't be configured away
# (other tools options select TOOLS_LIBCRYPTO). Fedora 44 has OpenSSL 3.5,
# with the ENGINE headers in the separate openssl-devel-engine package.
set -euo pipefail

src=$(realpath "${1:?usage: $0 <u-boot-src> <dtb-name> <outdir>}")
dtb=${2:?usage: $0 <u-boot-src> <dtb-name> <outdir>}
out=${3:?usage: $0 <u-boot-src> <dtb-name> <outdir>}
mkdir -p "$out"
out=$(realpath "$out")
here=$(cd "$(dirname "$0")" && pwd)

podman run --rm \
    -v "$src:/src" -v "$out:/out" -v "$here:/scripts:ro" \
    registry.fedoraproject.org/fedora:44 bash -euc '
        dnf -y -q install gcc make bison flex openssl-devel openssl-devel-engine \
            gnutls-devel python3 python3-pyelftools python3-setuptools swig dtc \
            bc android-tools gzip diffutils xxd >/dev/null
        make -C /src mrproper >/dev/null
        /scripts/build.sh /src "$1" /out
        unpack_bootimg --boot_img /out/uboot.img --out /tmp/check \
            | grep -E "header version|kernel_size|dtb size|dtb address"
    ' _ "$dtb"
