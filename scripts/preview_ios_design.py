#!/usr/bin/env python3
"""Launch an installed Debug Talaria app with the synthetic iPhone UI fixture.

Start scripts/fixtures/mobile_design_gateway.py separately, then run:
    python3 scripts/preview_ios_design.py --device <SIMULATOR-UDID> --tab Home
    python3 scripts/preview_ios_design.py --device <SIMULATOR-UDID> \
        --tab Home --destination approval --keyboard

Requires a booted Simulator with com.talaria.native.ios already installed. This
runner does not build, install, boot a device, or start a gateway. It replaces
the running Talaria process on the selected Simulator. All fixture data is
synthetic; this verifies presentation, not real Hermes backend integration.

Credentials are read from the current user's private, unexpired fixture handoff
and passed only through SIMCTL_CHILD_ environment variables. They never appear
in the launch arguments or this script's output. Preview routing is Debug-only.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
from urllib.parse import urlsplit
import uuid


HANDOFF = Path("/tmp/talaria-ios-design-fixture.json")
BUNDLE_ID = "com.talaria.native.ios"
PREFIX = "SIMCTL_CHILD_TALARIA_DESIGN_"
MAX_HANDOFF_BYTES = 16_384


def read_handoff(path: Path, session: str) -> tuple[str, str, str]:
    """Open once without following a final symlink; validate that exact file."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) & 0o077 or info.st_nlink != 1):
            raise ValueError("The fixture handoff must be a private regular file owned by the current user (0600).")
        if not 0 < info.st_size <= MAX_HANDOFF_BYTES:
            raise ValueError("The fixture handoff has an invalid size.")
        raw = source.read(MAX_HANDOFF_BYTES + 1)
        if len(raw) > MAX_HANDOFF_BYTES:
            raise ValueError("The fixture handoff is too large.")
    data = json.loads(raw)
    if not isinstance(data, dict) or data.get("fixture_kind") != "synthetic-mobile-design-only":
        raise ValueError("This runner accepts only the synthetic mobile design fixture.")
    expiry = data.get("expires_at")
    if (isinstance(expiry, bool) or not isinstance(expiry, (int, float)) or not math.isfinite(expiry)
            or not 0 < expiry - time.time() <= 1800):
        raise ValueError("The fixture has expired or does not have a valid lifetime of at most 30 minutes.")
    url = data.get("base_url")
    if not isinstance(url, str) or len(url) > 2048 or any(char.isspace() for char in url):
        raise ValueError("The fixture URL is invalid.")
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError as error:
        raise ValueError("The fixture URL is invalid.") from error
    # The app's Debug connector intentionally permits only this loopback address.
    if (parts.scheme != "http" or parts.hostname != "127.0.0.1" or not port
            or parts.username is not None or parts.password is not None
            or parts.query or parts.fragment or parts.path not in ("", "/")):
        raise ValueError("The fixture must use an HTTP URL on 127.0.0.1 with an explicit port.")
    token = data.get("token")
    sessions = data.get("session_ids")
    session_id = sessions.get(session) if isinstance(sessions, dict) else None
    for label, value, maximum in (("token", token, 4096), ("session ID", session_id, 512)):
        if (not isinstance(value, str) or not value.strip() or len(value) > maximum
                or any(ord(char) < 32 or ord(char) == 127 for char in value)):
            raise ValueError(f"The fixture {label} is missing or invalid.")
    if data.get("profile") != "default":
        raise ValueError("The design fixture must use the default profile.")
    return url, token, session_id


def device_id(value: str) -> str:
    try:
        return str(uuid.UUID(value)).upper()
    except ValueError as error:
        raise argparse.ArgumentTypeError("Use the Simulator device UDID from xcrun simctl list devices.") from error


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", type=device_id, required=True, help="UDID of an already booted Simulator")
    parser.add_argument("--tab", choices=("Home", "Workspaces", "Automations", "Activity"), default="Home")
    parser.add_argument("--session", choices=("home", "chat", "approval", "inbox"), default="home")
    parser.add_argument("--destination", choices=("workspace", "approval", "automation", "run", "failed-run", "no-output", "conversation", "discuss", "activity-request"))
    parser.add_argument("--home", choices=("selected", "unselected", "unavailable"), default="selected")
    parser.add_argument("--appearance", choices=("system", "dark"), default="system")
    parser.add_argument("--large-type", action="store_true", help="Use accessibility text size within this preview only")
    parser.add_argument("--keyboard", action="store_true", help="Focus the composer in the conversation preview")
    parser.add_argument("--handoff", type=Path, default=HANDOFF)
    args = parser.parse_args(argv)
    try:
        url, token, session_id = read_handoff(args.handoff, args.session)
    except (OSError, ValueError) as error:
        # JSON decode errors contain positions, not the credential-bearing input.
        print(f"Cannot launch the design preview: {error}", file=sys.stderr)
        return 1
    environment = {key: value for key, value in os.environ.items() if not key.startswith(PREFIX)}
    environment.update({PREFIX + "PREVIEW": "1", PREFIX + "URL": url, PREFIX + "TOKEN": token,
                        PREFIX + "SESSION": session_id, PREFIX + "TAB": args.tab,
                        PREFIX + "KEYBOARD": "1" if args.keyboard else "0", PREFIX + "HOME": args.home,
                        PREFIX + "DESTINATION": args.destination or "", PREFIX + "APPEARANCE": args.appearance,
                        PREFIX + "LARGE_TYPE": "1" if args.large_type else "0"})
    command = ["xcrun", "simctl", "launch", "--terminate-running-process", args.device, BUNDLE_ID]
    try:
        result = subprocess.run(command, env=environment, stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, timeout=45)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"Simulator launch failed: {error}", file=sys.stderr)
        return 1
    if result.returncode:
        detail = result.stderr.replace(token, "[redacted]").strip()[:2000]
        print(f"Simulator launch failed: {detail or 'Check that the device is booted and Talaria Debug is installed.'}", file=sys.stderr)
        return result.returncode
    print(f"Opened Talaria's synthetic {args.tab} preview ({args.session}) on {args.device}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
