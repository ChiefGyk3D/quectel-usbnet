# quectel-usbnet

I put a Quectel EM160R-GL in a laptop, the kernel found every piece of it, `lsusb` listed it, and `mmcli -L` said "No modems were found". So I spent an evening convinced the card was badly seated, and it wasn't.

This is the fix, and a small script that applies it and undoes it. The short version: the modem was in MBIM mode, ModemManager 1.24 never finished setting it up, and switching the card to QMI mode (`AT+QCFG="usbnet",0`) made it work immediately.

## Do you have this problem

All of these at once:

- `lsusb` shows `2c7c:...` (Quectel), at SuperSpeed if it is a USB 3 card
- `/dev/cdc-wdm0` and a few `/dev/ttyUSB*` exist
- `dmesg` shows `cdc_mbim` binding, no resets, no disconnects
- `mmcli -L` says `No modems were found`
- the ModemManager journal says `port cdc-wdm0 timed out 10 consecutive times, marking modem as invalid`

If the card is missing from `lsusb`, or it falls back to USB 2, that is a different problem and a reseat is a fair thing to try. This repo is for the case where the hardware is fine.

`quectel-usbnet status` checks the list for you and reads nothing it should not.

## The fix

```
sudo install -m 0755 quectel-usbnet /usr/local/bin/
quectel-usbnet status
sudo quectel-usbnet set qmi
```

`set` stops ModemManager, finds the AT port, reads the current mode and prints the command that rolls it back, sets the new mode, confirms it reads back, resets the modem, waits for `qmi_wwan` to bind, and starts ModemManager again. If anything fails after it stopped ModemManager, it starts it again on the way out. `--dry-run` prints those steps and touches nothing.

To go back:

```
sudo quectel-usbnet set mbim
```

You can do it by hand if you would rather not run a script against your modem, and you should know what it does either way. Stop ModemManager, then on the AT port (on mine `/dev/ttyUSB3`, `ttyUSB4` also works, `ttyUSB2` only echoes):

```
AT+QCFG="usbnet"        -> +QCFG: "usbnet",2     (MBIM, what it shipped with)
AT+QCFG="usbnet",0      -> OK                    (QMI)
AT+CFUN=1,1             -> OK                    (reset, it re-enumerates)
```

Start ModemManager again and the modem shows up on `cdc-wdm0` with `qmi_wwan`. The mode lives in the modem's own storage, so it should survive a reboot, but I have only watched it survive a ModemManager restart and a modem reset so far.

## The SIM is "missing" but the card is in the slot

A second, different failure, seen in QMI mode. ModemManager marks the modem `failed: sim-missing` (`mmcli -m 0` shows the failed state), and its journal says `Illegal SIM/USIM application state`. Meanwhile `AT+CPIN?` on the AT port answers `READY`. The modem is fine and so is the SIM; the USIM application inside the modem is stuck in the QMI state `illegal`, and ModemManager does not retry.

It showed up after a suspend/resume and after a reboot, on the EM160R-GL with firmware `EM160RGLAUR02A07M4G`. I have seen it on that one card only.

`quectel-usbnet status` now prints the USIM application state (read with `qmicli -d /dev/cdc-wdmN --uim-get-card-status`, slot 1, application 1) and flags `illegal` as a wedged SIM.

The recovery is a power cycle of the SIM, with ModemManager out of the way:

```
sudo quectel-usbnet sim-recover
```

It stops ModemManager, runs `--uim-sim-power-off=1`, waits a couple of seconds, runs `--uim-sim-power-on=1`, polls up to 15 seconds for the application state `ready`, and starts ModemManager again. ModemManager is started again on any error too. If the SIM is already `ready` it says so and touches nothing. By hand, it is the same three `qmicli` calls with `systemctl stop ModemManager` before and `systemctl start ModemManager` after. After it, the modem registered and the data connection passed traffic.

For scripts, stdout carries exactly one line and progress goes to stderr:

```
sim-recover: ready       already fine, nothing done (exit 0)
sim-recover: recovered   power cycled, now ready (exit 0)
sim-recover: failed      never became ready, or an error (exit 1)
```

`--device /dev/cdc-wdmN` picks the node when there is more than one. The state reads (`status`, and the checks in `sim-recover`) use `qmicli -p`, which goes through `qmi-proxy`, so they are safe while ModemManager has the modem open. I have not run that on hardware. The power-off and power-on calls run with ModemManager stopped and do not use the proxy.

## After suspend/resume: `recover`

On the same laptop, after a resume the tray showed no modem while `lsusb` still listed `2c7c:0620`. A reboot fixed it. `recover` is the no-reboot version, and it needs no internet:

```
quectel-usbnet recover --dry-run     # print the ladder, touch nothing
quectel-usbnet recover
```

It climbs a ladder and stops at the first rung after which `mmcli -L` lists a modem and `nmcli device` shows the `cdc-wdm` device as anything but `unavailable`. Each rung prints what it did and what it then observed.

1. `nmcli radio wwan on`. A resume can leave the WWAN radio software-disabled.
2. `mmcli -m <n> --enable`, for a listed modem whose state is `disabled`.
3. Restart ModemManager, then wait for the modem. The wait has an iteration cap, so it cannot hang.
4. Toggle `authorized` to 0 then 1 on the USB device with ID `2c7c:0620`. It is found through sysfs by vendor and product ID, never by bus path.
5. `AT+CFUN=1,1` on the AT port. This resets the modem and drops its connections, so it only runs if you answer `y` at the prompt or pass `--yes`. Without a terminal and without `--yes` it is printed, not sent.

