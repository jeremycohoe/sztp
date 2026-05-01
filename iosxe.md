# SZTP on Cisco IOS-XE — Complete Operational Guide

This document covers everything needed to take a **fresh checkout** of the
OPI sztp repository and successfully bootstrap a Cisco IOS-XE switch via SZTP.
It captures all the non-obvious requirements discovered during bring-up against
a **Cisco C9300-24T running IOS-XE 17.18.01**.

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [Prerequisites — what you must have before starting](#2-prerequisites)
3. [PKI setup](#3-pki-setup)
4. [Identifying the switch serial number](#4-identifying-the-switch-serial-number)
5. [Ownership voucher and owner certificate](#5-ownership-voucher-and-owner-certificate)
6. [Device registration](#6-device-registration)
7. [Trust anchor selection](#7-trust-anchor-selection)
8. [DHCP — option 143](#8-dhcp--option-143)
9. [Configuration and scripts](#9-configuration-and-scripts)
10. [Starting the stack](#10-starting-the-stack)
11. [What the entrypoint patches do (and why)](#11-what-the-entrypoint-patches-do-and-why)
12. [Verifying and debugging](#12-verifying-and-debugging)
13. [Console automation script](#13-console-automation-script)
14. [Error lookup table](#14-error-lookup-table)
15. [Checklist for a new device](#15-checklist-for-a-new-device)

---

## 1. Architecture

```
┌──────────┐  DHCP option 143 (URL)  ┌─────────────────┐
│ C9300 /  │ ──────────────────────▶ │  IOS upstream   │  :67 UDP
│ IOS-XE   │                         │  or ISC dhcpd   │
│  switch  │                         └─────────────────┘
│          │     mTLS RESTCONF
│          │ ──────────────────────▶ ┌─────────────────┐
│          │   POST get-bootstrap    │   redirecter    │  SBI :8080  NBI :7070
│          │ ◀── redirect-info ───── │   (sztpd)       │
│          │                         └─────────────────┘
│          │     mTLS RESTCONF
│          │ ──────────────────────▶ ┌─────────────────┐
│          │   POST get-bootstrap    │   bootstrap     │  SBI :9090  NBI :7080
│          │ ◀── onboarding-info ─── │   (sztpd)       │
└──────────┘                         └─────────────────┘
```

Both sztpd instances run from the same `docker.io/opiproject/sztpd:0.0.15`
image. The Go agent under `sztp-agent/` is a separate Linux/DPU client — it
is **not involved** in the IOS-XE flow.

---

## 2. Prerequisites

Before you run `docker-compose up` you need:

| Item | Where it comes from |
|------|---------------------|
| Cisco MASA-signed **ownership voucher** (`.vcj` file) | Cisco TAC / MASA API, one per device serial number |
| **Pinned-domain certificate** + private key | You generate this; the MASA uses it to create the voucher |
| **Owner certificate** + private key | You generate this, signed by the pinned-domain cert |
| IOS-XE switch reachable on a management network | Physical lab |
| Docker + docker-compose on the bootstrap host | Standard install |

Python package `paramiko` is needed only for the optional console test script:

```bash
pip install paramiko
```

---

## 3. PKI setup

### 3.1 Server certificates (generated automatically)

`docker-compose up` runs the `setup-cert` service which calls
`scripts/keys.sh` (or `setup-cert.sh`) to generate the SBI TLS certificates
under a named Docker volume (`server-certs`).  These are the certificates
that the switch validates during the mTLS handshake — they are **not** the
ownership/voucher certs.

### 3.2 Owner certificate chain (must be provided for IOS-XE)

IOS-XE requires a proper ownership voucher and a matching owner certificate
chain.  These go into `local_files/` and are referenced by environment
variables in `docker-compose.yml`.

**Step 1 — generate the pinned-domain cert (self-signed root for the owner chain):**

```bash
openssl ecparam -name prime256v1 -genkey -noout -out local_files/pinned-domain-cert.key

openssl req -new -x509 -key local_files/pinned-domain-cert.key \
  -out local_files/pinned-domain-cert.crt \
  -days 365 \
  -subj "/C=US/ST=California/L=San Jose/O=Cisco/OU=BU/CN=SZTP-Pinned-Domain-Cert"
```

> **Critical**: the byte-for-byte content of `pinned-domain-cert.crt` must
> match the `pinned-domain-cert` field inside the ownership voucher that
> Cisco's MASA signs.  Generate this cert **first**, then submit it to the
> MASA to get the voucher.

**Step 2 — generate the owner certificate (signed by the pinned-domain cert):**

```bash
openssl ecparam -name prime256v1 -genkey -noout -out local_files/owner-certificate.key

openssl req -new -key local_files/owner-certificate.key \
  -out /tmp/owner.csr \
  -subj "/C=US/ST=California/L=San Jose/O=Cisco/OU=BU/CN=SZTP-Owner-Certificate"

openssl x509 -req -in /tmp/owner.csr \
  -CA local_files/pinned-domain-cert.crt \
  -CAkey local_files/pinned-domain-cert.key \
  -CAcreateserial \
  -out local_files/owner-certificate.crt \
  -days 365 \
  -extfile <(printf "keyUsage=critical,digitalSignature\n")
```

**Step 3 — build the owner certificate chain bundle (DER PKCS#7 + PEM):**

```bash
# PEM bundle: owner cert first, then pinned-domain cert
cat local_files/owner-certificate.crt local_files/pinned-domain-cert.crt \
    > local_files/owner_cert_chain.pem

# DER PKCS#7 degenerate SignedData (no content, just certs)
openssl crl2pkcs7 -nocrl \
  -certfile local_files/owner-certificate.crt \
  -certfile local_files/pinned-domain-cert.crt \
  -out local_files/owner_cert_chain.cms -outform DER
```

### 3.3 Trust anchor CMS files for SUDI validation

These are **Cisco public CA chains** — they authenticate the switch's SUDI
certificate, not the owner chain.  Two pre-built files are in `local_files/`:

| File | Contents | Use |
|------|----------|-----|
| `local_files/act2_sudi_chain.cms` | Cisco Root CA 2048 + ACT2 SUDI CA (SHA-1) | C9300, C9200, ISR, ASR (older) |
| `local_files/ha_sudi_chain.cms` | Cisco Root CA 2099 + High Assurance SUDI CA (SHA-256) | C9300X, C9500X, 8000V (newer) |

The `scripts/keys.sh` script copies the right one into the `server-certs`
volume as `ta_cert_chain_act2.cms`.  Both files are included in
`local_files/` — you do not need to generate them, but you must pick the
right one (see §7).

---

## 4. Identifying the switch serial number

sztpd extracts the device identity from the SUDI certificate's `Subject`
field using OID `2.5.4.5` (serialNumber).  On Cisco C9300/C9200 the value is:

```
PID:C9300-24T SN:FCW2129G03A
```

sztpd's extraction logic takes the portion **before the first space**, giving
`PID:C9300-24T` — which is **the PID, not the chassis serial number**.

To confirm what your device will present, trigger a failed bootstrap attempt
and read the audit log:

```bash
docker exec sztp-bootstrap-1 curl -s --user my-admin@example.com:my-secret \
  'http://127.0.0.1:7080/restconf/ds/ietf-datastores:operational/wn-sztpd-1:audit-log' \
  -H 'Accept: application/yang-data+json' | python3 -m json.tool
```

Look for `"comment": "Device \"X\" not found"` — `X` is the key sztpd
is searching for.

Alternatively, if you have the SUDI chain PEM:

```bash
openssl x509 -in sudi-leaf.pem -noout -subject -nameopt multiline \
  | grep serialNumber
# → serialNumber = PID:C9300-24T SN:FCW2129G03A
# Registration key = "PID:C9300-24T SN:FCW2129G03A".split(" ")[0]  → "PID:C9300-24T"
```

> **Note**: Some platforms use the chassis SN directly.  Always verify with
> a trial run before committing to config templates.

---

## 5. Ownership voucher and owner certificate

### 5.1 Getting the voucher from Cisco MASA

The ownership voucher (`.vcj`) is a CMS SignedData structure that Cisco's
MASA (Manufacturer Authorized Signing Authority) issues.  It cryptographically
binds a device serial number to a pinned-domain certificate.

You need:
1. The **device serial number** (chassis SN, e.g. `FCW2129G03A`)
2. The **pinned-domain certificate** you generated in §3.2 step 1

Submit both to Cisco TAC or through the appropriate MASA API.  The result is
a `.vcj` file, one per device.

Place it at:

```
local_files/<CHASSIS_SN>.vcj        # e.g. local_files/FCW2129G03A.vcj
```

> The voucher is tied to the **chassis SN** (`FCW2129G03A`), not the PID.
> The device registration key in sztpd (§6) uses the PID extracted from
> the SUDI cert.  These are two different identifiers.

### 5.2 Environment variables

`docker-compose.yml` wires the local_files paths through these env vars on
both the `bootstrap` and `redirecter` services:

| Variable | File | Purpose |
|----------|------|---------|
| `SZTP_OWNERSHIP_VOUCHER_CMS` | `local_files/<SN>.vcj` | Cisco MASA-signed voucher |
| `SZTP_OWNER_CERT_CMS` | `local_files/owner_cert_chain.cms` | DER PKCS#7 of owner + pinned-domain cert |
| `CMS_OWNER_KEY` | `local_files/owner-certificate.key` | Private key matching the owner cert |
| `CMS_OWNER_CERT` | `local_files/owner-certificate.crt` | Owner certificate (leaf) |
| `CMS_OWNER_CERT_CHAIN` | `local_files/owner_cert_chain.pem` | PEM bundle: owner cert + pinned-domain cert |

---

## 6. Device registration

Each device must be registered in **both** the redirecter and bootstrap
sztpd instances. The easiest way is to edit the JSON templates directly so
the registration survives container restarts.

### 6.1 In `config/sztpd.redirect.json.template`

Find the `"wn-sztpd-1:devices"` section and add an entry:

```json
{
  "serial-number": "PID:C9300-24T SN:FCW2129G03A",
  "device-type": "my-device-type",
  "response-manager": {
    "matched-response": [
      {
        "name": "catch-all-response",
        "response": {
          "conveyed-information": {
            "redirect-information": {
              "reference": "my-redirect-information"
            }
          }
        }
      }
    ]
  }
}
```

### 6.2 In `config/sztpd.running.json.template`

Same structure but the response references onboarding:

```json
{
  "serial-number": "PID:C9300-24T SN:FCW2129G03A",
  "device-type": "my-device-type",
  "response-manager": {
    "matched-response": [
      {
        "name": "catch-all-response",
        "response": {
          "conveyed-information": {
            "onboarding-information": {
              "reference": "first-onboarding-information"
            }
          }
        }
      }
    ]
  }
}
```

> The existing templates pre-register `FCW2129G03A` and `C9300-24T` as
> examples.  Copy the shape for your device's extracted serial number.

---

## 7. Trust anchor selection

The `device-type` in the JSON templates includes a
`local-truststore-reference` that points at the certificate bag used to
validate the device's SUDI during mTLS.

| Device generation | Certificate bag to reference | Cisco CA chain |
|---|---|---|
| C9300, C9200, ISR, ASR (ACT2 TAM) | `my-device-identity-ca-cert-act2-sudi` | Cisco Root CA 2048 + ACT2 SUDI CA (SHA-1) |
| C9300X, C9500X, 8000V (HA-SUDI) | `my-device-identity-ca-cert-circa-2020` | Cisco Root CA 2099 + HA SUDI CA (SHA-256) |

To identify your device's generation:

```
Switch# show crypto pki trustpool policy | include CA
Switch# show platform sudi certificate sign nonce 1
```

In both `sztpd.redirect.json.template` and `sztpd.running.json.template`,
set the `"certificate"` field under `"local-truststore-reference"`:

```json
"local-truststore-reference": {
  "certificate-bag": "my-device-identity-ca-certs",
  "certificate": "my-device-identity-ca-cert-act2-sudi"
}
```

Both template files must be updated.

---

## 8. DHCP — option 143

### 8.1 URI format requirement

IOS-XE's option 143 parser has a short per-URI buffer.  Send
**scheme + host + port only** — the switch appends the RESTCONF path itself.
Including the full path (`/restconf/operations/...`) causes a buffer overflow
and the option is silently discarded.

```
# CORRECT
https://10.1.1.3:8080

# WRONG — causes "string copy failed for SZTP Bootstrap server URI list"
https://10.1.1.3:8080/restconf/operations/ietf-sztp-bootstrap-server:get-bootstrapping-data
```

### 8.2 Using the bundled ISC dhcpd (Docker)

Edit `docker-compose.yml` and set the subnet variables for your lab:

```yaml
environment:
  NODE_IP_SUBNET: 10.1.1.0
  NODE_IP_NETMASK: 255.255.255.0
  NODE_IP_RANGE_MIN: 10.1.1.100
  NODE_IP_RANGE_MAX: 10.1.1.253
  NODE_IP_ADDRESS: 10.1.1.3    # IP of the bootstrap host
```

The DHCP container is gated behind the `dhcp` profile and uses host
networking so it can receive physical broadcasts:

```bash
docker-compose --profile dhcp up -d dhcp
```

The `dhcpd.conf.template` generates:

```
option sztp-redirect-urls "https://10.1.1.3:8080";
```

### 8.3 Using an upstream IOS switch as DHCP server

This is how the lab is currently configured.  On the upstream IOS switch:

```
! Option 143 in hex:  length(1B) + ASCII("https://10.1.1.3:9090")
! "https://10.1.1.3:9090" = 21 chars = 0x15
ip dhcp pool SZTP
   network 10.1.1.0 255.255.255.0
   default-router 10.1.1.1

! Option 143 (SZTP) hex encoding:  00 15 = length 21, then ASCII of the URL
option 143 hex 0015.6874.7470.733a.2f2f.3130.2e31.2e31.2e33.3a39.3039.30
```

> In this lab `opt 143` points **directly at the bootstrap SBI port 9090**
> (bypassing the redirecter) because the redirecter and bootstrap share the
> same host.  If you want the full redirect flow, point to port 8080.

---

## 9. Configuration and scripts

### 9.1 NETCONF configuration XML

Files in `config/` (e.g. `first-configuration.xml`) are NETCONF `<config>`
documents using the `Cisco-IOS-XE-native` YANG model.  They are base64-encoded
by `docker-entrypoint.sh` and embedded in the onboarding payload.

```xml
<config xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
  <native xmlns="http://cisco.com/ns/yang/Cisco-IOS-XE-native">
    <hostname>my-device-hostname</hostname>
    <!-- ... -->
  </native>
</config>
```

### 9.2 Pre- and post-configuration scripts

Scripts in `config/` (e.g. `first-pre-configuration-script.sh`) are
**Python 3 scripts** executed by the IOS-XE embedded Python interpreter.
They use the `cli` module to run IOS-XE CLI commands:

```python
#!/usr/bin/python3
from cli import configurep, executep

configurep(["hostname sztp-provisioning", "end"])
executep("show version | include Serial")
```

The shebang **must** be `#!/usr/bin/python3` (not `#!/bin/bash`).  IOS-XE
runs the script via its own Python runtime, not a shell.

Files are base64-encoded automatically by `docker-entrypoint.sh`.

---

## 10. Starting the stack

```bash
# Generate certificates and start all services
docker-compose down --volumes --remove-orphans
docker-compose up --build --force-recreate -d

# Watch bootstrap and redirecter logs
docker-compose logs -f bootstrap redirecter
```

After startup, verify the bootstrap server is healthy:

```bash
docker exec sztp-bootstrap-1 curl -s \
  -H 'Accept: application/yang-data+json' \
  http://127.0.0.1:7080/.well-known/host-meta
```

---

## 11. What the entrypoint patches do (and why)

`scripts/docker-entrypoint.sh` installs a `sitecustomize.py` via `PYTHONPATH`
that monkey-patches Python's `ssl` module and sztpd internals.  **All patches
are required for IOS-XE compatibility.  Do not remove any of them.**

### Patch 1 — SSL SECLEVEL=0

**Why**: Python's `ssl.create_default_context()` uses `@SECLEVEL=2` which
rejects SHA-1 CA signatures.  Cisco Root CA 2048 and the ACT2 SUDI CA are
SHA-1 signed (2005-era).

**Fix**: monkey-patch `create_default_context` to call
`ctx.set_ciphers("DEFAULT:@SECLEVEL=0")`.

### Patch 2 — TLS 1.2 maximum

**Why**: TLS 1.3 requires RSA-PSS for `CertificateVerify`.  Cisco's ACT2 TAM
hardware can only produce RSA PKCS#1 v1.5 signatures.  The switch sends a
valid PKCS#1 v1.5 signature which the server rejects as `WRONG_SIGNATURE_SIZE`.

**Fix**: force `ctx.maximum_version = ssl.TLSVersion.TLSv1_2`.

### Patch 3 — Pin sigalgs to PKCS#1 v1.5

**Why**: Even on TLS 1.2, OpenSSL's default `sigalgs_list` advertises RSA-PSS
before PKCS#1.  Some Cisco clients pick the first algorithm in the server's
advertised list regardless of what the TAM can produce.

**Fix**: call `SSL_CTX_ctrl(SSL_CTRL_SET_SIGALGS_LIST=98)` and
`SSL_CTX_ctrl(SSL_CTRL_SET_CLIENT_SIGALGS_LIST=102)` with:

```
RSA+SHA256:RSA+SHA384:RSA+SHA512:ECDSA+SHA256:ECDSA+SHA384:ECDSA+SHA512:RSA+SHA1:ECDSA+SHA1
```

### Patch 4 — certvalidator SHA-1 allowance

**Why**: After TLS succeeds, sztpd re-validates the client cert chain using
`certvalidator` 0.11.1, which has `weak_hash_algos = {"md2", "md5", "sha1"}`.
This rejects the ACT2 SUDI CA whose signature is SHA-1.

**Fix**: monkey-patch `certvalidator.ValidationContext.__init__` to default
`weak_hash_algos=set()`.

### Patch 5 — CMS SignedData wrapper + JSON OID (the critical one)

**Why (two sub-problems)**:

1. `sztpd 0.0.15` emits a bare `ContentInfo` with
   `contentType = 1.2.840.113549.1.9.16.1.42` (id-ct-sztpConveyedInfoXML).
   IOS-XE's SZTP client calls OpenSSL `CMS_*` functions which only accept
   `id-signedData` as the outer content type.

2. IOS-XE 17.x uses **OID `1.2.840.113549.1.9.16.1.43`
   (id-ct-sztpConveyedInfoJSON)** to identify the payload format.  OID 1.42
   (XML) triggers the XML parser which fails with
   `"Failed to parse the conveyed info xml: no redirect-information or
   onboarding-information nodes"` — regardless of which XML namespace you
   use.  The fix is to use the JSON OID and a JSON payload.

**Fix**: intercept `sztpd.rfc8572.encode_der`, convert the inner XML payload
to YANG-JSON format, set the eContent OID to 1.43, and re-wrap everything as
a proper `SignedData` with one ECDSA-SHA256 `SignerInfo`.

The **YANG-JSON payload format** that IOS-XE accepts:

```json
{
  "ietf-sztp-conveyed-info:onboarding-information": {
    "boot-image": {
      "download-uri": ["https://web:443/image.img"],
      "image-verification": [{
        "hash-algorithm": "ietf-sztp-conveyed-info:sha-256",
        "hash-value": "7b:ca:..."
      }]
    },
    "pre-configuration-script": "<base64>",
    "configuration-handling": "merge",
    "configuration": "<base64>",
    "post-configuration-script": "<base64>"
  }
}
```

Key rules:
- Top-level key **must** use the module-name prefix `ietf-sztp-conveyed-info:`
- `hash-algorithm` **must** use the module-name prefix
- Scripts and config are base64-encoded strings (same as in the XML)

### Patch 6 — Ownership voucher and owner-certificate injection

**Why**: `sztpd 0.0.15` never populates the `owner-certificate` or
`ownership-voucher` fields in its RPC response.  IOS-XE 17.18 logs
`"Ownership voucher is missing"` and aborts if either field is absent.

**Fix**: patch `sztpd.yangcore.utils.obj_to_encoded_str` to splice the
`<owner-certificate>` and `<ownership-voucher>` elements into the response
dict before sztpd serializes it to XML.  The bytes are loaded from the files
referenced by the `SZTP_OWNERSHIP_VOUCHER_CMS` and `SZTP_OWNER_CERT_CMS`
environment variables.

---

## 12. Verifying and debugging

### Bootstrap audit log

```bash
docker exec sztp-bootstrap-1 curl -s \
  --user my-admin@example.com:my-secret \
  'http://127.0.0.1:7080/restconf/ds/ietf-datastores:operational/wn-sztpd-1:audit-log' \
  -H 'Accept: application/yang-data+json' | python3 -m json.tool
```

A successful bootstrap shows `"outcome": "success"` with the device IP in
`source-ip`.

### Decode the last response served to the switch

```bash
docker exec sztp-bootstrap-1 python3 - <<'PY'
import re, base64, json
from pyasn1.codec.der.decoder import decode as d
from pyasn1_modules import rfc5652
xml = open('/tmp/sztp_last_response.xml','rb').read()
ci_b64 = re.search(rb'<conveyed-information>([^<]+)<', xml).group(1)
ci_der = base64.b64decode(b''.join(ci_b64.split()))
ci, _ = d(ci_der, asn1Spec=rfc5652.ContentInfo())
print('outer OID:', ci['contentType'])       # should be 1.2.840.113549.1.7.2
sd, _ = d(bytes(ci['content']), asn1Spec=rfc5652.SignedData())
print('eContent OID:', sd['encapContentInfo']['eContentType'])  # should be ...1.43
print('embedded certs:', len(sd['certificates']))               # should be 2
inner = bytes(sd['encapContentInfo']['eContent'])
print('inner content:', inner[:300].decode('utf-8', errors='replace'))
PY
```

### Verify CMS signature with OpenSSL

```bash
docker exec sztp-bootstrap-1 python3 - <<'PY'
import re, base64
from pyasn1.codec.der.decoder import decode as d
from pyasn1_modules import rfc5652
xml = open('/tmp/sztp_last_response.xml','rb').read()
ci_b64 = re.search(rb'<conveyed-information>([^<]+)<', xml).group(1)
open('/tmp/last.cms','wb').write(base64.b64decode(b''.join(ci_b64.split())))
print("wrote /tmp/last.cms")
PY
docker cp sztp-bootstrap-1:/tmp/last.cms /tmp/last.cms
openssl cms -inform DER -verify -in /tmp/last.cms \
    -CAfile local_files/pinned-domain-cert.crt -out /dev/null
```

### Container logs

```bash
docker-compose logs -f bootstrap     # sitecustomize debug prints go here
docker-compose logs -f redirecter
```

The `sitecustomize.py` prints a line for every key patch:

```
sitecustomize: ssl patched (SECLEVEL=0, TLSv1.2 max, sigalgs pinned)
sitecustomize: certvalidator.ValidationContext weak_hash_algos cleared
sitecustomize: sztpd CMS output now fully signed (owner cert attached)
sitecustomize: rev8 JSON eContent for onboarding-information, len=6797
sitecustomize: injected owner-certificate + ownership-voucher into RPC output
```

### On the switch

```
Switch# show logging process sztp internal start last 10 minutes
Switch# debug sztp all
Switch# debug crypto pki transactions
```

Successful IOS-XE log sequence:

```
The device trust anchor is verified
Signature on ownership voucher's CMS structure has been verified.
The certificate chain from the CMS structure for owner certificate verified
The conveyed info is signed
The conveyed info is json-formatted          ← OID 1.43 accepted
Conveyed info signature is verified
day0guestshell enabled successfully          ← pre-config script ran
```

---

## 13. Console automation script

`scripts/sztp_console_test.py` connects to the switch via conserver over SSH,
navigates the IOS-XE setup wizard, pulls the SZTP log, and optionally issues
`pnpa service reset no-prompt` to trigger a new test cycle.

```bash
# Pull the current SZTP log (last 30 min)
python3 scripts/sztp_console_test.py --pull-log-only --minutes 30

# Reset the switch and collect the post-reload log
python3 scripts/sztp_console_test.py

# Just reset, skip log collection
python3 scripts/sztp_console_test.py --reset-only
```

Configuration at the top of the script:

```python
CONSERVER_HOST = "128.107.223.248"
CONSERVER_USER = "auto"
CONSERVER_PASS = "G0ldl@bs247"
CONSOLE_NAME   = "ts199-line28"
ENABLE_PASS    = "EN-TME-Cisco123"
```

The script handles any IOS-XE hostname prompt (not just `Switch#`) so it
works correctly after SZTP renames the device.

---

## 14. Error lookup table

| Log line | Root cause | Fix |
|----------|-----------|-----|
| `CERTIFICATE_VERIFY_FAILED: CA signature digest algorithm too weak` | SECLEVEL≥2 rejects SHA-1 Cisco Root CA 2048 | Patch 1 (already in entrypoint) |
| `WRONG_SIGNATURE_SIZE` on TLS 1.3 | ACT2 TAM sends PKCS#1 v1.5, TLS 1.3 requires PSS | Patch 2 |
| `WRONG_SIGNATURE_SIZE` on TLS 1.2 | Server sigalgs advertises PSS before PKCS#1 | Patch 3 |
| `Client cert ... does not validate using trust anchors` | Wrong truststore bag (ACT2 vs HA-SUDI), or certvalidator rejects SHA-1 | §7 + Patch 4 |
| `Device "X" not found for any tenant` | Device not registered or wrong serial number extracted from SUDI | §4 + §6 |
| `Unable to init CMS data` / `Failed to verify conveyed info` | bare ContentInfo, not SignedData | Patch 5 |
| `The conveyed info is signed, however owner certificate is missing` | SignedData has no SignerInfo or no embedded cert | Patch 5 |
| `Ownership voucher is missing` | sztpd 0.0.15 does not serve RFC 8366 vouchers | Patch 6 + §5 |
| `Failed to verify the certificate chain ... unable to get local issuer certificate` | Owner cert chain does not end at the voucher's pinned-domain-cert | §3.2 + §5 — ensure owner cert is signed by the exact pinned-domain cert the MASA used |
| `Failed to parse the conveyed info xml: no redirect-information or onboarding-information nodes` | eContent OID is 1.42 (XML), IOS-XE expects 1.43 (JSON) | Patch 5 — check entrypoint rev8 JSON conversion is active |
| `The conveyed info is xml-formatted` (note, not error) followed by parse failure | Same as above — OID 1.42 was served | Patch 5 |
| `The conveyed info is json-formatted` (note) + `Conveyed info signature is verified` | **SUCCESS** — payload accepted |  |

---

## 15. Checklist for a new device

1. **Identify SUDI generation** — ACT2 (SHA-1) or HA-SUDI (SHA-256)?  Check
   `show platform sudi certificate sign nonce 1` on the switch.

2. **Extract the registration key** — run a failed bootstrap attempt, read
   the audit log `comment` field for `Device "X" not found`.  Use `X` as the
   `serial-number` value in the templates.

3. **Get the ownership voucher** from Cisco MASA using the chassis SN and
   your pinned-domain certificate.  Place at `local_files/<CHASSIS_SN>.vcj`.

4. **Generate owner certificate** chain signed by the pinned-domain cert
   used for the voucher (§3.2).

5. **Update `config/sztpd.redirect.json.template`**:
   - Set `local-truststore-reference.certificate` to `act2-sudi` or
     `circa-2020` per step 1.
   - Add a `device` entry with the registration key from step 2.

6. **Update `config/sztpd.running.json.template`** — same as step 5.

7. **Update `docker-compose.yml`** env vars to point at the correct
   `local_files/` paths for `SZTP_OWNERSHIP_VOUCHER_CMS`, `SZTP_OWNER_CERT_CMS`,
   `CMS_OWNER_KEY`, `CMS_OWNER_CERT`, `CMS_OWNER_CERT_CHAIN`.

8. **Set DHCP option 143** to `https://<bootstrap-host-ip>:8080` (redirecter)
   or `https://<bootstrap-host-ip>:9090` (direct to bootstrap).  Use only
   scheme + host + port, no path.

9. **Start the stack**:

   ```bash
   docker-compose down --volumes --remove-orphans
   docker-compose up --build --force-recreate -d
   ```

10. **Reload the switch** and watch:

    ```bash
    # Bootstrap audit log (poll every 2s)
    watch -n 2 "docker exec sztp-bootstrap-1 curl -s \
      --user my-admin@example.com:my-secret \
      'http://127.0.0.1:7080/restconf/ds/ietf-datastores:operational/wn-sztpd-1:audit-log' \
      -H 'Accept: application/yang-data+json' | python3 -m json.tool | tail -20"

    # Bootstrap container logs
    docker-compose logs -f bootstrap
    ```

11. **Confirm success** — audit log shows `"outcome": "success"` from the
    device IP, and the switch console shows the hostname changing and
    `day0guestshell enabled successfully`.
