#!/bin/ash
# SPDX-License-Identifier: Apache-2.0
# Generates all PKI artifacts needed by the OPI sZTP infra using pure openssl.
# Replaces the watsen.net sztpd-simulator dependency which is no longer reachable.
# Outputs match the paths expected by docker-entrypoint.sh and the agent containers.
set -euxo pipefail

mkdir -p /tmp/pki/sbi /tmp/pki/client

# ---------------------------------------------------------------------------
# Helper: write a CA-capable extension file
# ---------------------------------------------------------------------------
printf 'basicConstraints=CA:TRUE,pathlen:0\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n' \
    > /tmp/ca_ext.txt

# ---------------------------------------------------------------------------
# SERVER SBI PKI  (3-level: root-ca → intermediate → end-entity)
# Keys: EC prime256v1   Private-key format: RFC 5915 (ietf-crypto-types:ec-private-key-format)
# ---------------------------------------------------------------------------
echo "=== SERVER SBI ROOT CA ==="
openssl ecparam -name prime256v1 -genkey -noout -out /tmp/pki/sbi/root_key.pem
openssl req -new -x509 -key /tmp/pki/sbi/root_key.pem \
    -out /tmp/pki/sbi/root_cert.pem -days 3650 \
    -subj '/CN=SBI Root CA/O=OPI-SZTP'

echo "=== SERVER SBI INTERMEDIATE CA ==="
openssl ecparam -name prime256v1 -genkey -noout -out /tmp/pki/sbi/int_key.pem
openssl req -new -key /tmp/pki/sbi/int_key.pem \
    -out /tmp/pki/sbi/int.csr -subj '/CN=SBI Intermediate CA/O=OPI-SZTP'
openssl x509 -req -in /tmp/pki/sbi/int.csr \
    -CA /tmp/pki/sbi/root_cert.pem -CAkey /tmp/pki/sbi/root_key.pem \
    -CAcreateserial -out /tmp/pki/sbi/int_cert.pem \
    -days 3650 -extfile /tmp/ca_ext.txt

echo "=== SERVER SBI END-ENTITY (with SANs) ==="
openssl ecparam -name prime256v1 -genkey -noout -out /tmp/pki/sbi/ee_key.pem
# Convert to RFC 5915 PEM (traditional EC format, not PKCS#8)
openssl ec -in /tmp/pki/sbi/ee_key.pem -out /certs/server/private_key.pem
openssl ec -in /certs/server/private_key.pem -outform DER -out /certs/server/private_key.der
openssl ec -in /certs/server/private_key.pem -pubout -outform DER -out /certs/server/public_key.der

printf 'basicConstraints=CA:FALSE\nsubjectAltName=DNS:bootstrap,DNS:web,DNS:redirecter,IP:10.1.1.3\nkeyUsage=digitalSignature,keyAgreement\nextendedKeyUsage=serverAuth\n' \
    > /tmp/san_ext.txt

openssl req -new -key /certs/server/private_key.pem \
    -out /tmp/pki/sbi/ee.csr -subj '/CN=sztpd-server/O=OPI-SZTP'
openssl x509 -req -in /tmp/pki/sbi/ee.csr \
    -CA /tmp/pki/sbi/int_cert.pem -CAkey /tmp/pki/sbi/int_key.pem \
    -CAcreateserial -out /certs/server/my_cert.pem \
    -days 3650 -extfile /tmp/san_ext.txt

# cert_chain = end-entity + intermediate (what the SBI port presents)
cat /certs/server/my_cert.pem /tmp/pki/sbi/int_cert.pem > /certs/server/cert_chain.pem
openssl crl2pkcs7 -nocrl -certfile /certs/server/cert_chain.pem \
    -outform DER -out /certs/server/cert_chain.cms

# opi.pem = trust anchor for sztp-agent containers (SBI root + intermediate)
cat /tmp/pki/sbi/root_cert.pem /tmp/pki/sbi/int_cert.pem > /certs/client/opi.pem

# bootsvr_ta.cms = trust anchor handed to the switch in redirect-information
# so it can validate the bootstrap server's TLS cert when it follows the
# redirect. Contains our SBI Root CA (+ intermediate for leniency).
cat /tmp/pki/sbi/root_cert.pem /tmp/pki/sbi/int_cert.pem > /tmp/pki/sbi/bootsvr_ta.pem
openssl crl2pkcs7 -nocrl -certfile /tmp/pki/sbi/bootsvr_ta.pem \
    -outform DER -out /certs/server/bootsvr_ta.cms

