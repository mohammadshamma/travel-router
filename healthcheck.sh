#!/bin/sh
# Verify a GL.iNet travel router's Tailscale exit-node setup is fully intact.
# Each check below corresponds to something that broke at least once during setup.
#
# Usage:  ./healthcheck.sh [router-address]
# Default address is the router's Tailscale IP; override for LAN use.

R="${1:-<ROUTER_TAILSCALE_IP>}"

if [ "$R" = "<ROUTER_TAILSCALE_IP>" ]; then
	echo "Set the router address: ./healthcheck.sh 100.x.y.z   (or edit the default in this file)"
	exit 2
fi

ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$R" 'sh -s' <<"REMOTE"
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

echo "=== Travel router health check ==="
echo "firmware $(cat /etc/glversion 2>/dev/null) | tailscale $(tailscale version 2>/dev/null | head -1)"
echo

# 1. Exit node configured in UCI (survives gl_tailscale's `up --reset`)
EN=$(uci -q get tailscale.settings.exit_node_ip)
[ -n "$EN" ] && ok "exit node in UCI ($EN)" || bad "exit node NOT set in UCI - will not survive reload"

# 2. Exit node actually in use right now
tailscale status 2>/dev/null | grep -qi "active; exit node" \
	&& ok "exit node active" \
	|| bad "exit node NOT active - traffic is not being tunneled"

# 3. SNAT for LAN clients (firmware does not provide this)
iptables -t nat -S POSTROUTING 2>/dev/null | grep -q "tailscale0 -j MASQUERADE" \
	&& ok "SNAT present" \
	|| bad "SNAT MISSING - LAN clients will have no internet"

# 4. Kill switch: no lan->wan forwarding path
LW=0; i=0
while uci -q get firewall.@forwarding[$i] >/dev/null 2>&1; do
	[ "$(uci -q get firewall.@forwarding[$i].src)" = "lan" ] &&
		[ "$(uci -q get firewall.@forwarding[$i].dest)" = "wan" ] && LW=1
	i=$((i+1))
done
[ "$LW" = "0" ] && ok "kill switch intact (no lan->wan)" || bad "LEAK: lan->wan forwarding EXISTS"

# 5. Guest bypass (flushed by every WAN change)
GN=$(uci -q get network.guest.ipaddr | cut -d. -f1-3)
ip rule show 2>/dev/null | grep -q "from ${GN}.0/24 lookup main" \
	&& ok "guest bypass present" \
	|| bad "guest bypass MISSING - recovery SSID is dead"

# 6. Default route inside the tunnel table
ip route show table 52 2>/dev/null | grep -q "^default" \
	&& ok "table 52 has default route" \
	|| bad "table 52 has NO default route"

# 7. DNS handed to clients directly (kill switch cannot cover dnsmasq's upstream)
for N in lan guest; do
	uci -q get dhcp.$N.dhcp_option | grep -q "^6," \
		&& ok "$N DHCP resolver set" \
		|| bad "$N DHCP resolver NOT set - DNS will leak or fail"
done

# 8. Hotplug refresh installed and preserved across firmware updates
[ -x /etc/hotplug.d/iface/99-tailscale-refresh ] \
	&& ok "hotplug refresh installed" \
	|| bad "hotplug refresh MISSING - guest bypass will die on WAN change"
[ -f /lib/upgrade/keep.d/tailscale-travel ] \
	&& ok "hotplug registered in keep.d" \
	|| bad "hotplug NOT in keep.d - a firmware update will drop it"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && echo "Healthy." || echo "Fix the failures above before travelling."
exit $FAIL
REMOTE
