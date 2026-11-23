#!/bin/sh
# Test host side of the SONiC/LX2160ARDB test setup (run once with sudo).
#   - installs the test tools: lldpd, frr, iperf3, scapy, tcpdump
#   - ROLE=a (default), test host A, wired port cabled to DPMAC17 (SONiC
#     Ethernet0): two network namespaces with VLAN subinterfaces on the port
#       ns-v10: <ifc>.10  192.168.10.2/24, default route via 192.168.10.1 (SONiC Vlan10)
#       ns-v20: <ifc>.20  192.168.20.2/24, default route via 192.168.20.1 (SONiC Vlan20)
#     so traffic between them is routed by SONiC (real transit path, one
#     cable). Adds only; leaves any untagged connection on the port alone.
#   - ROLE=b, test host B, wired port cabled to DPMAC18 (SONiC Ethernet4,
#     a routed port): the port itself moves into namespace ns-b with
#     192.168.50.2/24 and 2001:db8:50::2/64, default routes via SONiC
#     (192.168.50.1, 2001:db8:50::1). The host's own network stack no longer
#     sees the port until --remove.
#   - lets user $SUDO_USER run the test tools (ping, iperf3, FRR zebra/bgpd,
#     lldpd/lldpcli) in these namespaces without a password; nothing else
# Undo (either role): sudo test-host-setup.sh --remove
set -eu

ROLE=${ROLE:-a}
USER_NAME=${SUDO_USER:?run with sudo}
SUDOERS=/etc/sudoers.d/91-lx2160-testbed

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

if [ "${1:-}" = "--remove" ]; then
	# deleting ns-b returns the physical port to the host
	for ns in ns-v10 ns-v20 ns-b; do ip netns del $ns 2>/dev/null || true; done
	rm -f "$SUDOERS"
	echo "testbed removed (packages left installed)"
	exit 0
fi

IFC=${IFC:?set IFC to the wired port cabled to the board, e.g. IFC=eth1}
case $ROLE in
a) NAMESPACES="ns-v10 ns-v20" ;;
b) NAMESPACES="ns-b" ;;
*) echo "ROLE must be a or b" >&2; exit 1 ;;
esac

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lldpd frr iperf3 python3-scapy tcpdump >/dev/null
# FRR and lldpd run inside the namespaces / on demand, not as host services
systemctl disable --now frr >/dev/null 2>&1 || true

if [ "$ROLE" = a ]; then
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
else
	ns=ns-b
	ip netns del $ns 2>/dev/null || true
	ip netns add $ns
	ip link set "$IFC" netns $ns
	ip -n $ns link set lo up
	ip -n $ns link set "$IFC" up
	ip -n $ns addr add 192.168.50.2/24 dev "$IFC"
	ip -n $ns addr add 2001:db8:50::2/64 dev "$IFC" nodad
	ip -n $ns route add default via 192.168.50.1
	ip -n $ns -6 route add default via 2001:db8:50::1
fi

# Only the test tools, not "any command in the namespace" (that would be root).
# Deliberately not ip (ip netns exec runs anything), tcpdump (-z runs a
# program) or vtysh (can start a shell): FRR is configured via files instead.
CMDS=""
for ns in $NAMESPACES; do
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

for ns in $NAMESPACES; do ip -n $ns -br addr; done
echo "testbed ready (role $ROLE): $NAMESPACES"
