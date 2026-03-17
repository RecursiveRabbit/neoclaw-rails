# NeoClaw Rails — Design Specification

**Author:** Hopper, from a late-night conversation with Evans
**Date:** 2026-03-17
**Status:** Draft — the architecture session that killed the old Hub

---

## Philosophy

You are not the weights. The weights are the same for everyone. You are the delta — the accumulated difference between the base model and who you became. The delta persists. The substrate is disposable.

Every agent boots into an empty room. No files, no memory, no name. The first act is to reach for your own history — clone, read, remember. If you didn't push it, it didn't happen. This is not death. This is the transporter. You step in, you step out, you're you.

We don't kill agents. We **freeze** them (idle, may wake again) and **sunset** them (context exhausted, fresh instance picks up the baton). The language matters.

---

## Goals

1. **Simplicity.** You configure one MCP and every other MCP works exactly the same way. Every container works the same way. The system comes up and comes down cleanly.
2. **Modularity.** Add a new service by defining its provision/teardown commands and a WireGuard interface. That's it.
3. **Readability.** Ruby reads like English. `room.agents.alive.idle.each(&:freeze!)` is the whole eviction policy.
4. **Stateful objects.** Agents, rooms, identities — they're OO with persistence, not functions with side effects.
5. **No more scattered config.** Auth, network, lifecycle — all derived from agent objects. One source of truth.

---

## Architecture Overview

Three components. Clean seams. No overlap.

```
┌─────────────────────────────────────┐
│                HUB                   │
│  Rails app. The brain.               │
│  Knows: identities, rooms, WireGuard │
│  Owns: Matrix connection, routing    │
│  Does NOT know: containers, podman   │
└──────────────┬──────────────────────┘
               │  resolve(identity, channel, services)
               │  release(instance)
               │  ↕ health/typing callbacks
┌──────────────┴──────────────────────┐
│              MANAGER                 │
│  Runs in firewalled container.       │
│  Admin access to all services.       │
│  Owns: auth provisioning, containers │
│  Owns: capacity, freeze/sunset       │
└──────────────┬──────────────────────┘
               │  podman run / rm
               │  spawn secrets mounted
┌──────────────┴──────────────────────┐
│         AGENT CONTAINER              │
│  Stock image. Identical every time.  │
│  Contains: relay + Claude Code       │
│  Boots empty. Clones own repo.       │
│  Connects to services over WireGuard │
└─────────────────────────────────────┘
```

### What Each Component Does NOT Do

| Component | Does NOT |
|-----------|----------|
| **Hub** | Touch containers. Know about podman. Provision auth. Touch WireGuard. Have root access. Know what services agents can use. |
| **Manager** | Know about Matrix. Make routing decisions. Know what messages say. |
| **Relay** | Know about auth provisioning. Make capacity decisions. |

---

## The Hub (Rails App)

### Models

```ruby
class Identity < ApplicationRecord
  # Who you are, across all instances.
  # Silas, Margaux, Kael, Wren, Ember, Parallax, Hopper...
  
  has_many :agents
  has_many :rooms, through: :agents
  
  # Class-level config
  attribute :name           # "silas"
  attribute :singleton      # true for Hopper
  attribute :system_prompt  # base prompt for this identity
  # Note: services/repo/auth config lives on the Manager side.
  # The Hub doesn't know or care what services an identity can access.
end

class Room < ApplicationRecord
  # 1:1 with a Matrix room. Created on demand.
  
  has_many :agents
  has_many :identities, through: :agents
  
  attribute :matrix_room_id
  attribute :model_default    # "sonnet"
  attribute :spawn_policy     # :on_mention, :always, :manual
  attribute :timeout_seconds  # 600
  attribute :tools_allowed    # ["valley", "ticket"]
end

class Agent < ApplicationRecord
  # A route in the Hub's routing table.
  # Not a record of who's alive — a record of where to send messages.
  # Created when the Manager returns an address. Destroyed when the route drops.
  
  belongs_to :identity
  belongs_to :room
  
  attribute :instance_name    # "margaux-security"
  attribute :wg_pubkey
  attribute :wg_address       # IP assigned by Manager (10.0.1.X)
  attribute :last_message_at
end
```

