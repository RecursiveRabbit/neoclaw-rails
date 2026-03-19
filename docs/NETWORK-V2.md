# NeoClaw Network v2: WG-Router + Mesh Topology

## What Died

The v1 network had per-service WireGuard interfaces on the host (wg-hub, wg-git, wg-valley, etc.), source-based policy routing, bridge isolation rules, and `ip_forward=1` on the host. It worked but was complex, fragile, and had the bridge back door problem.

All of it has been torn down. Clean slate.

## Design Principles

1. **The host never forwards.** `ip_forward=0`. The host kernel is not a router.
2. **One WireGuard interface per entity.** Not per-service. Per entity: one for the router, one for the Manager, one per agent.
3. **wg-router is the only forwarder.** All internet-bound traffic goes through the router container. All cross-network traffic goes through the router.
4. **Authorization is peering.** If you're not peered, you can't reach it. No firewall rules needed for access control.
5. **Services bind to localhost.** Services are not on the WireGuard network directly. They're accessed through the host, which is on the WireGuard network.

## Architecture

### The Mesh

Every WireGuard entity peers directly with every entity it needs to talk to. No routing through intermediaries (except the router for internet).

```
                        ┌──────────────┐
                        │  wg-router   │
                        │ 10.0.0.254   │
                        │ 172.16.1.102 │
                        │ ip_forward=1 │
                        └──────┬───────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
     ┌────────┴───────┐  ┌────┴────────┐  ┌────┴────────┐
     │     Host       │  │  Agent A    │  │  Agent B    │
     │   10.0.0.1     │  │  10.0.1.1   │  │  10.0.1.2   │
     │                │  │             │  │             │
     │  Hub :9100     │  │  Relay      │  │  Relay      │
     │  Manager :9200 │  │  Claude     │  │  Claude     │
     │  Forgejo :3000 │  │             │  │             │
     │  Vikunja :8080 │  │             │  │             │
     │  Valley :4001  │  │             │  │             │
     │  Ollama :11434 │  │             │  │             │
     │  ComfyUI :8188 │  │             │  │             │
     │  Synapse :8008 │  │             │  │             │
     └────────────────┘  └─────────────┘  └─────────────┘
```

### Entities

| Entity | WG Address | What it is |
|--------|-----------|------------|
| **Host** | 10.0.0.1 | Runs all services on localhost. Single WG interface. |
| **Manager** | 10.0.0.2 | Container. Peers with host + router. |
| **wg-router** | 10.0.0.254 | Container. 172.16.1.102 on LAN. Forwards to internet. |
| **Agents** | 10.0.1.x | Containers. Peer with host + router (+ Manager for lifecycle). |

### Host: One Interface, All Services

The host runs a single WireGuard interface: `wg0` at `10.0.0.1`.

All services bind to `127.0.0.1` (localhost) as they already do. The host exposes them to the WireGuard network by listening on `10.0.0.1` — either by binding services to `10.0.0.1` directly, or with socat/iptables DNAT forwarding localhost ports to the WG IP.

From an agent's perspective: `10.0.0.1:3000` is Forgejo. `10.0.0.1:8080` is Vikunja. `10.0.0.1:4001` is Valley. One IP, many ports. Like a server on a LAN.

### Service Authorization

**This is the key change from v1.** In v1, authorization was per-service interfaces — peered on wg-git or not. In v2, all services share one IP (10.0.0.1). Authorization moves to the **application layer** or the **host firewall**.

Options (pick one or combine):

#### Option A: Port-based firewall on the host

The host's WG interface knows the source IP of every packet. Use iptables/nftables on the host to control which agent IPs can reach which ports:

```bash
# Silas can reach Forgejo (3000), Vikunja (8080), Valley (4001), SSH (22)
iptables -A INPUT -i wg0 -s 10.0.1.1 -p tcp --dport 3000 -j ACCEPT
iptables -A INPUT -i wg0 -s 10.0.1.1 -p tcp --dport 8080 -j ACCEPT
iptables -A INPUT -i wg0 -s 10.0.1.1 -p tcp --dport 4001 -j ACCEPT
iptables -A INPUT -i wg0 -s 10.0.1.1 -p tcp --dport 22   -j ACCEPT

# Silas CANNOT reach ComfyUI (8188)
# (implicit DROP at the end of the chain)

# Margaux-art CAN reach ComfyUI
iptables -A INPUT -i wg0 -s 10.0.1.2 -p tcp --dport 8188 -j ACCEPT
```

The Manager generates these rules at spawn time based on the agent's authorized services. The `wg-admin` helper applies them on the host. At teardown, the rules are removed.

**Pros:** Authorization stays topological (source IP = identity). Same security model as v1.
**Cons:** iptables rules accumulate per agent. More complex than "peered or not."

#### Option B: Application-layer auth

Services that support authentication (Forgejo, Vikunja) use tokens/credentials provisioned by the Manager. Services that don't (ComfyUI, Ollama) use the port-based firewall from Option A.

