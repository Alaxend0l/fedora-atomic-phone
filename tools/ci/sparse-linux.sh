#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Sparse, shallow checkout of what tools/dtb-compile.sh needs from a Linux
# tree: arch/arm64/boot/dts, include/, scripts/dtc/include-prefixes.
#   tools/ci/sparse-linux.sh <git-url> <tag-or-branch> <dir>
set -euo pipefail
url=${1:?url}; ref=${2:?ref}; dir=${3:?dir}
git clone -q --depth 1 --branch "$ref" --filter=blob:none --sparse "$url" "$dir"
git -C "$dir" sparse-checkout set arch/arm64/boot/dts include scripts/dtc
echo "$url $ref -> $dir ($(git -C "$dir" rev-parse --short HEAD))"
