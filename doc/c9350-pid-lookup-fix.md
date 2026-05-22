# C9350 / Q200 sZTP enablement & PID-based device lookup

## Summary

Two related defects prevented Cisco Catalyst 9350-48P (IOS-XE 26.01.x,
Q200 / HA-SUDI generation) from completing RFC 8572 secure ZTP against the
sztpd stack in this repo, and one DHCP misconfiguration was steering switches
into classic ZTP. All three are now fixed and the fixes are baked into
[config/](../config/) and [scripts/](../scripts/) so they survive a clone of
the source VM.

| # | Symptom on the switch | Root cause | Fix |
|---|---|---|---|
| 1 | OFFER contained option 67 *and* option 143; some IOS-XE builds ran classic ZTP via `bootfile-name` | Host `isc-dhcp-server` had `option bootfile-name "http://10.1.1.3/ztp-simple.py"` alongside option 143 in `/etc/dhcp/dhcpd.conf` | Remove/comment `option bootfile-name` in host DHCP. Documented for source-VM templating. |
| 2 | Bootstrap failed with `Failed to extract xml body / Bootstrapping not received`; sztpd audit log: `Device "Q5CG-6PWR-DK2T" not found for any tenant` | sztpd 0.0.15's mTLS code path reads device-lookup key from `peercert['subject'][-1][0][1]`. On C9350 HA-SUDI certs the *last* RDN is CN (Cloud ID), not the `serialNumber` (PID/SN). | `scripts/docker-entrypoint.sh` sitecustomize now wraps `ssl.getpeercert` and rewrites the Subject so the lookup key is always the PID from the `serialNumber` RDN. |
| 3 | After (2) was fixed, C9300 bootstrap rejected the voucher: `Serial number mismatch. Expected: FCW2129G02U, actual: FCW2126G05V` | Per-chassis voucher hook in sztpd's `cryptography.x509.Name.get_attributes_for_oid` was never reached on the mTLS path (sztpd reads peercert straight from the SSL transport), so every device got the static fallback voucher | Same `getpeercert` hook also captures the chassis SN into the per-request contextvar, so the existing per-chassis voucher picker fires on the mTLS path. |

End-state, verified in lab POD11 on 2026-05-21:

| Device | Chassis SN | sztpd device-lookup key | Voucher served | Outcome |
|---|---|---|---|---|
| C9300-24T | FCW2129G02U | `C9300-24T` | `FCW2129G02U.vcj` | sZTP success |
| C9350-48P | FVH2943LJ0E | `C9350-48P` | `FVH2943LJ0E.vcj` | sZTP success |

---

## 1. DHCP — option 67 / option 143 coexistence

### What happened

