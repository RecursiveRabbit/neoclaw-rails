# NeoClaw Network v2: Mesh Topology + WG-Router

## What Changed

v1 was a star topology. All WireGuard interfaces lived on the host, the host kernel forwarded between them (`ip_forward=1`), and the bridge back door let containers bypass WireGuard entirely.

v2 is a mesh. Per-service WireGuard interfaces remain — peering IS authorization. But the host stops forwarding. Each interface is point-to-point. A dedicated wg-router container handles internet access.

## What Stays

- **Per-service WireGuard interfaces.** `wg-hub`, `wg-git`, `wg-valley`, `wg-comfyui`, etc. Each service has its own interface, its own keypair, its own address.
- **Peering IS authorization.** Peered on `wg-comfyui` = can reach ComfyUI. Not peered = can't. No firewall rules needed for access control.
- **Manager provisions peers.** At spawn, the Manager tells `wg-admin` to add the agent's pubkey to each authorized service interface. At teardown, it removes them.
- **`services.conf`** defines the interfaces. `init.sh` creates them.

## What Changes

### Host: ip_forward=0

The host kernel never forwards packets between interfaces. Each WireGuard interface is a dead-end point-to-point tunnel. Packets arrive from a peered client, get delivered to the local service, and stop.

No source-based policy routing. No `ip rule` commands. No bridge isolation iptables rules. The host can't route between interfaces because it doesn't forward.

### wg-router: Internet Access

A dedicated container with:
- A real LAN IP: **172.16.1.102**
- Its own WireGuard interface agents can peer with
- `ip_forward=1` inside the container only
- NAT for outbound internet traffic

Agents that need internet peer with wg-router. Agents that don't, don't. Internet access becomes another peering decision — same model as service access.

### Agent Peering: Three Categories

Every agent's WireGuard config is a combination of:

| Category | Purpose | Peering |
|----------|---------|---------|
| **Hub** | Messages, callbacks | `wg-hub` — everyone |
| **Services** | Direct service access | `wg-git`, `wg-valley`, etc. — per-agent |
| **Router** | Internet access | `wg-router` — per-agent (revocable) |

All point-to-point. No intermediary. No forwarding.

## Topology

```
Star (v1):                          Mesh (v2):

    wg-git ──┐                      wg-git ←──── Agent A
    wg-valley─┤                     wg-git ←──── Agent B
    wg-comfyui┼── Host kernel       
    wg-hub ───┤   (ip_forward=1)    wg-valley ←─ Agent A
    wg-ssh ───┘   routes between    
         ↕                          wg-comfyui ← Agent B (only)
      Agents                        
                                    wg-hub ←──── Agent A
                                    wg-hub ←──── Agent B
                                    
                                    wg-router ←─ Agent A (internet)
                                    wg-router ←─ Agent B (internet)
                                    
                                    Host: ip_forward=0
                                    Each line is point-to-point.
```

## What This Eliminates

- **`ip_forward=1` on host.** The host is a switchboard, not a router.
- **Source-based policy routing.** No routing tables per service. No `ip rule` commands. Each interface is point-to-point.
- **Bridge back door.** Even if an agent reaches a host WG IP through the podman bridge, the host won't forward it anywhere. (Defense-in-depth: keep the iptables INPUT rule if desired.)
- **Cross-interface leakage.** Impossible. The kernel doesn't forward.

## What This Enables

- **Per-agent internet control.** Remove wg-router peer → no internet. Same mechanism as removing a service peer.
- **Destination filtering.** Firewall the router container. Block destinations, rate limit, audit.
- **Clean init.sh.** Create interfaces, set IPs, done. No routing rules, no forwarding config.

## wg-router Container

```dockerfile
FROM alpine:3.19
RUN apk add --no-cache wireguard-tools iptables
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

```bash
#!/bin/sh
sysctl -w net.ipv4.ip_forward=1
wg-quick up /etc/wireguard/wg0.conf
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i wg0 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
exec sleep infinity
```

Run with `--network host` for LAN access at 172.16.1.102.

## Agent WG Config

Same structure as v1 — multiple peers, one per authorized service — plus the router peer for internet:

```ini
[Interface]
PrivateKey = <agent-private-key>
Address = 10.0.1.X/32

# Hub — messages
[Peer]
PublicKey = <hub-pubkey>
Endpoint = <host>:51820
AllowedIPs = 10.0.0.1/32

# Manager — lifecycle signals
[Peer]
PublicKey = <manager-pubkey>
Endpoint = <host>:51821
AllowedIPs = 10.0.0.2/32

# Git — authorized
[Peer]
PublicKey = <git-pubkey>
Endpoint = <host>:51823
AllowedIPs = 10.0.0.3/32

# Valley — authorized
[Peer]
PublicKey = <valley-pubkey>
Endpoint = <host>:51824
AllowedIPs = 10.0.0.4/32

# Router — internet
[Peer]
PublicKey = <router-pubkey>
Endpoint = 172.16.1.102:51830
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

The router peer's `AllowedIPs = 0.0.0.0/0` acts as the default route. Service peers have specific /32 routes that take priority (WireGuard most-specific wins). Service traffic goes direct. Everything else goes through the router.

## Migration

The old network was torn down. Fresh start:

1. `init.sh` creates per-service WG interfaces (same as before, simpler — no routing rules)
2. Build and start wg-router container
3. Peer Manager on all service interfaces (static)
4. Set `ip_forward=0` on host
5. Test: Manager can reach all services directly
6. Test: spawn agent, verify authorized service access, verify internet through router
7. Test: agent CANNOT reach unauthorized services (not peered)
8. Test: agent CANNOT cross-route between services (host doesn't forward)

## Design Principles

> "Peering is authorization. The host is a switchboard of point-to-point tunnels, not a router. The router is the one chokepoint for external access."

> "Nobody gets killed. Freeze, sunset, evacuate, release."

> "How this thing feels from the inside is really important to me. Warm, safe, hermetically sealed pods."
