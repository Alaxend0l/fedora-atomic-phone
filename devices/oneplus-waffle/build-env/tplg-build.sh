#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Build the OnePlus 12 AudioReach topology from linux-msm/audioreach-topology
# m4 sources (replaces the binary patcher tplg-sec-mi2s.py for the speakers).
#
#   tplg-build.sh <audioreach-topology checkout> <out dir> [shipped Kaanapali-MTP-tplg.bin]
#
# Runs inside the build container (needs m4, alsatplg, GNU diff/sed, xz; the
# reviewed diff was made with GNU diff, BSD diff places hunks differently).
# Example (from ~/Develop/fap-build/waffle):
#   podman run --rm -v <repo>:/repo:ro -v hw/tplg-src/audioreach-topology:/src:ro \
#     -v hw-v10/tplg:/out -v hw/work/tplg:/ref:ro localhost/fap-waffle-build \
#     bash -c "dnf -y -q install /usr/bin/alsatplg m4 git xz &&
#       /repo/devices/oneplus-waffle/build-env/tplg-build.sh /src /out /ref/kaanapali-tplg.bin"
# Steps:
#   1. check the checkout is the pinned commit,
#   2. build upstream SM8550-HDK.m4 and, if given, require it to equal the
#      shipped linux-firmware binary byte for byte (proves the m4 source is
#      what Fedora ships as qcom/kaanapali/Kaanapali-MTP-tplg.bin),
#   3. build devices/oneplus-waffle/tplg/OnePlus-12-waffle.m4 (our board file
#      + subgraph-device-i2s-playback-mfc.m4, found first on the include path),
#   4. decode both binaries with alsatplg -d and require their diff (after the
#      back-end rename) to equal the reviewed tplg/OnePlus-12-vs-stock.diff.
# Output: <out>/OnePlus-12-tplg.bin (+ .xz), stock.bin, *.conf, decoded.diff.
set -euo pipefail

PIN=d6bb205aca5f4b8fa6b2f44cf8b5f6a081cbf037
SRC=$(cd "${1:?audioreach-topology checkout}" && pwd)
OUT=${2:?out dir}
SHIPPED=${3:-}
HERE=$(cd "$(dirname "$0")/.." && pwd)
TP=$HERE/tplg
die() { echo "tplg-build: $*" >&2; exit 1; }

mkdir -p "$OUT"
if [[ -e $SRC/.git ]] && command -v git >/dev/null; then
    rev=$(git -c safe.directory='*' -C "$SRC" rev-parse HEAD)
    [[ $rev == "$PIN" ]] || die "checkout is $rev, expected $PIN"
fi

build() {   # build <board.m4> <out.bin> [extra -I dir first]
    local m4in=$1 bin=$2 inc=()
    [[ -n ${3:-} ]] && inc=(-I "$3")
    (cd "$SRC" && m4 "${inc[@]}" -I "$SRC" -I "$SRC/audioreach" "$m4in") > "${bin%.bin}.m4.conf"
    # alsatplg prints "undefined sink widget/stream '<x> Playback'" for the
    # back-end DAI links; upstream builds print the same, they are not fatal.
    alsatplg -c "${bin%.bin}.m4.conf" -o "$bin" 2> "${bin%.bin}.alsatplg.log"
}

build SM8550-HDK.m4 "$OUT/stock.bin"
if [[ -n $SHIPPED ]]; then
    cmp "$OUT/stock.bin" "$SHIPPED" || die "upstream m4 does not rebuild $SHIPPED"
    echo "stock: SM8550-HDK.m4 @ ${PIN:0:7} == $(basename "$SHIPPED") (byte-identical)"
fi

build "$TP/OnePlus-12-waffle.m4" "$OUT/OnePlus-12-tplg.bin" "$TP"
alsatplg -d "$OUT/stock.bin" -o "$OUT/stock.conf" 2>/dev/null
alsatplg -d "$OUT/OnePlus-12-tplg.bin" -o "$OUT/OnePlus-12.conf" 2>/dev/null
# Compare after renaming the back end (device16 -> device18, Primary ->
# Secondary): the rest must match the reviewed diff in tplg/ exactly (the MFC
# widget + tuples + route, DAI index 16 -> 18, I2S IID 0x6061 -> 0x6062,
# HW_IF_IDX 0 -> 1). Builds are reproducible, so any other change fails here.
sed -e 's/device16\./device18./g; s/Primary MI2S/Secondary MI2S/g; s/PRIMARY_MI2S_RX/SECONDARY_MI2S_RX/g' \
    "$OUT/stock.conf" > "$OUT/stock-renamed.conf"
diff "$OUT/stock-renamed.conf" "$OUT/OnePlus-12.conf" > "$OUT/decoded.diff" || true
grep -v '^#' "$TP/OnePlus-12-vs-stock.diff" | cmp -s "$OUT/decoded.diff" - \
    || die "decoded diff differs from tplg/OnePlus-12-vs-stock.diff (see $OUT/decoded.diff)"
xz -c --check=crc32 "$OUT/OnePlus-12-tplg.bin" > "$OUT/OnePlus-12-tplg.bin.xz"
echo "built: $OUT/OnePlus-12-tplg.bin ($(sha256sum < "$OUT/OnePlus-12-tplg.bin" | cut -c1-16)…), decoded diff == reviewed diff"
