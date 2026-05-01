#!/usr/bin/env python3
"""
sztp_console_test.py — SZTP iteration script using conserver console access.

Connects to the switch via SSH → conserver → console ts199-line28.
Navigates the IOS-XE setup wizard, collects the SZTP trace log, and
optionally issues 'pnpa service reset no-prompt' to trigger a new test cycle.

Usage:
    python3 sztp_console_test.py                 # pull log then reset
    python3 sztp_console_test.py --pull-log-only # just collect the log
    python3 sztp_console_test.py --reset-only    # just reset without pulling log first
    python3 sztp_console_test.py --minutes 30    # set log window (default 20)
"""

import argparse
import re
import sys
import time

import paramiko

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CONSERVER_HOST = "128.107.223.248"
CONSERVER_USER = "auto"
CONSERVER_PASS = "G0ldl@bs247"
CONSOLE_NAME   = "ts199-line28"
ENABLE_PASS    = "EN-TME-Cisco123"

RELOAD_WAIT    = 300  # seconds to wait after pnpa service reset before re-attaching
# ---------------------------------------------------------------------------


def _drain(chan, timeout: float = 3.0) -> str:
    """Read whatever is buffered on the channel."""
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if chan.recv_ready():
            buf += chan.recv(4096)
        else:
            time.sleep(0.2)
    return buf.decode("utf-8", errors="replace")


# Matches any IOS-XE privileged-mode prompt:  Switch#  sztp-provisioning#  etc.
_PRIV_PROMPT = r"[A-Za-z0-9._-]+#"
# Matches any IOS-XE user-mode prompt
_USER_PROMPT = r"[A-Za-z0-9._-]+>"


def _wait_for(chan, patterns: list, timeout: float = 30.0,
              send_cr_interval: float = 8.0) -> tuple:
    """
    Wait until one of the regex patterns matches accumulated channel output.

    Returns (index_of_matched_pattern, full_accumulated_output).
    Returns (-1, output) on timeout.
    """
    buf = ""
    deadline = time.time() + timeout
    last_cr = time.time()
    compiled = [re.compile(p, re.DOTALL | re.IGNORECASE) for p in patterns]

    while time.time() < deadline:
        if chan.recv_ready():
            chunk = chan.recv(4096).decode("utf-8", errors="replace")
            buf += chunk
            for i, pat in enumerate(compiled):
                if pat.search(buf):
                    return i, buf
        else:
            time.sleep(0.3)
            if send_cr_interval > 0 and (time.time() - last_cr) > send_cr_interval:
                chan.send("\r")
                last_cr = time.time()

    return -1, buf


def open_console():
    """
    SSH to conserver host and attach to the named console.
    Returns (paramiko.SSHClient, paramiko.Channel).
    """
    print(f"[*] SSH {CONSERVER_USER}@{CONSERVER_HOST} → console {CONSOLE_NAME}")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        CONSERVER_HOST,
        username=CONSERVER_USER,
        password=CONSERVER_PASS,
        look_for_keys=False,
        allow_agent=False,
        timeout=15,
    )
    chan = client.invoke_shell(term="vt100", width=220, height=50)
    time.sleep(2)
    _drain(chan)

    chan.send(f"console {CONSOLE_NAME}\n")
    time.sleep(3)
    _drain(chan)
    return client, chan


def navigate_to_enable(chan):
    """
    Navigate whatever state the switch console is in and arrive at Switch#.

    Handles:
      - Already at Switch> or Switch#
      - IOS-XE first-boot "Would you like to enter the initial config dialog?"
      - "Press RETURN to get started"
    """
    print("[console] Waking console...")
    chan.send("\r")

    idx, out = _wait_for(chan, [
        r"Would you like to enter the initial configuration dialog",
        _PRIV_PROMPT,
        _USER_PROMPT,
        r"Press RETURN to get started",
    ], timeout=40, send_cr_interval=6)

    if idx == 0:
        print("[console] Setup wizard — answering 'no'...")
        chan.send("no\n")
        _wait_for(chan, [r"Enter enable secret:"], timeout=20)
        chan.send(f"{ENABLE_PASS}\n")
        _wait_for(chan, [r"Confirm enable secret:"], timeout=10)
        chan.send(f"{ENABLE_PASS}\n")
        _wait_for(chan, [r"Enter your selection"], timeout=15)
        chan.send("0\n")
        idx, out = _wait_for(chan, [r"Press RETURN to get started",
                                    _USER_PROMPT, _PRIV_PROMPT], timeout=30)

    if idx == 3 or (idx >= 0 and "Press RETURN" in out):
        chan.send("\r")
        _wait_for(chan, [_USER_PROMPT, _PRIV_PROMPT], timeout=30, send_cr_interval=5)

    # Enter enable mode
    print("[console] Entering enable mode...")
    chan.send("en\n")
    idx2, _ = _wait_for(chan, [r"Password:", _PRIV_PROMPT], timeout=10)
    if idx2 == 0:
        chan.send(f"{ENABLE_PASS}\n")
        _wait_for(chan, [_PRIV_PROMPT], timeout=10)

    chan.send("term len 0\n")
    _drain(chan, timeout=2)
    chan.send("terminal no monitor\n")
    _drain(chan, timeout=2)
    # Capture current hostname for display
    chan.send("\r")
    _, snap = _wait_for(chan, [_PRIV_PROMPT], timeout=8, send_cr_interval=3)
    m = re.search(r"([A-Za-z0-9._-]+)#", snap)
    hostname = m.group(1) if m else "device"
    print(f"[console] At {hostname}#")


