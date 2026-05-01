#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jeremy Cohoe
"""Encode SZTP redirect URLs as RFC 8572 §8.2 DHCPv4 option 143 payload.

Payload format (RFC 8572 §8.2):
    option 143 = concatenation of 1..N URI records
    URI record = uint16 length (big-endian) || URI bytes (UTF-8)

Input:
    One or more URIs as CLI args, or a single comma-separated SZTP_URL env var.
    All URIs must be https://.

Output formats (select with --format):
    colon  : "00:15:68:74:..."  (ISC dhcpd binary literal; default)
    hex    : "00156874..."      (lower-case hex, no separators; IOS-XE dhcp pool)
    ios    : "0015.6874.74..."  (IOS dotted-hex groups of 2 bytes)

Exit codes:
    0 success
    2 bad input (scheme, length, encoding)
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Iterable


class EncodeError(ValueError):
    """Raised when inputs cannot be encoded as a valid option-143 payload."""


def encode_option143(urls: Iterable[str]) -> bytes:
    """Return the binary option-143 payload for one or more https URIs."""
    url_list = [u.strip() for u in urls if u and u.strip()]
    if not url_list:
        raise EncodeError("at least one URI is required")

    out = bytearray()
    for url in url_list:
        if not url.startswith("https://"):
            raise EncodeError(f"URI must start with https:// (got {url!r})")
        try:
            url_bytes = url.encode("ascii")
        except UnicodeEncodeError as exc:
            raise EncodeError(f"URI must be ASCII: {url!r}") from exc
        if len(url_bytes) > 0xFFFF:
            raise EncodeError(
                f"URI length {len(url_bytes)} exceeds 65535-byte uint16 limit"
            )
        out.append((len(url_bytes) >> 8) & 0xFF)
        out.append(len(url_bytes) & 0xFF)
        out.extend(url_bytes)
    return bytes(out)


def format_colon(payload: bytes) -> str:
    return ":".join(f"{b:02x}" for b in payload)


def format_hex(payload: bytes) -> str:
    return payload.hex()


def format_ios(payload: bytes) -> str:
    # IOS dotted-hex: groups of 2 bytes separated by '.'
    hex_str = payload.hex()
    # Pad to even number of bytes for grouping; option 143 is always even so
    # no padding is actually needed in practice.
    groups = [hex_str[i : i + 4] for i in range(0, len(hex_str), 4)]
    return ".".join(groups)


FORMATTERS = {
    "colon": format_colon,
    "hex": format_hex,
    "ios": format_ios,
}


def parse_urls_from_args(args: argparse.Namespace) -> list[str]:
    if args.urls:
        return args.urls
    env_value = os.environ.get("SZTP_URL", "").strip()
    if env_value:
        return [u.strip() for u in env_value.split(",") if u.strip()]
    return []


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("urls", nargs="*", help="https:// URIs; overrides SZTP_URL env var")
    parser.add_argument(
        "--format",
        choices=sorted(FORMATTERS.keys()),
        default="colon",
        help="output format (default: colon)",
    )
    args = parser.parse_args(argv)

    urls = parse_urls_from_args(args)
    try:
        payload = encode_option143(urls)
    except EncodeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    print(FORMATTERS[args.format](payload))
    return 0


if __name__ == "__main__":
    sys.exit(main())
