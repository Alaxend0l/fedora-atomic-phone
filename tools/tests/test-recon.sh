#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Tests for tools/recon/* with a fake sysfs/debugfs tree, a fake adb and a
# fake fap-dev. No phone involved.
# shellcheck source=tools/tests/lib.sh
source "$(dirname "$0")/lib.sh"
set +e
RECON=$TOOLS/recon

# --- a fake phone filesystem ---------------------------------------------------
S=$T/sysroot
mkdir -p "$S/sys/kernel/debug/clk" "$S/sys/kernel/debug/interconnect" "$S/sys/kernel/debug/pm_genpd" \
         "$S/proc/device-tree" "$S/proc/sys/kernel" "$S/proc/bus/input" \
         "$S/sys/class/net/usb0" "$S/sys/class/power_supply/battery" "$S/sys/class/remoteproc/remoteproc0" \
         "$S/sys/class/thermal/thermal_zone0" "$S/etc"
cat > "$S/sys/kernel/debug/clk/clk_summary" <<'EOF'
                                 enable  prepare  protect                                duty  hardware                            connection
   clock                          count    count    count        rate   accuracy phase  cycle    enable   consumer                         id
---------------------------------------------------------------------------------------------------------------------------------------------
 xo_board                            1       1        0        19200000    0          0     50000      Y      deviceless                      no_connection_id
    gcc_gpu_iref_clk                 0       0        0        19200000    0          0     50000      Y      deviceless                      no_connection_id
    gcc_usb30_prim_master_clk        1       1        0        66666667    0          0     50000      Y      4ef8800.usb                     core
    gcc_camss_top_ahb_clk            0       0        0        19200000    0          0     50000      N      deviceless                      no_connection_id
EOF
cat > "$S/sys/kernel/debug/interconnect/interconnect_summary" <<'EOF'
 node                                  tag          avg         peak
--------------------------------------------------------------------
qnm_gpu                                            3880000      3880000
  5900000.gpu                           0          3880000      3880000
qhs_ufs                                                  0            0
  4804000.ufshc                         0                0            0
ebi                                                 800000       800000
  5e00000.display-subsystem             0           800000       800000
  4804000.ufshc                         0                0            0
EOF
printf 'domain                          status          children\ngpu_cx_gdsc                     on\n' > "$S/sys/kernel/debug/pm_genpd/pm_genpd_summary"
: > "$S/sys/kernel/debug/devices_deferred"
echo "console=tty0 clk_ignore_unused pd_ignore_unused fap.root=LABEL=fap-root" > "$S/proc/cmdline"
printf 'OnePlus Nord N100\0' > "$S/proc/device-tree/model"
printf 'oneplus,billie2\0qcom,sm4250\0' > "$S/proc/device-tree/compatible"
echo 7.3.4-300.fc45.aarch64 > "$S/proc/sys/kernel/osrelease"
echo "123.45 100.00" > "$S/proc/uptime"
printf 'I: Bus=0019\nN: Name="pm8941_pwrkey"\n\nI: Bus=0018\nN: Name="ili9882n"\n' > "$S/proc/bus/input/devices"
echo up > "$S/sys/class/net/usb0/operstate"; echo 02:00:00:00:00:01 > "$S/sys/class/net/usb0/address"
printf 'POWER_SUPPLY_NAME=battery\nPOWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=65\n' > "$S/sys/class/power_supply/battery/uevent"
echo mpss > "$S/sys/class/remoteproc/remoteproc0/name"; echo running > "$S/sys/class/remoteproc/remoteproc0/state"
echo cpu0-thermal > "$S/sys/class/thermal/thermal_zone0/type"; echo 33000 > "$S/sys/class/thermal/thermal_zone0/temp"
printf '%s\n' '[    1.234567] platform 1d84000.ufshc: supply vdd-hba not found, using dummy regulator' \
              '[    2.000000] ath10k_snoc 18800000.wifi: supply vdd-3.3-ch1 not found, using dummy regulator' \
              '[    3.000000] remoteproc remoteproc0: Direct firmware load for qcom/a610_zap.mdt failed with error -2' > "$T/dmesg.txt"
export FAP_SYSROOT=$S FAP_DMESG="cat $T/dmesg.txt"

