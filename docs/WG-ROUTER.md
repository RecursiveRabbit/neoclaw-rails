# WG-Router: Zero-Forward Host Architecture

## The Problem

The original design used the host kernel as a router. All WireGuard interfaces lived on the host, `ip_forward=1` was required, and the kernel could route packets between interfaces. This created two issues:

1. **Bridge back door.** Agent containers had a default route through the podman bridge (10.88.0.0/16). The host was on that bridge. An agent could reach any host-local WG IP through the bridge — bypassing WireGuard authorization entirely. Fixed with an iptables INPUT rule, but the fix was a patch for a design flaw.

2. **Cross-interface leakage.** With forwarding enabled, any misconfiguration could allow traffic to cross between WG interfaces the host kernel happened to know about. Source-based policy routing mitigated this but added complexity.

## The Solution

**The host kernel forwards nothing.** `ip_forward=0`. Each WireGuard interface is a dead-end point-to-point tunnel. Packets arrive, get delivered to the local service, and never cross interfaces.

A dedicated **wg-router container** is the only thing in the system that forwards traffic. It's an explicit, auditable, firewallable chokepoint.

## Architecture

### Host (ip_forward=0)

The host runs WireGuard interfaces as point-to-point tunnels:

```
wg-hub      10.0.0.1  ←→  Hub/Agents/Manager (messages and callbacks)
wg-git      10.0.0.3  ←→  Forgejo (anyone peered)
wg-valley   10.0.0.4  ←→  Evennia (anyone peered)
wg-vikunja  10.0.0.5  ←→  Vikunja (anyone peered)
wg-comfyui  10.0.0.6  ←→  ComfyUI (anyone peered)
wg-matrix   10.0.0.7  ←→  Synapse (anyone peered)
wg-ssh      10.0.0.8  ←→  SSH (anyone peered)
wg-ollama   10.0.0.9  ←→  Ollama (anyone peered)
```

Each interface has exactly one local IP. Services bind to that IP. Packets arrive from peered clients, get delivered to the service, and stop. The host never forwards a packet from one interface to another.

### wg-router Container

A minimal container with:
- A real LAN IP: **172.16.1.102** (on the host network)
- A WireGuard interface that agents/Manager can peer with
- `ip_forward=1` inside the container only
- NAT for outbound internet traffic
- Firewall rules controlling what goes where

```
┌─────────────────────────────────────────────────┐
│ Host (ip_forward=0)                             │
│                                                 │
│  wg-hub ── 10.0.0.1 ──── Hub service           │
│  wg-git ── 10.0.0.3 ──── Forgejo               │
│  wg-valley ── 10.0.0.4 ── Evennia              │
│  ...                                            │
│                                                 │
│  ┌───────────────────────────────────────┐      │
│  │ wg-router container                   │      │
│  │                                       │      │
│  │  eth0: 172.16.1.102 (LAN)            │      │
│  │  wg0:  10.0.0.10 (peers: agents)     │      │
│  │                                       │      │
│  │  ip_forward=1                         │      │
│  │  iptables MASQUERADE on eth0          │      │
│  │  (future: per-agent firewall rules)   │      │
│  └───────────────────────────────────────┘      │
│                                                 │
│  ┌───────────────────────────────────────┐      │
│  │ Agent container (e.g. margaux-art)    │      │
│  │                                       │      │
│  │  wg0 peers:                           │      │
│  │    10.0.0.1  (Hub — messages)         │      │
│  │    10.0.0.2  (Manager — lifecycle)    │      │
│  │    10.0.0.3  (git — authorized)       │      │
│  │    10.0.0.6  (comfyui — authorized)   │      │
│  │    10.0.0.10 (router — internet)      │      │
│  │                                       │      │
│  │  default route → 10.0.0.10            │      │
│  └───────────────────────────────────────┘      │
└─────────────────────────────────────────────────┘
```

### Agent Peering: Three Categories

Every agent's WireGuard config is a combination of three categories:

