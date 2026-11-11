#!/bin/bash
# Render and run the two separate Babo pods (D-12).
#
#   babo-ui       the operator's only door: its own wg0 at 10.0.0.5, the
#                 user-facing listener on 8843, host /32 trusted.
#   babo-manager  the deterministic core: its own wg0 at 10.0.0.6, the runtime
#                 socket, and the UI /32 as its only trusted source. Headless.
#
# No shared mount, volume or network namespace between the pods (D12-8): each
# has its own runtime dir and its own pod. `--print` renders without touching a
# runtime, which is the mode the shape check uses.
#
# The API hop itself (UI -> Manager) is the core/API work; this script renders
# the pods and their identities, not the protocol.

set -eu

UI_NAME="${BABO_UI_POD:-babo-ui}"
MGR_NAME="${BABO_MANAGER_POD:-babo-manager}"
IMAGE="${BABO_IMAGE:-localhost/neoclaw-babo:latest}"
SPAWN_ROOT="${HOST_SPAWN_DIR:-/spawn}/runtime"
RUNTIME_SOCKET="${BABO_RUNTIME_SOCKET:-/run/podman/podman.sock}"
NETWORK="${BABO_MESH_NETWORK:-babo-mesh}"
UI_ADDR="${BABO_UI_ADDRESS:-10.0.0.5}"
MGR_ADDR="${BABO_MANAGER_ADDRESS:-10.0.0.6}"
UI_PORT="${BABO_PORT:-8843}"
API_PORT="${BABO_API_PORT:-8843}"
PRINT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --print) PRINT=1; shift ;;
    --image) IMAGE="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --ui-address) UI_ADDR="$2"; shift 2 ;;
    --manager-address) MGR_ADDR="$2"; shift 2 ;;
    --api-port) API_PORT="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

run() { if [ "$PRINT" = "1" ]; then printf '+ %s\n' "$*"; else "$@"; fi; }

UI_KEY="${SPAWN_ROOT}/babo-ui"
MGR_KEY="${SPAWN_ROOT}/babo-manager"

run podman pod create --name "$UI_NAME" --network "$NETWORK"
run podman run -d --pod "$UI_NAME" --name "${UI_NAME}-app" \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -v "${UI_KEY}:/etc/wireguard:ro,Z" \
  -e BABO_ROLE=ui -e "BABO_WG_ADDRESS=${UI_ADDR}" \
  -e "BABO_PORT=${UI_PORT}" \
  -e "BABO_RUNTIME_CONFIG=/run/babo/config.json" \
  "$IMAGE"

run podman pod create --name "$MGR_NAME" --network "$NETWORK"
run podman run -d --pod "$MGR_NAME" --name "${MGR_NAME}-app" \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -v "${MGR_KEY}:/etc/wireguard:ro,Z" \
  -v "${RUNTIME_SOCKET}:${RUNTIME_SOCKET}" \
  -e BABO_ROLE=manager -e "BABO_WG_ADDRESS=${MGR_ADDR}" \
  -e "BABO_API_PORT=${API_PORT}" \
  -e "BABO_RUNTIME_CONFIG=/run/babo/config.json" \
  "$IMAGE"
