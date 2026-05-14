# Secure ZTP on Cisco IOS-XE — Single Source of Truth

End-to-end guide for bootstrapping a Cisco Catalyst (C9300 / C9200) running
IOS-XE 17.18.x using this repo's sZTPD stack.

This file **supersedes** the previous `iosxe.md`, `iosxe2.md`, and
`IOSXE-QUICKSTART.md`. Operational notes for AI agents are in
[AGENTS.md](AGENTS.md); generic ZTP background is in [ZTP.md](ZTP.md).

---

## Contents

1. [Architecture](#1-architecture)
2. [Host prerequisites](#2-host-prerequisites)
3. [Crypto artifacts](#3-crypto-artifacts)
4. [Device identity (SUDI) and registration](#4-device-identity-sudi-and-registration)
5. [Trust anchor selection](#5-trust-anchor-selection)
6. [DHCP option 143](#6-dhcp-option-143)
7. [Bring the stack up](#7-bring-the-stack-up)
8. [Preflight checks](#8-preflight-checks)
9. [Reload the switch and watch](#9-reload-the-switch-and-watch)
10. [Why the sztpd container needs patches](#10-why-the-sztpd-container-needs-patches)
11. [Error → fix lookup table](#11-error--fix-lookup-table)
12. [New-device checklist](#12-new-device-checklist)

---

## 1. Architecture

```
┌──────────┐  DHCP option 143  ┌─────────────────┐
│  C9300   │ ────────────────▶ │  DHCP server    │ UDP/67
│ IOS-XE   │                   │  (host or       │
│ switch   │                   │   container)    │
│          │                   └─────────────────┘
│          │   mTLS RESTCONF
│          │ ────────────────▶ ┌─────────────────┐
│          │   POST get-       │   redirecter    │ SBI :8080  NBI :7070
│          │ ◀── redirect ──── │   (sztpd)       │
│          │                   └─────────────────┘
│          │   mTLS RESTCONF
│          │ ────────────────▶ ┌─────────────────┐
│          │   POST get-       │   bootstrap     │ SBI :9090  NBI :7080
│          │ ◀── onboard ───── │   (sztpd)       │
└──────────┘                   └─────────────────┘
```

Both sztpd instances run from `docker.io/opiproject/sztpd:0.0.15`. The Go
agent under `sztp-agent/` is a Linux/DPU client and is **not** involved in
the IOS-XE flow.

---

## 2. Host prerequisites

Tested on Ubuntu 24.04. Install once:

```sh
sudo apt-get update
sudo apt-get install -y \
    docker.io docker-compose-v2 \
    python3-scapy \
    openssl
```

Notes:

- `docker-compose-v2` provides `docker compose` (the legacy `docker-compose`
  Python script is **not** required and is no longer available in 24.04).
- `python3-scapy` is only needed for the on-the-wire option-143 probe
  ([§6](#6-dhcp-option-143)). Skip it on prod hosts.
- `openssl` is used by [scripts/validate-sztp-artifacts.sh](scripts/validate-sztp-artifacts.sh)
  and by ad-hoc verification commands in this guide.

No Python `pip` packages are required on the host — sztpd's internals run
inside the container.

---

## 3. Crypto artifacts

All six files live in [local_files/](local_files/) and are mounted into the
bootstrap and redirecter containers.

| File | Required? | What it is |
|---|---|---|
| `<CHASSIS_SN>.vcj` (e.g. `FCW2126G05V.vcj`) | yes | Cisco MASA-signed ownership voucher (RFC 8366). Binds the chassis SN to a pinned-domain-cert. |
| `pinned-domain-cert.crt` | yes | Self-signed root that issues the owner cert. **Must byte-match** the `pinned-domain-cert` field inside the voucher. |
| `pinned-domain-cert.key` | only to re-issue | Private key for the PDC. Only needed if you ever re-sign the owner cert. **Keep offline if possible.** |
| `owner-certificate.crt` | yes | EE cert signed by the PDC. Identifies you as the device owner. |
| `owner-certificate.key` | yes | Private key for the owner cert. sztpd uses it to sign the conveyed-information CMS. |
| `owner_cert_chain.cms` | yes | DER PKCS#7 degenerate bundle: owner-cert + PDC. Served to the switch in the response. |
| `owner_cert_chain.pem` | yes | Same chain in PEM form, used by various scripts. |

Cisco SUDI trust-anchor chains for **server-side mTLS** are also in
`local_files/` and are pre-built — no action needed:

| File | Use for |
|---|---|
| `act2_sudi_chain.cms` | C9300, C9200, ISR, ASR (ACT2 TAM, SHA-1) |
| `ha_sudi_chain.cms` | C9300X, C9500X, 8000V (HA-SUDI, SHA-256) |

### 3.1 Validate the bundle

```sh
scripts/validate-sztp-artifacts.sh
```

Passes all six checks before proceeding. Common failures:

- **`missing local_files/owner-certificate.key`** — sZTP cannot sign the
  CMS response without this. Recover from backup or re-issue (requires PDC
  key). If both PDC and owner keys are lost, you must generate a new PDC
  and request a fresh voucher from Cisco MASA against it.
- **`pinned-domain-cert byte-mismatch`** — your local PDC is not the one
  the voucher pins. The voucher is the source of truth.

### 3.2 Re-generating the owner cert (only when you have the PDC key)

```sh
cd local_files

openssl ecparam -name prime256v1 -genkey -noout -out owner-certificate.key
openssl req -new -key owner-certificate.key -out /tmp/owner.csr \
    -subj "/C=US/ST=California/L=San Jose/O=Cisco/OU=BU/CN=SZTP-Owner-Certificate"
openssl x509 -req -in /tmp/owner.csr \
    -CA pinned-domain-cert.crt -CAkey pinned-domain-cert.key \
    -CAcreateserial -out owner-certificate.crt -days 365 \
    -extfile <(printf "keyUsage=critical,digitalSignature\n")

cat owner-certificate.crt pinned-domain-cert.crt > owner_cert_chain.pem
openssl crl2pkcs7 -nocrl \
    -certfile owner-certificate.crt \
    -certfile pinned-domain-cert.crt \
    -out owner_cert_chain.cms -outform DER

cd .. && scripts/validate-sztp-artifacts.sh
```

> If you need to generate a brand-new PDC, do so **before** requesting the
> voucher — Cisco MASA embeds your PDC into the voucher and the voucher is
> immutable after issuance.

---

## 4. Device identity (SUDI) and registration

sZTPD identifies a device from its SUDI client cert. The relevant attribute
is the `Subject`'s `serialNumber` (OID 2.5.4.5), which on C9300/C9200 is:

```
serialNumber = PID:C9300-24T SN:FCW2126G05V
```

sztpd splits on the first space, so **the registration key is the PID**,
not the chassis SN. For our lab unit it is `C9300-24T`. (Older sztpd
builds register `PID:C9300-24T` with the prefix — confirm in the audit log
on the first attempt; see below.)

The chassis SN (`FCW2126G05V`) is used only to name the voucher file.

### 4.1 Templates already register the lab device

[config/sztpd.redirect.json.template](config/sztpd.redirect.json.template)
and [config/sztpd.running.json.template](config/sztpd.running.json.template)
each contain a `wn-sztpd-1:devices` entry keyed `"C9300-24T"`. Duplicate
that block for each new device.

### 4.2 Audit-log trick — find the exact key sztpd is looking for

After a failed attempt:

```sh
docker exec sztp-bootstrap-1 curl -s \
    -u my-admin@example.com:my-secret \
    'http://127.0.0.1:7080/restconf/ds/ietf-datastores:operational/wn-sztpd-1:audit-log' \
    -H 'Accept: application/yang-data+json' | python3 -m json.tool
```

Look for `"comment": "Device \"X\" not found for any tenant"` — the
quoted `X` is the exact value to put in `serial-number`.

---

## 5. Trust anchor selection

In **both** sztpd JSON templates, set:

```json
"local-truststore-reference": {
    "certificate-bag": "my-device-identity-ca-certs",
    "certificate": "my-device-identity-ca-cert-act2-sudi"
}
```

| Device generation | `certificate` value |
|---|---|
| C9300, C9200, ISR, ASR (ACT2 SUDI, SHA-1) | `my-device-identity-ca-cert-act2-sudi` |
| C9300X, C9500X, 8000V (HA-SUDI, SHA-256) | `my-device-identity-ca-cert-circa-2020` |

Identify your device on the switch:

```
Switch# show platform sudi certificate sign nonce 1
Switch# show crypto pki trustpool policy | include CA
```

- "Cisco Root CA 2048" + "ACT2 SUDI CA" → **ACT2** (use `act2-sudi`)
- "Cisco Root CA 2099" + "High Assurance SUDI CA" → **HA-SUDI** (use `circa-2020`)

---

## 6. DHCP option 143

### 6.1 The two non-negotiable rules

1. **RFC 8572 §8.2 binary framing.** IOS-XE 17.18 silently drops a plain
   `text`-encoded URL — the autoinstall log shows only `si-addr`, never
   `bootstrap-server-list:`. The on-the-wire bytes must be:

   ```
   uint16_BE_length || URI_bytes (UTF-8)        # repeated per URI
   ```

2. **Scheme + host + port only — no path.** The switch appends the RESTCONF
   path itself (`/restconf/operations/ietf-sztp-bootstrap-server:get-bootstrapping-data`).
   Including the path in option 143 produces a doubled URL and sztpd
   answers `404 Unrecognized RPC`. [dhcp/entrypoint.sh](dhcp/entrypoint.sh)
   and [scripts/sztp-preflight.sh](scripts/sztp-preflight.sh) both
   hard-refuse a path.

   - ✅ `https://10.1.1.3:8080` (redirecter)
   - ✅ `https://10.1.1.3:9090` (direct to bootstrap, skips redirect)
   - ❌ `https://10.1.1.3:9090/restconf/operations/...`

### 6.2 Two ways to serve option 143

Pick one. **Only one DHCP server may answer on the lab subnet.**

#### Option A — Container DHCP (the repo's happy path)

Stop any host DHCP first:

```sh
sudo systemctl disable --now isc-dhcp-server
```

Then start the stack with the `dhcp` profile:

```sh
docker compose --env-file config/catalyst/c9300.env --profile dhcp up -d
```

`dhcp/entrypoint.sh` renders option 143 with binary framing automatically
from `$SZTP_URL`.

#### Option B — Existing host `isc-dhcp-server` (when it serves other lab traffic)

Edit `/etc/dhcp/dhcpd.conf`:

```isc
# Add at top-level (outside any subnet block):
option sztp-redirect-urls code 143 = string;

subnet 10.1.1.0 netmask 255.255.255.0 {
    range 10.1.1.150 10.1.1.159;
    # ... existing options ...

    # sZTP RFC 8572 option 143 (binary-framed: uint16 BE length || URI).
    # URL: https://10.1.1.3:8080 (21 bytes).
    option sztp-redirect-urls 00:15:68:74:74:70:73:3a:2f:2f:31:30:2e:31:2e:31:2e:33:3a:38:30:38:30;

    # Remove or comment out any `option bootfile-name` (classic option 67
    # ZTP) — otherwise the switch may run classic ZTP instead of sZTP.
}
```

Generate the binary literal for any URL with:

```sh
scripts/encode_sztp_url.py 'https://HOST:PORT' --format isc
```

Validate and restart:

```sh
sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf
sudo systemctl restart isc-dhcp-server
```

### 6.3 Verify option 143 on the wire

```sh
sudo python3 - <<'PY'
from scapy.all import Ether, IP, UDP, BOOTP, DHCP, conf, AsyncSniffer, sendp
import binascii, time
conf.iface, conf.checkIPaddr = "ens19", False        # ← change to your lab iface
mac = "a0:f8:49:de:ad:bf"
hw = binascii.unhexlify(mac.replace(":", ""))
xid = 0xC0FFEE99
sn = AsyncSniffer(iface=conf.iface, filter="udp and (port 67 or port 68)", store=True)
sn.start(); time.sleep(0.3)
disc = (Ether(src=mac, dst="ff:ff:ff:ff:ff:ff") /
        IP(src="0.0.0.0", dst="255.255.255.255") /
        UDP(sport=68, dport=67) /
        BOOTP(chaddr=hw, xid=xid, flags=0x8000) /
        DHCP(options=[("message-type", "discover"),
                       ("param_req_list", [1, 3, 6, 15, 143]), "end"]))
sendp(disc, iface=conf.iface, verbose=0); time.sleep(2)
for p in sn.stop():
    if p.haslayer(DHCP) and p[BOOTP].xid == xid and p[BOOTP].op == 2:
        for o in p[DHCP].options:
            if isinstance(o, tuple) and o[0] == 143:
                print("option 143:", o[1])
PY
```

Expected:

```
option 143: b'\x00\x15https://10.1.1.3:8080'
```

If `option 143` is missing or shows quoted text instead of `\x00\x15…`,
fix it before reloading the switch.

---

## 7. Bring the stack up

Edit [config/catalyst/c9300.env](config/catalyst/c9300.env) for your lab:

```
SZTP_URL=https://10.1.1.3:8080
SZTP_DEVICE_SN=C9300-24T
SZTP_VOUCHER_FILE=/local_files/FCW2126G05V.vcj
SZTP_OWNER_CERT_FILE=/local_files/owner_cert_chain.cms
```

Then:

```sh
docker compose down --volumes --remove-orphans
docker compose --env-file config/catalyst/c9300.env up -d
```

Healthy state:

```sh
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Both `sztp-bootstrap-1` and `sztp-redirecter-1` must show `(healthy)`.

---

## 8. Preflight checks

```sh
scripts/sztp-preflight.sh --env-file config/catalyst/c9300.env
```

Each step is a one-line pass/fail with a concrete next action. The two
items that are **expected to fail when using host DHCP (Option B above)**
are `sztp-dhcp-1 not running` and the container-`dhcpd.conf` option-143
check — verify option 143 with the scapy probe in §6.3 instead.

You should also see `sitecustomize` patches loaded in the bootstrap log
(six lines):

```sh
docker logs sztp-bootstrap-1 2>&1 | grep -E 'sitecustomize:' | sort -u
```

```
sitecustomize: ssl patched (SECLEVEL=0, TLSv1.2 max, sigalgs pinned)
sitecustomize: certvalidator.ValidationContext weak_hash_algos cleared
sitecustomize: loaded owner-certificate from /local_files/owner_cert_chain.cms (...)
sitecustomize: loaded ownership-voucher from /local_files/FCW2126G05V.vcj
sitecustomize: obj_to_encoded_str patched to inject owner-certificate
sitecustomize: sztpd CMS output now fully signed (owner cert attached)
```

Anonymously probing the SBI should return **401 access-denied** — that's
correct (mTLS enforced):

```sh
SZTP_URL=https://10.1.1.3:8080 bash scripts/verify-sztp.sh
# → OK: 401 access-denied (mTLS enforced; endpoint and auth are healthy)
```

---

## 9. Reload the switch and watch

On the device console:

```
enable
write erase
yes
reload
no              ← do not save
yes             ← confirm
```

`write erase` is **mandatory**. IOS-XE persists "ZTP attempted" state in
NVRAM; without erasing it the device skips sZTP on the next boot.

After ~3 minutes the switch should onboard. Watch from the host:

```sh
docker logs -f sztp-bootstrap-1 2>&1 | grep -iE 'signed|onboard|injected|error|404'
```

And on the switch — **this is the only switch command you should need**:

```
show logging process sztp internal start last 20 minutes
```

Successful log sequence:

```
bootstrap-server-list: https://10.1.1.3:8080
Signature on ownership voucher's CMS structure has been verified
The certificate chain from the CMS structure for owner certificate verified
The conveyed info is signed
The conveyed info is json-formatted          ← OID 1.43 accepted
Conveyed info signature is verified
Received onboarding info
pre-script-complete  → config-complete  → post-script-complete  → bootstrap-complete
day0guestshell enabled successfully
```

The hostname changing on the switch (e.g. to `sztp-provisioning>`) is
the surest sign onboarding completed.

---

## 10. Why the sztpd container needs patches

`scripts/docker-entrypoint.sh` installs a `sitecustomize.py` via
`PYTHONPATH` that monkey-patches Python's `ssl` module and sztpd internals.
All six patches are required for IOS-XE 17.18 compatibility.

| # | Patch | Reason |
|---|---|---|
| 1 | `ssl SECLEVEL=0` | Python `ssl.create_default_context()` defaults to `@SECLEVEL=2`, which rejects SHA-1 CA signatures. Cisco Root CA 2048 and the ACT2 SUDI CA are SHA-1 signed (2005-era). |
| 2 | TLS 1.2 ceiling | TLS 1.3 requires RSA-PSS in `CertificateVerify`. Cisco ACT2 TAM hardware can only produce RSA PKCS#1 v1.5; the handshake fails as `WRONG_SIGNATURE_SIZE`. |
| 3 | Pin `sigalgs` to PKCS#1 v1.5 | Even on TLS 1.2 OpenSSL advertises RSA-PSS first; some Cisco clients pick the first algorithm regardless of TAM capability. |
| 4 | `certvalidator.ValidationContext.weak_hash_algos = set()` | After TLS, sztpd's `certvalidator 0.11.1` re-validates the chain and rejects SHA-1 unless this is cleared. |
| 5 | Wrap response as `SignedData` with **OID 1.2.840.113549.1.9.16.1.43** (id-ct-sztpConveyedInfoJSON) | sztpd 0.0.15 emits a bare `ContentInfo`. IOS-XE's OpenSSL `CMS_*` API only accepts `id-signedData`, and IOS-XE 17.x **only** parses the JSON conveyed-info OID (1.43) — OID 1.42 (XML) is rejected with `Failed to parse the conveyed info xml`. |
| 6 | Inject `owner-certificate` and `ownership-voucher` into the RPC response | sztpd 0.0.15 leaves both fields empty; IOS-XE 17.18 aborts with `Ownership voucher is missing` if either is absent. |

The YANG-JSON payload format IOS-XE accepts (built by patch 5):

```json
{
  "ietf-sztp-conveyed-info:onboarding-information": {
    "boot-image": { "...": "..." },
    "pre-configuration-script":  "<base64>",
    "configuration-handling":    "merge",
    "configuration":             "<base64>",
    "post-configuration-script": "<base64>"
  }
}
```

Top-level key **must** carry the `ietf-sztp-conveyed-info:` module-name
prefix.

---

## 11. Error → fix lookup table

| Log line (host or switch) | Root cause | Fix |
|---|---|---|
| Switch: only `si-addr` line, no `bootstrap-server-list` | Option 143 not delivered or `text`-encoded | [§6.3](#63-verify-option-143-on-the-wire) — confirm with scapy probe |
| Switch: `bootfile: http://...ztp-simple.py` appears | Classic ZTP option 67 wins over sZTP | Remove/disable `option bootfile-name` in the DHCP config |
| Host: `Server response is not signed` / 404 | Doubled URL — `SZTP_URL` has a path | Set `SZTP_URL=https://HOST:PORT` only |
| Host: `Failed to extract xml body from server response` | sitecustomize patches not loaded | Check `docker logs sztp-bootstrap-1 \| grep sitecustomize` — expect 6 lines |
| Host: `access-denied` (401) | Device PID not registered, or wrong key | Use the audit-log trick in [§4.2](#42-audit-log-trick--find-the-exact-key-sztpd-is-looking-for) |
| Switch: `CERTIFICATE_VERIFY_FAILED: CA signature digest algorithm too weak` | SECLEVEL≥2 rejects SHA-1 | Patch 1 (already in entrypoint) |
| Switch: `WRONG_SIGNATURE_SIZE` | RSA-PSS vs PKCS#1 v1.5 mismatch | Patches 2 & 3 |
| Switch: `Client cert ... does not validate using trust anchors` | Wrong truststore bag (ACT2 vs HA-SUDI) | [§5](#5-trust-anchor-selection) |
| Switch: `Failed to verify the certificate chain ... unable to get local issuer certificate` | Owner cert isn't signed by the voucher's PDC | [§3](#3-crypto-artifacts) — re-validate with `scripts/validate-sztp-artifacts.sh` |
| Switch: `Ownership voucher is missing` | Voucher not injected | Patch 6 + check `SZTP_OWNERSHIP_VOUCHER_CMS` env var |
| Switch: `Failed to parse the conveyed info xml: no redirect-information or onboarding-information nodes` | eContent OID is 1.42 (XML) — IOS-XE wants 1.43 (JSON) | Patch 5 — confirm `sitecustomize: sztpd CMS output now fully signed` is in logs |
| Switch: `The conveyed info is json-formatted` + `Conveyed info signature is verified` | **SUCCESS** |  |

---

## 12. New-device checklist

1. Confirm SUDI generation (ACT2 or HA-SUDI) — `show platform sudi certificate sign nonce 1`.
2. Place the Cisco MASA voucher at `local_files/<CHASSIS_SN>.vcj`.
3. Confirm `validate-sztp-artifacts.sh` passes — voucher's pinned-domain
   cert must match the local one, owner cert must chain to it, owner key
   must match owner cert.
4. Trigger one failed bootstrap to capture the exact registration key
   from the audit log (`Device "X" not found`).
5. Add that key to **both** `config/sztpd.redirect.json.template` and
   `config/sztpd.running.json.template`. Set the trust-anchor bag.
6. Set `SZTP_URL`, `SZTP_DEVICE_SN`, `SZTP_VOUCHER_FILE` in
   `config/catalyst/c9300.env`.
7. Decide DHCP path (host or container) and verify option 143 on the
   wire ([§6.3](#63-verify-option-143-on-the-wire)).
8. `docker compose --env-file config/catalyst/c9300.env up -d`.
9. `scripts/sztp-preflight.sh --env-file config/catalyst/c9300.env`.
10. `write erase` + reload the switch.
11. Hostname change is the success signal. If anything goes sideways,
    pull `show logging process sztp internal start last 20 minutes` and
    consult [§11](#11-error--fix-lookup-table).

---

## See also

- [AGENTS.md](AGENTS.md) — short, lab-specific operational notes
- [ZTP.md](ZTP.md) — generic ZTP / RFC 8572 background
- [dhcp/examples/README.md](dhcp/examples/README.md) — paste-ready DHCP snippets
- [RFC 8572](https://www.rfc-editor.org/rfc/rfc8572) — sZTP standard
- [RFC 8366](https://www.rfc-editor.org/rfc/rfc8366) — voucher format
