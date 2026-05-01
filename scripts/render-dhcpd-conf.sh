#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jeremy Cohoe
# Render dhcp/dhcpd.conf from dhcp/dhcpd.conf.template.
#
# Inputs (env vars):
#   SZTP_URL            Comma-separated https:// URI list (required)
#   NODE_IP_SUBNET      e.g. 10.1.1.0
#   NODE_IP_NETMASK     e.g. 255.255.255.0
#   NODE_IP_RANGE_MIN   e.g. 10.1.1.100
#   NODE_IP_RANGE_MAX   e.g. 10.1.1.253
#
# Output:
#   /data/dhcpd.conf    ISC dhcpd configuration with RFC 8572 §8.2
#                       option 143 payload encoded as ":"-separated hex.
#
# Exits non-zero on any error.

set -eu

: "${SZTP_URL:?SZTP_URL must be set (comma-separated https URIs)}"
: "${NODE_IP_SUBNET:=10.1.1.0}"
: "${NODE_IP_NETMASK:=255.255.255.0}"
: "${NODE_IP_RANGE_MIN:=10.1.1.100}"
: "${NODE_IP_RANGE_MAX:=10.1.1.253}"

TEMPLATE="${TEMPLATE:-/data/dhcpd.conf.template}"
OUTPUT="${OUTPUT:-/data/dhcpd.conf}"
ENCODER="${ENCODER:-/usr/local/bin/encode_sztp_url.py}"

if [ ! -f "$TEMPLATE" ]; then
    echo "render-dhcpd-conf: template not found: $TEMPLATE" >&2
    exit 1
fi

OPTION_143_BINARY="$(python3 "$ENCODER" --format colon)"
export OPTION_143_BINARY NODE_IP_SUBNET NODE_IP_NETMASK NODE_IP_RANGE_MIN NODE_IP_RANGE_MAX

# Only substitute the known variables; leave other $… untouched.
envsubst '$NODE_IP_SUBNET $NODE_IP_NETMASK $NODE_IP_RANGE_MIN $NODE_IP_RANGE_MAX $OPTION_143_BINARY' \
    < "$TEMPLATE" > "$OUTPUT"

echo "render-dhcpd-conf: wrote $OUTPUT"
echo "render-dhcpd-conf: SZTP_URL=$SZTP_URL"
echo "render-dhcpd-conf: OPTION_143_BINARY=$OPTION_143_BINARY"
