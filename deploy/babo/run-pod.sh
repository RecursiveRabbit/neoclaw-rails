#!/bin/bash
# Render and run the Babo pod in the D-10 two-container shape.
#
#   babo-core  the product process: owns wg0, NET_ADMIN in this pod's namespace,
#              the podman runtime socket, and the internal operator socket.
#   babo-ui    the privilege-minimal edge: no runtime socket, no NET_ADMIN, no
#              wg0. It joins the same pod network namespace and mounts the same
#              internal socket volume, so an operator CLI in either container can
#              use the internal socket without a second external door.
#
# The two containers share a pod network namespace and one named volume; they do
# NOT share privileges. Mounts and capabilities are stated per container here and
# asserted per container by `test/proof/babo_pod_shape_check.sh`.
#
#   run-pod.sh [--print] [--name babo] [--image IMAGE] [--core-image IMAGE]
#              [--ui-image IMAGE] [--spawn-dir DIR] [--runtime-socket PATH]
#              [--internal-volume NAME]
#
# `--print` renders the commands and exits; it does not touch the runtime. That
# is the mode the shape check uses, so the render is testable on any host.

set -eu

NAME="babo"
IMAGE="${BABO_IMAGE:-localhost/neoclaw-babo:latest}"
CORE_IMAGE=""
UI_IMAGE=""
SPAWN_DIR="${HOST_SPAWN_DIR:-/spawn}/runtime/babo"
RUNTIME_SOCKET="${BABO_RUNTIME_SOCKET:-/run/podman/podman.sock}"
INTERNAL_VOLUME="${BABO_INTERNAL_VOLUME:-babo-internal}"
NETWORK="${BABO_MESH_NETWORK:-babo-mesh}"
PRINT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --print) PRINT=1; shift ;;
    --name) NAME="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --core-image) CORE_IMAGE="$2"; shift 2 ;;
    --ui-image) UI_IMAGE="$2"; shift 2 ;;
    --spawn-dir) SPAWN_DIR="$2"; shift 2 ;;
    --runtime-socket) RUNTIME_SOCKET="$2"; shift 2 ;;
    --internal-volume) INTERNAL_VOLUME="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

CORE_IMAGE="${CORE_IMAGE:-$IMAGE}"
UI_IMAGE="${UI_IMAGE:-$IMAGE}"
INTERNAL_DIR="/run/babo/internal"

say() { echo "+ $*"; }
run() {
  if [ "$PRINT" = "1" ]; then say "$@"; else "$@"; fi
}

POD_ARGS=(pod create --name "$NAME" --network "$NETWORK")
say podman "${POD_ARGS[@]}"
[ "$PRINT" = "1" ] || podman "${POD_ARGS[@]}" >/dev/null

CORE=(
  run -d --pod "$NAME" --name "${NAME}-core" --hostname "${NAME}-core"
  --cap-add NET_ADMIN
  --device /dev/net/tun
  -v "${SPAWN_DIR}:/etc/wireguard:ro,Z"
  -v "${RUNTIME_SOCKET}:${RUNTIME_SOCKET}"
  -v "${INTERNAL_VOLUME}:${INTERNAL_DIR}:Z"
  -e BABO_ROLE=core
  -e "BABO_RUNTIME_CONFIG=/run/babo/config.json"
  -e "BABO_INTERNAL_SOCKET=${INTERNAL_DIR}/office.sock"
  "$CORE_IMAGE"
)
say podman "${CORE[@]}"
[ "$PRINT" = "1" ] || podman "${CORE[@]}" >/dev/null

UI=(
  run -d --pod "$NAME" --name "${NAME}-ui" --hostname "${NAME}-ui"
  -v "${INTERNAL_VOLUME}:${INTERNAL_DIR}:Z"
  -e BABO_ROLE=ui
  -e "BABO_RUNTIME_CONFIG=/run/babo/ui-config.json"
  "$UI_IMAGE"
)
say podman "${UI[@]}"
[ "$PRINT" = "1" ] || podman "${UI[@]}" >/dev/null

say "pod ${NAME}: ${NAME}-core (runtime socket, NET_ADMIN) + ${NAME}-ui (neither)"
