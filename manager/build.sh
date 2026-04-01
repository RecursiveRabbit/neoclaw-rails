#!/bin/bash
set -euo pipefail

# Build the NeoClaw infrastructure images.
#
# Generates fresh WG keypairs for the Router, Manager, and Hub.
# Bakes keys and configs into each image. When the containers start,
# the WG mesh comes up automatically — no runtime key discovery.
#
# The host's nc-host WG interface is updated to peer with the new Router.
#
# Options:
#   --endpoint IP:PORT   Public endpoint for Router WG (for user configs)
#   --users N            Number of user WG configs to generate (default: 0)
#   build-only           Build without restart (positional, must be last)
#
# Usage:
#   sudo ./build.sh                                    # build all + restart
#   sudo ./build.sh --endpoint 1.2.3.4:51821 --users 2 # with user configs
#   sudo ./build.sh build-only                         # build without restart

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

MANAGER_IMAGE="localhost/neoclaw-manager:latest"
ROUTER_IMAGE="localhost/neoclaw-router:latest"
HUB_IMAGE="localhost/neoclaw-hub:latest"

ROUTER_BRIDGE_IP="10.88.0.20"
ROUTER_WG_PORT="51820"

# Host's persistent key (one-time setup, never regenerated)
HOST_PUBKEY_PATH="$PROJECT_DIR/infra/wireguard/keys/nc-host.pub"
HOST_KEY_PATH="$PROJECT_DIR/infra/wireguard/keys/nc-host.key"

log() { echo "[build] $*"; }

# =================================================================
# Parse arguments
# =================================================================

ENDPOINT=""
USER_COUNT=0
BUILD_ONLY=false

while [ $# -gt 0 ]; do
    case "$1" in
        --endpoint) ENDPOINT="$2"; shift 2 ;;
        --users)    USER_COUNT="$2"; shift 2 ;;
        build-only) BUILD_ONLY=true; shift ;;
        *)          log "unknown argument: $1"; exit 1 ;;
    esac
done

# Parse endpoint into IP and port
ENDPOINT_IP=""
ENDPOINT_PORT=""
if [ -n "$ENDPOINT" ]; then
    ENDPOINT_IP="${ENDPOINT%:*}"
    ENDPOINT_PORT="${ENDPOINT##*:}"
    if [ "$ENDPOINT_IP" = "$ENDPOINT_PORT" ]; then
        log "FATAL: --endpoint must be IP:PORT (e.g. 1.2.3.4:51821)"
        exit 1
    fi
    log "public endpoint: ${ENDPOINT_IP}:${ENDPOINT_PORT}"
fi

if [ "$USER_COUNT" -gt 0 ]; then
    log "generating $USER_COUNT user config(s)"
    if [ -z "$ENDPOINT" ]; then
        log "WARNING: no --endpoint set — user configs will have no Endpoint line"
    fi
fi

# =================================================================
# Step 1: Generate all WG keypairs
# =================================================================

log "generating WG keypairs..."

ROUTER_PRIVKEY=$(wg genkey)
ROUTER_PUBKEY=$(echo "$ROUTER_PRIVKEY" | wg pubkey)

MANAGER_PRIVKEY=$(wg genkey)
MANAGER_PUBKEY=$(echo "$MANAGER_PRIVKEY" | wg pubkey)

HUB_PRIVKEY=$(wg genkey)
HUB_PUBKEY=$(echo "$HUB_PRIVKEY" | wg pubkey)

HOST_PUBKEY=$(cat "$HOST_PUBKEY_PATH")

log "  router:  ${ROUTER_PUBKEY:0:20}..."
log "  manager: ${MANAGER_PUBKEY:0:20}..."
log "  hub:     ${HUB_PUBKEY:0:20}..."
log "  host:    ${HOST_PUBKEY:0:20}..."

# User keypairs (10.2.0.1, 10.2.0.2, ...)
declare -a USER_PRIVKEYS=()
declare -a USER_PUBKEYS=()
declare -a USER_IPS=()

for i in $(seq 1 "$USER_COUNT"); do
    privkey=$(wg genkey)
    pubkey=$(echo "$privkey" | wg pubkey)
    ip="10.2.0.${i}"
    USER_PRIVKEYS+=("$privkey")
    USER_PUBKEYS+=("$pubkey")
    USER_IPS+=("$ip")
    log "  user-$i:  ${pubkey:0:20}... ($ip)"
