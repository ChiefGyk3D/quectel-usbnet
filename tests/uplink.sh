#!/usr/bin/env bash
# Tests for `quectel-usbnet uplink` (#25). Sourced by tests/run.sh, which supplies
# $TOOL, $HERE, $tmp and the ok/fail/expect_* helpers. Nothing here touches the
# machine: nmcli, ip and ping are fakes over a small "world" of files, and the
# systemd and nmcli steps the install prints are run against a temp HOME with a
# fake systemctl. No real nmcli modify, ip route change, nft, sudo or systemctl.

# Supplied by tests/run.sh; this fails loudly if the file is run on its own.
TOOL=${TOOL:?run tests/run.sh}
HERE=${HERE:?run tests/run.sh}
tmp=${tmp:?run tests/run.sh}

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=quectel-usbnet
source "$TOOL"

UW="$tmp/uw"
UST="$tmp/ustate"
ubin="$tmp/ubin"
mkdir -p "$ubin"

# --- the fakes -------------------------------------------------------------------
# The world is the directory $UW:
#   devices            what `nmcli -t -f DEVICE,TYPE,STATE device` prints
#   ipif_DEV           the IP interface of a device (modem: wwan0)
#   dhcp_DEV           what `nmcli -t -f DHCP4.OPTION device show DEV` prints
#   rt4_IF rt6_IF      the default routes the interface holds right now
#   tpl4_IF tpl6_IF    the routes NetworkManager installs when defaults are allowed
#   ping_IF=ok         the internet answers through IF (and only if IF holds a route)
#   gwaddr_IF, gwok_IF the gateway address, and whether it answers
#   calls              every call, in order
cat >"$ubin/nmcli" <<'FAKE'
#!/usr/bin/env bash
echo "nmcli LC_ALL=${LC_ALL:-unset} $*" >>"$UW/calls"
while [ "${1:-}" = --escape ] || [ "${1:-}" = --wait ]; do shift 2; done
[ ! -f "$UW/fail_nmcli" ] || { echo "Error: boom" >&2; exit 1; }
nroutes() { cat "$UW"/rt4_* "$UW"/rt6_* 2>/dev/null | grep -c . || true; }
case "$1 $2 $3 $4" in
  "-t -f DEVICE,TYPE,STATE device")
    [ ! -f "$UW/fail_list" ] || { echo "Error: boom" >&2; exit 1; }
    if [ -f "$UW/garbage_list" ]; then echo "this is not a device list"; exit 0; fi
    cat "$UW/devices"
    ;;
  "-t -f UUID,TYPE connection") cat "$UW/connections" ;;
  "-g GENERAL.IP-IFACE device show") cat "$UW/ipif_$5" 2>/dev/null || true ;;
  "-t -f DHCP4.OPTION device") cat "$UW/dhcp_$6" 2>/dev/null || true ;;
  "-g IP4.GATEWAY device show") cat "$UW/gw_$5" 2>/dev/null || true ;;
  "connection modify uuid "*) ;;
  "device modify "*)
    dev=$3
    val=$5
    if [ -f "$UW/fail_modify" ] || [ -f "$UW/fail_modify_$dev" ]; then
      echo "Error: modify failed" >&2
      exit 1
    fi
    if [ "$4" != ipv4.never-default ] || [ "$6" != ipv6.never-default ] || [ "$7" != "$val" ]; then
      echo "Error: unexpected arguments" >&2
      exit 1
    fi
    if [ -f "$UW/noop_modify" ]; then exit 0; fi
    if [ -f "$UW/noop_modify_once" ]; then
      rm -f "$UW/noop_modify_once"
      exit 0
    fi
    iface=$dev
    [ ! -f "$UW/ipif_$dev" ] || iface=$(cat "$UW/ipif_$dev")
    if [ "$val" = yes ]; then
      rm -f "$UW/rt4_$iface" "$UW/rt6_$iface"
    else
      [ ! -f "$UW/tpl4_$iface" ] || cp "$UW/tpl4_$iface" "$UW/rt4_$iface"
      [ ! -f "$UW/tpl6_$iface" ] || cp "$UW/tpl6_$iface" "$UW/rt6_$iface"
    fi
    echo "routes=$(nroutes) after modify $dev $val" >>"$UW/calls"
    ;;
  *) exit 9 ;;
esac
FAKE
cat >"$ubin/ip" <<'FAKE'
#!/usr/bin/env bash
# ip -o -4|-6 route show default
echo "ip $*" >>"$UW/calls"
case "$2" in
  -4)
    [ ! -f "$UW/fail_ip4" ] || exit 1
    cat "$UW"/rt4_* 2>/dev/null || true
    ;;
  -6)
    [ ! -f "$UW/fail_ip6" ] || exit 1
    cat "$UW"/rt6_* 2>/dev/null || true
    ;;
esac
exit 0
FAKE
cat >"$ubin/ping" <<'FAKE'
#!/usr/bin/env bash
# ping -n -q -c 1 -W T -w T -I IFACE TARGET
iface=""
target=""
while [ $# -gt 0 ]; do
  [ "$1" = -I ] && iface=$2
  target=$1
  shift
done
echo "ping $iface $target" >>"$UW/calls"
if [ -f "$UW/ping_deaf" ]; then
  trap '' TERM
  while :; do sleep 1; done
fi
if [ -f "$UW/ping_sleep" ]; then sleep "$(cat "$UW/ping_sleep")"; fi
if [ "$target" = "$(cat "$UW/gwaddr_$iface" 2>/dev/null)" ]; then
  [ "$(cat "$UW/gwok_$iface" 2>/dev/null)" = ok ]
else
  # the internet is only reachable through an interface that holds a route
  [ -s "$UW/rt4_$iface" ] || [ -s "$UW/rt6_$iface" ] || exit 1
  [ "$(cat "$UW/ping_$iface" 2>/dev/null)" = ok ]
fi
FAKE
chmod +x "$ubin"/*

# The seams the unit would set, and the clock.
export UW
UBIN="$ubin"
export UBIN
export QUECTEL_UPLINK_NMCLI="$ubin/nmcli"
export QUECTEL_UPLINK_IP="$ubin/ip"
export QUECTEL_UPLINK_PING="$ubin/ping"
export QUECTEL_UPLINK_STATE_DIR="$UST"
export QUECTEL_UPLINK_TARGETS="192.0.2.1 198.51.100.1"
export QUECTEL_UPLINK_VERIFY_WAIT=0
export QUECTEL_UPLINK_VERIFY_TRIES=2
export QUECTEL_UPLINK_NOW=1700000000
T0=1700000000

# uscene ETH WIFI CELL: each ok | dead | gone (listed, but unavailable) | none (no
# device at all). dead = the device is connected and holds its routes, but the
# internet does not answer and neither does its gateway.
uscene() {
  rm -rf "$UW" "$UST"
  mkdir -p "$UW"
  printf 'lo:loopback:connected (externally)\nvpn0:tun:connected\n' >"$UW/devices"
  uadd eth0 ethernet "$1" 100 192.0.2.254
  uadd wlan0 wifi "$2" 600 192.0.2.253
  if [ "$3" != none ]; then
    echo "cdc-wdm0:gsm:$([ "$3" = gone ] && echo unavailable || echo connected)" >>"$UW/devices"
    echo wwan0 >"$UW/ipif_cdc-wdm0"
    echo "default dev wwan0 proto static metric 1100" >"$UW/tpl4_wwan0"
    echo "default dev wwan0 proto static metric 1100 pref medium" >"$UW/tpl6_wwan0"
    [ "$3" != ok ] || echo ok >"$UW/ping_wwan0"
  fi
  export QUECTEL_UPLINK_NOW=$T0
  return 0
}
# uadd DEV TYPE STATE METRIC GATEWAY
uadd() {
  local dev=$1 type=$2 state=$3 metric=$4 gw=$5
  [ "$state" != none ] || return 0
  if [ "$state" = gone ]; then
    echo "$dev:$type:unavailable" >>"$UW/devices"
    return 0
  fi
  echo "$dev:$type:connected" >>"$UW/devices"
  echo "default via $gw dev $dev proto dhcp metric $metric" >"$UW/tpl4_$dev"
  cp "$UW/tpl4_$dev" "$UW/rt4_$dev"
  printf 'DHCP4.OPTION[21]:requested_routers = 1\nDHCP4.OPTION[26]:routers = %s\n' "$gw" >"$UW/dhcp_$dev"
  echo "$gw" >"$UW/gwaddr_$dev"
  if [ "$state" = ok ]; then
    echo ok >"$UW/ping_$dev"
    echo ok >"$UW/gwok_$dev"
  fi
  return 0
}
# uopen: the modem profile is not closed yet, so cellular holds default routes
uopen() {
  cp "$UW/tpl4_wwan0" "$UW/rt4_wwan0"
  cp "$UW/tpl6_wwan0" "$UW/rt6_wwan0"
}
# uholders: the interfaces that hold a default route in the world, sorted
uholders() {
  local f out=""
  for f in "$UW"/rt4_* "$UW"/rt6_*; do
    [ -s "$f" ] || continue
    f=${f##*/rt?_}
    case " $out " in *" $f "*) ;; *) out="$out $f" ;; esac
  done
  echo "$out" | tr ' ' '\n' | grep . | sort | tr '\n' ' ' | sed 's/ $//' || true
}
ucalls() { cat "$UW/calls" 2>/dev/null || true; }
# umods: the device modify calls, in order, compact
umods() { ucalls | grep 'device modify' | sed 's/^nmcli LC_ALL=C --escape no --wait [0-9]* device modify //; s/ ipv6.never-default.*//; s/ipv4.never-default //' | tr '\n' ';' || true; }
# ucli ARGS: run the real command line; sets ucli_out (stdout and stderr) and ucli_rc
ucli() {
  ucli_rc=0
  ucli_out=$("$TOOL" uplink "$@" 2>&1) || ucli_rc=$?
}
# unow SECONDS-SINCE-T0
unow() { export QUECTEL_UPLINK_NOW=$((T0 + $1)); }