Rungs 1 and 2 run as you. Rungs 3 to 5 need root, so `recover` re-runs itself with `sudo` (or `pkexec` if there is no `sudo`) and picks up at rung 3. If nothing works, it says so and exits 1. If `lsusb` no longer lists the card, only a full power cycle is left.

### Run it automatically after resume (opt-in)

Nothing installs this unless you ask:

```
quectel-usbnet install-resume-hook --dry-run   # show the hook and the paths
sudo quectel-usbnet install-resume-hook
```

The hook runs as root after every resume, so it must never run a file you can edit. The install copies the script to `/usr/local/libexec/quectel-usbnet` (`install -m 0755 -o root -g root`) and writes `/usr/lib/systemd/system-sleep/quectel-usbnet-recover`, which runs only that copy. `--tool PATH` only chooses which script is copied. The install refuses to continue if either directory is not owned by root or is writable by group or others, and it will not overwrite a hook or a copy it did not write. Run it again after you update the script to refresh the copy.

After resume the hook waits 5 seconds and runs `recover` in the background under `timeout 300`, with the output going to the journal (`journalctl -t quectel-usbnet`). It never delays the resume, and because it has no terminal it never sends the rung 5 reset. Before each run it checks that the copy is a regular file (not a symlink), owned by root, and not writable by group or others, in a directory that meets the same test. If not, it logs a refusal and does nothing.

To remove both files, only if quectel-usbnet wrote them:

```
sudo quectel-usbnet uninstall-resume-hook
```

The cause is not proven. See [docs/evidence.md](docs/evidence.md) for what was observed and what is inferred.

### recover and sim-recover are separate

They overlap in one respect: both can follow a suspend/resume, and both stop and start ModemManager. They fix different things and neither calls the other. `recover` is for a modem that is missing or unusable (no modem in `mmcli -L`, or the `cdc-wdm` device `unavailable` in NetworkManager). `sim-recover` is for a modem that is listed but failed with `sim-missing` because the USIM application is stuck in the QMI state `illegal`. If `recover` brings the modem back and `status` then shows an `illegal` SIM, run `sim-recover` next.


## What was going wrong

I turned ModemManager's logging up to debug (`mmcli -G DEBUG`) and read what it sent. It gets through MBIM setup normally for twenty transactions (device caps, SIM slots, UICC access), then sends a request on the `qdu` service, and the modem never answers it. Every retry gets silence, ten timeouts at about twenty seconds each, and ModemManager marks the modem invalid and does not try again.

That is the observed part. What I am inferring is that the QDU request is the cause. QDU is the firmware-update service, and ModemManager has a Quectel path that uses it to read the full firmware version, so it fits, but I could not read the merge request that added it (the site blocked my fetch) and I have not seen anyone confirm it. Switching to QMI fixes it, which is consistent with that and does not prove it.

The trace is in [docs/evidence.md](docs/evidence.md).

One more thing I got wrong along the way, so you do not: do not point `mbimcli` at `cdc-wdm0` while ModemManager is initializing. It opens and closes the device, which tears down ModemManager's own MBIM session and makes its next command fail with `NotOpened`. That muddied one of my tests.

## What I have tested

- Quectel EM160R-GL, firmware `EM160RGLAUR02A07M4G` (the AU variant), on USB 3
- Debian 13 base (Parrot 7.3), kernel 7.1, ModemManager 1.24.0, libmbim 1.32.0, libqmi 1.36.0
- MBIM mode: fails every time. QMI mode: registers on LTE, connects, passes traffic

I have not tried it on any other Quectel module. As far as I know the `usbnet` setting is documented for other Quectel families too, so the script is not specific to this card, but I have not checked that the mode numbers mean the same thing everywhere, and that is an assumption. Only `qmi` and `mbim` have run on hardware. `ecm` and `rndis` are in the table because the numbers are documented, and they are untested.

The tests (`tests/run.sh`) run the AT conversation against a fake modem on a pty, so they cover the parsing and the command line. The `recover` ladder and the resume hook are tested against stub `nmcli`, `mmcli` and `systemctl` and a fake sysfs tree, and `sim-recover` against a fake `qmicli` and `systemctl` (ready, wedged then fixed, never ready, power-off error), so no test touches a real modem, SIM or service. The `set` reset path and the real `recover` rungs have not been run on hardware beyond the one card.

## Firmware

A newer firmware might make the QDU request work. Quectel does not publish builds. They send them on request through their forum or support, privately, and I did not find a version list. Mine is A07 and one forum post mentions A011 on the AU branch, which I have not confirmed. If you get a newer build and it fixes MBIM, tell me, and I will add it here.

## If it does not work for you

Open an issue with the output of `quectel-usbnet status`, your ModemManager and libmbim versions (`ModemManager --version`, `dpkg -l libmbim-glib4`), the modem's `ATI` output, and the lines around the first `timed out` in the debug log. Leave out your IMEI, your serial numbers, and your hostname. They show up in those logs and nothing here needs them.

## License

GPL-3.0, see [LICENSE](LICENSE).
