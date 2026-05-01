#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jeremy Cohoe
# run-interop-matrix.sh
#
# For each row in tests/interop-matrix.yaml, render the stack config for
# that platform, run the preflight validator, and record pass/fail plus
# captured artifacts.
#
# NOTE: this script does NOT power-cycle or reload the target device.
# It only verifies the server-side stack is correctly configured for
# each row. Actual device runs are tracked manually in the row's
# `status` field.
#
# Usage:
#   scripts/run-interop-matrix.sh [--row <id>] [--out <dir>]
#
# Output directory layout:
#   <out>/
#     <row-id>/
#       preflight.log
#       dhcpd.conf.snippet
#       status.txt
#     summary.md

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MATRIX="${REPO_ROOT}/tests/interop-matrix.yaml"
OUT_DIR=""
ONLY_ROW=""

while (( $# > 0 )); do
    case "$1" in
        --row) ONLY_ROW="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="${REPO_ROOT}/tests/interop-results/$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUT_DIR"

# Python reader — parses YAML (requires PyYAML or falls back to a minimal
# parser) and prints tab-separated rows on stdout.
ROWS="$(python3 - "$MATRIX" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")
doc = yaml.safe_load(open(sys.argv[1]))
for row in doc.get("matrix", []):
    fields = [
        row.get("id", ""),
        row.get("trust_anchor", ""),
        row.get("sztp_url", ""),
        row.get("sztp_device_sn", ""),
        row.get("voucher_file", ""),
        row.get("owner_cert", ""),
        row.get("status", ""),
    ]
    print("\t".join(str(f) for f in fields))
PY
)"

SUMMARY="$OUT_DIR/summary.md"
{
    printf '# Interop matrix run — %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '| Row | Trust anchor | URL | SN | Encoder | Preflight |\n'
    printf '|---|---|---|---|---|---|\n'
} > "$SUMMARY"

overall_rc=0
while IFS=$'\t' read -r id trust url sn _voucher _owner status; do
    if [[ -n "$ONLY_ROW" && "$ONLY_ROW" != "$id" ]]; then continue; fi

    row_dir="$OUT_DIR/$id"
    mkdir -p "$row_dir"

    # Encoder check
    enc_result="pass"
    enc_hex="$(python3 "$REPO_ROOT/scripts/encode_sztp_url.py" "$url" --format hex 2>/dev/null || true)"
    if [[ -z "$enc_hex" ]]; then enc_result="fail"; overall_rc=1; fi
    printf '%s\n' "$enc_hex" > "$row_dir/opt143.hex"

    # Render a dhcpd snippet for this row (doesn't replace running dhcp).
    python3 "$REPO_ROOT/scripts/encode_sztp_url.py" "$url" > "$row_dir/opt143.colon" 2>/dev/null || true

    # Preflight against the currently-running stack, with this row's env.
    preflight_result="skip"
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q '^sztp-bootstrap-1$'; then
        if SZTP_URL="$url" SZTP_DEVICE_SN="$sn" SZTP_TRUST_ANCHOR="$trust" \
            "$REPO_ROOT/scripts/sztp-preflight.sh" > "$row_dir/preflight.log" 2>&1; then
            preflight_result="pass"
        else
            preflight_result="fail"
            # Preflight fail does not fail the matrix run itself — it is
            # expected for rows whose device isn't currently in the lab.
        fi
    fi

    printf '%s\t%s\n' "$id" "$status" > "$row_dir/status.txt"

    printf '| %s | %s | %s | %s | %s | %s |\n' \
        "$id" "$trust" "$url" "$sn" "$enc_result" "$preflight_result" >> "$SUMMARY"
done <<< "$ROWS"

printf 'Wrote %s\n' "$SUMMARY"
exit "$overall_rc"
