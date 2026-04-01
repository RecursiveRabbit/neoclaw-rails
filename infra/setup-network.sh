#!/bin/bash
# NeoClaw network setup — Router-centric star topology.
#
# Creates:
#   /etc/wireguard/nc-host.conf    (WireGuard config)
#   /etc/neoclaw/socat/*.conf      (socat env files)
#   systemd units for socat + wg-quick
#
# The host has ONE WireGuard interface (nc-host) peered with the Router.
# All services are on the host at 10.0.0.2. Localhost-bound services
# are exposed on the WG IP via socat forwarders.
#
# Run with sudo. Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WG_INTERFACE="nc-host"

log() { echo "[setup-network] $*"; }

# =====================================================================
# WireGuard
# =====================================================================

write_wg_config() {
    local privkey

    # Read private key from running interface or from keyfile
    if ip link show "$WG_INTERFACE" &>/dev/null; then
        privkey="$(wg show "$WG_INTERFACE" private-key)"
        log "read private key from running $WG_INTERFACE"
    elif [ -f "$SCRIPT_DIR/wireguard/keys/nc-host.key" ]; then
        privkey="$(cat "$SCRIPT_DIR/wireguard/keys/nc-host.key")"
        log "read private key from keyfile"
    else
        log "FATAL: no running interface and no keyfile"
        exit 1
    fi

    # Router public key — from the wg-router pod
    local router_pubkey="${ROUTER_PUBKEY:-s6MqVlEFH0X8dkh+QWSMfRHYVIZulpID6/OhEdB+6TA=}"
    local router_endpoint="${ROUTER_ENDPOINT:-10.88.0.20:51820}"

    cat > "/etc/wireguard/${WG_INTERFACE}.conf" <<EOF
[Interface]
PrivateKey = ${privkey}
Address = 10.0.0.2/32
ListenPort = 51820

# Block podman bridge traffic to WG address space.
# Agents reach WG addresses through WireGuard only, not the bridge.
PostUp = iptables -C INPUT -s 10.88.0.0/16 -d 10.0.0.0/8 -j DROP 2>/dev/null || iptables -I INPUT -s 10.88.0.0/16 -d 10.0.0.0/8 -j DROP
PostDown = iptables -D INPUT -s 10.88.0.0/16 -d 10.0.0.0/8 -j DROP 2>/dev/null || true

[Peer]
# wg-router pod — the center of the star
PublicKey = ${router_pubkey}
Endpoint = ${router_endpoint}
AllowedIPs = 10.0.0.0/8
PersistentKeepalive = 25
EOF

    chmod 600 "/etc/wireguard/${WG_INTERFACE}.conf"
    log "wrote /etc/wireguard/${WG_INTERFACE}.conf"
}

setup_wireguard() {
    write_wg_config

    # If the interface is already up (manual start), bring it down first
    # so wg-quick can manage it cleanly.
    if ip link show "$WG_INTERFACE" &>/dev/null; then
        # Check if wg-quick is already managing it
        if systemctl is-active "wg-quick@${WG_INTERFACE}" &>/dev/null; then
            log "wg-quick@${WG_INTERFACE} already active"
        else
            log "taking down manually-started $WG_INTERFACE"
            ip link delete "$WG_INTERFACE" 2>/dev/null || true
            sleep 0.5
        fi
    fi

    systemctl enable "wg-quick@${WG_INTERFACE}"
    if ! systemctl is-active "wg-quick@${WG_INTERFACE}" &>/dev/null; then
        systemctl start "wg-quick@${WG_INTERFACE}"
    fi
    log "wg-quick@${WG_INTERFACE} enabled and running"
}

# =====================================================================
# Socat forwarders
# =====================================================================

SOCAT_SERVICES=(vikunja valley comfyui mqtt)

setup_socat() {
    # Install template unit
    cp "$SCRIPT_DIR/neoclaw-socat@.service" /etc/systemd/system/
    log "installed neoclaw-socat@.service template"

    # Install env files
    mkdir -p /etc/neoclaw/socat
    for svc in "${SOCAT_SERVICES[@]}"; do
        cp "$SCRIPT_DIR/socat/${svc}.conf" "/etc/neoclaw/socat/${svc}.conf"
    done
    log "installed socat env files"

    # Kill any manually-started socat processes on our ports
    for svc in "${SOCAT_SERVICES[@]}"; do
        local port
        port=$(grep '^PORT=' "$SCRIPT_DIR/socat/${svc}.conf" | cut -d= -f2)
        pkill -f "socat.*LISTEN:${port},bind=10.0.0.2" 2>/dev/null || true
    done
    log "killed manual socat processes"

    systemctl daemon-reload

    for svc in "${SOCAT_SERVICES[@]}"; do
        systemctl enable "neoclaw-socat@${svc}"
        systemctl restart "neoclaw-socat@${svc}"
        log "neoclaw-socat@${svc} enabled and started"
    done
}

# =====================================================================
# Verify
# =====================================================================

verify() {
    echo ""
    log "=== Verification ==="

    # WireGuard
    if wg show "$WG_INTERFACE" &>/dev/null; then
        local handshake
        handshake=$(wg show "$WG_INTERFACE" latest-handshakes | awk '{print $2}')
        if [ "$handshake" != "0" ]; then
            log "WireGuard: UP, handshake active"
        else
            log "WireGuard: UP, no handshake yet (Router may not be running)"
        fi
    else
        log "WireGuard: DOWN"
    fi

    # Socat
    for svc in "${SOCAT_SERVICES[@]}"; do
        if systemctl is-active "neoclaw-socat@${svc}" &>/dev/null; then
            log "socat/$svc: running"
        else
            log "socat/$svc: NOT running"
        fi
    done

    # iptables
    if iptables -C INPUT -s 10.88.0.0/16 -d 10.0.0.0/8 -j DROP &>/dev/null; then
        log "iptables bridge block: active"
    else
        log "iptables bridge block: MISSING"
    fi
}

# =====================================================================
# Main
# =====================================================================

log "NeoClaw network setup — star topology"
echo ""

setup_wireguard
echo ""

setup_socat
echo ""

verify
echo ""
log "Done. Network persists across reboots."
