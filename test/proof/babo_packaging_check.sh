#!/bin/bash
# babo_packaging_check.sh — prove the Babo pod's boundaries in the check's own
# words, not by quoting the design.
#
# Runs on the deployment host (needs podman). Every line prints PASS, FAIL or
# UNMET. UNMET is a result — a claim this script cannot prove from the inputs
# it was given — and it is never converted into a pass by softening the
# assertion. An image that cannot be run at all is a FAIL, never an empty pass:
# every in-image probe goes through `probe`, which returns a sentinel on a
# non-zero `podman run` and fails the row instead of comparing "" to "".
#
# The script never prints a key or a token value, never touches production
# WireGuard, and never starts anything on a shared network.
#
# Usage:
#   babo_packaging_check.sh [IMAGE] [options]
#
#   IMAGE                 default: localhost/neoclaw-babo:latest
#   --container NAME      also inspect a RUNNING container of this image
#                         (mount set, published ports, network mode, caps,
#                         sysctls, environment, runtime config)
#   --wg-probe URL        URL reachable only from the host's WG address,
#                         e.g. http://10.0.0.2:8843/health
#   --loopback-probe URL  URL that must be REFUSED from the host's loopback,
#                         e.g. http://127.0.0.1:8843/health
#   --spawn-dir PATH      the per-boot runtime dir the mount must come from
#                         default: ${HOST_SPAWN_DIR:-/spawn}/runtime/babo
#
# Two rules of evidence this script follows:
#   - the Manager's source is an INPUT; the running container is the FACT.
#     Mounts, ports, network mode, caps and sysctls are read from `podman
#     inspect` on the container, never inferred from manager/entrypoint.sh.
#   - env values (BABO_PORT, NEOCLAW_MANAGER_URL, BABO_IMAGE) come from the
#     Manager's environment, so they are "as launched by this boot", not
#     "fixed at build". This script does not assert them against the image.
#
# Exit: 0 all PASS, 1 any FAIL, 2 no FAIL but some UNMET.

set -u

IMAGE="localhost/neoclaw-babo:latest"
CONTAINER=""
WG_PROBE=""
LOOPBACK_PROBE=""
SPAWN_DIR="${HOST_SPAWN_DIR:-/spawn}/runtime/babo"

while [ $# -gt 0 ]; do
  case "$1" in
    --container) CONTAINER="${2:-}"; shift 2 ;;
    --wg-probe) WG_PROBE="${2:-}"; shift 2 ;;
    --loopback-probe) LOOPBACK_PROBE="${2:-}"; shift 2 ;;
    --spawn-dir) SPAWN_DIR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 64 ;;
    *) IMAGE="$1"; shift ;;
  esac
done

PASS=0; FAIL=0; UNMET=0
ok()    { PASS=$((PASS+1));  echo "PASS   $*"; }
bad()   { FAIL=$((FAIL+1));  echo "FAIL   $*"; }
unmet() { UNMET=$((UNMET+1)); echo "UNMET  $*"; }

PROBE_FAILED="__probe_failed__"

run_in_image() { # entrypoint, then that program's own arguments
  local entry="$1"; shift
  podman run --rm --entrypoint "$entry" "$IMAGE" "$@"
}

# Never let "the image could not be run" look like "the image is clean".
probe() {
  local out
  if ! out=$(run_in_image "$@" 2>/dev/null); then
    printf '%s' "$PROBE_FAILED"
    return 0
  fi
  printf '%s' "$out"
}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ENTRY_SRC="$REPO_ROOT/deploy/babo/entrypoint.sh"

echo "== image: $IMAGE"
podman image exists "$IMAGE" || { echo "FAIL   image not present: $IMAGE"; exit 1; }

