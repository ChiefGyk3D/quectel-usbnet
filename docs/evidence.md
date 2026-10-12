# Evidence

What was observed, and how to see the same thing on your own machine. Observed and inferred are kept apart. Identifiers (hostname, IMEI, USB serial) are removed.

## Setup

- Quectel EM160R-GL, `2c7c:0620`, firmware `EM160RGLAUR02A07M4G`, in an M.2 slot wired to USB 3
- Debian 13 base, ModemManager 1.24.0, libmbim 1.32.0, libqmi 1.36.0, kernel 7.1

## The device is healthy (observed)

```
usb 4-4: new SuperSpeed USB device number 3 using xhci_hcd
usb 4-4: New USB device found, idVendor=2c7c, idProduct=0620
option 4-4:1.0: GSM modem (1-port) converter detected   (four of these, ttyUSB1-4)
cdc_mbim 4-4:1.4: cdc-wdm0: USB WDM device
cdc_mbim 4-4:1.4 wwan0: register 'cdc_mbim' at usb-0000:00:14.0-4, CDC MBIM
```

No resets, no disconnects, no over-current, no downgrade to USB 2. USB `authorized` was `1` and `power/control` was `on`.

`mbimcli`, run while ModemManager was not holding the port, answered:

```
mbimcli -d /dev/cdc-wdm0 --query-radio-state
    Hardware radio state: 'on'
    Software radio state: 'on'
```

So the firmware was alive and talking MBIM. The failure is narrower than "the modem does not respond".

## What ModemManager did (observed)

```
creating modem with plugin 'quectel' and '6' ports (2c7c:0620)
[modem0/cdc-wdm0/mbim] MBIM device is QMI capable
[modem0/cdc-wdm0/mbim] (shared-quectel) MBIM device is AT capable
...
[modem0] port cdc-wdm0 timed out 2 consecutive times
[modem0] port cdc-wdm0 timed out 3 consecutive times
...
[modem0] port cdc-wdm0 timed out 10 consecutive times, marking modem as invalid
couldn't set version: Unknown revision
error initializing: Operation was cancelled
```

It reproduced on every ModemManager restart, about three minutes each time, with nothing else touching the port.

## Which request goes unanswered (observed, debug log)

`mmcli -G DEBUG`, then the journal. Transactions 1 through 20 each get a reply. They cover the MBIM basics, the SIM slots, and the `ms-uicc-low-level-access` service. Then:

```
sent message  transaction = 21   service = 'qdu' (6427015f-579d-48f5-8c54-f43ed1e76f83)
   ... no reply ...
sent message  transaction = 22   service = 'qdu'
   ... no reply ...
sent message  transaction = 23   service = 'qdu'
```

Every later retry is the same `qdu` service and none is answered.

## What it means (inferred, not proven)

QDU is the MBIM firmware-update service. ModemManager has a Quectel path that sends a QDU request to read the full firmware version (a merge request titled "quectel: add read firmware info with MBIM QDU"). That fits what the trace shows, and a firmware that ignores the service would produce exactly this. I could not open that merge request, so I do not know which ModemManager release added it or whether it falls back when the modem is silent.

I found no public report that matches this exactly. The closest is a Quectel forum thread about an RM520N-GL where `cdc-wdm0` times out repeatedly and ModemManager marks the modem invalid. Quectel's own engineer there said they did not know which message goes unanswered, and nothing was confirmed fixed.

## The fix, and what it shows (observed)

```
AT+QCFG="usbnet"      +QCFG: "usbnet",2
AT+QCFG="usbnet",0    OK
AT+CFUN=1,1           OK
```

After the reset:

```
qmi_wwan 4-4:1.4: cdc-wdm0: USB WDM device
qmi_wwan 4-4:1.4 wwan0: register 'qmi_wwan' at usb-0000:00:14.0-4, WWAN/QMI device
```

ModemManager listed the modem about 30 seconds after it started, with `cdc-wdm0 (qmi)` as the primary port and two AT ports. It registered on LTE (home network, about 80% signal), NetworkManager brought the connection up, and pings through the modem interface lost nothing.

## Reproducing the diagnosis

```
quectel-usbnet status
sudo journalctl -b -u ModemManager | grep -E 'timed out|marking modem'
sudo mmcli -G DEBUG && sudo systemctl restart ModemManager   # then read the journal for 'qdu'
sudo mmcli -G INFO                                           # put it back
```

Do not run `mbimcli` against the same port while ModemManager is starting. It closes ModemManager's session.
