#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Print the newest kernel-devel version-release.arch of this Fedora (run
# inside the fedora:<release> container), e.g. 7.3.4-300.fc45.aarch64.
#   tools/ci/fedora-kernel.sh            -> 7.3.4-300.fc45.aarch64
#   tools/ci/fedora-kernel.sh --tag      -> v7.3.4  (matching Linux tag)
set -euo pipefail
nvra=$(dnf5 -q repoquery --latest-limit=1 --arch "$(uname -m)" \
          --qf '%{version}-%{release}.%{arch}\n' kernel-devel | tail -n 1)
[ -n "$nvra" ] || { echo "fedora-kernel: no kernel-devel found" >&2; exit 1; }
if [ "${1:-}" = --tag ]; then
    ver=${nvra%%-*}                 # 7.3.4
    ver=${ver%.0}                   # 7.3.0 -> 7.3 (Linux tags drop .0)
    echo "v$ver"
else
    echo "$nvra"
fi
