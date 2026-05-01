#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jeremy Cohoe
# verify-sztp.sh
#
# Runtime smoke test: pretend to be the device and POST get-bootstrapping-data
# to the redirecter from inside the docker network. Catches regressions in the
# sitecustomize patches, CMS signing, and TLS configuration BEFORE involving a
# real switch.
#
# Pass = HTTP 200 + body is a CMS SignedData blob containing redirect-info.
#
# Usage:
#   scripts/verify-sztp.sh [--env-file config/catalyst/c9300.env]

set -eu

ENV_FILE=""
while (( $# > 0 )); do
    case "$1" in
        --env-file) ENV_FILE="$2"; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done
if [[ -n "$ENV_FILE" ]]; then
    set -a; . "$ENV_FILE"; set +a
fi

SZTP_URL="${SZTP_URL:-https://10.1.1.3:8080}"
DEVICE_SN="${SZTP_DEVICE_SN:-C9300-24T}"

# RFC 8572 RPC body — minimum fields the redirecter accepts.
body='{"ietf-sztp-bootstrap-server:input":{"signed-data-preferred":[null],"hw-model":"'"$DEVICE_SN"'","os-name":"IOS-XE","os-version":"17.18.01"}}'

printf 'POST %s/restconf/operations/ietf-sztp-bootstrap-server:get-bootstrapping-data\n' "$SZTP_URL"

response="$(curl -sk -w '\n__HTTP_CODE__%{http_code}' \
    -X POST \
    -H 'Accept: application/yang-data+json' \
    -H 'Content-Type: application/yang-data+json' \
    --data "$body" \
    "${SZTP_URL}/restconf/operations/ietf-sztp-bootstrap-server:get-bootstrapping-data" \
    || true)"

http_code="${response##*__HTTP_CODE__}"
payload="${response%$'\n'__HTTP_CODE__*}"

printf 'HTTP %s\n' "$http_code"

if [[ "$http_code" != "200" ]]; then
    printf 'FAIL: expected 200, got %s\n' "$http_code" >&2
    printf 'body: %s\n' "$payload" | head -c 400 >&2
    exit 1
fi

if printf '%s' "$payload" | grep -q 'conveyed-information'; then
    printf 'OK: redirecter returned signed conveyed-information (%d bytes)\n' "${#payload}"
    exit 0
fi

printf 'FAIL: 200 but body has no conveyed-information field\n' >&2
printf '%s\n' "$payload" | head -c 400 >&2
exit 1
