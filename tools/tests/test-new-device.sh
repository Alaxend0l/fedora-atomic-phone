#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Tests for tools/new-device.sh. Runs on a scratch copy of the parts of the
# repo it needs, so the real devices/ is never touched.
#   tools/tests/test-new-device.sh
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tools" "$tmp/devices" "$tmp/boot"
cp "$repo/tools/new-device.sh" "$repo/tools/check-device.sh" "$tmp/tools/"
cp -R "$repo/devices/_template" "$tmp/devices/"
for m in "$repo"/boot/*/; do mkdir -p "$tmp/boot/$(basename "$m")"; done

fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; fails=$((fails + 1)); }
expect_ok()   { local t=$1; shift; if "$@" >"$tmp/out" 2>&1; then pass "$t"; else fail "$t"; cat "$tmp/out" >&2; fi; }
expect_fail() { local t=$1; shift; if "$@" >"$tmp/out" 2>&1; then fail "$t (should have failed)"; else pass "$t"; fi; }
# shellcheck disable=SC2329 # called through expect_ok/expect_fail
nd() { FAP_DATE=2026-01-02 "$tmp/tools/new-device.sh" "$@"; }

expect_ok "scaffold a device" nd --soc google-zuma --maintainer "A B <a@b>" google-shiba "Google Pixel 8 & co/x"
d=$tmp/devices/google-shiba
expect_ok "check-device accepts it" "$tmp/tools/check-device.sh" "$d"
expect_fail "no placeholders left" grep -rq '@[A-Z_]*@' "$d"
expect_ok "name substituted literally" grep -q '^DEVICE_NAME="Google Pixel 8 & co/x"' "$d/device.env"
expect_ok "codename" grep -q '^DEVICE_CODENAME="shiba"' "$d/device.env"
expect_ok "soc" grep -q '^DEVICE_SOC="google-zuma"' "$d/device.env"
expect_ok "maintainer" grep -q '^DEVICE_MAINTAINER="A B <a@b>"' "$d/device.env"
expect_ok "kernel dtb uses vendor-codename" grep -q '^KERNEL_DTB="qcom/google-shiba.dtb"' "$d/device.env"
expect_ok "features.yaml names the device" grep -q '^device: "google-shiba"' "$d/features.yaml"
expect_ok "date filled" grep -q '^updated: "2026-01-02"' "$d/features.yaml"
expect_ok "build is executable" test -x "$d/build"
for f in README.md TODO.md hidden-dependencies.md firmware.yaml dts/README.md kmod/README.md \
         rootfs/usr/lib/image-builder/bootc/disk.yaml; do
    expect_ok "has $f" test -f "$d/$f"
done
expect_ok "dts placeholder is dual-licensed" grep -q 'SPDX-License-Identifier: (GPL-2.0+ OR BSD-3-Clause)' "$d/dts/board.dts.example"
expect_ok "kmod placeholder is GPL-2.0-only" grep -q 'SPDX-License-Identifier: GPL-2.0-only' "$d/kmod/README.md"
expect_ok "template is untouched" grep -q '@DEVICE_ID@' "$tmp/devices/_template/device.env"

expect_fail "refuses an existing folder" nd google-shiba "Again"
expect_fail "refuses an id without vendor" nd shiba "No vendor"
expect_fail "refuses upper case" nd Google-shiba "Upper"
expect_fail "refuses path tricks" nd ../evil-x "Evil"
expect_fail "refuses quotes in the name" nd foo-bar 'Say "hi"'
expect_fail "refuses a missing name" nd foo-bar
expect_fail "refuses a bad soc" nd --soc 'a b' foo-baz "X"
expect_fail "nothing created on refusal" test -e "$tmp/devices/foo-bar"

# check-device catches a broken edit
sed -i.bak 's/^AVB_FOOTERS=""/AVB_FOOTERS="boot"/' "$d/device.env"
expect_fail "check-device rejects a bad AVB_FOOTERS" "$tmp/tools/check-device.sh" "$d"
mv "$d/device.env.bak" "$d/device.env"
sed -i.bak 's/^DEVICE_STATUS=.*/DEVICE_STATUS="great"/' "$d/device.env"
expect_fail "check-device rejects a bad DEVICE_STATUS" "$tmp/tools/check-device.sh" "$d"
mv "$d/device.env.bak" "$d/device.env"

[ "$fails" = 0 ] && echo "all new-device tests passed"
exit "$fails"