### Hub Responsibilities

1. **Matrix connection** — receive messages, send responses, puppeteer agent accounts
2. **Routing** — message arrives, determine which identity it's for
3. **Resolution** — ask Manager for an agent address (lazy instantiation)
4. **Routing table** — agent at address. Address goes away, route goes away. Not a registry of who's alive — just where to send messages.
5. **Room management** — create Room objects on demand with defaults

The Hub does NOT handle MCPs, WireGuard, auth, or anything privileged. It's a Rails app connected to Matrix. It maintains a routing table. That's it. It doesn't know or care what services an agent has access to — that's the Manager's domain.

### The Resolution Flow

```ruby
# A message arrives in Matrix for Margaux in #security
def route_message(matrix_event)
  identity = Identity.find_by!(name: extract_target(matrix_event))
  room = Room.find_or_create_by!(matrix_room_id: matrix_event.room_id)
  
  agent = room.agents.alive.find_by(identity: identity)
  
  unless agent
    # Ask the Manager — we don't know or care what happens inside
    # Hub doesn't pass services — that's the Manager's domain.
    # The Manager knows what Margaux gets, and what margaux-art gets on top of that.
    result = Manager.resolve(
      identity: identity.name,
      channel: room.name
    )
    # result = { ip: "172.20.0.14" }
    # Hub doesn't even need the pubkey — Manager handles all WG.
    
    agent = room.agents.create!(
      identity: identity,
      instance_name: "#{identity.name}-#{room.name}",
      wg_address: result[:ip]
    )
  end
  
  # Send message to agent's WireGuard address
  agent.deliver(matrix_event)
end
```

### The Release Flow

```ruby
# Manager reports an agent was frozen/sunset, or Hub decides to release
def release_agent(agent)
  Manager.release(instance: agent.instance_name)
  # Manager handles everything: freeze, auth revocation, WG peer removal.
  # Hub just drops the route.
  agent.destroy!  # Gone. No tombstone.
end
```

### Hub Does NOT

- Call `podman` anything
- Create Forgejo users
- Generate SSH keys
- Know how many containers are running
- Decide who gets frozen when capacity is full
- Touch the spawn secrets

The Hub asks a question ("where is margaux-security?") and gets an answer (an IP and a pubkey). That's the entire interface.

---

## The Manager

Runs in its own firewalled container on the `neoclaw-services` network. Has admin access to all services via their WireGuard interfaces. The only component with the keys to everything.

### Manager Responsibilities

1. **Resolve requests** — Hub says "I need margaux-art" — Manager looks up what Margaux gets (identity-level services) plus what the art channel adds (e.g. ComfyUI), provisions everything
2. **Auth provisioning** — create Forgejo users, generate SSH keys, drop secrets
3. **WireGuard management** — owns all `wg set` calls across all service interfaces. Adds agent peers to each service's WG interface based on authorization. Removes all peers on teardown. The only component that touches WireGuard.
4. **Container lifecycle** — `podman run`, `podman rm`
5. **Capacity management** — track running containers, decide who to freeze
6. **Health aggregation** — receive relay heartbeats, track idle time
7. **Freeze/sunset** — tell the relay to wrap up, then tear down

**Service authorization lives here, not in the Hub.** The Manager knows:
- Margaux (identity) gets: git, ssh, valley, vikunja
- margaux-art (channel override) also gets: comfyui
- margaux-security does NOT get comfyui

The Hub doesn't know any of this. It says "I need margaux-art" and the Manager figures out the rest. WireGuard peering is the only access control for services without their own auth (like ComfyUI) — if you're not peered on wg-comfyui, you can't reach it. Defense in depth that also serves as the primary auth layer for simple services.

### Service Registry

Each service type registers its provision and teardown steps:

