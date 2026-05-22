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


# Visual marker so sZTP-onboarded devices are distinguishable from
# classic-ZTP-onboarded ones at a glance (e.g. cat9300-pod22b-sztp).
SZTP_HOSTNAME_SUFFIX = "-sztp"


def apply_pod_identity(hostname, vlan, last_octet):
    """Set hostname (with -sztp suffix), mgmt VLAN, and mgmt IP for this pod."""
    sztp_hostname = f"{hostname}{SZTP_HOSTNAME_SUFFIX}"
    print(f"*** Applying pod identity: {sztp_hostname} vlan={vlan} ip=10.1.1.{last_octet} ***")
    configurep([f"hostname {sztp_hostname}", "end"])

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

    # Set HTTP/TFTP source interface so management traffic uses the pod VLAN.
    configurep([
        f"ip http client source-interface Vlan{vlan}",
        f"ip tftp source-interface Vlan{vlan}",
        "end",
    ])

    # Push all access ports onto the pod VLAN (range commands per platform).
    # Best-effort: any range that doesn't exist on this platform is ignored.
    for cmd_range in (
        f"interface range Gi1/0/1 - 24",
        f"interface range Gi1/0/1 - 48",
        f"interface range Te1/0/1 - 48",
    ):
        try:
            configurep([cmd_range, f" switchport access vlan {vlan}", "end"])
        except Exception as e:
            print(f"DEBUG: range {cmd_range} not applicable: {e}")


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

is_c9350 = False
show_inv = cli("show inventory | include PID") or ""
if "C9350" in show_inv:
    is_c9350 = True

if chassis_sn and chassis_sn in PODS:
    hostname, vlan, last_octet = PODS[chassis_sn]
    apply_pod_identity(hostname, vlan, last_octet)
    apply_uplink_role(hostname)
else:
    # Unknown chassis — leave a clear breadcrumb in the running config.
    fallback = f"sztp-unprovisioned-{chassis_sn or 'unknown'}{SZTP_HOSTNAME_SUFFIX}"
    print(f"*** Chassis SN {chassis_sn!r} not in PODS table — using fallback hostname {fallback} ***")
    configurep([f"hostname {fallback}", "end"])
    vlan = None  # skip per-VLAN follow-ons

# --------------------------------------------------------------------------
# Common day-0 hardening (applies to every pod)
# Ported from /var/www/html/ztp-simple.py — runs alongside the NETCONF merge
# in first-configuration.xml. AAA / SSH / NETCONF / RESTCONF / NTP / DNS /
# default route / logging buffered / scp / service timestamps are already
# applied by that XML merge and are NOT duplicated here.
# --------------------------------------------------------------------------

print("*** Enabling gNMI ***")
configurep([
    "gnxi",
    " gnxi secure-init",
    " gnxi secure-allow-self-signed-trustpoint",
    " gnxi server",
    "end",
])

print("*** TCP / TFTP tuning for management traffic ***")
configurep(["ip tcp window-size 65535", "ip tftp blocksize 8192", "end"])

# CoPP rate tuning — speeds up day-0 image / file pulls.
print("*** Applying CoPP policy for faster image download ***")
copp_commands = [
    "policy-map system-cpp-policy",
    " class system-cpp-police-forus",
    "  police rate 20000 pps",
]
if not is_c9350:
    # These classes don't exist on the C9350 / Q200-based platforms.
    copp_commands += [
        " class system-cpp-police-data",
        "  police rate 20000 pps",
        " class system-cpp-police-sys-data",
        "  police rate 20000 pps",
    ]
copp_commands += [
    " class system-cpp-police-sw-forward",
    "  police rate 20000 pps",
    "end",
]
try:
    configurep(copp_commands)
except Exception as e:
    print(f"DEBUG: CoPP tuning skipped: {e}")

# VTP transparent — required for the lab's per-pod VLAN model.
print("*** Setting VTP mode transparent ***")
configurep(["vtp mode transparent", "end"])

# Catch-all EEM applet — every CLI command is mirrored to syslog.
print("*** Installing catch-all EEM applet ***")
configurep([
    "no event manager applet catchall",
    "event manager applet catchall",
    ' event cli pattern ".*" sync no skip no',
    ' action 1 syslog msg "$_cli_msg"',
    "end",
])

# Loopback0 for router-id / NETCONF source / lab IGP.
print("*** Creating Loopback0 ***")
configurep([
    "interface Loopback0",
    " ip address 192.168.12.1 255.255.255.0",
    "end",
])

