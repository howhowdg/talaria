"""Test-only Python network fence. Imported through this fixture's PYTHONPATH.

The real Hermes backend still runs its real HTTP, WebSocket and agent code. Only
outbound non-loopback Python sockets are forbidden, so a missing mock-provider
configuration cannot accidentally call a paid service during the smoke test.
"""

import ipaddress
import os
import sys


if os.environ.get("HERMES_NATIVE_SMOKE_LOOPBACK_ONLY") == "1":
    def _is_loopback(host):
        if isinstance(host, bytes):
            host = host.decode("ascii", errors="replace")
        if host == "localhost":
            return True
        try:
            return ipaddress.ip_address(str(host).split("%", 1)[0]).is_loopback
        except ValueError:
            return False

    def _check_network(event, args):
        if event == "socket.connect":
            address = args[1]
            # AF_UNIX paths stay available to Python's local process machinery.
            if isinstance(address, tuple) and not _is_loopback(address[0]):
                raise PermissionError("Native smoke fixture forbids outbound network connections")
        elif event == "socket.getaddrinfo" and not _is_loopback(args[0]):
            raise PermissionError("Native smoke fixture forbids outbound DNS lookups")

    sys.addaudithook(_check_network)
