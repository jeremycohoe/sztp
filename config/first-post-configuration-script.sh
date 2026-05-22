#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
#
# SZTP Post-Configuration Script — runs AFTER the base configuration merge.
# Executed on the switch by IOS-XE's embedded Python interpreter via the
# `cli` module.
#
# Per-chassis identity model
# --------------------------
# sZTPD matches the device by **PID** (e.g. C9300-24T) — the same response
# is returned to every chassis sharing that PID. This script does the
# per-chassis differentiation on the device itself, after the base config
# has merged.
#
# Steps:
#   1. Discover the chassis serial number from `show version`.
#   2. Look it up in PODS (a static dict shipped inside this script).
#   3. Apply per-pod hostname, management VLAN, and management IP.
#   4. Apply per-pod role flags (uplinks, etc.) if present.
#   5. Save and signal completion.
#
# To onboard new pods, add a row to PODS, regenerate the templates with
# `scripts/render-device-entries.py`, and recreate the bootstrap container.
# The script itself is signed and base64-embedded inside the sZTP CMS
# response — no separate distribution channel needed.
#
# Mirrors the classic-ZTP table at:
#   https://github.com/jeremycohoe/IOSXE-Zero-Touch-Provisioning/blob/main/ztp-xelab.py

from cli import cli, configurep, executep
import re

print("\n*** SZTP Post-Configuration Script Starting ***\n")