# --- 1. No WireGuard key or config in the image ------------------------
# Deliberately narrow, because "PrivateKey" appears in ordinary crypto library
# sources and docs and a match there is not key material: look for WireGuard
# config files by name, and for an actual assignment line in /etc only.
WG=$(probe /bin/sh -c '
  find / -xdev \( -name "wg0.conf" -o -name "*.key" -path "*/wireguard/*" \) 2>/dev/null
  grep -rls -- "^[[:space:]]*PrivateKey[[:space:]]*=" /etc 2>/dev/null
  true')
if [ "$WG" = "$PROBE_FAILED" ]; then
  bad "image could not be run, so key material could not be checked (podman run failed)"
elif [ -z "$WG" ]; then
  ok "image contains no wg0.conf and no WireGuard private key"
else
  bad "image contains key material (paths only): $(echo "$WG" | tr '\n' ' ')"
fi

# --- 2. No container-runtime socket and no runtime client --------------
RT=$(probe /bin/sh -c '
  ls /run/podman/podman.sock /var/run/docker.sock 2>/dev/null
  command -v podman docker ctr nerdctl 2>/dev/null
  true')
if [ "$RT" = "$PROBE_FAILED" ]; then
  bad "image could not be run, so the runtime-socket check did not run (podman run failed)"
elif [ -z "$RT" ]; then
  ok "image has no podman/docker socket and no container-runtime client"
else
  bad "image carries a runtime socket or client: $(echo "$RT" | tr '\n' ' ')"
fi

# --- 3. The entrypoint refuses to start without a mounted config -------
OUT3=$(podman run --rm "$IMAGE" 2>&1); RC3=$?
if [ "$RC3" -eq 0 ]; then
  bad "container started with no mounted wg0.conf"
elif echo "$OUT3" | grep -q "wg0.conf not mounted"; then
  ok "container refuses to start without a mounted wg0.conf (rc=$RC3, reason stated)"
else
  bad "container failed before its own config check (rc=$RC3): $(echo "$OUT3" | tail -1)"
fi

# --- 3b. No alternate token-issuance door in the pod -------------------
# Dova's gate issues tokens only via /webui/bootstrap for trusted peers. The
# static issue route (token_issue_path/token_issue_secret) is the other way in;
# in a pod it must be unset, or the WG rule stops being the only door.
ISSUE=$(probe python3 -c "
from babo.channels.websocket.runtime import WebSocketConfig as W
c = W()
print(repr(c.token_issue_path), repr(c.token_issue_secret))")
if [ "$ISSUE" = "$PROBE_FAILED" ]; then
  bad "image could not be run, so the token-issuance defaults could not be read"
else
  case "$ISSUE" in
    "None None"|"'None' 'None'"|"'' ''") ok "no static token-issuance route configured in the image defaults" ;;
    "")  bad "could not read token_issue_path/token_issue_secret from the image" ;;
    *)   bad "image defaults configure a static token issue route: $ISSUE" ;;
  esac
fi
ENVISSUE=$(probe /bin/sh -c 'env' | grep -iE '(TOKEN_ISSUE|TOKEN_PATH)' || true)
if [ -z "$ENVISSUE" ]; then
  ok "no TOKEN_ISSUE/TOKEN_PATH in the image environment"
else
  bad "image environment carries a token issuance variable: $(echo "$ENVISSUE" | tr '\n' ' ')"
fi

# --- 3c. Trusted-source handling is fail-closed in the pod -------------
# Cheap checks first: an invalid value must be refused BEFORE anything else,
# with the value named, and without needing a mounted wg0.conf.
for BADVAL in "0.0.0.0/0" "10.0.0.0/8" "10.0.0.2" "::/0" "example.internal"; do
  set +e
  O=$(podman run --rm -e "BABO_TRUSTED_SOURCES=$BADVAL" "$IMAGE" 2>&1); R=$?
  set -e 2>/dev/null || true
  if [ "$R" -ne 0 ] && echo "$O" | grep -qF "$BADVAL"; then
    ok "refuses trusted source '$BADVAL' by name (rc=$R)"
  elif [ -z "$O" ]; then
    bad "image could not be run, so the trusted-source refusal for '$BADVAL' could not be checked (rc=$R)"
  else
    bad "did not refuse trusted source '$BADVAL' by name (rc=$R): $(echo "$O" | tail -1)"
  fi
done

