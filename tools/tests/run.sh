#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Run all tool tests. No phone needed: adb/fastboot/ssh are shimmed to fail.
#   tools/tests/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
TOOLS=$(cd "$here/.." && pwd)
export TOOLS
rc=0
for t in "$here"/test-*.sh; do
    echo "== ${t##*/}"
    bash "$t" || rc=1
done
echo "== test_lp_parse.py"
python3 -I "$here/test_lp_parse.py" || rc=1
echo "== test_update.py (needs PyYAML)"
python3 -I "$here/test_update.py" || rc=1
exit $rc
