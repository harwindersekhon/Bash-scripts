#!/usr/bin/env bash
#
# sync-helpers.sh - Copy the COMMON HELPERS block from templates/script-skeleton.sh
# into every scripts/*.sh, so each script stays standalone but identical.
#
# Usage: tools/sync-helpers.sh           rewrite the block in every script
#        tools/sync-helpers.sh --check   only report scripts whose block differs
#
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKELETON="${ROOT}/templates/script-skeleton.sh"
BEGIN='# ===== BEGIN COMMON HELPERS'
END='# ===== END COMMON HELPERS'

extract() { sed -n "/^${BEGIN}/,/^${END}/p" "$1"; }

ref=$(extract "$SKELETON")
[[ -n "$ref" ]] || { echo "No helper block found in ${SKELETON}" >&2; exit 1; }

mode=${1:-sync}
case "$mode" in
    sync | --check) ;;
    *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac
status=0
for f in "${ROOT}"/scripts/*.sh; do
    rel=${f#"${ROOT}/"}
    if ! grep -q "^${BEGIN}" "$f"; then
        echo "SKIP ${rel} (no helper markers)"
        continue
    fi
    if [[ "$(extract "$f")" == "$ref" ]]; then
        echo "ok   ${rel}"
        continue
    fi
    if [[ "$mode" == --check ]]; then
        echo "DIFF ${rel}"
        status=1
        continue
    fi
    tmp=$(mktemp)
    # Pass the block via the environment: awk -v would mangle its backslashes.
    BLOCK="$ref" awk -v b="^${BEGIN}" -v e="^${END}" '
        $0 ~ b { print ENVIRON["BLOCK"]; skip = 1; next }
        $0 ~ e { skip = 0; next }
        !skip  { print }
    ' "$f" >"$tmp"
    cat "$tmp" >"$f"
    rm -f "$tmp"
    echo "sync ${rel}"
done
exit "$status"
