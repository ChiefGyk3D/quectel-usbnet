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
ULD="$tmp/uledger"
ubin="$tmp/ubin"
mkdir -p "$ubin"

# --- the fakes -------------------------------------------------------------------
# The world is the directory $UW:
#   devices            what `nmcli -t -f DEVICE,TYPE,STATE device` prints
#   ipif_DEV           the IP interface of a device (modem: wwan0)
#   uuid_DEV           the UUID of the profile active on a device
#   prof_UUID          that profile's never-default and route metrics (4 lines)
#   props_DEV          the runtime values a `device modify` set (4 lines)
#   rt4_IF rt6_IF      the default routes the interface holds right now
#   tpl4_IF tpl6_IF    the routes NetworkManager installs when defaults are allowed
#   ping_IF=ok         IPv4 internet answers through IF (only if IF holds an IPv4 default)
#   ping6_IF=ok        the same for IPv6
#   nolink_DEV         the modem has lost its link
#   calls              every call, in order
cat >"$ubin/apply" <<'FAKE'
#!/usr/bin/env bash
# apply DEV ND4 ND6 RM4 RM6: what NetworkManager does to the routes of a device
dev=$1
iface=$dev
[ ! -f "$UW/ipif_$dev" ] || iface=$(cat "$UW/ipif_$dev")
for fam in 4 6; do
  if [ "$fam" = 4 ]; then nd=$2 rm=$4; else nd=$3 rm=$5; fi
  if [ "$nd" = yes ]; then
    rm -f "$UW/rt${fam}_$iface"
  elif [ -f "$UW/tpl${fam}_$iface" ]; then
    if [ "$rm" = -1 ]; then
      cp "$UW/tpl${fam}_$iface" "$UW/rt${fam}_$iface"
    else
      sed -E "s/metric [0-9]+/metric $rm/" "$UW/tpl${fam}_$iface" >"$UW/rt${fam}_$iface"
    fi
  fi
done
FAKE
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
  "-t -f DEVICE device")
    [ ! -f "$UW/fail_devs" ] || { echo "Error: boom" >&2; exit 1; }
    cut -d: -f1 "$UW/devices"
    ;;
  "-t -f UUID,TYPE connection")
    [ ! -f "$UW/fail_conlist" ] || { echo "Error: boom" >&2; exit 1; }
    cat "$UW/connections"
    ;;
  "-g ipv4.never-default,ipv6.never-default connection show")
    [ ! -f "$UW/fail_conread_$6" ] || { echo "Error: no such profile" >&2; exit 1; }
    if [ -f "$UW/prof_$6" ]; then head -n 2 "$UW/prof_$6"; else printf 'no\nno\n'; fi
    ;;
  "-g GENERAL.IP-IFACE device show") cat "$UW/ipif_$5" 2>/dev/null || true ;;
  "-g GENERAL.CON-UUID device show")
    # fail_cur: the active connection of any device cannot be read
    [ ! -f "$UW/fail_cur" ] || { echo "Error: boom" >&2; exit 1; }
    cat "$UW/uuid_$5" 2>/dev/null || true
    ;;
  "-g GENERAL.STATE device show")
    if [ -f "$UW/nolink_$5" ]; then echo "30 (disconnected)"; else echo "100 (connected)"; fi
    ;;
  "-g ipv4.never-default,ipv6.never-default,ipv4.route-metric,ipv6.route-metric connection show")
    [ ! -f "$UW/fail_cur" ] || { echo "Error: no such profile" >&2; exit 1; }
    cat "$UW/prof_$6"
    ;;
  "connection modify uuid "*)
    [ ! -f "$UW/fail_conmod_$4" ] || { echo "Error: modify failed" >&2; exit 1; }
    # the profile changes: never-default is rewritten in the fake profile, when it has one
    if [ -f "$UW/prof_$4" ]; then
      { echo "$6"; echo "$8"; tail -n 2 "$UW/prof_$4"; } >"$UW/prof_$4.new"
      mv "$UW/prof_$4.new" "$UW/prof_$4"
    fi
    ;;
  "device modify "*)
    dev=$3
    shift 3
    if [ -f "$UW/fail_modify" ] || [ -f "$UW/fail_modify_$dev" ]; then
      echo "Error: modify failed" >&2
      exit 1
    fi
    if [ "$1" != ipv4.never-default ] || [ "$3" != ipv6.never-default ] || [ "$5" != ipv4.route-metric ] || [ "$7" != ipv6.route-metric ]; then
      echo "Error: unexpected arguments" >&2
      exit 1
    fi
    if [ -f "$UW/noop_modify" ]; then exit 0; fi
    if [ -f "$UW/noop_modify_once" ]; then
      rm -f "$UW/noop_modify_once"
      exit 0
    fi
    printf '%s\n%s\n%s\n%s\n' "$2" "$4" "$6" "$8" >"$UW/props_$dev"
    "$UBIN/apply" "$dev" "$2" "$4" "$6" "$8"
    # hook: right after this device is changed to this value, the modem loses its
    # route, its link, or both (the file holds "DEVICE VALUE [route|link|both]")
    if [ -f "$UW/hook_after_modify" ]; then
      read -r hd hv hm <"$UW/hook_after_modify"
      if [ "$hd $hv" = "$dev $2" ]; then
        case ${hm:-both} in route | both) rm -f "$UW/rt4_wwan0" "$UW/rt6_wwan0" ;; esac
        case ${hm:-both} in link | both) touch "$UW/nolink_cdc-wdm0" ;; esac
      fi
    fi
    echo "routes=$(nroutes) after modify $dev $2" >>"$UW/calls"
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
if [ -f "$UW/ping_term" ]; then
  trap 'echo "ping got TERM" >>"$UW/calls"; exit 1' TERM
  sleep 100 &
  wait
fi
if [ -f "$UW/ping_sleep" ]; then sleep "$(cat "$UW/ping_sleep")"; fi
# the internet is only reachable through an interface that holds a default route
# of the family of the target
if [[ $target == *:* ]]; then
  [ -s "$UW/rt6_$iface" ] || exit 1
  [ "$(cat "$UW/ping6_$iface" 2>/dev/null)" = ok ]
else
  [ -s "$UW/rt4_$iface" ] || exit 1
  [ "$(cat "$UW/ping_$iface" 2>/dev/null)" = ok ] || exit 1
  # ping_dropsroute_IF holds N: the Nth answer is the last; the route is gone right after
  if [ -f "$UW/ping_dropsroute_$iface" ]; then
    n=$(cat "$UW/ping_dropsroute_$iface")
    if [ "$n" -le 1 ]; then
      rm -f "$UW/rt4_$iface" "$UW/ping_dropsroute_$iface"
    else
      echo $((n - 1)) >"$UW/ping_dropsroute_$iface"
    fi
  fi
