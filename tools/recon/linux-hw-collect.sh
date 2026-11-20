#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck disable=SC2016  # code in single quotes runs elsewhere (phone shell, awk), on purpose
# Hardware inventory collector: runs ON THE PHONE (as root, mainline Linux:
# our netroot or installed system) and writes a tar of raw files to stdout.
# Read-only, apart from mounting debugfs and a temporary directory in /tmp.
#
#   tools/recon/linux-hw-inventory.sh <outdir>      (from the host, over SSH)
#   sh linux-hw-collect.sh > inventory.tar           (on the phone)
#
# The raw files include serial numbers and MAC addresses.
# FAP_SYSROOT prefixes /sys and /proc, FAP_DMESG replaces dmesg (tests only).
R=${FAP_SYSROOT:-}
DMESG=${FAP_DMESG:-dmesg}
[ -n "$R" ] || [ -d /sys/kernel/debug/clk ] || mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
D=$(mktemp -d /tmp/fap-inventory.XXXXXX)
trap 'rm -rf "$D"' EXIT
run() { f=$1; shift; "$@" > "$D/$f" 2>&1 || true; }
each() {   # each <file> <glob> <command using $d>: one block per match
    f=$1 g=$2 c=$3
    for d in $g; do [ -e "$d" ] || continue; echo "== ${d##*/}"; eval "$c"; done > "$D/$f" 2>&1
}
DBG=$R/sys/kernel/debug

run uname.txt uname -a
run os-release.txt cat "$R/etc/os-release"
run cmdline.txt cat "$R/proc/cmdline"
run cpuinfo.txt cat "$R/proc/cpuinfo"
run meminfo.txt cat "$R/proc/meminfo"
run model.txt sh -c "tr -d '\0' < $R/proc/device-tree/model; echo; tr '\0' ' ' < $R/proc/device-tree/compatible; echo"
cp "$R/sys/firmware/fdt" "$D/fdt.dtb" 2>/dev/null
cp "$R/proc/config.gz" "$D/kernel-config.gz" 2>/dev/null
run soc.txt sh -c "for f in $R/sys/devices/soc0/*; do [ -f \"\$f\" ] && echo \"\$(basename \$f): \$(cat \$f)\"; done"
# shellcheck disable=SC2086  # FAP_DMESG may be "cat <file>"
run dmesg.txt $DMESG
run modules.txt cat "$R/proc/modules"
run partitions.txt sh -c "cat $R/proc/partitions; ls -l /dev/disk/by-partlabel/ 2>/dev/null"

# Driver state
run deferred.txt cat "$DBG/devices_deferred"
run clk-summary.txt cat "$DBG/clk/clk_summary"
run interconnect-summary.txt cat "$DBG/interconnect/interconnect_summary"
run genpd-summary.txt cat "$DBG/pm_genpd/pm_genpd_summary"
run regulator-summary.txt cat "$DBG/regulator/regulator_summary"
run gpio.txt cat "$DBG/gpio"
run interrupts.txt cat "$R/proc/interrupts"
each platform-drivers.txt "$R/sys/bus/platform/drivers/*" 'ls "$d" | grep "\." | tr "\n" " "; echo'
each i2c.txt "$R/sys/bus/i2c/devices/*" 'echo "name=$(cat $d/name 2>/dev/null) driver=$(basename "$(readlink $d/driver)" 2>/dev/null) of=$(tr "\0" " " < $d/of_node/compatible 2>/dev/null)"'
each spi.txt "$R/sys/bus/spi/devices/*" 'echo "driver=$(basename "$(readlink $d/driver)" 2>/dev/null) of=$(tr "\0" " " < $d/of_node/compatible 2>/dev/null)"'
each remoteproc.txt "$R/sys/class/remoteproc/*" 'echo "$(cat $d/name) state=$(cat $d/state) firmware=$(cat $d/firmware 2>/dev/null)"'

# Device classes
run input.txt cat "$R/proc/bus/input/devices"
each drm.txt "$R/sys/class/drm/card*-*" 'echo "status=$(cat $d/status 2>/dev/null) enabled=$(cat $d/enabled 2>/dev/null) modes=$(tr "\n" " " < $d/modes 2>/dev/null)"'
each net.txt "$R/sys/class/net/*" 'echo "driver=$(basename "$(readlink $d/device/driver)" 2>/dev/null) operstate=$(cat $d/operstate) address=$(cat $d/address)"'
each iio.txt "$R/sys/bus/iio/devices/*" 'echo "name=$(cat $d/name 2>/dev/null) channels=$(ls $d | grep _raw$ | tr "\n" " ")"'
each power-supply.txt "$R/sys/class/power_supply/*" 'cat $d/uevent 2>/dev/null'
each thermal.txt "$R/sys/class/thermal/thermal_zone*" 'echo "$(cat $d/type) $(cat $d/temp 2>/dev/null)"'
each sound.txt "$R/proc/asound/card*/id" 'cat $d'
each udc.txt "$R/sys/class/udc/*" 'cat $d/uevent $d/state 2>/dev/null'
each backlight.txt "$R/sys/class/backlight/*" 'echo "$(cat $d/brightness)/$(cat $d/max_brightness)"'
each leds.txt "$R/sys/class/leds/*" 'cat $d/brightness'
run firmware-log.txt sh -c "$DMESG"' | grep -iE "firmware|direct-loading" | grep -iE "fail|error|not found|loaded|request" | tail -n 80'

tar -C "$D" -cf - .