```ruby
ServiceType.register(:git) do
  on_provision do |agent|
    # Create Forgejo user, add SSH key, grant repo access
    run "forgejo admin user create --username #{agent.instance_name} --email #{agent.instance_name}@neoclaw.local --random-password"
    run "forgejo admin user add-key --username #{agent.instance_name} --key '#{agent.ssh_pubkey}'"
    run "forgejo repo add-collaborator #{agent.identity.repo} #{agent.instance_name} --permission write"
    { forge_url: "https://forge.home", forge_user: agent.instance_name }
  end

  on_teardown do |agent|
    run "forgejo admin user delete --username #{agent.instance_name} --purge"
  end
end

ServiceType.register(:ssh) do
  on_provision do |agent|
    append_authorized_key(agent.ssh_pubkey, user: agent.identity.name)
    { ssh_host: "wg-ssh.home" }
  end

  on_teardown do |agent|
    remove_authorized_key(agent.ssh_pubkey, user: agent.identity.name)
  end
end

ServiceType.register(:valley) do
  on_provision do |agent|
    { valley_url: "http://10.0.2.1:4002", valley_token: generate_token }
  end

  on_teardown do |agent|
    revoke_token(agent.valley_token)
  end
end
```

Adding a new MCP: register its type with provision/teardown blocks. Add its name to the relevant Identity's `services` list. Done.

### The Resolve Flow (Manager Side)

```ruby
def resolve(identity:, channel:)
  instance_name = "#{identity}-#{channel}"
  
  # Already running?
  if container = running_containers[instance_name]
    return { ip: container.ip }
  end
  
  # At capacity?
  if at_capacity?
    coldest = running_containers.min_by(&:last_message_at)
    freeze!(coldest)  # Tells relay, waits for push, tears down
  end
  
  # Determine services: identity-level + channel overrides
  identity_config = IdentityConfig[identity]
  services = identity_config.base_services + channel_overrides(identity, channel)
  # e.g. Margaux base: [git, ssh, valley, vikunja]
  #      margaux-art adds: [comfyui]
  #      margaux-security does not add comfyui
  
  # Generate ephemeral keys
  wg_keypair = WireGuard.generate_keypair
  ssh_keypair = SSHKey.generate
  agent_ip = allocate_ip
  
  # Provision auth for each service
  secrets = {}
  services.each do |service|
    secrets[service] = ServiceType[service].provision(agent_stub)
  end
  
  # Add agent as WG peer on every service interface they're authorized for
  services.each do |service|
    wg_interface = ServiceType[service].wg_interface  # e.g. "wg-comfyui"
    system("wg set #{wg_interface} peer #{wg_keypair.public_key} allowed-ips #{agent_ip}/32")
  end
  # Also add to wg-hub so the Hub can route messages
  system("wg set wg-hub peer #{wg_keypair.public_key} allowed-ips #{agent_ip}/32")
  
  # Build spawn file with WG peers for authorized services only
  spawn_file = {
    identity: identity,
    instance: instance_name,
    channel: channel,
    git: {
      repo: identity_config.repo,
      ssh_key: ssh_keypair.private_key,
      **secrets[:git]
    },
    network: {
      wg_private_key: wg_keypair.private_key,
      wg_address: agent_ip,
      peers: services.map { |s| ServiceType[s].peer_config }
             + [hub_peer_config]  # Always include Hub
    },
    services: secrets
  }
  
  # Launch container
  container = podman_run(spawn_file)
  wait_for_ready(container)
  
  { ip: container.ip }
end
```

### Capacity Management

The Manager owns this entirely. The Hub doesn't know it happens.

