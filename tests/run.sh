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