done

# =================================================================
# Step 2: Write keys and configs into build contexts
# =================================================================

# --- Router ---
log "writing Router key and config..."

echo "$ROUTER_PRIVKEY" > "$PROJECT_DIR/router/wg-private.key"
chmod 600 "$PROJECT_DIR/router/wg-private.key"

cat > "$PROJECT_DIR/router/config/config.yml" <<EOF
router:
  wg_interface: wg0
  wg_address: "10.0.0.1/32"
  wg_listen_port: 51820
  wg_private_key: /etc/wireguard/private.key
  api_port: 8080
  lan_interface: eth0

network:
  host_ip: "10.0.0.2"
  manager_ip: "10.0.0.3"
  hub_ip: "10.0.0.4"
  hub_ip: "10.0.0.4"
  agent_subnet: "10.1.0.0/16"
  user_subnet: "10.2.0.0/16"

peers:
  host:
    pubkey: "$HOST_PUBKEY"
    allowed_ips: "10.0.0.2/32"
  manager:
    pubkey: "$MANAGER_PUBKEY"
    allowed_ips: "10.0.0.3/32"
  hub:
    pubkey: "$HUB_PUBKEY"
    allowed_ips: "10.0.0.4/32"
EOF

# Append user peers to Router config
for i in $(seq 0 $((USER_COUNT - 1))); do
    cat >> "$PROJECT_DIR/router/config/config.yml" <<EOF
  user-$((i + 1)):
    pubkey: "${USER_PUBKEYS[$i]}"
    allowed_ips: "${USER_IPS[$i]}/32"
EOF
done

cat >> "$PROJECT_DIR/router/config/config.yml" <<EOF

services:
  default:
    tcp: [3100]
    udp: [53]
  forgejo:
    tcp: [3000, 2222]
  vikunja:
    tcp: [3456]
  comfyui:
    tcp: [8188]
  valley:
    tcp: [4006]
  semantic-search:
    tcp: [8100]
  matrix:
    tcp: [8008]
  ssh:
    tcp: [22]
  ollama:
    tcp: [11434]
EOF

# --- Manager ---
log "writing Manager WG config..."

cat > "$SCRIPT_DIR/wg0.conf" <<EOF
[Interface]
PrivateKey = $MANAGER_PRIVKEY
Address = 10.0.0.3/32

[Peer]
PublicKey = $ROUTER_PUBKEY
Endpoint = ${ROUTER_BRIDGE_IP}:${ROUTER_WG_PORT}
AllowedIPs = 10.0.0.0/8
PersistentKeepalive = 25
EOF
chmod 600 "$SCRIPT_DIR/wg0.conf"

echo "$ROUTER_PUBKEY" > "$SCRIPT_DIR/router_pubkey"

# --- Hub ---
log "writing Hub WG config..."

cat > "$PROJECT_DIR/wg0.conf" <<EOF
[Interface]
PrivateKey = $HUB_PRIVKEY
Address = 10.0.0.4/32

[Peer]
PublicKey = $ROUTER_PUBKEY
Endpoint = ${ROUTER_BRIDGE_IP}:${ROUTER_WG_PORT}
AllowedIPs = 10.0.0.0/8
PersistentKeepalive = 25
EOF
chmod 600 "$PROJECT_DIR/wg0.conf"

# --- User configs ---
if [ "$USER_COUNT" -gt 0 ]; then
    USER_CONFIG_DIR="$PROJECT_DIR/user-configs"
    rm -rf "$USER_CONFIG_DIR"
    mkdir -p "$USER_CONFIG_DIR"

    for i in $(seq 0 $((USER_COUNT - 1))); do
        NUM=$((i + 1))
        CONF="$USER_CONFIG_DIR/user-${NUM}.conf"

        cat > "$CONF" <<USEREOF
[Interface]
PrivateKey = ${USER_PRIVKEYS[$i]}
Address = ${USER_IPS[$i]}/32
DNS = 10.0.0.2

[Peer]
PublicKey = $ROUTER_PUBKEY
AllowedIPs = 10.0.0.0/8
PersistentKeepalive = 25
USEREOF

        # Add endpoint if provided
        if [ -n "$ENDPOINT" ]; then
            sed -i "/^PublicKey/a Endpoint = ${ENDPOINT_IP}:${ENDPOINT_PORT}" "$CONF"
        fi

        chmod 600 "$CONF"
        log "  wrote user-${NUM}.conf (${USER_IPS[$i]})"
    done
    log "$USER_COUNT user config(s) in $USER_CONFIG_DIR/"
