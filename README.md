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
2. A zero-trust VPN client picks one default gateway and interface and binds its own sockets to it, ignoring route metrics. With Wi-Fi (metric 600) and cellular (1100) both holding default routes it bound everything to the modem.

Route metrics cannot fix either, and a firewall that blocks the modem does not help an application that picked the modem on purpose (its tunnel and DNS just died). What did work: with `ipv4.never-default` and `ipv6.never-default` set on the modem profile and only Wi-Fi holding default routes, the VPN client bound to Wi-Fi and everything worked. The client's exact rule is not known, so the design does not depend on it: it keeps the situation simple wherever that matters.

### The design

`quectel-usbnet uplink` runs as you. No sudo, no root service, no firewall. It uses `nmcli device modify`.

```
quectel-usbnet uplink status [--json]    # what is going on; --json is the tray's contract
quectel-usbnet uplink auto               # the default
quectel-usbnet uplink cell-first [--for 2h]   # cellular first, then back to auto on its own
quectel-usbnet uplink run [--dry-run]    # one evaluation; the timer calls this
quectel-usbnet uplink restore            # put back every change the manager recorded
quectel-usbnet uplink install            # prints the steps; runs nothing
quectel-usbnet uplink uninstall          # prints the steps; runs nothing
```

- **`auto` touches only cellular.** The cellular profile is closed (`never-default` on both families, set once by the install steps), so after a boot, a reconnect or a crash it holds no default route and nothing is bound to it. Ethernet and Wi-Fi are never changed in `auto`: they keep their own NetworkManager defaults and metrics (Ethernet automatic 100, Wi-Fi 600). That is also what makes them measurable at any time, because each still holds a default route, so a ping bound to its interface reaches the real internet. Every link is judged by a real probe, never by whether its gateway answers.
- **Failover.** When Ethernet and Wi-Fi have both been unhealthy for two rounds (two probes, 15 s apart), cellular is opened: `never-default` off and a route metric of 50 for the open period. Without the lower metric a dead Wi-Fi would keep winning on metric 600 against the modem's 1100. When either is healthy for two rounds, cellular is closed again, put back to exactly what it was.
- **`cell-first`** is the one mode that demotes Ethernet and Wi-Fi (`never-default` at runtime; their connected subnet routes stay, so the local network still works), so cellular is the single, deterministic owner. It is for the emergency case: the LAN firewall is down, cellular is up, and a lab host must still be reachable. Order: open cellular, confirm its default route is in `ip route show default` and that the modem still has link, and only then demote Ethernet and Wi-Fi, one by one, reading the route table and the modem again before each one. If cellular's default disappears or the modem loses its link half way, everything is put back (Ethernet and Wi-Fi first, then cellular) and the run fails. It ends after `--for` (`30m`, `2h`, `1d`, up to `30d`; `0` means never; default `2h`), and when it ends (`auto`, expiry, the modem lost) the way back is the same make-before-break the other way: Ethernet and Wi-Fi first, confirmed, and only then cellular closes. It refuses to start without a connected modem.
- A link is healthy when a ping bound to its interface answers one of two public targets (2 s timeout each). A link that holds only an IPv6 default route is probed with IPv6 targets (`QUECTEL_UPLINK_TARGETS6`), one that holds only IPv4 with IPv4 targets, a dual-stack one with both (any answer counts). Two failures in a row take an up link down, two successes bring a down one back; this counts rounds, so no clock is involved. All probes run in parallel under one 12 s deadline, and one that hangs gets TERM, then KILL.
- With Ethernet and Wi-Fi both healthy, the VPN client may bind to either of them. It will not bind to cellular, because cellular holds no default route. That is the thing to check live.
- Interface names come from NetworkManager device types (`ethernet`, `wifi`, `gsm`), never hard-coded, and every name is checked against a plain-name pattern before it reaches a command. NetworkManager is always read with `LC_ALL=C` and `--escape no`.

### Never without a default route, and what happens on bad input

