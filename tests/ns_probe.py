#!/usr/bin/env python3
"""Send one UDP datagram out of the dummy interface wwan0 and say what happened.

usage: ns_probe.py FAMILY DEST PORT SPORT

FAMILY is 4 or 6, SPORT is a source port or - for any. Prints one word:
  rejected  the guard's reject: ECONNREFUSED or EPERM on the send
  passed    nothing came back: the packet left the interface
  error:X   anything else
Only meant to run inside a private network namespace (tests/ns_guard.sh).
"""

import errno
import socket
import sys

family, dest, port, sport = sys.argv[1:5]
af = socket.AF_INET if family == "4" else socket.AF_INET6
sock = socket.socket(af, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"wwan0")
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.settimeout(1.0)
try:
    if sport != "-":
        sock.bind(("0.0.0.0" if af == socket.AF_INET else "::", int(sport)))
    if family == "4":
        addr = (dest, int(port))
    else:
        addr = (dest, int(port), 0, socket.if_nametoindex("wwan0"))
    sock.connect(addr)
    sock.send(b"x")
    sock.recv(10)
except (ConnectionRefusedError, PermissionError):
    print("rejected")
except socket.timeout:
    print("passed")
except OSError as exc:
    print("error:%s" % errno.errorcode.get(exc.errno, exc.errno))
else:
    print("passed")
