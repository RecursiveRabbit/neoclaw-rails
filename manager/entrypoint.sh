#!/bin/bash
set -u

# NeoClaw Manager Entrypoint
#
# Phase 1: WireGuard up from mounted config
# Phase 2: Database init/migrate
# Phase 3: Start Rails
#
# Mounts:
#   /etc/wireguard/wg0.conf        — WG config (one peer: Router)
#   /run/podman/podman.sock        — podman socket
#   /run/secrets/claude-credentials — Claude OAuth creds
#   /spawn                         — spawn.json staging
#   /data                          — persistent SQLite database

log() { echo "[manager] $*"; }

# --- WireGuard ---
if [ ! -f /etc/wireguard/wg0.conf ]; then
    log "FATAL: no WG config at /etc/wireguard/wg0.conf"
    exit 1
fi

wg-quick up wg0 || { log "FATAL: wg-quick failed"; exit 1; }
log "wireguard up"

# Route all traffic through the Router — podman bridge has no internet
ip route del default 2>/dev/null || true
ip route add default via 10.0.0.1 dev wg0
log "default route via Router (10.0.0.1)"

# --- Secrets ---
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')}"

# --- Database ---
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

# --- Start Rails ---
log "starting manager on 0.0.0.0:9200"
exec bin/rails server -b 0.0.0.0 -p 9200 -e production
