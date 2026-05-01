# Quick Start — IOS-XE SZTP Bootstrap

**New to SZTP on IOS-XE?** Start here. This is a streamlined checklist for getting a
Cisco switch bootstrapped in ~5 minutes (not including waiting for the device to reload).

For comprehensive details, see [IOSXE.md](IOSXE.md).

---

## Prerequisites Checklist

Before you begin, make sure you have:

- [ ] Docker + docker-compose on your bootstrap host
- [ ] A Cisco C9300, C9200, ISR, or ASR switch on a management network
- [ ] The switch's **ownership voucher** (`.vcj` file) from Cisco MASA
- [ ] The **pinned-domain certificate** and private key used to create the voucher
- [ ] DHCP option 143 configured to point to the bootstrap host
- [ ] SSH access to conserver (optional, for console automation)

---

## 5-Minute Setup

### 1. Generate owner certificate chain (if starting from scratch)

```bash
cd local_files

# Pinned-domain cert (self-signed root)
openssl ecparam -name prime256v1 -genkey -noout -out pinned-domain-cert.key
openssl req -new -x509 -key pinned-domain-cert.key \
  -out pinned-domain-cert.crt -days 365 \
  -subj "/C=US/ST=California/L=San Jose/O=Cisco/OU=BU/CN=SZTP-Pinned-Domain-Cert"

# Owner cert (signed by pinned-domain)
openssl ecparam -name prime256v1 -genkey -noout -out owner-certificate.key
openssl req -new -key owner-certificate.key -out /tmp/owner.csr \
  -subj "/C=US/ST=California/L=San Jose/O=Cisco/OU=BU/CN=SZTP-Owner-Certificate"
openssl x509 -req -in /tmp/owner.csr \
  -CA pinned-domain-cert.crt -CAkey pinned-domain-cert.key \
  -CAcreateserial -out owner-certificate.crt -days 365 \
  -extfile <(printf "keyUsage=critical,digitalSignature\n")

# Build PEM + DER PKCS#7 chains
cat owner-certificate.crt pinned-domain-cert.crt > owner_cert_chain.pem
openssl crl2pkcs7 -nocrl \
  -certfile owner-certificate.crt \
  -certfile pinned-domain-cert.crt \
  -out owner_cert_chain.cms -outform DER

cd ..
```

**Or** if you already have these files, ensure they're in `local_files/` and the filenames match
the env vars in `docker-compose.yml` (see §5 in IOSXE.md).

### 2. Get the ownership voucher

Submit the **chassis serial number** and **pinned-domain cert** to Cisco MASA.
You'll receive a `.vcj` file (e.g. `FCW2129G03A.vcj`).
Place it in `local_files/`.

### 3. Identify device serial number and trust anchor

On the switch:

```
Switch# show platform sudi certificate sign nonce 1
Switch# show crypto pki trustpool policy | include CA
```

- If you see "Cisco Root CA 2048" + "ACT2 SUDI CA" → **ACT2** device (older)
- If you see "Cisco Root CA 2099" + "High Assurance SUDI CA" → **HA-SUDI** device (newer)

Then trigger a failed bootstrap to find the registration key:

```bash
# On bootstrap host:
docker-compose up --build --force-recreate -d
# Reload switch, wait 30 seconds, then:
docker exec sztp-bootstrap-1 curl -s \
  --user my-admin@example.com:my-secret \
  'http://127.0.0.1:7080/restconf/ds/ietf-datastores:operational/wn-sztpd-1:audit-log' \
  -H 'Accept: application/yang-data+json' | python3 -m json.tool
```

Look for: `"comment": "Device \"PID:C9300-24T SN:FCW2129G03A\" not found"`.
The quoted string is your **registration key**.

### 4. Update config templates

**In `config/sztpd.redirect.json.template`** — find `"wn-sztpd-1:devices"` and add:

```json
{
  "serial-number": "PID:C9300-24T SN:FCW2129G03A",
  "device-type": "my-device-type",
  "response-manager": {
    "matched-response": [{
      "name": "catch-all-response",
      "response": {
        "conveyed-information": {
          "redirect-information": {
            "reference": "my-redirect-information"
          }
        }
      }
    }]
  }
}
```

**In `config/sztpd.running.json.template`** — same `"serial-number"` and `"device-type"`, but reference `"first-onboarding-information"`:

```json
{
  "serial-number": "PID:C9300-24T SN:FCW2129G03A",
  "device-type": "my-device-type",
  "response-manager": {
    "matched-response": [{
      "name": "catch-all-response",
      "response": {
        "conveyed-information": {
          "onboarding-information": {
            "reference": "first-onboarding-information"
          }
        }
      }
    }]
  }
}
```

**In both templates**, set the trust anchor bag name in the `device-type` section:

```json
"local-truststore-reference": {
  "certificate-bag": "my-device-identity-ca-certs",
  "certificate": "my-device-identity-ca-cert-act2-sudi"     // or "circa-2020" for HA-SUDI
}
```

### 5. Set DHCP option 143

On your DHCP server (upstream IOS router or ISC dhcpd in the docker network):

