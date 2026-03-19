#!/bin/bash
set -euo pipefail

# Build the Manager container image.
#
# This script generates a fresh WG keypair, collects service public keys,
# and bakes everything into the image. The host never sees the Manager's
# WG private key after the build completes.
#
# After building, it peers the new Manager pubkey on all host WG interfaces
# so the Manager can reach every service.
#
# Secrets baked into the image:
#   /run/secrets/wg_private_key    — Manager's WG private key (host forgets)
#   /run/secrets/forgejo_token     — Forgejo admin API token
#   /run/secrets/wg_peers.json     — All service WG public keys + endpoints
#
# Host mounts (NOT baked — passed at runtime):
#   /run/podman/podman.sock        — podman socket
#   /run/secrets/claude-credentials — Claude OAuth credentials (refreshes)
#   /spawn                         — spawn.json staging directory
#   /app/db                        — persistent SQLite database
#
# Usage:
#   sudo ./build.sh                # build + peer
#   sudo ./build.sh build-only     # build without peering (for CI)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$PROJECT_DIR/infra"
KEYDIR="$INFRA_DIR/wireguard/keys"
SECRETS_DIR="$SCRIPT_DIR/build-secrets"
IMAGE_NAME="localhost/neoclaw-manager:latest"

BRIDGE_GATEWAY="${BRIDGE_GATEWAY:-10.88.0.1}"

log() { echo "[manager-build] $*"; }

# =================================================================
# Step 1: Generate fresh WG keypair
# =================================================================

log "generating WG keypair..."
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

wg genkey > "$SECRETS_DIR/wg_private_key"
chmod 600 "$SECRETS_DIR/wg_private_key"
wg pubkey < "$SECRETS_DIR/wg_private_key" > "$SECRETS_DIR/wg_public_key"

MANAGER_PUBKEY=$(cat "$SECRETS_DIR/wg_public_key")
log "manager pubkey: ${MANAGER_PUBKEY:0:20}..."

# =================================================================
# Step 2: Collect service public keys + endpoints
# =================================================================

log "collecting service peers..."

# Read services.conf and build peer list for the Manager.
# The Manager needs to reach every service over WG.
# Endpoints use the podman bridge gateway because the Manager
# container reaches host WG ports through the bridge.
PEERS="["
FIRST=true
while read -r name ip port svc_port rest; do
    [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
    pubkey_file="$KEYDIR/wg-${name}.pub"
    if [ ! -f "$pubkey_file" ]; then
        log "  WARNING: no public key for $name, skipping"
        continue
    fi

    pubkey=$(cat "$pubkey_file")
    endpoint="${BRIDGE_GATEWAY}:${port}"

    $FIRST || PEERS+=","
    FIRST=false
    PEERS+=$(cat <<PEER
{"public_key":"$pubkey","endpoint":"$endpoint","allowed_ips":"${ip}/32"}
PEER
)
    log "  peer: $name ($ip via $endpoint)"
done < "$INFRA_DIR/services.conf"
PEERS+="]"

echo "$PEERS" | python3 -m json.tool > "$SECRETS_DIR/wg_peers.json"

# =================================================================
# Step 3: Copy Forgejo admin token
# =================================================================

FORGEJO_TOKEN="${FORGEJO_ADMIN_TOKEN:-1f0759db1301cd07f336c119ef0cd8287984433e}"
echo -n "$FORGEJO_TOKEN" > "$SECRETS_DIR/forgejo_token"
chmod 600 "$SECRETS_DIR/forgejo_token"
log "forgejo token: ${FORGEJO_TOKEN:0:10}..."

# =================================================================
# Step 4: Build the image
# =================================================================

log "building image..."
podman build \
    -t "$IMAGE_NAME" \
    -f "$SCRIPT_DIR/Containerfile" \
    "$SCRIPT_DIR"

BUILD_EXIT=$?

# =================================================================
# Step 5: Clean up build secrets from host filesystem
# =================================================================

# The private key is now only inside the image layers.
MANAGER_PUBKEY_SAVED=$(cat "$SECRETS_DIR/wg_public_key")
rm -rf "$SECRETS_DIR"
log "build secrets removed from host"

if [ $BUILD_EXIT -ne 0 ]; then
    log "FATAL: build failed"
    exit 1
fi

log "image built: $IMAGE_NAME"

# =================================================================
# Step 6: Peer the Manager on all host WG interfaces
# =================================================================

if [ "${1:-}" = "build-only" ]; then
    log "build-only mode — skipping peering"
    log "manager public key: $MANAGER_PUBKEY_SAVED"
    exit 0
fi

log "peering manager on host WG interfaces..."

MANAGER_IP="10.0.0.2"
while read -r name ip port svc_port rest; do
    [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue

    iface="wg-${name}"
    wg set "$iface" peer "$MANAGER_PUBKEY_SAVED" allowed-ips "${MANAGER_IP}/32" 2>/dev/null \
        && log "  peered on $iface" \
        || log "  WARNING: failed to peer on $iface"
done < "$INFRA_DIR/services.conf"

log "done. manager pubkey: $MANAGER_PUBKEY_SAVED"
log ""
log "launch with:"
log "  sudo ./run.sh"