**Pros:** Defense in depth. Even if an agent somehow reaches a port, the service rejects them without credentials.
**Cons:** Two auth systems to manage.

#### Option C: Hybrid (recommended)

- Port-based firewall for coarse access control (can you reach this service at all?)
- Application-layer auth for services that support it (Forgejo tokens, Vikunja tokens)
- Neither alone — both together

This is what the Manager already does: it provisions WireGuard peers (network access) AND Forgejo accounts (application access). The only change is that network access is now port-based rules on one interface instead of peering on separate interfaces.

### wg-router Container

Unchanged from WG-ROUTER.md:

```
Alpine + wireguard-tools + iptables
eth0: 172.16.1.102 (host network)
wg0: 10.0.0.254
ip_forward=1 (inside container only)
MASQUERADE on eth0
```

Agents peer with the router. Their default route (`AllowedIPs = 0.0.0.0/0`) goes through the router. Service traffic (`AllowedIPs = 10.0.0.1/32`) goes directly to the host. WireGuard's most-specific-route wins.

### Agent WG Config

```ini
[Interface]
PrivateKey = <agent-private-key>
Address = 10.0.1.X/32

# Host — all services
[Peer]
PublicKey = <host-pubkey>
Endpoint = <host-bridge-ip>:51820
AllowedIPs = 10.0.0.1/32, 10.0.0.2/32
PersistentKeepalive = 25

# Router — internet
[Peer]
PublicKey = <router-pubkey>
Endpoint = 172.16.1.102:51830
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

Two peers. That's it. Every agent has the same WG config (different keys, same topology). Service authorization happens at the host firewall, not in the WG config.

### Manager WG Config

```ini
[Interface]
PrivateKey = <manager-private-key>
Address = 10.0.0.2/32

# Host — all services (Manager needs everything for provisioning)
[Peer]
PublicKey = <host-pubkey>
Endpoint = <host-bridge-ip>:51820
AllowedIPs = 10.0.0.1/32
PersistentKeepalive = 25

# Router — internet (if needed)
[Peer]
PublicKey = <router-pubkey>
Endpoint = 172.16.1.102:51830
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

### Host WG Config

```ini
[Interface]
PrivateKey = <host-private-key>
Address = 10.0.0.1/32
ListenPort = 51820

# Manager
[Peer]
PublicKey = <manager-pubkey>
AllowedIPs = 10.0.0.2/32

# Agents get added dynamically by wg-admin
# [Peer]
# PublicKey = <agent-pubkey>
# AllowedIPs = 10.0.1.X/32
```

One interface. Manager is a static peer. Agents are added/removed dynamically by the Manager via wg-admin.

## What's Simpler Than v1

| v1 | v2 |
|----|-----|
| 8+ WireGuard interfaces on host | 1 WireGuard interface on host |
| Per-service routing tables | No routing tables |
| Source-based policy routing (`ip rule`) | No policy routing |
| `ip_forward=1` on host | `ip_forward=0` on host |
| Bridge isolation iptables | Not needed (host doesn't forward) |
| Per-service keypairs on host | One keypair on host |
| `services.conf` + `init.sh` (~200 lines) | One `wg0.conf` + one router container |
| Agent WG config: N peers (one per service) | Agent WG config: 2 peers (host + router) |

## What's Different

**Authorization model shifts.** v1: peered on wg-git = can reach Forgejo. v2: everyone can reach 10.0.0.1, port-based firewall controls which services. This is slightly weaker in principle (one interface vs many) but equivalent in practice (iptables is just as enforceable as WG peering).

**The Manager's `wg-admin` helper gains a new job.** In v1 it added/removed peers from multiple interfaces. In v2 it adds/removes peers from one interface AND manages port-based firewall rules.

**`services.conf` changes meaning.** No longer "interfaces to create." Now "ports to expose and firewall rules to manage." Same file, different interpretation.

```
# services.conf v2
# name    port    default_access
hub       9100    all
manager   9200    manager_only
git       3000    all
valley    4001    all
vikunja   8080    all
comfyui   8188    authorized
matrix    8008    all
ssh       22      authorized
ollama    11434   authorized
```

## Migration

This is a fresh start — the old network was torn down.

1. Generate host keypair, write `wg0.conf`, bring up `wg0` at 10.0.0.1
2. Build and start wg-router container (10.0.0.254, 172.16.1.102)
3. Generate Manager keypair, add as static peer on host wg0
4. Start Manager container, verify it can reach host services
5. Write firewall rule generator that reads `services.conf` and agent authorization
6. Test: spawn a test agent, verify it reaches authorized services, gets blocked from unauthorized ones, has internet through router
7. Update `init.sh` (dramatically simpler now)
8. Update Spawner to generate 2-peer agent configs instead of N-peer

## Design Principle

> "One interface per entity, not per service. Authorization at the port level, not the interface level. The host is a server on the WireGuard network, not a router between WireGuard networks."
