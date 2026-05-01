#!/bin/ash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jeremy Cohoe
#
# Offline replacement for the `setup-cert` step that previously pulled
# `https://watsen.net/support/sztpd-simulator-0.0.11.tgz` (now 404) to
# build the SZTPD SBI PKI and the device-identity trust anchor.
#
# This script:
#   1. Builds a 2-tier SBI PKI (root + intermediate + end-entity) with
#      SANs covering both the docker network names and the lab IP
#      `10.1.1.3` so a real Cisco IOS-XE device can validate the cert.
#   2. Uses `/local_files/cisco_sudi_ta_chain.pem` (Cisco SUDI TA chain
#      shipped in `sztp_local_files/`) as the device-identity trust
#      anchor, so the C9300's SUDI client cert is trusted by sztpd.
#   3. Generates the demo `first/second/third` client end-entity certs
#      so the existing running-mode template renders unchanged.
#
# All artifacts written to the locations the running container expects:
#   /certs/server/{private_key.{pem,der},public_key.der,my_cert.pem,
#                  cert_chain.{pem,cms},ta_cert_chain.{pem,cms}}
#   /certs/client/{opi.pem, first_*, second_*, third_*}

set -euxo pipefail

apk add --no-cache --no-check-certificate make >/dev/null
mkdir -p /tmp/pki /certs/server /certs/client
cd /tmp/pki

SBI_SAN="DNS:bootstrap,DNS:web,DNS:redirecter,DNS:localhost,IP:127.0.0.1,IP:10.127.127.3,IP:10.1.1.3"

# ---- SBI: Root CA -----------------------------------------------------
# Use RSA-2048 throughout for compatibility with the Cisco IOS-XE sZTP
# client, whose libcurl/crypto stack rejected ECDSA (`SSL connect error`
# on a 17.18.01 C9300 — see commit log).
openssl genrsa -out sbi-root.key.pem 2048
openssl req -x509 -new -nodes -key sbi-root.key.pem -sha256 -days 3650 \
    -subj "/CN=sztpd-sbi-root-ca" -out sbi-root.cert.pem

# ---- SBI: Intermediate CA --------------------------------------------
openssl genrsa -out sbi-int.key.pem 2048
openssl req -new -key sbi-int.key.pem -subj "/CN=sztpd-sbi-intermediate-ca" \
    -out sbi-int.csr.pem
cat > sbi-int.ext <<EOF
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
EOF
openssl x509 -req -in sbi-int.csr.pem -CA sbi-root.cert.pem -CAkey sbi-root.key.pem \
    -CAcreateserial -days 1825 -sha256 -extfile sbi-int.ext -out sbi-int.cert.pem

# ---- SBI: End-entity (server cert) -----------------------------------
openssl genrsa -out sbi-ee.key.pem 2048
# Persist as PKCS#8 so sztpd's `ietf-crypto-types:rsa
# ---- SBI: End-entity (server cert) -----------------------------------
openssl genrsa -out sbi-ee.key.pem 2048
# Persist as PKCS#8 so sztpd's `ietf-crypto-types:rsa-private-key-format` works.
openssl pkcs8 -topk8 -nocrypt -in sbi-ee.key.pem -out sbi-ee.key.p8.pem
openssl pkey -in sbi-ee.key.pem -pubout -outform DER -out sbi-ee.pub.der
openssl pkey -in sbi-ee.key.pem -outform DER -out sbi-ee.key.der

openssl req -new -key sbi-ee.key.pem -subj "/CN=sztpd-sbi-bootstrap" \
    -out sbi-ee.csr.pem
cat > sbi-ee.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${SBI_SAN}
EOF
openssl x509 -req -in sbi-ee.csr.pem -CA sbi-int.cert.pem -CAkey sbi-int.key.pem \
    -CAcreateserial -days 825 -sha256 -extfile sbi-ee.ext -out sbi-ee.cert.pem

