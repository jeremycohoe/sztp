# Working IOS-XE bootstrap — fork overlay guide

The upstream `opiproject/sztp` repo (after the enablement PR) makes IOS-XE
**testable and documented**: the `sztp-agent option143` encoder, the opt-in
`iosxe` Compose profile, the Catalyst env bundles, the preflight/validator
scripts, and the `IOSXE.md` quickstart.

A **fully working zero-touch bootstrap** of a real Catalyst switch needs a few
things that are *deliberately not upstreamed* (they are vendor/environment
specific). This guide is the overlay: what to add on top of a clean upstream
clone, and why.

## What the overlay adds

| Area | File(s) | Why IOS-XE needs it |
| --- | --- | --- |
| sztpd TLS/CMS patch | `scripts/docker-entrypoint.sh` | Injects a runtime `sitecustomize.py` that lowers OpenSSL `SECLEVEL` (accept Cisco Root CA 2048 / SHA-1), pins sigalgs to PKCS#1 v1.5, caps TLS 1.2, clears `certvalidator` weak-hash rejection, and re-signs the conveyed-info as **signed-JSON CMS (SignedData)** — IOS-XE rejects the default XML (OID `…1.42`) and has no unsigned path. Also injects the ownership voucher + owner cert. |
| sztpd templates | `config/sztpd.redirect.json.template`, `config/sztpd.running.json.template` | CMS owner/voucher placeholders the entrypoint fills. |
| Compose wiring | `docker-compose.yml` | Mounts `./local_files:/local_files:ro` and sets `SZTP_OWNERSHIP_VOUCHER_CMS`, `SZTP_OWNER_CERT_CMS`, `CMS_OWNER_KEY/CERT/CHAIN` on `bootstrap`/`redirecter`. |
| Server PKI | `scripts/setup-cert.sh`, `config/openssl-tls12.cnf` | Builds the SBI server cert as **RSA-2048** (IOS-XE sZTP rejects ECDSA) against the Cisco trust anchors. |
| Cisco SUDI trust anchors (public) | `local_files/act2_sudi_chain.*`, `cisco_sudi_ta_chain.*`, `ha_sudi_chain.*`, `crca2048.pem`, `crca2099.pem`, `hasudi.pem` | The ACT2 (SHA-1) and HA-SUDI (SHA-256) CA chains the server validates the device's SUDI client cert against. These are public Cisco CA certs. |

### Operator-supplied secrets (never committed anywhere)

| File | Source |
| --- | --- |
| `local_files/<chassis-sn>.vcj` | MASA-signed ownership voucher (RFC 8366) for the device. |
| `local_files/owner-certificate.crt` / `.key` | Your owner certificate + private key. |
| `local_files/pinned-domain-cert.crt` | The pinned-domain-cert the voucher pins. |
| `local_files/owner_cert_chain.cms` / `.pem` | Owner + pinned-domain chain. |

## Apply the overlay to a clean upstream clone

```sh
git clone https://github.com/opiproject/sztp.git
cd sztp
git remote add fork https://github.com/jeremycohoe/sztp.git
git fetch fork

# Overlay the sztpd patch + PKI + templates + compose wiring from the fork:
git checkout fork/main -- \
  scripts/docker-entrypoint.sh \
  scripts/setup-cert.sh \
  config/openssl-tls12.cnf \
  config/sztpd.redirect.json.template \
  config/sztpd.running.json.template \
  docker-compose.yml

# Public Cisco SUDI trust-anchor chains:
git checkout fork/main -- \
  local_files/act2_sudi_chain.cms local_files/act2_sudi_chain.pem \
  local_files/cisco_sudi_ta_chain.cms local_files/cisco_sudi_ta_chain.pem \
  local_files/ha_sudi_chain.cms local_files/ha_sudi_chain.pem \
  local_files/crca2048.pem local_files/crca2099.pem local_files/hasudi.pem
```

Then drop your **per-device secrets** into `local_files/` (voucher, owner
cert/key, pinned-domain-cert) and validate:

```sh
scripts/validate-sztp-artifacts.sh local_files
```

## Bring up and verify

```sh
# Pick the env bundle matching the device's SUDI generation:
#   ACT2 (SHA-1):     config/catalyst/c9300.env   (C9200/C9300)
#   HA-SUDI (SHA-256): config/catalyst/c9300x.env  (C9300X/C9500X)
docker compose --env-file config/catalyst/c9300.env --profile iosxe up -d

scripts/sztp-preflight.sh --env-file config/catalyst/c9300.env
```

Confirm the sztpd patch loaded:

```sh
docker logs sztp-bootstrap-1 | grep sitecustomize   # expect the SSL/CMS lines
```

Boot the switch and watch the one log:

```text
Switch# show logging process sztp internal start last 20 minutes
```

**Success signal:** the hostname changes after onboarding. The error → fix
table in the fork's `IOSXE.md` maps every common failure to its patch.

## Maintenance

Keep this overlay thin. When upstream bumps the sztpd image or restructures
Compose, re-check `scripts/docker-entrypoint.sh` and the compose wiring against
the new base. Everything else (encoder, profile, env bundles, validators) lives
upstream and needs no fork maintenance.
