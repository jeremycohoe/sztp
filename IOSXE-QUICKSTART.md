# IOS-XE sZTP — Quickstart

Five-minute path to onboarding a Catalyst 9300 with this stack. For the
deep-dive (PKI generation, error tables, all six sitecustomize patches),
see [IOSXE.md](temp/sztp/iosxe-transfer-bundle-20260423/IOSXE.md) and
[AGENTS.md](AGENTS.md).

## What you need

- Cisco C9300 / C9300L on IOS-XE 17.18.x with `write erase`-able config
- Ownership voucher `<CHASSIS-SN>.vcj` from your Cisco MASA owner
- Owner cert chain (`owner_cert_chain.cms`, `owner_cert_chain.pem`,
  `owner-certificate.{crt,key}`) under `local_files/`
- Docker + docker-compose on a host reachable on the lab subnet
- Host's `isc-dhcp-server` **disabled** (`sudo systemctl disable --now isc-dhcp-server`)

## The two non-obvious knobs

These two settings cost the most time to discover. Code now enforces both.

1. **DHCP option 143 must use RFC 8572 §8.2 binary framing.**
   IOS-XE 17.18 silently drops the ISC `text` encoding — the device only
   logs `si-addr`, never `bootstrap-server-list:`. The dhcp container's
   `entrypoint.sh` writes the correct `uint16 BE length || URI bytes` form.

2. **`SZTP_URL` must be scheme+host+port ONLY — no path.**
   The switch appends `/restconf/operations/ietf-sztp-bootstrap-server:get-bootstrapping-data`
   itself. Including the path here produces a doubled URL and sztpd
   answers 404 "Unrecognized RPC."
   - ✅ `https://10.1.1.3:8080`  (redirecter)
   - ❌ `https://10.1.1.3:9090/restconf/operations/...`

   Both `dhcp/entrypoint.sh` and `scripts/sztp-preflight.sh` now refuse
   URLs with a path.

## Bring it up

1. Drop your voucher into `local_files/`:
   ```bash
   cp ~/FCW2126G05V.vcj local_files/
   ```

2. Set the device PID in both sztpd templates (already pre-populated for
   `C9300-24T`; change for other models):
   - `config/sztpd.redirect.json.template`
   - `config/sztpd.running.json.template`

   The registration key is the **PID** (`C9300-24T`), not the chassis
   serial — Cisco's SUDI exposes the PID in the cert subject's
   `serialNumber` attribute. See AGENTS.md §6 for the audit-log trick to
   confirm what sztpd extracts.

3. Adjust `config/catalyst/c9300.env` if your subnet differs:
   ```
   SZTP_URL=https://10.1.1.3:8080      # redirecter, no path
   SZTP_DEVICE_SN=C9300-24T            # PID from SUDI
   SZTP_TRUST_ANCHOR=act2-sudi         # or circa-2020 for C9300X/C9500X
   ```

4. Start the stack:
   ```bash
   docker-compose --env-file config/catalyst/c9300.env --profile iosxe up -d
   ```

5. Run preflight (fails loud on every common landmine):
   ```bash
   scripts/sztp-preflight.sh --env-file config/catalyst/c9300.env
   ```

6. Reload the switch:
   ```
   enable
   write erase     ! mandatory; IOS-XE persists "ZTP attempted" state
   yes
   reload
   no              ! don't save
   yes             ! confirm reload
   ```

## Verify success

After ~3 minutes the switch should self-onboard. Check from the host:

```bash
docker logs sztp-bootstrap-1 2>&1 | grep -E 'signed|onboard|injected'
# expect: "signed+wrapped … CMS SignedData"
#         "injected owner-certificate + ownership-voucher"
```

From the device console:

```
show logging process sztp internal start last 10 minutes | redirect tftp://10.1.1.3/sztp.log
```

Look for, in order: `bootstrap-server-list: https://10.1.1.3:8080`,
`Signature on ownership voucher's CMS structure has been verified`,
`Conveyed info signature is verified`,
`Received onboarding info`,
`pre-script-complete` → `config-complete` → `post-script-complete` →
`bootstrap-complete`.

Hostname change on the switch (e.g. `sztp-provisioning#`) is the surest
sign that the configuration applied.

## When it fails

| Symptom (in switch log) | Probable cause | Fix |
|---|---|---|
| Only `si-addr: …`, no `bootstrap-server-list:` | DHCP option 143 not delivered or `text`-encoded | Verify `dhcp/entrypoint.sh` is the entrypoint (not the bundle's `eval` render); check `docker logs sztp-dhcp-1` for `option sztp-redirect-urls 00:15:…` |
| `Server response is not signed` / 404 | Doubled URL — `SZTP_URL` has a path | Set `SZTP_URL=https://HOST:PORT` only |
| `Failed to extract xml body from server response` | sztpd returned XML not signed JSON | Check sitecustomize patches loaded: `docker logs sztp-bootstrap-1 \| grep sitecustomize` (expect 6 lines) |
| `access-denied` (401) | Device PID not registered | Look at `bootstrapping-log` in sztpd: `docker exec sztp-bootstrap-1 curl -s -u my-admin@example.com:my-secret 'http://127.0.0.1:7080/restconf/ds/ietf-datastores:operational/wn-sztpd-1:audit-log'` — find which `serial-number` it actually saw, register that exact value |

For the comprehensive error table see
[temp/sztp/iosxe-transfer-bundle-20260423/IOSXE.md](temp/sztp/iosxe-transfer-bundle-20260423/IOSXE.md) §14
and [AGENTS.md](AGENTS.md) §8.