def pull_sztp_log(chan, minutes: int = 20) -> str:
    """Run show logging process sztp internal and return raw output."""
    print(f"[console] Pulling SZTP log (last {minutes} min)...")
    chan.send(
        f"show logging process sztp internal start last {minutes} minutes\n"
    )
    _, out = _wait_for(chan, [_PRIV_PROMPT], timeout=90, send_cr_interval=0)
    return out


def pnpa_reset(chan) -> str:
    """Issue pnpa service reset no-prompt."""
    print("[console] Issuing pnpa service reset no-prompt...")
    chan.send("pnpa service reset no-prompt\n")
    idx, out = _wait_for(chan, [r"PnP reset is done", _PRIV_PROMPT], timeout=30)
    print("[console] Reset issued — switch will reload in ~30 seconds.")
    return out


def print_sztp_summary(log_output: str) -> bool:
    """
    Print SZTP-relevant lines from the log.
    Returns True if the log contains a successful parse (no ERR on parse line).
    """
    keywords = re.compile(
        r"(parse|conveyed|Failed|verified|onboard|redirect|ERR\):|bootstrap|"
        r"signature|script|configuration|boot.image|progress)",
        re.IGNORECASE,
    )
    print("\n" + "=" * 70)
    print("SZTP LOG SUMMARY")
    print("=" * 70)
    lines = [ln for ln in log_output.splitlines()
             if "[sztp]" in ln and keywords.search(ln)]
    if not lines:
        print("  (no matching sztp lines found)")
    for ln in lines:
        # trim the long timestamp/host prefix, keep the message part
        m = re.search(r"\[sztp\]\s+\[\d+\]:\s+\(\w+\):\s+(.*)", ln)
        ts_m = re.search(r"(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}\.\d+)", ln)
        ts = ts_m.group(1)[-12:] if ts_m else "             "
        msg = m.group(1) if m else ln.strip()
        tag = "(ERR)" if "(ERR)" in ln else "(note)"
        print(f"  {ts}  {tag:7}  {msg}")
    print("=" * 70 + "\n")

    # Success check: no parse error and "signature is verified" present
    success = (
        "Conveyed info signature is verified" in log_output
        and "Failed to parse the conveyed info xml" not in log_output
        and "Bootstrapping not received" not in log_output
    )
    if success:
        print("[SUCCESS] SZTP conveyed info parsed successfully!")
    else:
        last_err = next(
            (ln.strip() for ln in reversed(log_output.splitlines())
             if "[sztp]" in ln and "(ERR)" in ln),
            "unknown error",
        )
        print(f"[FAIL] SZTP failed. Last error: {last_err}")
    return success


def main():
    parser = argparse.ArgumentParser(description="SZTP console test runner")
    parser.add_argument("--pull-log-only", action="store_true",
                        help="Only pull the log, do not reset")
    parser.add_argument("--reset-only", action="store_true",
                        help="Only reset, skip pre-reset log pull")
    parser.add_argument("--minutes", type=int, default=20,
                        help="SZTP log window in minutes (default: 20)")
    args = parser.parse_args()

    client, chan = open_console()
    try:
        navigate_to_enable(chan)

        if not args.reset_only:
            log = pull_sztp_log(chan, minutes=args.minutes)
            print_sztp_summary(log)

        if not args.pull_log_only:
            pnpa_reset(chan)

            # Detach from conserver during reload
            chan.send("\x05c.")  # Ctrl-E c . = conserver detach
            print(f"[*] Waiting {RELOAD_WAIT}s for switch to reload...")
            time.sleep(RELOAD_WAIT)

            # Re-attach
            print("[*] Re-attaching to console...")
            chan.send(f"console {CONSOLE_NAME}\n")
            time.sleep(4)
            navigate_to_enable(chan)

            log2 = pull_sztp_log(chan, minutes=args.minutes)
            print_sztp_summary(log2)

    finally:
        try:
            chan.send("\x05c.")
        except Exception:
            pass
        client.close()
        print("[*] Console session closed.")


if __name__ == "__main__":
    main()
