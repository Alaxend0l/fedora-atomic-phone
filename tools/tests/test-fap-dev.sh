#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Tests for tools/fap-dev with a fake fastboot and canned command output.
# No phone involved.
# shellcheck disable=SC2016  # fake tools are written with single-quoted code
# shellcheck source=tools/tests/lib.sh
source "$(dirname "$0")/lib.sh"
set +e   # failures are counted, not fatal

# A fake fastboot: a little state machine in $T/fb.
#   up=1|0, gone=<polls left while rebooting>, userspace=yes|no, log of calls.
mkdir -p "$T/fb"
cat > "$T/fake-fastboot" <<'EOF'
#!/usr/bin/env bash
S=$FAKE_FB
echo "$*" >> "$S/calls"
[ "$1" = -s ] && shift 2
case "$1" in
    devices)
        g=$(cat "$S/gone" 2>/dev/null || echo 0)
        if [ "$g" -gt 0 ]; then echo $((g - 1)) > "$S/gone"; exit 0; fi
        [ "$(cat "$S/up")" = 1 ] && printf 'FAKE123\tfastboot\n'
        [ -f "$S/second" ] && printf 'OTHER456\tfastboot\n'
        exit 0 ;;
    getvar)
        case "$2" in
            is-userspace) echo "is-userspace: $(cat "$S/userspace")" >&2 ;;
            all) cat "$S/getvar-all" >&2 ;;
        esac
        echo "Finished. Total time: 0.001s" >&2 ;;
    reboot) echo 2 > "$S/gone"; echo no > "$S/userspace" ;;
    boot) echo "Sending 'boot.img'" >&2 ;;
    *) echo "FORBIDDEN $*" >> "$S/calls"; exit 9 ;;
