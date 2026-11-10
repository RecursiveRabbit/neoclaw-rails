#!/bin/bash
# babo_packaging_check.sh — prove the Babo pod's boundaries in the check's own
# words, not by quoting the design.
#
# Runs on the deployment host (needs podman). Every line prints PASS, FAIL or
# UNMET. UNMET is a result — a claim this script cannot prove from the inputs
# it was given — and it is never converted into a pass by softening the
# assertion. The script never prints a key, never touches production
# WireGuard, and never starts anything on a shared network.
#
# Usage:
#   babo_packaging_check.sh [IMAGE] [options]
#
#   IMAGE                 default: localhost/neoclaw-babo:latest
#   --container NAME      also inspect a RUNNING container of this image
#                         (mount set, published ports, network mode, caps)
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
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 64 ;;
    *) IMAGE="$1"; shift ;;
  esac
done

PASS=0; FAIL=0; UNMET=0
ok()    { PASS=$((PASS+1));  echo "PASS   $*"; }
bad()   { FAIL=$((FAIL+1));  echo "FAIL   $*"; }
unmet() { UNMET=$((UNMET+1)); echo "UNMET  $*"; }

run_in_image() { # entrypoint, shell command
  podman run --rm --entrypoint "$1" "$IMAGE" -c "$2" 2>/dev/null
}

echo "== image: $IMAGE"
podman image exists "$IMAGE" || { echo "FAIL   image not present: $IMAGE"; exit 1; }

# --- 1. No WireGuard key or config in the image ------------------------
WG=$(run_in_image /bin/sh '
  find / -xdev -name "wg0.conf" 2>/dev/null
  grep -rls -- "PrivateKey" /etc /usr/local /opt 2>/dev/null
  true')
if [ -z "$WG" ]; then
  ok "image contains no wg0.conf and no WireGuard private key"
else
  bad "image contains key material (paths only): $(echo "$WG" | tr '\n' ' ')"
fi

# --- 2. No container-runtime socket and no runtime client --------------
RT=$(run_in_image /bin/sh '
  ls /run/podman/podman.sock /var/run/docker.sock 2>/dev/null
  command -v podman docker ctr nerdctl 2>/dev/null
  true')
if [ -z "$RT" ]; then
  ok "image has no podman/docker socket and no container-runtime client"
else
  bad "image carries a runtime socket or client: $(echo "$RT" | tr '\n' ' ')"
fi

# --- 3. The entrypoint refuses to start without a mounted config -------
set +e
OUT3=$(podman run --rm "$IMAGE" 2>&1); RC3=$?
if [ "$RC3" -ne 0 ] && echo "$OUT3" | grep -q "wg0.conf not mounted"; then
  ok "container refuses to start without a mounted wg0.conf (rc=$RC3, reason stated)"
elif [ "$RC3" -ne 0 ]; then
  bad "container failed without the expected reason (rc=$RC3): $(echo "$OUT3" | tail -1)"
else
  bad "container started with no mounted wg0.conf"
fi

# --- 4. The installed package ships a built UI -------------------------
UI=$(run_in_image python3 -c "
import os, babo.web
p = os.path.join(os.path.dirname(babo.web.__file__), 'dist', 'index.html')
print(p if os.path.isfile(p) and os.path.getsize(p) > 0 else 'MISSING:' + p)" 2>/dev/null)
case "$UI" in
  MISSING:*) bad "installed package has no web bundle: ${UI#MISSING:}" ;;
  *.html)    ok "installed package ships the built UI ($UI)" ;;
  *)         bad "could not determine the web bundle path: ${UI:-<empty>}" ;;
esac

# --- 5. The Manager default is not loopback ---------------------------
MURL=$(run_in_image python3 -c "from babo.office.backend import DEFAULT_MANAGER_URL; print(DEFAULT_MANAGER_URL)" 2>/dev/null)
case "$MURL" in
  "")                 bad "could not read DEFAULT_MANAGER_URL from the image" ;;
  *127.0.0.1*|*localhost*|*"://[::1]"*) bad "Manager default is loopback: $MURL" ;;
  http*)              ok "Manager default is not loopback ($MURL)" ;;
  *)                  bad "Manager default is not a URL: $MURL" ;;
esac

# --- 6. The bind is rendered from the interface, not defaulted ---------
EP=$(run_in_image /bin/sh 'cat /usr/local/bin/babo-entrypoint 2>/dev/null')
if [ -z "$EP" ]; then
  bad "image has no /usr/local/bin/babo-entrypoint"
else
  if echo "$EP" | grep -q "gateway.host" && echo "$EP" | grep -q "ip -4 -o addr show dev wg0"; then
    ok "entrypoint renders gateway.host from the wg0 address"
  else
    bad "entrypoint does not render the bind from the wg0 address"
  fi
  if echo "$EP" | grep -qE -- "--host[ =]"; then
    bad "entrypoint passes --host, which 'babo webui' does not accept"
  else
    ok "entrypoint does not rely on a --host flag"
  fi
fi

# --- 7-9. Run-time facts, from a live container ------------------------
if [ -z "$CONTAINER" ]; then
  unmet "mount set: exactly one read-only bind, source under $SPAWN_DIR, target /etc/wireguard (pass --container NAME)"
  unmet "no published ports, no --network host (pass --container NAME)"
  unmet "capabilities: NET_ADMIN only, scoped to this container (pass --container NAME)"
else
  if [ -z "$SPAWN_DIR" ]; then
    unmet "mount source prefix unknown: pass --spawn-dir or set HOST_SPAWN_DIR"
  fi
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
  if [ "$CAPADD" = '["NET_ADMIN"]' ] && { [ "$CAPDROP" = "null" ] || [ "$CAPDROP" = "[]" ]; }; then
    ok "capabilities are exactly NET_ADMIN (container namespace only)"
  else
    bad "capability set is not exactly NET_ADMIN (CapAdd=$CAPADD CapDrop=$CAPDROP)"
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
