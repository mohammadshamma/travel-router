# Leak-Proof Travel Router with a Tailscale Exit Node

A guide for turning a **GL.iNet travel router** into a device that tunnels all your traffic to a home exit node, **fails closed** if the tunnel drops, and keeps a second SSID that goes out directly so you can still fix things.

Written against a **GL.iNet GL-MT3000 (Beryl AX), firmware 4.8.1** (OpenWrt 21.02, fw3/iptables, bundled Tailscale 1.80.3). Most of it applies to any GL.iNet 4.x device. Where behavior is version-specific it is called out.

> **Read §3 before you configure the exit node.** GL.iNet's firmware actively resets manual Tailscale settings, and there is a required NAT rule the firmware does not create. Skipping either produces a total LAN outage or a silent leak.

---

## The design

| SSID | Network | Zone | Subnet | Behavior |
|---|---|---|---|---|
| `<TUNNELED_SSID>` (2.4G + 5G) | LAN | `lan` | `192.168.66.0/24` | Everything tunneled; **kill-switched** |
| `<DIRECT_SSID>` (2.4G + 5G) | guest | `guest` | `192.168.9.0/24` | Straight out to the local network |

Stock firmware already provides both zones, so this needs no extra VAP work.

**Why two networks.** A kill switch that fails closed is only safe if you retain a way to debug and to clear captive portals. The guest SSID is not a convenience — it is the recovery path, and captive portals routinely refuse to load behind a tunnel.

### The three failure modes

| | Scenario | Behavior |
|---|---|---|
| **A** | Exit node set, goes offline | Fails **closed** — route stays in the tunnel, packets dropped. No internet, no leak. |
| **B** | Exit node never set, or the setting silently reverted | Fails **open** — the router NATs to the local WAN normally. Everything looks fine while you browse in the clear. **This is the real risk.** |
| **C** | Pointed at a node that is not an approved exit node | Fails **loudly at setup time** — the CLI validates against the netmap and errors. |

The whole design converts **B** into **A**.

---

## 1. Create an exit node at home

You need a machine at home advertising as an exit node. A dedicated always-on box (Pi, mini-PC) beats a workstation, but any always-on machine works.

```bash
tailscale set --advertise-exit-node
```

Then **approve it** — advertising alone does nothing:

**login.tailscale.com/admin/machines** → your node → **⋯** → **Edit route settings** → **Use as exit node**

Also **⋯ → Disable key expiry**. Default expiry is 180 days; you do not want that firing mid-trip.

> Key expiry can **only** be changed in the admin console — not the router UI, not the desktop app. This trips people up repeatedly.

If it is a Mac, disable system sleep (`pmset -g` should show `sleep 0`). If it is a desktop, enable auto-restart after power failure.

**Gate:** `tailscale exit-node list` must show the node before you continue. This is what makes failure mode C impossible later.

**Smoke-test it** from another machine before touching the router:

```bash
tailscale set --exit-node=<EXIT_NODE_TS_IP> --exit-node-allow-lan-access
tailscale status | grep "exit node"     # look for tx/rx counters climbing
tailscale set --exit-node=              # revert
```

---

## 2. Router base configuration

1. **Update firmware** (SYSTEM → Upgrade). The Tailscale exit-node selector only exists on newer 4.x builds.
2. **Change the LAN subnet off the default.** Hotels use `192.168.8.x` and `192.168.1.x` constantly, and a collision in repeater mode fails in confusing ways.

   Network → LAN → `192.168.66.1`. Also update GL.iNet's admin hostname records:

   ```bash
   uci set network.lan.ipaddr='192.168.66.1'
   uci set dhcp.@domain[0].ip='192.168.66.1'
   uci set dhcp.@domain[1].ip='::ffff:192.168.66.1'
   uci commit network; uci commit dhcp
   /etc/init.d/network reload; /etc/init.d/dnsmasq restart
   ```