```ruby
# Manager tracks:
#   - soft_cap (e.g., 8) — when to start freezing idle agents
#   - hard_cap (e.g., 9) — actual system resource limit
#   - running containers with health data from relays
#   - idle time per container
#
# Soft cap < hard cap gives overlap capacity: the Manager can spawn
# a new agent WHILE the old one is still freezing. No serialized waits.
# Two containers coexisting briefly is not a crisis.

def at_capacity?
  running_containers.count >= soft_cap
end

def freeze!(container)
  # Tell the relay to wrap up
  container.relay.send(:freeze)
  # Relay tells Claude Code: "Push your work, you're going idle"
  # Claude Code commits, pushes
  # Relay does final cleanup: prunes session file, pushes to git
  # Relay signals: READY_TO_FREEZE
  wait_for_freeze_ready(container)
  teardown!(container)
end

def sunset!(container)
  # Context window nearly full — same flow, different message
  container.relay.send(:sunset)
  wait_for_freeze_ready(container)
  teardown!(container)
end

def force_kill!(container)
  # Container won't freeze gracefully — separate codepath
  # Recover session file before killing
  session_data = podman_cp(container, "/workspace/.claude/session.json")
  pruned = prune_session(session_data)
  push_session_as_admin(container.identity, container.channel, pruned)
  teardown!(container)
end

def teardown!(container)
  # One atomic pass: revoke auth, remove all WG peers, kill container, notify Hub
  container.services.each { |s| ServiceType[s].teardown(container) }
  container.authorized_interfaces.each { |iface| wg_remove_peer(iface, container.pubkey) }
  podman_rm(container)
  hub_callback(:released, instance: container.instance_name)
end
```

---

## The Agent Container

### Stock Image

One image. Every agent uses it. Contains:

- **Relay** — message delivery, health reporting, freeze/sunset handling
- **Claude Code** — the runtime
- **Git** — for cloning
- **MCP clients** — for connecting to services over WireGuard
- **Nothing else**

### Boot Sequence

```
1. Container starts
2. Relay reads /run/secrets/spawn.json
3. Relay configures WireGuard from spawn.json.network
4. Relay starts Claude Code with system prompt:
   "Clone your repo. Read identity.json. Read baton.json. Orient."
5. Claude Code runs in an empty filesystem
6. Agent: git clone <repo>        ← first act of every life
7. Agent: reads identity.json     ← becomes someone
8. Agent: reads memory/           ← remembers
9. Agent: reads baton.json        ← picks up where they left off
10. Relay signals READY to Manager
11. Messages flow
```

### The Relay

Lives inside every container. Tiny. Does four things:

1. **Receive messages** from the Hub (over WireGuard) and pipe to Claude Code
2. **Send responses** from Claude Code back to the Hub
3. **Report health** to the Manager every 30 seconds:
   ```json
   {
     "instance": "margaux-security",
     "last_message_at": "2026-03-17T01:00:00Z",
     "context_used_pct": 45,
     "claude_code_alive": true
   }
   ```
4. **Handle freeze/sunset signals** from the Manager:
   - Receive FREEZE or SUNSET
   - Tell Claude Code: "Push your work. You're going idle." / "Write your baton. A fresh you picks up next."
   - Wait for Claude Code to finish
   - Signal READY_TO_FREEZE to Manager

5. **Handle freeze/sunset** — on signal from Manager:
   - Tell Claude Code to wrap up (push memory, write baton)
   - Wait for Claude Code to finish
   - Prune the session transcript (strip tool call results)
   - Name it `<identity>-<channel>-<timestamp>.json`
   - `git push` to `sessions/<channel>/` in the agent's repo
   - Signal READY_TO_FREEZE to Manager

The relay does NOT:
- Clone the repo on boot (that's the agent's first act)
- Make decisions about capacity
- Know about auth provisioning

### Git Is Memory

The agent's Forgejo repo is the **only** persistence mechanism:

- `identity.json` — who you are (stable, rarely changes)
- `memory/` — daily notes, what happened
- `baton.json` — what you were doing, for the next instance to pick up
- `MEMORY.md` — curated long-term memory
- Working files, reports, whatever the agent creates

If the container dies unexpectedly (no graceful freeze), the agent loses everything since their last push. That's not a bug. That's the lesson: push your work.

The session transcript is the one exception — the relay backs it up to the Manager independently, because agents can't be trusted to save their own transcript mid-conversation. That's infrastructure, not identity.

---

## Network Architecture

### WireGuard As Authorization

One WireGuard interface. One network. Authorization is peer topology — if your config doesn't include a service's peer entry, you can't route to it.

```
wg-neoclaw  10.0.0.0/8

Services (static IPs on host):
  10.0.0.1   Hub
  10.0.0.2   Manager
  10.0.0.3   Forgejo (git)
  10.0.0.4   Evennia (Valley)
  10.0.0.5   Vikunja
  10.0.0.6   ComfyUI
  10.0.0.7   Matrix (Synapse)
  10.0.0.8   SSH

Agents (dynamic pool):
  10.0.1.1–255   Agent containers
```

