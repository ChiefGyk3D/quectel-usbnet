#!/usr/bin/env bash
# Tests for quectel-usbnet. No hardware needed: the AT conversation runs against
# a fake modem on a pty (tests/fake_modem.py), and everything that would touch
# sysfs, ModemManager or the journal is only checked on its refusal paths.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOL="$HERE/../quectel-usbnet"
failures=0
checks=0

ok() {
  checks=$((checks + 1))
  echo "ok   $1"
}

fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  echo "FAIL $1" >&2
  [ $# -lt 2 ] || echo "     $2" >&2
}

expect_eq() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    fail "$1" "wanted '$3', got '$2'"
  fi
}

expect_contains() {
  if [[ $2 == *"$3"* ]]; then
    ok "$1"
  else
    fail "$1" "'$3' not found in: $2"
  fi
}

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=quectel-usbnet
source "$TOOL"

# --- mode mapping -----------------------------------------------------------
expect_eq "qmi maps to 0" "$(mode_to_value qmi)" 0
expect_eq "rmnet is an alias for qmi" "$(mode_to_value RMNET)" 0
expect_eq "ecm maps to 1" "$(mode_to_value ecm)" 1
expect_eq "mbim maps to 2" "$(mode_to_value mbim)" 2
expect_eq "a bare number passes through" "$(mode_to_value 3)" 3
if mode_to_value nonsense >/dev/null; then
  fail "an unknown mode is refused"
else
  ok "an unknown mode is refused"
fi
expect_eq "0 names qmi" "$(value_to_name 0)" qmi
expect_eq "2 names mbim" "$(value_to_name 2)" mbim
expect_eq "mbim expects cdc_mbim" "$(expected_driver 2)" cdc_mbim
expect_eq "qmi expects qmi_wwan" "$(expected_driver 0)" qmi_wwan
expect_eq "qmi_wwan reads as qmi" "$(driver_to_mode qmi_wwan)" qmi

# --- response parsing -------------------------------------------------------
expect_eq "parse_usbnet reads a CRLF response" \
  "$(printf '+QCFG: "usbnet",2\r\n\r\nOK\r\n' | parse_usbnet)" 2
expect_eq "parse_usbnet reads a spaced response" \
  "$(printf '+QCFG: "usbnet", 0\r\nOK\r\n' | parse_usbnet)" 0
expect_eq "parse_usbnet prints nothing on ERROR" \
  "$(printf 'ERROR\r\n' | parse_usbnet)" ""