# --- 4. The installed package ships a built UI -------------------------
UI=$(probe python3 -c "
import os, babo.web
p = os.path.join(os.path.dirname(babo.web.__file__), 'dist', 'index.html')
print(p if os.path.isfile(p) and os.path.getsize(p) > 0 else 'MISSING:' + p)")
if [ "$UI" = "$PROBE_FAILED" ]; then
  bad "image could not be run, so the web bundle could not be checked (podman run failed)"
else
  case "$UI" in
    MISSING:*) bad "installed package has no web bundle: ${UI#MISSING:}" ;;
    *.html)    ok "installed package ships the built UI ($UI)" ;;
    *)         bad "could not determine the web bundle path: ${UI:-<empty>}" ;;
  esac
fi

# --- 5. The Manager default is not loopback ---------------------------
MURL=$(probe python3 -c "from babo.office.backend import DEFAULT_MANAGER_URL; print(DEFAULT_MANAGER_URL)")
if [ "$MURL" = "$PROBE_FAILED" ]; then
  bad "image could not be run, so the Manager default could not be read (podman run failed)"
else
  case "$MURL" in
    "")                 bad "could not read DEFAULT_MANAGER_URL from the image" ;;
    *127.0.0.1*|*localhost*|*"://[::1]"*) bad "Manager default is loopback: $MURL" ;;
    http*)              ok "Manager default is not loopback ($MURL)" ;;
    *)                  bad "Manager default is not a URL: $MURL" ;;
  esac
fi

# --- 6. The bind is rendered from the interface, not defaulted ---------
# Assert the CODE, not the prose: comments in the entrypoint explain why there
# is no --host flag, and a grep over the whole file would fail the image for
# describing itself correctly.
ENTRY_CODE=$(probe /bin/sh -c 'grep -v "^[[:space:]]*#" /usr/local/bin/babo-entrypoint 2>/dev/null')
if [ "$ENTRY_CODE" = "$PROBE_FAILED" ]; then
  bad "image could not be run, so the entrypoint could not be read (podman run failed)"
elif [ -z "$ENTRY_CODE" ]; then
  bad "image has no /usr/local/bin/babo-entrypoint (or it is all comments)"
else
  if echo "$ENTRY_CODE" | grep -q '"websocket"' && echo "$ENTRY_CODE" | grep -q '"trusted_sources"'; then
    ok "entrypoint renders channels.websocket.trusted_sources"
  else
    bad "entrypoint does not render channels.websocket.trusted_sources"
  fi
  if echo "$ENTRY_CODE" | grep -q "gateway.host" && echo "$ENTRY_CODE" | grep -q "ip -4 -o addr show dev wg0"; then
    ok "entrypoint renders gateway.host from the wg0 address"
  else
    bad "entrypoint does not render the bind from the wg0 address"
  fi
  EXEC_LINE=$(echo "$ENTRY_CODE" | grep -E '^[[:space:]]*(exec[[:space:]]+)?babo[[:space:]]' | tail -1)
  if [ -z "$EXEC_LINE" ]; then
    bad "entrypoint has no exec line invoking babo"
  else
    case "$EXEC_LINE" in
      *--host*) bad "exec line passes --host (the gateway CLI has no such flag): $EXEC_LINE" ;;
      *)        ok "exec line passes no --host: $EXEC_LINE" ;;
    esac
    case "$EXEC_LINE" in
      *"babo gateway"*) ok "exec line runs 'babo gateway' in the foreground" ;;
      *)                bad "exec line is not 'babo gateway': $EXEC_LINE" ;;
    esac
  fi
fi

# --- 6b. The image's entrypoint matches its readable source -------------
if [ -f "$ENTRY_SRC" ]; then
  IMG_EP_SHA=$(probe /bin/sh -c 'sha256sum /usr/local/bin/babo-entrypoint 2>/dev/null | cut -d" " -f1')
  SRC_EP_SHA=$(sha256sum "$ENTRY_SRC" | cut -d" " -f1)
  if [ "$IMG_EP_SHA" = "$PROBE_FAILED" ]; then
    bad "image could not be run, so entrypoint drift could not be checked (podman run failed)"
  elif [ -n "$IMG_EP_SHA" ] && [ "$IMG_EP_SHA" = "$SRC_EP_SHA" ]; then
    ok "image entrypoint matches deploy/babo/entrypoint.sh (sha256 ${IMG_EP_SHA:0:12}…)"
  else
    bad "image entrypoint differs from deploy/babo/entrypoint.sh (image=${IMG_EP_SHA:-?} file=${SRC_EP_SHA:0:12}…); regenerate the base64 blob"
  fi
