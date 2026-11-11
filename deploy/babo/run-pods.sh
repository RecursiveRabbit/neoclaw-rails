#!/bin/bash
# Render and run the two separate Babo pods (D-12). No runtime touched in --print.
#
#   babo-ui       the operator's only door; own wg0, listener on 8843.
#   babo-manager  the deterministic core; own wg0, runtime socket, headless;
#                 API (and /health) on its own port.
#
# Shape rules this script encodes:
#   - one underlay network per peer, Router joins both (N-03). The two pods never
#     share a bridge, so UI->Manager is routed and the Router's rule is consulted.
#   - addresses and ports come from deploy/babo/mesh.env, one source (N-01).
#   - separate API and UI port symbols (N-05): 8844 != 8843.
#   - the Manager's egress allow-list is derived from the service definitions,
#     deny-by-default; a named service with no port is a render refusal.
#   - no shared mount, volume or namespace between the pods (D12-8).

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/mesh.env"

UI_NAME="${BABO_UI_POD:-babo-ui}"
MGR_NAME="${BABO_MANAGER_POD:-babo-manager}"
IMAGE="${BABO_IMAGE:-localhost/neoclaw-babo:latest}"
SPAWN_ROOT="${HOST_SPAWN_DIR:-/spawn}/runtime"
RUNTIME_SOCKET="${BABO_RUNTIME_SOCKET:-/run/podman/podman.sock}"
ROUTER_CONTAINER="${BABO_ROUTER_CONTAINER:-wg-router}"
PRINT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --print) PRINT=1; shift ;;
    --image) IMAGE="$2"; shift 2 ;;
    --check-address) CHECK_ADDRESS="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

[ "$BABO_UI_PORT" != "$BABO_API_PORT" ] || {
  echo "FATAL: UI and API ports are the same symbol value ($BABO_UI_PORT)" >&2; exit 1; }

DEFS_CHECK="$HERE/../../${BABO_SERVICE_DEFINITIONS}"
address_taken() { # address -> 0 when any legacy service definition claims it
  [ -r "$DEFS_CHECK" ] || return 1
  awk -v a="$1" '$2 == a {found=1} END {exit !found}' "$DEFS_CHECK"
}
if [ -n "${CHECK_ADDRESS:-}" ]; then
  if address_taken "$CHECK_ADDRESS"; then
    echo "TAKEN: ${CHECK_ADDRESS} is claimed by a service definition" >&2; exit 1
  fi
  echo "FREE: ${CHECK_ADDRESS} collides with no service definition"; exit 0
fi
if address_taken "$BABO_MANAGER_ADDRESS"; then
  echo "FATAL: the Manager address ${BABO_MANAGER_ADDRESS} is claimed by a service definition; N-01 forbids shipping it" >&2
  exit 1
fi

DEFS="$HERE/../../${BABO_SERVICE_DEFINITIONS}"
EGRESS=""
if [ -r "$DEFS" ]; then
  for svc in $BABO_EGRESS_SERVICES; do
    line=$(awk -v s="$svc" '$1 == s {print; exit}' "$DEFS")
    [ -n "$line" ] || { echo "FATAL: service '$svc' has no definition; cannot render egress" >&2; exit 1; }
    port=$(printf '%s\n' "$line" | awk '{print $4}')
    [ -n "$port" ] || { echo "FATAL: service '$svc' defines no port; deny-by-default cannot allow it" >&2; exit 1; }
    ip=$(printf '%s\n' "$line" | awk '{print $2}')
    EGRESS="${EGRESS}manager->${ip}:${port} "
  done
else
  EGRESS="UNMET: ${BABO_SERVICE_DEFINITIONS} not found"
fi

run() { if [ "$PRINT" = "1" ]; then printf '+ %s\n' "$*"; else "$@"; fi; }

run podman pod create --name "$UI_NAME" --network "$BABO_UI_NETWORK"
run podman run -d --pod "$UI_NAME" --name "${UI_NAME}-app" \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -v "${SPAWN_ROOT}/babo-ui:/etc/wireguard:ro,Z" \
  -e BABO_ROLE=ui -e "BABO_WG_ADDRESS=${BABO_UI_ADDRESS}" \
  -e "BABO_PORT=${BABO_UI_PORT}" \
  -e "BABO_MANAGER_API=http://${BABO_MANAGER_ADDRESS}:${BABO_API_PORT}" \
  -e "BABO_MANAGER_HEALTH=http://${BABO_MANAGER_ADDRESS}:${BABO_API_PORT}/health" \
  -e "BABO_RUNTIME_CONFIG=/run/babo/config.json" \
  "$IMAGE"

run podman pod create --name "$MGR_NAME" --network "$BABO_MANAGER_NETWORK"
run podman run -d --pod "$MGR_NAME" --name "${MGR_NAME}-app" \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -v "${SPAWN_ROOT}/babo-manager:/etc/wireguard:ro,Z" \
  -v "${RUNTIME_SOCKET}:${RUNTIME_SOCKET}" \
  -e BABO_ROLE=manager -e "BABO_WG_ADDRESS=${BABO_MANAGER_ADDRESS}" \
  -e "BABO_API_PORT=${BABO_API_PORT}" -e "BABO_HEALTH_PORT=${BABO_API_PORT}" \
  -e "BABO_EGRESS_ALLOW=${EGRESS// /,}" \
  -e "BABO_RUNTIME_CONFIG=/run/babo/config.json" \
  "$IMAGE"

run podman network connect "$BABO_UI_NETWORK" "$ROUTER_CONTAINER"
run podman network connect "$BABO_MANAGER_NETWORK" "$ROUTER_CONTAINER"