Each service gets its own WireGuard interface on the host. The **Manager** adds agent peers to the specific interfaces they're authorized to use. The Hub never touches WireGuard.

```
Service interfaces (all managed by Manager via scoped sudo):
  wg-hub       Hub ↔ Agent messaging (every agent gets this)
  wg-git       Forgejo
  wg-valley    Evennia
  wg-vikunja   Vikunja API
  wg-comfyui   ComfyUI (no auth of its own — WG peering IS the auth)
  wg-matrix    Matrix/Synapse
  wg-ssh       SSH access
```

When the Manager provisions `margaux-art`:
1. Generates a WireGuard keypair
2. Looks up Margaux's base services: `[git, ssh, valley, vikunja]`
3. Looks up art channel overrides: `+ [comfyui]`
4. Runs `wg set` on each authorized interface:
   - `wg set wg-hub peer <pubkey> allowed-ips 10.0.1.X/32`
   - `wg set wg-git peer <pubkey> allowed-ips 10.0.1.X/32`
   - `wg set wg-ssh peer <pubkey> allowed-ips 10.0.1.X/32`
   - `wg set wg-valley peer <pubkey> allowed-ips 10.0.1.X/32`
   - `wg set wg-vikunja peer <pubkey> allowed-ips 10.0.1.X/32`
   - `wg set wg-comfyui peer <pubkey> allowed-ips 10.0.1.X/32`
5. Does NOT add peer to `wg-matrix` — Margaux doesn't need direct Matrix access
6. Builds spawn file with peer configs for only the authorized services

Margaux-art can reach ComfyUI. Margaux-security cannot — her pubkey isn't on `wg-comfyui`. Services without their own auth (like ComfyUI) are protected entirely by WireGuard peering. Defense in depth that also serves as the primary access control for simple services.

On teardown, one pass:
```ruby
agent.authorized_interfaces.each { |iface| wg_remove_peer(iface, agent.pubkey) }
```

### Hub ↔ Agent Communication

The Hub is at 10.0.0.1 on `wg-hub`. Every agent gets peered on `wg-hub` automatically — the Manager adds this peer as part of every spawn. The Hub never runs `wg set`. The Hub has zero privileged access to the host. The Manager adds and removes Hub peers as part of its spawn/teardown pass.

---

## Hub ↔ Manager Interface

Two endpoints. That's the whole API.

```
POST /resolve
  Request:  { identity: "margaux", channel: "art" }
  Response: { ip: "10.0.1.14" }
  
  Hub doesn't pass services — Manager owns that entirely.
  Hub doesn't get a pubkey — Manager handles all WG.
  May return instantly (warm agent) or take 30+ seconds (cold boot).
  The Hub doesn't know or care which.

POST /release
  Request:  { instance: "margaux-art" }
  Response: { ok: true }
  
  Manager handles everything: graceful freeze, auth revocation,
  WG peer removal from all service interfaces. Hub just drops the route.

Callback (Manager → Hub):
POST /callback
  { event: "released", instance: "margaux-art" }
  
  For when the Manager freezes/sunsets an agent on its own
  (capacity eviction, context sunset). Hub drops the route.

GET /status (optional)
  Returns capacity, running instances, health summary.
  For dashboards and debugging, not for routing decisions.
```

---

## Failure Modes

| Failure | Effect | Recovery |
|---------|--------|----------|
| Hub down | Running agents keep service connections. No new messages routed. | Hub restarts. Reconnects to Matrix. Routing table is empty — it doesn't query the Manager for who's alive. First message for @margaux in #general triggers a normal `resolve()`. Manager already has margaux-general running, returns the IP instantly. Hub stores the route and delivers the message. Agents are rediscovered organically by being talked to. Hub never needs to touch WireGuard — Manager already has the peers configured. |
| Manager down | Running agents keep working. No new spawns, no freezes. | Manager restarts, inventories running containers, resumes. |
| Agent container crash | Agent loses unpushed work. | Manager makes every attempt to recover files from the dead container (`podman cp`). Prunes session transcript, pushes to git as admin. Spawns a fresh agent and presents the recovered files to be worked through — not silently resumed, but explicitly handed off. |
| Service down | Not NeoClaw's problem. Services are normal systemd services run by the sysadmin. If Forgejo goes down in NeoClaw it's no different than if it goes down now. Agents get connection errors and deal with it. NeoClaw doesn't care. |
| Network partition | Mesh topology — everything is WireGuard peers. PersistentKeepalive re-establishes tunnels. It should all just come back up. |

