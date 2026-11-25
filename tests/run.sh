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

# --- install-resume-hook: opt-in only, and never a user-writable path ---------
# The hook runs as root after every resume. It must point at a root-owned copy
# of the tool, never at the source tree or anything under $HOME. The tests stand
# in for "root" with the current user by reassigning ROOT_UID/ROOT_GID, and for
# /usr with directories under $tmp.
export SLEEP_HOOK_DIR="$tmp/sleep" LIBEXEC_DIR="$tmp/libexec"
ROOT_UID=$(id -u)
ROOT_GID=$(id -g)
mkdir -p "$SLEEP_HOOK_DIR" "$LIBEXEC_DIR"
chmod 755 "$SLEEP_HOOK_DIR" "$LIBEXEC_DIR"
installed_files() { find "$SLEEP_HOOK_DIR" "$LIBEXEC_DIR" -mindepth 1; }
set +e
out=$(cmd_install_resume_hook --dry-run --tool "$HOME/src/quectel-usbnet/quectel-usbnet" 2>&1)
code=$?
set -e
expect_eq "install dry run exits 0" "$code" 0
expect_contains "install dry run shows the hook" "$out" "timeout"
expect_contains "install dry run names the root-owned copy" "$out" "$LIBEXEC_DIR/quectel-usbnet"
if [[ $out == *"$HOME"* ]]; then fail "the dry-run hook never mentions \$HOME"; else ok "the dry-run hook never mentions \$HOME"; fi
expect_eq "install dry run writes nothing" "$(installed_files)" ""
expect_eq "no other command installs a hook or a copy" \
  "$(
    cmd_status >/dev/null 2>&1 || true
    cmd_recover --dry-run >/dev/null 2>&1
    installed_files
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
copy="$LIBEXEC_DIR/quectel-usbnet"
if [ -x "$hook" ]; then ok "install writes an executable hook"; else fail "install writes an executable hook"; fi
if [ -x "$copy" ]; then ok "install writes an executable copy of the tool"; else fail "install writes an executable copy of the tool"; fi
expect_eq "the copy is mode 0755" "$(stat -c %a "$copy")" 755
expect_eq "the copy is the given source" "$(cat "$copy")" "$(cat "$hooktool")"
hook_text=$(cat "$hook")
expect_contains "the hook runs only the root-owned copy" "$hook_text" "tool=\"$copy\""
for bad in "$hooktool" "$HOME" "$HERE" "$TOOL"; do
  if [[ $hook_text == *"$bad"* ]]; then
    fail "the hook never names a source or user path" "found '$bad'"
  else
    ok "the hook never names a source or user path"
  fi
done
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

# The hook refuses a copy that something else could have edited.
: >"$HOOK_LOG"
chmod 775 "$copy"
"$hook" post suspend
sleep 0.5
expect_eq "the hook refuses a group-writable copy" "$(cat "$HOOK_LOG")" ""
chmod 757 "$copy"
"$hook" post suspend
sleep 0.5
expect_eq "the hook refuses an other-writable copy" "$(cat "$HOOK_LOG")" ""
chmod 755 "$copy"
chmod 777 "$LIBEXEC_DIR"
"$hook" post suspend
sleep 0.5
expect_eq "the hook refuses a copy in a writable directory" "$(cat "$HOOK_LOG")" ""
chmod 755 "$LIBEXEC_DIR"
mv "$copy" "$copy.real"
ln -s "$copy.real" "$copy"
"$hook" post suspend
sleep 0.5
expect_eq "the hook refuses a symlinked copy" "$(cat "$HOOK_LOG")" ""
rm -f "$copy"
mv "$copy.real" "$copy"
# the stand-in owner is the current user; a different owner is refused too
sed -i "s/-user $ROOT_UID /-user 99999 /" "$hook"
"$hook" post suspend
sleep 0.5
expect_eq "the hook refuses a copy with the wrong owner" "$(cat "$HOOK_LOG")" ""

# Re-running the install updates the copy.
cat >"$hooktool" <<'HT'
#!/usr/bin/env bash
echo "hook ran v2: $*" >>"$HOOK_LOG"
HT
cmd_install_resume_hook --tool "$hooktool" >/dev/null
expect_contains "re-running install updates the copy" "$(cat "$copy")" "v2"
"$hook" post suspend
for _ in $(seq 1 50); do
  [ -s "$HOOK_LOG" ] && break
  sleep 0.1
done
expect_contains "the reinstalled hook works again" "$(cat "$HOOK_LOG")" "hook ran v2: recover"

# Refusals: a destination directory others can write, or a foreign file.
chmod 775 "$LIBEXEC_DIR"
set +e
out=$(cmd_install_resume_hook --tool "$hooktool" 2>&1)
code=$?
set -e
expect_eq "install refuses a group-writable destination directory" "$code" 1
expect_contains "the refusal names the directory" "$out" "not safe"
chmod 757 "$LIBEXEC_DIR"
set +e
(cmd_install_resume_hook --tool "$hooktool") >/dev/null 2>&1
code=$?
set -e
expect_eq "install refuses an other-writable destination directory" "$code" 1
chmod 755 "$LIBEXEC_DIR"
set +e
(
  ROOT_UID=99999
  cmd_install_resume_hook --tool "$hooktool"
) >/dev/null 2>&1
code=$?
set -e
expect_eq "install refuses a destination directory that is not root-owned" "$code" 1

rm -f "$hook" "$copy"
echo "# someone else's script" >"$hook"
set +e
out=$(cmd_install_resume_hook --tool "$hooktool" 2>&1)
code=$?
set -e
expect_eq "install refuses to overwrite a hook it did not write" "$code" 1
expect_contains "the refusal says why" "$out" "not written by"
expect_eq "a refused install leaves no copy behind" "$(ls "$LIBEXEC_DIR")" ""
rm -f "$hook"
echo "# someone else's tool" >"$copy"
set +e
(cmd_install_resume_hook --tool "$hooktool") >/dev/null 2>&1
code=$?
set -e
expect_eq "install refuses to overwrite a copy it did not write" "$code" 1
rm -f "$copy"

out=$(TEST_ROOT=no cmd_install_resume_hook --tool "$hooktool" 2>&1)
expect_contains "install without root re-executes through a privilege helper" "$out" "REEXEC"
expect_eq "install without root wrote nothing yet" "$(installed_files)" ""

# --- uninstall-resume-hook: removes only what the installer wrote -------------
# "Wrote" is recognised by the script's own header for the copy and a marker for
# the hook, so a real copy of this script is installed for these checks.
cmd_install_resume_hook --tool "$TOOL" >/dev/null
if [ -e "$hook" ] && [ -e "$copy" ]; then ok "install with the real script writes both files"; else fail "install with the real script writes both files"; fi
cmd_uninstall_resume_hook >/dev/null
expect_eq "uninstall removes the hook and the copy" "$(installed_files)" ""
set +e
(cmd_uninstall_resume_hook) >/dev/null 2>&1
code=$?
set -e
expect_eq "uninstall with nothing installed succeeds" "$code" 0
echo "# someone else's script" >"$hook"
echo "# someone else's tool" >"$copy"
cmd_uninstall_resume_hook >/dev/null 2>&1 || true
if [ -e "$hook" ] && [ -e "$copy" ]; then ok "uninstall leaves files it did not write"; else fail "uninstall leaves files it did not write"; fi
rm -f "$hook" "$copy"
out=$(TEST_ROOT=no cmd_uninstall_resume_hook 2>&1)
expect_contains "uninstall without root re-executes through a privilege helper" "$out" "REEXEC"

