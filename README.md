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


## Keep the cellular link a quiet fallback: `uplink`

Once the modem works, a second problem shows up: it works too well. With Wi-Fi up and healthy the modem still carried traffic. Two causes, both measured on one laptop:

1. Wi-Fi had no IPv6, so the modem held the only IPv6 default route, and every client that prefers IPv6 used cellular.
2. A zero-trust VPN client picks one default gateway and interface and binds its own sockets to it, ignoring route metrics. It bound everything to the modem while Wi-Fi was healthy.

Route metrics cannot fix either, and a firewall that blocks the modem does not help an application that picked the modem on purpose (its tunnel and DNS just died). What did work: with `ipv4.never-default` and `ipv6.never-default` set on the modem profile, the modem stayed connected and kept its address but held no default route, and the VPN client moved every socket to Wi-Fi on its own.

`quectel-usbnet uplink` turns that into a rule. The order is always Ethernet, then Wi-Fi, then cellular, and **only the best healthy link holds default routes**. Everything else is `never-default`. It runs as you, with no sudo, no root service, no firewall and no nftables, using `nmcli device modify`, which NetworkManager applies to the running connection with a reapply (a runtime change, not a profile change).

```
quectel-usbnet uplink status [--json]    # what is going on; --json is the tray's contract
quectel-usbnet uplink auto               # Ethernet, then Wi-Fi, then cellular (the default)
quectel-usbnet uplink cell-first [--for 2h]   # cellular first, then back to auto on its own
quectel-usbnet uplink run [--dry-run]    # one evaluation; the timer calls this
quectel-usbnet uplink install            # prints the steps; runs nothing
quectel-usbnet uplink uninstall          # prints the steps; runs nothing
```

### How it decides

- A link is healthy when a ping bound to its interface answers one of two public targets (2 s timeout each). Two failures in a row take an up link down, two successes bring a down one back. All probes run in parallel under one 12 s deadline, and one that hangs gets TERM, then KILL.
- `auto`: the owner is Ethernet if healthy, else Wi-Fi if healthy, else cellular (the last resort, whether or not it can be measured).
- `cell-first`: cellular owns the defaults and Ethernet and Wi-Fi are `never-default` (their connected subnet routes stay, so the local network still works). It expires after `--for` (`30m`, `2h`, `1d`, up to `30d`; `0` means never; the default is `2h`) so cellular data is not burned by accident. If cellular is not connected it refuses to start, and if the modem drops while it is active the normal order takes over, so asking for cellular can never strand the machine.
- Interface names come from NetworkManager device types (`ethernet`, `wifi`, `gsm`), never hard-coded, and every name is checked against a plain-name pattern before it reaches a command. NetworkManager is always read with `LC_ALL=C` and `--escape no`.
- The first run after a login never demotes a working link: with no history, a link that holds a default route counts as up.

How a change is made, so the machine is never left without a default route: the new owner's defaults are added first, and the route table is read back (`ip route show default`) to confirm they are there. Only then are the other links demoted, and the table is read again, with one retry. If it still is not right, everything is put back and the run exits non-zero. Default routes on interfaces it does not manage (a full-tunnel VPN, a bridge) are left alone.

Fail safe: bad input, a missing tool, an `nmcli` or `ip` error, a malformed state file or an out-of-range setting makes `run` change nothing, log why and exit non-zero.

### Two things you should know it cannot do

- A link that holds no default route cannot reach the internet bound to itself. So a link this manager demoted (Ethernet or Wi-Fi) is probed through its own gateway (taken from the DHCP lease), which only proves the local link is alive. To keep a gateway that answers while the internet behind it is dead from making the owner flap, a link that failed a real probe has to stay down for 120 s before it can come back. If a demoted link has no known gateway, it cannot be measured and the manager stays where it is (look for the log line saying so).
- The modem holds no default route while it is idle, so it is not measured then. It reads as healthy when it is connected, and it is measured as soon as it carries traffic.