```
option 143 = "https://10.1.1.3:8080"    (redirecter)
     or
option 143 = "https://10.1.1.3:9090"    (direct to bootstrap)
```

**CRITICAL**: Send **scheme + host + port only** — no path. Include the path and
DHCP option is silently discarded.

### 6. Verify docker-compose.yml env vars

Ensure the paths in `docker-compose.yml` match your files:

```yaml
SZTP_OWNERSHIP_VOUCHER_CMS: /local_files/FCW2129G03A.vcj    # ← your .vcj filename
SZTP_OWNER_CERT_CMS: /local_files/owner_cert_chain.cms
CMS_OWNER_KEY: /local_files/owner-certificate.key
CMS_OWNER_CERT: /local_files/owner-certificate.crt
CMS_OWNER_CERT_CHAIN: /local_files/owner_cert_chain.pem
```

### 7. Start the stack and reload the switch

```bash
docker-compose down --volumes --remove-orphans
docker-compose up --build --force-recreate -d
docker-compose logs -f bootstrap redirecter    # watch for errors
```

On the switch:

```
Switch# pnpa service reset no-prompt
# Wait ~4 minutes for reload and SZTP to run
```

### 8. Verify success

```bash
# Check audit log (poll every 2s)
watch -n 2 "docker exec sztp-bootstrap-1 curl -s \
  --user my-admin@example.com:my-secret \
  'http://127.0.0.1:7080/restconf/ds/ietf-datastores:operational/wn-sztpd-1:audit-log' \
  -H 'Accept: application/yang-data+json' | python3 -m json.tool | tail -30"
```

Look for:
- `"outcome": "success"` with your device's IP in `source-ip`
- Container logs showing `sitecustomize: rev8 JSON eContent for onboarding-information`
- Switch console showing `day0guestshell enabled successfully` and hostname changed

---

## Debugging

### Bootstrap won't start

```bash
docker-compose logs bootstrap | grep -i error
```

Check:
- [ ] `PYTHONPATH` points to `/tmp/pysite` where `sitecustomize.py` is installed
- [ ] All env vars in `docker-compose.yml` point to existing files in `local_files/`
- [ ] `docker-compose exec setup-cert /setup-cert.sh` ran successfully

### Device not found

Audit log shows: `"comment": "Device \"X\" not found for any tenant"`

Check:
- [ ] Registration key `X` matches the `serial-number` field in both JSON templates
- [ ] Both `sztpd.redirect.json.template` and `sztpd.running.json.template` are updated
- [ ] Device serial number was extracted correctly (run the failed attempt again to confirm)

### "Failed to parse the conveyed info xml"

This is the **wrong OID** error — switch received OID 1.42 (XML) instead of 1.43 (JSON).

Check:
- [ ] `sitecustomize.py` printed `rev8 JSON eContent` in the container logs
- [ ] `/tmp/sztp_last_response.xml` exists in bootstrap container
- [ ] The eContent OID decodes to `1.2.840.113549.1.9.16.1.43` (run the CMS decode command from IOSXE.md §12)

### TLS/signature failures

Check the bootstrap container logs for `SECLEVEL`, `WRONG_SIGNATURE_SIZE`, or `digest algorithm`:

```bash
docker-compose logs bootstrap | grep -i "ssl\|signature\|digest"
```

These should be patched by `sitecustomize.py`. If still failing, verify:
- [ ] All six patches printed their success messages
- [ ] The container's Python is running with the correct `PYTHONPATH`
- [ ] No custom `sitecustomize.py` elsewhere overrides the one in `/tmp/pysite`

---

## Console Automation (optional)

To automate the reload + log pull:

```bash
pip install paramiko

python3 scripts/sztp_console_test.py --pull-log-only --minutes 30   # just get logs
python3 scripts/sztp_console_test.py                                # reload + logs
```

Edit the script header if your conserver details differ:

```python
CONSERVER_HOST = "128.107.223.248"
CONSERVER_USER = "auto"
CONSERVER_PASS = "G0ldl@bs247"
CONSOLE_NAME   = "ts199-line28"
ENABLE_PASS    = "EN-TME-Cisco123"
```

---

## Next Steps

- **Customize the config** — edit `config/first-configuration.xml` to set your actual hostname, users, IPs, etc.
- **Add pre/post scripts** — modify `config/first-pre-configuration-script.sh` and `.../post...` for device-specific setup
- **Test with multiple devices** — duplicate the config/script/image triplets for second, third, etc.
- **Use HTTPS web server** — replace the bundled httpd with a real one that serves boot images (see `config/boot-images`)

---

## Full Documentation

For comprehensive details on each section, PKI regeneration, error recovery, and advanced topics, see:

- [IOSXE.md](IOSXE.md) — Full IOS-XE operational guide
- [CHANGELOG.md](CHANGELOG.md) — What was needed to fix the XML parsing issue
- [ZTP.md](ZTP.md) — High-level ZTP concepts
- [RFC 8572](https://www.rfc-editor.org/rfc/pdfrfc/rfc8572.txt.pdf) — SZTP standard