# --------------------------------------------------------------------------
# Per-chassis-SN identity table
#   serial : (hostname,        vlan, ipaddr-last-octet)
# Management network is 10.1.1.0/24, default gateway 10.1.1.1, sZTP server
# 10.1.1.3. Pods 1..30 use VLANs 21..50 (vlan = 20 + pod_id).
# --------------------------------------------------------------------------
PODS = {
    # ---- C9300X (HA-SUDI) — odd "a" half of each pod, last octet .5 ----
    "FOC2727Y739": ("cat9300x-pod01a", 21, 5),
    "FOC2727Y6MX": ("cat9300x-pod02a", 22, 5),
    "FOC2727Y75Q": ("cat9300x-pod03a", 23, 5),
    "FOC2727Y767": ("cat9300x-pod04a", 24, 5),
    "FOC2727Y72E": ("cat9300x-pod05a", 25, 5),
    "FOC2727Y72J": ("cat9300x-pod06a", 26, 5),
    "FOC2727Y6TE": ("cat9300x-pod07a", 27, 5),
    "FOC2727Y70N": ("cat9300x-pod08a", 28, 5),
    "FOC2727Y72F": ("cat9300x-pod09a", 29, 5),
    "FOC2727Y72G": ("cat9300x-pod10a", 30, 5),
    "FOC2727Y6ML": ("cat9300x-pod11a", 31, 5),
    "FOC2727Y6TW": ("cat9300x-pod12a", 32, 5),
    "FOC2727Y73C": ("cat9300x-pod13a", 33, 5),
    "FOC2727Y6Z9": ("cat9300x-pod14a", 34, 5),
    "FOC2727Y6EJ": ("cat9300x-pod15a", 35, 5),
    "FOC2727Y71E": ("cat9300x-pod16a", 36, 5),
    "FOC2727Y6MU": ("cat9300x-pod17a", 37, 5),
    "FOC2727Y6X1": ("cat9300x-pod18a", 38, 5),
    "FOC2724YB76": ("cat9300x-pod19a", 39, 5),
    "FOC2727Y73Z": ("cat9300x-pod20a", 40, 5),
    "FOC2724YBQ4": ("cat9300x-pod21a", 41, 5),
    "FOC2724YBQ9": ("cat9300x-pod22a", 42, 5),
    "FOC2724YBQH": ("cat9300x-pod23a", 43, 5),
    "FOC2724YBSA": ("cat9300x-pod24a", 44, 5),
    "FOC2724YBPN": ("cat9300x-pod25a", 45, 5),
    "FOC2724YBPZ": ("cat9300x-pod26a", 46, 5),
    "FOC2724YBP8": ("cat9300x-pod27a", 47, 5),
    "FOC2724YBS5": ("cat9300x-pod28a", 48, 5),
    "FOC2724YBMS": ("cat9300x-pod29a", 49, 5),
    "FOC2724YBPM": ("cat9300x-pod30a", 50, 5),

    # ---- C9300 (ACT2) — even "b" half of each pod, last octet .55 ----
    "FCW2129G042": ("cat9300-pod01b", 21, 55),
    "FCW2129G01K": ("cat9300-pod02b", 22, 55),
    "FCW2129G02M": ("cat9300-pod03b", 23, 55),
    "FCW2129L05L": ("cat9300-pod04b", 24, 55),
    "FCW2129L03E": ("cat9300-pod05b", 25, 55),
    "FCW2241DH93": ("cat9300-pod06b", 26, 55),
    "FCW2126G05V": ("cat9300-pod07b", 27, 55),
    "FCW2241AHB1": ("cat9300-pod08b", 28, 55),
    "FCW2129L0DU": ("cat9300-pod09b", 29, 55),
    "FCW2241AHAT": ("cat9300-pod10b", 30, 55),
    "FCW2129G02U": ("cat9300-pod11b", 31, 55),
    "FCW2129L05A": ("cat9300-pod12b", 32, 55),
    "FCW2241CHAT": ("cat9300-pod13b", 33, 55),
    "FCW2129L049": ("cat9300-pod14b", 34, 55),
    "FCW2241CH9K": ("cat9300-pod15b", 35, 55),
    "FCW2241D0KM": ("cat9300-pod16b", 36, 55),
    "FCW2129G0EF": ("cat9300-pod17b", 37, 55),
    "FCW2129L09E": ("cat9300-pod18b", 38, 55),
    "FCW2241BH95": ("cat9300-pod19b", 39, 55),
    "FCW2241BH96": ("cat9300-pod20b", 40, 55),
    "FCW2129L04A": ("cat9300-pod21b", 41, 55),
    "FCW2241DHBH": ("cat9300-pod22b", 42, 55),
    "FCW2146G095": ("cat9300-pod23b", 43, 55),
    "FCW2241DHBN": ("cat9300-pod24b", 44, 55),
    "FCW2129L02R": ("cat9300-pod25b", 45, 55),
    "FCW2129L03Z": ("cat9300-pod26b", 46, 55),
    "FCW2129G03A": ("cat9300-pod27b", 47, 55),
    "FCW2129G03G": ("cat9300-pod28b", 48, 55),
    "FCW2129G0PZ": ("cat9300-pod29b", 49, 55),
    "FCW2129L05N": ("cat9300-pod30b", 50, 55),

    # ---- C9350 "c" devices (FVH*) --------------------------------------
    # Mgmt last-octet = .15 (a=.5 / c=.15 / b=.55)
    "FVH2943LHRX": ("cat9350-pod01c", 21, 15),
    "FVH2943LJQX": ("cat9350-pod02c", 22, 15),
    "FVH2944LC8A": ("cat9350-pod03c", 23, 15),
    "FVH2943LHUA": ("cat9350-pod04c", 24, 15),
    "FVH2943LJKM": ("cat9350-pod05c", 25, 15),
    "FVH2943LJWE": ("cat9350-pod06c", 26, 15),
    "FVH2944LDKS": ("cat9350-pod07c", 27, 15),
    "FVH2944LCXF": ("cat9350-pod08c", 28, 15),
    "FVH2943LHSM": ("cat9350-pod09c", 29, 15),
    "FVH2943LJ3Z": ("cat9350-pod10c", 30, 15),
    "FVH2943LJ0E": ("cat9350-pod11c", 31, 15),
    "FVH2943LJNK": ("cat9350-pod12c", 32, 15),
    "FVH2944L1ZY": ("cat9350-pod13c", 33, 15),
    "FVH2943LHSV": ("cat9350-pod14c", 34, 15),
    "FVH2943LJFE": ("cat9350-pod15c", 35, 15),
    "FVH2944LEXF": ("cat9350-pod16c", 36, 15),
    "FVH2943LK9C": ("cat9350-pod17c", 37, 15),
    "FVH2943LJN5": ("cat9350-pod18c", 38, 15),
    "FVH2943LHME": ("cat9350-pod19c", 39, 15),
    "FVH2944LEXA": ("cat9350-pod20c", 40, 15),
    "FVH2943LHMV": ("cat9350-pod21c", 41, 15),
    "FVH2944L20P": ("cat9350-pod22c", 42, 15),
    "FVH2944LDFS": ("cat9350-pod23c", 43, 15),
    "FVH2944LDFR": ("cat9350-pod24c", 44, 15),
    "FVH2944LDBP": ("cat9350-pod25c", 45, 15),
    "FVH2943LHZZ": ("cat9350-pod26c", 46, 15),
    "FVH2944L20B": ("cat9350-pod27c", 47, 15),
    "FVH2943LJHN": ("cat9350-pod28c", 48, 15),  # was UNKNOWN — only remaining staged FVH
    "FVH2943LJUZ": ("cat9350-pod29c", 49, 15),
    "FVH2944L204": ("cat9350-pod30c", 50, 15),
}