- Cellular is opened before anything else moves, and confirmed in the route table. Cellular is closed only when another managed link holds a default route.
- Bad input, a missing tool, an `nmcli` or `ip` error, an unreadable route table, a malformed state file or an out-of-range setting makes `run` change nothing, log why and exit non-zero. A link-history file or a ledger that is not exactly what this tool writes is "unknown": the run does not guess, it does nothing. The mode file must be exactly one line with consistent fields (an end time and a duration go together, or neither is set); anything else is malformed and the run does nothing until `uplink auto` rewrites it. State files are written to a temp file that is never a symlink and then renamed.
- Default routes on interfaces the manager does not manage (a full-tunnel VPN, a bridge) are left alone.
- No history for a link (first run, or after a logout): a link that holds a default route counts as up, and a modem counts as up, so a first run in `auto` never demotes anything (it does not touch Ethernet or Wi-Fi at all). The exception: if the ledger says cellular is open, Ethernet and Wi-Fi start as down and have to prove themselves twice before cellular closes.

### The ledger: every change is recorded first

Before the manager changes a device at runtime (open cellular, demote Ethernet or Wi-Fi), it writes the device, its profile's UUID and the previous `never-default` and route-metric values to `~/.local/state/quectel-usbnet/ledger` (`$XDG_STATE_HOME` if set), then makes the change. Restoring puts exactly those values back, not an assumed policy. The ledger survives a logout, a crash and a kill.

- **Self-heal.** Every `uplink run` and `uplink auto` reads the ledger first. Anything it lists that the current mode does not need is put back: after a kill, a logout, an expired `cell-first`, a lost modem. Ethernet and Wi-Fi go back before cellular closes.
- **Only proof drops a line.** A ledger line is dropped when NetworkManager was read successfully and the device is not in its device list, has no active profile, or has a different profile UUID: it re-activated (a reconnect, a reboot, a resume) and NetworkManager already reset the runtime change. If any of those reads fails or prints something unexpected, nothing is dropped and nothing is reported as restored: the line stays, the restore exits non-zero, and a later restore or run tries again.
- **Stopping.** The install writes a small service that runs `uplink restore` whenever the timer stops (stop, disable, logout, shutdown). `uplink restore` can also be run by hand. It restores Ethernet and Wi-Fi first and closes cellular last, and it will not close cellular if nothing else holds a default route (it says so, exits non-zero, and keeps the line).

### What `nmcli device modify` does

`man nmcli` (read on this machine, nmcli 1.52): `device modify` "modif[ies] the settings currently active on the device... temporary changes ... not preserved in the connection profile", with the caveat that "some properties can't be changed on an already connected device". `device reapply` is described as updating the device "with changes to the currently active connection made since it was last applied", so it is for profile edits. The manager therefore calls `device modify` and no separate `reapply`. Whether NetworkManager really applies `never-default` and the route metric to a connected device at once, on both families, is documented but not something the tests can prove (they use a fake `nmcli`), so it is an owner acceptance check below. To drop every runtime change at once by hand, `nmcli device reapply <device>` applies the profile again.

### Install (user level, nothing runs until you run it)

```
quectel-usbnet uplink install
```

prints a block of steps for you to read and run. It checks everything that can refuse first (the units, the copy and the state directories are yours, real directories or plain files, no foreign or symlinked file in the way) and only then changes anything, in this order: set `ipv4.never-default yes` and `ipv6.never-default yes` on every `gsm` profile (all or none: the list and the previous values are read first, and if one profile fails the ones already changed are put back and nothing is installed) (found from NetworkManager by type, since the profile name differs per machine; stored in the profile, the one change that outlives the manager), copy the script to `~/.local/libexec/quectel-usbnet-uplink`, write the `systemd --user` units (the 15 s timer, the service it runs, the restore-on-stop service), and run one evaluation. The units carry absolute paths for `nmcli`, `ip`, `ping`, `flock` and `timeout`, resolved when you ran `install`, and a fixed `PATH=/usr/sbin:/usr/bin`. It refuses to overwrite a file it did not write.

The mode (`auto` or `cell-first`, with its end time) is kept in `$XDG_RUNTIME_DIR/quectel-usbnet/`, so a reboot or logout always goes back to `auto`.

### Uninstall

