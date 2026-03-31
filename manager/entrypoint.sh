#!/bin/bash
set -u

# NeoClaw Manager Entrypoint — the orchestrator.
#
# WG config is baked into the image at build time. The Router and Hub
# images also have their keys baked in. When they start, the WG mesh
# just comes up — no runtime key discovery, no peering, no polling.
#
# Boot sequence:
# 1. WG up (config baked, handshake happens when Router starts)
# 2. Clean slate — stop stale infrastructure containers
# 3. Start Router (keys baked, no volumes)
# 4. Verify Router + WG handshake
# 5. Start Hub (keys baked, env vars for Matrix)
# 6. Verify Hub health (warn-only)
# 7. DB migrate/seed
# 8. Rails start → Orchestrator reconciles orphaned pods
#
# Runtime mounts:
#   /run/podman/podman.sock        — podman socket (host)
#   /run/secrets/claude-credentials — Claude OAuth creds
#   /spawn                         — spawn.json staging
#   /ssh-keys                      — agent SSH keys
#   /data                          — persistent SQLite database

log() { echo "[manager] $*"; }
die() { log "FATAL: $*"; exit 1; }

PODMAN="podman --remote --url unix:///run/podman/podman.sock"

# Build config — baked at build time. Contains ROUTER_PUBLISH_WG if users configured.
source /etc/neoclaw/build_config.sh 2>/dev/null || true

# =====================================================================
# Phase 1: WireGuard up
# =====================================================================
# Config is baked into the image. The Router isn't up yet so there's
# no handshake, but the interface and routes are ready.

wg-quick up wg0 || die "wg-quick failed"
log "wireguard up (10.0.0.3)"

# =====================================================================
# Phase 2: Clean slate
# =====================================================================

log "cleaning up stale infrastructure..."
$PODMAN rm -f wg-router 2>/dev/null || true
$PODMAN rm -f neoclaw-hub 2>/dev/null || true

# =====================================================================
# Phase 3: Start Router
# =====================================================================
# Keys and config baked into the image. No volumes needed.
# Router knows Manager and Hub as static peers from config.yml.

ROUTER_IMAGE="${ROUTER_IMAGE:-localhost/neoclaw-router:latest}"

ROUTER_PUBLISH_ARGS=""
if [ -n "${ROUTER_PUBLISH_WG:-}" ]; then
    ROUTER_PUBLISH_ARGS="-p ${ROUTER_PUBLISH_WG}:51820/udp"
    log "Router WG published on host port ${ROUTER_PUBLISH_WG}/udp"
fi

log "starting Router..."
ROUTER_ID=$($PODMAN run -d \
    --name wg-router \
    --hostname wg-router \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --sysctl net.ipv4.ip_forward=1 \
    --ip "${ROUTER_BRIDGE_IP:-10.88.0.20}" \
    $ROUTER_PUBLISH_ARGS \
    "$ROUTER_IMAGE" 2>&1) || die "Router failed to start: $ROUTER_ID"

log "Router started: ${ROUTER_ID:0:12}"

# =====================================================================
# Phase 4: Verify Router + WG handshake
# =====================================================================
# Keys are pre-shared (baked at build). Handshake should be fast.

log "waiting for Router..."
for i in $(seq 1 30); do
    if $PODMAN exec wg-router curl -sf http://localhost:8080/health >/dev/null 2>&1; then
        log "Router is healthy"
        break
    fi
    [ "$i" -eq 30 ] && {
        $PODMAN logs --tail 20 wg-router 2>&1 || true
        die "Router failed to become healthy"
    }
    sleep 1
done

log "verifying WG connectivity..."
# Can't use ping — Router's firewall drops ICMP. Use the API over WG instead.
for i in $(seq 1 30); do
    if curl -sf http://10.0.0.1:8080/health >/dev/null 2>&1; then
        log "WG mesh connected — Router API reachable at 10.0.0.1:8080"
        break
    fi
    if [ "$i" -eq 30 ]; then
        log "WG state:"
        wg show wg0 2>&1 || true
        ip route 2>&1 || true
        die "WG handshake failed — cannot reach Router API at 10.0.0.1:8080"
    fi
    sleep 2
done

# =====================================================================
# Phase 5: Start Hub
# =====================================================================
# Hub has its own WG identity (10.0.0.4). Keys baked in.
# Matrix credentials passed as env vars. Hub failure is not fatal.

HUB_IMAGE="${HUB_IMAGE:-localhost/neoclaw-hub:latest}"

log "starting Hub..."
HUB_RESULT=$($PODMAN run -d \
    --name neoclaw-hub \
    --hostname neoclaw-hub \
    --cap-add NET_ADMIN \
    -e "NEOCLAW_AS_TOKEN=${NEOCLAW_AS_TOKEN:-}" \
    -e "NEOCLAW_HS_TOKEN=${NEOCLAW_HS_TOKEN:-}" \
    -e "NEOCLAW_SYNAPSE_URL=${NEOCLAW_SYNAPSE_URL:-http://10.0.0.2:8008}" \
    -e "NEOCLAW_SERVER_NAME=${NEOCLAW_SERVER_NAME:-matrix.home}" \
    -e "NEOCLAW_MANAGER_URL=${NEOCLAW_MANAGER_URL:-http://10.0.0.3:9200}" \
    -e "NEOCLAW_OPERATORS=${NEOCLAW_OPERATORS:-evans,hopper}" \
    -e "NEOCLAW_APPSERVICE_USER=${NEOCLAW_APPSERVICE_USER:-neoclaw}" \
    -e "RAILS_ENV=production" \
    -e "SECRET_KEY_BASE=${SECRET_KEY_BASE:-$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')}" \
    -e "PORT=3100" \
    "$HUB_IMAGE" 2>&1)

if [ $? -eq 0 ]; then
    log "Hub started: ${HUB_RESULT:0:12}"
else
    log "WARNING: Hub failed to start: $HUB_RESULT"
fi

# =====================================================================
# Phase 6: Verify Hub health (warn-only)
# =====================================================================

HUB_HEALTHY=false
log "waiting for Hub..."
for i in $(seq 1 20); do
    if curl -sf http://10.0.0.4:3100/health >/dev/null 2>&1; then
        log "Hub is healthy (10.0.0.4)"
        HUB_HEALTHY=true
        break
    fi
    sleep 2
done

if [ "$HUB_HEALTHY" = "false" ]; then
    log "WARNING: Hub did not become healthy"
    $PODMAN logs --tail 20 neoclaw-hub 2>&1 || true
fi

# =====================================================================
# Phase 7: Database
# =====================================================================

export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')}"

mkdir -p /data
if [ ! -f /data/manager_production.sqlite3 ]; then
    log "initializing database..."
    RAILS_ENV=production bin/rails db:schema:load
    RAILS_ENV=production bin/rails db:seed
    log "database ready"
else
    RAILS_ENV=production bin/rails db:migrate
    log "database migrated"
fi

# =====================================================================
# Phase 8: Start Rails
# =====================================================================
# Orchestrator initializer runs after boot: discovers orphaned agent
# pods and hot-swaps each one with fresh Router credentials.

# Bind to WG interface only. If you're on the mesh, you can reach Manager.
# If you're not, you can't. WG is the auth layer.
BIND_ADDR="10.0.0.3"
log "starting Manager on ${BIND_ADDR}:9200"
log "Router: up | Hub: ${HUB_HEALTHY} | Reconciliation: pending"
exec bin/rails server -b "$BIND_ADDR" -p 9200 -e production
