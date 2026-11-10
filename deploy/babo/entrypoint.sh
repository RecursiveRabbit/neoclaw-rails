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

# --- Operator-session trust (checked before anything expensive) ------------
# The WebUI listener is the websocket channel (babo/channels/websocket/
# runtime.py: WebSocketConfig), so the trust list belongs there, not on
# gateway.*. Exactly one source is legitimate: the address the Router admits
# to this port. Anything else — a bare IP, a shorter prefix, 0.0.0.0/0, ::/0,
# a hostname, a reserved/unspecified address — is refused BY NAME rather than
# trimmed into something that looks safer than it is.
TRUSTED="${BABO_TRUSTED_SOURCES:-}"
trusted_ok() {
    case "$1" in
        *[!0-9./]*) return 1 ;;                 # hostname or junk
    esac
    case "$1" in
        */32) : ;;
        *)    return 1 ;;                       # bare IP, /8, /0, ...
    esac
    local ip="${1%/32}" octet
    local IFS=.
    set -- $ip
    [ $# -eq 4 ] || return 1
    for octet in "$@"; do
        case "$octet" in ''|*[!0-9]*) return 1 ;; esac
        [ "$octet" -le 255 ] || return 1
    done
    # unspecified / loopback / multicast / reserved are not operator sources
    case "$ip" in
        0.*|127.*|2[2-5][0-9].*) return 1 ;;
    esac
    return 0
}

if [ -z "$TRUSTED" ]; then
    log "WARNING: BABO_TRUSTED_SOURCES is unset — no operator source is trusted; the UI will only answer loopback, which nothing on the mesh can reach"
elif ! trusted_ok "$TRUSTED"; then
    log "FATAL: refusing to start with trusted source '${TRUSTED}' — exact IPv4 /32 required; open, shortened, reserved or malformed values are refused, not trimmed"
    exit 1
else
    log "WebUI session sources: ${TRUSTED}"
fi

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

# Two listeners, two keys (verified by dova in source, and by me at
# babo/channels/websocket/runtime.py:180 + babo/cli/gateway_runtime.py:1109):
#   channels.websocket.host:port  — the SPA, /api/*, /webui/bootstrap
#   gateway.host:port             — the gateway's own GET /health
# Both must be bound to the WG address; each keeps its own port.
PORT="${BABO_PORT:-8843}"
HEALTH_PORT="${BABO_HEALTH_PORT:-18790}"
CONFIG="${BABO_RUNTIME_CONFIG:-/run/babo/config.json}"
mkdir -p "$(dirname "$CONFIG")"
if [ -n "$TRUSTED" ]; then
    cat > "$CONFIG" <<EOF
{
  "gateway": {
    "host": "${BIND}",
    "port": ${HEALTH_PORT}
  },
  "channels": {
    "websocket": {
      "host": "${BIND}",
      "port": ${PORT},
      "trusted_sources": ["${TRUSTED}"]
    }
  }
}
EOF
else
    cat > "$CONFIG" <<EOF
{
  "gateway": {
    "host": "${BIND}",
    "port": ${HEALTH_PORT}
  },
  "channels": {
    "websocket": {
      "host": "${BIND}",
      "port": ${PORT}
    }
  }
}
EOF
fi
log "runtime config: ${CONFIG} (websocket ${BIND}:${PORT}, health ${BIND}:${HEALTH_PORT})"

# The Manager endpoint is the ONLY outbound dependency. Unreachable -> the UI
# shows its unknown banner; nothing falls back to a local path.
log "manager endpoint: ${NEOCLAW_MANAGER_URL:-unset}"
log "office backend:   ${NEOCLAW_OFFICE_BACKEND:-manager}"

# `babo gateway`, not `babo webui`: the webui launcher's first-run setup forced
# channels.websocket.host back to 127.0.0.1 and could mint token_issue_secret
# (dova, 88cc75ef). The gateway verb never runs that setup path, and the config
# above is the whole story.
#
# No --port here on purpose: `babo gateway --port` OVERRIDES gateway.port
# (babo/cli/gateway_runtime.py:440: "port = port if port is not None else
# config.gateway.port"), so passing the UI port would move the health server
# onto the UI port and leave 18790 unanswered. The rendered config carries both
# ports; the CLI adds nothing.
exec babo gateway --config "$CONFIG"
