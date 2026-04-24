# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jeremy Cohoe

"""Unit tests for scripts/encode_sztp_url.py (RFC 8572 §8.2)."""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

# Import the encoder from scripts/ without installing anything.
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import encode_sztp_url as enc  # noqa: E402


class EncodeOption143Tests(unittest.TestCase):
    def test_single_url_known_fixture(self) -> None:
        # Matches the hex already shipped in dhcp/dhcpd.conf for
        # "https://10.1.1.3:8080" (22 bytes = 0x0016? let's compute).
        url = "https://10.1.1.3:8080"
        payload = enc.encode_option143([url])
        self.assertEqual(payload[:2], bytes([0x00, len(url)]))
        self.assertEqual(payload[2:].decode("ascii"), url)
        # Length byte sanity: "https://10.1.1.3:8080" is 21 chars => 0x15.
        self.assertEqual(len(url), 0x15)
        self.assertEqual(payload[0:2], b"\x00\x15")

    def test_colon_format_matches_existing_dhcpd_conf(self) -> None:
        expected = "00:15:68:74:74:70:73:3a:2f:2f:31:30:2e:31:2e:31:2e:33:3a:38:30:38:30"
        payload = enc.encode_option143(["https://10.1.1.3:8080"])
        self.assertEqual(enc.format_colon(payload), expected)

    def test_multi_url_concatenates_length_prefixed_records(self) -> None:
        urls = ["https://a.example:8080", "https://b.example:9090"]
        payload = enc.encode_option143(urls)
        # Two length-prefixed segments back-to-back.
        off = 0
        for url in urls:
            length = (payload[off] << 8) | payload[off + 1]
            self.assertEqual(length, len(url))
            self.assertEqual(payload[off + 2 : off + 2 + length].decode("ascii"), url)
            off += 2 + length
        self.assertEqual(off, len(payload))

    def test_rejects_non_https(self) -> None:
        for bad in ["http://x", "ftp://x", "x", "", "   "]:
            with self.subTest(url=bad):
                with self.assertRaises(enc.EncodeError):
                    enc.encode_option143([bad] if bad.strip() else [bad])

    def test_rejects_empty_list(self) -> None:
        with self.assertRaises(enc.EncodeError):
            enc.encode_option143([])

    def test_rejects_too_long_uri(self) -> None:
        long_url = "https://" + ("a" * (0xFFFF - len("https://") + 1))
        with self.assertRaises(enc.EncodeError):
            enc.encode_option143([long_url])

    def test_ios_format_groups_in_dotted_hex(self) -> None:
        payload = enc.encode_option143(["https://10.1.1.3:9090"])
        ios = enc.format_ios(payload)
        # Two-byte groups separated by '.'; trailing group may be 1 byte if
        # the payload length is odd. Lower-case hex only.
        self.assertRegex(ios, r"^[0-9a-f]{4}(\.[0-9a-f]{4})*(\.[0-9a-f]{2})?$")
        # Round-trip: strip dots, hex-decode, equal to payload.
        self.assertEqual(bytes.fromhex(ios.replace(".", "")), payload)

    def test_hex_format_plain(self) -> None:
        payload = enc.encode_option143(["https://10.1.1.3:8080"])
        self.assertEqual(enc.format_hex(payload), payload.hex())

    def test_env_var_comma_separated(self) -> None:
        os.environ["SZTP_URL"] = "https://a.example:8080, https://b.example:9090"
        try:
            rc = enc.main(["--format", "hex"])
            # main() returned 0 and used env var when no CLI urls provided.
            self.assertEqual(rc, 0)
        finally:
            del os.environ["SZTP_URL"]


if __name__ == "__main__":
    unittest.main()