# SNMP RO community (YANG Suite SNMP→YANG mapping use case).
print("*** Enabling SNMP RO community ***")
configurep(["snmp-server community Cisco123 RO", "end"])

# Line VTY (line vty 0 32, transport all, no idle timeout) — beyond XML merge.
print("*** Tuning VTY lines ***")
configurep([
    "line vty 0 32",
    " transport input all",
    " exec-timeout 0 0",
    "end",
])
configurep([
    "line con 0",
    " logging synchronous limit 1000",
    "end",
])

# Additional syslog target (UDP 5144 — lab MDT collector).
print("*** Adding syslog target 10.1.1.3:5144 ***")
configurep(["logging host 10.1.1.3 transport udp port 5144", "end"])

# Clock / timezone — XML merge sets NTP server only.
print("*** Setting timezone (Pacific) ***")
configurep([
    "clock timezone Pacific -8 0",
    "clock summer-time PDST recurring",
    "end",
])
configurep([
    "service timestamps debug datetime msec localtime show-timezone year",
    "service timestamps log datetime msec localtime show-timezone year",
    "end",
])

# Boot enable-break for OOB recovery (lab convenience).
print("*** Enabling boot break ***")
configurep(["boot enable-break switch 1", "end"])

# Telemetry / MDT dial-out subscriptions to the lab collector on 10.1.1.3:57500.
print("*** Configuring MDT telemetry subscriptions ***")
MDT_SUBS = [
    (6041337,  "/process-cpu-ios-xe-oper:cpu-usage/cpu-utilization/five-seconds", 30000),
    (2024001,  "/environment-sensors",                                                60000),
    (2024002,  "/oc-platform:components",                                              60000),
    (2024003,  "/platform-ios-xe-oper:components/component",                           60000),
    (2024004,  "/platform-ios-xe-oper:components/component/platform-properties/platform-property", 60000),
    (2024005,  "/poe-oper-data/poe-module",                                            60000),
    (2024006,  "/poe-oper-data/poe-port-detail",                                       60000),
    (2024007,  "/poe-oper-data/poe-stack",                                             60000),
    (2024008,  "/poe-oper-data/poe-switch",                                            60000),
]
for sub_id, xpath, period in MDT_SUBS:
    try:
        configurep([
            f"telemetry ietf subscription {sub_id}",
            " encoding encode-kvgpb",
            f" filter xpath {xpath}",
            " stream yang-push",
            f" update-policy periodic {period}",
            " receiver ip address 10.1.1.3 57500 protocol grpc-tcp",
            "end",
        ])
    except Exception as e:
        print(f"DEBUG: MDT sub {sub_id} skipped: {e}")

# Pre-provision Guest Shell + NAT (VLAN 4094, 192.168.2.0/24).
print("*** Pre-provisioning Guest Shell + NAT ***")
configurep(["iox", "end"])
configurep([
    "ip access-list standard NAT_ACL",
    " permit 192.168.0.0 0.0.255.255",
    "end",
])
configurep(["ip nat inside source list NAT_ACL interface Vlan1 overload", "end"])
configurep(["vlan 4094", "end"])
configurep([
    "interface Vlan4094",
    " ip address 192.168.2.1 255.255.255.0",
    " ip nat inside",
    " ip routing",
    "end",
])
configurep(["ip route 0.0.0.0 0.0.0.0 10.1.1.3", "end"])
configurep([
    "app-hosting appid guestshell",
    " app-vnic AppGigabitEthernet trunk",
    "  vlan 4094 guest-interface 0",
    "   guest-ipaddress 192.168.2.2 netmask 255.255.255.0",
    "  exit",
    " app-default-gateway 192.168.2.1 guest-interface 0",
    " name-server0 10.1.1.3",
    " app-resource profile custom",
    "  cpu-percent 100",
    "  memory 7000",
    "  persist-disk 65535",
    "end",
])
for app_iface in ("AppGigabitEthernet1/0/1", "AppGigabitEthernet1/0/2"):
    try:
        configurep([f"interface {app_iface}", " switchport mode trunk", "end"])
    except Exception as e:
        print(f"DEBUG: {app_iface} not present: {e}")

print("*** Saving configuration ***")
executep("write memory")

# Light the blue beacon to signal SZTP completion (C9300X / C9500X / C9350).
print("*** Enabling blue beacon (best-effort) ***")
executep("hw-module beacon slot active on")

print("\n*** SZTP Post-Configuration Complete ***")
executep("show running-config | include hostname|netconf|restconf|gnxi")
executep("show ip interface brief | exclude unassigned")