fi

# --- Build config (baked into Manager image) ---
cat > "$SCRIPT_DIR/build_config.sh" <<EOF
# Generated by build.sh — baked into Manager image.
# Sourced by entrypoint.sh at boot.
ROUTER_PUBLISH_WG="${ENDPOINT_PORT}"
EOF

# =================================================================
# Step 3: Vendor gems
# =================================================================

log "vendoring Manager gems..."
mkdir -p "$SCRIPT_DIR/vendor/bundle"
podman run --rm --network=host \
    -v "$SCRIPT_DIR:/app:Z" \
    -w /app \
    ruby:3.3-slim \
    bash -c 'apt-get update -qq && apt-get install -y -qq build-essential libsqlite3-dev libyaml-dev pkg-config > /dev/null 2>&1 && bundle config set --local path vendor/bundle && bundle config set --local without "development test" && bundle install --quiet'
log "Manager gems vendored"

log "vendoring Hub gems..."
mkdir -p "$PROJECT_DIR/vendor/bundle"
podman run --rm --network=host \
    -v "$PROJECT_DIR:/app:Z" \
    -w /app \
    ruby:3.3-slim \
    bash -c 'apt-get update -qq && apt-get install -y -qq build-essential libyaml-dev pkg-config > /dev/null 2>&1 && bundle config set --local path vendor/bundle && bundle config set --local without "development test" && bundle install --quiet'
log "Hub gems vendored"

# =================================================================
# Step 4: Build images
# =================================================================

log "building Router image..."
podman build --network=host -t "$ROUTER_IMAGE" -f "$PROJECT_DIR/router/Containerfile" "$PROJECT_DIR/router" \
    || { log "FATAL: Router build failed"; exit 1; }
log "Router image built"

log "building Manager image..."
podman build --network=host -t "$MANAGER_IMAGE" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR" \
    || { log "FATAL: Manager build failed"; exit 1; }
log "Manager image built"

log "building Hub image..."
podman build --network=host -t "$HUB_IMAGE" -f "$PROJECT_DIR/Containerfile.hub" "$PROJECT_DIR" \
    || { log "FATAL: Hub build failed"; exit 1; }
log "Hub image built"

# =================================================================
# Step 5: Update host's nc-host to peer with new Router
# =================================================================

log "updating host WG peer..."

# Update running interface
wg set nc-host peer "$ROUTER_PUBKEY" \
    endpoint "${ROUTER_BRIDGE_IP}:${ROUTER_WG_PORT}" \
    allowed-ips "10.0.0.0/8" \
    persistent-keepalive 25 2>/dev/null \
    && log "host nc-host peer updated (live)" \
    || log "WARNING: could not update nc-host peer (interface may not exist yet)"

# Persist to config file
if [ -f "$HOST_KEY_PATH" ]; then
    HOST_PRIVKEY=$(cat "$HOST_KEY_PATH")
    cat > /etc/wireguard/nc-host.conf <<EOF
[Interface]
PrivateKey = $HOST_PRIVKEY
Address = 10.0.0.2/32

[Peer]
PublicKey = $ROUTER_PUBKEY
Endpoint = ${ROUTER_BRIDGE_IP}:${ROUTER_WG_PORT}
AllowedIPs = 10.0.0.0/8
PersistentKeepalive = 25
EOF
    chmod 600 /etc/wireguard/nc-host.conf
    log "nc-host.conf updated"
fi

# =================================================================
# Step 6: Clean up sensitive files from build contexts
# =================================================================
# Keys are baked into images now. Remove from disk.
# .gitignore should also exclude these.

rm -f "$PROJECT_DIR/router/wg-private.key"
rm -f "$SCRIPT_DIR/wg0.conf"
rm -f "$SCRIPT_DIR/router_pubkey"
rm -f "$SCRIPT_DIR/build_config.sh"
rm -f "$PROJECT_DIR/wg0.conf"
log "build artifacts cleaned up"

# =================================================================
# Step 7: Restart Manager (which launches Router + Hub on boot)
# =================================================================

if [ "$BUILD_ONLY" = "true" ]; then
    log "build-only mode — skipping restart"
    exit 0
fi

log "restarting Manager..."
"$SCRIPT_DIR/run.sh"
