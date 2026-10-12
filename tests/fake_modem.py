"""A pretend Quectel modem on a pty, for tests/run.sh.

Prints the slave tty path on its first line, then answers the handful of AT
commands quectel-usbnet sends. Runs until it is killed.
"""

import os
import pty
import sys
import tty

master, slave = pty.openpty()
tty.setraw(slave)
print(os.ttyname(slave), flush=True)

usbnet = 2  # starts in MBIM, like the real card
pending = b""

while True:
    try:
        chunk = os.read(master, 1024)
    except OSError:
        break
    if not chunk:
        break
    pending += chunk
    while b"\r" in pending:
        raw, pending = pending.split(b"\r", 1)
        cmd = raw.decode(errors="replace").strip()
        if cmd == "ATI":
            body = "Quectel\r\nEM160R-GL\r\nRevision: EM160RGLAUR02A07M4G\r\n\r\nOK"
        elif cmd == 'AT+QCFG="usbnet"':
            body = f'+QCFG: "usbnet",{usbnet}\r\n\r\nOK'
        elif cmd.startswith('AT+QCFG="usbnet",'):
            usbnet = int(cmd.rsplit(",", 1)[1])
            body = "OK"
        elif cmd == "AT+CFUN=1,1":
            body = "OK"
        else:
            body = "ERROR"
        os.write(master, f"\r\n{body}\r\n".encode())

sys.exit(0)
