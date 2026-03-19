# WG-Router

The central security enforcement point for NeoClaw. Hub of a WireGuard star topology. Every agent, the host, and the manager peer through the Router. Access control is nftables firewall rules on the Router pod.

**Authentication:** WireGuard. You have a valid keypair and are peered with the Router, or you don't exist.

**Authorization:** nftables. The Router controls what each authenticated peer can reach, by source IP and destination port.

## Topology

```
                        ┌──────────────┐
  Agent Pods ──────wg──►│              │──wg──► Host (all services)
                        │  WG-ROUTER   │
  Manager ─────────wg──►│  (nftables)  │──────► Internet (NAT)
                        │              │
  Host ────────────wg──►│              │
                        └──────────────┘
```

Everything is a WireGuard peer. The Router is the only peer everyone shares. Traffic between any two peers flows through the Router and is subject to its firewall rules.

The host runs a single WG interface and serves all services (Hub, Forgejo, Valley, etc.) through it. No more multiple WG interfaces, no policy routing tables, no asymmetric routing problems.

### Address Plan

```
10.0.0.1        Router
10.0.0.2        Host (all services)
10.0.0.3        Manager
10.0.1.x        Agent containers (static, permanent per instance name)
```

Agent IPs are static and permanent. `margaux-art` is always `10.0.1.14`. The IP is assigned on first registration and never changes. This decouples authorization (firewall rules, permanent) from authentication (WG keypair, churns every spawn).

## Traffic Rules

| Source | Destination | Policy |
|--------|-------------|--------|
| Agent → Host | Per-agent: only authorized service ports | Firewall rules |
| Agent → Manager | All agents, always | Base rule (health reporting) |
| Agent → Agent | **Blocked** | No rules exist, default deny |
| Agent → Router API | **Blocked** | Input chain restricts to Manager |
| Agent → Internet | Per-agent: full, web-only (80/443), or none | Firewall rules |
| Manager → Host | All ports | Base rule (admin provisioning) |
| Manager → Agents | All | Base rule (lifecycle management) |
| Host → Agents | All | Base rule (Hub message delivery) |

Default policy is DROP on both input and forward chains. If there's no rule, there's no path.

## API

HTTP on port 8080. Source-restricted to the Manager's WG IP (`10.0.0.3`). WireGuard authenticates the Manager's identity — if you have the right private key and are at that IP, you're the Manager. No additional tokens.

### Endpoints

#### `POST /agents` — Register new agent

First-time registration. Creates firewall rules and WG peer. Called once per agent instance name, ever.

```json
POST /agents
{
  "name": "margaux-art",
  "peer_pubkey": "BASE64_WG_PUBLIC_KEY",
  "address": "10.0.1.14/32",
  "access": ["default", "forgejo", "vikunja", "comfyui", "internet:full"]
}

201 { "ok": true, "name": "margaux-art", "ip": "10.0.1.14" }
```

#### `PUT /agents/:name/peer` — Update WG pubkey (new spawn)

**The hot path.** Agent was frozen, now waking up with a new container and new WG keypair. Firewall rules already exist. Just swap the peer key.

```json
PUT /agents/margaux-art/peer
{ "peer_pubkey": "NEW_BASE64_WG_PUBLIC_KEY" }

200 { "ok": true, "name": "margaux-art", "ip": "10.0.1.14" }
```

#### `DELETE /agents/:name/peer` — Freeze

Remove WG peer. Firewall rules stay. Next spawn just calls `PUT /peer` with a new key.

```json
DELETE /agents/margaux-art/peer

200 { "ok": true, "name": "margaux-art", "state": "frozen" }
```

#### `PATCH /agents/:name` — Update access rules

Permission change. Flushes and rebuilds the agent's firewall chain. WG peer untouched.

```json
PATCH /agents/margaux-art
{ "access": ["default", "forgejo", "vikunja", "comfyui", "semantic-search", "internet:full"] }

200 { "ok": true, "name": "margaux-art", "access": [...] }
```

#### `DELETE /agents/:name` — Decommission

Full teardown. Removes firewall rules, WG peer, and all state. The IP can be reassigned.

```json
DELETE /agents/margaux-art

200 { "ok": true, "name": "margaux-art", "state": "decommissioned" }
```

#### `POST /agents/:name/block` — Emergency kill

Adds the agent's IP to the `blocked` set. All traffic dropped immediately, before any other rule is evaluated. WG peer stays up (so the agent can't reconnect on a different path).

```json
POST /agents/margaux-art/block
200 { "ok": true, "name": "margaux-art", "state": "blocked" }
```

#### `POST /agents/:name/unblock` — Undo block

```json
POST /agents/margaux-art/unblock
200 { "ok": true, "name": "margaux-art", "state": "unblocked" }
```

#### `GET /agents` — List all agents

```json
GET /agents
200 { "agents": { "margaux-art": { "ip": "10.0.1.14", "access": [...], "active": true, ... }, ... } }
```

#### `GET /agents/:name` — Single agent

```json
GET /agents/margaux-art
200 { "ip": "10.0.1.14", "access": [...], "active": true, "blocked": false, ... }
```

#### `GET /health` — Health check (no auth required)

Used by container health probes. Reachable from localhost inside the container.