# --- pure: link health with hysteresis ----------------------------------------------
UP_FAILS=2
UP_OKS=2
UP_HOLD=120
expect_eq "step: one failed probe keeps an up link up" "$(uplink_link_step up 0 0 0 fail 1000)" "up 1 0 0"
expect_eq "step: two failed probes take it down and start the hold-down" "$(uplink_link_step up 1 0 0 fail 1000)" "down 2 0 1000"
expect_eq "step: a good probe resets the failures" "$(uplink_link_step up 1 0 0 ok 1000)" "up 0 1 0"
expect_eq "step: one good probe does not bring a down link up" "$(uplink_link_step down 0 0 0 ok 1000)" "down 0 1 0"
expect_eq "step: two good probes bring a down link up (no hold-down)" "$(uplink_link_step down 0 1 0 ok 1000)" "up 0 2 0"
expect_eq "step: a failure resets the good probes" "$(uplink_link_step down 0 1 0 fail 1000)" "down 1 0 0"
expect_eq "step: a failure while down keeps the hold-down start" "$(uplink_link_step down 0 1 900 fail 1000)" "down 1 0 900"
expect_eq "step: hold-down blocks the way back" "$(uplink_link_step down 0 1 1000 ok 1050)" "down 0 2 1000"
expect_eq "step: hold-down ends after UP_HOLD seconds" "$(uplink_link_step down 0 2 1000 ok 1120)" "up 0 3 0"
expect_eq "step: hold-down is exactly UP_HOLD, not one less" "$(uplink_link_step down 0 2 1000 ok 1119)" "down 0 3 1000"
expect_eq "step: absent goes down at once and clears the hold-down" "$(uplink_link_step up 0 5 777 absent 1000)" "down 2 0 0"
expect_eq "step: skip changes nothing" "$(uplink_link_step up 1 3 0 skip 1000)" "up 1 3 0"
expect_eq "step: skip does not revive a down link" "$(uplink_link_step down 0 1 50 skip 1000)" "down 0 1 50"
expect_eq "step: bad history reads as down with none" "$(uplink_link_step bogus x y z ok 1000)" "down 0 1 0"
expect_eq "step: an unknown probe never counts as healthy" "$(uplink_link_step down 0 1 0 weird 1000)" "down 0 0 0"
expect_eq "step: a counter cannot grow without bound" "$(uplink_link_step up 0 99 0 ok 1000 | cut -d' ' -f3)" 99
UP_FAILS=3
expect_eq "step: UP_FAILS is honored" "$(uplink_link_step up 1 0 0 fail 1000)" "up 2 0 0"
UP_FAILS=2

# --- pure: the decision -----------------------------------------------------------------
# uplink_decide MODE ES EH WS WH CS CH
d() { uplink_decide "$@" | cut -d' ' -f1; }
expect_eq "decide: ethernet first when healthy" "$(d auto up up up up up up)" ethernet
expect_eq "decide: wifi when ethernet is unhealthy" "$(d auto up down up up up up)" wifi
expect_eq "decide: wifi when ethernet is absent" "$(d auto absent down up up up up)" wifi
expect_eq "decide: wifi when ethernet is unplugged but its status is stale-up" "$(d auto down up up up up up)" wifi
expect_eq "decide: cell when both are unhealthy" "$(d auto up down up down up up)" cell
expect_eq "decide: cell when wifi is down and ethernet absent" "$(d auto absent down down down up up)" cell
expect_eq "decide: cell is the last resort even if its health is down" "$(d auto absent down down down up down)" cell
expect_eq "decide: none when nothing is usable" "$(d auto absent down down down down down)" none
expect_eq "decide: none when cell is down and wifi is unhealthy" "$(d auto absent down up down down down)" none
expect_eq "decide: cell-first picks cell over a healthy ethernet" "$(d cell-first up up up up up up)" cell
expect_eq "decide: cell-first without a cell link falls back to the auto order" "$(d cell-first up up up up absent down)" ethernet
expect_eq "decide: cell-first with cell down falls back to wifi" "$(d cell-first absent down up up down down)" wifi
expect_eq "decide: an unknown mode is none" "$(d sideways up up up up up up)" none
expect_eq "decide: a malformed state is none" "$(d auto up up bogus up up up)" none
expect_eq "decide: a malformed health is none" "$(d auto up maybe up up up up)" none
expect_eq "decide: empty arguments are none" "$(d)" none
expect_eq "decide: ethernet outranks wifi when both are healthy" "$(d auto up up up up absent down)" ethernet

# --- pure: parsers -------------------------------------------------------------------------
nm_out=$'eth0:ethernet:connected\nwlan0:wifi:connected\ncdc-wdm0:gsm:connected\nvpn0:tun:connected\nlo:loopback:connected (externally)\np2p-dev-wlan0:wifi-p2p:disconnected\nenp3:ethernet:unavailable'
expect_eq "devices: ethernet, wifi and gsm are found, with their state" \
  "$(printf '%s\n' "$nm_out" | uplink_parse_devices | tr '\n' ';')" "ethernet eth0 up;wifi wlan0 up;gsm cdc-wdm0 up;ethernet enp3 down;"
expect_eq "devices: wifi-p2p is not wifi, a tun is nothing" \
  "$(printf '%s\n' "$nm_out" | uplink_parse_devices | grep -c -e p2p -e tun || true)" 0
expect_eq "devices: a name with a colon is refused (split from the right)" \
  "$(printf 'we:ird0:ethernet:connected\neth0:ethernet:connected\n' | uplink_parse_devices | tr '\n' ';')" "ethernet eth0 up;"
expect_eq "devices: a name with shell characters is refused" \
  "$(printf "eth0;reboot:ethernet:connected\n\$(id):wifi:connected\nwlan0:wifi:connected\n" | uplink_parse_devices | tr '\n' ';')" "wifi wlan0 up;"
