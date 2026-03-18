# NeoClaw Network Architecture

## Overview

Every agent runs in a podman container. The only path between an agent and a service is WireGuard. If you're not peered, you can't route. WireGuard peering IS the authorization model.

```
┌─────────────────────────────────────────────────────────┐
│                        HOST                              │
│                                                          │
│  wg-hub      10.0.0.1:51820   Hub ↔ Agent messaging     │
│  wg-manager  10.0.0.2:51821   Manager ↔ Agent lifecycle  │
│  wg-git      10.0.0.3:51823   Forgejo                    │
│  wg-valley   10.0.0.4:51824   Evennia                    │
│  wg-vikunja  10.0.0.5:51825   Vikunja                    │
│  wg-comfyui  10.0.0.6:51826   ComfyUI                    │
│  wg-matrix   10.0.0.7:51827   Matrix/Synapse             │
│  wg-ssh      10.0.0.8:51828   SSH                        │
│                                                          │
│  Agent pool: 10.0.1.1 – 10.0.255.254                    │
│                                                          │
└─────────────────────────────────────────────────────────┘

┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  pod-silas   │  │  pod-margaux │  │  pod-kael    │
│  10.0.1.1    │  │  10.0.1.2    │  │  10.0.1.3    │
│  wg0 peers:  │  │  wg0 peers:  │  │  wg0 peers:  │
│   hub        │  │   hub        │  │   hub        │
│   git        │  │   git        │  │   git        │
│   ssh        │  │   ssh        │  │   ssh        │
│   valley     │  │   valley     │  │   valley     │
│   vikunja    │  │   vikunja    │  │              │
│              │  │   comfyui    │  │              │
└──────────────┘  └──────────────┘  └──────────────┘
```

## Why Separate Interfaces Per Service

Each service on the host has its own WireGuard interface with its own keypair
and listen port. This gives two-sided enforcement:

1. **Host side**: each service interface only peers agents that are authorized.
   An unauthorized agent can't even handshake — it doesn't have the service's
   public key in its spawn.json.

2. **Pod side**: the pod's WG config only has peers for authorized services.
   The pod's kernel has no route to unauthorized service IPs.

A single-interface design would let any peered agent reach any service,
with access control only on the pod side (which the pod could modify since
it has NET_ADMIN). Separate interfaces make the host the enforcer.

## The Routing Problem

Multiple WG interfaces on the same host means the kernel has multiple paths
for the same destination. When pod-kael (10.0.1.3) pings wg-git (10.0.0.3),
the response needs to go back through `wg-git`, not `wg-hub`. But the
kernel's main routing table only supports one entry per destination.

### Solution: Source-Based Policy Routing

Linux policy routing selects a routing table based on packet attributes.
We route based on the **source address** of the response — which is the
service's own IP. Each service gets two commands:

```bash
ip rule add from <service-ip> lookup <table-id>
ip route add 10.0.0.0/16 dev <wg-interface> table <table-id>
```

The flow for a ping from kael (10.0.1.3) to git (10.0.0.3):

1. Packet arrives on `wg-git`, decapsulated by WireGuard
2. Kernel generates ICMP reply: source=10.0.0.3, dest=10.0.1.3
3. Kernel checks policy rules: "from 10.0.0.3 → table 103"
4. Table 103: "10.0.0.0/16 dev wg-git"
5. Reply goes out `wg-git`, encrypted with `wg-git`'s keypair
6. Kael's wg0 expects 10.0.0.3 traffic from wg-git's pubkey — match

### Routing Table Reference

| Service    | IP       | Port  | Table | Rule                        |
|------------|----------|-------|-------|-----------------------------|
| wg-hub     | 10.0.0.1 | 51820 | 101   | `from 10.0.0.1 lookup 101` |
| wg-manager | 10.0.0.2 | 51821 | 102   | `from 10.0.0.2 lookup 102` |
| wg-git     | 10.0.0.3 | 51823 | 103   | `from 10.0.0.3 lookup 103` |
| wg-valley  | 10.0.0.4 | 51824 | 104   | `from 10.0.0.4 lookup 104` |
| wg-vikunja | 10.0.0.5 | 51825 | 105   | `from 10.0.0.5 lookup 105` |
| wg-comfyui | 10.0.0.6 | 51826 | 106   | `from 10.0.0.6 lookup 106` |
| wg-matrix  | 10.0.0.7 | 51827 | 107   | `from 10.0.0.7 lookup 107` |
| wg-ssh     | 10.0.0.8 | 51828 | 108   | `from 10.0.0.8 lookup 108` |

Table numbers match the last octet. Each table has one route:
`10.0.0.0/16 dev <interface>`.

## The Bridge Back Door

