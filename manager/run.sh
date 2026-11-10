#!/bin/bash
set -euo pipefail

# Launch the Manager container.
#
# WG config is baked into the image (no mount needed).
# The Manager launches the Router and Hub on boot.
#
# Runtime mounts:
#   /run/podman/podman.sock  — create/destroy pods
#   /spawn                   — spawn.json staging
#   /ssh-keys                — agent SSH keys
#   /data                    — persistent SQLite database
#   claude-credentials       — Claude OAuth creds

CONTAINER_NAME="neoclaw-manager"
IMAGE="localhost/neoclaw-manager:latest"

# --- Mesh underlay: one source, asserted before launch -----------------
# Addresses come from manager/network.env (the single source) and the network is
# created-if-absent and asserted by manager/mesh-network.sh. Rootless podman's
# pasta default cannot hold a static address and cannot reach a bridge peer, so
# the mesh rides a named user-defined network and never a host default.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NETWORK_ENV="${NETWORK_ENV:-${SCRIPT_DIR}/network.env}"
[ -r "$NETWORK_ENV" ] || { echo "[manager-run] FATAL: no network source at ${NETWORK_ENV}" >&2; exit 1; }
# shellcheck disable=SC1090
. "$NETWORK_ENV"
# shellcheck source=mesh-network.sh
. "${SCRIPT_DIR}/mesh-network.sh"
NC_MESH_NETWORK="$NC_MESH_NETWORK" ROUTER_BRIDGE_IP="$ROUTER_BRIDGE_IP" ROUTER_ENDPOINT="$ROUTER_ENDPOINT"

HOST_SPAWN_DIR="/var/lib/neoclaw/spawn"
HOST_SSH_KEYS_DIR="/var/lib/neoclaw/sftp-keys"
HOST_DB_DIR="/var/lib/neoclaw/manager-db"
HOST_CLAUDE_CREDS="/var/lib/neoclaw/secrets/claude-credentials.json"
PODMAN_SOCKET="/run/podman/podman.sock"

# Service credentials — NEVER defaults in this file.
# Read from the host secret store (mode 0600), or from the environment for
# an operator who is deliberately injecting them. Missing required secrets
# abort the launch instead of silently using a value from the repo.
SECRETS_DIR="${SECRETS_DIR:-/var/lib/neoclaw/secrets}"

read_secret() {  # $1 = filename under SECRETS_DIR; echoes value or nothing
    local f="${SECRETS_DIR}/$1"
    [ -r "$f" ] && tr -d '\n' < "$f"
}

FORGEJO_ADMIN_TOKEN="${FORGEJO_ADMIN_TOKEN:-$(read_secret forgejo-admin-token)}"
if [ -z "$FORGEJO_ADMIN_TOKEN" ]; then
    echo "[manager-run] FATAL: no Forgejo admin token. Set FORGEJO_ADMIN_TOKEN or write ${SECRETS_DIR}/forgejo-admin-token (0600)." >&2
    echo "[manager-run] There is deliberately no default: a token in this script is a token in git." >&2
    exit 1
fi

# Matrix tokens — optional (Hub degrades without them); same store, no defaults.
NEOCLAW_AS_TOKEN="${NEOCLAW_AS_TOKEN:-$(read_secret matrix-as-token)}"
NEOCLAW_HS_TOKEN="${NEOCLAW_HS_TOKEN:-$(read_secret matrix-hs-token)}"

log() { echo "[manager-run] $*"; }

# --- Per-boot host peering -------------------------------------------------
# The Router key is generated fresh by the Manager entrypoint on every boot.
# The host's nc-host peer must be re-pointed after each start; this script is
# the root step that does it. It waits for the boot handoff file, then updates
# the live interface and the persisted config.
update_host_peer() {
    local pubkey_file="${HOST_SPAWN_DIR}/runtime/router.pubkey"
    local i
    for i in $(seq 1 60); do
        [ -s "$pubkey_file" ] && break
        sleep 1
    done
    if [ ! -s "$pubkey_file" ]; then
        log "WARNING: no router.pubkey after 60s — host peer not updated"
        return 1
    fi
    local pubkey
    pubkey=$(tr -d '\n' < "$pubkey_file")
    wg set nc-host peer "$pubkey" \
        endpoint "${ROUTER_ENDPOINT}" \
        allowed-ips "10.0.0.0/8" \
        persistent-keepalive 25 2>/dev/null \
        && log "host nc-host peer re-pointed (live) → ${pubkey:0:12}..." \
        || log "WARNING: could not update nc-host (interface may not exist yet)"
    local host_conf=/etc/wireguard/nc-host.conf
    if [ -f "$host_conf" ]; then
        local host_privkey
        host_privkey=$(awk '/^PrivateKey/{print $3}' "$host_conf")
        if [ -n "$host_privkey" ]; then
            (umask 077; cat > "$host_conf" <<EOF
[Interface]
PrivateKey = ${host_privkey}
Address = 10.0.0.2/32

[Peer]
PublicKey = ${pubkey}
Endpoint = ${ROUTER_ENDPOINT}
AllowedIPs = 10.0.0.0/8
PersistentKeepalive = 25
EOF
            )
            log "nc-host.conf re-pointed at the current boot's Router key"
        fi
    fi
}