unset NMCLI MMCLI SYSTEMCTL USB_SYSFS RECOVER_SLEEP RECOVER_MM_WAIT RECOVER_NM_WAIT SLEEP_HOOK_DIR LIBEXEC_DIR
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
  "$(
    rm -f "$qdir/state"
    FAKE_QMI_SCENARIO=ready qmicli --uim-get-card-status | parse_app_state
  )" ready
expect_eq "parse_app_state reads an illegal card" \
  "$(
    rm -f "$qdir/state"
    FAKE_QMI_SCENARIO=illegal-fixed qmicli --uim-get-card-status | parse_app_state
  )" illegal
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

# --- the modem egress guard: pure decision logic ------------------------------
GUARD_FAILS=2
GUARD_OKS=2

# guard_link_step PREV FAILS OKS PROBE -> "status fails oks"
expect_eq "link: one failed ping does not flip an up link (flapping)" \
  "$(guard_link_step up 0 0 fail)" "up 1 0"
expect_eq "link: two failed pings in a row flip an up link down" \
  "$(guard_link_step up 1 0 fail)" "down 2 0"
expect_eq "link: a good ping between failures resets the streak" \
  "$(guard_link_step up 1 0 ok)" "up 0 1"
expect_eq "link: one good ping does not flip a down link up" \
  "$(guard_link_step down 2 0 ok)" "down 0 1"
expect_eq "link: two good pings in a row flip a down link up" \
  "$(guard_link_step down 0 1 ok)" "up 0 2"
expect_eq "link: a failure between good pings resets the streak" \
  "$(guard_link_step down 0 1 fail)" "down 1 0"
expect_eq "link: an absent device is down at once" \
  "$(guard_link_step up 0 5 absent)" "down 2 0"
expect_eq "link: a malformed previous state is down with no history" \
  "$(guard_link_step bogus x y ok)" "down 0 1"
expect_eq "link: an unknown probe result never counts as healthy" \
  "$(guard_link_step down 0 1 weird)" "down 0 0"

# guard_decide OVERRIDE ETH WIFI MODEM_METRIC WIFI_METRIC ETH_METRIC
d() { guard_decide "$@" | cut -d' ' -f1; }
r() { guard_decide "$@" | cut -d' ' -f2; }
expect_eq "decide: both links healthy, modem behind -> on" "$(d auto up up 1100 600 100)" on
expect_eq "decide: only Wi-Fi healthy -> on" "$(d auto down up 1100 600 100)" on
expect_eq "decide: only Ethernet healthy -> on" "$(d auto up down 1100 600 100)" on
expect_eq "decide: Ethernet and Wi-Fi both down -> off (failover)" "$(d auto down down 1100 600 100)" off
expect_eq "decide: failover reason is named" "$(r auto down down 1100 600 100)" failover
expect_eq "decide: modem metric below Wi-Fi's -> off (owner flipped)" "$(d auto up up 500 600 100)" off
expect_eq "decide: flip reason is named" "$(r auto up up 500 600 100)" modem-first
expect_eq "decide: modem metric equal to Wi-Fi's is not a flip" "$(d auto up up 600 600 100)" on
expect_eq "decide: no Wi-Fi route, flip is judged against Ethernet" "$(d auto up down 50 '' 100)" off
expect_eq "decide: no Wi-Fi route, modem behind Ethernet -> on" "$(d auto up down 1100 '' 100)" on
expect_eq "decide: no modem route -> off" "$(d auto up up '' 600 100)" off
expect_eq "decide: override off wins over healthy links" "$(d off up up 1100 600 100)" off
expect_eq "decide: override off names its reason" "$(r off up up 1100 600 100)" override-off
expect_eq "decide: override on holds even in failover" "$(d on down down 1100 600 100)" on
expect_eq "decide: override on holds even when flipped" "$(d on up up 500 600 100)" on
expect_eq "decide: an invalid override fails open" "$(d invalid up up 1100 600 100)" off
expect_eq "decide: a malformed link status fails open" "$(d auto maybe up 1100 600 100)" off
expect_eq "decide: a non-numeric modem metric fails open" "$(d auto up up abc 600 100)" off
expect_eq "decide: a non-numeric Wi-Fi metric fails open" "$(d auto up up 1100 6x0 100)" off
expect_eq "decide: a negative metric fails open" "$(d auto up up -1 600 100)" off
expect_eq "decide: no arguments fails open" "$(d)" off

# The override file.
gt="$tmp/guard"
mkdir -p "$gt"
expect_eq "override: no file is auto" "$(guard_override_value "$gt/none")" auto
printf 'off\n' >"$gt/ov"
expect_eq "override: off" "$(guard_override_value "$gt/ov")" off
printf '  ON \r\n' >"$gt/ov"
expect_eq "override: on, case and whitespace ignored" "$(guard_override_value "$gt/ov")" on
printf 'auto\n' >"$gt/ov"
expect_eq "override: auto" "$(guard_override_value "$gt/ov")" auto
printf 'maybe\n' >"$gt/ov"
expect_eq "override: unknown text is invalid" "$(guard_override_value "$gt/ov")" invalid
: >"$gt/ov"
expect_eq "override: an empty file is invalid" "$(guard_override_value "$gt/ov")" invalid
ln -sf "$gt/ov" "$gt/ovlink"
expect_eq "override: a symlink is invalid" "$(guard_override_value "$gt/ovlink")" invalid

# Parsers.
nm_out=$'wlan0:wifi:connected\ncdc-wdm0:gsm:connected\nsdwan0:tun:connected\neth0:ethernet:unavailable\np2p-dev-wlan0:wifi-p2p:disconnected'
expect_eq "devices: a connected wifi is found" "$(printf '%s\n' "$nm_out" | guard_devices_of_type wifi)" wlan0
expect_eq "devices: an unavailable ethernet is not" "$(printf '%s\n' "$nm_out" | guard_devices_of_type ethernet)" ""
expect_eq "devices: the gsm control port is found" "$(printf '%s\n' "$nm_out" | guard_devices_of_type gsm)" cdc-wdm0
expect_eq "devices: wifi-p2p is not wifi" "$(printf 'p2p-dev-wlan0:wifi-p2p:connected\n' | guard_devices_of_type wifi)" ""
expect_eq "devices: garbage gives nothing" "$(printf 'garbage\n::\n' | guard_devices_of_type wifi)" ""
expect_eq "metric: lowest of two routes" \
  "$(printf 'default via x dev a metric 700\ndefault dev a metric 600\n' | guard_min_metric)" 600
expect_eq "metric: a route without a metric is 0" \
  "$(printf 'default dev a proto static\n' | guard_min_metric)" 0
expect_eq "metric: no default route gives nothing" \
  "$(printf '10.0.0.0/24 dev a metric 5\n' | guard_min_metric)" ""
expect_eq "metric: empty input gives nothing" "$(printf '' | guard_min_metric)" ""
if guard_iface_ok 'wwan0; flush ruleset'; then
  fail "iface: a name with shell or nft syntax is refused"
else
  ok "iface: a name with shell or nft syntax is refused"
fi
if guard_iface_ok 'wwp0s20f0u4i4' && guard_iface_ok 'wlan0'; then
  ok "iface: ordinary names pass"
else
  fail "iface: ordinary names pass"
fi

