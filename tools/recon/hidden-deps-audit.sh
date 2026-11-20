#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Hidden-dependency audit: runs ON THE PHONE (as root, mainline Linux) and
# prints a Markdown report of state that works only because something else
# (the bootloader, another device) left it on. Read-only: it reads debugfs and
# dmesg, and mounts debugfs if it isn't mounted yet.
#
#   tools/fap-dev audit                       (from the host, over SSH)
#   sh hidden-deps-audit.sh                   (on the phone)
#
# What each section means: devices/oneplus-billie2/hidden-dependencies.md.
# For tests, FAP_SYSROOT prefixes every /sys and /proc path and FAP_DMESG
# replaces the dmesg command.
R=${FAP_SYSROOT:-}
DMESG=${FAP_DMESG:-dmesg}
DBG=$R/sys/kernel/debug

[ -n "$R" ] || [ -d "$DBG/clk" ] || mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

section() { printf '\n## %s\n\n' "$1"; }
code() { echo '```'; cat; echo '```'; }
missing() { echo "(not available: $1)"; }

echo "# Hidden-dependency audit"
echo
echo "- kernel: $(cat "$R/proc/sys/kernel/osrelease" 2>/dev/null)"
echo "- model: $(tr -d '\0' < "$R/proc/device-tree/model" 2>/dev/null)"
echo "- uptime: $(cut -d' ' -f1 "$R/proc/uptime" 2>/dev/null) s"
cmdline=$(cat "$R/proc/cmdline" 2>/dev/null)
echo "- cmdline: \`$cmdline\`"
case " $cmdline " in
    *" clk_ignore_unused "*|*" pd_ignore_unused "*)
        echo
        echo "> Booted with clk_ignore_unused / pd_ignore_unused: the clocks and"
        echo "> power domains below stay on although nothing claims them. Without"
        echo "> those arguments the kernel would switch them off at late_initcall." ;;
esac

section "Clocks on but unclaimed"
echo "Enabled in hardware (\`hardware_enable\` Y) with enable count 0: left on by"
echo "the bootloader or kept by clk_ignore_unused."
echo
f=$DBG/clk/clk_summary
if [ -r "$f" ]; then
    if head -n 3 "$f" | grep -q hardware; then
        awk 'NR>3 && $2==0 && $9=="Y" {print $1, "rate=" $5}' "$f" | code
    else
        echo "(this kernel's clk_summary has no hardware_enable column; listing enable_count 0, prepare_count > 0)"
        awk 'NR>3 && $2==0 && $3>0 {print $1, "rate=" $5}' "$f" | code
    fi
else
    missing "$f"
fi

section "Interconnect votes per consumer (non-zero)"
f=$DBG/interconnect/interconnect_summary
if [ -r "$f" ]; then
    # Node lines start in column 1, consumer lines are indented; print each
    # node that has a non-zero consumer, followed by those consumers.
    awk 'NR<=2 {next}
         /^[^ ]/ {node=$0; shown=0; next}
         /^ / && ($(NF-1) + $NF) > 0 { if (!shown) {print node; shown=1}; print }' "$f" | code
else
    missing "$f"
fi

section "Power domains (pm_genpd_summary)"
f=$DBG/pm_genpd/pm_genpd_summary
if [ -r "$f" ]; then code < "$f"; else missing "$f"; fi

section "Dummy regulators"
echo "Supplies the DT doesn't describe; the hardware gets whatever the bootloader set."
echo
$DMESG 2>/dev/null | grep "using dummy regulator" | sed 's/^\[[ 0-9.]*\] //' | sort -u | code

section "Deferred devices"
f=$DBG/devices_deferred
if [ -r "$f" ]; then
    # debugfs files report size 0, so test the content, not the size.
    deferred=$(cat "$f")
    if [ -n "$deferred" ]; then echo "$deferred" | code; else echo "(none)"; fi
else
    missing "$f"
fi