# --- the AT conversation, against the fake modem ----------------------------
tmp=$(mktemp -d)
pty_file="$tmp/pty"
python3 -I "$HERE/fake_modem.py" >"$pty_file" &
fake_pid=$!
cleanup() {
  kill "$fake_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
for _ in $(seq 1 50); do
  [ -s "$pty_file" ] && break
  sleep 0.1
done
port=$(head -n 1 "$pty_file")
[ -n "$port" ] || {
  echo "fake modem did not start" >&2
  exit 1
}

reply=$(at_cmd "$port" ATI)
expect_contains "ATI is answered by something that says Quectel" "$reply" Quectel
expect_contains "ATI reports the revision" "$reply" "Revision: EM160RGLAUR02A07M4G"
expect_eq "the fake modem starts in MBIM" \
  "$(at_cmd "$port" 'AT+QCFG="usbnet"' | parse_usbnet)" 2
reply=$(at_cmd "$port" 'AT+QCFG="usbnet",0')
expect_contains "setting the mode is acknowledged" "$reply" OK
expect_eq "the new mode reads back" \
  "$(at_cmd "$port" 'AT+QCFG="usbnet"' | parse_usbnet)" 0
reply=$(at_cmd "$port" 'AT+NOPE')
expect_contains "an unknown command is an ERROR, not a hang" "$reply" ERROR
if at_cmd /nonexistent/tty ATI >/dev/null 2>&1; then
  fail "a missing port is an error"
else
  ok "a missing port is an error"
fi

# --- finding the AT ports through a symlinked device directory --------------
# /sys/bus/usb/devices/4-4 is a symlink; a plain `find` on it prints nothing.
mkdir -p "$tmp/real/4-4/4-4:1.2/ttyUSB2/tty" "$tmp/real/4-4/4-4:1.3/ttyUSB3/tty" "$tmp/devices"
ln -s "$tmp/real/4-4" "$tmp/devices/4-4"
expect_eq "device_ttys follows the symlinked device directory" \
  "$(device_ttys "$tmp/devices/4-4" | xargs -n1 basename | tr '\n' ' ')" "ttyUSB2 ttyUSB3 "

# --- recover: the escalating ladder, against stub nmcli/mmcli/systemctl -------
# Every external command goes through a seam (NMCLI, MMCLI, SYSTEMCTL, USB_SYSFS,
# RECOVER_SLEEP, SLEEP_HOOK_DIR) or an overridable function (is_root, reexec_root,
# sysfs_write, at_cmd, find_at_port), so nothing here touches real hardware,
# services or sysfs. The stub keeps its state in files under $STATE.
STATE="$tmp/state"
STUB_LOG="$tmp/stub.log"
export STATE STUB_LOG
stubdir="$tmp/stubs"
mkdir -p "$stubdir"
cat >"$stubdir/stub" <<'STUB'
#!/usr/bin/env bash
# One stub for nmcli, mmcli and systemctl. $STATE/fixed_by names the rung that
# makes the system healthy; $STATE/listed says a (broken) modem is already listed.
name=$(basename "$0")
echo "$name $*" >>"$STUB_LOG"
fixed_by=$(cat "$STATE/fixed_by" 2>/dev/null || true)
fix() { [ "$fixed_by" = "$1" ] && touch "$STATE/healthy"; return 0; }
case "$name $*" in
  "nmcli radio wwan on")
    fix radio
    ;;
  "nmcli -t -f DEVICE,TYPE,STATE device")
    echo "wlan0:wifi:connected"
    if [ -e "$STATE/healthy" ]; then echo "cdc-wdm0:gsm:connected"; else echo "cdc-wdm0:gsm:unavailable"; fi
    ;;
  "mmcli -L")
    if [ -e "$STATE/healthy" ] || [ -e "$STATE/listed" ]; then
      echo "    /org/freedesktop/ModemManager1/Modem/22 [Quectel] EM160R-GL"
    else
      echo "No modems were found" >&2
    fi
    ;;
  "mmcli -m 22 -K")
    if [ -e "$STATE/enabled" ] || [ -e "$STATE/healthy" ]; then
      echo "modem.generic.state                      : enabled"
    else
      echo "modem.generic.state                      : disabled"
    fi
    ;;
  "mmcli -m 22 --enable")
    touch "$STATE/enabled"
    fix enable
    ;;
  "systemctl restart ModemManager")
    fix restart
    ;;
  "systemctl start ModemManager")
    [ -e "$STATE/cfun_done" ] && fix cfun
    ;;
  "systemctl is-active --quiet ModemManager") ;;
  "systemctl stop ModemManager") ;;
  *) exit 1 ;;
esac
exit 0
STUB
chmod +x "$stubdir/stub"
for n in nmcli mmcli systemctl; do ln -sf stub "$stubdir/$n"; done
export NMCLI="$stubdir/nmcli" MMCLI="$stubdir/mmcli" SYSTEMCTL="$stubdir/systemctl"
export RECOVER_SLEEP=true RECOVER_MM_WAIT=3 RECOVER_NM_WAIT=2

# A fake sysfs: the modem under a bus path the code must not hardcode, another
# Quectel product that must be left alone, and an unrelated vendor.
export USB_SYSFS="$tmp/usb"
mkdir -p "$USB_SYSFS/7-2" "$USB_SYSFS/3-1" "$USB_SYSFS/1-1" "$USB_SYSFS/7-2:1.4"
echo 2c7c >"$USB_SYSFS/7-2/idVendor"
echo 0620 >"$USB_SYSFS/7-2/idProduct"
echo 1 >"$USB_SYSFS/7-2/authorized"
echo 2c7c >"$USB_SYSFS/3-1/idVendor"
echo 0125 >"$USB_SYSFS/3-1/idProduct"
echo 8087 >"$USB_SYSFS/1-1/idVendor"
echo 0a2b >"$USB_SYSFS/1-1/idProduct"

is_root() { [ "${TEST_ROOT:-yes}" = yes ]; }
reexec_root() { echo "REEXEC $*"; }
sysfs_write() {
  echo "sysfs_write $1 $2" >>"$STUB_LOG"
  [ "$1" = 1 ] && [ "$(cat "$STATE/fixed_by" 2>/dev/null)" = authorized ] && touch "$STATE/healthy"
  return 0
}
at_cmd() {
  echo "at_cmd $2" >>"$STUB_LOG"
  [ "$2" = "AT+CFUN=1,1" ] && touch "$STATE/cfun_done"
  echo OK
}
find_at_port() { echo /dev/ttyFAKE; }

