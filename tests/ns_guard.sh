#!/usr/bin/env bash
# The real nft ruleset, loaded into a throwaway network namespace. Run by
# tests/run.sh as `unshare -rn bash tests/ns_guard.sh TOOL`: the namespace is
# private and has only a dummy interface, so nothing here touches the host.
# Prints "PASS name" or "FAIL name (detail)" per check.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$HERE/ns_probe.py"
# shellcheck source=quectel-usbnet
source "$1"
set +e +u
set +o pipefail

check() {
  if [ "$2" = "$3" ]; then
    echo "PASS $1"
  else
    echo "FAIL $1 (wanted $3, got $2)"
  fi
}

probe() { python3 -I "$PROBE" "$@"; }

ip link set lo up || exit 0
ip link add wwan0 type dummy || exit 0
ip link set wwan0 up
ip addr add 192.0.2.2/24 dev wwan0
ip -6 addr add 2001:db8::2/64 dev wwan0 nodad
ip route add default via 192.0.2.1 dev wwan0
ip -6 route add default via 2001:db8::1 dev wwan0

# Before the table: everything leaves the interface (nothing answers).
check "before the table, IPv4 leaves" "$(probe 4 198.51.100.7 9000 -)" passed
check "before the table, IPv6 leaves" "$(probe 6 2001:db8:ffff::7 9000 -)" passed

# The real ruleset loads, and loads again over itself (one atomic replace).
guard_ruleset wwan0 | nft -f -
check "the real ruleset loads" "$?" 0
guard_ruleset wwan0 | nft -f -
check "the ruleset reloads over itself" "$?" 0

check "armed: IPv4 is rejected" "$(probe 4 198.51.100.7 9000 -)" rejected
check "armed: IPv6 is rejected" "$(probe 6 2001:db8:ffff::7 9000 -)" rejected
check "armed: a UDP packet to port 67 from a random port is rejected" "$(probe 4 255.255.255.255 67 -)" rejected
check "armed: a UDP packet to port 67 of a unicast host is rejected" "$(probe 4 192.0.2.1 67 68)" rejected
check "armed: a UDP packet from port 68 to a wrong port is rejected" "$(probe 4 255.255.255.255 9000 68)" rejected
check "armed: DHCPv4 shape (68 to 67, limited broadcast) passes" "$(probe 4 255.255.255.255 67 68)" passed
check "armed: a UDP packet to port 547 from a random port is rejected" "$(probe 6 ff02::1:2 547 -)" rejected
check "armed: a UDP packet 546 to 547 of a global host is rejected" "$(probe 6 2001:db8::5 547 546)" rejected
check "armed: DHCPv6 shape (546 to 547, All_DHCP_Relay_Agents) passes" "$(probe 6 ff02::1:2 547 546)" passed
check "armed: DHCPv6 shape to a link-local server passes" "$(probe 6 fe80::1 547 546)" passed

# Delete opens the guard.
nft delete table inet quectel_modem_guard
check "delete table succeeds" "$?" 0
check "after delete, IPv4 leaves again" "$(probe 4 198.51.100.7 9000 -)" passed
check "after delete, IPv6 leaves again" "$(probe 6 2001:db8:ffff::7 9000 -)" passed

# The dead-man switch: with nothing refreshing it, the rules expire.
GUARD_TTL=3
guard_ruleset wwan0 | nft -f -
check "a fresh table rejects" "$(probe 4 198.51.100.7 9000 -)" rejected
read -r -t 5 <> <(:)
check "after the TTL with no refresh, the guard is inert" "$(probe 4 198.51.100.7 9000 -)" passed
check "after the TTL, IPv6 leaves too" "$(probe 6 2001:db8:ffff::7 9000 -)" passed
nft delete table inet quectel_modem_guard