# --- the guard runner, against fake nft, nmcli, ip and ping -------------------
gf="$tmp/gfake"
gbin="$tmp/gbin"
mkdir -p "$gf" "$gbin"
cat >"$gbin/nft" <<'FAKE'
#!/usr/bin/env bash
# fake nft: the table is the file $GFAKE/table; every call is logged.
echo "nft $*" >>"$GFAKE/calls"
case "$*" in
  "list table inet quectel_modem_guard") [ -f "$GFAKE/table" ] ;;
  "-f -")
    if [ -f "$GFAKE/fail_load" ]; then
      cat >/dev/null
      echo "Error: load failed" >&2
      exit 1
    fi
    cat >"$GFAKE/table"
    ;;
  "delete table inet quectel_modem_guard")
    # fail_delete: always fails. fail_delete_once: fails the first time only.
    if [ -f "$GFAKE/fail_delete" ]; then
      echo "Error: netlink busy" >&2
      exit 1
    fi
    if [ -f "$GFAKE/fail_delete_once" ]; then
      rm -f "$GFAKE/fail_delete_once"
      echo "Error: netlink busy" >&2
      exit 1
    fi
    if [ ! -f "$GFAKE/table" ]; then
      echo "Error: No such file or directory" >&2
      exit 1
    fi
    rm -f "$GFAKE/table"
    ;;
  *) exit 9 ;;
esac
FAKE
cat >"$gbin/nmcli" <<'FAKE'
#!/usr/bin/env bash
echo "nmcli LC_ALL=${LC_ALL:-unset} $*" >>"$GFAKE/calls"
if [ "$1" = --escape ]; then shift 2; fi
case "$1" in
  -t) cat "$GFAKE/devices" ;;
  -g) cat "$GFAKE/ipiface_${5}" 2>/dev/null ;;