def discover_chassis_sn():
    """Return chassis serial number, or None if it can't be parsed."""
    out = cli("show version | include System Serial Number") or ""
    m = re.search(r":\s*(\S+)", out)
    return m.group(1) if m else None


def apply_pod_identity(hostname, vlan, last_octet):
    """Set hostname, mgmt VLAN, and mgmt IP for this pod."""
    print(f"*** Applying pod identity: {hostname} vlan={vlan} ip=10.1.1.{last_octet} ***")
    configurep([f"hostname {hostname}", "end"])

    # Create the per-pod VLAN, move mgmt onto it, drop default Vlan1 IP.
    configurep([f"vlan {vlan}", "end"])
    configurep(["interface Vlan1", "no ip address", "shutdown", "end"])
    configurep([
        f"interface Vlan{vlan}",
        f" ip address 10.1.1.{last_octet} 255.255.255.0",
        " no shutdown",
        "end",
    ])

    # Default route via the sZTP server / lab gateway (mirrors classic ZTP).
    configurep(["ip route 0.0.0.0 0.0.0.0 10.1.1.3", "end"])


def apply_uplink_role(hostname):
    """Set per-platform uplink port descriptions."""
    if hostname.startswith("cat9300x-"):
        # C9300X uses Ten/TwentyFive Gig uplinks
        configurep(["interface Te1/0/1", "description LINK-C9300", "end"])
        configurep(["interface Te1/0/3", "description LINK-C9300X", "end"])
    elif hostname.startswith("cat9300-"):
        # Classic C9300 uses Gig uplinks
        configurep(["interface Gi1/0/1", "description LINK-C9300", "end"])
        configurep(["interface Gi1/0/3", "description LINK-C9300X", "end"])


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
chassis_sn = discover_chassis_sn()
print(f"*** Chassis serial: {chassis_sn} ***")

if chassis_sn and chassis_sn in PODS:
    hostname, vlan, last_octet = PODS[chassis_sn]
    apply_pod_identity(hostname, vlan, last_octet)
    apply_uplink_role(hostname)
else:
    # Unknown chassis — leave a clear breadcrumb in the running config.
    fallback = f"sztp-unprovisioned-{chassis_sn or 'unknown'}"
    print(f"*** Chassis SN {chassis_sn!r} not in PODS table — using fallback hostname {fallback} ***")
    configurep([f"hostname {fallback}", "end"])

# --------------------------------------------------------------------------
# Common day-0 hardening (applies to every pod)
# --------------------------------------------------------------------------
print("*** Enabling gNMI ***")
configurep([
    "gnxi",
    " gnxi secure-init",
    " gnxi secure-allow-self-signed-trustpoint",
    "end",
])

print("*** TCP / TFTP tuning for management traffic ***")
configurep(["ip tcp window-size 65535", "ip tftp blocksize 8192", "end"])

print("*** Saving configuration ***")
executep("write memory")

# Light the blue beacon to signal SZTP completion (C9300X / C9500X).
print("*** Enabling blue beacon (best-effort) ***")
executep("hw-module beacon slot active on")

print("\n*** SZTP Post-Configuration Complete ***")
executep("show running-config | include hostname|netconf|restconf|gnxi")
executep("show ip interface brief | exclude unassigned")
