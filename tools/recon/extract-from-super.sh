#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck disable=SC2016  # code in single quotes runs elsewhere (phone shell, awk), on purpose
#
# Copy files out of a logical partition inside Android's dynamic `super`
# partition (vendor_a, odm_a, system_a, ...), on a phone running our Linux
# (netroot or installed system, reachable with tools/fap-dev ssh). Read-only.
#
#   tools/recon/extract-from-super.sh [--super <dev>] --list
#   tools/recon/extract-from-super.sh [--super <dev>] <partition> <outdir> <path>...
#
#   e.g. tools/recon/extract-from-super.sh vendor_a out/vendor-fw \
#            /firmware /etc/acdbdata
#
# How: reads the first MiB of super over SSH, finds the partition's byte
# range with lp-parse.py, then on the phone sets up a read-only loop device
# (losetup -r -o <offset> --sizelimit <size>), mounts it `ro,noload` (ext4:
# no journal replay; erofs: plain ro), streams the paths back as a tar,
# unmounts and detaches the loop device, also on failure.
#
# Firmware and vendor files are not redistributable: keep <outdir> out of git.
# --super defaults to /dev/disk/by-partlabel/super.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
FAP_DEV=${FAP_DEV:-$here/../fap-dev}
super=/dev/disk/by-partlabel/super
die() { echo "extract-from-super: $*" >&2; exit 1; }
usage="usage: $0 [--super <dev>] --list | <partition> <outdir> <path>..."

list=0
while [ $# -gt 0 ]; do
    case "$1" in
        --super) super=${2:?$usage}; shift 2 ;;
        --list) list=1; shift ;;
        -h|--help) echo "$usage"; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) break ;;
    esac
done
if [ "$list" = 0 ]; then
    [ $# -ge 3 ] || die "$usage"
    part=$1 outdir=$2; shift 2
fi

# Quote for the remote POSIX shell: 'it'\''s'.
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$FAP_DEV" ssh "dd if=$(q "$super") bs=1M count=1 status=none" > "$tmp/super-head.bin" \
    || die "could not read $super on the phone"

if [ "$list" = 1 ]; then
    python3 "$here/lp-parse.py" "$tmp/super-head.bin"; exit
fi
read -r off size < <(python3 "$here/lp-parse.py" "$tmp/super-head.bin" --partition "$part") \
    || die "cannot map $part from $super (see above)"
echo "extract-from-super: $part = $super bytes $off +$size" >&2

# Paths relative to the partition root, for tar.
args=""
for p in "$@"; do
    p=${p#/}
    [ -n "$p" ] || p=.
    args="$args $(q "$p")"
done

remote='set -eu
super=$1 off=$2 size=$3; shift 3
loop=""
mnt=$(mktemp -d /tmp/fap-extract.XXXXXX)
cleanup() {
    umount "$mnt" 2>/dev/null || true
    [ -n "$loop" ] && losetup -d "$loop" 2>/dev/null || true
    rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
loop=$(losetup -r -f --show -o "$off" --sizelimit "$size" "$super")
mount -o ro,noload "$loop" "$mnt" 2>/dev/null || mount -o ro "$loop" "$mnt"
echo "phone: $loop mounted read-only ($(findmnt -no FSTYPE "$mnt" 2>/dev/null || echo ?))" >&2
cd "$mnt"
tar -cf - -- "$@"'

mkdir -p "$outdir"
# shellcheck disable=SC2086  # $args is pre-quoted for the remote shell
printf '%s\n' "$remote" | "$FAP_DEV" ssh "sh -s -- $(q "$super") $off $size $args" \
    | tar -xf - -C "$outdir"
echo "extract-from-super: $(find "$outdir" -type f | wc -l | tr -d ' ') files in $outdir" >&2