### Install (user level, nothing runs until you run it)

```
quectel-usbnet uplink install
```

prints a block of steps for you to read and run. They do four things: set `ipv4.never-default yes` and `ipv6.never-default yes` on every `gsm` profile (found from NetworkManager by type, since the profile name differs per machine; this is stored in the profile and is the one change that outlives the manager), copy the script to `~/.local/libexec/quectel-usbnet-uplink`, write a `systemd --user` service and a timer that runs `uplink run` every 15 seconds, and run one evaluation. The unit carries absolute paths for `nmcli`, `ip`, `ping`, `flock` and `timeout`, resolved when you ran `install`, and a fixed `PATH=/usr/sbin:/usr/bin`. It refuses to overwrite a file it did not write.

The mode (`auto` or `cell-first`, with its end time) is kept in `$XDG_RUNTIME_DIR/quectel-usbnet/`, so a reboot or logout always goes back to `auto`.

### `status --json`

```
{"mode":"auto|cell-first","owner":"ethernet|wifi|cell|none",
 "links":{"ethernet":{"state":"up|down|absent","healthy":true},"wifi":{...},"cell":{...}},
 "until":"<iso or null>","since":"<iso>"}
```

`owner` is whoever holds a default route right now, read from the route table. `state` is NetworkManager's: `up` is connected, `down` is a device that exists but is not connected, `absent` is no such device. `since` is when the mode was set. It reads and prints, exit 0; if it cannot read NetworkManager or the routes it prints nothing on stdout and exits 1.

### If the manager stops

A stopped, crashed or uninstalled manager leaves the system usable: the modem profile stays closed (`never-default`), and every link keeps whatever it had at that moment. The one case to know: if it stopped while cellular was the owner (Wi-Fi had failed), cellular keeps its default routes and Wi-Fi stays without them until it reconnects. To return to a clean state, in this order:

```
quectel-usbnet uplink auto                  # if the copy is still installed
nmcli device reapply <each device>          # or: nmcli connection up <each profile>
```

`uplink uninstall` prints the steps that stop the timer, run `uplink auto`, remove the units, the copy and the state files (only ones carrying this tool's marker), and say how to reopen the modem profile if you ever want that.

### The modem guard it replaces

An earlier approach (#22) put an nftables guard on the modem interface. It kept the modem up and rejected its traffic, but the VPN client stayed bound to the modem and its tunnel died. It is superseded and not part of this script. If you installed it from that branch, `quectel-usbnet guard-uninstall` prints the steps that remove it.

### Settings

All are environment variables with safe defaults, checked at start (a bad value changes nothing): `QUECTEL_UPLINK_TARGETS` (`"1.1.1.1 9.9.9.9"`), `QUECTEL_UPLINK_FAILS` (2), `QUECTEL_UPLINK_OKS` (2), `QUECTEL_UPLINK_HOLD` (120 s), `QUECTEL_UPLINK_PING_TIMEOUT` (2 s), `QUECTEL_UPLINK_DEADLINE` (12 s), `QUECTEL_UPLINK_MAX_DEVICES` (4 per link type). The unit sets only the tool paths.

### What I have and have not run

The decision logic, the flapping hysteresis, the expiry, the malformed-input and tool-failure paths, the order of the `nmcli` calls and the printed steps are tested against fake `nmcli`, `ip` and `ping` (`tests/uplink.sh`), with a fake route table that the fake `nmcli` changes, so "never no default route" and "the old owner's routes are intact after a failure" are checked, not assumed. The read-only commands (`status`, `run --dry-run`) were run against a real NetworkManager. The real `nmcli device modify`/`reapply` changes, the timer, a Wi-Fi radio-off failover and the VPN client re-binding have not been run by the test suite; those are the live checks (modem counters flat with Wi-Fi up, failover within about 45 s, `cell-first` and back, lab and DNS reachable at every step).

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