Podman gives each container an `eth0` on a bridge network (10.88.0.0/16)
with a default route to the host. Without mitigation, an agent could reach
host-local WG addresses through the bridge, bypassing WireGuard entirely.

### Fix: iptables INPUT Rule

```bash
iptables -I INPUT -s 10.88.0.0/16 -d 10.0.0.0/16 -j DROP
```

This drops any traffic from the podman bridge destined for the WG address
space. Agents can only reach WG addresses through WireGuard. Internet
access (via the bridge's NAT gateway) is unaffected.

The `/16` on the destination covers services (10.0.0.x) and the entire
agent pool (10.0.1.x through 10.0.255.x). The podman bridge at
10.88.0.0/16 is in a different part of 10/8, so no conflict.

**Why INPUT not FORWARD:** The WG addresses are local to the host
(assigned to its own interfaces). Traffic to them goes through the INPUT
chain, not FORWARD. FORWARD rules only catch traffic the host is routing
to another machine.

## UFW Integration

UFW must allow WG handshake UDP from the podman bridge to the host's
WG listen ports:

```bash
ufw allow in on podman0 proto udp to any port 51820:51828 \
  comment "WG - neoclaw-rails agent pods"
```

The WG handshake is a UDP packet from the pod's bridge IP (10.88.x.x)
to the host's LAN IP (172.16.x.x) on a WG listen port. This doesn't
touch WG addresses, so the iptables INPUT rule doesn't affect it. But
UFW's default-deny on INPUT will block it without this allow rule.

## Address Space

```
10.0.0.0/16   — WireGuard address space (NeoClaw)
  10.0.0.1-8  — Service interfaces (static, host)
  10.0.1.1+   — Agent pool (dynamic, ~65k addresses)

10.88.0.0/16  — Podman default bridge (managed by podman)

172.16.x.x    — LAN (host's physical network)
```

The WG space uses a /16 within 10/8. This gives ~65k agent addresses
(10.0.1.1 through 10.0.255.254) — enough for any reasonable workload.
The podman bridge sits in a different /16 of the 10/8 space.

## Operations

### Adding a New Service

1. Generate keypair: `wg genkey | tee wg-foo.key | wg pubkey > wg-foo.pub`
2. Pick IP (10.0.0.9) and port (51829)
3. Create interface:
   ```bash
   ip link add wg-foo type wireguard
   ip addr add 10.0.0.9/32 dev wg-foo
   wg set wg-foo private-key wg-foo.key listen-port 51829
   ip link set wg-foo up
   ```
4. Add Manager as peer: `wg set wg-foo peer <manager-pub> allowed-ips 10.0.0.2/32`
5. Add policy routing: `ip rule add from 10.0.0.9 lookup 109 && ip route add 10.0.0.0/16 dev wg-foo table 109`
6. Register in Manager's ServiceType table (name, pubkey, IP, port)
7. Agents are peered automatically when the Manager provisions them

### Adding an Agent Peer (Manager Does This)

1. Generate ephemeral keypair
2. Allocate IP from pool (10.0.1.X)
3. Peer on each authorized service interface: `wg set wg-git peer <pub> allowed-ips 10.0.1.X/32`
4. Write spawn.json with peers for only authorized services
5. Pod boots, configures wg0 from spawn.json, can only route to authorized IPs

### Removing an Agent Peer (Manager Does This)

One pass per interface — remove the peer:
```bash
wg set wg-hub peer <pub> remove
wg set wg-git peer <pub> remove
# ... each interface the agent was peered on
```

No routes to clean up. Policy routing tables route by source address,
not per-peer. Peer removal is instant and atomic.

## Scripts

| Script | Purpose |
|--------|---------|
| `infra/wireguard/generate-keys.sh` | Generate all keypairs (run once) |
| `infra/wireguard/setup-host.sh` | Create host interfaces, add Manager peer, set up policy routing |
| `infra/wireguard/spawn-test-pods.sh` | Spin up test pods for connectivity testing |
| `wg-admin/wg-admin.rb` | Host-side HTTP helper the Manager calls for peer add/remove |

## What We Proved

Four test pods, eight service interfaces, full connectivity matrix:

| Pod | Authorized | Unauthorized | Internet |
|-----|-----------|-------------|----------|
| pod-silas (hub, git, ssh, valley, vikunja) | 5/5 ✓ | comfyui ✓ matrix ✓ | ✓ |
| pod-margaux (hub, git, ssh, valley, vikunja, comfyui) | 6/6 ✓ | matrix ✓ | ✓ |
| pod-kael (hub, git, ssh, valley) | 4/4 ✓ | vikunja ✓ comfyui ✓ matrix ✓ | ✓ |
| pod-hopper (everything) | 7/7 ✓ | — | ✓ |

Every authorized path works. Every unauthorized path is blocked. Every pod has internet.
