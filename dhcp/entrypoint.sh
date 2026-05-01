#!/bin/sh
# Render /etc/dhcp/dhcpd.conf from /opt/dhcpd.conf.template, then exec dhcpd.
#
# Why binary framing?
#   Cisco IOS-XE 17.18 *silently drops* option 143 when delivered with the
#   ISC `text` encoding — the autoinstall log shows si-addr only, never
#   `bootstrap-server-list:`. Only RFC 8572 §8.2 binary framing is parsed:
#       uint16 BE length || URI bytes
#   expressed here as a colon-separated hex literal (e.g. 00:15:68:74:74:...).
#
# Why scheme+host+port only (no path)?
#   The switch's sZTP client appends the RESTCONF path itself
#   (`/restconf/operations/ietf-sztp-bootstrap-server:get-bootstrapping-data`).
#   If SZTP_URL also includes that path the request URL becomes doubled and
#   sztpd returns 404 "Unrecognized RPC." Always set SZTP_URL to the
#   redirecter endpoint scheme+host+port only — e.g. https://10.1.1.3:8080.
set -eu

: "${SZTP_URL:?SZTP_URL must be set}"
: "${NODE_IP_SUBNET:=10.1.1.0}"
: "${NODE_IP_NETMASK:=255.255.255.0}"
: "${NODE_IP_RANGE_MIN:=10.1.1.100}"
: "${NODE_IP_RANGE_MAX:=10.1.1.253}"
: "${DHCP_INTERFACE:=ens19}"

# Refuse SZTP_URL with a path component — IOS-XE will double the path and 404.
case "$SZTP_URL" in
    https://*/*)
        echo "FATAL: SZTP_URL must be scheme+host+port only (no path)." >&2
        echo "       got:      $SZTP_URL" >&2
        echo "       expected: https://HOST:PORT (e.g. https://10.1.1.3:8080)" >&2
        exit 2
        ;;
    https://*) ;;
    *)
        echo "FATAL: SZTP_URL must start with https:// (got: $SZTP_URL)" >&2
        exit 2
        ;;
esac

URL_LEN=$(printf %s "$SZTP_URL" | wc -c)
HI=$(( URL_LEN >> 8 ))
LO=$(( URL_LEN & 0xff ))
URL_HEX=$(printf %s "$SZTP_URL" | od -An -tx1 -v | tr -d '\n ' | sed 's/\(..\)/:\1/g')
OPTION_143_BINARY=$(printf '%02x:%02x%s' "$HI" "$LO" "$URL_HEX")

export NODE_IP_SUBNET NODE_IP_NETMASK NODE_IP_RANGE_MIN NODE_IP_RANGE_MAX OPTION_143_BINARY

sed \
    -e "s|\${NODE_IP_SUBNET}|${NODE_IP_SUBNET}|g" \
    -e "s|\${NODE_IP_NETMASK}|${NODE_IP_NETMASK}|g" \
    -e "s|\${NODE_IP_RANGE_MIN}|${NODE_IP_RANGE_MIN}|g" \
    -e "s|\${NODE_IP_RANGE_MAX}|${NODE_IP_RANGE_MAX}|g" \
    -e "s|\${OPTION_143_BINARY}|${OPTION_143_BINARY}|g" \
    /opt/dhcpd.conf.template > /etc/dhcp/dhcpd.conf

echo "=== SZTP_URL=$SZTP_URL (len=$URL_LEN) ==="
echo "=== rendered /etc/dhcp/dhcpd.conf ==="
cat /etc/dhcp/dhcpd.conf
echo "=== end ==="

touch /var/lib/dhcp/dhcpd.leases
exec dhcpd -d -cf /etc/dhcp/dhcpd.conf "$DHCP_INTERFACE"
