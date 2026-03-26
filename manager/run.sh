#!/bin/bash
set -euo pipefail

# Launch the Manager container.
#
# Mounts:
#   /run/podman/podman.sock        — host podman socket (create/destroy agents)
#   /spawn                         — spawn.json staging (Manager writes, podman reads)
#   /app/db                        — persistent SQLite database
#   /run/secrets/claude-credentials — Claude OAuth creds (refreshes externally)
#
# Secrets are passed as env vars at runtime — not baked into the image.

CONTAINER_NAME="neoclaw-manager"
IMAGE="localhost/neoclaw-manager:latest"

HOST_SPAWN_DIR="/var/lib/neoclaw/spawn"
HOST_SSH_KEYS_DIR="/var/lib/neoclaw/sftp-keys"
HOST_DB_DIR="/var/lib/neoclaw/manager-db"
HOST_CLAUDE_CREDS="/var/lib/neoclaw/secrets/claude-credentials.json"
HOST_WG_CONF="/var/lib/neoclaw/manager-wg/wg0.conf"
PODMAN_SOCKET="/run/podman/podman.sock"

FORGEJO_ADMIN_TOKEN="${FORGEJO_ADMIN_TOKEN:-1f0759db1301cd07f336c119ef0cd8287984433e}"
ROUTER_PUBKEY=$(podman exec wg-router wg show wg0 public-key 2>/dev/null) || { echo "[manager-run] FATAL: can't reach wg-router"; exit 1; }
ROUTER_ENDPOINT="10.88.0.20:51820"

log() { echo "[manager-run] $*"; }

# Ensure host directories exist
mkdir -p "$HOST_SPAWN_DIR" "$HOST_SSH_KEYS_DIR" "$HOST_DB_DIR"

# Remove existing container if present
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

log "launching $CONTAINER_NAME..."

podman run -d \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_NAME" \
    --cap-add NET_ADMIN \
    -v "${PODMAN_SOCKET}:/run/podman/podman.sock" \
    -v "${HOST_SPAWN_DIR}:/spawn" \
    -v "${HOST_SSH_KEYS_DIR}:/ssh-keys" \
    -v "${HOST_DB_DIR}:/data" \
    -v "${HOST_CLAUDE_CREDS}:/run/secrets/claude-credentials:ro" \
    -v "${HOST_WG_CONF}:/etc/wireguard/wg0.conf:ro" \
    -e HOST_SPAWN_DIR="$HOST_SPAWN_DIR" \
    -e HOST_SSH_KEYS_DIR="$HOST_SSH_KEYS_DIR" \
    -e HOST_CLAUDE_CREDENTIALS="$HOST_CLAUDE_CREDS" \
    -e FORGEJO_ADMIN_TOKEN="$FORGEJO_ADMIN_TOKEN" \
    -e ROUTER_PUBKEY="$ROUTER_PUBKEY" \
    -e ROUTER_ENDPOINT="$ROUTER_ENDPOINT" \
    "$IMAGE"

log "started. checking health..."
sleep 3

# Wait for the Manager to come up (WG + Rails boot)
for i in $(seq 1 20); do
    if podman exec "$CONTAINER_NAME" curl -sf http://localhost:9200/health >/dev/null 2>&1; then
        log "manager is up"

        # Show WG status inside the container
        podman exec "$CONTAINER_NAME" wg show wg0 2>/dev/null | head -8

        log ""
        log "Manager running at 10.0.0.2:9200 (over WireGuard)"
        log "Admin UI:  http://10.0.0.2:9200/"
        log "Health:    http://10.0.0.2:9200/health"
        log "Logs:      podman logs -f $CONTAINER_NAME"
        exit 0
    fi
    sleep 2
done

log "WARNING: manager didn't come up in 40 seconds"
log "check logs: podman logs $CONTAINER_NAME"
exit 1