# User configs: build.sh writes templates; the per-boot Router pubkey is
# substituted here so the files operators hold always match the mesh.
render_user_configs() {
    local pubkey_file="${HOST_SPAWN_DIR}/runtime/router.pubkey"
    local dir="${USER_CONFIG_DIR:-/var/lib/neoclaw/user-configs}"
    [ -s "$pubkey_file" ] || return 0
    [ -d "$dir" ] || return 0
    local pubkey
    pubkey=$(tr -d '\n' < "$pubkey_file")
    local f out
    for f in "$dir"/*.conf.in; do
        [ -e "$f" ] || return 0
        out="${f%.in}"
        sed "s|^PublicKey = __ROUTER_PUBKEY__$|PublicKey = ${pubkey}|" "$f" > "$out"
        chmod 600 "$out"
        log "rendered $(basename "$out") with current Router key"
    done
}


# Ensure host directories exist
mkdir -p "$HOST_SPAWN_DIR" "$HOST_SSH_KEYS_DIR" "$HOST_DB_DIR"

# Remove existing container if present
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

log "launching $CONTAINER_NAME..."

mesh_network_ensure || { log "FATAL: mesh underlay network unusable"; exit 1; }

podman run -d \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_NAME" \
    --network "${NC_MESH_NETWORK}" \
    --cap-add NET_ADMIN \
    -v "${PODMAN_SOCKET}:/run/podman/podman.sock" \
    -v "${HOST_SPAWN_DIR}:/spawn" \
    -v "${HOST_SSH_KEYS_DIR}:/ssh-keys" \
    -v "${HOST_DB_DIR}:/data" \
    -v "${HOST_CLAUDE_CREDS}:/run/secrets/claude-credentials:ro" \
    -e HOST_SPAWN_DIR="$HOST_SPAWN_DIR" \
    -e HOST_SSH_KEYS_DIR="$HOST_SSH_KEYS_DIR" \
    -e HOST_CLAUDE_DIR="/home/hopper/.claude" \
    -e FORGEJO_ADMIN_TOKEN="$FORGEJO_ADMIN_TOKEN" \
    -e ROUTER_IMAGE="${ROUTER_IMAGE:-localhost/neoclaw-router:latest}" \
    -e ROUTER_BRIDGE_IP="${ROUTER_BRIDGE_IP}" \
    -e ROUTER_ENDPOINT="${ROUTER_ENDPOINT}" \
    -e NC_MESH_NETWORK="${NC_MESH_NETWORK}" \
    -e NC_MESH_SUBNET="${NC_MESH_SUBNET}" \
    -e NC_MESH_GATEWAY="${NC_MESH_GATEWAY}" \
    -e HUB_IMAGE="${HUB_IMAGE:-localhost/neoclaw-hub:latest}" \
    -e NEOCLAW_AS_TOKEN="$NEOCLAW_AS_TOKEN" \
    -e NEOCLAW_HS_TOKEN="$NEOCLAW_HS_TOKEN" \
    -e NEOCLAW_SYNAPSE_URL="${NEOCLAW_SYNAPSE_URL:-http://10.0.0.2:8008}" \
    -e NEOCLAW_SERVER_NAME="${NEOCLAW_SERVER_NAME:-matrix.home}" \
    -e NEOCLAW_MANAGER_URL="${NEOCLAW_MANAGER_URL:-http://10.0.0.3:9200}" \
    -e NEOCLAW_OPERATORS="${NEOCLAW_OPERATORS:-evans,hopper}" \
    -e NEOCLAW_APPSERVICE_USER="${NEOCLAW_APPSERVICE_USER:-neoclaw}" \
    "$IMAGE"

log "started. checking health..."
sleep 3

# Wait for Manager (WG + Router + Hub + Rails boot)
for i in $(seq 1 40); do
    if podman exec "$CONTAINER_NAME" curl -sf http://localhost:9200/health >/dev/null 2>&1; then
        log "manager is up"
        update_host_peer || true
        render_user_configs || true
        log ""
        log "Router key this boot: $(cat "${HOST_SPAWN_DIR}/runtime/router.pubkey" 2>/dev/null | cut -c1-12)..."
        log "Manager:  http://10.0.0.3:9200/"
        log "Router:   podman exec wg-router wg show"
        log "Hub:      http://10.0.0.4:3100/health"
        log "Logs:     podman logs -f $CONTAINER_NAME"
        exit 0
    fi
    sleep 2
done

log "WARNING: manager didn't come up in 80 seconds"
log "check logs: podman logs $CONTAINER_NAME"
exit 1
