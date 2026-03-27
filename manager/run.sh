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

HOST_SPAWN_DIR="/var/lib/neoclaw/spawn"
HOST_SSH_KEYS_DIR="/var/lib/neoclaw/sftp-keys"
HOST_DB_DIR="/var/lib/neoclaw/manager-db"
HOST_CLAUDE_CREDS="/var/lib/neoclaw/secrets/claude-credentials.json"
PODMAN_SOCKET="/run/podman/podman.sock"

# Service credentials
FORGEJO_ADMIN_TOKEN="${FORGEJO_ADMIN_TOKEN:-1f0759db1301cd07f336c119ef0cd8287984433e}"

# Matrix tokens — Manager passes these through to the Hub container
NEOCLAW_AS_TOKEN="${NEOCLAW_AS_TOKEN:-f6f2b7713fa76c0d9b8785770276a59181e55c159304bff93fcf0a54bd75f356}"
NEOCLAW_HS_TOKEN="${NEOCLAW_HS_TOKEN:-091c5f175e45ee0b3196cdce5ff869be1d1cf78de0470f80298009a3c5ec9d91}"

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
    -e HOST_SPAWN_DIR="$HOST_SPAWN_DIR" \
    -e HOST_SSH_KEYS_DIR="$HOST_SSH_KEYS_DIR" \
    -e HOST_CLAUDE_DIR="/home/hopper/.claude" \
    -e FORGEJO_ADMIN_TOKEN="$FORGEJO_ADMIN_TOKEN" \
    -e ROUTER_IMAGE="${ROUTER_IMAGE:-localhost/neoclaw-router:latest}" \
    -e ROUTER_BRIDGE_IP="${ROUTER_BRIDGE_IP:-10.88.0.20}" \
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
        log ""
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
