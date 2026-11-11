#!/bin/bash
set -eu

# Babo in a pod, in one of two roles (D-10):
#
#   BABO_ROLE=core  (default) — the product process. Brings up its own wg0,
#   binds the WG address only, and holds the podman runtime socket. Lifecycle
#   decisions are made here. NET_ADMIN is scoped to this container's namespace.
#
#   BABO_ROLE=ui — the privilege-minimal UI edge. No runtime socket, no
#   NET_ADMIN, no wg0: it binds loopback inside the pod's shared network
#   namespace and shares the internal socket volume. It must never be the
#   container that can act on the runtime; if it can see the socket, it refuses
#   to start rather than become a second holder of the privilege boundary.
#
# Why `babo gateway` and not `babo webui`: `babo webui` is a client launcher --
# it starts a *background* gateway, opens (or suppresses) a browser, attaches to
# the gateway log, and returns; with tini as PID 1 the container would exit and
# take the service with it. `babo gateway` (no --background) runs the server in
# this process's foreground, which is what a pod needs. Recorded deviation.

ROLE="${BABO_ROLE:-core}"
log() { echo "[babo:${ROLE}] $*" ; }

case "$ROLE" in
    core|ui) : ;;
    *) log "FATAL: BABO_ROLE must be core or ui, not '${ROLE}'"; exit 1 ;;
esac

# --- the privilege boundary refused at boot, not assumed (D-10c) -----------
# `babo-ui` has no socket mount by construction; this check makes a render
# that gives it one a refusal to start instead of a quiet second holder.
if [ "$ROLE" = "ui" ] && [ -e /run/podman/podman.sock ]; then
    log "FATAL: the runtime socket is visible in babo-ui; refusing to start a second holder of the runtime privilege"
    exit 1
fi
if [ "$ROLE" = "ui" ] && [ -f /etc/wireguard/wg0.conf ]; then
    log "FATAL: wg0.conf is mounted in babo-ui; the mesh identity belongs to babo-core only"
    exit 1
fi
if [ "$ROLE" = "core" ] && ! command -v podman >/dev/null 2>&1; then
    log "FATAL: podman-remote is not installed in babo-core; every lifecycle verb would be refused"
    exit 1
fi

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

if [ "$ROLE" = "core" ]; then
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
else
    # The UI edge has no mesh identity of its own. It binds loopback in the
    # pod's shared network namespace; the host-WG listener belongs to core until
    # the core<->ui internal socket has a client and server on both sides.
    if [ -n "$TRUSTED" ]; then
        log "FATAL: BABO_TRUSTED_SOURCES belongs to babo-core; babo-ui must not carry a mesh trust list"
        exit 1
    fi
    BIND="127.0.0.1"
    log "UI edge on loopback only (no runtime socket, no NET_ADMIN)"
fi

# Two listeners, two keys (verified by dova in source, and by me at
# babo/channels/websocket/runtime.py:180 + babo/cli/gateway_runtime.py:1109):
#   channels.websocket.host:port  — the SPA, /api/*, /webui/bootstrap
#   gateway.host:port             — the gateway's own GET /health
# Core binds both to the WG address; the UI edge binds both to loopback.
PORT="${BABO_PORT:-8843}"
HEALTH_PORT="${BABO_HEALTH_PORT:-18790}"
CONFIG="${BABO_RUNTIME_CONFIG:-/run/babo/config.json}"
mkdir -p "$(dirname "$CONFIG")"

# The internal operator socket (dova, UI-in-pod revoke): the gateway creates it
# on a volume both containers share; the CLI uses it for the verbs that cannot
# come from loopback or the mesh trust list. Core serves it; the UI edge mounts
# the directory but does not create a second listener on the same path.
UNIX_KEY=""
if [ "$ROLE" = "core" ]; then
    UNIX_SOCKET="${BABO_INTERNAL_SOCKET:-/run/babo/internal/office.sock}"
    mkdir -p "$(dirname "$UNIX_SOCKET")"
    chmod 700 "$(dirname "$UNIX_SOCKET")"
    UNIX_KEY=",\"unix_socket_path\": \"${UNIX_SOCKET}\""
    log "internal operator socket: ${UNIX_SOCKET}"
fi

if [ "$ROLE" = "core" ] && [ -n "$TRUSTED" ]; then
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
      "trusted_sources": ["${TRUSTED}"]${UNIX_KEY}
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
      "port": ${PORT}${UNIX_KEY}
    }
  }
}
EOF
fi
log "runtime config: ${CONFIG} (websocket ${BIND}:${PORT}, health ${BIND}:${HEALTH_PORT})"

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