[/etc/dhcp/dhcpd.conf](file:///etc/dhcp/dhcpd.conf) on the host had both:

```isc
option sztp-redirect-urls 00:15:68:74:74:70:73:3a:2f:2f:31:30:2e:31:2e:31:2e:33:3a:38:30:38:30;
option bootfile-name "http://10.1.1.3/ztp-simple.py";
```

The OFFER carried both options; the switch console showed:

```
bootfile             : http://10.1.1.3/ztp-simple.py
bootstrap-server-list: https://10.1.1.3:8080
```

Although IOS-XE 17/26 generally prefers option 143 when both are present,
mixed behavior was observed and it complicated triage. The repo position
([IOSXE.md §6.2](../IOSXE.md)) is now explicit: **comment out
`option bootfile-name` when you intend to run sZTP**.

### Detection one-liner

```sh
sudo timeout 6 python3 - <<'PY'
from scapy.all import Ether, IP, UDP, BOOTP, DHCP, conf, AsyncSniffer, sendp
import binascii, time
conf.iface, conf.checkIPaddr = "ens19", False
mac = "a0:f8:49:de:ad:c1"; hw = binascii.unhexlify(mac.replace(":",""))
xid = 0xC0FFEEBB
sn = AsyncSniffer(iface="ens19",
                  filter="udp and (port 67 or port 68)", store=True); sn.start()
time.sleep(0.3)
disc = (Ether(src=mac, dst="ff:ff:ff:ff:ff:ff") /
        IP(src="0.0.0.0", dst="255.255.255.255") /
        UDP(sport=68, dport=67) /
        BOOTP(chaddr=hw, xid=xid, flags=0x8000) /
        DHCP(options=[("message-type","discover"),
                       ("param_req_list",[1,3,6,15,66,67,143]),"end"]))
sendp(disc, iface="ens19", verbose=0); time.sleep(2)
for p in sn.stop():
    if p.haslayer(DHCP) and p[BOOTP].xid == xid and p[BOOTP].op == 2:
        for o in p[DHCP].options:
            if isinstance(o, tuple):
                print(o[0], "=", o[1] if not isinstance(o[1], bytes) else o[1][:80])
PY
```

OFFER must contain `143 = b'\x00\x15https://10.1.1.3:8080'` and **no**
`boot-file-name`.

---

## 2. sztpd device-lookup picked the Cloud ID instead of the PID

### How sztpd 0.0.15 builds the lookup key

`sztpd.rfc8572.get-bootstrapping-data` extracts the device-lookup key from
the SSL transport's peercert dict (`/usr/local/lib/python3.11/site-packages/sztpd/rfc8572.py:248`):

```python
N = C.transport.get_extra_info('peercert')
if N is not None:
    O = N['subject'][-1][0][1]   # value of the LAST RDN
    K.add(O)
```

That works on older Cisco SUDI certs that carry a single RDN —
`serialNumber=PID:<x> SN:<y>` — because the "last RDN" *is* the
`serialNumber` and its value starts with `PID:<x>`, which sztpd later
splits on whitespace.

### What the C9350 cert looks like

```text
subject=
    CN=Q5CG-6PWR-DK2T            <-- Cloud ID
    OU=ACT-2 Lite SUDI
    O=Cisco
    serialNumber=PID:C9350-48P SN:FVH2943LJ0E
issuer=
    O=Cisco
    CN=High Assurance SUDI CA    <-- HA-SUDI (SHA-256)
```

In the peercert dict Python emits, `CN` sorts **last**, so
`subject[-1][0][1]` = `Q5CG-6PWR-DK2T` (the Cloud ID), not the PID.
sztpd then reported in the audit log:

```json
"comment": "Device \"Q5CG-6PWR-DK2T\" not found for any tenant."
```

By policy in this project Cloud ID is **never** used as a device key.

### Fix — sitecustomize peercert normalizer

[scripts/docker-entrypoint.sh](../scripts/docker-entrypoint.sh) wraps both
`ssl.SSLObject.getpeercert` and `ssl.SSLSocket.getpeercert`. For every
peercert dict the wrapper:

1. Finds the `serialNumber` RDN and parses Cisco's canonical
   `PID:<x> SN:<y>` value.
2. **Appends** a synthetic `serialNumber` RDN whose value is the PID, so
   `subject[-1][0][1]` is now deterministically the PID on every Cisco
   platform — old (single-RDN) and new (multi-RDN, with CN).
3. Stashes the chassis SN into the existing `_current_chassis_sn`
   contextvar so the per-chassis voucher picker fires (see §3).

Diagnostic line emitted at container start:

```
sitecustomize: ssl.getpeercert hooked to normalize peercert.subject to PID
  (drop Cloud ID); chassis SN captured on mTLS path
```

### Why we don't just add the Cloud ID to the templates

- Cloud ID is opaque, regenerable, and is a Cisco-cloud (Meraki) identifier
  unrelated to sZTP.
- The project deliberately keys devices on **PID** (one entry per model)
  and selects per-chassis vouchers by SN. Mixing in Cloud IDs would
  bifurcate the device registry by platform generation for no benefit.

---

## 3. Per-chassis voucher picker never fired on the mTLS path

### What was already there

The previous fix
([commit 45414d7](https://github.com/jeremycohoe/sztp/commit/45414d7))
hooked `cryptography.x509.Name.get_attributes_for_oid` to capture the
chassis SN into a contextvar, so [scripts/docker-entrypoint.sh](../scripts/docker-entrypoint.sh)
could pick `local_files/<CHASSIS_SN>.vcj` per request.

That hook runs only when sztpd parses a PEM-encoded peer cert (the HTTP
header `Ssl-Client-Cert` path, used behind reverse proxies). The native
mTLS path reads `peercert` from the SSL transport directly and **never
calls `get_attributes_for_oid`**, so the contextvar stayed `None` and
sztpd served the static `SZTP_OWNERSHIP_VOUCHER_CMS` fallback to every
device.

Symptom: C9300 (`FCW2129G02U`) was sent `FCW2126G05V.vcj`. The switch's
sZTP client verified the voucher signature and trust anchor, then
correctly rejected it on chassis-SN mismatch:

```
Signature on ownership voucher's CMS structure has been verified.
The voucher is created in the past
The voucher is not expired
ERR: Serial number mismatch. Expected: FCW2129G02U, actual: FCW2126G05V
ERR: Failed to validate ownership voucher in the bootstrapping data
```

### Fix

The same `ssl.getpeercert` wrapper from §2 also writes to
`_current_chassis_sn`, so the existing per-chassis picker fires on the
mTLS path now. Diagnostic line on every request when it works:

```
sitecustomize: loaded per-chassis voucher /local_files/FCW2129G02U.vcj
sitecustomize: injected owner-certificate + ownership-voucher
  [FCW2129G02U.vcj] into RPC output
```

---

## 4. Trust anchor for C9350

C9350 SUDI certs are issued by `CN=High Assurance SUDI CA`
(SHA-256, "Cisco Root CA 2099"). They are correctly matched by the
HA-SUDI trust anchor already present in both sztpd templates:

```json
"local-truststore-reference": {
    "certificate-bag": "my-device-identity-ca-certs",
    "certificate":     "my-device-identity-ca-cert-circa-2020"
}
```

…via the `cisco-hasudi-device-type` device-type. The new C9350 device
entry references that device-type:

```json
{
  "serial-number": "C9350-48P",
  "device-type":   "cisco-hasudi-device-type",
  "response-manager": { ... }
}
```

No change to the trust-anchor configuration was required.

---

## 5. PID list & template entries

Added in this branch:

- [config/cisco-pids.txt](../config/cisco-pids.txt) — `C9350-48P,hasudi`
- [config/sztpd.redirect.json.template](../config/sztpd.redirect.json.template) — device entry referencing `my-redirect-information`
- [config/sztpd.running.json.template](../config/sztpd.running.json.template) — device entry referencing `first-onboarding-information`

Add other C9350 variants the same way as Cisco publishes them.

---

## 6. Verification commands

Server side:

```sh
# 1. Hooks are loaded
docker logs sztp-redirecter-1 2>&1 | grep -E 'sitecustomize:'

# 2. Live audit log (device-lookup keys + outcomes)
docker exec sztp-redirecter-1 curl -s \
  -u my-admin@example.com:my-secret \
  'http://127.0.0.1:7070/restconf/ds/ietf-datastores:operational/wn-sztpd-1:audit-log' \
  -H 'Accept: application/yang-data+json' | python3 -m json.tool | tail -40

# 3. Confirm per-chassis voucher selection on each request
docker logs sztp-redirecter-1 2>&1 \
  | grep -E 'per-chassis voucher|fallback\(env\)|injected.*ownership-voucher'
```

Switch side:

```text
Switch# show logging process sztp internal start last 20 minutes
```

Expected on success:

```
Retrieved HW model: C9300-24T            (or C9350-48P)
Signature on ownership voucher's CMS structure has been verified.
Retrieved serial number: <chassis SN>
Serial number matched
The ownership voucher is valid
Conveyed info signature is verified
Bootstrapping received
```

---

## 7. Source-VM bake-in checklist

To carry these fixes into the source-VM image that other pods clone from:

1. `git pull` on the source VM (this branch on `origin/main`).
2. On the source VM, comment out `option bootfile-name` in
   `/etc/dhcp/dhcpd.conf` (or remove host `isc-dhcp-server` entirely if
   the pod uses container DHCP — see [AGENTS.md](../AGENTS.md) §"DHCP").
3. Drop **per-chassis voucher files** for all expected chassis SNs into
   `local_files/` named `<CHASSIS_SN>.vcj` (e.g. `FVH2943LJ0E.vcj`).
4. Confirm `local_files/owner-certificate.{crt,key}`,
   `owner_cert_chain.{cms,pem}`, and `pinned-domain-cert.crt` match the
   pinned-domain-cert inside every voucher you ship.
5. Take the VM snapshot. Clones will inherit the fixed templates,
   sitecustomize, and PID list automatically; only step 2 is manual
   per-host system config.

---

## Commits

- `feat(fleet): register C9350-48P (HA-SUDI) device-type` — c051b94
- `fix(sztpd): normalize mTLS peercert to PID, capture chassis SN` — e5b54c8

Pushed to `https://github.com/jeremycohoe/sztp` on `main`.
