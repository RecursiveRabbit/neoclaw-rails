#!/bin/bash
set -u

# Babo in a pod: bring up its own WG interface (10.0.0.5), bind the UI to
# that address only, and start the app. No podman socket, no host binds.

log() { echo "[babo] $*"; }

if [ -f /etc/wireguard/wg0.conf ]; then
    wg-quick up wg0 || { log "FATAL: wg-quick failed"; exit 1; }
    log "wireguard up (10.0.0.5)"
    BIND="10.0.0.5"
else
    log "FATAL: /etc/wireguard/wg0.conf not mounted (per-boot key missing)"
    exit 1
fi

# The Manager endpoint is the ONLY outbound dependency. If it is unreachable
# the UI shows its `unknown` banner; nothing falls back to a local path.
log "manager endpoint: ${NEOCLAW_MANAGER_URL:-unset}"
log "office backend:   ${NEOCLAW_OFFICE_BACKEND:-manager}"

exec babo webui --host "$BIND" --port "${BABO_PORT:-8843}"
