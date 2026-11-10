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
# Step 1: Public inputs only
# =================================================================
# NO router/manager/hub keypair is generated here any more. Every boot
# generates them in the Manager's entrypoint (fresh Router key per Manager
# boot, reused for Router replacements within the boot). The build bakes
# only public facts: the host's persistent pubkey, the user pubkeys, and
# the service port map the boot-rendered Router config appends.

log "collecting public peers..."

HOST_PUBKEY=$(cat "$HOST_PUBKEY_PATH")
log "  host:    ${HOST_PUBKEY:0:20}..."

# User keypairs (10.2.0.1, 10.2.0.2, ...) — generated here because their
# private halves are an operator artifact for distribution, not deployment
# state. Only the public halves enter any image.
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

printf '%s\n' "$HOST_PUBKEY" > "$SCRIPT_DIR/nc-host.pub"

# =================================================================
# Step 2: Write public-only fragments into the build contexts
# =================================================================
# The Router's config.yml is rendered at boot (Manager entrypoint Phase 0)
# because it carries the Manager and Hub pubkeys, which are per-boot. Only
# static public fragments are baked here.

log "writing public config fragments..."

: > "$PROJECT_DIR/router/users-peers.fragment"
for i in $(seq 0 $((USER_COUNT - 1))); do
    cat >> "$PROJECT_DIR/router/users-peers.fragment" <<EOF
  user-$((i + 1)):
    pubkey: "${USER_PUBKEYS[$i]}"
    allowed_ips: "${USER_IPS[$i]}/32"
EOF
done

cat > "$PROJECT_DIR/router/services.yml" <<EOF

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

# --- User configs ---
if [ "$USER_COUNT" -gt 0 ]; then
    USER_CONFIG_DIR="$PROJECT_DIR/user-configs"
    rm -rf "$USER_CONFIG_DIR"
    mkdir -p "$USER_CONFIG_DIR"

    for i in $(seq 0 $((USER_COUNT - 1))); do
        NUM=$((i + 1))
        # Template, not a finished config: the Router pubkey is per-boot now,
        # so run.sh renders the final file from runtime/router.pubkey.
        CONF="$USER_CONFIG_DIR/user-${NUM}.conf.in"

        cat > "$CONF" <<USEREOF
[Interface]
PrivateKey = ${USER_PRIVKEYS[$i]}
Address = ${USER_IPS[$i]}/32
DNS = 10.0.0.2

[Peer]
PublicKey = __ROUTER_PUBKEY__
AllowedIPs = 10.0.0.0/8
PersistentKeepalive = 25
USEREOF

        # Add endpoint if provided
        if [ -n "$ENDPOINT" ]; then
            sed -i "/^PublicKey/a Endpoint = ${ENDPOINT_IP}:${ENDPOINT_PORT}" "$CONF"
        fi

        chmod 600 "$CONF"
        log "  wrote user-${NUM}.conf.in (${USER_IPS[$i]})"
    done
    log "$USER_COUNT user config template(s) in $USER_CONFIG_DIR/"
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

log "host WG peer: deferred to run.sh (Router pubkey is per-boot now)"

# =================================================================
# Step 6: Clean up build artifacts
# =================================================================
# There is no private key in any build context any more. Clean the
# public fragments and the generated build config.

rm -f "$PROJECT_DIR/router/users-peers.fragment"
rm -f "$PROJECT_DIR/router/services.yml"
rm -f "$SCRIPT_DIR/nc-host.pub"
rm -f "$SCRIPT_DIR/build_config.sh"
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