# scenario FIXED_BY [listed]: reset the stub, name the rung that heals it.
scenario() {
  rm -rf "$STATE"
  mkdir -p "$STATE"
  : >"$STUB_LOG"
  echo "$1" >"$STATE/fixed_by"
  [ "${2:-}" = listed ] && touch "$STATE/listed"
  return 0
}
run_recover() {
  set +e
  out=$(cmd_recover "$@" 2>&1)
  code=$?
  set -e
}
calls() { cat "$STUB_LOG"; }
expect_called() { expect_contains "$1" "$(calls)" "$2"; }
expect_not_called() {
  if [[ $(calls) == *"$2"* ]]; then fail "$1" "'$2' was called: $(calls)"; else ok "$1"; fi
}

scenario none listed
touch "$STATE/healthy"
run_recover
expect_eq "already healthy: exits 0" "$code" 0
expect_not_called "already healthy: radio untouched" "radio wwan on"
expect_not_called "already healthy: ModemManager not restarted" "restart"

scenario radio listed
run_recover
expect_eq "rung 1 (wwan radio on) heals: exit 0" "$code" 0
expect_called "rung 1 turns the wwan radio on" "nmcli radio wwan on"
expect_not_called "rung 1 stops the ladder before enable" "--enable"
expect_not_called "rung 1 stops the ladder before the restart" "restart"
expect_contains "rung 1 prints what it did" "$out" "nmcli radio wwan on"
expect_contains "rung 1 prints the observed result" "$out" "recovered"

scenario enable listed
run_recover
expect_eq "rung 2 (mmcli --enable) heals: exit 0" "$code" 0
expect_called "rung 2 enables the disabled modem by its index" "mmcli -m 22 --enable"
expect_not_called "rung 2 stops the ladder before the restart" "restart"

scenario enable listed
touch "$STATE/enabled"
run_recover
expect_not_called "rung 2 does not enable a modem that is already enabled" "--enable"

scenario restart
run_recover
expect_eq "rung 3 (restart ModemManager) heals: exit 0" "$code" 0
expect_called "rung 3 restarts ModemManager" "systemctl restart ModemManager"
expect_not_called "rung 3 stops the ladder before sysfs" "sysfs_write"
expect_contains "rung 3 reports the modem appeared" "$out" "recovered"

scenario authorized
run_recover
expect_eq "rung 4 (authorized 0/1) heals: exit 0" "$code" 0
expect_eq "rung 4 toggles authorized 0 then 1 on the 2c7c:0620 device only" \
  "$(grep '^sysfs_write' "$STUB_LOG" | tr '\n' ';')" \
  "sysfs_write 0 $USB_SYSFS/7-2/authorized;sysfs_write 1 $USB_SYSFS/7-2/authorized;"
expect_not_called "rung 4 stops the ladder before the AT reset" "at_cmd"

scenario none
run_recover
expect_eq "nothing heals: exit 1" "$code" 1
expect_contains "nothing heals: the AT reset is only offered, not sent" "$out" "AT+CFUN=1,1"
expect_not_called "no --yes and no terminal: the modem is not reset" "at_cmd AT+CFUN"
expect_contains "nothing heals: says what to do next" "$out" "not recovered"

scenario cfun
run_recover --yes
expect_eq "rung 5 (AT+CFUN=1,1 with --yes) heals: exit 0" "$code" 0
expect_called "rung 5 resets the modem on the AT port" "at_cmd AT+CFUN=1,1"
expect_called "rung 5 stops ModemManager first" "systemctl stop ModemManager"
expect_called "rung 5 starts ModemManager again" "systemctl start ModemManager"

scenario none listed
TEST_ROOT=no run_recover
expect_contains "not root at rung 3: re-executes through a privilege helper" "$out" "REEXEC"
expect_contains "the re-exec resumes at rung 3, not rung 1" "$out" "--from 3"
expect_called "rungs 1 and 2 ran unprivileged first" "nmcli radio wwan on"
expect_not_called "nothing privileged ran before the re-exec" "restart"
expect_contains "the root message is clear" "$out" "need root"

scenario restart
run_recover --from 3
expect_not_called "--from 3 skips the radio rung" "radio wwan on"
expect_called "--from 3 still restarts ModemManager" "restart ModemManager"

scenario none
run_recover --dry-run
expect_eq "dry run exits 0" "$code" 0
expect_eq "dry run runs no external command" "$(calls)" ""
for want in "nmcli radio wwan on" "mmcli" "restart ModemManager" "authorized" "AT+CFUN=1,1" "nothing will be touched"; do
  expect_contains "dry run lists: $want" "$out" "$want"
done

# A device that never reappears must not hang the loop: the cap is the guard.
scenario none
RECOVER_MM_WAIT=2 run_recover
expect_eq "bounded waits: a modem that never comes back ends in exit 1" "$code" 1

