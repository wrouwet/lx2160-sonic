#!/bin/sh
# test host A side of the SONiC/LX2160ARDB test setup (run once with sudo).
# The test host A's wired port is cabled to the board's DPMAC17 (SONiC Ethernet0).
#   - installs the test tools: lldpd, frr, iperf3, scapy, tcpdump
#   - creates two network namespaces with VLAN subinterfaces on the wired port:
#       ns-v10: <ifc>.10  192.168.10.2/24, default route via 192.168.10.1 (SONiC Vlan10)
#       ns-v20: <ifc>.20  192.168.20.2/24, default route via 192.168.20.1 (SONiC Vlan20)
#     so traffic between them is routed by SONiC (real transit path, one cable)
#   - lets user $SUDO_USER run the test tools (ping, iperf3, FRR zebra/bgpd,
#     lldpd/lldpcli) in these namespaces without a password; nothing else
# Adds only; leaves the untagged shared-connection connection on the port alone.
# Undo: sudo test-host-a-testbed.sh --remove
set -eu

IFC=${IFC:-enp0s31f6}
USER_NAME=${SUDO_USER:?run with sudo}
SUDOERS=/etc/sudoers.d/91-lx2160-testbed

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

if [ "${1:-}" = "--remove" ]; then
	for v in 10 20; do ip netns del ns-v$v 2>/dev/null || true; done
	rm -f "$SUDOERS"
	echo "testbed removed (packages left installed)"
	exit 0
fi

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lldpd frr iperf3 python3-scapy tcpdump >/dev/null
# FRR and lldpd run inside the namespaces / on demand, not as host services
systemctl disable --now frr >/dev/null 2>&1 || true

for v in 10 20; do
	ns=ns-v$v
	ip netns del $ns 2>/dev/null || true
	ip netns add $ns
	ip link add link "$IFC" name "$IFC.$v" type vlan id $v
	ip link set "$IFC.$v" netns $ns
	ip -n $ns link set lo up
	ip -n $ns link set "$IFC.$v" name v$v up
	ip -n $ns addr add 192.168.$v.2/24 dev v$v
	ip -n $ns route add default via 192.168.$v.1
done

# Only the test tools, not "any command in the namespace" (that would be root).
# Deliberately not ip (ip netns exec runs anything), tcpdump (-z runs a
# program) or vtysh (can start a shell): FRR is configured via files instead.
CMDS=""
for ns in ns-v10 ns-v20; do
	for c in "/usr/bin/ping *" "/usr/bin/iperf3 *" "/usr/lib/frr/zebra *" "/usr/lib/frr/bgpd *" \
		"/usr/sbin/lldpd *" "/usr/sbin/lldpcli *"; do
		CMDS="$CMDS, /usr/bin/ip netns exec $ns $c"
	done
done
cat > "$SUDOERS" <<EOF
# lx2160-sonic testbed: test tools inside the test namespaces, no password
$USER_NAME ALL=(root) NOPASSWD: ${CMDS#, }
EOF
chmod 440 "$SUDOERS"
visudo -c -q

ip -br addr show dev "$IFC"
for v in 10 20; do ip -n ns-v$v -br addr; done
echo "testbed ready: ns-v10 (192.168.10.2), ns-v20 (192.168.20.2) on $IFC"
