#!/bin/bash
set -eu

# Babo in a pod, in one of two separate-pod roles (D-12):
#
#   BABO_ROLE=ui       the operator's only door: its own wg0 at 10.0.0.11,
#                      user-facing listener on 8843, host /32 trusted.
#   BABO_ROLE=manager  the deterministic core: its own wg0 at 10.0.0.12, the
#                      container-runtime socket, and the UI /32 as its only
#                      trusted source. Headless: no sshd, no shell path, no
#                      user listener; the Router admits only UI -> Manager.
#
# The pods share no mount, no volume and no network namespace; the only thing
# between them is the wire (D12-8).
# Why `babo gateway` and not `babo webui`: `babo webui` is a client launcher --
# it starts a *background* gateway, opens (or suppresses) a browser, attaches to
# the gateway log, and returns; with tini as PID 1 the container would exit and
# take the service with it. `babo gateway` (no --background) runs the server in
# this process's foreground, which is what a pod needs. Recorded deviation.

ROLE="${BABO_ROLE:-manager}"
log() { echo "[babo:${ROLE}] $*" ; }

case "$ROLE" in
    ui|manager) : ;;
    *) log "FATAL: BABO_ROLE must be ui or manager, not '${ROLE}'"; exit 1 ;;
esac

case "$ROLE" in
    ui)      EXPECT="${BABO_WG_ADDRESS:-10.0.0.11}" ; DEFAULT_TRUSTED="${BABO_TRUSTED_SOURCES:-10.0.0.2/32}"
             DEFAULT_OPERATOR="" ;;
    manager) EXPECT="${BABO_WG_ADDRESS:-10.0.0.12}" ; DEFAULT_TRUSTED="${BABO_TRUSTED_SOURCES:-10.0.0.11/32}"
             DEFAULT_OPERATOR="${BABO_OPERATOR_SOURCES-10.0.0.2/32}" ;;
esac

if [ "$ROLE" = "manager" ] && ! command -v podman >/dev/null 2>&1; then
    log "FATAL: podman-remote is not installed in the manager; every lifecycle verb would be refused"
    exit 1
fi
if [ "$ROLE" = "manager" ] && command -v sshd >/dev/null 2>&1; then
    log "FATAL: an sshd binary is present in babo-manager; the Manager is headless by ruling"
    exit 1
fi

# --- Operator-session trust (checked before anything expensive) ------------
# The WebUI listener is the websocket channel (babo/channels/websocket/
# runtime.py: WebSocketConfig), so the trust list belongs there, not on
# gateway.*. Exactly one source is legitimate: the address the Router admits
# to this port. Anything else — a bare IP, a shorter prefix, 0.0.0.0/0, ::/0,
# a hostname, a reserved/unspecified address — is refused BY NAME rather than
# trimmed into something that looks safer than it is.
TRUSTED="${DEFAULT_TRUSTED}"
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

# --- The operator door's source ---------------------------------------------
# Two doors, two names. `BABO_TRUSTED_SOURCES` above is THIS pod's listener
# list: on the UI role that is the host, on the Manager role it is the UI pod.
# `BABO_OPERATOR_SOURCES` is the host operator's address admitted to
# `restart-ui` at the Manager. It is declared separately because they are two
# different admissions that happen to share one address in one of the two roles;
# collapsing them into one variable is how a UI-listener row gets read as an
# operator-door row — the near-proof soro's checklist named.
OPERATOR="${DEFAULT_OPERATOR}"
if [ "$ROLE" = "manager" ]; then
    if [ -z "$OPERATOR" ]; then
        log "FATAL: BABO_OPERATOR_SOURCES is empty — the Manager would start with its operator door closed, and every host call would be refused as 'not the operator' rather than as 'no door here'"
        exit 1
    elif ! trusted_ok "$OPERATOR"; then
        log "FATAL: refusing to start with operator source '${OPERATOR}' — exact IPv4 /32 required; open, shortened, reserved or malformed values are refused, not trimmed"
        exit 1
    else
        log "operator door sources: ${OPERATOR}"
    fi
    # Resolved and exported so the process inherits the render's value rather
    # than the caller's spelling or nothing. The Manager reads it through
    # `babo.office.service.doors_from_render`, not from the config file: the
    # config's `trusted_sources` is a listener's list, and a second list under
    # the same word would be a second meaning for one word.
    export BABO_OPERATOR_SOURCES="$OPERATOR"
fi

    if [ ! -f /etc/wireguard/wg0.conf ]; then
        log "FATAL: /etc/wireguard/wg0.conf not mounted (per-boot key missing)"
        exit 1
    fi

    wg-quick up wg0 || { log "FATAL: wg-quick failed"; exit 1; }

    # The effective bind address is a fact read from wg0, not an assumption. The
    # Router rule admits 10.0.0.11 only, so a different address is a loud failure
    # rather than a page nobody can reach.
BIND="$(ip -4 -o addr show dev wg0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
if [ -z "${BIND}" ]; then
    log "FATAL: wg0 came up with no IPv4 address; nothing to bind"
    exit 1
fi
if [ "${BIND}" != "${EXPECT}" ]; then
    log "FATAL: wg0 address is ${BIND}, but this pod's identity is ${EXPECT}; refusing to bind an address that cannot be reached"
    exit 1
fi
log "wireguard up (${BIND})"

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
# on a volume; a CLI in the same container (or a future sidecar sharing the
# volume) uses it for verbs that cannot come from loopback or the trust list.
UNIX_KEY=""
if [ "$ROLE" = "manager" ]; then
    UNIX_SOCKET="${BABO_INTERNAL_SOCKET:-/run/babo/internal/office.sock}"
    mkdir -p "$(dirname "$UNIX_SOCKET")"
    chmod 700 "$(dirname "$UNIX_SOCKET")"
    UNIX_KEY=",\"unix_socket_path\": \"${UNIX_SOCKET}\""
    log "internal operator socket: ${UNIX_SOCKET}"
fi

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