3. **Name the four SSIDs and enable the guest network.** Give the bands distinct names — repeater mode channel-locks whichever radio is repeating, so you will want to steer devices off it.

   ```bash
   uci set wireless.wifi2g.ssid='<TUNNELED_SSID>'
   uci set wireless.wifi5g.ssid='<TUNNELED_SSID>-5g'
   uci set wireless.guest2g.ssid='<DIRECT_SSID>'
   uci set wireless.guest5g.ssid='<DIRECT_SSID>-5g'
   uci set wireless.guest2g.disabled='0'
   uci set wireless.guest5g.disabled='0'
   uci set network.guest.disabled='0'
   uci commit wireless; uci commit network
   wifi reload
   ```

   Set a strong guest key (`wireless.guest{2g,5g}.key`) — this SSID gets broadcast in hotel corridors.

> **Do not reuse an existing SSID name for the guest network.** Devices with that profile saved would silently auto-join the *untunneled* network. Saved profiles should point at the protected one.

---

## 3. Tailscale on the router — the part that matters

Tailscale ships in firmware 4.x; nothing to install.

**First-time login requires working internet.** Onboard at home — you cannot bootstrap this from a hotel room.

```bash
uci set tailscale.settings.enabled='1'
uci commit tailscale
/etc/init.d/tailscale start
tailscale up          # open the printed URL and authorize
```

Leave **"Allow Remote Access LAN"** off — it advertises the travel router's subnet into your tailnet, the opposite of what you want. Don't run GL.iNet's WireGuard/OpenVPN client at the same time; it contends for the default route.

Then **⋯ → Disable key expiry** on the new router node.

### 3a. Set the exit node via UCI, NOT `tailscale set`

`/usr/bin/gl_tailscale` (run as `gl_tailscale restart`) executes:

```sh
timeout 10 /usr/sbin/tailscale up --reset --accept-routes $param --timeout 3s --accept-dns=false
```

**`--reset` wipes every preference you don't restate**, so a manual `tailscale set --exit-node=...` is destroyed on the next network reload. Use GL.iNet's own option instead:

```bash
uci set tailscale.settings.exit_node_ip='<EXIT_NODE_TS_IP>'
uci commit tailscale
gl_tailscale restart
```

The script then supplies `--exit-node-allow-lan-access --exit-node=...` every time it runs. The mechanism that destroys manual config becomes the mechanism that maintains yours.

It also installs the **guest bypass** (`from 192.168.9.0/24 lookup main`) and an exit-node rule at the correct priority, both derived at runtime.

> `/etc/init.d/tailscale` never calls `tailscale up` — it only launches the daemon. So *boot* is not the risk; *network reload* is.

### 3b. Add the SNAT rule — the firmware does not

**Without this, every LAN client loses internet the moment you set an exit node.**

Client packets enter the tunnel with source `192.168.66.x`; the exit node drops them for failing its source check. GL.iNet's `zone_tailscale0_postrouting` contains no masquerade.

Append to `/etc/firewall.user` (fw3 re-runs it on every reload):

```sh
iptables -t nat -C POSTROUTING -o tailscale0 -j MASQUERADE 2>/dev/null || \
	iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
```

> **Why not GL.iNet's way?** Their design expects you to *approve* the advertised LAN route so the exit node accepts unSNATed traffic (hence the script force-setting `lan_enabled=1`). Don't. Approving it makes whatever hotel subnet you're on routable across your whole tailnet. **Leave the router's pending route requests unapproved** and use SNAT instead.

---

## 4. DNS — the leak the kill switch cannot catch

Clients query the router's dnsmasq, but **dnsmasq's upstream queries originate from the router itself** — OUTPUT chain, not FORWARD — so a `lan -> wan` firewall rule never touches them. Left alone, every domain you visit goes to the hotel's resolver while your traffic is tunneled.

Hand clients an external resolver directly, turning lookups into *forwarded* traffic the kill switch does protect:

```bash
uci add_list dhcp.lan.dhcp_option='6,1.1.1.1,1.0.0.1'
uci add_list dhcp.guest.dhcp_option='6,1.1.1.1,1.0.0.1'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

**Set it on guest too.** Networks hand out ISP-specific resolvers (Comcast's `75.75.75.75`, etc.) that only answer their own customers. Guest clients relying on dnsmasq will have **no DNS at all** when the upstream ISP differs from yours. Verified failure:

```
nslookup example.com 1.1.1.1      → answers
nslookup example.com 75.75.75.75  → connection timed out   (queried from a different ISP)
```

Cost: clients lose `*.ts.net` resolution. Minor.

**IPv6:** confirm `dhcpv6` and `ra` are `disabled` on the LAN interface, or apply the kill switch to `ip6tables` as well — a v4-only rule leaves a v6 bypass.

---

## 5. The kill switch

Delete the `lan -> wan` forwarding. That leaves the LAN exactly one way out — `tailscale0`.

```bash
# find it by value, not index
i=0
while uci -q get firewall.@forwarding[$i] >/dev/null 2>&1; do
	if [ "$(uci -q get firewall.@forwarding[$i].src)" = "lan" ] && \
	   [ "$(uci -q get firewall.@forwarding[$i].dest)" = "wan" ]; then
		uci delete firewall.@forwarding[$i]; break
	fi
	i=$((i+1))
done
uci commit firewall
/etc/init.d/firewall reload
gl_tailscale restart      # fw3 rebuilds root chains and drops Tailscale's jumps
```

Keep `guest -> wan` (your recovery path) and `lan -> tailscale0`.

**This does not break the tunnel.** Tailscale's encrypted packets originate from the router (OUTPUT); client traffic is forwarded (FORWARD). Also `ts-forward` already contains `-o tailscale0 -j ACCEPT`, which runs before fw3's DROP.

> **Do this last**, after the tunnel demonstrably works — otherwise you cut the connection you are configuring over.
>
> **A fw3 reload flushes Tailscale's root-chain jumps.** Always follow it with `gl_tailscale restart`.

---

## 6. Survive WAN changes (required for real travel)

**Repointing the repeater flushes the guest bypass rule, and nothing reinstates it.** Guest traffic then falls to table 52 → `tailscale0` → dropped (there is no `guest -> tailscale0` forwarding). You lose your recovery network at every check-in, silently.

Create `/etc/hotplug.d/iface/99-tailscale-refresh`:

```sh
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
case "$INTERFACE" in
	wan|wwan|wan6|tethering) ;;
	*) exit 0 ;;