# --- install-resume-hook: opt-in only ---------------------------------------
export SLEEP_HOOK_DIR="$tmp/sleep"
mkdir -p "$SLEEP_HOOK_DIR"
set +e
out=$(cmd_install_resume_hook --dry-run --tool /usr/local/bin/quectel-usbnet 2>&1)
code=$?
set -e
expect_eq "install dry run exits 0" "$code" 0
expect_contains "install dry run shows the hook" "$out" "timeout"
expect_eq "install dry run writes nothing" "$(ls "$SLEEP_HOOK_DIR")" ""
expect_eq "no other command installs a hook" \
  "$(
    cmd_status >/dev/null 2>&1 || true
    cmd_recover --dry-run >/dev/null 2>&1
    ls "$SLEEP_HOOK_DIR"
  )" ""

hooktool="$tmp/hooktool"
cat >"$hooktool" <<'HT'
#!/usr/bin/env bash
echo "hook ran: $*" >>"$HOOK_LOG"
HT
chmod +x "$hooktool"
export HOOK_LOG="$tmp/hook.log" QUECTEL_RESUME_DELAY=0 QUECTEL_RESUME_LOGGER=cat
: >"$HOOK_LOG"
cmd_install_resume_hook --tool "$hooktool" >/dev/null
hook="$SLEEP_HOOK_DIR/quectel-usbnet-recover"
if [ -x "$hook" ]; then ok "install writes an executable hook"; else fail "install writes an executable hook"; fi
hook_text=$(cat "$hook")
expect_contains "the hook runs recover with the given tool" "$hook_text" "\"$hooktool\" recover"
expect_contains "the hook is time limited" "$hook_text" "timeout"
expect_contains "the hook runs in the background" "$hook_text" "&"

"$hook" pre suspend
sleep 0.5
expect_eq "the hook does nothing before suspend" "$(cat "$HOOK_LOG")" ""
"$hook" post suspend
for _ in $(seq 1 50); do
  [ -s "$HOOK_LOG" ] && break
  sleep 0.1
done
expect_contains "the hook runs recover after resume" "$(cat "$HOOK_LOG")" "hook ran: recover"

echo "# someone else's script" >"$SLEEP_HOOK_DIR/quectel-usbnet-recover"
set +e
out=$(cmd_install_resume_hook --tool "$hooktool" 2>&1)
code=$?
set -e
expect_eq "install refuses to overwrite a file it did not write" "$code" 1
expect_contains "the refusal says why" "$out" "not written by"
rm -f "$SLEEP_HOOK_DIR/quectel-usbnet-recover"

out=$(TEST_ROOT=no cmd_install_resume_hook --tool "$hooktool" 2>&1)
expect_contains "install without root re-executes through a privilege helper" "$out" "REEXEC"
expect_eq "install without root wrote nothing yet" "$(ls "$SLEEP_HOOK_DIR")" ""

unset NMCLI MMCLI SYSTEMCTL USB_SYSFS RECOVER_SLEEP RECOVER_MM_WAIT RECOVER_NM_WAIT SLEEP_HOOK_DIR
unset -f is_root reexec_root sysfs_write at_cmd find_at_port
# Put the real implementations back for the command-line checks below.
# shellcheck source=quectel-usbnet
source "$TOOL"

# --- the recover command line -----------------------------------------------
out=$("$TOOL" recover --dry-run 2>&1)
expect_contains "recover --dry-run works from the command line" "$out" "nothing will be touched"
out=$("$TOOL" install-resume-hook --dry-run 2>&1)
expect_contains "install-resume-hook --dry-run works from the command line" "$out" "post"
set +e
"$TOOL" recover --bogus >/dev/null 2>&1
code=$?
set -e
expect_eq "recover with an unknown option exits 2" "$code" 2

# --- the command line -------------------------------------------------------
out=$("$TOOL" set qmi --dry-run 2>&1)
expect_contains "dry run names the AT command it would send" "$out" 'AT+QCFG="usbnet",0'
expect_contains "dry run says it touches nothing" "$out" "nothing will be touched"
out=$("$TOOL" set mbim --dry-run 2>&1)
expect_contains "dry run for mbim waits for cdc_mbim" "$out" cdc_mbim

set +e
out=$("$TOOL" set bogus 2>&1)
code=$?
set -e
expect_eq "an unknown mode exits 1" "$code" 1
expect_contains "an unknown mode says what is valid" "$out" "qmi, ecm, mbim, rndis"

set +e
"$TOOL" >/dev/null 2>&1
code=$?
set -e
expect_eq "no arguments exits 2 with usage" "$code" 2

expect_eq "--version prints the version" "$("$TOOL" --version)" "quectel-usbnet $VERSION"

echo
echo "$checks checks, $failures failed"
[ "$failures" -eq 0 ]
