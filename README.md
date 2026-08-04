# Leak-Proof Travel Router with a Tailscale Exit Node

Turn a **GL.iNet travel router** into a device that tunnels all your traffic to a home exit node, **fails closed** if the tunnel drops, and keeps a second SSID that goes out directly so you can still clear captive portals and debug.

**→ [GUIDE.md](GUIDE.md)** is the setup guide.
**→ [healthcheck.sh](healthcheck.sh)** verifies a working install.

---

## Why this exists

Plenty of write-ups tell you to install Tailscale on a GL.iNet router and pick an exit node. In practice that alone gives you one of two outcomes:

- **A total LAN outage**, because the firmware provides no NAT rule for traffic leaving `tailscale0`, so the exit node discards your clients' packets; or
- **A silent leak**, because nothing enforces that traffic *must* use the tunnel, and a setting that quietly reverts leaves you browsing the hotel's network while everything looks fine.

This guide covers the parts that are easy to miss:

- The firmware runs `tailscale up --reset` on network reloads, **destroying manually-set preferences** — so the exit node must be configured through its own UCI option instead.
- **SNAT is required and the firmware does not create it.**
- A kill switch **cannot cover DNS**, because the resolver's queries originate from the router rather than being forwarded.
- The guest bypass rule is **flushed by every WAN change** — i.e. at every hotel check-in — and nothing puts it back.

Each of those was found by breaking a real setup, not by reading documentation.

## The design

| SSID | Network | Subnet | Behavior |
|---|---|---|---|
| tunneled (2.4G + 5G) | `lan` | `192.168.66.0/24` | Everything via the exit node; **kill-switched** |
| direct (2.4G + 5G) | `guest` | `192.168.9.0/24` | Straight out to the local network |

The second network is not a convenience. A kill switch that fails closed is only safe if you keep a way to reach captive portals and debug a broken tunnel.

## Verification

Testing this at home is misleading: tunneled and direct traffic exit the same public IP, so `ifconfig.me` cannot tell them apart. The guide covers using `traceroute` as a discriminator that works anywhere, and how to confirm results with **router-side packet counters** rather than trusting client-side success or failure.

```
$ ./healthcheck.sh 100.x.y.z
  PASS  exit node in UCI
  PASS  exit node active
  PASS  SNAT present
  PASS  kill switch intact (no lan->wan)
  PASS  guest bypass present
  PASS  table 52 has default route
  PASS  lan DHCP resolver set
  PASS  guest DHCP resolver set
  PASS  hotplug refresh installed
  PASS  hotplug registered in keep.d
```

Every check corresponds to something that broke at least once during development.

## Tested on

- **GL.iNet GL-MT3000 (Beryl AX)**, firmware **4.8.1** — OpenWrt 21.02, fw3/iptables, bundled Tailscale 1.80.3
- Verified end-to-end against a foreign upstream on a different ISP behind a captive portal

Most of it applies to any GL.iNet 4.x device. Version-specific behavior is called out in the guide.

## Caveats

- **This disagrees with the vendor's intended design in one place.** GL.iNet expects you to *approve* the router's advertised LAN route so the exit node accepts unSNATed traffic. This guide uses SNAT instead and leaves those routes unapproved — approving them would make whatever hotel subnet you are on routable across your entire tailnet. The reasoning is spelled out so you can decide differently.
- **The two load-bearing facts are firmware behaviors** (`gl_tailscale` calling `--reset`, and the absent SNAT). GL.iNet could change either. Verify `/usr/bin/gl_tailscale` still behaves as described rather than trusting this blindly.
- **A single exit node is a single point of failure.** If it goes down while you are away, the tunneled SSID stays dead until you are home. `--exit-node=auto:any` gives failover, but needs a second exit node to be worth anything.

## License

MIT.