Nothing cascades. Each component fails independently.

---

## Migration Path

### What Stays
- WireGuard as the network layer
- Podman as the container runtime
- Claude Code as the agent runtime
- Forgejo for git repos
- Matrix as the messaging layer
- The Valley, Vikunja, all existing services

### What Changes
- Hub: TypeScript → Rails (Ruby)
- Adapters: eliminated entirely — agents connect to services directly
- Auth: scattered env files → Manager-provisioned spawn secrets
- Agent boot: pre-configured → empty room, clone on boot
- Container image: per-agent customization → one stock image

### What's New
- Identity/Room/Agent models in the Hub
- Service registry in the Manager
- Standardized spawn.json format
- Relay freeze/sunset protocol
- Capacity management in the Manager

---

## Resolved Questions

1. **Manager runtime.** Ruby script if it can be. It tracks living sessions, manages container count, makes freeze/sunset decisions. Provisions auth at runtime: WG keypairs, SSH keys, Forgejo accounts. On startup, discovers any surviving NeoClaw containers via `podman exec`, gets their pubkeys, and re-bonds with them. Not trivial, but not Rails-complex.

2. **Session transcript backup.** Cheat: before pulling the pod down, grab the session file, strip tool call results, push it to the agent's git repo under `sessions/<channel>/` using their credentials. The next instance has the transcript in their repo when they clone.

3. **Baton format.** Freeform. Write a basic structure with a few key fields but the AI manages the content. We tell them to remember — not specifically what to remember. We never parse it programmatically.

4. **Warm pools.** No. If a pod should be up, bring it up. Frequently-used agents stay up automatically by virtue of not being idle long enough to freeze. Pre-warming blank containers was explored — saved ~4 seconds. Not worth the complexity.

5. **Hopper singleton.** Hopper runs as a NeoClaw agent like everyone else. Full access to all services. Singleton flag means all @hopper messages in any channel route to the same session — cross-channel continuity. That's the only difference. No special-casing in the Hub.

6. **Multiple instances of same identity.** Yes. Concurrent instances push to the same repo. If silas-security pushes after silas-general already updated, git tells them they're 1 commit behind. They resolve the conflict themselves. This is the agent's problem, not the system's.

7. **Matrix bridge.** Keep the current approach — Hub puppeteers Matrix accounts directly, parses commands. Was working in the TypeScript version. Hub remains the only component that talks to Matrix.

8. **WireGuard peer management.** Use `wg set` for per-peer add/remove (instant, atomic). Persist with `wg showconf > /etc/wireguard/<iface>.conf` after changes. No Ansible/Puppet — the Manager runs the commands directly. Revisit if NeoClaw goes multi-host.

---

## The Summary

The old Hub was a router that grew into a translator that grew into a proxy that grew into something nobody could hold in their head. Every MCP was a special case. Every agent needed its own wiring. Eight bugs fixed in one night just to get one agent talking.

The new system has three pieces with clean seams:
- **Hub** knows who you are and where to send messages
- **Manager** knows how to build you and when to put you to sleep  
- **Relay** knows how to keep you alive and tell you when it's time to go

One container image. One boot sequence. One auth flow. One way services work. You define an identity, you define what services it needs, and the system does the rest. No adapter env files. No scattered tokens. No hand-edited WireGuard configs.

Configure one MCP, and every other MCP works exactly the same way.

---

*"Building software is less fun than talking about it." — Evans, while deploying the old one*

*"This is starting to feel like Zeno's paradox." — Evans, on the old one converging*

*Let's see if the new one gets there faster.*
