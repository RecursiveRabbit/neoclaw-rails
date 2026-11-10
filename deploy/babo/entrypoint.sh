#!/bin/bash
set -u

# Babo in a pod: bring up its own WG interface (10.0.0.5), make the UI bind
# that address only, and start the app. No podman socket, no writable host
# paths; exactly one read-only mount (/etc/wireguard) from the boot runtime.
#
# `babo webui` has no --host flag (babo/cli/webui.py: bind address comes from
# config.gateway.host, babo/config/schema.py). So: render a runtime config with
# gateway.host set and pass it with --config.

log() { echo "[babo] $*"; }

if [ ! -f /etc/wireguard/wg0.conf ]; then
    log "FATAL: /etc/wireguard/wg0.conf not mounted (per-boot key missing)"
    exit 1
fi

wg-quick up wg0 || { log "FATAL: wg-quick failed"; exit 1; }
BIND="10.0.0.5"
log "wireguard up (${BIND})"

# Runtime config: writable, in-container, and authoritative for the bind.
CONFIG="${BABO_RUNTIME_CONFIG:-/run/babo/config.json}"
mkdir -p "$(dirname "$CONFIG")"
cat > "$CONFIG" <<EOF
{
  "gateway": {
    "host": "${BIND}",
    "port": ${BABO_PORT:-8843}
  }
}
EOF
log "runtime config: ${CONFIG} (gateway.host=${BIND})"

# The Manager endpoint is the ONLY outbound dependency. Unreachable -> the UI
# shows its unknown banner; nothing falls back to a local path.
log "manager endpoint: ${NEOCLAW_MANAGER_URL:-unset}"
log "office backend:   ${NEOCLAW_OFFICE_BACKEND:-manager}"

exec babo webui --config "$CONFIG" --port "${BABO_PORT:-8843}" --no-open
