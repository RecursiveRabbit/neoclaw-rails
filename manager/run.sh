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
HOST_CLAUDE_DIR="${HOST_CLAUDE_DIR:-/home/rook/.claude}"
HOST_WG_CONF="/var/lib/neoclaw/manager-wg/wg0.conf"
PODMAN_SOCKET="${PODMAN_SOCKET:-/run/user/1000/podman/podman.sock}"

FORGEJO_ADMIN_TOKEN="${FORGEJO_ADMIN_TOKEN:-1f0759db1301cd07f336c119ef0cd8287984433e}"
MATRIX_AS_TOKEN="${MATRIX_AS_TOKEN:-f6f2b7713fa76c0d9b8785770276a59181e55c159304bff93fcf0a54bd75f356}"
MATRIX_SERVER_NAME="${MATRIX_SERVER_NAME:-localhost}"
MATRIX_HOMESERVER_URL="${MATRIX_HOMESERVER_URL:-http://10.7.7.62:8008}"
ARCHIVER_URL="${ARCHIVER_URL:-http://10.0.0.2:4010}"
ARCHIVER_API_KEY="${ARCHIVER_API_KEY:-}"
VIKUNJA_TOKEN_URL="${VIKUNJA_TOKEN_URL:-}"
ROUTER_PUBKEY=$(podman exec wg-router wg show wg0 public-key 2>/dev/null) || { echo "[manager-run] FATAL: can't reach wg-router"; exit 1; }
ROUTER_ENDPOINT="${ROUTER_ENDPOINT:-host.containers.internal:51820}"
ROUTER_URL="${ROUTER_URL:-http://10.0.0.1:8080}"

log() { echo "[manager-run] $*"; }

# Preflight: refuse to start if router peer keys drift from host/manager reality.
# Use --fix to auto-heal (updates router config + restarts wg-router).
WG_DRIFT_CHECK="/home/rook/.openclaw/workspace/neoclaw-rails-upstream-2026-03-23/infra/scripts/wg-drift-check.sh"
if [ -x "$WG_DRIFT_CHECK" ]; then
  if ! "$WG_DRIFT_CHECK" >/tmp/manager_wg_drift.log 2>&1; then
    log "FATAL: WireGuard key drift detected."
    cat /tmp/manager_wg_drift.log || true
    log "Run: $WG_DRIFT_CHECK --fix"
    exit 1
  fi
fi

# Ensure host directories exist
mkdir -p "$HOST_SPAWN_DIR" "$HOST_SSH_KEYS_DIR" "$HOST_DB_DIR"

# Remove existing container if present
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

log "launching $CONTAINER_NAME..."

podman run -d \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_NAME" \
    --cap-add NET_ADMIN \
    -p 9201:9200 \
    -v "${PODMAN_SOCKET}:/run/podman/podman.sock" \
    -v "${HOST_SPAWN_DIR}:/spawn" \
    -v "${HOST_SSH_KEYS_DIR}:/ssh-keys" \
    -v "${HOST_DB_DIR}:/data" \
    -v "${HOST_CLAUDE_CREDS}:/run/secrets/claude-credentials:ro" \
    -v "${HOST_WG_CONF}:/etc/wireguard/wg0.conf:ro" \
    -e HOST_SPAWN_DIR="$HOST_SPAWN_DIR" \
    -e HOST_SSH_KEYS_DIR="$HOST_SSH_KEYS_DIR" \
    -e HOST_CLAUDE_CREDENTIALS="$HOST_CLAUDE_CREDS" \
    -e HOST_CLAUDE_DIR="$HOST_CLAUDE_DIR" \
    -e FORGEJO_ADMIN_TOKEN="$FORGEJO_ADMIN_TOKEN" \
    -e MATRIX_AS_TOKEN="$MATRIX_AS_TOKEN" \
    -e MATRIX_SERVER_NAME="$MATRIX_SERVER_NAME" \
    -e MATRIX_HOMESERVER_URL="$MATRIX_HOMESERVER_URL" \
    -e ARCHIVER_URL="$ARCHIVER_URL" \
    -e ARCHIVER_API_KEY="$ARCHIVER_API_KEY" \
    -e VIKUNJA_TOKEN_URL="$VIKUNJA_TOKEN_URL" \
    -e ROUTER_PUBKEY="$ROUTER_PUBKEY" \
    -e ROUTER_ENDPOINT="$ROUTER_ENDPOINT" \
    -e ROUTER_URL="$ROUTER_URL" \
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
