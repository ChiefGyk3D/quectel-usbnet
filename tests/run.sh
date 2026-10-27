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

# --- the SIM application state, against a fake qmicli ------------------------
# A fake qmicli, systemctl and id go first on PATH. systemctl always reports
# ModemManager as running and logs what it was asked, so the tests can check
# that it was stopped before the power cycle and started again after.
bin="$tmp/bin"
qdir="$tmp/qmi"
mkdir -p "$bin" "$qdir"
cp "$HERE/fake_qmicli" "$bin/qmicli"
cat >"$bin/systemctl" <<SH
#!/usr/bin/env bash
echo "systemctl \$*" >>"$qdir/calls.log"
[ "\$1" != is-active ] || exit 0
SH
printf '#!/usr/bin/env bash\necho 0\n' >"$bin/id"
chmod +x "$bin/systemctl" "$bin/id"
export FAKE_QMI_DIR="$qdir"
export QUECTEL_SIM_OFF_WAIT=0 QUECTEL_SIM_READY_TIMEOUT=2 QUECTEL_SIM_POLL_INTERVAL=0.2
OLD_PATH=$PATH
PATH="$bin:$PATH"

new_scenario() {
  rm -f "$qdir/state" "$qdir/calls.log"
  touch "$qdir/calls.log"
  export FAKE_QMI_SCENARIO=$1
  unset FAKE_QMI_FAIL_OFF
}
calls() { tr '\n' '|' <"$qdir/calls.log"; }

expect_eq "parse_app_state reads a ready card" \
  "$(rm -f "$qdir/state"; FAKE_QMI_SCENARIO=ready qmicli --uim-get-card-status | parse_app_state)" ready
expect_eq "parse_app_state reads an illegal card" \
  "$(rm -f "$qdir/state"; FAKE_QMI_SCENARIO=illegal-fixed qmicli --uim-get-card-status | parse_app_state)" illegal
expect_eq "parse_app_state ignores a state that is not slot 1 application 1" \
  "$(printf "Slot [2]:\n\tApplication [1]:\n\t\tApplication state: 'ready'\n" | parse_app_state)" ""
expect_eq "parse_app_state prints nothing for garbage" \
  "$(printf 'error: no\n' | parse_app_state)" ""

new_scenario illegal-fixed
out=$(sim_status_lines /dev/fake-wdm)
expect_contains "status reads the SIM through the qmi proxy" "$(calls)" "qmicli -p -d /dev/fake-wdm --uim-get-card-status"
expect_contains "status names the USIM state" "$out" "USIM state:    illegal"
expect_contains "status flags an illegal USIM as wedged" "$out" "WEDGED"
expect_contains "status points at sim-recover" "$out" "sim-recover"
new_scenario ready
out=$(sim_status_lines /dev/fake-wdm)
expect_contains "status shows a ready USIM" "$out" "USIM state:    ready"
case $out in
  *WEDGED*) fail "a ready USIM is not flagged" ;;
  *) ok "a ready USIM is not flagged" ;;
esac

# Already ready: say so, change nothing, leave ModemManager alone.
new_scenario ready
set +e
out=$("$TOOL" sim-recover --device /dev/fake-wdm 2>"$tmp/err")
code=$?
set -e
expect_eq "sim-recover on a ready SIM exits 0" "$code" 0
expect_eq "sim-recover on a ready SIM prints one result line" "$out" "sim-recover: ready"
case $(calls) in
  *power-off* | *stop*) fail "a ready SIM is not power cycled" "$(calls)" ;;
  *) ok "a ready SIM is not power cycled" ;;
esac

# Wedged, fixed by a power cycle.
new_scenario illegal-fixed
set +e
out=$("$TOOL" sim-recover --device /dev/fake-wdm 2>"$tmp/err")
code=$?
set -e
expect_eq "sim-recover on a wedged SIM exits 0" "$code" 0
expect_eq "sim-recover reports recovered" "$out" "sim-recover: recovered"
expect_eq "sim-recover stops MM, cycles the SIM, polls, starts MM" \
  "$(calls | sed 's/ -p -d \/dev\/fake-wdm//g; s/ -d \/dev\/fake-wdm//g; s/systemctl is-active --quiet ModemManager|//')" \
  "qmicli --uim-get-card-status|systemctl stop ModemManager|qmicli --uim-sim-power-off=1|qmicli --uim-sim-power-on=1|qmicli --uim-get-card-status|systemctl start ModemManager|"

# Wedged and a power cycle does not help: fail loudly, still hand MM back.
new_scenario never
set +e
out=$("$TOOL" sim-recover --device /dev/fake-wdm 2>"$tmp/err")
code=$?
set -e
expect_eq "sim-recover exits 1 when the SIM never becomes ready" "$code" 1
expect_eq "sim-recover reports failed" "$out" "sim-recover: failed"
expect_contains "sim-recover says why on stderr" "$(cat "$tmp/err")" "did not become ready"
expect_contains "ModemManager is started again after a failure" "$(calls)" "systemctl start ModemManager"

# An error half way through: the EXIT trap still starts ModemManager.
new_scenario illegal-fixed
export FAKE_QMI_FAIL_OFF=1
set +e
out=$("$TOOL" sim-recover --device /dev/fake-wdm 2>"$tmp/err")
code=$?
set -e
expect_eq "sim-recover exits 1 when power-off fails" "$code" 1
expect_eq "sim-recover reports failed when power-off fails" "$out" "sim-recover: failed"
expect_contains "ModemManager is started again after a power-off error" "$(calls)" "systemctl start ModemManager"

# The cdc-wdm node is found through the symlinked device directory.
mkdir -p "$tmp/real/4-4/4-4:1.4/usbmisc/cdc-wdm0" "$tmp/devices2"
ln -s "$tmp/real/4-4" "$tmp/devices2/4-4"
expect_eq "device_wdm follows the symlinked device directory" \
  "$(device_wdm "$tmp/devices2/4-4")" "/dev/cdc-wdm0"

PATH=$OLD_PATH
unset FAKE_QMI_SCENARIO FAKE_QMI_FAIL_OFF

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
