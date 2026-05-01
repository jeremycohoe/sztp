# AGENTS.md

Operational notes for AI agents (and humans) working on this sZTP lab. Keep
short and verified — anything in here should be runnable as-is.

## Lab device under test

- C9300-24T, SN `FCW2126G05V`, mgmt `10.1.1.55`
- IOS-XE 17.18.01
- SUDI subject: `serialNumber=PID:C9300-24T SN:FCW2126G05V` (sztpd splits on
  first space → registers as `PID:C9300-24T`)

## Single CLI rule on the switch

The **only** command to ask for is:

```
show logging process sztp internal start last 20 minutes
```

Do not ask for `debug`, `show running`, `show sztp` repeatedly, etc. —
everything we need is in that one log.

## DHCP — known-good configuration

DHCP option 143 must use **RFC 8572 §8.2 framing**:

```
payload = uint16_BE_length || URI_bytes (UTF-8)   # repeated per URI
```

IOS-XE 17.x silently drops a plain text URL in option 143. The framing is
non-negotiable.

ISC dhcpd literal (in `dhcp/dhcpd.conf.template`):

```isc
option sztp-redirect-urls code 143 = string;

subnet ${NODE_IP_SUBNET} netmask ${NODE_IP_NETMASK} {
    range ${NODE_IP_RANGE_MIN} ${NODE_IP_RANGE_MAX};
    option sztp-redirect-urls ${OPTION_143_BINARY};
}
```

`${OPTION_143_BINARY}` is rendered by [dhcp/entrypoint.sh](dhcp/entrypoint.sh)
from `SZTP_URL` (set in `docker-compose.yml`). Default value:

```
SZTP_URL=https://10.1.1.3:9090/restconf/operations/ietf-sztp-bootstrap-server:get-bootstrapping-data
```

## DHCP — simplification rules

Two requirements, both verifiable in seconds. Run these before every reload.

1. **Exactly one DHCP server answers on the lab subnet**

   ```sh
   sudo ss -lnup | grep ':67 '
   ```

   Must show exactly one line, and that line must be the container's `dhcpd`.
   The host's `isc-dhcp-server` has been disabled (`systemctl disable
   isc-dhcp-server`); do not re-enable it.

2. **Option 143 is binary-encoded in the rendered config**

   ```sh
   docker exec sztp-dhcp-1 grep 'sztp-redirect-urls 00:' /etc/dhcp/dhcpd.conf
   ```

   Must show `00:5b:68:74:74:70:73:…`. If it shows `"https://…"` (quoted text),
   the framing is wrong and IOS-XE will drop it.

3. **Optional active probe** — confirm option 143 is in the OFFER on the wire:

   ```sh
   sudo python3 - <<'PY'
   from scapy.all import Ether, IP, UDP, BOOTP, DHCP, conf, AsyncSniffer, sendp
   import binascii, time
   conf.iface, conf.checkIPaddr = "ens19", False
   mac = "a0:f8:49:de:ad:bf"
   hw = binascii.unhexlify(mac.replace(":",""))
   xid = 0xC0FFEE99
   sn = AsyncSniffer(iface="ens19", filter="udp and (port 67 or port 68)", store=True)
   sn.start(); time.sleep(0.3)
   disc = (Ether(src=mac, dst="ff:ff:ff:ff:ff:ff")/
           IP(src="0.0.0.0", dst="255.255.255.255")/
           UDP(sport=68, dport=67)/
           BOOTP(chaddr=hw, xid=xid, flags=0x8000)/
           DHCP(options=[("message-type","discover"),
                          ("param_req_list",[1,3,6,15,143]), "end"]))
   sendp(disc, iface="ens19", verbose=0); time.sleep(2)
   for p in sn.stop():
       if p.haslayer(DHCP) and p[BOOTP].xid==xid and p[BOOTP].op==2:
           for o in p[DHCP].options:
               if isinstance(o, tuple) and o[0] == 143:
                   print("option 143:", o[1])
   PY
   ```

   Should print `option 143: b'\x00\x5bhttps://10.1.1.3:9090/restconf/...'`.

## Bring the stack up

```sh
cd /home/auto/sztp
docker compose down --volumes --remove-orphans
docker compose --profile dhcp up -d
```

Healthy state:

```sh
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep sztp
```

All of `sztp-bootstrap-1`, `sztp-redirecter-1`, `sztp-web-1`, `sztp-dhcp-1`
should be `Up` and the first two should be `(healthy)`.

## Common pitfalls (already hit and resolved)

- **Plain quoted URL in option 143** — wrong framing, silently dropped by
  IOS-XE. Use the binary-encoded form rendered by `dhcp/entrypoint.sh`.
- **Two DHCP servers on UDP/67** — host's `isc-dhcp-server` competing with the
  container, container losing the race. Host service has been disabled.
- **Pre-registration key mismatch** — sztpd extracts `PID:C9300-24T` (with
  prefix) from the SUDI subject; the templates must register that exact
  string, not bare `C9300-24T`.
- **Multi-line shell in `docker-compose.yml` `command:`** — YAML escaping is
  fragile. The render logic lives in `dhcp/entrypoint.sh` instead; compose
  just runs `["sh", "/opt/entrypoint.sh"]`.
