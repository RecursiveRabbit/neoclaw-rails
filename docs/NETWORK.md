# Manager Network Requirements

The Manager runs in a firewalled Podman pod. Every connection must be explicitly opened. This document is the firewall spec — if it's not listed here, it's blocked.

## Manager Pod Identity

| Property | Value |
|----------|-------|
| Network | `neoclaw-services` (172.20.0.0/24) |
| WireGuard IP | `10.100.0.2` on `wg-hub` |
| WireGuard listen port | `51821` |
| Admin UI port | `9200` (HTTP, on WireGuard) |
| ActionCable (WebSocket) | `9200` (same port, /cable path) |

## Outbound Connections (Manager → Services)

These are the holes the Manager needs punched through the pod's firewall.

### Hub Communication

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| Hub (`10.100.0.1`) | `9100` | HTTP | POST /callback (released, sunset_warning, crash) |
| Hub (`10.100.0.1`) | `9100` | HTTP | Health checks |

### Container Lifecycle (Podman)

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| Podman socket | — | Unix socket | `podman run`, `podman stop`, `podman rm`, `podman exec`, `podman cp`, `podman ps`, `podman inspect` |

The Manager runs `podman` CLI directly (Podman is daemonless). Needs the rootless Podman socket mounted or the `podman` binary available. See [Podman Access](#podman-access) below.

### Forgejo (Git)

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| Forgejo (`git.home` / `10.100.0.1`) | `3000` | HTTP | Create/delete users, add SSH keys, manage deploy keys, grant repo access |
| Forgejo (`git.home` / `10.100.0.1`) | `2222` | SSH | Admin push for session recovery (dead pod fallback) |

Requires: Forgejo admin API token (stored in Manager config).

### SSH/SFTP

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| SFTP host (`10.100.0.5`) | `22` | — | Write to `authorized_keys` per-nick home dirs |

Requires: Filesystem access to `/var/lib/neoclaw/sftp-keys/` (bind mount or SFTP).

### WireGuard Interfaces (All Service Interfaces)

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| Host | various | UDP | `wg set <interface> peer <pubkey> allowed-ips <ip>/32` on every service interface |

The Manager adds/removes agent peers on all `wg-*` interfaces at spawn/teardown. Requires `CAP_NET_ADMIN` or scoped sudo for `wg` commands, and access to the host's WireGuard interfaces.

| Interface | Listen Port | Purpose |
|-----------|-------------|---------|
| `wg-hub` | `51820` | Hub ↔ Agent messaging |
| `wg-git` | `51823` | Forgejo |
| `wg-valley` | `51824` | Evennia |
| `wg-vikunja` | `51825` | Vikunja |
| `wg-comfyui` | `51826` | ComfyUI |
| `wg-zigbee` | `51827` | Zigbee |
| `wg-ssh` | `51828` | SSH/SFTP |

### Agent Relay Health Checks

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| Agent containers (`10.100.1.x`) | `9300` | HTTP | GET /health (poll until ready, ongoing health) |

Routed via WireGuard. The Manager is a peer on `wg-hub` and agents are peers on `wg-hub`. The Manager adds agents as its own WireGuard peers to reach their Relays directly.

### DNS

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| Hub/dnsmasq (`10.100.0.1`) | `53` | UDP/TCP | Resolve `git.home`, `hub.home` |

## Inbound Connections (Services → Manager)

### From Hub

| Source | Port | Protocol | Purpose |
|--------|------|----------|---------|
| Hub (`10.100.0.1`) | `9200` | HTTP | POST /resolve, POST /release, GET /status |

### From Agent Relays

| Source | Port | Protocol | Purpose |
|--------|------|----------|---------|
| Agents (`10.100.1.x`) | `9200` | HTTP | POST /containers/:instance/output (stream), POST /containers/:instance/health |

### From Evans (Admin UI)

| Source | Port | Protocol | Purpose |
|--------|------|----------|---------|
| Evans's browser | `9200` | HTTP + WebSocket | Dashboard, agent config, live stream |

Evans reaches the Manager UI via WireGuard (Evans is a peer on `wg-hub`) or via a reverse proxy on the host.

## Podman Access

The Manager needs to create and manage sibling containers on the same Podman network. Two options:

### Option A: Podman socket mount (preferred)
Mount the rootless Podman socket into the Manager pod:
```
podman run -v $XDG_RUNTIME_DIR/podman/podman.sock:/run/podman/podman.sock ...
```
Manager uses `podman --remote --url unix:///run/podman/podman.sock` or the Podman API.

### Option B: Podman binary + shared namespace
Run the Manager pod with `--privileged` or with sufficient capabilities to run `podman` directly. Less isolated but simpler.

### Option C: SSH to host
Manager SSHs to the host to run `podman` commands. Most isolated but adds latency and an SSH key to manage.

## WireGuard Access

The Manager needs to run `wg set` on host WireGuard interfaces. Options:

### Option A: Scoped sudo via SSH
Manager SSHs to host with a restricted user that can only run `wg set` via sudoers:
```
manager ALL=(root) NOPASSWD: /usr/bin/wg set wg-*
```

### Option B: CAP_NET_ADMIN in Manager pod
If the Manager pod has `CAP_NET_ADMIN` and access to the host's network namespace (e.g. `--network host` for WireGuard only), it can run `wg set` directly.

### Option C: WireGuard management API on the host
A small privileged helper on the host that exposes WireGuard operations over HTTP on a Unix socket or loopback. Manager calls the API. Most secure separation but another component.

## Filesystem Mounts

| Host Path | Container Mount | Purpose |
|-----------|----------------|---------|
| Podman socket | `/run/podman/podman.sock` | Container lifecycle |
| `/var/lib/neoclaw/sftp-keys/` | `/sftp-keys` | Per-nick SSH authorized_keys |
| `/var/lib/neoclaw/sessions/` | `/sessions` | Session JSONL bind mounts for crash recovery |
| Manager data dir | `/data` | SQLite database, config |

## Summary: What to Open

```
# Manager pod creation (minimal version):
podman run \
  --name neoclaw-manager \
  --network neoclaw-services \
  --cap-add NET_ADMIN \
  -v $XDG_RUNTIME_DIR/podman/podman.sock:/run/podman/podman.sock \
  -v /var/lib/neoclaw/sftp-keys:/sftp-keys \
  -v /var/lib/neoclaw/sessions:/sessions \
  -v /var/lib/neoclaw/manager-data:/data \
  -e NEOCLAW_HUB_URL=http://10.100.0.1:9100 \
  -e NEOCLAW_FORGEJO_URL=http://git.home:3000 \
  -e NEOCLAW_FORGEJO_TOKEN=<token> \
  neoclaw-manager:latest
```

### Firewall Rules (nftables)

```
# Allow Manager → Hub (HTTP)
allow 172.20.0.2 → 10.100.0.1:9100 tcp

# Allow Manager → Forgejo (HTTP API + SSH)
allow 172.20.0.2 → 10.100.0.1:3000 tcp
allow 172.20.0.2 → 10.100.0.1:2222 tcp

# Allow Manager → Agent Relays (HTTP over WireGuard)
allow 172.20.0.2 → 10.100.1.0/24:9300 tcp  (via wg0)

# Allow Hub → Manager (HTTP)
allow 10.100.0.1 → 172.20.0.2:9200 tcp  (via wg-hub)

# Allow Agents → Manager (HTTP for streaming/health)
allow 10.100.1.0/24 → 172.20.0.2:9200 tcp  (via wg0)

# Allow Evans → Manager (HTTP + WebSocket for admin UI)
allow <evans-wg-ip> → 172.20.0.2:9200 tcp

# Allow Manager → host WireGuard interfaces (UDP)
allow 172.20.0.2 → host:51820-51828 udp

# Allow DNS
allow 172.20.0.2 → 10.100.0.1:53 udp

# DENY everything else
```
