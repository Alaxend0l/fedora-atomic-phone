#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Create devices/<vendor>-<codename>/ from devices/_template/, with names,
# date and maintainer filled in, then validate it with tools/check-device.sh.
#
#   tools/new-device.sh [--soc <soc>] [--maintainer "<who>"] <vendor-codename> "<Name>"
#   e.g. tools/new-device.sh --soc google-zuma google-shiba "Google Pixel 8"
#
# Writes nothing outside the new folder and never talks to a phone. Next
# steps are printed at the end (and in docs/porting.md).
set -euo pipefail

usage() {
    sed -n 's/^#   //p' "$0" >&2
    exit 2
}

soc="unknown"
maintainer=$(git config user.name 2>/dev/null || true)
while [ $# -gt 0 ]; do
    case "$1" in
        --soc) soc=${2:?--soc needs a value}; shift 2 ;;
        --maintainer) maintainer=${2:?--maintainer needs a value}; shift 2 ;;
        -h|--help) usage ;;
        --) shift; break ;;
        -*) echo "new-device: unknown option $1" >&2; usage ;;
        *) break ;;
    esac
done
[ $# -eq 2 ] || usage
id=$1
name=$2

# <vendor>-<codename>: lower case, vendor without dashes, as in postmarketOS.
if ! [[ "$id" =~ ^[a-z0-9]+-[a-z0-9][a-z0-9_-]*$ ]]; then
    echo "new-device: '$id' is not <vendor>-<codename> (lower case, e.g. oneplus-billie2)" >&2
    exit 2
fi
[ -n "$name" ] || { echo "new-device: empty name" >&2; exit 2; }
case "$name" in *$'\n'*|*'"'*) echo "new-device: name must be one line without quotes" >&2; exit 2 ;; esac
[[ "$soc" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "new-device: bad --soc '$soc'" >&2; exit 2; }
case "$maintainer" in *$'\n'*|*'"'*) echo "new-device: maintainer must be one line without quotes" >&2; exit 2 ;; esac
[ -n "$maintainer" ] || maintainer="unknown"

root=$(cd "$(dirname "$0")/.." && pwd)
template=$root/devices/_template
dest=$root/devices/$id
[ -d "$template" ] || { echo "new-device: no $template" >&2; exit 1; }
[ ! -e "$dest" ] || { echo "new-device: $dest already exists" >&2; exit 1; }

cp -R "$template" "$dest"

# Fill the @TOKEN@ placeholders with bash's own string replacement, so names
# with /, & or \ need no escaping (sed would). The replacements are quoted
# so bash >= 5.2 (patsub_replacement) doesn't expand & in them.
date=${FAP_DATE:-$(date +%F)}
while IFS= read -r -d '' f; do
    text=$(cat "$f"; echo x); text=${text%x}       # keep trailing newlines
    text=${text//@DEVICE_ID@/"$id"}
    text=${text//@DEVICE_NAME@/"$name"}
    text=${text//@VENDOR@/"${id%%-*}"}
    text=${text//@CODENAME@/"${id#*-}"}
    text=${text//@SOC@/"$soc"}
    text=${text//@MAINTAINER@/"$maintainer"}
    text=${text//@DATE@/"$date"}
    printf '%s' "$text" > "$f"
done < <(find "$dest" -type f -print0)
chmod +x "$dest/build"

if left=$(grep -rl '@[A-Z_]*@' "$dest"); then
    echo "new-device: placeholders left in: $left" >&2
    exit 1
fi

"$root/tools/check-device.sh" "$dest"

cat <<EOF

Created devices/$id. Next (docs/porting.md has the full list):
  1. device.env: SoC, KERNEL_DTB, boot image layout from the stock boot image,
     FASTBOOT_PRODUCT, BACKUP_PARTITIONS / PROTECTED_PARTITIONS.
  2. README.md: hardware table, partitions, recovery path (tested!).
  3. firmware.yaml: every blob, where it lives on the phone.
  4. features.yaml: statuses as you go; regenerate docs/devices.md with
     tools/support-matrix.py.
  5. First boot from RAM (fastboot boot), nothing written. Recipes for what
     goes wrong: docs/porting-cookbook.md.
EOF