expect_eq "devices: garbage gives nothing" "$(printf 'garbage\n::\n' | uplink_parse_devices | tr '\n' ';')" ""
expect_eq "routes: devices of default routes, both families" \
  "$(printf 'default via 192.0.2.1 dev eth0 proto dhcp metric 100\ndefault via fe80::1 dev wlan0 proto ra metric 1024 pref medium\n' | uplink_route_devs | tr '\n' ' ')" "eth0 wlan0 "
expect_eq "routes: a multipath default names every device" \
  "$(printf 'default nexthop via 192.0.2.1 dev eth0 weight 1 nexthop via 192.0.2.2 dev wlan0 weight 1\n' | uplink_route_devs | tr '\n' ' ')" "eth0 wlan0 "
expect_eq "routes: only plain default routes count" \
  "$(printf 'unreachable default dev lo metric 4278198272\n10.0.0.0/24 dev eth0 proto kernel\nblackhole default\n' | uplink_route_devs | tr '\n' ' ')" ""
expect_eq "routes: a hostile device name is dropped" \
  "$(printf 'default dev eth0;reboot proto static\n' | uplink_route_devs | tr '\n' ' ')" ""
expect_eq "duration: 30m" "$(uplink_parse_duration 30m)" 1800
expect_eq "duration: 2h" "$(uplink_parse_duration 2h)" 7200
expect_eq "duration: 1d" "$(uplink_parse_duration 1d)" 86400
expect_eq "duration: 90s" "$(uplink_parse_duration 90s)" 90
expect_eq "duration: 0 means no expiry" "$(uplink_parse_duration 0)" 0
dur_bad=""
for s in "" 5 -1 0h 0m 2x 2hh h 31d 999999d 1.5h "2 h" 2h\;id; do
  if uplink_parse_duration "$s" >/dev/null 2>&1; then dur_bad="$dur_bad [$s]"; fi
done
expect_eq "duration: everything else is refused" "$dur_bad" ""
expect_eq "duration: 30d is the limit" "$(uplink_parse_duration 30d)" 2592000

# --- the runner, against the fake world, through the real command line --------------------------
# Steady state: Wi-Fi owns the defaults, the modem profile is closed. Nothing to change.
uscene gone ok ok
ucli run
expect_eq "run: a steady state exits 0" "$ucli_rc" 0
expect_contains "run: names the owner and the reason" "$ucli_out" "owner=wifi (wifi-healthy)"
expect_eq "run: a steady state changes nothing" "$(umods)" ""
expect_eq "run: wifi still owns" "$(uholders)" "wlan0"
expect_contains "run: nmcli is read in the C locale, unescaped" "$(ucalls)" "nmcli LC_ALL=C --escape no -t -f DEVICE,TYPE,STATE device"
expect_contains "run: the modem interface is read in the C locale, unescaped" "$(ucalls)" "nmcli LC_ALL=C --escape no -g GENERAL.IP-IFACE device show cdc-wdm0"
: >"$UW/calls"
ucli run
expect_eq "run: a second steady pass still changes nothing" "$(umods)" ""
expect_eq "run: the probes are bound to the owner's interface" "$(ucalls | grep -c '^ping wlan0 ')" 1
expect_eq "run: the modem is not pinged while it holds no route" "$(ucalls | grep -c '^ping wwan0 ' || true)" 0
expect_eq "run: the state directory is private" "$(stat -c %a "$UST")" 700
: >"$UW/calls"
out=$(LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 "$TOOL" uplink run 2>&1)
expect_contains "run: a non-C locale still reads nmcli in C" "$(ucalls | head -n 1)" "LC_ALL=C"

# The modem profile is not closed yet: the first run closes it at runtime, Wi-Fi keeps the defaults.
uscene gone ok ok
uopen
ucli run
expect_eq "first run: cellular is demoted" "$(umods)" "cdc-wdm0 yes;"
expect_eq "first run: only Wi-Fi holds defaults afterwards" "$(uholders)" "wlan0"
expect_eq "first run: exits 0" "$ucli_rc" 0
expect_eq "first run: Wi-Fi was never demoted or re-allowed" "$(ucalls | grep -c 'modify wlan0' || true)" 0

# Ethernet outranks Wi-Fi: Wi-Fi is demoted, make-before-break is not needed (ethernet already holds).
uscene ok ok ok
ucli run
expect_contains "ethernet first: owner is ethernet" "$ucli_out" "owner=ethernet"
expect_eq "ethernet first: Wi-Fi is demoted" "$(umods)" "wlan0 yes;"
expect_eq "ethernet first: only ethernet holds defaults" "$(uholders)" "eth0"

# Failover and recovery, one pass each. Wi-Fi's internet dies; its gateway still answers.
uscene gone ok ok
ucli run # T0: wifi ok
rm -f "$UW/ping_wlan0"
unow 15
ucli run
expect_eq "failover: one failed probe is tolerated (flapping)" "$(umods)" ""
expect_contains "failover: still wifi after one failure" "$ucli_out" "owner=wifi"
echo ok >"$UW/ping_wlan0"
unow 30
ucli run
expect_eq "failover: a success resets the count, still no change" "$(umods)" ""
rm -f "$UW/ping_wlan0"
unow 45
ucli run
unow 60
ucli run
expect_contains "failover: the second failure in a row fails over to cell" "$ucli_out" "owner=cell (failover)"
expect_eq "failover: only the modem holds defaults" "$(uholders)" "wwan0"
expect_eq "failover: cell is promoted before Wi-Fi is demoted" "$(umods)" "cdc-wdm0 no;wlan0 yes;"
expect_eq "failover: the machine never had no default route" "$(ucalls | grep -c 'routes=0 ' || true)" 0
expect_eq "failover: exit 0" "$ucli_rc" 0
fo_calls=$(ucalls | grep -c 'device modify' || true)
unow 75
: >"$UW/calls"
ucli run
expect_eq "failover: a steady cell owner changes nothing" "$(umods)" ""
expect_eq "failover: the modem is probed once it holds the defaults" "$(ucalls | grep -c '^ping wwan0 ')" 1
expect_eq "failover: the demoted Wi-Fi is probed through its gateway only" "$(ucalls | grep '^ping wlan0 ' | sort -u | tr '\n' ';')" "ping wlan0 192.0.2.253;"
expect_eq "failover: two device changes were made, no more" "$fo_calls" 2
# Wi-Fi's internet comes back. Its gateway answers all along.
echo ok >"$UW/ping_wlan0"
unow 90
ucli run
unow 105
ucli run
expect_eq "recovery: held down, Wi-Fi does not return in under UP_HOLD seconds" "$(uholders)" "wwan0"
unow 179
ucli run
expect_eq "recovery: one second short of the hold-down is still cell" "$(uholders)" "wwan0"
unow 180
: >"$UW/calls"
ucli run
expect_contains "recovery: after the hold-down Wi-Fi owns again" "$ucli_out" "owner=wifi"
expect_eq "recovery: Wi-Fi is promoted before the modem is demoted" "$(umods)" "wlan0 no;cdc-wdm0 yes;"
expect_eq "recovery: only Wi-Fi holds defaults" "$(uholders)" "wlan0"
expect_eq "recovery: never without a default route" "$(ucalls | grep -c 'routes=0 ' || true)" 0

