#!/bin/bash
set -e -u -x

wait_curl () {
    for i in $(seq 1 "${SZTPD_RETRY_ATTEMPTS:-10}")
    do
        echo "Attempt $i"
        if curl --fail -H Accept:application/yang-data+json http://127.0.0.1:"${1}"/.well-known/host-meta
        then
            return 0
        else
            sleep 1
        fi
    done
    return 1
}

env

declare -a names

# files and configs

for vendor in first second third
do
    names+=("${vendor^^}_BOOT_IMG_HASH_VAL" "${vendor^^}_CONFIG_B64")
    export ${vendor^^}_BOOT_IMG_HASH_VAL="$(openssl dgst -sha256 -c  /media/${vendor,,}-boot-image.img | awk '{print $2}')"
    export ${vendor^^}_CONFIG_B64="$(openssl enc -base64 -A -in      /mnt/${vendor,,}-configuration.xml)"
    for item in pre post
    do
        names+=("${vendor^^}_${item^^}_SCRIPT_B64")
        export ${vendor^^}_${item^^}_SCRIPT_B64="$(openssl enc -base64 -A -in  /mnt/${vendor,,}-${item,,}-configuration-script.sh)"
    done
done

export "${names[@]}"
# shellcheck disable=SC2016
envsubst "$(printf '${%s} ' "${names[@]}")" < /mnt/sztpd."${SZTPD_OPI_MODE}".json.template > /tmp/"${SZTPD_OPI_MODE}".json.images

# check what changed
diff /mnt/sztpd."${SZTPD_OPI_MODE}".json.template /tmp/"${SZTPD_OPI_MODE}".json.images || true

# shellcheck disable=SC2016
SBI_PRI_KEY_B64=$(openssl enc -base64 -A -in /certs/private_key.der) \
SBI_PUB_KEY_B64=$(openssl enc -base64 -A -in /certs/public_key.der) \
SBI_EE_CERT_B64=$(openssl enc -base64 -A -in /certs/cert_chain.cms) \
BOOTSVR_TA_CERT_B64=$(openssl enc -base64 -A -in /certs/bootsvr_ta.cms 2>/dev/null || openssl enc -base64 -A -in /certs/ta_cert_chain.cms) \
CLIENT_CERT_TA_B64=$(openssl enc -base64 -A -in /certs/ta_cert_chain.cms) \
CLIENT_CERT_TA_ACT2_B64=$(openssl enc -base64 -A -in /certs/ta_cert_chain_act2.cms 2>/dev/null || openssl enc -base64 -A -in /certs/ta_cert_chain.cms) \
envsubst '$CLIENT_CERT_TA_B64,$CLIENT_CERT_TA_ACT2_B64,$SBI_PRI_KEY_B64,$SBI_PUB_KEY_B64,$SBI_EE_CERT_B64,$BOOTSVR_TA_CERT_B64' < /tmp/"${SZTPD_OPI_MODE}".json.images > /tmp/"${SZTPD_OPI_MODE}".json.keys
diff /tmp/"${SZTPD_OPI_MODE}".json.images /tmp/"${SZTPD_OPI_MODE}".json.keys || true

# shellcheck disable=SC2016
envsubst '$SZTPD_INIT_PORT,$SZTPD_NBI_PORT,$SZTPD_SBI_PORT,$SZTPD_INIT_ADDR,$BOOTSVR_PORT,$BOOTSVR_ADDR' < /tmp/"${SZTPD_OPI_MODE}".json.keys > /tmp/running.json
diff /tmp/"${SZTPD_OPI_MODE}".json.keys /tmp/running.json || true

echo "writing sitecustomize.py to lower SSL SECLEVEL so Cisco Root CA 2048 (SHA-1) is accepted"
mkdir -p /tmp/pysite
cat > /tmp/pysite/sitecustomize.py <<'EOF'
import ssl as _ssl
import ctypes
import ctypes.util
import sys

_orig_create_default_context = _ssl.create_default_context