`quectel-usbnet uplink uninstall` prints steps that stop the timer, run `uplink restore` (printing what it restored), and only if that finished remove the units, the copy and the state (only files carrying this tool's marker, exact names). If the restore did not finish, nothing is removed. The cellular profile stays closed on purpose.

### Clocks

Nothing that counts uses the wall clock. Link health counts rounds. `cell-first` records both clocks: it ends when the wall clock reaches the end time, when the wall clock is behind the time the request was made (it jumped backward, so the end time means nothing), or when the monotonic clock (`/proc/uptime`) says the duration has passed. `--for 0` has no expiry and so no clock check.

### `status --json`

```
{"mode":"auto|cell-first","owner":"ethernet|wifi|cell|none",
 "links":{"ethernet":{"state":"up|down|absent","healthy":true},"wifi":{...},"cell":{...}},
 "until":"<iso or null>","since":"<iso>"}
```

`owner` is whoever carries traffic right now: the managed link whose default route has the lowest metric (IPv4 first, IPv6 if there is no IPv4 default). `state` is NetworkManager's: `up` is connected, `down` is a device that exists but is not connected, `absent` is no such device. `healthy` is the last measured result (a modem that is closed is not measured and reads healthy while connected). `since` is when the mode was set. It reads and prints, exit 0; if it cannot read NetworkManager, the routes or the state files, it prints nothing on stdout and exits 1.

### If the manager stops or is killed

- **Stopped cleanly** (timer stopped, logout, shutdown, uninstall): the restore service runs `uplink restore`. Nothing is left changed.
- **Killed, crashed, power cut:** the profile is still closed. Cellular may be left open (after a failover) or Ethernet and Wi-Fi demoted (after `cell-first`) until the next `uplink run` or `uplink auto`, which heals from the ledger, or until the device reconnects or the machine reboots (NetworkManager re-applies the profile).
- **Exact recovery commands**, in this order:

```
quectel-usbnet uplink restore          # from the ledger; prints what it restored
quectel-usbnet uplink auto             # and back to the normal order
nmcli device reapply <each device>     # without the manager: applies the profile again
nmcli connection up <each profile>     # the heavier version, reconnects
```

### What this does not defend against

A shell script cannot defend against a hostile process running as the same user. That process could write the mode, link history or ledger files, replace the lock, or run `nmcli` itself. The state directories being mode 0700, owned by you, not symlinks, and the lock file being opened without following a symlink, is the whole boundary. It keeps other users out and keeps accidents contained; it is not tamper resistance, and no part of this should be read as such.

### The modem guard it replaces

An earlier approach (#22) put an nftables guard on the modem interface. It kept the modem up and rejected its traffic, but the VPN client stayed bound to the modem and its tunnel died. It is superseded and not part of this script. If you installed it from that branch, `quectel-usbnet guard-uninstall` prints the steps that remove it.

### Settings

All are environment variables with safe defaults, checked at start (a bad value changes nothing): `QUECTEL_UPLINK_TARGETS` (`"1.1.1.1 9.9.9.9"`), `QUECTEL_UPLINK_TARGETS6` (`"2606:4700:4700::1111 2620:fe::fe"`), `QUECTEL_UPLINK_FAILS` (2), `QUECTEL_UPLINK_OKS` (2), `QUECTEL_UPLINK_PING_TIMEOUT` (2 s), `QUECTEL_UPLINK_DEADLINE` (12 s), `QUECTEL_UPLINK_MAX_DEVICES` (4 per link type), `QUECTEL_UPLINK_CELL_METRIC` (50, must be below Ethernet's 100). The units set only the tool paths.

### What I have and have not run

The decision logic, the flapping hysteresis, the cell-first order and its aborts, the expiry on both clocks, the ledger (including a kill, a re-activated device and a malformed file), the malformed-input and tool-failure paths, the order of the `nmcli` calls, the state-directory and lock refusals, and the printed install and uninstall steps (run for real against a temp HOME and a fake `systemctl`) are tested against fake `nmcli`, `ip` and `ping` (`tests/uplink.sh`), with a fake route table that the fake `nmcli` changes, so "never no default route" and "the old routes are intact after a failure" are checked, not assumed. The read-only commands (`status`, `run --dry-run`, the profile and link reads) were run against a real NetworkManager. What the suite cannot show, and the live checks are for:

- `nmcli device modify` really changing `never-default` and the route metric of a connected device, both families, at once, without dropping the connection.
- Modem counters flat with Ethernet or Wi-Fi up, and the VPN client bound to Wi-Fi (or Ethernet), never to cellular.
- Wi-Fi radio off leads to cellular within about 45 s and the VPN re-binds; Wi-Fi back closes cellular again; Ethernet and Wi-Fi are never changed in all of that (`nmcli device modify` is only ever called on the modem).
- `cell-first`, then `auto`, then `cell-first` and stop the timer: everything ends up as it was; lab hosts and DNS reachable at every step.
- The restore-on-stop service on a real `systemctl --user stop`, and at logout.

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