else
  unmet "entrypoint drift check: $ENTRY_SRC not found next to this script"
fi

# --- 6c. No token issuer in the image or the pod ------------------------
# Soro's token contract: WireGuard identity is the authentication by ruling, so
# the pod must not carry a token-issuing path or secret. A token would be a
# second, weaker door. Values are never printed — only the variable/key name.
IMG_ENV=$(podman image inspect -f '{{json .Config.Env}}' "$IMAGE" 2>/dev/null)
if [ -z "$IMG_ENV" ]; then
  bad "image env could not be read (podman image inspect failed)"
else
  TOKEN_ENV=$(echo "$IMG_ENV" | tr ',' '\n' | tr -d '[]"' | grep -E '^[A-Za-z_]*TOKEN[A-Za-z_]*=' | cut -d= -f1 | tr '\n' ' ')
  if [ -z "$TOKEN_ENV" ]; then
    ok "image bakes no token environment variable"
  else
    bad "image bakes token environment variable(s): $TOKEN_ENV"
  fi
fi

# --- 7-9. Run-time facts, from a live container ------------------------
if [ -z "$CONTAINER" ]; then
  unmet "mount set: exactly one read-only bind, source under $SPAWN_DIR, target /etc/wireguard (pass --container NAME)"
  unmet "no published ports, no --network host (pass --container NAME)"
  unmet "capabilities: NET_ADMIN only, scoped to this container (pass --container NAME)"
  unmet "no token issuer in the pod: token_issue_path/token_issue_secret unset in the runtime config and environment (pass --container NAME)"