# ---------------------------------------------------------------------------
# CLIENT DEVICE IDENTITY PKI  (trust anchor for device cert verification)
# ---------------------------------------------------------------------------
echo "=== CLIENT DEVICE IDENTITY ROOT CA ==="
openssl ecparam -name prime256v1 -genkey -noout -out /tmp/pki/client/root_key.pem
openssl req -new -x509 -key /tmp/pki/client/root_key.pem \
    -out /tmp/pki/client/root_cert.pem -days 3650 \
    -subj '/CN=Device Identity Root CA/O=OPI-SZTP'

echo "=== CLIENT DEVICE IDENTITY INTERMEDIATE CA ==="
openssl ecparam -name prime256v1 -genkey -noout -out /tmp/pki/client/int_key.pem
openssl req -new -key /tmp/pki/client/int_key.pem \
    -out /tmp/pki/client/int.csr -subj '/CN=Device Identity Intermediate CA/O=OPI-SZTP'
openssl x509 -req -in /tmp/pki/client/int.csr \
    -CA /tmp/pki/client/root_cert.pem -CAkey /tmp/pki/client/root_key.pem \
    -CAcreateserial -out /tmp/pki/client/int_cert.pem \
    -days 3650 -extfile /tmp/ca_ext.txt

# ta_cert_chain = Cisco SUDI CA trust anchors (real device identity CAs)
# Chain 1: Cisco Root CA 2099 + High Assurance SUDI CA  (C9300X, newer HA devices)
# Chain 2: Cisco Root CA 2048 + ACT2 SUDI CA            (older Catalyst/ISR devices)
#
# Fetch from Cisco PKI. If offline, files must be pre-staged in /etc/cisco-pki/
for url_file in \
    "https://www.cisco.com/security/pki/certs/crca2099.pem crca2099.pem" \
    "https://www.cisco.com/security/pki/certs/hasudi.pem   hasudi.pem" \
    "https://www.cisco.com/security/pki/certs/crca2048.cer crca2048.cer" \
    "https://www.cisco.com/security/pki/certs/ACT2SUDICA.pem act2sudica.pem"; do
    url=$(echo $url_file | awk '{print $1}')
    file=$(echo $url_file | awk '{print $2}')
    wget -q -O /tmp/pki/${file} "${url}" || true
done
# crca2048 is DER — convert to PEM
openssl x509 -inform DER -in /tmp/pki/crca2048.cer -out /tmp/pki/crca2048.pem 2>/dev/null || cp /tmp/pki/crca2048.cer /tmp/pki/crca2048.pem

# Build CMS bundle per chain (one root per bundle — sztpd constraint)
cat /tmp/pki/crca2099.pem /tmp/pki/hasudi.pem > /tmp/pki/ha_sudi_chain.pem
openssl crl2pkcs7 -nocrl -certfile /tmp/pki/ha_sudi_chain.pem \
    -outform DER -out /certs/server/ta_cert_chain.cms
cat /tmp/pki/crca2048.pem /tmp/pki/act2sudica.pem > /tmp/pki/act2_sudi_chain.pem
openssl crl2pkcs7 -nocrl -certfile /tmp/pki/act2_sudi_chain.pem \
    -outform DER -out /certs/server/ta_cert_chain_act2.cms
# ta_cert_chain.pem used by Apache httpd (full combined bundle for SSL client auth)
cat /tmp/pki/crca2099.pem /tmp/pki/hasudi.pem \
    /tmp/pki/crca2048.pem /tmp/pki/act2sudica.pem > /certs/server/ta_cert_chain.pem

# ---------------------------------------------------------------------------
# Per-vendor test client end-entity certs  (CN = <vendor>-serial-number)
# Used by the sztp-agent containers for the simulated DPU/IPU devices.
# ---------------------------------------------------------------------------
echo "=== GENERATE CLIENT ENDPOINT CERTS (first / second / third) ==="
for vendor in first second third; do
    openssl ecparam -name prime256v1 -genkey -noout -out /tmp/pki/client/${vendor}_key.pem
    openssl ec -in /tmp/pki/client/${vendor}_key.pem \
        -out /certs/client/${vendor}_private_key.pem
    openssl req -new -key /certs/client/${vendor}_private_key.pem \
        -out /tmp/pki/client/${vendor}.csr \
        -subj "/CN=${vendor}-serial-number/O=OPI-SZTP"
    openssl x509 -req -in /tmp/pki/client/${vendor}.csr \
        -CA /tmp/pki/client/int_cert.pem -CAkey /tmp/pki/client/int_key.pem \
        -CAcreateserial -out /certs/client/${vendor}_my_cert.pem -days 3650 \
        -extfile <(printf 'basicConstraints=CA:FALSE\n')
done

echo "=== PKI GENERATION COMPLETE ==="
ls -la /certs/server/ /certs/client/
