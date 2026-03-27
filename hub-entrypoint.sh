#!/bin/bash
set -u

# NeoClaw Hub Entrypoint
#
# WG up (10.0.0.4 on the mesh), then start Rails.
# Hub doesn't need internet — all services reachable via WG.

log() { echo "[hub] $*"; }

wg-quick up wg0 || { log "FATAL: wg-quick failed"; exit 1; }
log "wireguard up (10.0.0.4)"

log "starting Hub on 0.0.0.0:${PORT:-3100}"
exec bundle exec puma -b "tcp://0.0.0.0:${PORT:-3100}"
