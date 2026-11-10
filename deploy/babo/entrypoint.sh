#!/bin/bash
set -eu

# Babo in a pod: bring up its own WG interface, make the UI bind that address
# only, and run the gateway in the FOREGROUND (the container's main process).
#
# Why `babo gateway` and not `babo webui`: `babo webui` is a client launcher --
# it starts a *background* gateway, opens (or suppresses) a browser, attaches to
# the gateway log, and returns; with tini as PID 1 the container would exit and
# take the service with it. `babo gateway` (no --background) runs the server in
# this process's foreground, which is what a pod needs. Recorded deviation.
#
# Why a rendered config: the bind address is not a CLI flag (there is no --host);
# it comes from config.gateway.host (babo/config/schema.py, default 127.0.0.1).
# The bind address is the address the Router admits, so it is read from the
# interface itself rather than hardcoded or defaulted.

log() { echo "[babo] $*"; }

if [ ! -f /etc/wireguard/wg0.conf ]; then
    log "FATAL: /etc/wireguard/wg0.conf not mounted (per-boot key missing)"
    exit 1
fi

wg-quick up wg0 || { log "FATAL: wg-quick failed"; exit 1; }

# The effective bind address is a fact read from wg0, not an assumption. The
# Router rule admits 10.0.0.5 only, so a different address is a loud failure
# rather than a page nobody can reach.
BIND="$(ip -4 -o addr show dev wg0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
if [ -z "${BIND}" ]; then
    log "FATAL: wg0 came up with no IPv4 address; nothing to bind"
    exit 1
fi
if [ "${BIND}" != "10.0.0.5" ]; then
    log "FATAL: wg0 address is ${BIND}, but the Router admits 10.0.0.5 only; refusing to bind an address that cannot be reached"
    exit 1
fi
log "wireguard up (${BIND})"

PORT="${BABO_PORT:-8843}"
CONFIG="${BABO_RUNTIME_CONFIG:-/run/babo/config.json}"
mkdir -p "$(dirname "$CONFIG")"
cat > "$CONFIG" <<EOF
{
  "gateway": {
    "host": "${BIND}",
    "port": ${PORT}
  }
}
EOF
log "runtime config: ${CONFIG} (gateway.host=${BIND}, gateway.port=${PORT})"

# The Manager endpoint is the ONLY outbound dependency. Unreachable -> the UI
# shows its unknown banner; nothing falls back to a local path.
log "manager endpoint: ${NEOCLAW_MANAGER_URL:-unset}"
log "office backend:   ${NEOCLAW_OFFICE_BACKEND:-manager}"

exec babo gateway --config "$CONFIG" --port "$PORT"