# ---- SBI: chain (end-entity + intermediate) → PEM + CMS --------------
cat sbi-ee.cert.pem sbi-int.cert.pem > sbi-cert-chain.pem
openssl crl2pkcs7 -nocrl -certfile sbi-cert-chain.pem -outform DER \
    -out sbi-cert-chain.cms

# ---- Device-identity TA: real Cisco SUDI chain -----------------------
# sztpd requires the truststore certificate-bag to contain exactly ONE
# self-signed root. cisco_sudi_ta_chain.pem holds two roots (CRCA-2048
# and CRCA-2099) which sztpd rejects. The C9300 ACT2 trust path is
# Cisco Root CA 2048 -> ACT2 SUDI CA -> device SUDI, so use the smaller
# bundle that contains only that single root + intermediate.
#
# Override with TA_CHAIN_FILE env var if a different chain is required.
TA_CHAIN_FILE="${TA_CHAIN_FILE:-/local_files/act2_sudi_chain.pem}"
if [ -f "$TA_CHAIN_FILE" ]; then
    cp "$TA_CHAIN_FILE" device-ta-chain.pem
    echo "setup-cert-offline: using TA chain from $TA_CHAIN_FILE"
else
    echo "setup-cert-offline: WARNING — $TA_CHAIN_FILE missing, falling back to SBI root"
    cp sbi-root.cert.pem device-ta-chain.pem
fi
openssl crl2pkcs7 -nocrl -certfile device-ta-chain.pem -outform DER \
    -out device-ta-chain.cms

# ---- Demo client (first/second/third) end-entity certs ---------------
# These satisfy the running-mode template's references for the demo
# device serial numbers. They do NOT need to chain to the device-identity
# TA used for the real C9300; sztpd indexes per-device by trust anchor.
openssl ecparam -name prime256v1 -genkey -noout -out client-root.key.pem
openssl req -x509 -new -nodes -key client-root.key.pem -sha256 -days 3650 \
    -subj "/CN=sztpd-demo-client-ca" -out client-root.cert.pem

cat > client-ee.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
EOF
for vendor in first second third; do
    openssl ecparam -name prime256v1 -genkey -noout -out "${vendor}.key.pem"
    openssl pkcs8 -topk8 -nocrypt -in "${vendor}.key.pem" -out "${vendor}.key.p8.pem"
    openssl req -new -key "${vendor}.key.pem" \
        -subj "/CN=${vendor}-demo/serialNumber=${vendor}-serial-number" \
        -out "${vendor}.csr.pem"
    openssl x509 -req -in "${vendor}.csr.pem" \
        -CA client-root.cert.pem -CAkey client-root.key.pem \
        -CAcreateserial -days 825 -sha256 -extfile client-ee.ext \
        -out "${vendor}.cert.pem"
    cp "${vendor}.key.p8.pem"  "/certs/client/${vendor}_private_key.pem"
    cp "${vendor}.cert.pem"    "/certs/client/${vendor}_my_cert.pem"
done

# ---- Place artifacts where the bootstrap/web containers expect them --
cp sbi-ee.key.p8.pem        /certs/server/private_key.pem
cp sbi-ee.key.der           /certs/server/private_key.der
cp sbi-ee.pub.der           /certs/server/public_key.der
cp sbi-ee.cert.pem          /certs/server/my_cert.pem
cp sbi-cert-chain.pem       /certs/server/cert_chain.pem
cp sbi-cert-chain.cms       /certs/server/cert_chain.cms
cp device-ta-chain.pem      /certs/server/ta_cert_chain.pem
cp device-ta-chain.cms      /certs/server/ta_cert_chain.cms

# Client-side TA bundle (used by curl examples to trust the SBI cert).
cat sbi-root.cert.pem sbi-int.cert.pem > /certs/client/opi.pem

echo "setup-cert-offline: done"
ls -la /certs/server /certs/client
