# runtime-keys.sh — per-boot key generation and config rendering.
#
# Sourced by manager/entrypoint.sh (Phase 0) and by the per-boot proof test.
# A function, not a script, so the test can render a boot without podman.
#
# Contract:
#   input  RUNTIME_DIR        container/host path that will hold this boot's keys
#   input  PUBLIC_DIR         directory holding nc-host.pub, users-peers.fragment,
#                             router-services.yml (defaults /etc/neoclaw)
#   input  HOST_WG_PUBKEY     host's persistent public key (required)
#   input  ROUTER_BRIDGE_IP   default 10.88.0.20
#   input  ROUTER_WG_PORT     default 51820
#   output ROUTER_PUBKEY, MANAGER_PUBKEY, HUB_PUBKEY, BOOT_ID (echoed, and in
#          $RUNTIME_DIR/boot.json)
#
# Nothing is read from the environment but the above; nothing is baked.

render_boot_runtime() {
    local public_dir="${PUBLIC_DIR:-/etc/neoclaw}"
    local bridge="${ROUTER_BRIDGE_IP:-10.88.0.20}"
    local wg_port="${ROUTER_WG_PORT:-51820}"

    if [ -z "${HOST_WG_PUBKEY:-}" ]; then
        echo "render_boot_runtime: HOST_WG_PUBKEY is required (host persistent pubkey)" >&2
        return 1
    fi
    if ! command -v wg >/dev/null 2>&1; then
        echo "render_boot_runtime: wireguard-tools (wg) not found" >&2
        return 1
    fi

    rm -rf "$RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR/router" "$RUNTIME_DIR/manager" "$RUNTIME_DIR/hub"
    chmod 700 "$RUNTIME_DIR"

    _gen_keypair() {  # $1 = private key path; echoes public key
        (umask 077 && wg genkey > "$1") || return 1
        wg pubkey < "$1"
    }

    ROUTER_PUBKEY=$(_gen_keypair "$RUNTIME_DIR/router/private.key")
    MANAGER_PUBKEY=$(_gen_keypair "$RUNTIME_DIR/manager/private.key")
    HUB_PUBKEY=$(_gen_keypair "$RUNTIME_DIR/hub/private.key")
    BABO_PUBKEY=$(_gen_keypair "$RUNTIME_DIR/babo/private.key")
    BOOT_ID=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')

    cat > "$RUNTIME_DIR/router/config.yml" <<EOF
router:
  wg_interface: wg0
  wg_address: "10.0.0.1/32"
  wg_listen_port: ${wg_port}
  wg_private_key: /etc/router/private.key
  api_port: 8080
  lan_interface: eth0

network:
  host_ip: "10.0.0.2"
  manager_ip: "10.0.0.3"
  hub_ip: "10.0.0.4"
  babo_ip: "10.0.0.5"
  agent_subnet: "10.1.0.0/16"
  user_subnet: "10.2.0.0/16"

peers:
  host:
    pubkey: "${HOST_WG_PUBKEY}"
    allowed_ips: "10.0.0.2/32"
  manager:
    pubkey: "${MANAGER_PUBKEY}"
    allowed_ips: "10.0.0.3/32"
  hub:
    pubkey: "${HUB_PUBKEY}"
    allowed_ips: "10.0.0.4/32"
  babo:
    pubkey: "${BABO_PUBKEY}"
    allowed_ips: "10.0.0.5/32"
EOF

    # Public, static fragments (baked at build time; no secrets in them).
    [ -f "$public_dir/users-peers.fragment" ] && \
        cat "$public_dir/users-peers.fragment" >> "$RUNTIME_DIR/router/config.yml"
    [ -f "$public_dir/router-services.yml" ] && \
        cat "$public_dir/router-services.yml" >> "$RUNTIME_DIR/router/config.yml"

    cat > "$RUNTIME_DIR/manager/wg0.conf" <<EOF
[Interface]
PrivateKey = $(cat "$RUNTIME_DIR/manager/private.key")
Address = 10.0.0.3/32

[Peer]
PublicKey = ${ROUTER_PUBKEY}
Endpoint = ${bridge}:${wg_port}
AllowedIPs = 10.0.0.0/8
PersistentKeepalive = 25
EOF
    chmod 600 "$RUNTIME_DIR/manager/wg0.conf"

    cat > "$RUNTIME_DIR/hub/wg0.conf" <<EOF
[Interface]
PrivateKey = $(cat "$RUNTIME_DIR/hub/private.key")
Address = 10.0.0.4/32

[Peer]
PublicKey = ${ROUTER_PUBKEY}
Endpoint = ${bridge}:${wg_port}
AllowedIPs = 10.0.0.0/8
PersistentKeepalive = 25
EOF
    chmod 600 "$RUNTIME_DIR/hub/wg0.conf"

    cat > "$RUNTIME_DIR/babo/wg0.conf" <<EOF
[Interface]
PrivateKey = $(cat "$RUNTIME_DIR/babo/private.key")
Address = 10.0.0.5/32

[Peer]
PublicKey = ${ROUTER_PUBKEY}
Endpoint = ${bridge}:${wg_port}
AllowedIPs = 10.0.0.0/8
PersistentKeepalive = 25
EOF
    chmod 600 "$RUNTIME_DIR/babo/wg0.conf"

    # Public handoff for the host: run.sh re-points nc-host from this.
    printf '%s\n' "$ROUTER_PUBKEY" > "$RUNTIME_DIR/router.pubkey"
    chmod 644 "$RUNTIME_DIR/router.pubkey"

    cat > "$RUNTIME_DIR/boot.json" <<EOF
{"boot_id":"${BOOT_ID}","generated_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","router_pubkey":"${ROUTER_PUBKEY}","manager_pubkey":"${MANAGER_PUBKEY}","hub_pubkey":"${HUB_PUBKEY}"}
EOF
    chmod 644 "$RUNTIME_DIR/boot.json"

    export ROUTER_PUBKEY MANAGER_PUBKEY HUB_PUBKEY BABO_PUBKEY BOOT_ID
}
