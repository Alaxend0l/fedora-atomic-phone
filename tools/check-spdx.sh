#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Every tracked text file needs an SPDX-License-Identifier line in its first
# five lines (LICENSING.md says which license where). Exempt: LICENSE, empty
# files, binary files.
#   tools/check-spdx.sh
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
while IFS= read -r -d '' f; do
    case "$f" in LICENSE) continue ;; esac
    [ -s "$f" ] || continue
    grep -Iq . "$f" || continue          # binary
    if ! head -n 5 "$f" | grep -q 'SPDX-License-Identifier:'; then
        echo "no SPDX-License-Identifier: $f"
        fail=1
    fi
done < <(git ls-files -z)
[ "$fail" = 0 ] && echo "SPDX: all tracked text files tagged"
exit "$fail"