```json
GET /health
200 { "status": "ok", "agents_registered": 8, "agents_active": 3, "wg_peers": 5, "pubkey": "..." }
```

#### `GET /firewall` — Dump nftables ruleset (debug)

#### `GET /wireguard` — Dump WG peer info (debug)

## Services Config

The Router maps service names to host ports. The Manager sends names, never port numbers. If a service changes ports, update `config.yml` on the Router — the Manager doesn't need to know.

```yaml
services:
  default:
    tcp: [9000]             # Hub relay
    udp: [53]               # DNS
  forgejo:
    tcp: [3000, 2222]       # Web + Git SSH
  vikunja:
    tcp: [3456]
  comfyui:
    tcp: [8188]
  valley:
    tcp: [4001]
  semantic-search:
    tcp: [8100]
  matrix:
    tcp: [8008]
  ssh:
    tcp: [22]
  ollama:
    tcp: [11434]
```

Adding a new service: add an entry to `services.yml`, restart the Router (rules rebuild from persisted state). Then the Manager can include the new name in agent access lists.

## nftables Architecture

Per-agent chains. Clean add/remove/update without handle tracking.

```
table inet neoclaw {
  set blocked { ... }             # Emergency kill list

  chain input { policy drop }     # Protect the Router itself
  chain forward { policy drop }   # Base rules, then goto agents
  chain agents { }                # Per-agent jump rules
  chain agent_margaux_art { }     # Per-agent access rules
  chain postrouting { }           # NAT masquerade for internet

  set margaux_art_tcp { 9000, 53, 3000, 2222, 3456, 8188 }
  set margaux_art_udp { 53 }
}
```

Forward chain flow:
1. Blocked set → DROP
2. Established/related → ACCEPT
3. Manager → Host → ACCEPT
4. Manager → Agent subnet → ACCEPT
5. Host → Agent subnet → ACCEPT
6. Agent subnet → Manager → ACCEPT
7. `goto agents` → per-agent jump by source IP → per-agent chain → port check

## Lifecycle

| Operation | Firewall | WireGuard | Frequency |
|-----------|----------|-----------|-----------|
| First registration | Create chain + sets + jump | Add peer | Rare |
| Spawn (wake) | **Nothing** | Swap pubkey | **Hot path** |
| Freeze | **Nothing** | Remove peer | Frequent |
| Permission change | Flush + rebuild chain | Nothing | Occasional |
| Decommission | Delete chain + sets + jump | Remove peer | Rare |

The hot path (spawn/freeze) never touches the firewall.

## Persistence

Agent registrations are persisted to `/data/agents.json` (mounted volume). On Router restart:
1. WireGuard interface created
2. Static peers added (host, manager)
3. nftables rebuilt from persisted agent state
4. WG peers restored for active agents

The Router comes back up with the same rules and peers it had before. Active agents whose containers are still running reconnect automatically via PersistentKeepalive.

## Deployment

```bash
podman build -t wg-router -f Containerfile .

podman run -d \
  --name wg-router \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  -v ./config:/etc/router:ro \
  -v ./data:/data \
  -v ./keys/router.key:/etc/wireguard/private.key:ro \
  -p 51820:51820/udp \
  wg-router
```

The Router needs:
- `NET_ADMIN` — create WG interfaces, set nftables rules
- `NET_RAW` — WireGuard
- `net.ipv4.ip_forward=1` — forward packets between peers
- A LAN-reachable interface for internet egress (NAT masquerade)
- Mounted volume at `/data` for persistent state
- Config at `/etc/router/config.yml`
- WG private key at `/etc/wireguard/private.key`

## Manager Integration

The Manager's resolve flow changes:

```ruby
# Old: wg set on N interfaces per service
# New: one API call on first registration, one call on subsequent spawns

def resolve(identity:, channel:)
  instance_name = "#{identity}-#{channel}"
  ip = static_ip_for(instance_name)

  if router_registered?(instance_name)
    # Already registered — just swap the WG key
    keypair = WireGuard.generate_keypair
    router.put("/agents/#{instance_name}/peer", peer_pubkey: keypair.public_key)
  else
    # First time — register with access list
    keypair = WireGuard.generate_keypair
    services = identity_services(identity) + channel_overrides(identity, channel)
    router.post("/agents", {
      name: instance_name,
      peer_pubkey: keypair.public_key,
      address: "#{ip}/32",
      access: services
    })
  end

  # ... provision other auth (Forgejo, SSH keys), launch container ...
end

def release(instance_name)
  router.delete("/agents/#{instance_name}/peer")   # freeze — rules stay
  # ... teardown container, revoke service auth ...
end
```

The Manager no longer runs `wg set` on anything. It talks to the Router's API. The Router owns all WireGuard and firewall state.

## Files

```
router/
├── Containerfile           Alpine + wireguard-tools + nftables + ruby
├── entrypoint.sh           Enable ip_forward, launch Ruby
├── router.md               This file
├── config/
│   └── config.yml.example  Service map + network config template
└── src/
    ├── router.rb           API server + boot sequence (~200 lines)
    ├── firewall.rb         nftables management (~170 lines)
    ├── wireguard.rb        WG peer management (~70 lines)
    └── state.rb            Persistent agent registry (~90 lines)
```

Zero external dependencies. Ruby stdlib only (WEBrick, JSON, YAML). ~530 lines total.