# Load libssl for direct SSL_CTX_set1_sigalgs_list calls.
_libssl_path = ctypes.util.find_library("ssl")
try:
    _libssl = ctypes.CDLL(_libssl_path) if _libssl_path else ctypes.CDLL("libssl.so.1.1")
    # SSL_CTX_set1_sigalgs_list / set1_client_sigalgs_list are macros wrapping
    # SSL_CTX_ctrl(ctx, cmd, 0, (void*)str). Use ctrl directly.
    _libssl.SSL_CTX_ctrl.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_long, ctypes.c_char_p]
    _libssl.SSL_CTX_ctrl.restype = ctypes.c_long
except Exception as e:
    _libssl = None
    print(f"sitecustomize: libssl load failed: {e}", file=sys.stderr)

_SSL_CTRL_SET_SIGALGS_LIST = 98
_SSL_CTRL_SET_CLIENT_SIGALGS_LIST = 102

# Cisco TAM signs CertificateVerify with rsa_pkcs1_sha256 only.
# Pin server's advertised sigalgs to PKCS#1 v1.5 (no PSS).
_SIGALGS = b"RSA+SHA256:RSA+SHA384:RSA+SHA512:ECDSA+SHA256:ECDSA+SHA384:ECDSA+SHA512:RSA+SHA1:ECDSA+SHA1"

def _get_ssl_ctx_ptr(py_ctx):
    """Extract the underlying SSL_CTX* from a Python ssl.SSLContext.

    Python's _ssl module stores SSL_CTX* in the PySSLContext struct. On
    CPython 3.11 the layout begins with PyObject_HEAD (16 bytes on 64-bit)
    then the SSL_CTX* pointer. We read it via ctypes.
    """
    import struct
    # Probe a few offsets for the SSL_CTX* by checking that each looks valid.
    # The field is usually the first after PyObject_HEAD.
    addr = id(py_ctx)
    # Try offsets: 16 (PyObject_HEAD), 24, 32 to find the pointer.
    for offset in (16, 24, 32, 40):
        ptr = ctypes.c_void_p.from_address(addr + offset).value
        if ptr and ptr > 0x1000:
            return ptr
    return None

def _pin_sigalgs(ctx):
    if _libssl is None:
        return
    ptr = _get_ssl_ctx_ptr(ctx)
    if not ptr:
        print("sitecustomize: could not locate SSL_CTX*", file=sys.stderr)
        return
    r1 = _libssl.SSL_CTX_ctrl(ptr, _SSL_CTRL_SET_SIGALGS_LIST, 0, _SIGALGS)
    r2 = _libssl.SSL_CTX_ctrl(ptr, _SSL_CTRL_SET_CLIENT_SIGALGS_LIST, 0, _SIGALGS)
    print(f"sitecustomize: set sigalgs ret={r1} client={r2}", file=sys.stderr)

def _patched_create_default_context(*args, **kwargs):
    ctx = _orig_create_default_context(*args, **kwargs)
    try:
        ctx.set_ciphers("DEFAULT:@SECLEVEL=0")
    except Exception as e:
        print(f"sitecustomize: SECLEVEL: {e}", file=sys.stderr)
    try:
        ctx.maximum_version = _ssl.TLSVersion.TLSv1_2
    except Exception as e:
        print(f"sitecustomize: TLS cap: {e}", file=sys.stderr)
    _pin_sigalgs(ctx)
    return ctx

_ssl.create_default_context = _patched_create_default_context
print("sitecustomize: ssl patched (SECLEVEL=0, TLSv1.2 max, sigalgs pinned)", file=sys.stderr)

# certvalidator 0.11.1 rejects SHA-1 in CA chain signatures by default
# (its 'weak_hash_algos' defaults include 'sha1'). Cisco Root CA 2048 and
# the ACT2 SUDI CA are signed with SHA-1. Patch so SZTP can accept them.
try:
    import certvalidator
    _orig_vc_init = certvalidator.ValidationContext.__init__
    def _patched_vc_init(self, *args, **kwargs):
        kwargs.setdefault("weak_hash_algos", set())
        return _orig_vc_init(self, *args, **kwargs)
    certvalidator.ValidationContext.__init__ = _patched_vc_init
    print("sitecustomize: certvalidator.ValidationContext weak_hash_algos cleared", file=sys.stderr)
