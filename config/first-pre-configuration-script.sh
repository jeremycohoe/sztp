#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
# SZTP Pre-Configuration Script — runs BEFORE configuration merge
# Executed by IOS XE embedded Python interpreter via the cli module

from cli import configurep, executep
import time

print("\n\n*** SZTP Pre-Configuration Script Starting (FCW2129G03A) ***\n")

# Identify the device
print("*** Device inventory ***")
executep("show version | include Serial|Model|IOS")

# Ensure basic VTY access is available before the main config merge
print("*** Enabling temporary console access ***")
configurep(["line con 0", "logging synchronous", "exec-timeout 0 0", "end"])
configurep(["line vty 0 15", "transport input ssh telnet", "exec-timeout 30 0", "end"])

# Set a temporary hostname so the device is identifiable during provisioning
configurep(["hostname sztp-provisioning", "end"])

print("*** Pre-configuration complete — proceeding to configuration merge ***\n")