# --- hidden-deps-audit.sh --------------------------------------------------------
out=$(sh "$RECON/hidden-deps-audit.sh")
check "audit: model" contains "$out" "model: OnePlus Nord N100"
check "audit: warns about clk_ignore_unused" contains "$out" "Booted with clk_ignore_unused"
check "audit: unclaimed clock listed" contains "$out" "gcc_gpu_iref_clk rate=19200000"
check "audit: claimed clock not listed" lacks "$out" "gcc_usb30_prim_master_clk"
check "audit: hardware-off clock not listed" lacks "$out" "gcc_camss_top_ahb_clk"
check "audit: GPU vote listed under its node" contains "$out" "qnm_gpu"
check "audit: zero-vote node omitted" lacks "$out" "qhs_ufs"
check "audit: zero-vote consumer omitted" lacks "$out" "4804000.ufshc"
check "audit: genpd" contains "$out" "gpu_cx_gdsc"
check "audit: dummy regulator" contains "$out" "supply vdd-hba not found"
check "audit: nothing deferred" contains "$out" "(none)"
echo "4e00000.usb   platform: wait for supplier" > "$S/sys/kernel/debug/devices_deferred"
out=$(sh "$RECON/hidden-deps-audit.sh")
check "audit: deferred device" contains "$out" "4e00000.usb"
out=$(FAP_SYSROOT=$T/empty sh "$RECON/hidden-deps-audit.sh" 2>&1); rc=$?
check "audit: missing debugfs is reported, not fatal" [ $rc -eq 0 ]
check "audit: missing clk_summary noted" contains "$out" "not available"

# --- linux-hw-collect.sh + linux-hw-inventory.sh --summary ---------------------
mkdir -p "$T/inv/raw"
sh "$RECON/linux-hw-collect.sh" 2>/dev/null | tar -xf - -C "$T/inv/raw"
check "collect: clk summary copied" [ -s "$T/inv/raw/clk-summary.txt" ]
check "collect: model" grep -q "OnePlus Nord N100" "$T/inv/raw/model.txt"
check "collect: power supply" grep -q CAPACITY=65 "$T/inv/raw/power-supply.txt"
check "collect: leaves no temp dir" [ -z "$(ls -d /tmp/fap-inventory.* 2>/dev/null)" ]
out=$("$RECON/linux-hw-inventory.sh" --summary "$T/inv" 2>&1); rc=$?
check "inventory summary runs" [ $rc -eq 0 ]
sum=$(cat "$T/inv/summary.md")
check "summary: deferred" contains "$sum" "4e00000.usb"
check "summary: unclaimed clock" contains "$sum" "gcc_gpu_iref_clk"
check "summary: input names" contains "$sum" '"ili9882n"'
check "summary: remoteproc" contains "$sum" "mpss state=running"
check "summary: firmware failure" contains "$sum" "a610_zap.mdt failed"
check "summary: network interface" contains "$sum" "== usb0"

# The host side drives the collector through fap-dev ssh.
cat > "$T/fake-fap-dev" <<EOF
#!/bin/sh
# fake fap-dev: "ssh <cmd>" runs <cmd> locally against the fake sysroot
[ "\$1" = ssh ] || exit 9
shift
case "\$*" in
    "sh -s") exec sh -s ;;
    dd\ if=*) exec cat "$T/super-head.bin" ;;
    "sh -s -- "*) echo "\$*" > "$T/remote-args"; cat > "$T/remote-script"; exec tar -C "$T/vendorfs" -cf - firmware ;;
esac
exit 9
EOF
chmod +x "$T/fake-fap-dev"
FAP_DEV="$T/fake-fap-dev" "$RECON/linux-hw-inventory.sh" "$T/inv2" >/dev/null 2>&1
check "inventory via fap-dev ssh" grep -q "OnePlus Nord N100" "$T/inv2/summary.md"

