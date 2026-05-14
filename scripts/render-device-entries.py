#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# render-device-entries.py
#
# Regenerate the `wn-sztpd-1:device-types` and `wn-sztpd-1:devices` arrays
# in both sztpd JSON templates from a flat PID catalog
# (config/cisco-pids.txt). Idempotent — safe to re-run after editing the
# catalog.
#
# Usage:
#   scripts/render-device-entries.py [--catalog config/cisco-pids.txt]
#                                    [--repo-root .]
#                                    [--check]   # exit non-zero if any change
#
# Effect:
#   - config/sztpd.redirect.json.template  →  device entries reference
#                                              "my-redirect-information"
#   - config/sztpd.running.json.template   →  device entries reference
#                                              "first-onboarding-information"
#
# Two device-types are emitted (regardless of catalog content):
#   - cisco-act2-device-type   → my-device-identity-ca-cert-act2-sudi
#   - cisco-hasudi-device-type → my-device-identity-ca-cert-circa-2020
#
# Each device entry uses the device-type matching its `sudi_generation`
# from the catalog.

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

DEVICE_TYPES = {
    "act2": {
        "name": "cisco-act2-device-type",
        "identity-certificates": {
            "verification": {
                "local-truststore-reference": {
                    "certificate-bag": "my-device-identity-ca-certs",
                    "certificate": "my-device-identity-ca-cert-act2-sudi",
                },
            },
            "serial-number-extraction": "wn-x509-c2n:serial-number",
        },
    },
    "hasudi": {
        "name": "cisco-hasudi-device-type",
        "identity-certificates": {
            "verification": {
                "local-truststore-reference": {
                    "certificate-bag": "my-device-identity-ca-certs",
                    "certificate": "my-device-identity-ca-cert-circa-2020",
                },
            },
            "serial-number-extraction": "wn-x509-c2n:serial-number",
        },
    },
}

# Per-template response fragment keyed by template basename.
RESPONSES = {
    "sztpd.redirect.json.template": {
        "conveyed-information": {
            "redirect-information": {"reference": "my-redirect-information"},
        },
    },
    "sztpd.running.json.template": {
        "conveyed-information": {
            "onboarding-information": {"reference": "first-onboarding-information"},
        },
    },
}


def parse_catalog(path: Path) -> list[tuple[str, str]]:
    """Return a list of (pid, sudi_generation) pairs from the catalog file."""
    entries: list[tuple[str, str]] = []
    seen: set[str] = set()
    for lineno, raw in enumerate(path.read_text().splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "," not in line:
            raise ValueError(f"{path}:{lineno}: expected 'PID,gen' got {raw!r}")
        pid, gen = (p.strip() for p in line.split(",", 1))
        if not pid:
            raise ValueError(f"{path}:{lineno}: empty PID")
        if gen not in DEVICE_TYPES:
            raise ValueError(
                f"{path}:{lineno}: sudi_generation must be one of "
                f"{sorted(DEVICE_TYPES)}, got {gen!r}"
            )
        if pid in seen:
            raise ValueError(f"{path}:{lineno}: duplicate PID {pid!r}")
        seen.add(pid)
        entries.append((pid, gen))
    if not entries:
        raise ValueError(f"{path}: no PID entries found")
    return entries


def build_devices(pids: list[tuple[str, str]], response: dict) -> list[dict]:
    """One device entry per PID, all sharing the same response shape."""
    return [
        {
            "serial-number": pid,
            "device-type": DEVICE_TYPES[gen]["name"],
            "response-manager": {
                "matched-response": [
                    {"name": "catch-all-response", "response": response},
                ],
            },
        }
        for pid, gen in pids
    ]


def render_template(
    template_path: Path,
    pids: list[tuple[str, str]],
) -> bool:
    """Rewrite device-types and devices in `template_path`. Returns True if changed.

    Templates contain unquoted $VAR shell substitutions (e.g. `: $SZTPD_NBI_PORT`)
    which are not valid JSON. We quote them with a sentinel before parsing,
    then unquote them after dumping so the file remains shell-substitutable.
    """
    name = template_path.name
    response = RESPONSES[name]

    raw = template_path.read_text()

    # Quote unquoted shell vars: ": $VAR" -> ": \"@@VAR_NAME@@\""
    # Match colon-space-$IDENT followed by , } ] or whitespace.
    sentinel_re = re.compile(r":\s*\$([A-Za-z_][A-Za-z0-9_]*)")
    quoted = sentinel_re.sub(lambda m: f': "@@VAR_{m.group(1)}@@"', raw)

    data = json.loads(quoted)

    data["wn-sztpd-1:device-types"] = {
        "device-type": [DEVICE_TYPES[g] for g in ("act2", "hasudi")],
    }
    data["wn-sztpd-1:devices"] = {"device": build_devices(pids, response)}

    new_quoted = json.dumps(data, indent=2) + "\n"

    # Restore: "@@VAR_X@@" -> $X (drops the quotes).
    new_raw = re.sub(r'"@@VAR_([A-Za-z_][A-Za-z0-9_]*)@@"', r"$\1", new_quoted)

    if new_raw == raw:
        return False
    template_path.write_text(new_raw)
    return True


def main() -> int:
    p = argparse.ArgumentParser(
        description="Regenerate sztpd device-types and devices arrays from "
                    "the Cisco PID catalog (config/cisco-pids.txt).",
    )
    p.add_argument(
        "--catalog",
        type=Path,
        default=Path("config/cisco-pids.txt"),
        help="path to PID catalog (default: config/cisco-pids.txt)",
    )
    p.add_argument(
        "--repo-root",
        type=Path,
        default=Path("."),
        help="repository root (default: cwd)",
    )
    p.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if templates would change (for CI)",
    )
    args = p.parse_args()

    catalog = (args.repo_root / args.catalog).resolve()
    pids = parse_catalog(catalog)
    print(f"loaded {len(pids)} PIDs from {catalog}", file=sys.stderr)

    changed = False
    for name in RESPONSES:
        path = (args.repo_root / "config" / name).resolve()
        if not path.exists():
            print(f"WARNING: template not found: {path}", file=sys.stderr)
            continue
        if render_template(path, pids):
            print(f"updated {path}", file=sys.stderr)
            changed = True
        else:
            print(f"unchanged {path}", file=sys.stderr)

    if args.check and changed:
        print("ERROR: templates are out of date; rerun without --check", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