else
  MOUNTS=$(podman inspect -f '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}|{{.RW}}
{{end}}' "$CONTAINER" 2>/dev/null)
  NLINES=$(printf '%s' "$MOUNTS" | grep -c '|' || true)
  case "$NLINES" in
    1)
      MTYPE=$(printf '%s\n' "$MOUNTS" | cut -d'|' -f1)
      MSRC=$(printf '%s\n'  "$MOUNTS" | cut -d'|' -f2)
      MDST=$(printf '%s\n'  "$MOUNTS" | cut -d'|' -f3)
      MRW=$(printf '%s\n'   "$MOUNTS" | cut -d'|' -f4)
      case "$MTYPE|$MDST|$MRW" in
        "bind|/etc/wireguard|false")
          case "$MSRC" in
            "$SPAWN_DIR"|"$SPAWN_DIR"/*) ok "exactly one bind mount: $MSRC -> /etc/wireguard (read-only)" ;;
            *) bad "the single mount's source is not under $SPAWN_DIR: $MSRC" ;;
          esac ;;
        *) bad "the single mount is not a read-only bind to /etc/wireguard: $MTYPE $MSRC -> $MDST rw=$MRW" ;;
      esac ;;
    0) bad "no bind mounts: the per-boot wg0.conf would be missing" ;;
    *) bad "$NLINES mounts present; exactly one is allowed" ;;
  esac

  PORTS=$(podman inspect -f '{{json .HostConfig.PortBindings}}' "$CONTAINER" 2>/dev/null)
  NETMODE=$(podman inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER" 2>/dev/null)
  if { [ "$PORTS" = "{}" ] || [ "$PORTS" = "null" ] || [ -z "$PORTS" ]; } && [ "$NETMODE" != "host" ]; then
    ok "no published ports and no host network mode (network=$NETMODE)"
  else
    bad "published ports or host networking present (ports=$PORTS network=$NETMODE)"
  fi

  SYSCTLS=$(podman inspect -f '{{json .HostConfig.Sysctls}}' "$CONTAINER" 2>/dev/null)
  case "$SYSCTLS" in
    *ip_forward*) bad "net.ipv4.ip_forward is set for Babo; it does not route traffic ($SYSCTLS)" ;;
    *)            ok "no ip_forward sysctl set (Babo does not route traffic)" ;;
  esac

  CAPADD=$(podman inspect -f '{{json .HostConfig.CapAdd}}' "$CONTAINER" 2>/dev/null)
  CAPDROP=$(podman inspect -f '{{json .HostConfig.CapDrop}}' "$CONTAINER" 2>/dev/null)
  # podman reports the long form, CAP_NET_ADMIN; accept the short form only as
  # a spelling, never as a different privilege.
  case "$CAPADD" in
    '["CAP_NET_ADMIN"]') CAPWORD=CAP_NET_ADMIN ;;
    '["NET_ADMIN"]')     CAPWORD=NET_ADMIN ;;
    *)                   CAPWORD="" ;;
  esac
  if [ -n "$CAPWORD" ] && { [ "$CAPDROP" = "null" ] || [ "$CAPDROP" = "[]" ]; }; then
    ok "capabilities are exactly $CAPWORD (container namespace only)"
  else
    bad "capability set is not exactly NET_ADMIN/CAP_NET_ADMIN (CapAdd=$CAPADD CapDrop=$CAPDROP)"
  fi

  CENV=$(podman inspect -f '{{json .Config.Env}}' "$CONTAINER" 2>/dev/null)
  CTOKENS=$(echo "$CENV" | tr ',' '\n' | tr -d '[]"' | grep -E '^[A-Za-z_]*TOKEN[A-Za-z_]*=' | cut -d= -f1 | tr '\n' ' ')
  if [ -z "$CTOKENS" ]; then
    ok "container environment carries no token variable"
  else
    bad "container environment carries token variable(s): $CTOKENS"
  fi

  # The runtime config the entrypoint renders. Read-only; values are not printed.
  RTCFG=$(podman exec "$CONTAINER" cat /run/babo/config.json 2>/dev/null)
  if [ -z "$RTCFG" ]; then
    unmet "no token issuer in the pod's runtime config: /run/babo/config.json could not be read (container without shell, or different path)"
  else
    CFG_KEYS=$(printf '%s' "$RTCFG" | grep -oE '"(token_issue_path|token_issue_secret)"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f2 | sort -u | tr '\n' ' ')
    if [ -z "$CFG_KEYS" ]; then
      ok "runtime config declares no token_issue_path/token_issue_secret"
    elif printf '%s' "$RTCFG" | grep -qE '"(token_issue_path|token_issue_secret)"[[:space:]]*:[[:space:]]*"[^"]+"'; then
      bad "runtime config enables a token issuer (keys: $CFG_KEYS) — WG identity is the authentication by ruling"
    else
      ok "runtime config declares token keys but leaves them empty (keys: $CFG_KEYS)"
    fi
  fi
fi

# --- 10-12. Effective listener and denial ------------------------------
if [ -z "$WG_PROBE" ]; then
  unmet "host-WG probe returns 200 (pass --wg-probe URL with a live boot)"
else
  CODE=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$WG_PROBE" || echo "000")
  if [ "$CODE" = "200" ]; then ok "host-WG probe 200 ($WG_PROBE)"
  else bad "host-WG probe returned $CODE ($WG_PROBE)"; fi
fi

if [ -z "$LOOPBACK_PROBE" ]; then
  unmet "loopback probe refused (pass --loopback-probe URL with a live boot)"
else
  if curl -s -o /dev/null -m 3 "$LOOPBACK_PROBE"; then
    bad "loopback probe was ANSWERED ($LOOPBACK_PROBE); nothing should be published on the host"
  else
    ok "loopback probe refused ($LOOPBACK_PROBE)"
  fi
fi

unmet "off-source denial: needs a probe from a non-WG source or the Router's own allowlist review — this script cannot fake it"

echo "---"
echo "PASS=$PASS FAIL=$FAIL UNMET=$UNMET"
[ "$FAIL" -eq 0 ] || exit 1
[ "$UNMET" -eq 0 ] || exit 2
exit 0