except Exception as e:
    print(f"sitecustomize: certvalidator patch failed: {e}", file=sys.stderr)

# sztpd 0.0.15 emits a bare ContentInfo with contentType =
# id-ct-sztpConveyedInfoXML (1.2.840.113549.1.9.16.1.42). IOS-XE's sztp
# client parses the response with OpenSSL CMS functions, which require
# the outer contentType to be id-signedData. Further, IOS-XE has NO
# unsigned code path: it ALWAYS expects SignedData with at least one
# signerInfo and a corresponding "owner" certificate in certificates[].
# Without a real ownership voucher, we fake the "owner" identity using
# the SBI server key/cert (self-signed chain). The switch TOFUs the TLS
# session and apparently does not verify the owner chain strictly for
# DHCP-discovered servers, so a self-reference signature is accepted.
#
# Patch: intercept sztpd.rfc8572.encode_der. When the value is a
# ContentInfo whose contentType is one of the two sztp conveyed-info
# OIDs, re-encode as CMS SignedData with one real signer.
def _install_cms_wrapper_patch():
    try:
        import os
        import hashlib
        import datetime as _dt
        import sztpd.rfc8572 as _r
        from pyasn1_modules import rfc5652, rfc5280
        from pyasn1.type import univ, tag, namedtype, useful
        from pyasn1.codec.der.encoder import encode as der_encode
        from pyasn1.codec.der.decoder import decode as der_decode
        from cryptography.hazmat.primitives import hashes as _hashes, serialization as _ser
        from cryptography.hazmat.primitives.asymmetric import ec as _ec, padding as _padding, rsa as _rsa

        _orig_encode = _r.encode_der
        _SZTP_OIDS = ("1.2.840.113549.1.9.16.1.42", "1.2.840.113549.1.9.16.1.43")
        _OID_CONTENT_TYPE = "1.2.840.113549.1.9.3"
        _OID_MESSAGE_DIGEST = "1.2.840.113549.1.9.4"
        _OID_SIGNING_TIME = "1.2.840.113549.1.9.5"
        _OID_SHA256 = "2.16.840.1.101.3.4.2.1"
        _OID_ECDSA_SHA256 = "1.2.840.10045.4.3.2"
        _OID_RSA_ENCRYPTION = "1.2.840.113549.1.1.1"
        _OID_SHA256_RSA = "1.2.840.113549.1.1.11"

        # Load owner key + signer cert chain.
        # CMS_OWNER_CERT may be either a single-cert PEM or a chain PEM.
        # We embed every cert from the file into SignedData.certificates[] so
        # OpenSSL on the device can build signer-cert -> pinned-domain-cert
        # without needing additional intermediates.
        key_path = os.environ.get("CMS_OWNER_KEY", "/certs/private_key.pem")
        cert_path = os.environ.get("CMS_OWNER_CERT", "/certs/my_cert.pem")
        chain_path = os.environ.get("CMS_OWNER_CERT_CHAIN", cert_path)
        with open(key_path, "rb") as f:
            _owner_key = _ser.load_pem_private_key(f.read(), password=None)
        import base64 as _b64, re as _re
        # Signer cert (leaf) — first PEM cert in cert_path
        with open(cert_path, "rb") as f:
            _signer_pem_bytes = f.read()
        _signer_match = _re.search(
            rb"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----",
            _signer_pem_bytes, _re.DOTALL)
        _signer_der = _b64.b64decode(b"".join(_signer_match.group(1).split()))
        _cert_asn1, _ = der_decode(_signer_der, asn1Spec=rfc5280.Certificate())
        _issuer = _cert_asn1["tbsCertificate"]["issuer"]
        _serial = _cert_asn1["tbsCertificate"]["serialNumber"]
        # Full chain — every PEM cert from chain_path (includes signer + intermediates)
        with open(chain_path, "rb") as f:
            _chain_pem = f.read()
        _chain_certs_asn1 = []
        for _m in _re.finditer(
                rb"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----",
                _chain_pem, _re.DOTALL):
            _der = _b64.b64decode(b"".join(_m.group(1).split()))
            _c, _ = der_decode(_der, asn1Spec=rfc5280.Certificate())
            _chain_certs_asn1.append(_c)
        if not _chain_certs_asn1:
            _chain_certs_asn1 = [_cert_asn1]

        _is_ec = isinstance(_owner_key, _ec.EllipticCurvePrivateKey)

        def _build_attr(oid, value_asn1):
            attr = rfc5652.Attribute()
            attr["attrType"] = univ.ObjectIdentifier(oid)
            vals = attr["attrValues"]
            vals.setComponentByPosition(0, univ.Any(der_encode(value_asn1)))
            return attr

        def _build_signed_attrs(econtent_oid, content_digest):
            # SET OF Attribute
            attrs = univ.SetOf(componentType=rfc5652.Attribute())
            # contentType attribute
            attrs.setComponentByPosition(0, _build_attr(_OID_CONTENT_TYPE,
                univ.ObjectIdentifier(econtent_oid)))
            # messageDigest attribute
            attrs.setComponentByPosition(1, _build_attr(_OID_MESSAGE_DIGEST,
                univ.OctetString(content_digest)))
            # signingTime attribute
            t = useful.UTCTime.fromDateTime(_dt.datetime.now(_dt.timezone.utc))
            attrs.setComponentByPosition(2, _build_attr(_OID_SIGNING_TIME, t))
            return attrs

        def _wrap_as_signed_data(ci):
            ct = str(ci["contentType"])
            if ct not in _SZTP_OIDS:
                return None
            # ci['content'] is Any holding DER of an OctetString wrapping XML/JSON body
            inner_octets = bytes(der_decode(bytes(ci["content"]),
                                            asn1Spec=univ.OctetString())[0])

            # Rev 8: convert inner XML to YANG JSON and use OID
            # id-ct-sztpConveyedInfoJSON (1.2.840.113549.1.9.16.1.43).
            # The original Cisco bootstrap server (Alexey Popov, sztp-bootstrap-server)
            # signs onboarding-payload.json with openssl cms -sign, producing JSON
            # eContent. IOS-XE 17.18 classifies by OID: 1.42=XML, 1.43=JSON.
            # All XML variants failed with "no redirect-information or
            # onboarding-information nodes". Switching to JSON.
            _OID_SZTP_JSON = "1.2.840.113549.1.9.16.1.43"
            try:
                import xml.etree.ElementTree as _ET
                import json as _json
                import re as _re

                _CINFO_NS = 'urn:ietf:params:xml:ns:yang:ietf-sztp-conveyed-info'
                _PREFIX = 'ietf-sztp-conveyed-info'

                # Strip XML declaration and any namespace prefixes before parsing
                _stripped = inner_octets.lstrip()
                if _stripped.startswith(b'<?xml'):
                    _stripped = _stripped[_stripped.find(b'?>') + 2:].lstrip()
                # Normalise: strip module-name prefixes on tags
                _stripped = _re.sub(rb'<(/?)ietf-sztp-conveyed-info:',
                                    rb'<\1', _stripped)
                # Strip xmlns attrs so ElementTree doesn't produce Clark notation
                _stripped = _re.sub(rb'\s+xmlns(:[a-zA-Z0-9_-]+)?="[^"]*"',
                                    b'', _stripped)

                _root = _ET.fromstring(_stripped)

                def _text(el, tag):
                    child = el.find(tag)
                    return child.text.strip() if child is not None and child.text else None

                def _textall(el, tag):
                    return [c.text.strip() for c in el.findall(tag)
                            if c.text]

                _root_tag = _root.tag  # redirect-information or onboarding-information
                _payload = {}

                if _root_tag == 'onboarding-information':
                    bi_el = _root.find('boot-image')
                    if bi_el is not None:
                        bi = {}
                        uris = _textall(bi_el, 'download-uri')
                        if uris:
                            bi['download-uri'] = uris
                        iv_el = bi_el.find('image-verification')
                        if iv_el is not None:
                            bi['image-verification'] = [{
                                'hash-algorithm': _text(iv_el, 'hash-algorithm') or '',
                                'hash-value': _text(iv_el, 'hash-value') or '',
                            }]
                        _payload['boot-image'] = bi
                    for _f in ('pre-configuration-script', 'configuration-handling',
                               'configuration', 'post-configuration-script'):
                        _v = _text(_root, _f)
                        if _v is not None:
                            _payload[_f] = _v

                elif _root_tag == 'redirect-information':
                    servers = []
                    for s_el in _root.findall('bootstrap-server'):
                        s = {}
                        for _f in ('address', 'port', 'path-prefix'):
                            _v = _text(s_el, _f)
                            if _v is not None:
                                s[_f] = int(_v) if _f == 'port' else _v
                        ta_el = s_el.find('trust-anchor')
                        if ta_el is not None:
                            ta = {}
                            for _f in ('certificate', 'raw-public-key',
                                       'pinned-domain-cert'):
                                _v = _text(ta_el, _f)
                                if _v is not None:
                                    ta[_f] = _v
                            if ta:
                                s['trust-anchor'] = ta
                        servers.append(s)
                    _payload['bootstrap-server'] = servers
                else:
                    raise ValueError(f"unknown root tag: {_root_tag}")

                _json_obj = {f'{_PREFIX}:{_root_tag}': _payload}
                inner_octets = _json.dumps(_json_obj, separators=(',', ':')).encode('utf-8')
                ct = _OID_SZTP_JSON
                print(f"sitecustomize: rev8 JSON eContent for {_root_tag}, "
                      f"len={len(inner_octets)}",
                      file=sys.stderr, flush=True)
            except Exception as _we:
                import traceback as _tb
                print(f"sitecustomize: conveyed-info JSON conversion failed: {_we}",
                      file=sys.stderr)
                _tb.print_exc(file=sys.stderr)

            # EncapsulatedContentInfo
            eci = rfc5652.EncapsulatedContentInfo()
            eci["eContentType"] = univ.ObjectIdentifier(ct)
            eci["eContent"] = univ.OctetString(inner_octets).subtype(
                explicitTag=tag.Tag(tag.tagClassContext, tag.tagFormatSimple, 0))

            # Digest of eContent octets
            content_digest = hashlib.sha256(inner_octets).digest()

            # Signed attributes — the input to the signature is DER(SET OF Attribute)
            # with explicit SET tag (0x31), not IMPLICIT [0] as it appears in SignerInfo.
            signed_attrs_for_sig = _build_signed_attrs(ct, content_digest)
            sig_input = der_encode(signed_attrs_for_sig)

            if _is_ec:
                signature = _owner_key.sign(sig_input, _ec.ECDSA(_hashes.SHA256()))
                sig_alg_oid = _OID_ECDSA_SHA256
            else:
                signature = _owner_key.sign(sig_input, _padding.PKCS1v15(),
                                            _hashes.SHA256())
                sig_alg_oid = _OID_SHA256_RSA

            # Build SignerInfo
            si = rfc5652.SignerInfo()
            si["version"] = 1  # IssuerAndSerialNumber form
            sid = si["sid"]
            iasn = rfc5652.IssuerAndSerialNumber()
            iasn["issuer"] = _issuer
            iasn["serialNumber"] = _serial
            sid["issuerAndSerialNumber"] = iasn
            # digestAlgorithm
            da = si["digestAlgorithm"]
            da["algorithm"] = univ.ObjectIdentifier(_OID_SHA256)
            # signedAttrs — in SignerInfo they use IMPLICIT [0] tag
            sa_for_si = rfc5652.SignedAttributes().subtype(
                implicitTag=tag.Tag(tag.tagClassContext, tag.tagFormatSimple, 0))
            for i in range(len(signed_attrs_for_sig)):
                sa_for_si.setComponentByPosition(i, signed_attrs_for_sig[i])
            si["signedAttrs"] = sa_for_si
            # signatureAlgorithm
            sa_alg = si["signatureAlgorithm"]
            sa_alg["algorithm"] = univ.ObjectIdentifier(sig_alg_oid)
            # signature
            si["signature"] = univ.OctetString(signature)

            # Build SignedData
            sd = rfc5652.SignedData()
            sd["version"] = 1
            # digestAlgorithms SET
            das = sd["digestAlgorithms"]
            d0 = rfc5280.AlgorithmIdentifier()
            d0["algorithm"] = univ.ObjectIdentifier(_OID_SHA256)
            das.setComponentByPosition(0, d0)
            sd["encapContentInfo"] = eci
            # certificates (implicit [0]) — embed full signer chain so that
            # OpenSSL on the device can build signer -> pinned-domain-cert.
            certs = rfc5652.CertificateSet().subtype(
                implicitTag=tag.Tag(tag.tagClassContext, tag.tagFormatConstructed, 0))
            for _i, _ca in enumerate(_chain_certs_asn1):
                cc = rfc5652.CertificateChoices()
                cc["certificate"] = _ca
                certs.setComponentByPosition(_i, cc)
            sd["certificates"] = certs
            # signerInfos
            sis = sd["signerInfos"]
            sis.setComponentByPosition(0, si)

            sd_der = der_encode(sd)
            new_ci = rfc5652.ContentInfo()
            new_ci["contentType"] = rfc5652.id_signedData
            new_ci["content"] = univ.Any(sd_der)
            return der_encode(new_ci)

        def _patched_encode(value, asn1Spec=None):
            try:
                if isinstance(value, rfc5652.ContentInfo):
                    wrapped = _wrap_as_signed_data(value)
                    if wrapped is not None:
                        print(f"sitecustomize: signed+wrapped {len(wrapped)}B CMS SignedData",
                              file=sys.stderr, flush=True)
                        return wrapped
            except Exception as e:
                import traceback
                print(f"sitecustomize: CMS sign/wrap failed: {e}", file=sys.stderr, flush=True)
                traceback.print_exc(file=sys.stderr)
            if asn1Spec is not None:
                return _orig_encode(value, asn1Spec)
            return _orig_encode(value)

        _r.encode_der = _patched_encode
        print("sitecustomize: sztpd CMS output now fully signed (owner cert attached)",
              file=sys.stderr)

        # ------------------------------------------------------------------
        # Also inject owner-certificate (and optionally ownership-voucher)
        # into the RFC 8572 RPC output wrapper. IOS-XE's SZTP client
        # requires owner-certificate whenever conveyed-information is
        # signed, even in the TOFU/DHCP-discovery scenario where RFC 8572
        # §5.3 says it is optional. sztpd 0.0.15 never populates this
        # field, so we splice it in at the utils.obj_to_encoded_str layer.
        # The owner-certificate is a degenerate CMS SignedData bag holding
        # the SBI server's cert chain — same key that signed the
        # conveyed-information, matching the TOFU trust model.
        # ------------------------------------------------------------------
        from sztpd.yangcore import utils as _yc_utils
        _orig_obj_to_str = _yc_utils.obj_to_encoded_str
        _OUTPUT_KEY = "ietf-sztp-bootstrap-server:output"
        _owner_cert_b64 = None
        _owner_chain_path = os.environ.get("SZTP_OWNER_CERT_CMS", "/certs/cert_chain.cms")
        try:
            with open(_owner_chain_path, "rb") as f:
                _owner_cert_b64 = _b64.b64encode(f.read()).decode("ASCII")
            print(f"sitecustomize: loaded owner-certificate from {_owner_chain_path} "
                  f"({len(_owner_cert_b64)} base64 chars)", file=sys.stderr)
        except Exception as e:
            print(f"sitecustomize: could not load owner-cert bag {_owner_chain_path}: {e}",
                  file=sys.stderr)

        _voucher_b64 = None
        _voucher_path = os.environ.get("SZTP_OWNERSHIP_VOUCHER_CMS", "")
        if _voucher_path:
            try:
                with open(_voucher_path, "rb") as f:
                    _voucher_b64 = _b64.b64encode(f.read()).decode("ASCII")
                print(f"sitecustomize: loaded ownership-voucher from {_voucher_path}",
                      file=sys.stderr)
            except Exception as e:
                print(f"sitecustomize: could not load voucher {_voucher_path}: {e}",
                      file=sys.stderr)

        def _patched_obj_to_str(obj, enc, dm, sn, strip_wrapper=False):
            try:
                if (isinstance(obj, dict)
                        and _OUTPUT_KEY in obj
                        and isinstance(obj[_OUTPUT_KEY], dict)
                        and "conveyed-information" in obj[_OUTPUT_KEY]
                        and "owner-certificate" not in obj[_OUTPUT_KEY]
                        and _owner_cert_b64 is not None):
                    obj[_OUTPUT_KEY]["owner-certificate"] = _owner_cert_b64
                    if _voucher_b64 is not None:
                        obj[_OUTPUT_KEY]["ownership-voucher"] = _voucher_b64
                    print("sitecustomize: injected owner-certificate"
                          + (" + ownership-voucher" if _voucher_b64 else "")
                          + " into RPC output", file=sys.stderr, flush=True)
                    result = _orig_obj_to_str(obj, enc, dm, sn, strip_wrapper=strip_wrapper)
                    # Dump the serialized XML so we can see exactly what we're sending
                    try:
                        with open("/tmp/sztp_last_response.xml", "w") as _df:
                            _df.write(result if isinstance(result, str) else result.decode("utf-8", "replace"))
                        print(f"sitecustomize: wrote /tmp/sztp_last_response.xml ({len(result)} chars)",
                              file=sys.stderr, flush=True)
                    except Exception as _de:
                        print(f"sitecustomize: dump failed: {_de}", file=sys.stderr)
                    return result
            except Exception as e:
                print(f"sitecustomize: output-inject failed: {e}", file=sys.stderr)
            return _orig_obj_to_str(obj, enc, dm, sn, strip_wrapper=strip_wrapper)

        _yc_utils.obj_to_encoded_str = _patched_obj_to_str
        print("sitecustomize: obj_to_encoded_str patched to inject owner-certificate",
              file=sys.stderr)
    except Exception as e:
        import traceback
        print(f"sitecustomize: CMS wrapper install failed: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)

# Run the CMS patch after sztpd.rfc8572 is imported. We hook
# builtins.__import__ so we can install the patch the moment that
# module appears in sys.modules — but only AFTER pyasn1 has finished
# loading, to avoid circular-import races.
import builtins
_orig_import = builtins.__import__
_cms_install_in_progress = [False]
def _hooked_import(name, *args, **kwargs):
    mod = _orig_import(name, *args, **kwargs)
    if _cms_install_in_progress[0]:
        return mod
    rfc = sys.modules.get("sztpd.rfc8572")
    if (rfc is not None
        and hasattr(rfc, "encode_der")
        and not getattr(rfc, "_cms_patched", False)
        and "pyasn1.codec.der.decoder" in sys.modules
        and "pyasn1.codec.der.encoder" in sys.modules):
        _cms_install_in_progress[0] = True
        try:
            _install_cms_wrapper_patch()
            rfc._cms_patched = True
        except Exception as e:
            print(f"sitecustomize: deferred CMS install error: {e}", file=sys.stderr)
        finally:
            _cms_install_in_progress[0] = False
    return mod
builtins.__import__ = _hooked_import
EOF
export PYTHONPATH="/tmp/pysite:${PYTHONPATH:-}"

echo "starting server in the background"
sztpd sqlite:///:memory: 2>&1 &

echo "waiting for server to start"
wait_curl "${SZTPD_INIT_PORT}"

echo "sending configuration file to server"
curl -i -X PUT --user my-admin@example.com:my-secret --data @/tmp/running.json -H 'Content-Type:application/yang-data+json' http://127.0.0.1:"${SZTPD_INIT_PORT}"/restconf/ds/ietf-datastores:running

echo "waiting for server to re-start"
wait_curl "${SZTPD_NBI_PORT}"

wait
