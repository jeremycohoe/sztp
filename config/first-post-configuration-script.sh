#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
# SZTP Post-Configuration Script — runs AFTER configuration merge
# Executed by IOS XE embedded Python interpreter via the cli module

from cli import configurep, executep
import time

print("\n\n*** SZTP Post-Configuration Script Starting ***\n")

# Verify hostname was set by the configuration merge
print("*** Verifying configuration was applied ***")
executep("show running-config | include hostname")
executep("show ip interface brief | exclude unassigned")
executep("show version | include uptime")

# Enable gNMI (requires NETCONF-YANG to be up first)
print("*** Enabling gNMI ***")
configurep(["gnxi", "gnxi secure-init", "gnxi secure-allow-self-signed-trustpoint", "end"])

# TCP tuning for management traffic
configurep(["ip tcp window-size 65535", "ip tftp blocksize 8192", "end"])

# Save the configuration
print("*** Saving configuration (write memory) ***")
executep("write memory")

# Light the blue beacon to signal SZTP completion — C9300X only
print("*** Enabling blue beacon to signal provisioning complete ***")
executep("hw-module beacon slot active on")

print("\n\n*** SZTP Post-Configuration Complete for FCW2129G03A ***\n")
executep("show running-config | include hostname|netconf|restconf|gnxi")