# The Wi-Fi radio goes off: the device becomes unavailable at once, no hold-down on the way back.
uscene gone ok ok
ucli run
sed -i 's/^wlan0:wifi:connected/wlan0:wifi:unavailable/' "$UW/devices"
rm -f "$UW/rt4_wlan0"
unow 15
ucli run
expect_contains "radio off: fails over to cell at the next pass" "$ucli_out" "owner=cell"
expect_eq "radio off: the modem holds the defaults" "$(uholders)" "wwan0"
expect_eq "radio off: the unavailable device is not touched" "$(umods)" "cdc-wdm0 no;"
sed -i 's/^wlan0:wifi:unavailable/wlan0:wifi:connected/' "$UW/devices"
cp "$UW/tpl4_wlan0" "$UW/rt4_wlan0" # NetworkManager reconnects it with its own, open, profile
unow 30
ucli run
expect_contains "radio on: one good pass is not enough" "$ucli_out" "owner=cell"
unow 45
ucli run
expect_contains "radio on: two good passes and Wi-Fi owns again (no hold-down after a plain unplug)" "$ucli_out" "owner=wifi"
expect_eq "radio on: only Wi-Fi holds the defaults" "$(uholders)" "wlan0"

# Both die: ethernet and Wi-Fi unhealthy, cell takes over. Then everything returns.
uscene ok ok ok
ucli run
rm -f "$UW/ping_eth0" "$UW/ping_wlan0" "$UW/gwok_wlan0"
unow 15
ucli run
unow 30
ucli run
expect_contains "both dead: cell owns" "$ucli_out" "owner=cell"
expect_eq "both dead: the modem is alone" "$(uholders)" "wwan0"