esac
EOF
chmod +x "$T/fake-fastboot"
export FASTBOOT="$T/fake-fastboot" FAKE_FB="$T/fb" FAP_POLL=0 FAP_TIMEOUT=2
reset_fb() { rm -f "$T/fb"/*; echo 1 > "$T/fb/up"; echo "${1:-no}" > "$T/fb/userspace"; }

# shellcheck source=tools/fap-dev
source "$TOOLS/fap-dev"
set +e

# --- fastboot allow-list
out=$( (fb flash boot x.img) 2>&1); check "fb refuses flash" contains "$out" refusing
out=$( (fb erase dtbo) 2>&1); check "fb refuses erase" contains "$out" refusing
out=$( (fb flashing lock) 2>&1); check "fb refuses flashing lock" contains "$out" refusing
out=$( (fb set_active b) 2>&1); check "fb refuses set_active" contains "$out" refusing
out=$( (fb reboot recovery) 2>&1); check "fb refuses reboot recovery" contains "$out" refusing
out=$( (fb oem unlock) 2>&1); check "fb refuses oem" contains "$out" refusing

# --- wait-fastboot / fresh session
reset_fb
check "wait_fastboot prints the serial" [ "$(wait_fastboot 1)" = FAKE123 ]
touch "$T/fb/second"
out=$( (wait_fastboot 1) 2>&1); check "wait_fastboot refuses two phones" contains "$out" FAP_SERIAL
check "FAP_SERIAL picks one" [ "$(FAP_SERIAL=OTHER456 wait_fastboot 1)" = OTHER456 ]
reset_fb; echo 0 > "$T/fb/up"
out=$( (wait_fastboot 0) 2>&1); check "wait_fastboot times out" contains "$out" "no phone in fastboot"

reset_fb yes
fresh_fastboot always 2>/dev/null
calls=$(cat "$T/fb/calls")
check "fresh session reboots to the bootloader" contains "$calls" "reboot bootloader"
check "fresh session saw the phone leave" [ "$(cat "$T/fb/gone")" = 0 ]

reset_fb no
fresh_fastboot if-userspace 2>/dev/null
check "--reuse-session skips the reboot in the bootloader" lacks "$(cat "$T/fb/calls")" reboot
reset_fb yes
fresh_fastboot if-userspace 2>/dev/null
check "--reuse-session still leaves fastbootd" contains "$(cat "$T/fb/calls")" "reboot bootloader"

# --- ramboot (gadget and SSH waits faked)
reset_fb
: > "$T/boot.img"
usb_products() { echo "Some Keyboard"; echo "ramboot debug shell"; }
wait_ssh() { echo 172.16.42.1; }
out=$( (cmd_ramboot "$T/boot.img") 2>&1)
calls=$(cat "$T/fb/calls")
check "ramboot: reboot bootloader before boot" contains "$calls" "reboot bootloader"
check "ramboot: fastboot boot <img>" contains "$calls" "boot $T/boot.img"
check "ramboot: no forbidden fastboot calls" lacks "$calls" FORBIDDEN
check "ramboot reports SSH ready" contains "$out" "ready"
usb_products() { echo "Some Keyboard"; }
reset_fb
out=$( (FAP_POLL=0.1 cmd_ramboot "$T/boot.img") 2>&1)
check "ramboot fails without the gadget" contains "$out" "no USB gadget"
out=$( (cmd_ramboot "$T/missing.img") 2>&1)
check "ramboot checks the image exists" contains "$out" "no such file"

# --- getvar summary (Pixel-like and Qualcomm-like samples; serials made up)
reset_fb
cat > "$T/fb/getvar-all" <<'EOF'
(bootloader) ap-ar-ns:3
(bootloader) current-slot:a
(bootloader) gsa-bl1-ar:3
(bootloader) has-slot:boot:yes
(bootloader) product:shiba
(bootloader) serialno:00000000TEST
(bootloader) slot-count:2
(bootloader) slot-successful:a:yes
(bootloader) slot-successful:b:no
(bootloader) slot-unbootable:a:no
(bootloader) slot-unbootable:b:yes
(bootloader) slot-retry-count:b:0
(bootloader) unlocked:yes
(bootloader) is-userspace:no
(bootloader) version-bootloader:ripcurrent-17.0-16433839
(bootloader) partition-type:userdata:f2fs
all: Done!!
EOF
out=$(cmd_state -o "$T/raw.txt" 2>/dev/null)
check "state: product" contains "$out" "| product | shiba |"
check "state: slot b unbootable row" contains "$out" "| slot-unbootable:b | yes |"
check "state: anti-rollback ap-ar-ns" contains "$out" "| ap-ar-ns | 3 |"
check "state: anti-rollback gsa-bl1-ar" contains "$out" "| gsa-bl1-ar | 3 |"
check "state: warns about slot b" contains "$out" "slot b is marked unbootable"
check "state: no serial in the summary" lacks "$out" 00000000TEST
check "state: has-slot not mistaken for ARB" lacks "$out" "has-slot"
check "state: raw saved" grep -q serialno "$T/raw.txt"
out=$(printf '(bootloader) product:bengal\n(bootloader) unlocked:no\n(bootloader) is-userspace:yes\n' | summarize_getvar)
check "state: locked warning" contains "$out" LOCKED
check "state: fastbootd warning" contains "$out" fastbootd
out=$(echo "< waiting for any device >" | summarize_getvar); check "state: empty input fails" [ $? -ne 0 ]

# --- finding the phone
ifconfig_mac='lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255
en7: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet6 fe80::1c2d:aaaa:bbbb:cccc%en7 prefixlen 64 secured scopeid 0x13
	inet 169.254.12.34 netmask 0xffff0000 broadcast 169.254.255.255
en8: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 172.16.42.2 netmask 0xffffff00 broadcast 172.16.42.255'
check "parse_ifconfig (macOS)" [ "$(echo "$ifconfig_mac" | parse_ifconfig)" = "en7 169.254.12.34
en8 172.16.42.2" ]
ip_linux='1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever
5: enp0s20f0u1    inet 172.16.42.2/24 brd 172.16.42.255 scope global dynamic enp0s20f0u1\       valid_lft 3500sec
6: usb1    inet 169.254.3.4/16 brd 169.254.255.255 scope link usb1'
check "parse_ip_addr (Linux)" [ "$(echo "$ip_linux" | parse_ip_addr)" = "enp0s20f0u1 172.16.42.2
usb1 169.254.3.4" ]

host_usb_ifaces() { echo "en8 172.16.42.2"; }
check "addr: DHCP lease -> 172.16.42.1" [ "$(find_phone)" = 172.16.42.1 ]
check "addr: FAP_PHONE wins" [ "$(FAP_PHONE=10.0.0.9 find_phone)" = 10.0.0.9 ]

host_usb_ifaces() { echo "en7 169.254.12.34"; }
host_ll() { echo "fe80::1c2d:aaaa:bbbb:cccc"; }
ping6_out='PING6(56=40+8+8 bytes) fe80::1c2d:aaaa:bbbb:cccc%en7 --> ff02::1%en7
16 bytes from fe80::1c2d:aaaa:bbbb:cccc%en7, icmp_seq=0 hlim=64 time=0.081 ms
16 bytes from fe80::d0a1:22ff:fe33:4455%en7, icmp_seq=0 hlim=64 time=1.203 ms
16 bytes from fe80::1c2d:aaaa:bbbb:cccc%en7, icmp_seq=1 hlim=64 time=0.090 ms'
with_timeout() { echo "$ping6_out"; }
check "addr: link-local neighbour, host's own skipped" [ "$(find_phone)" = "fe80::d0a1:22ff:fe33:4455%en7" ]
ping_linux='64 bytes from fe80::d0a1:22ff:fe33:4455%usb1: icmp_seq=1 ttl=64 time=0.9 ms'
with_timeout() { echo "$ping_linux"; }
host_usb_ifaces() { echo "usb1 169.254.3.4"; }
check "addr: Linux ping output" [ "$(FAP_OS=Linux find_phone)" = "fe80::d0a1:22ff:fe33:4455%usb1" ]
with_timeout() { :; }
find_phone >/dev/null; check "addr: nothing found -> failure" [ $? -ne 0 ]

check "scp target IPv4" [ "$(scp_target 172.16.42.1)" = "root@172.16.42.1" ]
check "scp target IPv6 bracketed" [ "$(scp_target fe80::1%en7)" = "root@[fe80::1%en7]" ]

# --- ssh/scp/audit/clock build the right commands (fake ssh/scp record argv)
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$FAKE_ARGS"; [ -z "$FAKE_READ_STDIN" ] || cat > "$FAKE_ARGS.stdin"\necho "phone: Thu Jan  1 00:00:00 UTC 1970"\n' > "$T/fake-ssh"
chmod +x "$T/fake-ssh"
export FAKE_ARGS="$T/args" FAKE_READ_STDIN=""
run() { FAP_PHONE=172.16.42.1 SSH="$T/fake-ssh" SCP="$T/fake-ssh" "$TOOLS/fap-dev" "$@" </dev/null >/dev/null 2>&1; }
run ssh uname -a; a=$(cat "$T/args")
check "ssh: host-key options" contains "$a" "UserKnownHostsFile=/dev/null"
check "ssh: target and command" contains "$a" "root@172.16.42.1
uname
-a"
run scp-to ./x /tmp/y; check "scp-to: target" contains "$(cat "$T/args")" "root@172.16.42.1:/tmp/y"
FAP_PHONE=fe80::1%en7 SSH="$T/fake-ssh" SCP="$T/fake-ssh" "$TOOLS/fap-dev" scp-from /etc/os-release . </dev/null >/dev/null 2>&1
check "scp-from: IPv6 bracketed" contains "$(cat "$T/args")" "root@[fe80::1%en7]:/etc/os-release"
FAKE_READ_STDIN=1 FAP_PHONE=172.16.42.1 SSH="$T/fake-ssh" "$TOOLS/fap-dev" audit >/dev/null 2>&1
check "audit: sends the audit script on stdin" grep -q "Hidden-dependency audit" "$T/args.stdin"
run clock; a=$(cat "$T/args")
check "clock: sets the date in UTC" contains "$a" "date -u -s '20"
check "unknown command fails" [ "$("$TOOLS/fap-dev" frobnicate >/dev/null 2>&1; echo $?)" = 2 ]
check "help works" contains "$("$TOOLS/fap-dev" help)" "fresh-fastboot"

finish