fi
FAKE
chmod +x "$ubin"/*

# The seams the unit would set, and the clocks.
export UW
UBIN="$ubin"
export UBIN
export QUECTEL_UPLINK_NMCLI="$ubin/nmcli"
export QUECTEL_UPLINK_IP="$ubin/ip"
export QUECTEL_UPLINK_PING="$ubin/ping"
export QUECTEL_UPLINK_STATE_DIR="$UST"
export QUECTEL_UPLINK_LEDGER_DIR="$ULD"
export QUECTEL_UPLINK_TARGETS="192.0.2.1 198.51.100.1"
export QUECTEL_UPLINK_TARGETS6="2001:db8::1 2001:db8::2"
export QUECTEL_UPLINK_VERIFY_WAIT=0
export QUECTEL_UPLINK_VERIFY_TRIES=2
T0=1700000000
M0=1000

# uscene ETH WIFI CELL: each ok | dead | gone (listed, but unavailable) | none (no
# device at all). dead = connected and holding its routes, but the internet does
# not answer. Cellular is always closed (never-default, as the install leaves it).
uscene() {
  rm -rf "$UW" "$UST" "$ULD"
  mkdir -p "$UW"
  printf 'lo:loopback:connected (externally)\nvpn0:tun:connected\n' >"$UW/devices"
  uadd eth0 ethernet "$1" 100 192.0.2.254 1
  uadd wlan0 wifi "$2" 600 192.0.2.253 2
  if [ "$3" != none ]; then
    echo "cdc-wdm0:gsm:$([ "$3" = gone ] && echo unavailable || echo connected)" >>"$UW/devices"
    echo wwan0 >"$UW/ipif_cdc-wdm0"
    echo "default dev wwan0 proto static metric 1100" >"$UW/tpl4_wwan0"
    echo "default dev wwan0 proto static metric 1100 pref medium" >"$UW/tpl6_wwan0"
    if [ "$3" != gone ]; then
      echo 00000003-0000-0000-0000-000000000000 >"$UW/uuid_cdc-wdm0"
      printf 'yes\nyes\n1100\n1100\n' >"$UW/prof_00000003-0000-0000-0000-000000000000"
    fi
    [ "$3" != ok ] || echo ok >"$UW/ping_wwan0"
  fi
  unow 0
  return 0
}
# uadd DEV TYPE STATE METRIC GATEWAY N
uadd() {
  local dev=$1 type=$2 state=$3 metric=$4 gw=$5 n=$6
  [ "$state" != none ] || return 0
  if [ "$state" = gone ]; then
    echo "$dev:$type:unavailable" >>"$UW/devices"
    return 0
  fi
  echo "$dev:$type:connected" >>"$UW/devices"
  echo "default via $gw dev $dev proto dhcp metric $metric" >"$UW/tpl4_$dev"
  cp "$UW/tpl4_$dev" "$UW/rt4_$dev"
  echo "0000000$n-0000-0000-0000-000000000000" >"$UW/uuid_$dev"
  printf 'no\nno\n-1\n-1\n' >"$UW/prof_0000000$n-0000-0000-0000-000000000000"
  if [ "$state" = ok ]; then echo ok >"$UW/ping_$dev"; fi
  return 0
}
# uopen: the modem profile is not closed yet, so cellular holds default routes
uopen() {
  printf 'no\nno\n1100\n1100\n' >"$UW/prof_00000003-0000-0000-0000-000000000000"
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
# umods: the device modify calls, in order, compact: "DEVICE never-default route-metric;"
umods() {
  ucalls | grep 'device modify' | sed -E 's/^nmcli LC_ALL=C --escape no --wait [0-9]+ device modify ([^ ]+) ipv4.never-default ([a-z]+) ipv6.never-default ([a-z]+) ipv4.route-metric (-?[0-9]+) ipv6.route-metric (-?[0-9]+)$/\1 \2 \4/' | tr '\n' ';' || true
}
# uledger: the devices in the ledger, sorted
uledger() {
  { cut -d' ' -f1 "$ULD/ledger" 2>/dev/null || true; } | sort | tr '\n' ' ' | sed 's/ $//'
}
# ucli ARGS: run the real command line; sets ucli_out (stdout and stderr) and ucli_rc
ucli() {
  ucli_rc=0
  ucli_out=$("$TOOL" uplink "$@" 2>&1) || ucli_rc=$?
}
# unow SECONDS: both clocks, that many seconds after the start
unow() {
  export QUECTEL_UPLINK_NOW=$((T0 + $1))
  export QUECTEL_UPLINK_MONO=$((M0 + $1))
}

# --- pure: link health with hysteresis ----------------------------------------------
UP_FAILS=2
UP_OKS=2
expect_eq "step: one failed probe keeps an up link up" "$(uplink_link_step up 0 0 fail)" "up 1 0"
expect_eq "step: two failed probes take it down" "$(uplink_link_step up 1 0 fail)" "down 2 0"
expect_eq "step: a good probe resets the failures" "$(uplink_link_step up 1 0 ok)" "up 0 1"
expect_eq "step: one good probe does not bring a down link up" "$(uplink_link_step down 0 0 ok)" "down 0 1"
expect_eq "step: two good probes bring a down link up" "$(uplink_link_step down 0 1 ok)" "up 0 2"
expect_eq "step: a failure resets the good probes" "$(uplink_link_step down 0 1 fail)" "down 1 0"
expect_eq "step: absent goes down at once" "$(uplink_link_step up 0 5 absent)" "down 2 0"
expect_eq "step: skip changes nothing" "$(uplink_link_step up 1 3 skip)" "up 1 3"
expect_eq "step: skip does not revive a down link" "$(uplink_link_step down 0 1 skip)" "down 0 1"
expect_eq "step: an unknown probe never counts as healthy" "$(uplink_link_step down 0 1 weird)" "down 0 0"
expect_eq "step: a counter cannot grow without bound" "$(uplink_link_step up 0 99 ok | cut -d' ' -f3)" 99
UP_FAILS=3
expect_eq "step: UP_FAILS is honored" "$(uplink_link_step up 1 0 fail)" "up 2 0"
UP_FAILS=2
UP_OKS=3
expect_eq "step: UP_OKS is honored" "$(uplink_link_step down 0 1 ok)" "down 0 2"
UP_OKS=2

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
expect_eq "routes: devices and metrics of default routes, both families" \
  "$(printf 'default via 192.0.2.1 dev eth0 proto dhcp metric 100\ndefault via fe80::1 dev wlan0 proto ra metric 1024 pref medium\n' | uplink_route_devs | tr '\n' ';')" "eth0 100;wlan0 1024;"
expect_eq "routes: a route without a metric is metric 0" \
  "$(printf 'default dev wwan0 proto static\n' | uplink_route_devs | tr '\n' ';')" "wwan0 0;"
expect_eq "routes: a multipath default names every device" \
  "$(printf 'default nexthop via 192.0.2.1 dev eth0 weight 1 nexthop via 192.0.2.2 dev wlan0 weight 1\n' | uplink_route_devs | tr '\n' ';')" "eth0 0;wlan0 0;"
expect_eq "routes: only plain default routes count" \
  "$(printf 'unreachable default dev lo metric 4278198272\n10.0.0.0/24 dev eth0 proto kernel\nblackhole default\n' | uplink_route_devs | tr '\n' ' ')" ""
expect_eq "routes: a hostile device name is dropped" \
  "$(printf 'default dev eth0;reboot proto static\n' | uplink_route_devs | tr '\n' ' ')" ""
expect_eq "metric: the lowest metric of an interface" "$(uplink_metric_of $'eth0 200\neth0 100\nwlan0 50' eth0)" 100
expect_eq "metric: an interface that is not there has none" "$(uplink_metric_of $'eth0 200' eth)" ""
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

# --- pure: the mode file and the clocks --------------------------------------------------------
# uplink_load_mode NOW MONO on a mode file; prints "MODE EXPIRED UNTIL"
mode_check() {
  UP_DIR="$tmp/modecheck"
  rm -rf "$UP_DIR"
  mkdir -p "$UP_DIR"
  if [ -n "$1" ]; then printf '%b\n' "$1" >"$UP_DIR/mode"; fi
  uplink_load_mode "$2" "$3" || {
    echo invalid
    return 0
  }
  echo "$UP_MODE $UP_EXPIRED $UP_UNTIL"
}
# a cell-first set at wall 1000 / mono 500, for 3600 s, ending at wall 4600
cf="cell-first 1000 4600 500 3600"
expect_eq "mode: no file is auto" "$(mode_check "" 1000 500)" "auto false 0"
expect_eq "mode: an auto line" "$(mode_check "auto 900" 1000 500)" "auto false 0"
expect_eq "mode: a live cell-first" "$(mode_check "$cf" 2000 1500)" "cell-first false 4600"
expect_eq "mode: it ends when the wall clock reaches the end" "$(mode_check "$cf" 4600 1500)" "auto true 0"
expect_eq "mode: one second before, it is live" "$(mode_check "$cf" 4599 1500)" "cell-first false 4600"
expect_eq "mode: a forward wall clock jump past the end ends it" "$(mode_check "$cf" 90000 1500)" "auto true 0"
expect_eq "mode: a backward wall clock jump ends it at once" "$(mode_check "$cf" 999 1500)" "auto true 0"
expect_eq "mode: a large backward jump ends it too" "$(mode_check "$cf" 1 1500)" "auto true 0"
expect_eq "mode: the monotonic clock ends it even if the wall clock stands still" "$(mode_check "$cf" 2000 4100)" "auto true 0"
expect_eq "mode: one second of monotonic time before the end it is live" "$(mode_check "$cf" 2000 4099)" "cell-first false 4600"
expect_eq "mode: a monotonic clock behind its start (a reboot) ends it" "$(mode_check "$cf" 2000 100)" "auto true 0"
expect_eq "mode: no expiry means no clock check, even after a backward jump" "$(mode_check "cell-first 1000 0 500 0" 1 100)" "cell-first false 0"
up_now=$(cut -d. -f1 /proc/uptime)
up_got=$(QUECTEL_UPLINK_MONO="" uplink_mono)
expect_eq "mono: the real monotonic clock is /proc/uptime, not the wall clock" "$((up_got >= up_now && up_got <= up_now + 3 ? 1 : 0))" 1
for bad in "cell-first 1000 4600" "cell-first 1000 4600 500""cell-first 1000 4600 500 3600 7" "cell-first a b c d" "AUTO 5" "auto 5 6" "auto" "" " " "cell-first 1 2 3 99999999999"; do
  r=$(mode_check "$bad" 2000 1500)
  if [ -n "$bad" ] || [ ! -e "$tmp/modecheck/mode" ]; then
    [ "$r" = invalid ] || [ -z "$bad" ] || fail "mode: '$bad' is refused" "got $r"
  fi
done
checks=$((checks + 1))
echo "ok   mode: every malformed line is refused"

# --- pure: the link history ----------------------------------------------------------------------
# hist_check CONTENT: prints "valid N" or "invalid"
hist_check() {
  UP_DIR="$tmp/histcheck"
  rm -rf "$UP_DIR"
  mkdir -p "$UP_DIR"
  if [ "$1" != @none ]; then printf '%b' "$1" >"$UP_DIR/links"; fi
  if uplink_load_links 2>/dev/null; then echo "valid ${#UP_HIST[@]}"; else echo invalid; fi
}
expect_eq "history: no file is a first run" "$(hist_check @none)" "valid 0"
expect_eq "history: what this tool writes is read" "$(hist_check 'ethernet up 0 3\nwifi down 2 0\ncell up 0 0\n')" "valid 3"
expect_eq "history: a partial file is fine" "$(hist_check 'wifi up 0 0\n')" "valid 1"
hist_bad=""
for line in 'ethernet garbage' 'ethernet up' 'ethernet up 0' 'ethernet maybe 0 0' 'ethernet up x 0' 'ethernet up 0 x' 'bluetooth up 0 0' 'ethernet up 0 0 0' 'ethernet up 100 0' 'ethernet up -1 0' 'ethernet  up 0 0' 'Ethernet up 0 0' ''; do
  r=$(hist_check "wifi up 0 0\n$line\n")
  [ "$r" = invalid ] || hist_bad="$hist_bad [$line]"
done
expect_eq "history: every malformed line makes the whole file unknown" "$hist_bad" ""
expect_eq "history: a repeated link is unknown" "$(hist_check 'wifi up 0 0\nwifi down 1 0\n')" invalid
UP_DIR="$tmp/histcheck"
rm -f "$UP_DIR/links"
printf "wifi up 0 0\n" >"$tmp/real_links"
ln -s "$tmp/real_links" "$UP_DIR/links"
expect_eq "history: a symlinked file is unknown" "$(uplink_load_links 2>/dev/null && echo valid || echo invalid)" invalid
rm -f "$UP_DIR/links"
UP_DIR=""

# --- the runner, against the fake world, through the real command line --------------------------
# Steady state: Wi-Fi is the only link; nothing to change, the modem profile is closed.
uscene gone ok ok
ucli run
expect_eq "run: a steady state exits 0" "$ucli_rc" 0
expect_contains "run: names the owner and the reason" "$ucli_out" "owner=wifi (wifi-healthy)"
expect_eq "run: a steady state changes nothing" "$(umods)" ""
expect_eq "run: wifi still owns" "$(uholders)" "wlan0"
expect_eq "run: no ledger is written when nothing is changed" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no
expect_contains "run: nmcli is read in the C locale, unescaped" "$(ucalls)" "nmcli LC_ALL=C --escape no -t -f DEVICE,TYPE,STATE device"
expect_contains "run: the modem interface is read in the C locale, unescaped" "$(ucalls)" "nmcli LC_ALL=C --escape no -g GENERAL.IP-IFACE device show cdc-wdm0"
: >"$UW/calls"
ucli run
expect_eq "run: a second steady pass still changes nothing" "$(umods)" ""
expect_eq "run: the probe is bound to the link's interface" "$(ucalls | grep -c '^ping wlan0 ')" 1
expect_eq "run: the modem is not pinged while it is closed" "$(ucalls | grep -c '^ping wwan0 ' || true)" 0
expect_eq "run: no gateway lookup exists any more" "$(ucalls | grep -c -e DHCP4 -e IP4.GATEWAY || true)" 0
expect_eq "run: the state directory is private" "$(stat -c %a "$UST")" 700
expect_eq "run: the ledger directory is private" "$(stat -c %a "$ULD")" 700
: >"$UW/calls"
out=$(LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 "$TOOL" uplink run 2>&1)
expect_contains "run: a non-C locale still reads nmcli in C" "$(ucalls | head -n 1)" "LC_ALL=C"

# Ethernet and Wi-Fi both healthy: neither is touched, both keep their own defaults and metrics.
uscene ok ok ok
ucli run
expect_contains "both healthy: ethernet is the owner" "$ucli_out" "owner=ethernet"
expect_eq "both healthy: nothing is changed at all" "$(umods)" ""
expect_eq "both healthy: both keep their own default routes" "$(uholders)" "eth0 wlan0"
expect_eq "both healthy: every link is judged by a real bound probe" "$(ucalls | grep -c -e '^ping eth0 ' -e '^ping wlan0 ')" 2
ucli status --json
expect_contains "both healthy: status names the lowest metric as the owner" "$ucli_out" '"owner":"ethernet"'

# The modem profile is not closed yet: the first run closes it at runtime; Wi-Fi is untouched.
uscene gone ok ok
uopen
ucli run
expect_eq "first run: cellular is closed, keeping its own metric" "$(umods)" "cdc-wdm0 yes 1100;"
expect_eq "first run: only Wi-Fi holds defaults afterwards" "$(uholders)" "wlan0"
expect_eq "first run: exits 0" "$ucli_rc" 0
expect_eq "first run: Wi-Fi was never touched" "$(ucalls | grep -c 'modify wlan0' || true)" 0
expect_eq "first run: closing is the safe direction, nothing is recorded" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no

# Failover opens only cellular; recovery closes it again. Ethernet and Wi-Fi are never touched.
uscene gone ok ok
ucli run # wifi ok
rm -f "$UW/ping_wlan0"
unow 15
ucli run
expect_eq "failover: one failed probe is tolerated (flapping)" "$(umods)" ""
echo ok >"$UW/ping_wlan0"
unow 30
ucli run
rm -f "$UW/ping_wlan0"
unow 45
ucli run
expect_eq "failover: a success in between reset the count, still nothing" "$(umods)" ""
unow 60
ucli run
expect_contains "failover: the second failure in a row fails over to cell" "$ucli_out" "owner=cell (failover)"
expect_eq "failover: only cellular was changed: opened, with a metric below both" "$(umods)" "cdc-wdm0 no 50;"
expect_eq "failover: Wi-Fi was never touched" "$(ucalls | grep -c 'modify wlan0' || true)" 0
expect_eq "failover: Wi-Fi keeps its own default route; cellular holds one too" "$(uholders)" "wlan0 wwan0"
expect_eq "failover: the ledger lists the modem" "$(uledger)" "cdc-wdm0"
expect_eq "failover: the ledger holds the previous (closed) values" "$(cut -d' ' -f2- "$ULD/ledger")" "cell 00000003-0000-0000-0000-000000000000 yes yes 1100 1100"
expect_eq "failover: the machine never had no default route" "$(ucalls | grep -c 'routes=0 ' || true)" 0
expect_eq "failover: exit 0" "$ucli_rc" 0
ucli status --json
expect_contains "failover: status names cellular as the owner (lowest metric)" "$ucli_out" '"owner":"cell"'
expect_contains "failover: and Wi-Fi as not healthy" "$ucli_out" '"wifi":{"state":"up","healthy":false}'
unow 75
: >"$UW/calls"
ucli run
expect_eq "failover: a steady cell owner changes nothing" "$(umods)" ""
expect_eq "failover: the modem is probed while it carries traffic" "$(ucalls | grep -c '^ping wwan0 ')" 1
expect_eq "failover: Wi-Fi is probed for real, bound to itself" "$(ucalls | grep -c '^ping wlan0 192.0.2.1')" 1
echo ok >"$UW/ping_wlan0"
unow 90
ucli run
expect_eq "recovery: one good probe is not enough" "$(uholders)" "wlan0 wwan0"
unow 105
ucli run
expect_contains "recovery: two good probes and Wi-Fi owns again" "$ucli_out" "owner=wifi"
expect_eq "recovery: cellular is put back exactly" "$(umods)" "cdc-wdm0 yes 1100;"
expect_eq "recovery: only Wi-Fi holds defaults" "$(uholders)" "wlan0"
expect_eq "recovery: the ledger is empty again" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no
expect_eq "recovery: Wi-Fi was never touched in all of it" "$(ucalls | grep -c 'modify wlan0' || true)" 0
expect_eq "recovery: never without a default route" "$(ucalls | grep -c 'routes=0 ' || true)" 0

# Hysteresis counts rounds: the wall clock jumping around changes nothing.
uscene gone ok ok
ucli run
rm -f "$UW/ping_wlan0"
export QUECTEL_UPLINK_NOW=$((T0 + 99999))
ucli run
export QUECTEL_UPLINK_NOW=$((T0 - 5000))
ucli run
expect_contains "clock jumps: two failures still fail over, whatever the wall clock says" "$ucli_out" "owner=cell"
unow 0

# The Wi-Fi radio goes off: the device becomes unavailable at once.
uscene gone ok ok
ucli run
sed -i 's/^wlan0:wifi:connected/wlan0:wifi:unavailable/' "$UW/devices"
rm -f "$UW/rt4_wlan0"
unow 15
ucli run
expect_contains "radio off: fails over to cell at the next pass" "$ucli_out" "owner=cell"
expect_eq "radio off: the modem holds the defaults" "$(uholders)" "wwan0"
expect_eq "radio off: only cellular was changed" "$(umods)" "cdc-wdm0 no 50;"
sed -i 's/^wlan0:wifi:unavailable/wlan0:wifi:connected/' "$UW/devices"
cp "$UW/tpl4_wlan0" "$UW/rt4_wlan0" # NetworkManager reconnects it with its own profile
unow 30
ucli run
expect_contains "radio on: one good pass is not enough" "$ucli_out" "owner=cell"
unow 45
ucli run
expect_contains "radio on: two good passes and Wi-Fi owns again" "$ucli_out" "owner=wifi"
expect_eq "radio on: only Wi-Fi holds the defaults" "$(uholders)" "wlan0"

# Both die: cellular opens; neither Ethernet nor Wi-Fi is touched.
uscene ok ok ok
ucli run
rm -f "$UW/ping_eth0" "$UW/ping_wlan0"
unow 15
ucli run
unow 30
ucli run
expect_contains "both dead: cell owns" "$ucli_out" "owner=cell"
expect_eq "both dead: the modem is the lowest metric, the others keep their routes" "$(uholders)" "eth0 wlan0 wwan0"
expect_eq "both dead: only cellular was changed" "$(umods)" "cdc-wdm0 no 50;"
echo ok >"$UW/ping_eth0"
unow 45
ucli run
unow 60
ucli run
expect_contains "ethernet back: it owns again, cellular is closed" "$ucli_out" "owner=ethernet"
expect_eq "ethernet back: cellular is closed again, nothing else was touched" "$(umods)" "cdc-wdm0 no 50;cdc-wdm0 yes 1100;"

# Ethernet dead but Wi-Fi fine: Wi-Fi owns, cellular stays closed.
uscene dead ok ok
ucli run
unow 15
ucli run
unow 30
ucli run
expect_contains "ethernet dead: wifi owns" "$ucli_out" "owner=wifi"
expect_eq "ethernet dead: nothing was changed" "$(umods)" ""

# A connected Wi-Fi with no default route at all cannot reach the internet: it fails.
uscene gone ok ok
rm -f "$UW/rt4_wlan0"
ucli run
expect_contains "no default route: the link counts as failed, not ok" "$ucli_out" "wifi=up/down(fail)"
unow 15
ucli run
expect_contains "no default route: two rounds and cellular opens" "$ucli_out" "owner=cell"

# Closing cellular is refused when the link that was healthy has lost its route by then.
uscene gone ok ok
ucli run
rm -f "$UW/ping_wlan0"
unow 15
ucli run
unow 30
ucli run
echo ok >"$UW/ping_wlan0"
echo 2 >"$UW/ping_dropsroute_wlan0"
unow 45
ucli run
unow 60
: >"$UW/calls"
ucli run
expect_eq "close guard: cellular is not closed when nothing else holds a default route" "$ucli_rc" 1
expect_contains "close guard: says why" "$ucli_out" "not closing cellular: nothing else holds a default route"
expect_eq "close guard: nothing was modified" "$(umods)" ""
expect_eq "close guard: cellular still holds its default" "$(uholders)" "wwan0"
rm -f "$UW/ping_dropsroute_wlan0"

# A profile with values that are not what nmcli prints is not trusted
uscene gone ok ok
printf 'maybe\nyes\n1100\n1100\n' >"$UW/prof_00000003-0000-0000-0000-000000000000"
rm -f "$UW/ping_wlan0"
ucli run
unow 15
ucli run
unow 30
ucli run
expect_eq "garbage profile values: cellular is not opened" "$ucli_rc" 1
expect_contains "garbage profile values: says why" "$ucli_out" "cannot read the current settings of cdc-wdm0"
expect_eq "garbage profile values: nothing modified" "$(umods)" ""

# IPv6: a link with only an IPv6 default route is judged on IPv6.
uscene gone ok ok
rm -f "$UW/rt4_wlan0" "$UW/ping_wlan0"
echo "default via fe80::1 dev wlan0 proto ra metric 1024 pref medium" >"$UW/tpl6_wlan0"
cp "$UW/tpl6_wlan0" "$UW/rt6_wlan0"
echo ok >"$UW/ping6_wlan0"
ucli run
expect_contains "ipv6 only: the link is healthy" "$ucli_out" "wifi=up/up(ok)"
expect_eq "ipv6 only: the probe used an IPv6 target" "$(ucalls | grep -c '^ping wlan0 2001:db8::1')" 1
expect_eq "ipv6 only: and no IPv4 target" "$(ucalls | grep -c '^ping wlan0 192.0.2.' || true)" 0
rm -f "$UW/ping6_wlan0"
unow 15
ucli run
unow 30
ucli run
expect_contains "ipv6 only: a dead IPv6 link does fail over" "$ucli_out" "owner=cell"
uscene gone ok ok
ucli run
expect_eq "ipv4 only: a link with only IPv4 is never probed on IPv6" "$(ucalls | grep -c '^ping wlan0 2001:db8' || true)" 0
uscene gone ok ok
cp "$UW/tpl4_wlan0" "$UW/rt4_wlan0"
echo "default via fe80::1 dev wlan0 proto ra metric 1024 pref medium" >"$UW/tpl6_wlan0"
cp "$UW/tpl6_wlan0" "$UW/rt6_wlan0"
rm -f "$UW/ping_wlan0"
echo ok >"$UW/ping6_wlan0"
ucli run
expect_contains "dual stack: IPv6 answering is enough, both families are tried" "$ucli_out" "wifi=up/up(ok)"
expect_eq "dual stack: the IPv4 targets were tried first" "$(ucalls | grep -c '^ping wlan0 192.0.2.1')" 1

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
expect_contains "deaf probe: one that was killed counts as a failure" "$ucli_t" "wifi=up/up(fail)"
rm -f "$UW/ping_deaf"

# a probe that handles TERM is sent TERM first (a graceful stop), then KILL if it lingers
uscene gone ok ok
: >"$UW/ping_term"
ucli_t=$(QUECTEL_UPLINK_DEADLINE=2 timeout 30 "$TOOL" uplink run 2>&1 || true)
expect_contains "term probe: TERM reaches a hung probe before KILL" "$(ucalls)" "ping got TERM"
expect_contains "term probe: a probe that had to be stopped counts as a failure" "$ucli_t" "wifi=up/up(fail)"

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

# A modem that is connected but has no IP interface yet is not usable.
uscene gone ok ok
: >"$UW/ipif_cdc-wdm0"
rm -f "$UW/ping_wlan0"
ucli run
unow 15
ucli run
unow 30
ucli run
expect_contains "modem without an interface: cell is not chosen" "$ucli_out" "owner=none"
expect_eq "modem without an interface: Wi-Fi keeps its routes" "$(uholders)" "wlan0"
expect_eq "modem without an interface: nothing changed" "$(umods)" ""
expect_eq "modem without an interface: the run still exits 0 (nothing to do)" "$ucli_rc" 0

# --- cell-first -----------------------------------------------------------------------------------------
# The emergency mode: cellular first, then Ethernet and Wi-Fi demoted, make-before-break.
uscene ok ok ok
ucli run
unow 100
ucli cell-first
expect_eq "cell-first: exit 0" "$ucli_rc" 0
expect_eq "cell-first: cellular is opened before anything is demoted" "$(umods)" "cdc-wdm0 no 50;eth0 yes -1;wlan0 yes -1;"
expect_eq "cell-first: the modem alone holds the defaults" "$(uholders)" "wwan0"
expect_eq "cell-first: the machine never had no default route" "$(ucalls | grep -c 'routes=0 ' || true)" 0
expect_eq "cell-first: every changed device is in the ledger" "$(uledger)" "cdc-wdm0 eth0 wlan0"
expect_eq "cell-first: the ledger keeps the previous values of Wi-Fi" "$(grep '^wlan0 ' "$ULD/ledger" | cut -d' ' -f2-)" "wifi 00000002-0000-0000-0000-000000000000 no no -1 -1"
expect_eq "cell-first: default expiry is two hours, on both clocks" "$(cat "$UST/mode")" "cell-first $((T0 + 100)) $((T0 + 100 + 7200)) $((M0 + 100)) 7200"
ucli status --json
expect_contains "cell-first: status shows the mode" "$ucli_out" '"mode":"cell-first"'
expect_contains "cell-first: status shows the owner" "$ucli_out" '"owner":"cell"'
expect_contains "cell-first: status shows when it ends" "$ucli_out" '"until":"2023-11-15T00:15:00Z"'
: >"$UW/calls"
unow 3600
ucli run
expect_eq "cell-first: a run in the middle changes nothing" "$(umods)" ""
expect_eq "cell-first: the demoted links are not probed" "$(ucalls | grep -c -e '^ping eth0 ' -e '^ping wlan0 ' || true)" 0
unow 7299
ucli run
expect_eq "cell-first: one second before the end it is still cell" "$(uholders)" "wwan0"
unow 7300
: >"$UW/calls"
ucli run
expect_contains "cell-first: says it expired" "$ucli_out" "cell-first expired"
expect_eq "cell-first: at the end Ethernet and Wi-Fi come back first, then cellular closes" "$(umods)" "eth0 no -1;wlan0 no -1;cdc-wdm0 yes 1100;"
expect_eq "cell-first: and ethernet owns again, Wi-Fi alongside" "$(uholders)" "eth0 wlan0"
expect_eq "cell-first: the ledger is empty again" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no
expect_eq "cell-first: the mode file is auto afterwards" "$(cut -d' ' -f1 "$UST/mode")" auto
expect_eq "cell-first: never without a default route on the way back" "$(ucalls | grep -c 'routes=0 ' || true)" 0
ucli status --json
expect_contains "cell-first expired: status shows auto" "$ucli_out" '"mode":"auto"'
expect_contains "cell-first expired: no end any more" "$ucli_out" '"until":null'

# going back with `uplink auto`: the same order
uscene gone ok ok
ucli run
unow 10
ucli cell-first --for 90m
expect_eq "cell-first --for 90m ends in 5400 s" "$(cut -d' ' -f3,5 "$UST/mode")" "$((T0 + 10 + 5400)) 5400"
: >"$UW/calls"
unow 20
ucli auto
expect_eq "auto: Wi-Fi first, then cellular closes" "$(umods)" "wlan0 no -1;cdc-wdm0 yes 1100;"
expect_eq "auto: Wi-Fi holds the defaults" "$(uholders)" "wlan0"
expect_eq "auto: the mode file says auto" "$(cut -d' ' -f1 "$UST/mode")" auto

# the clocks: a forward wall clock jump, a backward one, and the monotonic clock
uscene gone ok ok
ucli run
ucli cell-first --for 1h
export QUECTEL_UPLINK_NOW=$((T0 + 86400 * 5))
export QUECTEL_UPLINK_MONO=$((M0 + 100))
ucli run
expect_contains "clocks: a forward jump past the end expires it" "$ucli_out" "cell-first expired"
expect_eq "clocks: and Wi-Fi owns again" "$(uholders)" "wlan0"
uscene gone ok ok
ucli run
ucli cell-first --for 1h
export QUECTEL_UPLINK_NOW=$((T0 - 86400))
export QUECTEL_UPLINK_MONO=$((M0 + 100))
ucli run
expect_contains "clocks: a backward jump expires it at once" "$ucli_out" "cell-first expired"
expect_eq "clocks: and Wi-Fi owns again after a backward jump" "$(uholders)" "wlan0"
uscene gone ok ok
ucli run
ucli cell-first --for 1h
export QUECTEL_UPLINK_NOW=$((T0 + 100))
export QUECTEL_UPLINK_MONO=$((M0 + 3601))
ucli run
expect_contains "clocks: the monotonic clock expires it even if the wall clock lags" "$ucli_out" "cell-first expired"
uscene gone ok ok
ucli run
ucli cell-first --for 0
export QUECTEL_UPLINK_NOW=$((T0 - 86400))
export QUECTEL_UPLINK_MONO=$((M0 + 99999999))
ucli run
expect_eq "clocks: cell-first --for 0 never expires, whatever the clocks do" "$(uholders)" "wwan0"
unow 0
ucli auto
expect_eq "clocks: and auto still ends it" "$(uholders)" "wlan0"

# the bad --for values and usage errors
for bad in banana 5 -1 31d 1.5h 0h; do
  ucli cell-first --for "$bad"
  [ "$ucli_rc" -eq 1 ] || fail "cell-first --for $bad is refused" "rc=$ucli_rc"
done
checks=$((checks + 1))
echo "ok   cell-first refuses a bad --for"
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

# the modem drops while cell-first is active: the normal order comes back, restored first
uscene ok ok ok
ucli cell-first
sed -i 's/^cdc-wdm0:gsm:connected/cdc-wdm0:gsm:unavailable/' "$UW/devices"
rm -f "$UW/rt4_wwan0" "$UW/rt6_wwan0" "$UW/uuid_cdc-wdm0" # an unavailable device has no active profile
: >"$UW/calls"
unow 15
ucli run
expect_contains "modem lost: the normal order takes over" "$ucli_out" "owner=ethernet"
expect_eq "modem lost: Ethernet and Wi-Fi are restored" "$(uholders)" "eth0 wlan0"
expect_eq "modem lost: they were restored from the ledger" "$(umods)" "eth0 no -1;wlan0 no -1;"
expect_eq "modem lost: the stale modem line is dropped too" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no

# cellular's default disappears (or the modem loses its link) between two demotions: abort and restore
uscene ok ok ok
echo "eth0 yes" >"$UW/hook_after_modify"
ucli cell-first
expect_eq "mid-demotion loss: exit 1" "$ucli_rc" 1
expect_contains "mid-demotion loss: says what happened" "$ucli_out" "cellular lost its default route or its link"
expect_eq "mid-demotion loss: Wi-Fi was never demoted" "$(ucalls | grep -c 'modify wlan0' || true)" 0
expect_eq "mid-demotion loss: Ethernet came back before cellular was closed" "$(umods)" "cdc-wdm0 no 50;eth0 yes -1;eth0 no -1;cdc-wdm0 yes 1100;"
expect_eq "mid-demotion loss: Ethernet and Wi-Fi hold their defaults" "$(uholders)" "eth0 wlan0"
expect_eq "mid-demotion loss: the ledger is empty" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no
expect_eq "mid-demotion loss: no mode was left behind" "$([ -e "$UST/mode" ] && echo yes || echo no)" no
expect_eq "mid-demotion loss: never without a default route" "$(ucalls | grep -c 'routes=0 ' || true)" 0

# the same, but only the route goes (the link stays), and only the link goes (the route stays)
for variant in route link; do
  uscene ok ok ok
  echo "eth0 yes $variant" >"$UW/hook_after_modify"
  ucli cell-first
  expect_eq "mid-demotion $variant loss: exit 1" "$ucli_rc" 1
  expect_eq "mid-demotion $variant loss: Wi-Fi was never demoted" "$(ucalls | grep -c 'modify wlan0' || true)" 0
  expect_eq "mid-demotion $variant loss: Ethernet and Wi-Fi hold their defaults" "$(uholders)" "eth0 wlan0"
done

# cellular's route never shows after opening it: nothing is demoted, cellular goes back
uscene gone ok ok
echo "cdc-wdm0 no" >"$UW/hook_after_modify"
ucli cell-first
expect_eq "cell does not open: exit 1" "$ucli_rc" 1
expect_contains "cell does not open: says so" "$ucli_out" "cellular did not get a default route"
expect_eq "cell does not open: Wi-Fi was never touched" "$(ucalls | grep -c 'modify wlan0' || true)" 0
expect_eq "cell does not open: cellular is put back" "$(umods)" "cdc-wdm0 no 50;cdc-wdm0 yes 1100;"
expect_eq "cell does not open: Wi-Fi still holds the defaults" "$(uholders)" "wlan0"

# the modem has no link when the first demotion is due
uscene gone ok ok
touch "$UW/nolink_cdc-wdm0"
ucli cell-first
expect_eq "no link: exit 1" "$ucli_rc" 1
expect_eq "no link: Wi-Fi was never demoted" "$(ucalls | grep -c 'modify wlan0' || true)" 0
expect_eq "no link: Wi-Fi holds the defaults" "$(uholders)" "wlan0"

# a VPN's default route (an interface the manager does not manage) is never touched
uscene gone ok ok
echo "default dev tun0 scope link metric 50" >"$UW/rt4_tun0"
ucli cell-first
expect_eq "unmanaged: cell-first completes with a VPN default present" "$(uholders)" "tun0 wwan0"
expect_eq "unmanaged: the VPN is never touched" "$(ucalls | grep -c 'tun0' || true)" 0

# --- the ledger and self-healing -------------------------------------------------------------------------
# A kill in the middle of cell-first leaves the ledger and demoted links; the next run heals.
uscene ok ok ok
ucli cell-first
rm -rf "$UST" # a logout (the runtime directory is gone), or a kill: nothing ran the restore
expect_eq "kill: Ethernet and Wi-Fi are left demoted, cellular open" "$(uholders)" "wwan0"
: >"$UW/calls"
unow 30
ucli run
expect_eq "kill: the next run puts Ethernet and Wi-Fi back first" "$(umods)" "eth0 no -1;wlan0 no -1;"
expect_eq "kill: they hold their defaults again, cellular stays open until they prove themselves" "$(uholders)" "eth0 wlan0 wwan0"
unow 45
ucli run
unow 60
ucli run
expect_eq "kill: after two good rounds cellular is closed from the ledger" "$(umods)" "eth0 no -1;wlan0 no -1;cdc-wdm0 yes 1100;"
expect_eq "kill: only Ethernet and Wi-Fi hold defaults" "$(uholders)" "eth0 wlan0"
expect_eq "kill: the ledger is empty" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no
expect_eq "kill: never without a default route" "$(ucalls | grep -c 'routes=0 ' || true)" 0

# A kill while cellular is open for a failover, Wi-Fi still dead: cellular stays open (history gone)
uscene gone ok ok
ucli run
rm -f "$UW/ping_wlan0"
unow 15
ucli run
unow 30
ucli run
rm -rf "$UST"
unow 45
ucli run
expect_contains "kill in failover: with the history gone and Wi-Fi still dead, cellular stays" "$ucli_out" "owner=cell"
expect_eq "kill in failover: the ledger still lists the modem" "$(uledger)" "cdc-wdm0"
echo ok >"$UW/ping_wlan0"
unow 60
ucli run
unow 75
ucli run
expect_contains "kill in failover: Wi-Fi back, it has to prove itself twice, then cellular closes" "$ucli_out" "owner=wifi"
expect_eq "kill in failover: closed again" "$(uholders)" "wlan0"

# A re-activated device already lost its runtime change: the ledger line is dropped, not applied
uscene ok ok ok
ucli cell-first
# NetworkManager re-activates Wi-Fi: a new profile activation (new UUID), runtime change gone, defaults back
echo 0000000a-0000-0000-0000-000000000000 >"$UW/uuid_wlan0"
printf 'no\nno\n-1\n-1\n' >"$UW/prof_0000000a-0000-0000-0000-000000000000"
cp "$UW/tpl4_wlan0" "$UW/rt4_wlan0"
: >"$UW/calls"
unow 30
ucli run
expect_eq "re-activated: Wi-Fi is demoted again (a fresh ledger line for the new activation)" "$(umods)" "wlan0 yes -1;"
expect_eq "re-activated: only cellular holds defaults" "$(uholders)" "wwan0"
expect_contains "re-activated: the ledger holds the new activation" "$(grep '^wlan0 ' "$ULD/ledger")" "0000000a-0000-0000-0000-000000000000"
ucli auto
expect_eq "re-activated: auto puts everything back" "$(uholders)" "eth0 wlan0"
uscene ok ok ok
ucli cell-first
echo 0000000b-0000-0000-0000-000000000000 >"$UW/uuid_wlan0"
printf 'no\nno\n-1\n-1\n' >"$UW/prof_0000000b-0000-0000-0000-000000000000"
cp "$UW/tpl4_wlan0" "$UW/rt4_wlan0"
rm -f "$UW/rt4_eth0"
ucli restore
expect_eq "restore: a re-activated device is dropped, not modified" "$(ucalls | grep -c 'modify wlan0 .* no ' || true)" 0
expect_contains "restore: says it dropped it" "$ucli_out" "dropped wlan0"

# uplink restore, by hand
uscene ok ok ok
ucli restore
expect_eq "restore: an empty ledger is not an error" "$ucli_rc" 0
expect_contains "restore: says so" "$ucli_out" "nothing to restore"
ucli cell-first
: >"$UW/calls"
ucli restore
expect_eq "restore: exit 0" "$ucli_rc" 0
expect_eq "restore: Ethernet and Wi-Fi first, then cellular" "$(umods)" "eth0 no -1;wlan0 no -1;cdc-wdm0 yes 1100;"
expect_contains "restore: says what it restored" "$ucli_out" "restored cdc-wdm0: never-default yes/yes, route-metric 1100/1100"
expect_eq "restore: the ledger is empty" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no
# cellular is the only way out: it is not closed
uscene gone ok ok
ucli run
rm -f "$UW/ping_wlan0"
unow 15
ucli run
unow 30
ucli run
sed -i 's/^wlan0:wifi:connected/wlan0:wifi:unavailable/' "$UW/devices"
rm -f "$UW/rt4_wlan0"
: >"$UW/calls"
ucli restore
expect_eq "restore: cellular is the only default, so it is not closed: exit 1" "$ucli_rc" 1
expect_contains "restore: says why" "$ucli_out" "NOT restored cdc-wdm0"
expect_eq "restore: nothing was modified" "$(umods)" ""
expect_eq "restore: the ledger keeps the line" "$(uledger)" "cdc-wdm0"

# A malformed ledger: nothing is changed, and it says what to do by hand
uscene gone ok ok
mkdir -p "$ULD"
chmod 700 "$ULD"
for bad in "garbage" "cdc-wdm0 cell 00000003 yes yes 1100" "cdc-wdm0 modem 00000003-0000-0000-0000-000000000000 yes yes 1100 1100" "cdc-wdm0 cell 00000003-0000-0000-0000-000000000000 maybe yes 1100 1100" "cdc-wdm0 cell 00000003-0000-0000-0000-000000000000 yes yes 1100 x" "cdc-wdm0;reboot cell 00000003-0000-0000-0000-000000000000 yes yes 1100 1100"; do
  printf '%s\n' "$bad" >"$ULD/ledger"
  : >"$UW/calls"
  ucli run
  [ "$ucli_rc" -eq 1 ] && [ -z "$(umods)" ] || fail "a malformed ledger line is refused: $bad" "rc=$ucli_rc"
done
checks=$((checks + 1))
echo "ok   every malformed ledger line makes a run change nothing and fail"
expect_contains "malformed ledger: says to put things back by hand" "$ucli_out" "nmcli device reapply"
ucli restore
expect_eq "malformed ledger: restore refuses too" "$ucli_rc" 1
# two lines for one device are unknown too
printf '%s\n%s\n' "cdc-wdm0 cell 00000003-0000-0000-0000-000000000000 yes yes 1100 1100" "cdc-wdm0 cell 00000003-0000-0000-0000-000000000000 yes yes 1100 1100" >"$ULD/ledger"
: >"$UW/calls"
ucli run
expect_eq "a ledger that repeats a device: exit 1" "$ucli_rc" 1
expect_contains "a ledger that repeats a device: says so" "$ucli_out" "repeats cdc-wdm0"
# a symlinked ledger file is not followed, even to valid content
rm -f "$ULD/ledger"
printf '%s\n' "cdc-wdm0 cell 00000003-0000-0000-0000-000000000000 yes yes 1100 1100" >"$tmp/real_ledger"
ln -s "$tmp/real_ledger" "$ULD/ledger"
ucli run
expect_eq "a symlinked ledger file: exit 1" "$ucli_rc" 1
expect_contains "a symlinked ledger file: says it is not a plain file" "$ucli_out" "is not a plain file"
expect_eq "a symlinked ledger file: nothing modified" "$(umods)" ""
rm -f "$ULD/ledger"

# --- fail safe ----------------------------------------------------------------------------------
# Every failure below must leave the routes exactly as they were and exit non-zero.
# fail_start: Wi-Fi has failed once; the next run is the second failure, so it wants cellular
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

# the profile cannot be read: cellular is not changed blind
fail_start
touch "$UW/fail_cur"
ucli run
expect_eq "profile unreadable: exit 1" "$ucli_rc" 1
expect_contains "profile unreadable: says so" "$ucli_out" "cannot read the current settings of cdc-wdm0"
expect_eq "profile unreadable: nothing modified" "$(umods)" ""
rm -f "$UW/fail_cur"

# cellular cannot be opened
fail_start
touch "$UW/fail_modify_cdc-wdm0"
ucli run
expect_eq "open fails: exit 1" "$ucli_rc" 1
expect_contains "open fails: says why" "$ucli_out" "nmcli could not open cdc-wdm0"
expect_eq "open fails: Wi-Fi keeps its routes" "$(uholders)" "wlan0"
rm -f "$UW/fail_modify_cdc-wdm0"

# nmcli says yes and the table does not change: put back
fail_start
touch "$UW/noop_modify"
ucli run
expect_eq "open is a no-op: exit 1" "$ucli_rc" 1
expect_contains "open is a no-op: says cellular got no route" "$ucli_out" "cellular did not get a default route"
expect_eq "open is a no-op: Wi-Fi keeps its routes" "$(uholders)" "wlan0"
expect_eq "open is a no-op: it is put back" "$(umods)" "cdc-wdm0 no 50;cdc-wdm0 yes 1100;"
expect_eq "open is a no-op: the ledger is empty again" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no
rm -f "$UW/noop_modify"

# an interface whose name only starts like cellular's is not cellular
fail_start
touch "$UW/noop_modify"
echo "default dev wwan00 scope link metric 50" >"$UW/rt4_wwan00"
ucli run
expect_eq "name prefix: a default route on wwan00 is not one on wwan0" "$ucli_rc" 1
expect_contains "name prefix: so cellular is still found not open" "$ucli_out" "cellular did not get a default route"
rm -f "$UW/noop_modify"

# the first attempt to open cellular fails, the put-back works: the ledger is empty again
fail_start
cat >"$ubin/nmcli.failopen" <<'FAKE'
#!/usr/bin/env bash
# the first attempt to open the modem fails
if [[ "$*" == *"device modify cdc-wdm0 ipv4.never-default no"* ]] && [ ! -f "$UW/failed_once" ]; then
  touch "$UW/failed_once"
  echo "nmcli LC_ALL=${LC_ALL:-unset} $*" >>"$UW/calls"
  echo "Error: no" >&2
  exit 1
fi
exec "$UBIN/nmcli" "$@"
FAKE
chmod +x "$ubin/nmcli.failopen"
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_NMCLI="$ubin/nmcli.failopen" "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "failed open: exit 1" "$ucli_rc" 1
expect_eq "failed open: what was recorded is taken back out of the ledger" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no

# closing cellular is not taken on trust: if its route is still there afterwards, the run fails
fail_start
ucli run >/dev/null # cellular is open now
echo ok >"$UW/ping_wlan0"
unow 45
ucli run >/dev/null
cat >"$ubin/nmcli.stayopen" <<'FAKE'
#!/usr/bin/env bash
# closing the modem is silently lost
if [[ "$*" == *"device modify cdc-wdm0 ipv4.never-default yes"* ]]; then
  echo "nmcli LC_ALL=${LC_ALL:-unset} $*" >>"$UW/calls"
  exit 0
fi
exec "$UBIN/nmcli" "$@"
FAKE
chmod +x "$ubin/nmcli.stayopen"
unow 60
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_NMCLI="$ubin/nmcli.stayopen" "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "close is lost: exit 1" "$ucli_rc" 1
expect_contains "close is lost: says the route is still there" "$ucli_out" "still holds a default route after closing it"

# one demotion in cell-first fails: everything goes back
uscene ok ok ok
touch "$UW/fail_modify_wlan0"
ucli cell-first
expect_eq "demotion fails: exit 1" "$ucli_rc" 1
expect_contains "demotion fails: says why" "$ucli_out" "nmcli could not demote wlan0"
expect_eq "demotion fails: Ethernet and Wi-Fi hold their defaults" "$(uholders)" "eth0 wlan0"
expect_eq "demotion fails: never without a default route" "$(ucalls | grep -c 'routes=0 ' || true)" 0
rm -f "$UW/fail_modify_wlan0"

# one lost demotion: the retry fixes it
uscene ok ok ok
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
ucli_out=$(QUECTEL_UPLINK_NMCLI="$ubin/nmcli.once" "$TOOL" uplink cell-first 2>&1) || ucli_rc=$?
expect_eq "lost demotion: the retry succeeds, exit 0" "$ucli_rc" 0
expect_contains "lost demotion: says it retries once" "$ucli_out" "retrying once"
expect_eq "lost demotion: the modem owns" "$(uholders)" "wwan0"

# the table never gets right even after the retry: reverted
uscene ok ok ok
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
ucli_out=$(QUECTEL_UPLINK_NMCLI="$ubin/nmcli.stuck" "$TOOL" uplink cell-first 2>&1) || ucli_rc=$?
expect_eq "stuck table: exit 1" "$ucli_rc" 1
expect_contains "stuck table: says it did not settle" "$ucli_out" "did not reach the wanted state"
expect_eq "stuck table: reverted, Ethernet and Wi-Fi hold their defaults" "$(uholders)" "eth0 wlan0"

# the revert itself cannot restore a link: cellular is left open rather than leave nothing
uscene ok ok ok
cat >"$ubin/nmcli.nofix" <<'FAKE'
#!/usr/bin/env bash
# demoting works; putting Ethernet and Wi-Fi back never does
if [[ "$*" == *"device modify eth0 ipv4.never-default no"* ]] || [[ "$*" == *"device modify wlan0 ipv4.never-default no"* ]]; then
  echo "nmcli LC_ALL=${LC_ALL:-unset} $*" >>"$UW/calls"
  echo "Error: no" >&2
  exit 1
fi
exec "$UBIN/nmcli" "$@"
FAKE
chmod +x "$ubin/nmcli.nofix"
echo "wlan0 yes" >"$UW/hook_after_modify"
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_NMCLI="$ubin/nmcli.nofix" "$TOOL" uplink cell-first 2>&1) || ucli_rc=$?
expect_eq "revert cannot restore: exit 1" "$ucli_rc" 1
expect_contains "revert cannot restore: says it leaves cellular open" "$ucli_out" "leaving cellular open"

# Bad configuration and missing tools change nothing
fail_start
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_NMCLI=/nonexistent/nmcli "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "missing nmcli: exit 1" "$ucli_rc" 1
expect_eq "missing nmcli: nothing was called" "$(ucalls)" ""
expect_contains "missing nmcli: names the tool and the reason" "$ucli_out" "nmcli is /nonexistent/nmcli, which is not an executable file"
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_IP=relative/ip "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "a relative tool path is refused" "$ucli_rc" 1
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_FAILS=0 "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "a setting out of range is refused" "$ucli_rc" 1
expect_contains "a setting out of range is named" "$ucli_out" "QUECTEL_UPLINK_FAILS"
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_CELL_METRIC=100 "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "a cellular metric that would not beat Ethernet is refused" "$ucli_rc" 1
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_TARGETS='1.1.1.1;reboot' "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "a target with shell text is refused" "$ucli_rc" 1
ucli_rc=0
ucli_out=$(QUECTEL_UPLINK_OKS='1;reboot' "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "a setting with shell text is refused" "$ucli_rc" 1
expect_eq "bad settings: nothing was called" "$(umods)" ""
ucli_rc=0
ucli_out=$(XDG_RUNTIME_DIR="" QUECTEL_UPLINK_STATE_DIR="" "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "no runtime directory: exit 1, nothing changed" "$ucli_rc" 1
expect_eq "no runtime directory: nothing was modified" "$(umods)" ""
ucli_rc=0
ucli_out=$(HOME="" XDG_STATE_HOME="" QUECTEL_UPLINK_LEDGER_DIR="" "$TOOL" uplink run 2>&1) || ucli_rc=$?
expect_eq "no place for the ledger: exit 1, nothing changed" "$ucli_rc" 1

# --- the state directories: 0700, ours, no symlinks -----------------------------------------------------------
fail_start
rm -rf "$UST"
mkdir -p "$tmp/elsewhere"
chmod 700 "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$UST"
ucli run
expect_eq "a symlinked state directory is refused" "$ucli_rc" 1
expect_contains "a symlinked state directory: and says why" "$ucli_out" "is a symlink"
expect_eq "a symlinked state directory: nothing written there" "$(find "$tmp/elsewhere" -mindepth 1 | wc -l)" 0
rm -f "$UST"
mkdir -p "$UST"
chmod 755 "$UST"
ucli run
expect_eq "a state directory with mode 755 is refused" "$ucli_rc" 1
expect_contains "a state directory with mode 755: says so" "$ucli_out" "has mode 755"
chmod 777 "$UST"
ucli run
expect_eq "a state directory with mode 777 is refused" "$ucli_rc" 1
chmod 750 "$UST"
ucli run
expect_eq "a state directory with mode 750 is refused" "$ucli_rc" 1
expect_eq "a refused state directory: nothing modified" "$(umods)" ""
chmod 700 "$UST"
mkdir -p "$ULD"
chmod 755 "$ULD"
ucli run
expect_eq "a ledger directory with mode 755 is refused" "$ucli_rc" 1
expect_contains "a ledger directory with mode 755: says so" "$ucli_out" "has mode 755"
chmod 770 "$ULD"
ucli run
expect_eq "a ledger directory with mode 770 is refused" "$ucli_rc" 1
chmod 700 "$ULD"
ucli run
expect_eq "mode 700 is accepted" "$([ "$ucli_rc" -eq 0 ] || [ "$ucli_rc" -eq 1 ] && echo fine)" fine
expect_eq "mode 700: not refused for its mode" "$(printf '%s' "$ucli_out" | grep -c 'has mode' || true)" 0
rm -rf "$ULD"
ln -s "$tmp/elsewhere" "$ULD"
ucli run
expect_eq "a symlinked ledger directory is refused" "$ucli_rc" 1
rm -f "$ULD"
ucli status
expect_eq "status does not create or check the state directories" "$([ -e "$ULD" ] && echo yes || echo no)" no

# the lock file is never followed through a symlink
fail_start
echo "do not truncate me" >"$tmp/lock_target"
rm -f "$UST/lock"
ln -s "$tmp/lock_target" "$UST/lock"
ucli run
expect_eq "a symlinked lock file: the run is refused (exit 1, not a silent skip)" "$ucli_rc" 1
expect_contains "a symlinked lock file: says so" "$ucli_out" "is a symlink"
expect_eq "a symlinked lock file: its target is intact" "$(cat "$tmp/lock_target")" "do not truncate me"
expect_eq "a symlinked lock file: nothing was changed" "$(umods)" ""
ucli auto
expect_eq "a symlinked lock file: auto is refused too" "$ucli_rc" 1
expect_eq "a symlinked lock file: its target is still intact" "$(cat "$tmp/lock_target")" "do not truncate me"
rm -f "$UST/lock"

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
for bad in "" "auto" "auto x" "cell-first 1" "cell-first 1 2 3" "cell-first 1 2 3 4 5" "AUTO 5" "auto 5 6" "auto 99999999999999"; do
  printf '%s\n' "$bad" >"$UST/mode"
  ucli run
  [ "$ucli_rc" -eq 1 ] || fail "malformed mode file '$bad' is refused" "rc=$ucli_rc"
done
checks=$((checks + 1))
echo "ok   every malformed mode line is refused"
rm -f "$UST/mode"
echo "auto 5" >"$tmp/real_mode"
ln -s "$tmp/real_mode" "$UST/mode"
ucli run
expect_eq "a symlinked mode file is refused" "$ucli_rc" 1
rm -f "$UST/mode"
ucli auto
expect_eq "uplink auto repairs a bad mode state: exit 0" "$ucli_rc" 0

# A malformed link history: unknown, so nothing changes and the run fails (never read as down)
uscene gone ok ok
ucli run
printf 'wifi garbage\n' >"$UST/links"
rm -f "$UW/ping_wlan0"
: >"$UW/calls"
ucli run
expect_eq "malformed history: exit 1" "$ucli_rc" 1
expect_contains "malformed history: says why" "$ucli_out" "link history"
expect_eq "malformed history: nothing modified" "$(umods)" ""
expect_eq "malformed history: no probe, no route read changed anything" "$(uholders)" "wlan0"
ucli status --json
expect_eq "malformed history: status exits 1" "$ucli_rc" 1
printf 'ethernet up 0 0\nwifi up 0 0\ncell up 0 0\nextra\n' >"$UST/links"
ucli run
expect_eq "malformed history: an extra line is unknown too" "$ucli_rc" 1
rm -f "$UST/links"
printf 'ethernet up 0 0\nwifi up 0 0\ncell up 0 0\n' >"$tmp/real_links2"
ln -s "$tmp/real_links2" "$UST/links"
ucli run
expect_eq "a symlinked link history is not followed, even to valid content" "$ucli_rc" 1
expect_contains "a symlinked link history: says it is not a plain file" "$ucli_out" "is not a plain file"
rm -f "$UST/links"

# a lock file that is not a plain file (here a FIFO with a reader, so opening it does not hang) is refused
fail_start
rm -f "$UST/lock"
mkfifo "$UST/lock"
cat "$UST/lock" >/dev/null &
fifo_reader=$!
ucli_rc=0
ucli_out=$(timeout 20 "$TOOL" uplink run 2>&1) || ucli_rc=$?
kill "$fifo_reader" 2>/dev/null || true
wait "$fifo_reader" 2>/dev/null || true
expect_eq "a lock file that is not a plain file: exit 1" "$ucli_rc" 1
expect_contains "a lock file that is not a plain file: says so" "$ucli_out" "is not a plain file"
expect_eq "a lock file that is not a plain file: nothing modified" "$(umods)" ""
rm -f "$UST/lock"

# A second instance: the timer run waits one second for the lock, then skips and exits 0
fail_start
mkdir -p "$UST"
(
  exec 8>>"$UST/lock"
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
expect_eq "dry run: no ledger written" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no
# a dry run does not heal from the ledger either
uscene ok ok ok
ucli cell-first
rm -f "$UST/mode"
: >"$UW/calls"
ucli run --dry-run
expect_eq "dry run: does not put back what the ledger lists" "$(umods)" ""
expect_eq "dry run: leaves the ledger alone" "$(uledger)" "cdc-wdm0 eth0 wlan0"

# --- round 2: a read error is not proof; multi-modem rollback; the mode file; temp files ------------------------
# usecond: a second modem, connected, closed, with its own profile and routes
usecond() {
  echo "cdc-wdm1:gsm:connected" >>"$UW/devices"
  echo wwan1 >"$UW/ipif_cdc-wdm1"
  echo "default dev wwan1 proto static metric 1100" >"$UW/tpl4_wwan1"
  echo "default dev wwan1 proto static metric 1100 pref medium" >"$UW/tpl6_wwan1"
  echo 00000004-0000-0000-0000-000000000000 >"$UW/uuid_cdc-wdm1"
  printf 'yes\nyes\n1100\n1100\n' >"$UW/prof_00000004-0000-0000-0000-000000000000"
  echo ok >"$UW/ping_wwan1"
}

# H1: a profile read that fails during a restore keeps every ledger line
for seam in fail_cur fail_devs; do
  uscene ok ok ok
  ucli cell-first
  expect_eq "read error ($seam): setup, three lines in the ledger" "$(uledger)" "cdc-wdm0 eth0 wlan0"
  touch "$UW/$seam"
  : >"$UW/calls"
  ucli restore
  expect_eq "read error ($seam): restore exits non-zero" "$ucli_rc" 1
  expect_eq "read error ($seam): every ledger line is kept" "$(uledger)" "cdc-wdm0 eth0 wlan0"
  expect_eq "read error ($seam): nothing is modified" "$(umods)" ""
  expect_eq "read error ($seam): nothing is reported as restored or dropped" "$(printf '%s' "$ucli_out" | grep -c -e '^restored' -e '^dropped' || true)" 0
  expect_eq "read error ($seam): the links stay as they were" "$(uholders)" "wwan0"
  rm -f "$UW/$seam"
  : >"$UW/calls"
  ucli restore
  expect_eq "read error ($seam): a later restore succeeds" "$ucli_rc" 0
  expect_eq "read error ($seam): and puts everything back, Ethernet and Wi-Fi first" "$(umods)" "eth0 no -1;wlan0 no -1;cdc-wdm0 yes 1100;"
  expect_eq "read error ($seam): the ledger is empty" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no
done
# the same on the self-heal path of a run
uscene ok ok ok
ucli cell-first
rm -f "$UST/mode"
touch "$UW/fail_cur"
: >"$UW/calls"
ucli run
expect_eq "read error: a run does not heal on a guess: exit 1" "$ucli_rc" 1
expect_eq "read error: and keeps the ledger" "$(uledger)" "cdc-wdm0 eth0 wlan0"
expect_eq "read error: and modifies nothing" "$(umods)" ""
rm -f "$UW/fail_cur"
ucli run
expect_eq "read error: the next run heals" "$(uholders)" "eth0 wlan0"
# an unexpected UUID text is not "re-activated" either
uscene ok ok ok
ucli cell-first
echo "not a uuid!" >"$UW/uuid_wlan0"
ucli restore
expect_eq "unexpected profile text: that line is kept, exit 1" "$ucli_rc" 1
expect_contains "unexpected profile text: the ledger still lists Wi-Fi" "$(uledger)" "wlan0"
# and what IS proof still drops the line: a device that is not listed at all
uscene ok ok ok
ucli cell-first
sed -i '/^wlan0:/d' "$UW/devices"
rm -f "$UW/rt4_wlan0"
ucli restore
expect_contains "device not listed: dropped as gone" "$ucli_out" "dropped wlan0: gone"
expect_eq "device not listed: the others are restored" "$(uholders)" "eth0"

# M1: a second modem fails to open: the first is put back
uscene ok ok ok
usecond
touch "$UW/fail_modify_cdc-wdm1"
ucli cell-first
expect_eq "two modems, the second fails (cell-first): exit 1" "$ucli_rc" 1
expect_contains "two modems, the second fails (cell-first): the cell-first revert path ran" "$ucli_out" "reverting: restoring Ethernet and Wi-Fi first"
expect_eq "two modems, the second fails (cell-first): the first is closed again" "$(uholders)" "eth0 wlan0"
expect_eq "two modems, the second fails (cell-first): only the second (its put-back fails too, it never changed) is left in the ledger" "$(uledger)" "cdc-wdm1"
expect_eq "two modems, the second fails (cell-first): Ethernet and Wi-Fi were never touched" "$(ucalls | grep -c -e 'modify eth0' -e 'modify wlan0' || true)" 0
expect_eq "two modems, the second fails (cell-first): the first was opened, then put back" "$(umods | cut -d';' -f1,3)" "cdc-wdm0 no 50;cdc-wdm0 yes 1100"
uscene gone ok ok
usecond
ucli run
rm -f "$UW/ping_wlan0"
touch "$UW/fail_modify_cdc-wdm1"
unow 15
ucli run
unow 30
ucli run
expect_eq "two modems, the second fails (failover): exit 1" "$ucli_rc" 1
expect_eq "two modems, the second fails (failover): the first is closed again" "$(uholders)" "wlan0"
expect_eq "two modems, the second fails (failover): only the second (it never changed) is left in the ledger" "$(uledger)" "cdc-wdm1"
# the second modem's profile cannot be read (no active connection): the first is put back
uscene gone ok ok
usecond
rm -f "$UW/uuid_cdc-wdm1"
rm -f "$UW/ping_wlan0"
ucli run
unow 15
ucli run
unow 30
ucli run
expect_eq "two modems, the second unreadable: exit 1" "$ucli_rc" 1
expect_eq "two modems, the second unreadable: the first is closed again" "$(uholders)" "wlan0"
expect_eq "two modems, the second unreadable: the ledger is empty" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no
# both open fine: both are recorded and both close together
uscene gone ok ok
usecond
rm -f "$UW/ping_wlan0"
ucli run
unow 15
ucli run
unow 30
ucli run
expect_eq "two modems: both are opened" "$(uholders)" "wlan0 wwan0 wwan1"
expect_eq "two modems: both are in the ledger" "$(uledger)" "cdc-wdm0 cdc-wdm1"
ucli restore
expect_eq "two modems: restore closes both" "$(uholders)" "wlan0"

# M2: the mode file is exactly one line, with consistent fields
fail_start
mkdir -p "$UST"
for bad in "auto 1\ngarbage\n" "auto 1\n\n" "auto 1\n \n" "cell-first 1000 4600 500 3600\nauto 5\n" "cell-first 1000 0 500 7200\n" "cell-first 1000 4600 500 0\n"; do
  printf '%b' "$bad" >"$UST/mode"
  : >"$UW/calls"
  ucli run
  [ "$ucli_rc" -eq 1 ] && [ -z "$(umods)" ] || fail "mode file '$bad' is refused and changes nothing" "rc=$ucli_rc"
done
checks=$((checks + 1))
echo "ok   a mode file with trailing lines or inconsistent fields is refused and changes nothing"
printf 'cell-first 1000 0 500 7200\n' >"$UST/mode"
ucli status --json
expect_eq "inconsistent mode (no end, a duration): status exits 1" "$ucli_rc" 1
printf 'auto 1\n' >"$UST/mode"
ucli run
expect_eq "a plain one-line mode is still fine" "$ucli_rc" 0
printf 'cell-first 1000 0 500 0\n' >"$UST/mode"
ucli status --json
expect_eq "no end and no duration is still fine" "$ucli_rc" 0
rm -f "$UST/mode"
expect_eq "mode: trailing lines (pure)" "$(mode_check 'auto 1\ngarbage' 1000 500)" invalid
expect_eq "mode: an empty trailing line (pure)" "$(mode_check 'auto 1\n' 1000 500)" invalid
expect_eq "mode: no end with a duration (pure)" "$(mode_check 'cell-first 1000 0 500 7200' 1000 500)" invalid
expect_eq "mode: an end with no duration (pure)" "$(mode_check 'cell-first 1000 4600 500 0' 1000 500)" invalid

# L1: the .new temp files are never written through
for target in mode links; do
  uscene gone ok ok
  ucli run
  echo "keep me" >"$tmp/new_target"
  rm -f "$UST/$target.new"
  ln -s "$tmp/new_target" "$UST/$target.new"
  if [ "$target" = mode ]; then ucli auto; else ucli run; fi
  expect_eq "$target.new is a symlink: the target is untouched" "$(cat "$tmp/new_target")" "keep me"
  expect_contains "$target.new is a symlink: says it will not write through it" "$ucli_out" "refusing to write through it"
  rm -f "$UST/$target.new"
done
fail_start
echo "keep me" >"$tmp/new_target"
ln -s "$tmp/new_target" "$ULD/ledger.new"
ucli run
expect_eq "ledger.new is a symlink: the target is untouched" "$(cat "$tmp/new_target")" "keep me"
expect_eq "ledger.new is a symlink: nothing is changed without a ledger" "$(umods)" ""
expect_eq "ledger.new is a symlink: the run fails" "$ucli_rc" 1
rm -f "$ULD/ledger.new"
mkdir "$ULD/ledger.new"
ucli run
expect_eq "ledger.new is a directory: refused, nothing modified" "$(umods)" ""
expect_contains "ledger.new is a directory: says it is not a plain file" "$ucli_out" "is not a plain file"
rmdir "$ULD/ledger.new"
# a stale plain file under that name is replaced
echo "stale" >"$ULD/ledger.new"
ucli run
expect_eq "a stale plain ledger.new is replaced, the run works" "$ucli_rc" 0
expect_eq "a stale plain ledger.new: gone afterwards" "$([ -e "$ULD/ledger.new" ] && echo yes || echo no)" no
expect_eq "a stale plain ledger.new: the ledger is written" "$(uledger)" "cdc-wdm0"

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
sed -i 's/^eth0:ethernet:connected/eth0:ethernet:unavailable/' "$UW/devices"
rm -f "$UW/rt4_eth0"
ucli status --json
expect_contains "status: an ethernet unplugged after a good run is down, not healthy" "$ucli_out" '"ethernet":{"state":"down","healthy":false}'
expect_contains "status: and Wi-Fi is the owner" "$ucli_out" '"owner":"wifi"'
uscene gone ok ok
ucli status --json
expect_contains "status: an unplugged ethernet is down, not healthy" "$ucli_out" '"ethernet":{"state":"down","healthy":false}'
uscene none none none
ucli status --json
expect_contains "status: no links at all: owner none" "$ucli_out" '"owner":"none"'
expect_contains "status: no links at all: everything absent" "$ucli_out" '"cell":{"state":"absent","healthy":false}'
# an IPv6-only owner is still the owner
uscene gone ok ok
rm -f "$UW/rt4_wlan0"
echo "default via fe80::1 dev wlan0 proto ra metric 1024 pref medium" >"$UW/rt6_wlan0"
ucli status --json
expect_contains "status: an IPv6-only owner is found" "$ucli_out" '"owner":"wifi"'
# status is read only, and fails closed
uscene gone ok ok
ucli run
rm -rf "$UST" "$ULD"
: >"$UW/calls"
ucli status --json
expect_eq "status: makes no change" "$(umods)" ""
expect_eq "status: creates no state" "$([ -e "$UST" ] || [ -e "$ULD" ] && echo yes || echo no)" no
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

# The default state directories: under XDG_RUNTIME_DIR and XDG_STATE_HOME
uscene gone ok ok
mkdir -p "$tmp/xdg" "$tmp/xdgstate"
chmod 0700 "$tmp/xdg" "$tmp/xdgstate"
ucli_rc=0
ucli_out=$(env -u QUECTEL_UPLINK_STATE_DIR -u QUECTEL_UPLINK_LEDGER_DIR XDG_RUNTIME_DIR="$tmp/xdg" XDG_STATE_HOME="$tmp/xdgstate" "$TOOL" uplink auto 2>&1) || ucli_rc=$?
expect_eq "default state directories: exit 0" "$ucli_rc" 0
expect_eq "default state directory: \$XDG_RUNTIME_DIR/quectel-usbnet" "$(cut -d' ' -f1 "$tmp/xdg/quectel-usbnet/mode")" auto
expect_eq "default ledger directory: \$XDG_STATE_HOME/quectel-usbnet, private" "$(stat -c %a "$tmp/xdgstate/quectel-usbnet")" 700
ucli_rc=0
ucli_out=$(env -u QUECTEL_UPLINK_STATE_DIR -u QUECTEL_UPLINK_LEDGER_DIR -u XDG_STATE_HOME XDG_RUNTIME_DIR="$tmp/xdg" HOME="$tmp/xdghome" "$TOOL" uplink auto 2>&1) || ucli_rc=$?
expect_eq "default ledger directory under HOME/.local/state: exit 0" "$ucli_rc" 0
expect_eq "default ledger directory under HOME/.local/state: private" "$(stat -c %a "$tmp/xdghome/.local/state/quectel-usbnet")" 700

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
set +e
"$TOOL" uplink restore extra >/dev/null 2>&1
code=$?
set -e
expect_eq "uplink restore with an argument exits 2" "$code" 2
usage_text=$("$TOOL" 2>&1 || true)
expect_contains "usage names uplink status" "$usage_text" "uplink status"
expect_contains "usage names cell-first" "$usage_text" "uplink cell-first"
expect_contains "usage names uplink restore" "$usage_text" "uplink restore"
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
expect_contains "install: the units keep the fixed PATH line" "$steps" 'Environment="PATH=/usr/sbin:/usr/bin"'
expect_contains "install: the unit bakes in the absolute nmcli" "$steps" "Environment=\"QUECTEL_UPLINK_NMCLI=$ubin/nmcli\""
expect_contains "install: the unit bakes in the absolute ip" "$steps" "Environment=\"QUECTEL_UPLINK_IP=$ubin/ip\""
expect_contains "install: the unit bakes in the absolute ping" "$steps" "Environment=\"QUECTEL_UPLINK_PING=$ubin/ping\""
expect_contains "install: the timer runs every 15 seconds" "$steps" "OnUnitActiveSec=15s"
expect_contains "install: a systemd user timer, enabled with --user" "$steps" "systemctl --user enable --now quectel-uplink.timer"
expect_contains "install: the service runs uplink run from the copy" "$steps" "ExecStart=%h/.local/libexec/quectel-usbnet-uplink uplink run"
expect_contains "install: a restore service runs uplink restore when the timer stops" "$steps" "ExecStop=%h/.local/libexec/quectel-usbnet-uplink uplink restore"
expect_contains "install: the restore service is tied to the timer" "$steps" "PartOf=quectel-uplink.timer"
expect_contains "install: the timer pulls the restore service in" "$steps" "Wants=quectel-uplink-restore.service"
expect_contains "install: says what a stop leaves behind and how it heals" "$steps" "What a stopped, crashed or killed manager leaves behind"
expect_contains "install: says how to return to a clean state by hand" "$steps" "nmcli device reapply"
check_line=$(printf '%s\n' "$steps" | grep -n '^echo "checks passed"' | cut -d: -f1)
close_line=$(printf '%s\n' "$steps" | grep -n 'connection modify uuid' | head -n 1 | cut -d: -f1)
copy_line=$(printf '%s\n' "$steps" | grep -n "^mv -T -- \"\\\$tmp\" \"\\\$dest\"" | cut -d: -f1)
expect_eq "install: every check is printed before the first profile is changed" "$([ "$check_line" -lt "$close_line" ] && echo yes || echo no)" yes
expect_eq "install: and the profile is changed before anything is copied" "$([ "$close_line" -lt "$copy_line" ] && echo yes || echo no)" yes
expect_contains "install: the order is stated in the printed text" "$steps" "every check that can refuse comes first"
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
  HOME="$inst_home" XDG_CONFIG_HOME="" XDG_STATE_HOME="$inst_home/state" PATH="$tmp/sbin_fake:$PATH" bash -e "$tmp/install_block.sh" 2>&1
}
unit_dir="$inst_home/.config/systemd/user"
uopen
: >"$UW/calls"
out=$(run_install) || fail "install: the printed steps run" "$out"
expect_eq "install steps: the two gsm profiles are closed, by uuid" \
  "$(ucalls | grep 'connection modify' | sed 's/^nmcli LC_ALL=C --escape no //' | tr '\n' ';')" \
  "nmcli LC_ALL=C connection modify uuid bbbb-2222 ipv4.never-default yes ipv6.never-default yes;nmcli LC_ALL=C connection modify uuid dddd-4444 ipv4.never-default yes ipv6.never-default yes;"
expect_eq "install steps: no other profile is touched" "$(ucalls | grep 'connection modify' | grep -c -e aaaa -e cccc || true)" 0
expect_eq "install steps: the copy is executable" "$(stat -c %a "$inst_home/.local/libexec/quectel-usbnet-uplink")" 755
expect_eq "install steps: the copy is the script" "$(sed -n 2p "$inst_home/.local/libexec/quectel-usbnet-uplink")" "# quectel-usbnet: read or change the USB network mode of a Quectel modem."
for u in quectel-uplink.service quectel-uplink.timer quectel-uplink-restore.service; do
  expect_eq "install steps: $u is written, first line is the marker" "$(head -n 1 "$unit_dir/$u")" "# written by quectel-usbnet uplink install"
done
expect_eq "install steps: unit files are not group or world writable" "$(stat -c %a "$unit_dir/quectel-uplink.service")" 644
expect_contains "install steps: the timer is enabled for the user" "$(ucalls)" "systemctl --user enable --now quectel-uplink.timer"
expect_contains "install steps: the unit manager is reloaded first" "$(ucalls | head -n 20 | tr '\n' ';')" "systemctl --user daemon-reload"
expect_eq "install steps: the first evaluation ran and left Wi-Fi owner, modem closed" "$(uholders)" "wlan0"
expect_eq "install steps: the first evaluation wrote the mode" "$(cut -d' ' -f1 "$UST/mode")" auto
expect_eq "install steps: no leftover temp files" "$(find "$inst_home" -name '.*.??????' | wc -l)" 0
echo "# stale" >>"$inst_home/.local/libexec/quectel-usbnet-uplink"
out=$(run_install) || fail "install: running the steps again" "$out"
expect_eq "install steps: running again refreshes the copy" "$(grep -c '^# stale' "$inst_home/.local/libexec/quectel-usbnet-uplink" || true)" 0

# every conflict is found BEFORE any profile is closed, and nothing is written
conflict() {
  # conflict NAME: the printed steps must fail, close no profile, and be refused with "refusing"
  local name=$1
  : >"$UW/calls"
  if out=$(run_install); then
    fail "install conflict: $name is refused"
  else
    ok "install conflict: $name is refused"
  fi
  expect_contains "install conflict: $name: says refusing" "$out" "refusing"
  expect_eq "install conflict: $name: no profile was closed" "$(ucalls | grep -c 'connection modify' || true)" 0
}
fresh_home() {
  rm -rf "$inst_home"
  mkdir -p "$unit_dir" "$inst_home/.local/libexec" "$tmp/target_dir"
  echo victim >"$tmp/target_dir/victim"
}
fresh_home
echo "[Unit]" >"$unit_dir/quectel-uplink.service"
conflict "a foreign service unit"
expect_eq "install conflict: the foreign file is intact" "$(cat "$unit_dir/quectel-uplink.service")" "[Unit]"
fresh_home
echo "[Unit]" >"$unit_dir/quectel-uplink-restore.service"
conflict "a foreign restore unit"
fresh_home
echo "[Timer]" >"$unit_dir/quectel-uplink.timer"
conflict "a foreign timer"
fresh_home
ln -s "$tmp/target_dir/victim" "$unit_dir/quectel-uplink.timer"
conflict "a symlinked unit"
expect_eq "install conflict: the symlink target is intact" "$(cat "$tmp/target_dir/victim")" victim
fresh_home
printf '%s\n' "# written by quectel-usbnet uplink install" "[Unit]" >"$tmp/target_dir/marked.service"
ln -s "$tmp/target_dir/marked.service" "$unit_dir/quectel-uplink.service"
conflict "a symlinked unit with our marker behind it"
expect_eq "install conflict: that unit is still a symlink" "$([ -L "$unit_dir/quectel-uplink.service" ] && echo link || echo replaced)" link
fresh_home
echo "not ours" >"$inst_home/.local/libexec/quectel-usbnet-uplink"
conflict "a foreign copy"
expect_eq "install conflict: the foreign copy is intact" "$(cat "$inst_home/.local/libexec/quectel-usbnet-uplink")" "not ours"
fresh_home
ln -s "$tmp/target_dir/victim" "$inst_home/.local/libexec/quectel-usbnet-uplink"
conflict "a symlinked copy"
expect_eq "install conflict: the symlinked copy's target is intact" "$(cat "$tmp/target_dir/victim")" victim
fresh_home
cp "$TOOL" "$tmp/target_dir/copy"
rm -f "$inst_home/.local/libexec/quectel-usbnet-uplink"
ln -s "$tmp/target_dir/copy" "$inst_home/.local/libexec/quectel-usbnet-uplink"
conflict "a symlinked copy of the script"
expect_eq "install conflict: that copy is still a symlink" "$([ -L "$inst_home/.local/libexec/quectel-usbnet-uplink" ] && echo link || echo replaced)" link
fresh_home
rm -rf "$unit_dir"
mkdir -p "$tmp/target_dir/unitdir"
ln -s "$tmp/target_dir/unitdir" "$unit_dir"
conflict "a symlinked unit directory"
expect_eq "install conflict: nothing was written through the symlinked unit directory" "$(find "$tmp/target_dir/unitdir" -mindepth 1 | wc -l)" 0
fresh_home
rm -rf "$inst_home/.local/libexec"
mkdir -p "$tmp/target_dir/libexec"
ln -s "$tmp/target_dir/libexec" "$inst_home/.local/libexec"
conflict "a symlinked libexec directory"
expect_eq "install conflict: nothing was written through the symlinked libexec directory" "$(find "$tmp/target_dir/libexec" -mindepth 1 | wc -l)" 0
fresh_home
mkdir -p "$inst_home/state/quectel-usbnet"
chmod 755 "$inst_home/state/quectel-usbnet"
conflict "a state directory with mode 755"
fresh_home
mkdir -p "$inst_home/state"
ln -s "$tmp/target_dir" "$inst_home/state/quectel-usbnet"
conflict "a symlinked state directory"
fresh_home
mkdir -p "$inst_home/state/quectel-usbnet"
chmod 700 "$inst_home/state/quectel-usbnet"
: >"$UW/calls"
out=$(run_install) || fail "install: a private state directory is accepted" "$out"
expect_eq "install: with everything in order, the profiles are closed" "$(ucalls | grep -c 'connection modify' || true)" 2

# M3: closing the profiles is all or nothing, and nothing is installed after a failure
printf 'bbbb-2222:gsm\ncccc-3333:802-11-wireless\ndddd-4444:gsm\n' >"$UW/connections"
printf 'no\nyes\n1100\n1100\n' >"$UW/prof_bbbb-2222"
printf 'yes\nno\n1100\n1100\n' >"$UW/prof_dddd-4444"
nothing_installed() {
  [ ! -e "$inst_home/.local/libexec/quectel-usbnet-uplink" ] && [ ! -e "$unit_dir/quectel-uplink.service" ] && [ ! -e "$unit_dir/quectel-uplink.timer" ] && [ ! -e "$unit_dir/quectel-uplink-restore.service" ]
}
fresh_home
touch "$UW/fail_conlist"
: >"$UW/calls"
if out=$(run_install); then fail "install: a failed profile listing stops the steps"; else ok "install: a failed profile listing stops the steps"; fi
expect_contains "install: a failed profile listing says nothing was changed" "$out" "cannot list the connection profiles; nothing was changed"
expect_eq "install: a failed profile listing: no profile is modified" "$(ucalls | grep -c 'connection modify' || true)" 0
expect_eq "install: a failed profile listing: nothing is installed" "$(nothing_installed && echo yes || echo no)" yes
expect_eq "install: a failed profile listing does not read as 'no gsm profile found'" "$(printf '%s' "$out" | grep -c 'no gsm profile found' || true)" 0
rm -f "$UW/fail_conlist"
fresh_home
touch "$UW/fail_conread_dddd-4444"
: >"$UW/calls"
if out=$(run_install); then fail "install: an unreadable profile stops the steps"; else ok "install: an unreadable profile stops the steps"; fi
expect_eq "install: an unreadable profile: no profile is modified, not even the first" "$(ucalls | grep -c 'connection modify' || true)" 0
expect_eq "install: an unreadable profile: nothing is installed" "$(nothing_installed && echo yes || echo no)" yes
rm -f "$UW/fail_conread_dddd-4444"
fresh_home
printf 'bbbb-2222:gsm\nab;reboot:gsm\n' >"$UW/connections"
: >"$UW/calls"
if out=$(run_install); then fail "install: an odd profile id stops the steps"; else ok "install: an odd profile id stops the steps"; fi
expect_contains "install: an odd profile id is named" "$out" "an odd profile id; nothing was changed"
expect_eq "install: an odd profile id: nothing modified, not even the first" "$(ucalls | grep -c 'connection modify' || true)" 0
printf 'bbbb-2222:gsm\ncccc-3333:802-11-wireless\ndddd-4444:gsm\n' >"$UW/connections"
fresh_home
printf 'maybe\nno\n1100\n1100\n' >"$UW/prof_dddd-4444"
: >"$UW/calls"
if out=$(run_install); then fail "install: odd previous values stop the steps"; else ok "install: odd previous values stop the steps"; fi
expect_contains "install: odd previous values are named" "$out" "unexpected values for profile dddd-4444; nothing was changed"
expect_eq "install: odd previous values: nothing modified, not even the first" "$(ucalls | grep -c 'connection modify' || true)" 0
printf 'yes\nno\n1100\n1100\n' >"$UW/prof_dddd-4444"
fresh_home
touch "$UW/fail_conmod_dddd-4444"
: >"$UW/calls"
if out=$(run_install); then fail "install: a failure on the second profile stops the steps"; else ok "install: a failure on the second profile stops the steps"; fi
expect_contains "install: a failure on the second profile says it puts the first back" "$out" "putting back the ones already closed"
expect_eq "install: the profile calls are close one, close two (fails), put one back" \
  "$(ucalls | grep 'connection modify' | sed 's/^nmcli LC_ALL=C //' | tr '\n' ';')" \
  "connection modify uuid bbbb-2222 ipv4.never-default yes ipv6.never-default yes;connection modify uuid dddd-4444 ipv4.never-default yes ipv6.never-default yes;connection modify uuid bbbb-2222 ipv4.never-default no ipv6.never-default yes;"
expect_eq "install: the first profile has exactly its old values again" "$(head -n 2 "$UW/prof_bbbb-2222" | tr '\n' ' ')" "no yes "
expect_eq "install: the second profile was never changed" "$(head -n 2 "$UW/prof_dddd-4444" | tr '\n' ' ')" "yes no "
expect_eq "install: nothing is installed after the failure" "$(nothing_installed && echo yes || echo no)" yes
rm -f "$UW/fail_conmod_dddd-4444"
fresh_home
: >"$UW/calls"
out=$(run_install) || fail "install: with nothing failing, both profiles are closed and it installs" "$out"
expect_eq "install: both profiles are closed" "$(head -n 2 "$UW/prof_bbbb-2222" | tr '\n' ' ')$(head -n 2 "$UW/prof_dddd-4444" | tr '\n' ' ')" "yes yes yes yes "
expect_eq "install: and it is installed" "$(nothing_installed && echo no || echo yes)" yes
printf 'aaaa-1111:802-3-ethernet\nbbbb-2222:gsm\ncccc-3333:802-11-wireless\ndddd-4444:gsm\n' >"$UW/connections"

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
fresh_home
uscene ok ok ok
uopen
printf "00000003-0000-0000-0000-000000000000:gsm\n" >"$UW/connections"
out=$(run_install) || fail "install: for the uninstall test" "$out"
ucli cell-first
expect_eq "uninstall setup: cellular owns, Ethernet and Wi-Fi are demoted" "$(uholders)" "wwan0"
usteps=$("$TOOL" uplink uninstall 2>&1)
expect_eq "uninstall: never uses sudo" "$(printf '%s\n' "$usteps" | grep -c sudo || true)" 0
expect_contains "uninstall: stops the timer" "$usteps" "systemctl --user disable --now quectel-uplink.timer"
expect_contains "uninstall: restores every recorded change" "$usteps" "uplink restore"
expect_contains "uninstall: refuses to remove anything if the restore did not finish" "$usteps" "the restore did not finish; nothing was removed"
expect_contains "uninstall: explains the closed modem profile" "$usteps" "stays closed on purpose"
restore_line=$(printf '%s\n' "$usteps" | grep -n "\"\\\$dest\" uplink restore" | cut -d: -f1)
rm_line=$(printf '%s\n' "$usteps" | grep -n "^remove_ours \"\\\$unitdir/quectel-uplink.timer\"" | cut -d: -f1)
stop_line=$(printf '%s\n' "$usteps" | grep -n 'disable --now quectel-uplink.timer' | cut -d: -f1)
expect_eq "uninstall: the timer is stopped, then restored, and only then is anything removed" "$([ "$stop_line" -lt "$restore_line" ] && [ "$restore_line" -lt "$rm_line" ] && echo yes || echo no)" yes
printf '%s\n' "$usteps" | sed -n "/^bash <<'UPLINK_UNINSTALL'/,/^UPLINK_UNINSTALL/p" | sed '1d;$d' >"$tmp/uninstall_block.sh"
run_uninstall() {
  HOME="$inst_home" XDG_CONFIG_HOME="" XDG_STATE_HOME="$inst_home/state" XDG_RUNTIME_DIR="$tmp/xdg_u" PATH="$tmp/sbin_fake:$PATH" bash "$tmp/uninstall_block.sh" 2>&1
}
# a restore that cannot finish removes nothing
touch "$UW/fail_modify_wlan0"
if out=$(run_uninstall); then
  fail "uninstall: a failed restore stops the steps"
else
  ok "uninstall: a failed restore stops the steps"
fi
expect_contains "uninstall: says nothing was removed" "$out" "nothing was removed"
expect_eq "uninstall: the copy is still there" "$([ -e "$inst_home/.local/libexec/quectel-usbnet-uplink" ] && echo kept || echo removed)" kept
expect_eq "uninstall: the units are still there" "$([ -e "$unit_dir/quectel-uplink.timer" ] && echo kept || echo removed)" kept
expect_eq "uninstall: the ledger is still there" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" yes
rm -f "$UW/fail_modify_wlan0"
: >"$UW/calls"
echo "[Unit]" >"$unit_dir/quectel-uplink-other.service"
out=$(run_uninstall) || fail "uninstall: the printed steps run" "$out"
expect_contains "uninstall: stops and disables the timer" "$(ucalls)" "systemctl --user disable --now quectel-uplink.timer"
expect_eq "uninstall: the Wi-Fi the first attempt could not restore is restored now" "$(umods)" "wlan0 no -1;"
expect_contains "uninstall: says what it restored" "$out" "restored wlan0"
expect_eq "uninstall: Ethernet and Wi-Fi hold their defaults again" "$(uholders)" "eth0 wlan0"
for u in quectel-uplink.service quectel-uplink.timer quectel-uplink-restore.service; do
  expect_eq "uninstall: $u is removed" "$([ -e "$unit_dir/$u" ] && echo kept || echo removed)" removed
done
expect_eq "uninstall: the copy is removed" "$([ -e "$inst_home/.local/libexec/quectel-usbnet-uplink" ] && echo kept || echo removed)" removed
expect_eq "uninstall: a file that is not ours is left" "$(cat "$unit_dir/quectel-uplink-other.service")" "[Unit]"
expect_eq "uninstall: the ledger is gone" "$([ -e "$ULD/ledger" ] && echo yes || echo no)" no
echo "foreign" >"$unit_dir/quectel-uplink.service"
out=$(run_uninstall) || true
expect_eq "uninstall: a foreign file with our name is left" "$(cat "$unit_dir/quectel-uplink.service")" foreign
expect_contains "uninstall: and says so" "$out" "left"
# the runtime state is removed by exact name
mkdir -p "$tmp/xdg_u/quectel-usbnet"
touch "$tmp/xdg_u/quectel-usbnet/mode" "$tmp/xdg_u/quectel-usbnet/links" "$tmp/xdg_u/quectel-usbnet/lock" "$tmp/xdg_u/quectel-usbnet/keepme"
out=$(run_uninstall) || true
expect_eq "uninstall: the state files are removed" "$(find "$tmp/xdg_u/quectel-usbnet" -mindepth 1 | tr '\n' ' ')" "$tmp/xdg_u/quectel-usbnet/keepme "
# the leftovers of an interrupted ledger write go too, and the empty state directory with them
mkdir -p "$inst_home/state/quectel-usbnet"
chmod 700 "$inst_home/state/quectel-usbnet"
touch "$inst_home/state/quectel-usbnet/ledger.new"
out=$(run_uninstall) || true
expect_eq "uninstall: a leftover ledger.new and the empty state directory are removed" "$([ -e "$inst_home/state/quectel-usbnet" ] && echo kept || echo removed)" removed
# a ledger left with no copy to restore it: stop, remove nothing, say what to do
mkdir -p "$inst_home/state/quectel-usbnet"
chmod 700 "$inst_home/state/quectel-usbnet"
echo "cdc-wdm0 cell 00000003-0000-0000-0000-000000000000 yes yes 1100 1100" >"$inst_home/state/quectel-usbnet/ledger"
if out=$(run_uninstall); then
  fail "uninstall: a ledger with no copy to restore it stops the steps"
else
  ok "uninstall: a ledger with no copy to restore it stops the steps"
fi
expect_contains "uninstall: says what to do" "$out" "the copy is gone but a ledger is left"
expect_eq "uninstall: that ledger is kept" "$([ -e "$inst_home/state/quectel-usbnet/ledger" ] && echo kept || echo removed)" kept
rm -f "$inst_home/state/quectel-usbnet/ledger"
rmdir "$inst_home/state/quectel-usbnet"
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
