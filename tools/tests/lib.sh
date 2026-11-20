# shellcheck shell=bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Shared helpers for the tool tests. Source it.
#
# Safety: the tests never talk to a phone. PATH starts with shims named adb,
# fastboot, ssh, scp and telnet that fail loudly, so a test that forgets to
# point FASTBOOT/SSH/SCP at a fake can't reach a connected phone.
set -euo pipefail

export TOOLS
TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shims"
for tool in adb fastboot ssh scp telnet; do
    printf '#!/bin/sh\necho "TEST BUG: real %s called: $*" >&2\nexit 99\n' "$tool" > "$T/shims/$tool"
    chmod +x "$T/shims/$tool"
done
export PATH="$T/shims:$PATH"

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
nok() { fail=$((fail + 1)); echo "FAIL $*"; }
# check <description> <command...>: passes when the command succeeds.
check() { local d=$1; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }
contains() { case "$1" in *"$2"*) return 0 ;; *) echo "  expected to contain: $2" >&2; echo "  got: $1" >&2; return 1 ;; esac; }
lacks() { case "$1" in *"$2"*) echo "  expected NOT to contain: $2" >&2; return 1 ;; *) return 0 ;; esac; }
finish() { echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]; }