# A hung probe is bounded, and so are the ones that ignore TERM.
uscene gone ok ok
: >"$UW/ping_deaf"
SECONDS=0
ucli_t=$(QUECTEL_UPLINK_DEADLINE=2 timeout 30 "$TOOL" uplink run 2>&1 && echo ended || echo "rc=$?")
deaf_elapsed=$SECONDS
expect_eq "deaf probe: the run ends" "${ucli_t##*$'\n'}" ended
expect_eq "deaf probe: within deadline plus the 1 s grace plus slack" "$((deaf_elapsed <= 8 ? 1 : 0))" 1
deaf_left=0
for f in /proc/[0-9]*/cmdline; do
  case "$(tr '\0' ' ' <"$f" 2>/dev/null)" in
    *"$ubin/ping "*)
      deaf_left=$((deaf_left + 1))
      pid=${f#/proc/}
      kill -9 "${pid%/cmdline}" 2>/dev/null || true
      ;;
  esac
done
expect_eq "deaf probe: KILL leaves no probe behind" "$deaf_left" 0
rm -f "$UW/ping_deaf"

# Many devices: only the first UP_MAX_DEVICES of a type are used.
uscene none ok ok
for n in 1 2 3 4 5 6 7 8 9; do
  echo "enx$n:ethernet:connected" >>"$UW/devices"
  echo "default via 192.0.2.254 dev enx$n metric 100" >"$UW/rt4_enx$n"
  echo ok >"$UW/ping_enx$n"
done
ucli run
expect_eq "limits: nine ethernet devices, at most four are probed" "$(ucalls | grep -c '^ping enx' || true)" 4

# A hostile device name never reaches a command.
uscene gone ok ok
echo 'wlan1;reboot:wifi:connected' >>"$UW/devices"
echo 'we:ird0:ethernet:connected' >>"$UW/devices"
ucli run
expect_eq "hostile names: never probed" "$(ucalls | grep -c -e 'reboot' -e 'we:ird' || true)" 0
expect_eq "hostile names: the run is unaffected" "$ucli_rc" 0

# An unmanaged default route (a full-tunnel VPN) is left alone and does not stop a failover.
uscene gone ok ok
echo "default dev tun0 scope link metric 50" >"$UW/rt4_tun0"
ucli run
rm -f "$UW/ping_wlan0"
unow 15
ucli run
unow 30
ucli run
expect_eq "unmanaged: failover still completes with a VPN default present" "$(uholders)" "tun0 wwan0"
expect_eq "unmanaged: the VPN is never touched" "$(ucalls | grep -c 'tun0' || true)" 0

# A modem that is connected but has no IP interface yet is not usable.
uscene gone ok ok
: >"$UW/ipif_cdc-wdm0"
rm -f "$UW/ping_wlan0" "$UW/gwok_wlan0"
ucli run
unow 15
ucli run
unow 30
ucli run
expect_contains "modem without an interface: cell is not chosen" "$ucli_out" "owner=none"
expect_eq "modem without an interface: Wi-Fi keeps its routes" "$(uholders)" "wlan0"
expect_eq "modem without an interface: nothing changed" "$(umods)" ""
expect_eq "modem without an interface: the run still exits 0 (nothing to do)" "$ucli_rc" 0

# --- fail safe ----------------------------------------------------------------------------------
# Every failure below must leave the routes exactly as they were and exit non-zero.
# fail_start: Wi-Fi has failed once; the next run is the second failure, so the
# next run wants to fail over to cell
fail_start() {
  uscene gone ok ok
  ucli run >/dev/null
  rm -f "$UW/ping_wlan0"
  unow 15
  ucli run >/dev/null
  unow 30
  : >"$UW/calls"
}

# nmcli cannot be read
fail_start
touch "$UW/fail_list"
ucli run
expect_eq "nmcli list fails: exit 1" "$ucli_rc" 1
expect_eq "nmcli list fails: nothing modified" "$(umods)" ""
expect_eq "nmcli list fails: routes unchanged" "$(uholders)" "wlan0"
rm -f "$UW/fail_list"
touch "$UW/garbage_list"
ucli run
expect_eq "garbage device list: exit 1" "$ucli_rc" 1
expect_eq "garbage device list: nothing modified" "$(umods)" ""
rm -f "$UW/garbage_list"

# ip cannot be read
touch "$UW/fail_ip4"
ucli run
expect_eq "ip v4 fails: exit 1" "$ucli_rc" 1
expect_eq "ip v4 fails: nothing modified" "$(umods)" ""
rm -f "$UW/fail_ip4"
touch "$UW/fail_ip6"
inet6_file="$tmp/if_inet6"
: >"$inet6_file"
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_IF_INET6=$inet6_file "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "ip v6 fails on a machine with IPv6: exit 1" "$ucli_rc" 1
expect_eq "ip v6 fails on a machine with IPv6: nothing modified" "$(umods)" ""
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_IF_INET6=$tmp/no_such_file "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "ip v6 fails on a machine without IPv6: tolerated" "$ucli_rc" 0
rm -f "$UW/fail_ip6"

# The new owner cannot be promoted
fail_start
touch "$UW/fail_modify_cdc-wdm0"
ucli run
expect_eq "promote fails: exit 1" "$ucli_rc" 1
expect_contains "promote fails: says why" "$ucli_out" "could not allow default routes on cdc-wdm0"
expect_eq "promote fails: the old owner keeps its routes" "$(uholders)" "wlan0"
expect_eq "promote fails: nothing was demoted" "$(umods)" "cdc-wdm0 no;"
rm -f "$UW/fail_modify_cdc-wdm0"

# nmcli says yes and the table does not change: reverted, the old owner is untouched
fail_start
touch "$UW/noop_modify"
ucli run
expect_eq "promote is a no-op: exit 1" "$ucli_rc" 1
expect_contains "promote is a no-op: says the owner got no route" "$ucli_out" "did not get a default route"
expect_eq "promote is a no-op: the old owner keeps its routes" "$(uholders)" "wlan0"
expect_eq "promote is a no-op: the promotion is undone" "$(umods)" "cdc-wdm0 no;cdc-wdm0 yes;"
rm -f "$UW/noop_modify"

# The old owner cannot be demoted: the whole change is reverted
fail_start
touch "$UW/fail_modify_wlan0"
ucli run
expect_eq "demote fails: exit 1" "$ucli_rc" 1
expect_eq "demote fails: the old owner keeps its routes" "$(uholders)" "wlan0"
expect_eq "demote fails: the new owner is demoted again" "$(umods)" "cdc-wdm0 no;wlan0 yes;cdc-wdm0 yes;"
expect_eq "demote fails: never without a default route" "$(ucalls | grep -c 'routes=0 ' || true)" 0
rm -f "$UW/fail_modify_wlan0"

# One lost demotion: the retry fixes it
fail_start
# the promotion works; the first demotion is silently lost
cat >"$ubin/nmcli.once" <<'FAKE'
#!/usr/bin/env bash
# lose the demotion of wlan0 once, then behave
if [[ "$*" == *"device modify wlan0 ipv4.never-default yes"* ]]; then
  if [ ! -f "$UW/lost_once" ]; then
    touch "$UW/lost_once"
    echo "nmcli LC_ALL=${LC_ALL:-unset} $*" >>"$UW/calls"
    exit 0
  fi
fi
exec "$UBIN/nmcli" "$@"
FAKE
chmod +x "$ubin/nmcli.once"
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_NMCLI="$ubin/nmcli.once" "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "lost demotion: the retry succeeds, exit 0" "$ucli_rc" 0
expect_contains "lost demotion: says it retries once" "$ucli_out" "retrying once"
expect_eq "lost demotion: the modem owns" "$(uholders)" "wwan0"

# The table never gets right even after the retry: reverted
fail_start
cat >"$ubin/nmcli.stuck" <<'FAKE'
#!/usr/bin/env bash
# demotions of wlan0 are always lost
if [[ "$*" == *"device modify wlan0 ipv4.never-default yes"* ]]; then
  echo "nmcli LC_ALL=${LC_ALL:-unset} $*" >>"$UW/calls"
  exit 0
fi
exec "$UBIN/nmcli" "$@"
FAKE
chmod +x "$ubin/nmcli.stuck"
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_NMCLI="$ubin/nmcli.stuck" "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "stuck table: exit 1" "$ucli_rc" 1
expect_contains "stuck table: says it did not settle" "$ucli_out" "did not reach the wanted state"
expect_eq "stuck table: reverted, the old owner holds the routes" "$(uholders)" "wlan0"

# Bad configuration and missing tools change nothing
fail_start
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_NMCLI=/nonexistent/nmcli "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "missing nmcli: exit 1" "$ucli_rc" 1
expect_eq "missing nmcli: nothing was called" "$(ucalls)" ""
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_IP=relative/ip "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "a relative tool path is refused" "$ucli_rc" 1
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_FAILS=0 "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "a setting out of range is refused" "$ucli_rc" 1
expect_contains "a setting out of range is named" "$ucli_out" "QUECTEL_UPLINK_FAILS"
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_HOLD='1;reboot' "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "a setting with shell text is refused" "$ucli_rc" 1
expect_eq "bad settings: nothing was called" "$(umods)" ""
ucli_rc=0
ucli_out=$(XDG_RUNTIME_DIR="" QUECTEL_UPLINK_STATE_DIR="" "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "no runtime directory: exit 1, nothing changed" "$ucli_rc" 1
expect_eq "no runtime directory: nothing was modified" "$(umods)" ""

# A symlinked state directory is refused
fail_start
mkdir -p "$tmp/elsewhere"
rm -rf "$UST"
ln -s "$tmp/elsewhere" "$UST"
ucli run
expect_eq "a symlinked state directory is refused" "$ucli_rc" 1
expect_eq "a symlinked state directory: nothing written there" "$(find "$tmp/elsewhere" -mindepth 1 | wc -l)" 0
rm -f "$UST"

# A malformed mode file: leave the routes, say how to reset
fail_start
mkdir -p "$UST"
echo "cell-first yesterday never" >"$UST/mode"
ucli run
expect_eq "malformed mode file: exit 1" "$ucli_rc" 1
expect_contains "malformed mode file: says how to reset" "$ucli_out" "uplink auto"
expect_eq "malformed mode file: nothing modified" "$(umods)" ""
ucli status --json
expect_eq "malformed mode file: status exits 1" "$ucli_rc" 1
expect_eq "malformed mode file: status prints no JSON" "$(printf '%s' "$ucli_out" | grep -c '^{' || true)" 0
for bad in "" "auto" "auto x" "cell-first 1" "cell-first 1 2 3" "AUTO 5" "auto 5 6" "auto 99999999999999"; do
  printf '%s\n' "$bad" >"$UST/mode"
  ucli run
  [ "$ucli_rc" -eq 1 ] || fail "malformed mode file '$bad' is refused" "rc=$ucli_rc"
done
checks=$((checks + 1))
echo "ok   every malformed mode line is refused"
rm -f "$UST/mode"
ln -s /etc/hostname "$UST/mode"
ucli run
expect_eq "a symlinked mode file is refused" "$ucli_rc" 1
rm -f "$UST/mode"
ucli auto
expect_eq "uplink auto repairs a bad state: exit 0" "$ucli_rc" 0

# A second instance: the timer run waits one second for the lock, then skips and exits 0
fail_start
mkdir -p "$UST"
(
  exec 8>"$UST/lock"
  flock 8
  sleep 3
) &
lock_pid=$!
sleep 0.5
ucli run
expect_eq "locked: a run that finds another one running skips with exit 0" "$ucli_rc" 0
expect_contains "locked: says it skipped" "$ucli_out" "skipping this one"
expect_eq "locked: nothing was modified" "$(umods)" ""
wait "$lock_pid" || true

# --- dry run -----------------------------------------------------------------------------------------
fail_start
links_before=$(cat "$UST/links")
ucli run --dry-run
expect_eq "dry run: exit 0" "$ucli_rc" 0
expect_contains "dry run: reports the decision" "$ucli_out" "owner=cell"
expect_contains "dry run: says nothing was applied" "$ucli_out" "dry run: nothing applied"
expect_eq "dry run: nothing modified" "$(umods)" ""
expect_eq "dry run: the link state is not advanced" "$(cat "$UST/links")" "$links_before"
expect_eq "dry run: no mode written" "$([ -e "$UST/mode" ] && echo yes || echo no)" no

# --- modes ----------------------------------------------------------------------------------------------
# cell-first, its expiry, and back to auto
uscene gone ok ok
ucli run
unow 100
ucli cell-first
expect_eq "cell-first: exit 0" "$ucli_rc" 0
expect_eq "cell-first: the modem holds the defaults at once" "$(uholders)" "wwan0"
expect_eq "cell-first: promoted before demoted" "$(umods)" "cdc-wdm0 no;wlan0 yes;"
expect_eq "cell-first: default expiry is two hours" "$(cat "$UST/mode")" "cell-first $((T0 + 100)) $((T0 + 100 + 7200))"
ucli status --json
expect_contains "cell-first: status shows the mode" "$ucli_out" '"mode":"cell-first"'
expect_contains "cell-first: status shows the owner" "$ucli_out" '"owner":"cell"'
expect_contains "cell-first: status shows when it ends" "$ucli_out" '"until":"2023-11-15T00:15:00Z"'
unow 3600
ucli run
expect_eq "cell-first: still cell before it expires" "$(uholders)" "wwan0"
unow 7299
ucli run
expect_eq "cell-first: one second before the end it is still cell" "$(uholders)" "wwan0"
unow 7300
ucli run
expect_contains "cell-first: says it expired" "$ucli_out" "cell-first expired"
expect_eq "cell-first: at the end Wi-Fi owns again" "$(uholders)" "wlan0"
expect_eq "cell-first: the mode file is auto afterwards" "$(cut -d' ' -f1 "$UST/mode")" auto
ucli status --json
expect_contains "cell-first expired: status shows auto" "$ucli_out" '"mode":"auto"'
expect_contains "cell-first expired: no end any more" "$ucli_out" '"until":null'

# an expired mode that no run has cleaned up yet reads as auto in status
uscene gone ok ok
ucli run
unow 0
ucli cell-first --for 30m
unow 1800
ucli status --json
expect_contains "status: an expired cell-first reads as auto" "$ucli_out" '"mode":"auto"'
expect_contains "status: and since is when it ended" "$ucli_out" '"since":"2023-11-14T22:43:20Z"'

# --for
uscene gone ok ok
ucli run
ucli cell-first --for 90m
expect_eq "cell-first --for 90m" "$(cut -d' ' -f3 "$UST/mode")" "$((T0 + 5400))"
ucli cell-first --for 0
expect_eq "cell-first --for 0 never expires" "$(cat "$UST/mode")" "cell-first $T0 0"
export QUECTEL_UPLINK_NOW=$((T0 + 30 * 86400))
ucli run
expect_eq "cell-first --for 0: still cell a month later" "$(uholders)" "wwan0"
unow 0
ucli auto
expect_eq "auto: back to Wi-Fi" "$(uholders)" "wlan0"
expect_eq "auto: the mode file says auto" "$(cut -d' ' -f1 "$UST/mode")" auto
for bad in banana 5 -1 31d 1.5h 0h; do
  ucli cell-first --for "$bad"
  [ "$ucli_rc" -eq 1 ] || fail "cell-first --for $bad is refused" "rc=$ucli_rc"
done
checks=$((checks + 1))
echo "ok   cell-first refuses a bad --for"
expect_eq "a refused --for leaves the mode alone" "$(cut -d' ' -f1 "$UST/mode")" auto
ucli cell-first --for
expect_eq "cell-first --for without a value is a usage error" "$ucli_rc" 2
ucli cell-first --nope
expect_eq "cell-first with an unknown option is a usage error" "$ucli_rc" 2
ucli auto extra
expect_eq "auto with an argument is a usage error" "$ucli_rc" 2

# cell-first needs a connected modem, and says so
uscene gone ok gone
ucli run
: >"$UW/calls"
ucli cell-first
expect_eq "cell-first without a connected modem: exit 1" "$ucli_rc" 1
expect_contains "cell-first without a connected modem: says why" "$ucli_out" "cellular is not connected"
expect_eq "cell-first without a connected modem: no mode written" "$([ -e "$UST/mode" ] && echo yes || echo no)" no
expect_eq "cell-first without a connected modem: routes untouched" "$(umods)" ""
uscene gone ok none
ucli cell-first
expect_eq "cell-first without a modem device: exit 1" "$ucli_rc" 1

# a failed switch puts the old mode back
uscene gone ok ok
ucli auto
touch "$UW/fail_modify_cdc-wdm0"
ucli cell-first
expect_eq "failed switch: exit 1" "$ucli_rc" 1
expect_eq "failed switch: the previous mode is back" "$(cut -d' ' -f1 "$UST/mode")" auto
expect_eq "failed switch: Wi-Fi still owns" "$(uholders)" "wlan0"
rm -f "$UW/fail_modify_cdc-wdm0"
rm -rf "$UST"
touch "$UW/fail_modify_cdc-wdm0"
ucli cell-first
expect_eq "failed switch with no previous mode: no mode file is left" "$([ -e "$UST/mode" ] && echo yes || echo no)" no
rm -f "$UW/fail_modify_cdc-wdm0"

# cell-first falls back if the modem drops: the order never strands the machine
uscene gone ok ok
ucli cell-first
sed -i 's/^cdc-wdm0:gsm:connected/cdc-wdm0:gsm:unavailable/' "$UW/devices"
rm -f "$UW/rt4_wwan0" "$UW/rt6_wwan0" # the modem went away with its routes
unow 15
ucli run
expect_contains "cell-first: modem gone, falls back to wifi" "$ucli_out" "owner=wifi"
expect_eq "cell-first: modem gone, Wi-Fi holds the defaults again" "$(uholders)" "wlan0"

# --- status --json: the contract the tray builds against --------------------------------------------------
uscene none ok ok
ucli run
ucli status --json
expect_eq "status: exit 0" "$ucli_rc" 0
expect_eq "status: the exact JSON, field order and all" "$ucli_out" \
  '{"mode":"auto","owner":"wifi","links":{"ethernet":{"state":"absent","healthy":false},"wifi":{"state":"up","healthy":true},"cell":{"state":"up","healthy":true}},"until":null,"since":"2023-11-14T22:13:20Z"}'
json_check=$(printf '%s' "$ucli_out" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert list(d) == ["mode", "owner", "links", "until", "since"], list(d)
assert d["mode"] in ("auto", "cell-first")
assert d["owner"] in ("ethernet", "wifi", "cell", "none")
assert list(d["links"]) == ["ethernet", "wifi", "cell"]
for k, v in d["links"].items():
    assert list(v) == ["state", "healthy"], (k, v)
    assert v["state"] in ("up", "down", "absent")
    assert isinstance(v["healthy"], bool)
assert d["until"] is None or isinstance(d["until"], str)
assert isinstance(d["since"], str) and d["since"].endswith("Z")
print("valid")
' 2>&1 || true)
expect_eq "status: valid JSON with exactly the contracted fields and types" "$json_check" valid
uscene ok ok ok
ucli run
ucli status --json
expect_contains "status: ethernet owner, and it is healthy" "$ucli_out" '"owner":"ethernet","links":{"ethernet":{"state":"up","healthy":true}'
expect_contains "status: a demoted Wi-Fi is still up and healthy (measured through its gateway)" "$ucli_out" '"wifi":{"state":"up","healthy":true}'
uscene gone ok ok
ucli status --json
expect_contains "status: an unplugged ethernet is down, not healthy" "$ucli_out" '"ethernet":{"state":"down","healthy":false}'
uscene none none none
ucli status --json
expect_contains "status: no links at all: owner none" "$ucli_out" '"owner":"none"'
expect_contains "status: no links at all: everything absent" "$ucli_out" '"cell":{"state":"absent","healthy":false}'
# unhealthy after a measured failure
uscene gone ok ok
ucli run
rm -f "$UW/ping_wlan0"
unow 15
ucli run
unow 30
ucli run
ucli status --json
expect_contains "status: a link that failed over is not healthy" "$ucli_out" '"wifi":{"state":"up","healthy":false}'
expect_contains "status: and the modem owns" "$ucli_out" '"owner":"cell"'
# an idle modem that was unplugged and came back reads healthy again (it cannot be measured while idle)
uscene gone ok gone
ucli run
sed -i 's/^cdc-wdm0:gsm:unavailable/cdc-wdm0:gsm:connected/' "$UW/devices"
echo wwan0 >"$UW/ipif_cdc-wdm0"
unow 15
ucli run
ucli status --json
expect_contains "status: a modem that came back is up and healthy again" "$ucli_out" '"cell":{"state":"up","healthy":true}'
# a modem that failed as the owner and was demoted again is healthy again too
uscene gone ok ok
ucli run
rm -f "$UW/ping_wlan0"
unow 15
ucli run
unow 30
ucli run
rm -f "$UW/ping_wwan0"
unow 45
ucli run
unow 60
ucli run
ucli status --json
expect_contains "status: a failed modem owner reads unhealthy" "$ucli_out" '"cell":{"state":"up","healthy":false}'
echo ok >"$UW/ping_wlan0"
echo ok >"$UW/ping_wwan0"
for t in 75 90 105 120 135 150 165 180 195; do
  unow "$t"
  ucli run
done
expect_eq "status: Wi-Fi owns again after the hold-down" "$(uholders)" "wlan0"
ucli status --json
expect_contains "status: the idle modem is healthy again once demoted" "$ucli_out" '"cell":{"state":"up","healthy":true}'
# status is read only, and fails closed
uscene gone ok ok
ucli run
rm -rf "$UST"
: >"$UW/calls"
ucli status --json
expect_eq "status: makes no change" "$(umods)" ""
expect_eq "status: creates no state" "$([ -e "$UST" ] && echo yes || echo no)" no
expect_eq "status: sends no ping" "$(ucalls | grep -c '^ping' || true)" 0
touch "$UW/fail_nmcli"
ucli status --json
expect_eq "status: nmcli failing is exit 1" "$ucli_rc" 1
expect_eq "status: and no JSON on stdout" "$(printf '%s' "$ucli_out" | grep -c '^{' || true)" 0
rm -f "$UW/fail_nmcli"
touch "$UW/fail_ip4"
ucli status --json
expect_eq "status: ip failing is exit 1" "$ucli_rc" 1
rm -f "$UW/fail_ip4"
ucli status
expect_contains "status: plain text names the owner" "$ucli_out" "owner:    wifi"

# The default state directory is under XDG_RUNTIME_DIR
uscene gone ok ok
mkdir -p "$tmp/xdg"
chmod 0700 "$tmp/xdg"
ucli_rc=0
ucli_out=$(env -u QUECTEL_UPLINK_STATE_DIR XDG_RUNTIME_DIR="$tmp/xdg" "$TOOL" uplink auto 2>&1) || ucli_rc=$?
expect_eq "default state directory: exit 0" "$ucli_rc" 0
expect_eq "default state directory: \$XDG_RUNTIME_DIR/quectel-usbnet" "$(cut -d' ' -f1 "$tmp/xdg/quectel-usbnet/mode")" auto

# --- the command line -------------------------------------------------------------------------------------------
set +e
"$TOOL" uplink >/dev/null 2>&1
code=$?
set -e
expect_eq "uplink with no subcommand exits 2" "$code" 2
set +e
"$TOOL" uplink sideways >/dev/null 2>&1
code=$?
set -e
expect_eq "uplink with an unknown subcommand exits 2" "$code" 2
set +e
"$TOOL" uplink status --nope >/dev/null 2>&1
code=$?
set -e
expect_eq "uplink status with an unknown option exits 2" "$code" 2
set +e
"$TOOL" uplink run --nope >/dev/null 2>&1
code=$?
set -e
expect_eq "uplink run with an unknown option exits 2" "$code" 2
usage_text=$("$TOOL" 2>&1 || true)
expect_contains "usage names uplink status" "$usage_text" "uplink status"
expect_contains "usage names cell-first" "$usage_text" "uplink cell-first"
expect_contains "usage names guard-uninstall" "$usage_text" "guard-uninstall"

# --- the printed steps -----------------------------------------------------------------------------------------------
uscene gone ok ok
: >"$UW/calls"
inst_home="$tmp/uhome"
mkdir -p "$inst_home"
export QUECTEL_UPLINK_FLOCK
QUECTEL_UPLINK_FLOCK=$(command -v flock)
QUECTEL_UPLINK_TIMEOUT=$(command -v timeout)
export QUECTEL_UPLINK_TIMEOUT
steps=$("$TOOL" uplink install 2>&1)
expect_eq "install: prints and runs nothing (no tool was called)" "$(ucalls)" ""
expect_eq "install: creates nothing" "$(find "$inst_home" -mindepth 1 | wc -l)" 0
expect_eq "install: never uses sudo" "$(printf '%s\n' "$steps" | grep -c sudo || true)" 0
expect_contains "install: closes the modem profile on both families" "$steps" "ipv4.never-default yes ipv6.never-default yes"
expect_contains "install: finds the gsm profile from NetworkManager, by type" "$steps" "[ \"\$ptype\" = gsm ] || continue"
expect_contains "install: the unit keeps the fixed PATH line" "$steps" 'Environment="PATH=/usr/sbin:/usr/bin"'
expect_contains "install: the unit bakes in the absolute nmcli" "$steps" "Environment=\"QUECTEL_UPLINK_NMCLI=$ubin/nmcli\""
expect_contains "install: the unit bakes in the absolute ip" "$steps" "Environment=\"QUECTEL_UPLINK_IP=$ubin/ip\""
expect_contains "install: the unit bakes in the absolute ping" "$steps" "Environment=\"QUECTEL_UPLINK_PING=$ubin/ping\""
expect_contains "install: the timer runs every 15 seconds" "$steps" "OnUnitActiveSec=15s"
expect_contains "install: a systemd user timer, enabled with --user" "$steps" "systemctl --user enable --now quectel-uplink.timer"
expect_contains "install: the service runs uplink run from the copy" "$steps" "ExecStart=%h/.local/libexec/quectel-usbnet-uplink uplink run"
expect_contains "install: says what a stop leaves behind" "$steps" "What a stopped or crashed manager leaves behind"
expect_contains "install: says how to return to a clean state" "$steps" "nmcli device reapply"
expect_contains "install: the printed block is valid bash" "$(printf '%s\n' "$steps" | sed -n "/^bash -e <<'UPLINK_INSTALL'/,/^UPLINK_INSTALL/p" | sed '1d;$d' | bash -n 2>&1 && echo syntax-ok)" syntax-ok

# Run the printed steps for real against a temp HOME, a fake systemctl and the fake world.
mkdir -p "$tmp/sbin_fake"
cat >"$tmp/sbin_fake/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >>"$UW/calls"
FAKE
chmod +x "$tmp/sbin_fake/systemctl"
printf 'aaaa-1111:802-3-ethernet\nbbbb-2222:gsm\ncccc-3333:802-11-wireless\ndddd-4444:gsm\n' >"$UW/connections"
printf '%s\n' "$steps" | sed -n "/^bash -e <<'UPLINK_INSTALL'/,/^UPLINK_INSTALL/p" | sed '1d;$d' >"$tmp/install_block.sh"
run_install() {
  HOME="$inst_home" XDG_CONFIG_HOME="" PATH="$tmp/sbin_fake:$PATH" bash -e "$tmp/install_block.sh" 2>&1
}
uopen
: >"$UW/calls"
# the copy is made from the real script and carries its marker
out=$(run_install) || fail "install: the printed steps run" "$out"
unit_dir="$inst_home/.config/systemd/user"
expect_eq "install steps: the two gsm profiles are closed, by uuid" \
  "$(ucalls | grep 'connection modify' | sed 's/^nmcli LC_ALL=C --escape no //' | tr '\n' ';')" \
  "nmcli LC_ALL=C connection modify uuid bbbb-2222 ipv4.never-default yes ipv6.never-default yes;nmcli LC_ALL=C connection modify uuid dddd-4444 ipv4.never-default yes ipv6.never-default yes;"
expect_eq "install steps: no other profile is touched" "$(ucalls | grep 'connection modify' | grep -c -e aaaa -e cccc || true)" 0
expect_eq "install steps: the copy is executable" "$(stat -c %a "$inst_home/.local/libexec/quectel-usbnet-uplink")" 755
expect_eq "install steps: the copy is the script" "$(sed -n 2p "$inst_home/.local/libexec/quectel-usbnet-uplink")" "# quectel-usbnet: read or change the USB network mode of a Quectel modem."
expect_eq "install steps: the service unit is written, first line is the marker" "$(head -n 1 "$unit_dir/quectel-uplink.service")" "# written by quectel-usbnet uplink install"
expect_eq "install steps: the timer unit is written, first line is the marker" "$(head -n 1 "$unit_dir/quectel-uplink.timer")" "# written by quectel-usbnet uplink install"
expect_eq "install steps: unit files are not group or world writable" "$(stat -c %a "$unit_dir/quectel-uplink.service")" 644
expect_contains "install steps: the timer is enabled for the user" "$(ucalls)" "systemctl --user enable --now quectel-uplink.timer"
expect_contains "install steps: the unit manager is reloaded first" "$(ucalls | head -n 20 | tr '\n' ';')" "systemctl --user daemon-reload"
expect_eq "install steps: the first evaluation ran and left Wi-Fi owner, modem closed" "$(uholders)" "wlan0"
expect_eq "install steps: the first evaluation wrote the mode" "$(cut -d' ' -f1 "$UST/mode")" auto
expect_eq "install steps: no leftover temp files" "$(find "$inst_home" -name '.*.??????' | wc -l)" 0
# re-running refreshes the copy
echo "# stale" >>"$inst_home/.local/libexec/quectel-usbnet-uplink"
out=$(run_install) || fail "install: running the steps again" "$out"
expect_eq "install steps: running again refreshes the copy" "$(grep -c '^# stale' "$inst_home/.local/libexec/quectel-usbnet-uplink" || true)" 0

# refusals: a foreign file, a symlink, a foreign copy
rm -rf "$inst_home"
mkdir -p "$unit_dir"
echo "[Unit]" >"$unit_dir/quectel-uplink.service"
if out=$(run_install); then
  fail "install: a foreign unit file is not overwritten"
else
  ok "install: a foreign unit file is not overwritten"
fi
expect_contains "install: names the refusal" "$out" "refusing"
expect_eq "install: the foreign file is intact" "$(cat "$unit_dir/quectel-uplink.service")" "[Unit]"
rm -rf "$inst_home"
mkdir -p "$unit_dir" "$tmp/target_dir"
echo "victim" >"$tmp/target_dir/victim"
ln -s "$tmp/target_dir/victim" "$unit_dir/quectel-uplink.timer"
if out=$(run_install); then
  fail "install: a symlinked unit is not followed"
else
  ok "install: a symlinked unit is not followed"
fi
expect_eq "install: the symlink target is intact" "$(cat "$tmp/target_dir/victim")" victim
rm -rf "$inst_home"
mkdir -p "$inst_home/.local/libexec"
echo "not ours" >"$inst_home/.local/libexec/quectel-usbnet-uplink"
if out=$(run_install); then
  fail "install: a foreign copy is not overwritten"
else
  ok "install: a foreign copy is not overwritten"
fi
expect_eq "install: the foreign copy is intact" "$(cat "$inst_home/.local/libexec/quectel-usbnet-uplink")" "not ours"
rm -rf "$inst_home"
mkdir -p "$inst_home/.local/libexec"
ln -s "$tmp/target_dir/victim" "$inst_home/.local/libexec/quectel-usbnet-uplink"
if out=$(run_install); then
  fail "install: a symlinked copy is not followed"
else
  ok "install: a symlinked copy is not followed"
fi
expect_eq "install: the symlinked copy's target is intact" "$(cat "$tmp/target_dir/victim")" victim

# a tool whose path would break a unit file is refused
mkdir -p "$tmp/odd dir"
cp "$ubin/nmcli" "$tmp/odd dir/nmcli"
if out=$(QUECTEL_UPLINK_NMCLI="$tmp/odd dir/nmcli" "$TOOL" uplink install 2>&1); then
  fail "install: a tool path with a space is refused"
else
  ok "install: a tool path with a space is refused"
fi
mkdir -p "$tmp/odd%dir"
cp "$ubin/nmcli" "$tmp/odd%dir/nmcli"
if out=$(QUECTEL_UPLINK_NMCLI="$tmp/odd%dir/nmcli" "$TOOL" uplink install 2>&1); then
  fail "install: a tool path with % is refused"
else
  ok "install: a tool path with % is refused"
fi

# uninstall: the printed steps, run for real against the installed temp HOME
rm -rf "$inst_home"
uscene gone ok ok
uopen
printf 'bbbb-2222:gsm\n' >"$UW/connections"
out=$(run_install) || fail "install: for the uninstall test" "$out"
ucli cell-first
expect_eq "uninstall setup: cellular owns" "$(uholders)" "wwan0"
usteps=$("$TOOL" uplink uninstall 2>&1)
expect_eq "uninstall: never uses sudo" "$(printf '%s\n' "$usteps" | grep -c sudo || true)" 0
expect_contains "uninstall: stops the timer" "$usteps" "systemctl --user disable --now quectel-uplink.timer"
expect_contains "uninstall: returns to a clean state with uplink auto" "$usteps" "\"\$dest\" uplink auto"
expect_contains "uninstall: explains the closed modem profile" "$usteps" "stays closed on purpose"
printf '%s\n' "$usteps" | sed -n "/^bash <<'UPLINK_UNINSTALL'/,/^UPLINK_UNINSTALL/p" | sed '1d;$d' >"$tmp/uninstall_block.sh"
: >"$UW/calls"
echo "[Unit]" >"$unit_dir/quectel-uplink-other.service"
out=$(HOME="$inst_home" XDG_CONFIG_HOME="" XDG_RUNTIME_DIR="$tmp/xdg_u" PATH="$tmp/sbin_fake:$PATH" bash "$tmp/uninstall_block.sh" 2>&1) || fail "uninstall: the printed steps run" "$out"
expect_contains "uninstall: stops and disables the timer" "$(ucalls)" "systemctl --user disable --now quectel-uplink.timer"
expect_eq "uninstall: auto ran before the copy was removed, Wi-Fi owns again" "$(uholders)" "wlan0"
expect_eq "uninstall: the service unit is removed" "$([ -e "$unit_dir/quectel-uplink.service" ] && echo kept || echo removed)" removed
expect_eq "uninstall: the timer unit is removed" "$([ -e "$unit_dir/quectel-uplink.timer" ] && echo kept || echo removed)" removed
expect_eq "uninstall: the copy is removed" "$([ -e "$inst_home/.local/libexec/quectel-usbnet-uplink" ] && echo kept || echo removed)" removed
expect_eq "uninstall: a file that is not ours is left" "$(cat "$unit_dir/quectel-uplink-other.service")" "[Unit]"
echo "foreign" >"$unit_dir/quectel-uplink.service"
out=$(HOME="$inst_home" XDG_CONFIG_HOME="" PATH="$tmp/sbin_fake:$PATH" bash "$tmp/uninstall_block.sh" 2>&1) || true
expect_eq "uninstall: a foreign file with our name is left" "$(cat "$unit_dir/quectel-uplink.service")" foreign
expect_contains "uninstall: and says so" "$out" "left"
# the runtime state is removed by exact name
mkdir -p "$tmp/xdg_u/quectel-usbnet"
touch "$tmp/xdg_u/quectel-usbnet/mode" "$tmp/xdg_u/quectel-usbnet/links" "$tmp/xdg_u/quectel-usbnet/lock" "$tmp/xdg_u/quectel-usbnet/keepme"
out=$(HOME="$inst_home" XDG_CONFIG_HOME="" XDG_RUNTIME_DIR="$tmp/xdg_u" PATH="$tmp/sbin_fake:$PATH" bash "$tmp/uninstall_block.sh" 2>&1) || true
expect_eq "uninstall: the state files are removed" "$(find "$tmp/xdg_u/quectel-usbnet" -mindepth 1 | tr '\n' ' ')" "$tmp/xdg_u/quectel-usbnet/keepme "
expect_contains "uninstall: the printed block is valid bash" "$(bash -n "$tmp/uninstall_block.sh" 2>&1 && echo syntax-ok)" syntax-ok

# guard-uninstall: printed only, marker-checked, and valid bash
gsteps=$("$TOOL" guard-uninstall 2>&1)
expect_contains "guard-uninstall: stops the legacy timer" "$gsteps" "sudo systemctl disable --now quectel-modem-guard.timer"
expect_contains "guard-uninstall: removes the legacy nft table" "$gsteps" "sudo nft delete table inet quectel_modem_guard"
expect_contains "guard-uninstall: checks the guard's marker" "$gsteps" "written\\ by\\ quectel-usbnet\\ guard-install"
expect_contains "guard-uninstall: leaves foreign files" "$gsteps" "not written by quectel-usbnet"
expect_eq "guard-uninstall: names no wildcard" "$(printf '%s\n' "$gsteps" | grep -c '\*' || true)" 0
printf '%s\n' "$gsteps" | sed -n "/^bash <<'GUARD_UNINSTALL'/,/^GUARD_UNINSTALL/p" | sed '1d;$d' >"$tmp/guard_uninstall_block.sh"
expect_contains "guard-uninstall: the printed block is valid bash" "$(bash -n "$tmp/guard_uninstall_block.sh" 2>&1 && echo syntax-ok)" syntax-ok

# printing runs nothing: no printed step touched the fake world's tools
uscene gone ok ok
: >"$UW/calls"
"$TOOL" uplink uninstall >/dev/null 2>&1
"$TOOL" guard-uninstall >/dev/null 2>&1
expect_eq "uninstall and guard-uninstall only print" "$(ucalls)" ""
