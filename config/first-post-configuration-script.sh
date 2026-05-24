#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
#
# SZTP Post-Configuration Script — INTENTIONALLY A NO-OP.
#
# All day-0 configuration is performed by the pre-configuration script
# (config/first-pre-configuration-script.sh, which is ztp-simple.py).
# The sZTP onboarding-information response still requires a post-script
# element, so this file exists only to satisfy that contract.
#
# Do not add device configuration here — put it in the pre-script.

print("\n*** SZTP Post-Configuration Script: no-op (config done by pre-script) ***\n")