| Category | Interface | Purpose | Who gets it |
|----------|-----------|---------|-------------|
| **Hub** | wg-hub (10.0.0.1) | Message delivery, callbacks | Everyone |
| **Services** | wg-git, wg-valley, etc. | Direct service access | Per-agent authorization |
| **Router** | wg-router (10.0.0.10) | Internet access | Per-agent (can be revoked) |

Authorization is topological. If you're not peered, you can't route there. Nothing on the host will forward you there because nothing on the host forwards.

### Manager Peering

The Manager peers on:
- **wg-hub** — callbacks to Hub (route changes, lifecycle events)
- **Each service interface** — provisioning (create Forgejo users, add SSH keys, etc.)
- **wg-router** — if it ever needs internet access (optional)

The Manager is peered on service interfaces directly. It does not route through the Hub to reach services.

## What This Eliminates

- **ip_forward=1 on the host.** Gone. The host is a switchboard, not a router.
- **Bridge back door.** Doesn't matter — even if an agent reaches a host WG IP through the bridge, the host won't forward it anywhere.
- **Source-based policy routing.** Gone. No `ip rule` commands, no per-service routing tables. Each interface is point-to-point.
- **iptables INPUT rules for bridge isolation.** No longer needed as a security measure (though can be kept as defense-in-depth).
- **Cross-interface leakage.** Impossible. The kernel doesn't forward.

## What This Enables (Future)

The wg-router container becomes the control plane for external access:

- **Per-agent internet control.** Remove an agent's wg-router peer → no internet. No firewall changes needed.
- **Destination filtering.** Block specific IPs/domains at the router. Agents can reach PyPI but not social media.
- **Rate limiting.** Traffic shaping per peer at the router level.
- **Audit logging.** All outbound traffic flows through one point. Log it.
- **Network segmentation.** Multiple router containers with different policies. `wg-router-dev` allows everything, `wg-router-prod` is locked down.

## Implementation

### wg-router Container

Minimal. Alpine + wireguard-tools + iptables.

```dockerfile
FROM alpine:3.19
RUN apk add --no-cache wireguard-tools iptables
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

```bash
#!/bin/sh
# entrypoint.sh
sysctl -w net.ipv4.ip_forward=1
wg-quick up /etc/wireguard/wg0.conf
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i wg0 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
exec sleep infinity
```

Run with:
```bash
podman run -d \
  --name wg-router \
  --cap-add NET_ADMIN \
  --network host \
  -v /path/to/wg0.conf:/etc/wireguard/wg0.conf:ro \
  localhost/wg-router
```

Using `--network host` gives it 172.16.1.102 directly. The WG interface inside handles agent traffic. eth0 handles LAN/internet.

### Host Changes

```bash
# Disable forwarding
sysctl -w net.ipv4.ip_forward=0

# Remove source-based policy routing (no longer needed)
# Remove bridge isolation iptables rules (no longer needed as security measure)

# init.sh simplifies: just create interfaces and set IPs. No routing rules.
```

### Agent Container Changes

Agent default route points to wg-router instead of the podman bridge:

```
# In agent's wg0.conf
[Peer]
# Router
PublicKey = <router-pubkey>
Endpoint = 172.16.1.102:51830
AllowedIPs = 0.0.0.0/0  # Default route through router
```

The `AllowedIPs = 0.0.0.0/0` on the router peer captures all traffic not matched by a more specific peer (the service IPs). Internet traffic goes through the router. Service traffic goes directly to service peers.

## Migration from Current Architecture

1. Build and start the wg-router container
2. Test: agent can reach the internet through the router
3. Disable ip_forward on the host
4. Test: agents can still reach services (point-to-point, unaffected)
5. Test: agents can still reach internet (through router)
6. Test: agents CANNOT cross-route between services (host doesn't forward)
7. Remove source-based policy routing rules from init.sh
8. Remove bridge isolation iptables rule (optional — defense-in-depth)
9. Update init.sh to reflect simplified architecture

## Design Principle

> "The host never forwards. The router is the only thing that forwards, and it's explicitly designed for that."

The host is a switchboard of point-to-point tunnels. Authorization is peering. The router is a chokepoint. Everything else follows.