esac
FAKE
cat >"$gbin/ip" <<'FAKE'
#!/usr/bin/env bash
# ip -o -4|-6 route show default dev IFACE
fam=${2#-}
[ "$fam" = 4 ] && cat "$GFAKE/route4_${7}" 2>/dev/null
[ "$fam" = 6 ] && cat "$GFAKE/route6_${7}" 2>/dev/null
exit 0
FAKE
cat >"$gbin/ping" <<'FAKE'
#!/usr/bin/env bash
# ping -n -q -c 1 -W T -I IFACE TARGET
iface=""
while [ $# -gt 0 ]; do
  [ "$1" = -I ] && iface=$2
  shift
done
echo "ping $iface" >>"$GFAKE/calls"
# ping_sleep: a ping that hangs far longer than any timeout it was given
if [ -f "$GFAKE/ping_sleep" ]; then sleep "$(cat "$GFAKE/ping_sleep")"; fi
[ "$(cat "$GFAKE/ping_$iface" 2>/dev/null)" = ok ]
FAKE
chmod +x "$gbin"/*
export GFAKE="$gf"
GUARD_NFT="$gbin/nft"
GUARD_NMCLI="$gbin/nmcli"
GUARD_IP="$gbin/ip"
GUARD_PING="$gbin/ping"
GUARD_STATE_DIR="$tmp/gstate"
GUARD_OVERRIDE="$tmp/goverride"
GUARD_TARGETS="192.0.2.1 198.51.100.1"

# gscene ETH_STATE WIFI_STATE: a laptop with ethernet, Wi-Fi and a modem.
# State is "ok" or "dead" (pings fail) or "gone" (device not connected).
gscene() {
  rm -rf "$gf" "$GUARD_STATE_DIR" "$GUARD_OVERRIDE"
  mkdir -p "$gf"
  : >"$gf/devices"
  [ "$1" = gone ] || echo "eth0:ethernet:connected" >>"$gf/devices"
  [ "$2" = gone ] || echo "wlan0:wifi:connected" >>"$gf/devices"
  echo "cdc-wdm0:gsm:connected" >>"$gf/devices"
  echo "wwan0" >"$gf/ipiface_cdc-wdm0"
  echo "default via 192.0.2.254 dev eth0 proto dhcp metric 100" >"$gf/route4_eth0"
  echo "default via 192.0.2.254 dev wlan0 proto dhcp metric 600" >"$gf/route4_wlan0"
  echo "default dev wwan0 proto static metric 1100" >"$gf/route4_wwan0"
  echo "default dev wwan0 proto static metric 1100 pref medium" >"$gf/route6_wwan0"
  [ "$1" = ok ] && echo ok >"$gf/ping_eth0"
  [ "$2" = ok ] && echo ok >"$gf/ping_wlan0"
  return 0
}
# grun: one runner pass; prints the log line.
grun() { cmd_guard_run "$@" 2>&1; }
table_on() { [ -f "$gf/table" ]; }
expect_absent() {
  if [ -e "$1" ]; then fail "$2" "$1 exists"; else ok "$2"; fi
}
# expect_table on|off LABEL
expect_table() {
  if table_on; then
    if [ "$1" = on ]; then ok "$2"; else fail "$2" "the nft table exists"; fi
  else
    if [ "$1" = off ]; then ok "$2"; else fail "$2" "the nft table is missing"; fi
  fi
}

gscene ok ok
out=$(grun)
expect_table off "runner: the first pass does not arm the guard (needs $GUARD_OKS good probes)"
out=$(grun)
expect_contains "runner: both links healthy, two passes -> guard on" "$out" "guard=on (healthy)"
expect_table on "runner: the nft table exists"
expect_contains "ruleset names the modem interface" "$(cat "$gf/table")" '"wwan0"'
expect_contains "ruleset rejects egress on the armed interface" "$(cat "$gf/table")" "oifname @armed reject"
expect_contains "ruleset lets neighbor discovery through" "$(cat "$gf/table")" "nd-neighbor-solicit"
expect_contains "ruleset expires by itself if not refreshed" "$(cat "$gf/table")" "timeout 60s"
expect_contains "ruleset uses its own inet table" "$(cat "$gf/table")" "table inet quectel_modem_guard"
expect_contains "ruleset has its own priority" "$(cat "$gf/table")" "priority -5"
if grep -qE 'flush ruleset|delete table inet (filter|ufw)' "$gf/table"; then
  fail "runner: ruleset only touches its own table"
else
  ok "runner: ruleset only touches its own table"
fi
# only the guard's own table is named in any nft call
if grep '^nft' "$gf/calls" | grep -v quectel_modem_guard | grep -qv -e '-f -'; then
  fail "runner: nft is only asked about the guard's own table"
else
  ok "runner: nft is only asked about the guard's own table"
fi

# Failover: Wi-Fi and Ethernet die. One failed pass keeps the guard on (flapping),
# the second opens it.
echo dead >"$gf/ping_eth0"
echo dead >"$gf/ping_wlan0"
out=$(grun)
expect_contains "runner: one failed round does not open the guard" "$out" "guard=on (healthy)"
out=$(grun)
expect_contains "runner: two failed rounds open the guard (failover)" "$out" "guard=off (failover)"
expect_table off "runner: the table is removed on failover"
# Links return: two good rounds to re-arm.
echo ok >"$gf/ping_wlan0"
out=$(grun)
expect_contains "runner: one good round does not re-arm" "$out" "guard=off (failover)"
out=$(grun)
expect_contains "runner: two good rounds re-arm" "$out" "guard=on (healthy)"

# Wi-Fi alone is enough.
echo dead >"$gf/ping_eth0"
for _ in 1 2 3; do out=$(grun); done
expect_contains "runner: Ethernet down but Wi-Fi up keeps the guard on" "$out" "guard=on (healthy)"

# Flip detection: the owner sets the modem metric below Wi-Fi's.
echo "default dev wwan0 proto static metric 500" >"$gf/route4_wwan0"
echo "default dev wwan0 proto static metric 500 pref medium" >"$gf/route6_wwan0"
out=$(grun)
expect_contains "runner: modem metric below Wi-Fi's turns the guard off at once" "$out" "guard=off (modem-first)"
expect_table off "runner: flip removes the table"
echo "default dev wwan0 proto static metric 1100" >"$gf/route4_wwan0"
echo "default dev wwan0 proto static metric 1100 pref medium" >"$gf/route6_wwan0"
out=$(grun)
expect_contains "runner: flipping back turns the guard on" "$out" "guard=on (healthy)"

# The IPv6 route alone can carry the flip.
echo "default dev wwan0 proto static metric 500 pref medium" >"$gf/route6_wwan0"
out=$(grun)
expect_contains "runner: a lower IPv6 modem metric also counts as a flip" "$out" "guard=off (modem-first)"
echo "default dev wwan0 proto static metric 1100 pref medium" >"$gf/route6_wwan0"

# Override file.
echo off >"$GUARD_OVERRIDE"
out=$(grun)
expect_contains "runner: override off opens the guard" "$out" "guard=off (override-off)"
expect_table off "runner: override off removes the table"
echo garbage >"$GUARD_OVERRIDE"
out=$(grun)
expect_contains "runner: a malformed override fails open" "$out" "guard=off (override-invalid)"
rm -f "$GUARD_OVERRIDE"
out=$(grun)
expect_contains "runner: removing the override re-arms the guard" "$out" "guard=on (healthy)"

# No modem connected: nothing to guard, and a stale table is removed.
grep -v cdc-wdm0 "$gf/devices" >"$gf/devices.new"
mv "$gf/devices.new" "$gf/devices"
out=$(grun)
expect_contains "runner: no modem device, guard off" "$out" "guard=off"
expect_table off "runner: no modem device removes a stale table"

# A device that is not connected is down at once (unplugged cable).
gscene ok gone
grun >/dev/null
out=$(grun)
expect_contains "runner: Ethernet alone is enough" "$out" "guard=on (healthy)"
grep -v eth0 "$gf/devices" >"$gf/devices.tmp"
mv "$gf/devices.tmp" "$gf/devices"
out=$(grun)
expect_contains "runner: an unplugged Ethernet is down at once, guard opens" "$out" "guard=off (failover)"

# Dry run: decides, applies nothing, writes no state.
gscene ok ok
out=$(grun --dry-run)
expect_contains "runner: --dry-run says nothing was applied" "$out" "dry run: nothing applied"
if [ -d "$GUARD_STATE_DIR" ]; then
  fail "runner: --dry-run writes no state"
else
  ok "runner: --dry-run writes no state"
fi
if grep -qE '^nft (-f|delete)' "$gf/calls"; then
  fail "runner: --dry-run never changes nft"
else
  ok "runner: --dry-run never changes nft"
fi
# Armed guard, override says off: a dry run reports off but leaves the table.
grun >/dev/null
grun >/dev/null
echo off >"$GUARD_OVERRIDE"
out=$(grun --dry-run)
expect_contains "runner: --dry-run reports the decision" "$out" "guard=off (override-off)"
expect_table on "runner: --dry-run leaves an armed table alone"

# Malformed inputs from the tools.
gscene ok ok
echo 'wwan0; flush ruleset' >"$gf/ipiface_cdc-wdm0"
# give the hostile name real routes, so only the name check can stop it
echo "default dev wwan0 proto static metric 1100" >"$gf/route4_wwan0; flush ruleset"
grun >/dev/null
out=$(grun)
expect_contains "runner: a hostile interface name is never used" "$out" "guard=off"
expect_table off "runner: a hostile interface name never reaches nft"
gscene ok ok
printf 'wlan0:wifi\n::::\n' >"$gf/devices"
out=$(grun)
expect_contains "runner: malformed nmcli output fails open" "$out" "guard=off"
gscene ok ok
echo "default dev wwan0 metric 99999999999999999999" >"$gf/route4_wwan0"
echo "default dev wwan0 metric 99999999999999999999" >"$gf/route6_wwan0"
grun >/dev/null
out=$(grun)
expect_contains "runner: an absurd modem metric reads as high, not a crash" "$out" "guard=on (healthy)"
gscene ok ok
mkdir -p "$GUARD_STATE_DIR"
echo "total garbage here" >"$GUARD_STATE_DIR/wifi"
echo "up 9 9" >"$GUARD_STATE_DIR/ethernet"
out=$(grun)
expect_contains "runner: a corrupt state file does not crash the run" "$out" "guard="
run_bare_nft() {
  local GUARD_NFT=nft
  cmd_guard_run 2>&1
}
run_bad_state() {
  local GUARD_STATE_DIR="$gf/blocker/sub"
  grun
}

# Tool paths must be absolute.
set +e
out=$(run_bare_nft)
code=$?
set -e
expect_eq "runner: a bare tool name is refused" "$code" 1
expect_contains "runner: the refusal names the variable" "$out" "must be an absolute path"

# The ruleset text and the printed steps.
rs=$(guard_ruleset wwan0)
expect_contains "ruleset: replaces the table in one transaction" "$rs" "delete table inet quectel_modem_guard"
svc=$(guard_service_text /usr/sbin/nft /usr/bin/nmcli /usr/sbin/ip /usr/bin/ping)
expect_contains "service: absolute nft path is baked in" "$svc" "QUECTEL_GUARD_NFT=/usr/sbin/nft"
expect_contains "service: absolute ping path is baked in" "$svc" "QUECTEL_GUARD_PING=/usr/bin/ping"
expect_contains "service: runs the root-owned copy" "$svc" "ExecStart=/usr/local/libexec/quectel-usbnet-guard guard-run"
# The fakes stand in for the real tools on PATH, so this works where NetworkManager is absent.
out=$(PATH="$gbin:$PATH" "$TOOL" guard-install)
expect_contains "guard-install prints sudo steps" "$out" "sudo systemctl enable --now quectel-modem-guard.timer"
expect_contains "guard-install bakes in absolute tool paths" "$out" "QUECTEL_GUARD_NMCLI=$gbin/nmcli"
set +e
out2=$(PATH="$gf" "$BASH" "$TOOL" guard-install 2>&1)
code=$?
set -e
expect_eq "guard-install refuses when a needed tool is missing" "$code" 1
expect_contains "guard-install names the missing tool" "$out2" "not found"
expect_contains "guard-install says nothing was run" "$out" "Nothing has been run"
expect_contains "guard-install prints the script's sha256" "$out" "$(sha256sum "$TOOL" | cut -d' ' -f1)"
expect_contains "guard-install stages through a root-created temp file" "$out" 'sudo mktemp'
expect_contains "guard-install renames atomically" "$out" 'sudo mv -T --'
expect_contains "guard-install refuses a symlink destination" "$out" 'is a symlink'
out=$("$TOOL" guard-uninstall)
expect_contains "guard-uninstall removes the nft table" "$out" "delete table inet quectel_modem_guard"
expect_contains "guard-uninstall checks the marker before deleting" "$out" "remove_ours"
expect_contains "guard-uninstall leaves the resume hook's copy alone" "$out" "quectel-usbnet-guard"
if [[ $out == *"rm -rf"* ]]; then
  fail "guard-uninstall has no recursive delete"
else
  ok "guard-uninstall has no recursive delete"
fi
if [[ $out == *"/usr/local/libexec/quectel-usbnet "* ]] || [[ $out == *"/usr/local/libexec/quectel-usbnet$'\n'"* ]]; then
  fail "guard-uninstall never removes the resume hook's copy"
else
  ok "guard-uninstall never removes the resume hook's copy"
fi

# --- fix round 1: hostile paths, safe install steps, uninstall ----------------
# hostile NAME: a directory with that name holding copies of the four fake tools
# and a copy of the script, so command -v and readlink -f keep the directory text.
hostile() {
  local d="$tmp/h/$1"
  mkdir -p "$d"
  cp "$gbin/nft" "$gbin/nmcli" "$gbin/ip" "$gbin/ping" "$TOOL" "$d/"
  printf '%s' "$d"
}
mkdir -p "$tmp/h"
# run guard-install from a copy of the script in dir $1, tools found in dir $2
hrun() { PATH="$2:$PATH" "$BASH" "$1/quectel-usbnet" guard-install 2>&1; }

d=$(hostile "it has space")
set +e
out=$(hrun "$d" "$d")
code=$?
set -e
expect_eq "install: a space in the tool and script path is accepted" "$code" 0
expect_contains "install: the unit quotes the tool path" "$out" "Environment=\"QUECTEL_GUARD_NFT=$d/nft\""
expect_contains "install: the shell commands quote the script path" "$out" "$(printf '%q' "$d/quectel-usbnet")"
d=$(hostile "it's quoted")
set +e
out=$(hrun "$d" "$d")
code=$?
set -e
expect_eq "install: a single quote in the path is accepted" "$code" 0
expect_contains "install: a single quote is shell-escaped" "$out" "$(printf '%q' "$d/quectel-usbnet")"
for bad in 'per%cent' "dollar\$sign" 'back\slash' 'double"quote' $'new\nline' $'ctl\001char'; do
  d=$(hostile "$bad")
  set +e
  out=$(hrun "$d" "$d")
  code=$?
  set -e
  expect_eq "install: a tool path with $(printf '%q' "$bad") is refused" "$code" 1
  expect_contains "install: the refusal says why ($(printf '%q' "$bad"))" "$out" "cannot go into a unit file"
  if [[ $out == *"sudo "* ]]; then
    fail "install: no steps are printed for $(printf '%q' "$bad")"
  else
    ok "install: no steps are printed for $(printf '%q' "$bad")"
  fi
done
# a hostile script path (the tools are fine): control characters are refused,
# % is only quoted because the path goes to the shell, never into a unit
d=$(hostile $'src\nnewline')
set +e
out=$(hrun "$d" "$gbin")
code=$?
set -e
expect_eq "install: a newline in the script path is refused" "$code" 1
expect_contains "install: the script path refusal says why" "$out" "control character"
d=$(hostile 'src%percent')
set +e
out=$(hrun "$d" "$gbin")
code=$?
set -e
expect_eq "install: a % in the script path only needs shell quoting" "$code" 0
expect_contains "install: that % is shell-quoted" "$out" "$(printf '%q' "$d/quectel-usbnet")"

# Run the printed steps for real against temp directories, with a fake sudo
# that runs the command as the current user (chown is a no-op).
sb="$tmp/sudobin"
mkdir -p "$sb"
cat >"$sb/sudo" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  -v | chown) exit 0 ;;
esac
exec "$@"
FAKE
cat >"$sb/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >>"$GFAKE/calls"
FAKE
chmod +x "$sb/sudo" "$sb/systemctl"
# directories made below must not be group-writable: the printed steps now refuse those
umask 022
inst="$tmp/inst"
mkdir -p "$inst/src"
cp "$TOOL" "$inst/src/quectel-usbnet"
# envs NAME: the seams that point the install at a fresh temp tree
guard_env() {
  rm -rf "$inst/root"
  mkdir -p "$inst/root/units" "$inst/root/libexec"
  export QUECTEL_GUARD_UNIT_DIR="$inst/root/units" QUECTEL_GUARD_LIBEXEC_DIR="$inst/root/libexec"
  export QUECTEL_GUARD_OVERRIDE_DIR="$inst/root/etc" QUECTEL_GUARD_STATE_DIR="$inst/root/run" QUECTEL_GUARD_TEST_TREE="$inst"
}
steps() { PATH="$sb:$gbin:$PATH" "$BASH" "$inst/src/quectel-usbnet" guard-"$1" >"$inst/$1.sh" 2>&1; }
runsteps() { PATH="$sb:$gbin:$PATH" "$BASH" "$inst/$1.sh" >"$inst/$1.out" 2>&1; }

guard_env
: >"$gf/calls"
steps install
set +e
runsteps install
code=$?
set -e
expect_eq "install steps: a clean install succeeds" "$code" 0
expect_eq "install steps: the unit is mode 0644" "$(stat -c %a "$inst/root/units/quectel-modem-guard.service")" 644
expect_eq "install steps: the script copy is mode 0755" "$(stat -c %a "$inst/root/libexec/quectel-usbnet-guard")" 755
expect_eq "install steps: the copy is byte for byte the script" \
  "$(sha256sum <"$inst/root/libexec/quectel-usbnet-guard")" "$(sha256sum <"$inst/src/quectel-usbnet")"
expect_contains "install steps: the timer is enabled" "$(cat "$gf/calls")" "systemctl enable --now quectel-modem-guard.timer"
left=$(find "$inst/root/units" "$inst/root/libexec" -name '.*' | wc -l)
expect_eq "install steps: no temp files are left behind" "$left" 0
# a permissive unit written by an older install comes back 0644
chmod 0666 "$inst/root/units/quectel-modem-guard.service"
set +e
runsteps install
code=$?
set -e
expect_eq "install steps: a reinstall over our own files succeeds" "$code" 0
expect_eq "install steps: a permissive unit is replaced by a 0644 one" "$(stat -c %a "$inst/root/units/quectel-modem-guard.service")" 644
# a symlink at the destination is refused and its target is not written
guard_env
printf "# written by quectel-usbnet guard-install\nvictim\n" >"$inst/victim"
ln -s "$inst/victim" "$inst/root/units/quectel-modem-guard.service"
set +e
runsteps install
code=$?
set -e
expect_eq "install steps: a symlink destination is refused" "$code" 1
expect_eq "install steps: the symlink target is untouched" "$(tail -n 1 "$inst/victim")" victim
if [ -L "$inst/root/units/quectel-modem-guard.service" ]; then
  ok "install steps: the symlink is still a symlink"
else
  fail "install steps: the symlink is still a symlink"
fi
left=$(find "$inst/root/units" -name '.*' | wc -l)
expect_eq "install steps: a refused install leaves no temp file" "$left" 0
# a file that is not ours is refused
guard_env
echo "[Service] # an administrator's own unit" >"$inst/root/units/quectel-modem-guard.timer"
set +e
runsteps install
code=$?
set -e
expect_eq "install steps: a foreign file at the destination is refused" "$code" 1
expect_contains "install steps: the foreign file is left alone" "$(cat "$inst/root/units/quectel-modem-guard.timer")" "administrator's own"
# the script changes between printing and running: nothing is installed
guard_env
steps install
echo "# changed after review" >>"$inst/src/quectel-usbnet"
set +e
runsteps install
code=$?
set -e
expect_eq "install steps: a script changed after printing is refused" "$code" 1
expect_contains "install steps: the refusal explains" "$(cat "$inst/install.out")" "changed after guard-install printed"
if [ -e "$inst/root/libexec/quectel-usbnet-guard" ]; then
  fail "install steps: nothing is installed when the hash differs"
else
  ok "install steps: nothing is installed when the hash differs"
fi
cp "$TOOL" "$inst/src/quectel-usbnet"

# Uninstall: only files that carry the marker are deleted.
guard_env
steps install
runsteps install
mkdir -p "$inst/root/etc" "$inst/root/run"
echo off >"$inst/root/etc/guard-override"
echo "up 0 0" >"$inst/root/run/ethernet"
echo "up 0 0" >"$inst/root/run/wifi"
echo precious >"$inst/root/run/other-state"
echo "an admin edit" >"$inst/root/units/quectel-modem-guard.timer"
steps uninstall
set +e
runsteps uninstall
code=$?
set -e
expect_eq "uninstall steps: run cleanly" "$code" 0
expect_absent "$inst/root/units/quectel-modem-guard.service" "uninstall steps: our unit is removed"
expect_absent "$inst/root/libexec/quectel-usbnet-guard" "uninstall steps: our script copy is removed"
expect_eq "uninstall steps: a unit without the marker is left alone" "$(cat "$inst/root/units/quectel-modem-guard.timer")" "an admin edit"
expect_contains "uninstall steps: the left file is named" "$(cat "$inst/uninstall.out")" "left $inst/root/units/quectel-modem-guard.timer: not written by quectel-usbnet"
expect_absent "$inst/root/etc" "uninstall steps: the override and its empty directory are removed"
expect_absent "$inst/root/run/ethernet" "uninstall steps: the known state files are removed"
expect_absent "$inst/root/run/wifi" "uninstall steps: the wifi state file is removed"
expect_eq "uninstall steps: an unknown file in the state directory survives" "$(cat "$inst/root/run/other-state")" precious
# a symlinked script copy is not followed
guard_env
steps install
runsteps install
rm -f "$inst/root/libexec/quectel-usbnet-guard"
printf "quectel-usbnet: read or change the USB network mode\nvictim\n" >"$inst/victim"
ln -s "$inst/victim" "$inst/root/libexec/quectel-usbnet-guard"
steps uninstall
runsteps uninstall
expect_eq "uninstall steps: a symlinked copy's target survives" "$(tail -n 1 "$inst/victim")" victim
if [ -L "$inst/root/libexec/quectel-usbnet-guard" ]; then
  ok "uninstall steps: a symlinked copy is left in place, not followed or removed"
else
  fail "uninstall steps: a symlinked copy is left in place, not followed or removed"
fi
unset QUECTEL_GUARD_UNIT_DIR QUECTEL_GUARD_LIBEXEC_DIR QUECTEL_GUARD_OVERRIDE_DIR QUECTEL_GUARD_STATE_DIR QUECTEL_GUARD_TEST_TREE

# --- fix round 1: the off path fails open --------------------------------------
# arm: two good rounds
garm() {
  gscene ok ok
  grun >/dev/null
  grun >/dev/null
}
# Both links dead and the delete fails: the decision is off, the run says so
# loudly, retries once, exits non-zero, and still saves the link state.
garm
echo dead >"$gf/ping_eth0"
echo dead >"$gf/ping_wlan0"
grun >/dev/null
: >"$gf/calls"
: >"$gf/fail_delete"
set +e
out=$(grun)
code=$?
set -e
expect_contains "off path: the decision is still off" "$out" "guard=off (failover)"
expect_contains "off path: a failed delete is reported loudly" "$out" "ERROR: could not remove the nft table"
expect_eq "off path: a failed delete exits non-zero" "$code" 1
expect_eq "off path: the delete is tried twice" "$(grep -c '^nft delete' "$gf/calls")" 2
expect_contains "off path: the link state is saved even so" "$(cat "$GUARD_STATE_DIR/wifi")" "down"
# A state directory that cannot be written must not stop the guard from opening.
garm
echo dead >"$gf/ping_eth0"
echo dead >"$gf/ping_wlan0"
echo notadir >"$gf/blocker"
set +e
out=$(run_bad_state)
code=$?
set -e
expect_contains "off path: an unwritable state directory is only a warning" "$out" "could not save the link state"
expect_table off "off path: the guard still opens when the state cannot be saved"
# One transient failure: the retry opens the guard.
garm
echo dead >"$gf/ping_eth0"
echo dead >"$gf/ping_wlan0"
grun >/dev/null
: >"$gf/fail_delete_once"
set +e
out=$(grun)
code=$?
set -e
expect_eq "off path: a single failed delete is retried and succeeds" "$code" 0
expect_table off "off path: the retry removed the table"
# A table that is already gone is success, not an error.
gscene ok ok
set +e
out=$(grun)
code=$?
set -e
expect_eq "off path: deleting a table that is not there is not an error" "$code" 0
# A failed load removes the table instead of leaving the old one armed.
garm
: >"$gf/fail_load"
: >"$gf/calls"
set +e
out=$(grun)
code=$?
set -e
expect_eq "on path: a failed rule load exits non-zero" "$code" 1
expect_contains "on path: a failed rule load is reported" "$out" "loading the rules failed"
expect_table off "on path: a failed rule load fails open"

# --- fix round 1: bounded work -------------------------------------------------
# Ten Ethernet devices and a Wi-Fi, every ping hangs for far longer than the
# deadline. At most 4 per type are probed, in parallel, and the run still ends.
gscene dead ok
for i in 1 2 3 4 5 6 7 8 9; do echo "eth$i:ethernet:connected" >>"$gf/devices"; done
hang=$((40000 + $$ % 20000))
echo "$hang" >"$gf/ping_sleep"
: >"$gf/calls"
GUARD_DEADLINE=3
SECONDS=0
set +e
out=$(grun)
code=$?
set -e
elapsed=$SECONDS
GUARD_DEADLINE=12
expect_eq "bounded: the run ends near the deadline, not after the hanging pings" "$((elapsed <= 6 ? 1 : 0))" 1
expect_eq "bounded: the run still decides" "$code" 0
expect_contains "bounded: hanging probes count as failures, so the guard opens" "$out" "guard=off"
expect_eq "bounded: only 4 Ethernet devices and 1 Wi-Fi are probed" "$(grep -c '^ping' "$gf/calls")" 5
leftover=0
for f in /proc/[0-9]*/cmdline; do
  if [ "$(tr '\0' ' ' <"$f" 2>/dev/null)" = "sleep $hang " ]; then
    leftover=$((leftover + 1))
    pid=${f#/proc/}
    kill "${pid%/cmdline}" 2>/dev/null || true
  fi
done
expect_eq "bounded: the deadline kills the hanging pings" "$leftover" 0
rm -f "$gf/ping_sleep"

# --- fix round 1: settings are validated ---------------------------------------
for pair in "GUARD_TTL=60s; flush ruleset" "GUARD_TTL=5" "GUARD_FAILS=0" "GUARD_OKS=abc" \
  "GUARD_PING_TIMEOUT=999" "GUARD_DEADLINE=1" "GUARD_MAX_DEVICES=100" "GUARD_TTL="; do
  garm
  var=${pair%%=*}
  val=${pair#*=}
  set +e
  out=$(
    printf -v "$var" '%s' "$val"
    grun
  )
  code=$?
  set -e
  expect_eq "config: $var=$val exits non-zero" "$code" 1
  expect_contains "config: $var=$val names the setting" "$out" "QUECTEL_$var"
  expect_contains "config: $var=$val forces the guard off" "$out" "guard forced off"
  expect_table off "config: $var=$val removes an armed table"
done
garm
expect_table on "config: the defaults are valid"

# --- fix round 2: no DHCP exception (the interface is configured statically) ---
rs=$(guard_ruleset wwan0)
if [[ $rs == *"udp"* ]]; then
  fail "ruleset: no UDP accept of any kind"
else
  ok "ruleset: no UDP accept of any kind"
fi
expect_contains "ruleset: ICMPv6 neighbor and router discovery are kept" "$rs" "nd-router-advert"
accepts=$(printf '%s\n' "$rs" | grep -c ' accept$')
expect_eq "ruleset: exactly one accept rule" "$accepts" 1

# --- fix round 2: a probe that ignores TERM cannot hold the run ----------------
cat >"$gbin/ping" <<'FAKE'
#!/usr/bin/env bash
# ping -n -q -c 1 -W T -w T -I IFACE TARGET
iface=""
while [ $# -gt 0 ]; do
  [ "$1" = -I ] && iface=$2
  shift
done
echo "ping $iface" >>"$GFAKE/calls"
# ping_deaf: ignores TERM and never ends (only KILL stops it)
if [ -f "$GFAKE/ping_deaf" ]; then
  trap '' TERM
  while :; do sleep 1; done
fi
if [ -f "$GFAKE/ping_sleep" ]; then sleep "$(cat "$GFAKE/ping_sleep")"; fi
[ "$(cat "$GFAKE/ping_$iface" 2>/dev/null)" = ok ]
FAKE
chmod +x "$gbin/ping"
garm
echo dead >"$gf/ping_eth0"
echo dead >"$gf/ping_wlan0"
: >"$gf/ping_deaf"
GUARD_DEADLINE=2
# the run goes to a file and a watchdog ends the test if it hangs, instead of the suite
# watched: one run in a fresh shell under a 20 s timeout; prints ended or hung
# shellcheck disable=SC2031,SC2016 # earlier subshell assignments are scoped on purpose; the -c script must stay literal
watched() {
  local rc=0
  QUECTEL_GUARD_NFT=$GUARD_NFT QUECTEL_GUARD_NMCLI=$GUARD_NMCLI QUECTEL_GUARD_IP=$GUARD_IP \
    QUECTEL_GUARD_PING=$GUARD_PING QUECTEL_GUARD_STATE_DIR=$GUARD_STATE_DIR \
    QUECTEL_GUARD_OVERRIDE=$GUARD_OVERRIDE QUECTEL_GUARD_TARGETS=$GUARD_TARGETS \
    QUECTEL_GUARD_DEADLINE=$GUARD_DEADLINE \
    timeout 20 "$BASH" -c 'source "$1"; set +e; cmd_guard_run' _ "$TOOL" >"$tmp/deaf.out" 2>&1 || rc=$?
  if [ "$rc" -eq 124 ]; then echo hung; else echo ended; fi
}
expect_eq "deaf probe: the run ends within the deadline plus the 1 s grace" "$(watched)" ended
: >"$gf/calls"
SECONDS=0
grun >"$tmp/deaf.out" 2>&1 || true
deaf_elapsed=$SECONDS
expect_eq "deaf probe: a whole run takes at most deadline + grace + slack" "$((deaf_elapsed <= 6 ? 1 : 0))" 1
expect_contains "deaf probe: the run still decides" "$(cat "$tmp/deaf.out")" "guard=off (failover)"
expect_table off "deaf probe: the fail-open delete still ran"
deaf_left=0
for f in /proc/[0-9]*/cmdline; do
  case "$(tr '\0' ' ' <"$f" 2>/dev/null)" in
    *"$gbin/ping "*)
      deaf_left=$((deaf_left + 1))
      pid=${f#/proc/}
      kill -9 "${pid%/cmdline}" 2>/dev/null || true
      ;;
  esac
done
expect_eq "deaf probe: KILL leaves no probe process behind" "$deaf_left" 0
rm -f "$gf/ping_deaf"
GUARD_DEADLINE=12

# --- fix round 2: nmcli output is parsed in the C locale, unescaped -------------
expect_eq "parse: a colon inside a device name is split from the right" \
  "$(printf 'we:ird0:ethernet:connected\neth0:ethernet:connected\n' | guard_devices_of_type ethernet | tr '\n' ' ')" "we:ird0 eth0 "
gscene ok ok
echo "we:ird0:ethernet:connected" >>"$gf/devices"
echo ok >"$gf/ping_we:ird0"
: >"$gf/calls"
out=$(LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 grun)
expect_contains "nmcli: the device list is read with LC_ALL=C and --escape no" "$(cat "$gf/calls")" "nmcli LC_ALL=C --escape no -t -f DEVICE,TYPE,STATE device"
expect_contains "nmcli: the modem interface is read with LC_ALL=C and --escape no" "$(cat "$gf/calls")" "nmcli LC_ALL=C --escape no -g GENERAL.IP-IFACE device show cdc-wdm0"
expect_eq "nmcli: a device whose name holds a colon is never probed" "$(grep -c 'ping we' "$gf/calls")" 0
expect_contains "nmcli: the ordinary devices are still read in a non-C locale" "$out" "ethernet="

# --- fix round 2: the runner never takes a command from the caller's PATH ------
ev="$tmp/evil"
mkdir -p "$ev"
for n in grep head tr mktemp mv rm rmdir install cat sed cut sleep; do
  printf '#!/bin/sh\ntouch "%s/hit"\nexit 1\n' "$ev" >"$ev/$n"
  chmod +x "$ev/$n"
done
gscene ok ok
echo auto >"$GUARD_OVERRIDE"
with_evil_path() {
  local PATH="$ev:$PATH"
  grun >/dev/null
  grun >"$tmp/evil.out"
}
with_evil_path
expect_absent "$ev/hit" "PATH: a hostile directory on the caller's PATH is never used"
expect_contains "PATH: the run still works with that PATH" "$(cat "$tmp/evil.out")" "guard=on (healthy)"
expect_contains "unit: PATH is exactly the two system directories" "$(guard_service_text /a /b /c /d)" 'Environment="PATH=/usr/sbin:/usr/bin"'

# --- fix round 2: printed steps refuse symlinked directories and odd files -----
runsteps_t() { PATH="$sb:$gbin:$PATH" timeout 20 "$BASH" "$inst/$1.sh" >"$inst/$1.out" 2>&1; }
count_files() { find "$1" -mindepth 1 | wc -l; }
# a symlinked unit directory
guard_env
mv "$inst/root/units" "$inst/root/realunits"
ln -s realunits "$inst/root/units"
steps install
set +e
runsteps_t install
code=$?
set -e
expect_eq "install steps: a symlinked unit directory is refused" "$code" 1
expect_contains "install steps: the refusal names the symlink" "$(cat "$inst/install.out")" "symlink"
expect_eq "install steps: nothing was written through the symlinked unit directory" "$(count_files "$inst/root/realunits")" 0
# a symlinked parent of the libexec directory
guard_env
mkdir -p "$inst/realparent/libexec"
ln -s "$inst/realparent" "$inst/root/par"
export QUECTEL_GUARD_LIBEXEC_DIR="$inst/root/par/libexec"
steps install
set +e
runsteps_t install
code=$?
set -e
expect_eq "install steps: a symlinked parent directory is refused" "$code" 1
expect_eq "install steps: nothing was written through the symlinked parent" "$(count_files "$inst/realparent")" 1
# a symlinked libexec directory
guard_env
mkdir -p "$inst/elsewhere"
rmdir "$inst/root/libexec"
ln -s "$inst/elsewhere" "$inst/root/libexec"
steps install
set +e
runsteps_t install
code=$?
set -e
expect_eq "install steps: a symlinked libexec directory is refused" "$code" 1
expect_eq "install steps: nothing was written through the symlinked libexec directory" "$(count_files "$inst/elsewhere")" 0
# a symlinked override directory
guard_env
ln -s "$inst/elsewhere" "$inst/root/etc"
steps install
set +e
runsteps_t install
code=$?
set -e
expect_eq "install steps: a symlinked override directory is refused" "$code" 1
# the marker has to be the exact first line of a regular file
guard_env
steps install
printf 'one\ntwo\n# written by quectel-usbnet guard-install\n' >"$inst/root/units/quectel-modem-guard.service"
set +e
runsteps_t install
code=$?
set -e
expect_eq "install steps: a marker in the middle of a file is not ownership" "$code" 1
expect_eq "install steps: that file is left as it was" "$(head -n 1 "$inst/root/units/quectel-modem-guard.service")" one
guard_env
steps install
printf '# written by quectel-usbnet guard-install and then some\n' >"$inst/root/units/quectel-modem-guard.service"
set +e
runsteps_t install
code=$?
set -e
expect_eq "install steps: a first line that only starts with the marker is refused" "$code" 1
guard_env
steps install
mkfifo "$inst/root/units/quectel-modem-guard.timer"
set +e
runsteps_t install
code=$?
set -e
expect_eq "install steps: a FIFO at the destination is refused, not opened" "$code" 1
guard_env
steps install
printf '# written by quectel-usbnet guard-install\nold\n' >"$inst/root/units/quectel-modem-guard.service"
set +e
runsteps_t install
code=$?
set -e
expect_eq "install steps: a file with the exact marker line is accepted" "$code" 0
# uninstall: same rules
guard_env
steps install
runsteps_t install
mv "$inst/root/units" "$inst/root/realunits"
ln -s realunits "$inst/root/units"
steps uninstall
runsteps_t uninstall
if [ -e "$inst/root/realunits/quectel-modem-guard.service" ]; then
  ok "uninstall steps: a unit behind a symlinked directory is left alone"
else
  fail "uninstall steps: a unit behind a symlinked directory is left alone"
fi
expect_contains "uninstall steps: the symlinked directory is named" "$(cat "$inst/uninstall.out")" "sits under, a symlink"
guard_env
steps install
runsteps_t install
printf 'one\ntwo\n# written by quectel-usbnet guard-install\n' >"$inst/root/units/quectel-modem-guard.service"
rm -f "$inst/root/units/quectel-modem-guard.timer"
mkfifo "$inst/root/units/quectel-modem-guard.timer"
steps uninstall
set +e
runsteps_t uninstall
code=$?
set -e
expect_eq "uninstall steps: a FIFO does not hang or fail the uninstall" "$code" 0
expect_eq "uninstall steps: a marker in the middle is not ownership" "$(head -n 1 "$inst/root/units/quectel-modem-guard.service")" one
if [ -p "$inst/root/units/quectel-modem-guard.timer" ]; then
  ok "uninstall steps: the FIFO is left in place"
else
  fail "uninstall steps: the FIFO is left in place"
fi
# --- fix round 3: every directory in the chain is root-owned and closed --------
# the switch is documented, off by default, and never printed into the steps
guard_env
steps install
if grep -Eq '^(export )?QUECTEL_GUARD_TEST_TREE=' "$inst/install.sh"; then
  fail "dir owner: the test switch is never printed as set in the steps"
else
  ok "dir owner: the test switch is never printed as set in the steps"
fi
runsteps_strict() { env -u QUECTEL_GUARD_TEST_TREE PATH="$sb:$gbin:$PATH" timeout 20 "$BASH" "$inst/$1.sh" >"$inst/$1.out" 2>&1; }
set +e
runsteps_t install
code=$?
set -e
expect_eq "dir owner: with the test switch, a user-owned temp tree is accepted" "$code" 0
# default mode: a user-owned tree is refused before anything is written
guard_env
steps install
set +e
runsteps_strict install
code=$?
set -e
expect_eq "dir owner: by default a user-owned tree is refused" "$code" 1
expect_contains "dir owner: the refusal says not owned by root" "$(cat "$inst/install.out")" "not owned by root"
expect_eq "dir owner: nothing was written into the refused tree" "$(count_files "$inst/root/units") $(count_files "$inst/root/libexec")" "0 0"
# test mode, but a component is writable by group, then by others (also with the sticky bit)
for modebits in g+w o+w +t,o+w; do
  guard_env
  chmod "$modebits" "$inst/root/units"
  steps install
  set +e
  runsteps_t install
  code=$?
  set -e
  expect_eq "dir owner: a unit directory with mode change $modebits is refused" "$code" 1
  expect_contains "dir owner: that refusal says writable ($modebits)" "$(cat "$inst/install.out")" "writable by group or others"
done
# a writable parent in the chain, not only the leaf
guard_env
mkdir -p "$inst/root/par/sub"
chmod g+w "$inst/root/par"
export QUECTEL_GUARD_LIBEXEC_DIR="$inst/root/par/sub"
steps install
set +e
runsteps_t install
code=$?
set -e
expect_eq "dir owner: a group-writable parent of the destination is refused" "$code" 1
# uninstall refuses to remove from a chain that is not closed
guard_env
steps install
runsteps_t install
chmod o+w "$inst/root/units"
steps uninstall
runsteps_t uninstall
if [ -e "$inst/root/units/quectel-modem-guard.service" ]; then
  ok "dir owner: uninstall leaves a unit in a world-writable directory"
else
  fail "dir owner: uninstall leaves a unit in a world-writable directory"
fi
chmod o-w "$inst/root/units"
# Another uid without root: real root-owned directories against a user-owned one,
# through the printed helper itself (sudo is a pass-through function here).
helpers_check() {
  local rc=0
  # shellcheck disable=SC2329 # called by the eval-ed helper functions, not directly
  sudo() { "$@"; }
  eval "$(guard_helpers_text)"
  (
    unset QUECTEL_GUARD_TEST_TREE
    safe_dir "$1" 2>/dev/null
  ) || rc=1
  unset -f sudo
  return "$rc"
}
for d in /usr/lib /usr/bin; do
  if [ -d "$d" ] && [ "$(stat -c '%u' "$d")" = 0 ] && [ -z "$(find "$d" -maxdepth 0 -perm /022)" ] && [ "$(readlink -f "$d")" = "$d" ]; then
    if helpers_check "$d"; then
      ok "dir owner: the real root-owned directory $d is accepted"
    else
      fail "dir owner: the real root-owned directory $d is accepted"
    fi
  fi
done
if helpers_check /tmp; then
  fail "dir owner: /tmp (world-writable, sticky) is refused"
else
  ok "dir owner: /tmp (world-writable, sticky) is refused"
fi
if [ -d "$HOME" ] && [ "$(readlink -f "$HOME")" = "$HOME" ] && [ -z "$(find "$HOME" -maxdepth 0 -perm /022)" ] && [ "$(stat -c %u "$HOME")" != 0 ]; then
  # closed to group and others, so only the owner check can refuse it
  if helpers_check "$HOME"; then
    fail "dir owner: a closed directory owned by an ordinary user is refused on ownership alone"
  else
    ok "dir owner: a closed directory owned by an ordinary user is refused on ownership alone"
  fi
fi
if helpers_check "$inst/root/units"; then
  fail "dir owner: a directory owned by another uid than root is refused"
else
  ok "dir owner: a directory owned by another uid than root is refused"
fi
unset QUECTEL_GUARD_UNIT_DIR QUECTEL_GUARD_LIBEXEC_DIR QUECTEL_GUARD_OVERRIDE_DIR QUECTEL_GUARD_STATE_DIR QUECTEL_GUARD_TEST_TREE
expect_eq "script: line 2 is the marker the installed copy is recognized by" "$(sed -n 2p "$TOOL")" "$GUARD_COPY_LINE"

# --- fix round 1: the real ruleset in a throwaway network namespace ------------
# Skipped where unshare, nft, ip or python3 is missing or user namespaces are
# not allowed. The namespace is private: nothing here touches the host network.
if command -v unshare >/dev/null 2>&1 && command -v nft >/dev/null 2>&1 &&
  command -v ip >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 &&
  unshare -rn true >/dev/null 2>&1; then
  set +e
  nsout=$(unshare -rn "$BASH" "$HERE/ns_guard.sh" "$TOOL" 2>&1)
  set -e
  nsn=0
  while IFS= read -r line; do
    case $line in
      "PASS "*)
        ok "namespace: ${line#PASS }"
        nsn=$((nsn + 1))
        ;;
      "FAIL "*)
        fail "namespace: ${line#FAIL }"
        nsn=$((nsn + 1))
        ;;
      "SKIP "*) echo "skip ${line#SKIP }" ;;
    esac
  done <<<"$nsout"
  if [ "$nsn" -lt 10 ]; then
    fail "namespace: the checks ran" "only $nsn results: $nsout"
  fi
else
  echo "skip namespace tests: unshare, nft, ip, python3 or user namespaces are not available"
fi

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
