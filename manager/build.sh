#!/bin/bash
set -euo pipefail

# Build the Manager container image.
#
# Router topology: Manager has one WG peer — the Router.
# This script generates a WG keypair, writes wg0.conf for the Manager,
# registers the new pubkey on the Router, and builds the image.
#
# Usage:
#   sudo ./build.sh                # build + peer Router + restart
#   sudo ./build.sh build-only     # build without peering or restart

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_NAME="localhost/neoclaw-manager:latest"

MANAGER_WG_DIR="/var/lib/neoclaw/manager-wg"
MANAGER_WG_IP="10.0.0.3"
ROUTER_BRIDGE_IP="10.88.0.20"
ROUTER_WG_PORT="51820"

log() { echo "[manager-build] $*"; }

# =================================================================
# Step 1: Generate fresh WG keypair + write wg0.conf
# =================================================================

log "generating WG keypair..."
mkdir -p "$MANAGER_WG_DIR"
chmod 700 "$MANAGER_WG_DIR"

PRIVKEY=$(wg genkey)
PUBKEY=$(echo "$PRIVKEY" | wg pubkey)

log "manager pubkey: ${PUBKEY:0:20}..."

# Get Router's public key
ROUTER_PUBKEY=$(podman exec wg-router wg show wg0 public-key 2>/dev/null) || {
    log "FATAL: can't reach wg-router — is it running?"
    exit 1
}
log "router pubkey: ${ROUTER_PUBKEY:0:20}..."

cat > "$MANAGER_WG_DIR/wg0.conf" <<EOF
[Interface]
PrivateKey = $PRIVKEY
Address = ${MANAGER_WG_IP}/32

[Peer]
PublicKey = $ROUTER_PUBKEY
Endpoint = ${ROUTER_BRIDGE_IP}:${ROUTER_WG_PORT}
AllowedIPs = 10.0.0.0/16
PersistentKeepalive = 25
EOF

chmod 600 "$MANAGER_WG_DIR/wg0.conf"
log "wg0.conf written to $MANAGER_WG_DIR"

# =================================================================
# Step 2: Build the image
# =================================================================

log "building image..."
podman build \
    -t "$IMAGE_NAME" \
    -f "$SCRIPT_DIR/Containerfile" \
    "$SCRIPT_DIR"

if [ $? -ne 0 ]; then
    log "FATAL: build failed"
    exit 1
fi

log "image built: $IMAGE_NAME"

# =================================================================
# Step 3: Register Manager's new pubkey on the Router
# =================================================================

if [ "${1:-}" = "build-only" ]; then
    log "build-only mode — skipping peering and restart"
    log "manager public key: $PUBKEY"
    exit 0
fi

log "peering with Router..."
podman exec wg-router wg set wg0 peer "$PUBKEY" allowed-ips "${MANAGER_WG_IP}/32" 2>/dev/null \
    && log "Router peered" \
    || { log "FATAL: failed to peer with Router"; exit 1; }

# =================================================================
# Step 4: Restart Manager
# =================================================================

log "restarting Manager..."
"$SCRIPT_DIR/run.sh"

# Hub's persistent HTTP client caches the old Manager connection.
# New WG key = dead socket. Restart the Hub to clear it.
log "restarting Hub (stale connection to old Manager WG key)..."
systemctl restart neoclaw-rails-hub.service 2>/dev/null \
    && log "Hub restarted" \
    || log "WARNING: could not restart Hub — restart manually"
