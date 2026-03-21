#!/bin/bash
set -euo pipefail

# Hot-swap an agent pod to a new container image.
#
# Preserves the workspace and Claude Code session so the agent
# resumes with --continue instead of re-cloning and re-orienting.
#
# Usage:
#   sudo ./swap-image.sh silas-general
#   sudo ./swap-image.sh silas-general localhost/neoclaw-agent:v2
#
# What happens:
#   1. Copy /workspace and /home/agent/.claude out of the running pod
#   2. Stop and remove the old pod
#   3. Start a new pod from the (optionally specified) image
#   4. Copy the preserved files into the new pod
#   5. Relay detects populated workspace → --continue (no cold boot)

INSTANCE="${1:?Usage: swap-image.sh <instance-name> [image]}"
IMAGE="${2:-localhost/neoclaw-agent:latest}"
RESCUE_DIR="/var/lib/neoclaw/swap-staging/${INSTANCE}"

log() { echo "[swap] $*"; }

# =================================================================
# Step 1: Verify the pod is running
# =================================================================

if ! podman inspect "$INSTANCE" &>/dev/null; then
    log "FATAL: no pod named $INSTANCE"
    exit 1
fi

STATE=$(podman inspect "$INSTANCE" --format '{{.State.Status}}')
if [ "$STATE" != "running" ]; then
    log "FATAL: $INSTANCE is $STATE, not running"
    exit 1
fi

log "$INSTANCE is running"

# =================================================================
# Step 2: Copy state out of the running pod
# =================================================================

rm -rf "$RESCUE_DIR"
mkdir -p "$RESCUE_DIR"

log "copying workspace..."
podman cp "${INSTANCE}:/workspace" "${RESCUE_DIR}/workspace"

log "copying .claude (session files)..."
podman cp "${INSTANCE}:/home/agent/.claude" "${RESCUE_DIR}/dot-claude"

# Grab the spawn.json path — we need it to start the new pod
SPAWN_JSON=$(podman inspect "$INSTANCE" --format '{{range .Mounts}}{{if eq .Destination "/run/secrets/spawn.json"}}{{.Source}}{{end}}{{end}}')
# Always use the live claude directory for new pods
CLAUDE_DIR="/home/hopper/.claude"

log "spawn.json: $SPAWN_JSON"
log "credentials: $CLAUDE_DIR (live directory mount)"

# =================================================================
# Step 3: Stop and remove the old pod
# =================================================================

log "stopping $INSTANCE..."
podman stop "$INSTANCE" 2>/dev/null || true
podman rm "$INSTANCE" 2>/dev/null || true
log "old pod removed"

# =================================================================
# Step 4: Start new pod from new image
# =================================================================

log "starting new pod from $IMAGE (swap hold)..."
podman run -d \
    --name "$INSTANCE" \
    --hostname "$INSTANCE" \
    --cap-add NET_ADMIN \
    -e SWAP_HOLD=1 \
    -v "${SPAWN_JSON}:/run/secrets/spawn.json:ro" \
    -v "${CLAUDE_DIR}:/run/secrets/claude:ro" \
    --memory 2g \
    --cpus 2 \
    "$IMAGE"

# Wait for entrypoint to reach the hold point (WG up, creds linked, MCP written)
log "waiting for entrypoint to reach hold..."
for i in $(seq 1 30); do
    if podman exec "$INSTANCE" test -f /tmp/.swap-hold 2>/dev/null; then
        log "entrypoint holding"
        break
    fi
    sleep 1
done

# =================================================================
# Step 5: Copy preserved state into the new pod
# =================================================================

log "restoring workspace..."
# Remove the empty /workspace created by the Containerfile
podman exec "$INSTANCE" rm -rf /workspace
podman cp "${RESCUE_DIR}/workspace" "${INSTANCE}:/workspace"
podman exec "$INSTANCE" chown -R agent:agent /workspace

log "restoring .claude session..."
# Merge — don't clobber the fresh mcp.json and settings.json from entrypoint
# Copy session files (the big ones) into the existing .claude dir
for f in "${RESCUE_DIR}/dot-claude/"*; do
    fname=$(basename "$f")
    # Skip config files that the entrypoint just wrote fresh
    case "$fname" in
        mcp.json|settings.json|.credentials.json) continue ;;
    esac
    podman cp "$f" "${INSTANCE}:/home/agent/.claude/${fname}"
done
podman exec "$INSTANCE" chown -R agent:agent /home/agent/.claude

# Release the hold — entrypoint re-chowns and starts the relay
log "releasing hold..."
podman exec "$INSTANCE" rm -f /tmp/.swap-hold

log "cleanup staging..."
rm -rf "$RESCUE_DIR"

# =================================================================
# Step 6: Verify
# =================================================================

log "checking health..."
sleep 3
HEALTH=$(podman exec "$INSTANCE" curl -sf http://localhost:9300/health 2>/dev/null || echo '{"error":"not ready"}')
log "health: $HEALTH"

log ""
log "done. $INSTANCE is running on $IMAGE"
log "relay will detect workspace and use --continue (hot swap)"