esac
[ -n "$(uci -q get tailscale.settings.exit_node_ip)" ] || exit 0
logger -t tailscale-refresh "ifup on $INTERFACE - scheduling gl_tailscale restart"
(
	sleep 12
	/usr/bin/gl_tailscale restart >/dev/null 2>&1
	logger -t tailscale-refresh "done; guest rule count=$(ip rule show | grep -c 192.168.9)"
) &
```

```bash
chmod +x /etc/hotplug.d/iface/99-tailscale-refresh
mkdir -p /lib/upgrade/keep.d
echo "/etc/hotplug.d/iface/99-tailscale-refresh" > /lib/upgrade/keep.d/tailscale-travel
```

The `keep.d` entry makes firmware updates preserve it. Verify it fired with `logread | grep tailscale-refresh`.

---

## 7. Verification — and how to avoid fooling yourself

**At home, tunneled and direct traffic exit the same public IP.** `ifconfig.me` cannot tell them apart. Two ways to get a real answer:

**Traceroute** distinguishes them anywhere:

```bash
traceroute -n 8.8.8.8
# tunneled: hop 1 is the router, then silence (the exit node forwards in
#           userspace and emits no ICMP time-exceeded)
# direct:   hop 2 is your local ISP gateway
```

**Or test against a genuinely foreign upstream** — a phone hotspot or another building's WiFi. Then public IPs differ and become meaningful.

Full check, from the tunneled SSID with the router on a foreign upstream:

```bash
curl -s https://api.ipify.org                                  # must be HOME's IP
dig +short TXT o-o.myaddr.l.google.com @ns1.google.com         # must be HOME's IP
traceroute -n 8.8.8.8                                          # dark after the router
ping <upstream_gateway>                                        # must FAIL
```

That last one is a good kill-switch proof: the upstream subnet is `throw`-routed, so reaching it requires the `lan -> wan` path you deleted.

### Traps that produce false results

- **`tailscale down` refuses when you are connected over Tailscale** (`use --accept-risk=lose-ssh`). A kill-switch test that appears to "leak" may simply be a no-op. Check for the warning.
- **Your laptop may silently roam** to another known network during a router reboot. Always confirm which SSID and subnet you are actually on before believing a result.
- **Prefer router-side evidence.** Client-side success/failure is ambiguous. Count packets instead:

  ```bash
  iptables -N PROBE; iptables -I FORWARD 1 -s <client> -d <dest>/24 -j PROBE
  iptables -Z FORWARD           # zero, generate traffic, then:
  iptables -L FORWARD -v -n | grep PROBE
  ```

  An empty chain counts without altering flow. This distinguishes "the router dropped it" from "the client never sent it" — a distinction that matters more than you would expect.

### Reboot test

Reboot and confirm, unattended: exit node active, SNAT present, no `lan -> wan`, guest bypass present, `table 52` has a default route, DHCP options intact.

---

## 8. Making remote changes safely

When reconfiguring a router over the link you are reconfiguring, arm a dead-man's switch first:

```bash
printf '#!/bin/sh\nsleep 240\ngl_tailscale restart\n' > /tmp/restore.sh
chmod +x /tmp/restore.sh
start-stop-daemon -S -b -m -p /tmp/restore.pid -x /tmp/restore.sh
# ... make the change, verify ...
kill $(cat /tmp/restore.pid)   # disarm only once a NEW connection succeeds
```

Notes: busybox has no `nohup` or `setsid`; use `start-stop-daemon -b`. Point `-x` at your script, not `/bin/sh`, or it refuses with "already running". For changes that restart radios, write a self-verifying script that restores its own backup on failure and launch it detached — a command chain dies with your SSH session; a detached script does not.

Size the timer generously. A 150s timer is easily shorter than the gap between steps, and it will revert your change while you are still looking at it.

---

## Hotel-day runbook

1. Join the **tunneled** SSID, open `http://192.168.66.1` → **Internet → Repeater** → connect to hotel WiFi. Admin access is local, so it works with no internet.
2. **The tunneled SSID goes dark.** Expected — that is the kill switch.
3. Join the **direct** SSID and clear the captive portal there. Anything behind the router authenticates the router's own MAC.
4. Return to the tunneled SSID and verify your public IP reads home.
5. If step 4 shows the hotel's IP — **stop**. That is a leak.

Guest cannot reach the admin UI (`input=REJECT` on that zone) and the tunneled SSID cannot reach the portal. **You need both networks, in that order.**

Other field notes: use **MAC Clone** if the hotel authenticates or charges per device. Drop MTU toward ~1280 if TLS stalls. If the tunneled SSID is dead, that is the kill switch working — debug from the direct SSID.

---

## Known limitations

- **Single exit node is a single point of failure.** If it goes down while you are away, the tunneled SSID stays dead until you are home. `--exit-node=auto:any` provides failover but needs a second exit node to be worth anything.
- **Repeater mode channel-locks one radio**, costing throughput on SSIDs sharing it.
- **The bundled Tailscale lags upstream** and the admin console will flag it. Advisory. Feeds point at `fw.gl-inet.com`, so the only supported upgrade is a firmware update — hand-installing an upstream binary fights the `gl_tailscale` integration this whole setup depends on.
- **Back up before firmware updates:** `sysupgrade -b /tmp/backup.tar.gz`. `/etc/config/*`, `/etc/firewall.user` and anything in `keep.d` are preserved, but verify afterward regardless.
