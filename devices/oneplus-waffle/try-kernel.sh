#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# RAM-boot a candidate kernel on the installed OnePlus 12 (waffle) without
# flashing anything: its modules go into the spare module tree, the flashed
# boot_b kernel keeps its own, and fap-modules-guard picks the right tree at
# every boot. Then `fastboot boot` the candidate's install image and run a
# feature check. A normal reboot afterwards is the old kernel again.
#
#   devices/oneplus-waffle/try-kernel.sh [build-dir]
#     build-dir: a fap-waffle-build.sh OUT folder (default:
#                ~/Develop/fap-build/waffle/install-full)
#   env: FAP_PHONE (phone address, ssh as root), FAP_SERIAL (fastboot serial)
#
# Writes (inside fap_root only): the guard script + unit, the candidate's
# modules under /usr/lib/modules/.fap-spare/. Nothing on any partition other
# than fap_root changes; boot_b is untouched.
set -euo pipefail

B=${1:-$HOME/Develop/fap-build/waffle/install-full}
P=${FAP_PHONE:?set FAP_PHONE to the phone address}
S=${FAP_SERIAL:?set FAP_SERIAL to the fastboot serial}
HERE=$(cd "$(dirname "$0")" && pwd)
R=7.4.0-rc3-fap-waffle+
IMG=$B/ramboot/waffle-uniloader-v4-install.img
MOD=$B/parts/modules-$R.tar.gz
SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
say() { printf '\n==> %s\n' "$*"; }
die() { echo "try-kernel: $*" >&2; exit 1; }

say "Checking the build in $B"
[[ -f $IMG && -f $MOD ]] || die "missing $IMG or $MOD"
(cd "$B" && shasum -a 256 -c SHA256SUMS --quiet) || die "SHA256SUMS mismatch"

say "Installing the guard and the candidate's modules (spare tree) on $P"
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$HERE/installroot/usr/libexec/fap-modules-guard" "root@$P:/usr/libexec/"
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$HERE/installroot/usr/lib/systemd/system/fap-modules-guard.service" "root@$P:/usr/lib/systemd/system/"
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$MOD" "root@$P:/root/"
sum=$(shasum -a 256 "$MOD" | cut -d' ' -f1)
"${SSH[@]}" "root@$P" bash -s "$R" "$sum" <<'EOF'
set -euo pipefail
r=$1; sum=$2; m=/root/modules-$r.tar.gz
echo "$sum  $m" | sha256sum -c --quiet
chmod +x /usr/libexec/fap-modules-guard
act=/usr/lib/modules/$r; sp=/usr/lib/modules/.fap-spare/$r
# The running (flashed) kernel owns the active tree.
uname -v > "$act/.fap-kver"
rm -rf /tmp/try-m "$sp" && mkdir -p /tmp/try-m /usr/lib/modules/.fap-spare
tar -xzf "$m" -C /tmp/try-m
mv "/tmp/try-m/lib/modules/$r" "$sp"
echo '*' > "$sp/.fap-kver"
systemctl daemon-reload
systemctl enable fap-modules-guard.service
echo "active tree: $(cat "$act/.fap-kver")"
echo "spare tree:  $(find "$sp" -name '*.ko*' | wc -l) modules (candidate)"
sync
EOF

say "Rebooting into the bootloader (use the USB 2.0 cable)"
"${SSH[@]}" "root@$P" 'systemctl reboot --reboot-argument=bootloader' || true
for _ in $(seq 1 60); do sleep 2; fastboot devices | grep -q "^$S" && break; done
fastboot devices | grep -q "^$S" || die "phone not in fastboot"
[[ $(fastboot -s "$S" getvar is-userspace 2>&1 | head -1) == *": no" ]] || die "not bootloader fastboot"

say "RAM-booting the candidate (nothing is flashed)"
fastboot -s "$S" boot "$IMG"

say "Waiting for the phone"
for _ in $(seq 1 60); do "${SSH[@]}" -o BatchMode=yes "root@$P" true 2>/dev/null && break; sleep 5; done
sleep 30
say "Feature check"
"${SSH[@]}" "root@$P" bash -s <<'EOF'
chk() { if eval "$2" >/dev/null 2>&1; then echo "ok    $1"; else echo "FAIL  $1"; fi; }
echo "kernel: $(uname -v)"
journalctl -b -o cat | grep fap-modules-guard | tail -1
chk "root on fap_root"        'findmnt -no SOURCE / | grep -q fap_root'
chk "/home on userdata"       'findmnt -no SOURCE /home | grep -q sda14'
chk "KWin on the GPU"         'grep -q freedreno /proc/$(pgrep -x kwin_wayland)/maps'
chk "USB gadget (UDC)"        '[ -n "$(ls /sys/class/udc)" ]'
chk "Wi-Fi interface"         'ip -br link | grep -q ^wl'
chk "Bluetooth controller"    'bluetoothctl show | grep -q "Powered: yes"'
chk "sound card"              'aplay -l | grep -q "OnePlus 12"'
chk "binderfs"                'grep -q binder /proc/filesystems'
chk "Waydroid container"      'systemctl is-active waydroid-container'
for r in /sys/class/remoteproc/*; do printf "%s=%s " "$(cat "$r/name")" "$(cat "$r/state")"; done; echo
echo "failed units: $(systemctl --failed --no-legend | awk '{print $2}' | tr '\n' ' ')"
echo "deferred: $(cut -f1 /sys/kernel/debug/devices_deferred 2>/dev/null | tr '\n' ' ')"
EOF
cat <<EOF

Back to the flashed kernel: reboot normally (the guard swaps the modules
back). To keep the candidate: flash $B/boot_b/fap-boot_b.img to boot_b,
then the guard keeps using the candidate tree ("*") for it.
EOF