# --- extract-from-super.sh -------------------------------------------------------
python3 -I - "$T/super-head.bin" <<'EOF'
import importlib.util, os, sys
sys.path.insert(0, os.path.join(os.environ["TOOLS"], "tests"))
spec = importlib.util.spec_from_file_location("t", os.path.join(os.environ["TOOLS"], "tests", "test_lp_parse.py"))
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
open(sys.argv[1], "wb").write(t.build_super(t.PARTS))
EOF
mkdir -p "$T/vendorfs/firmware"; echo blob > "$T/vendorfs/firmware/a610_zap.mdt"
out=$(FAP_DEV="$T/fake-fap-dev" "$RECON/extract-from-super.sh" --list 2>&1)
check "extract --list prints the LP table" contains "$out" "vendor_a"
out=$(FAP_DEV="$T/fake-fap-dev" "$RECON/extract-from-super.sh" vendor_a "$T/x" /firmware "/it's here" 2>&1); rc=$?
check "extract: runs" [ $rc -eq 0 ]
check "extract: file arrived" [ "$(cat "$T/x/firmware/a610_zap.mdt" 2>/dev/null)" = blob ]
args=$(cat "$T/remote-args")
check "extract: byte offset and size from LP metadata" contains "$args" "$((2099200 * 512)) $((1048576 * 512))"
check "extract: paths made relative and quoted" contains "$args" "'firmware' 'it'\\''s here'"
script=$(cat "$T/remote-script")
check "extract: read-only loop device" contains "$script" "losetup -r"
check "extract: ro,noload mount" contains "$script" "mount -o ro,noload"
check "extract: cleanup trap" contains "$script" "trap cleanup EXIT"
out=$(FAP_DEV="$T/fake-fap-dev" "$RECON/extract-from-super.sh" product_a "$T/y" /x 2>&1)
check "extract: multi-extent partition refused" contains "$out" "2 extents"

# --- android-recon.sh with a fake adb --------------------------------------------
cat > "$T/getprop.txt" <<'EOF'
[gsm.version.baseband]: [g5300i-260818-261007-B-16536936]
[ro.boot.dynamic_partitions]: [true]
[ro.boot.flash.locked]: [1]
[ro.boot.slot_suffix]: [_a]
[ro.boot.verifiedbootstate]: [green]
[ro.bootloader]: [ripcurrent-17.0-16433839]
[ro.product.ab_ota_partitions]: [abl,bl1,bl2,boot,dtbo,system,vendor]
[ro.product.device]: [shiba]
[ro.product.model]: [Pixel 8]
[ro.serialno]: [00000000TEST]
[ro.soc.model]: [Tensor G3]
EOF
cat > "$T/fake-adb" <<EOF
#!/bin/sh
echo "\$*" >> "$T/adb.log"
case "\$1" in
    get-state) echo device ;;
    shell) case "\$2" in getprop) cat "$T/getprop.txt" ;; "uname -a") echo "Linux localhost 6.1.182 aarch64" ;; *) echo "permission denied" ;; esac ;;
    *) echo "FORBIDDEN \$*" >> "$T/adb.log"; exit 9 ;;
esac
EOF
chmod +x "$T/fake-adb"
out=$(ADB="$T/fake-adb" "$RECON/android-recon.sh" "$T/ar" 2>&1); rc=$?
check "android-recon runs" [ $rc -eq 0 ]
sum=$(cat "$T/ar/summary.md")
check "android-recon: model row" contains "$sum" "| Model | Pixel 8 | \`ro.product.model\` |"
check "android-recon: no serial in summary" lacks "$sum" 00000000TEST
check "android-recon: locked note" contains "$sum" "**locked**"
check "android-recon: A/B boot chain warning" contains "$sum" "(abl bl1 bl2)"
check "android-recon: dynamic partitions note" contains "$sum" "inside \`super\`"
check "android-recon: raw getprop kept" grep -q ro.serialno "$T/ar/raw/getprop.txt"
check "android-recon: only shell/get-state adb calls" lacks "$(cat "$T/adb.log")" FORBIDDEN
check "android-recon: no adb writes" lacks "$(cat "$T/adb.log")" "push"
printf '#!/bin/sh\necho unauthorized\n' > "$T/fake-adb2"; chmod +x "$T/fake-adb2"
out=$(ADB="$T/fake-adb2" "$RECON/android-recon.sh" "$T/ar2" 2>&1)
check "android-recon: refuses without a device" contains "$out" "no adb device"

finish
