#!/bin/bash
# Prove the D-10 two-container render from its own output, not from the prose.
#
# Runs `deploy/babo/run-pod.sh --print` (no runtime touched) and asserts, per
# container: babo-core has the runtime socket mount, NET_ADMIN and the internal
# volume; babo-UI has NEITHER the socket nor NET_ADMIN and shares the internal
# volume; no manager URL is rendered anywhere. Exit 1 on any FAIL.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
RENDER="$HERE/../../deploy/babo/run-pod.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS   $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL   $*"; }

if [ ! -x "$RENDER" ]; then
  echo "FAIL   render script not executable: $RENDER"
  exit 1
fi

OUT=$("$RENDER" --print 2>&1) || { echo "FAIL   render failed: $OUT"; exit 1; }

core=$(printf '%s\n' "$OUT" | grep -E '^\+ podman run .*--name babo-core' || true)
ui=$(printf '%s\n' "$OUT" | grep -E '^\+ podman run .*--name babo-ui' || true)

if [ -n "$core" ] && [ -n "$ui" ]; then
  ok "two containers rendered by name (babo-core, babo-ui)"
else
  bad "expected one babo-core and one babo-ui run line"
fi

case "$core" in
  *"/run/podman/podman.sock"*) ok "babo-core mounts the podman runtime socket" ;;
  *) bad "babo-core does not mount the runtime socket" ;;
esac
case "$core" in
  *"--cap-add NET_ADMIN"*) ok "babo-core carries NET_ADMIN" ;;
  *) bad "babo-core does not carry NET_ADMIN" ;;
esac
case "$core" in
  *"babo-internal:/run/babo/internal"*) ok "babo-core mounts the internal socket volume" ;;
  *) bad "babo-core does not mount the internal volume" ;;
esac
case "$core" in
  *"BABO_INTERNAL_SOCKET=/run/babo/internal/office.sock"*) ok "babo-core renders the internal operator socket" ;;
  *) bad "babo-core does not render the internal operator socket" ;;
esac

case "$ui" in
  *"podman.sock"*) bad "babo-ui mounts the runtime socket (D-10 defect)" ;;
  *) ok "babo-ui mounts no runtime socket" ;;
esac
case "$ui" in
  *"--cap-add NET_ADMIN"*) bad "babo-ui carries NET_ADMIN (D-10 defect)" ;;
  *) ok "babo-ui carries no NET_ADMIN" ;;
esac
case "$ui" in
  *"babo-internal:/run/babo/internal"*) ok "babo-ui shares the internal socket volume" ;;
  *) bad "babo-ui does not share the internal volume" ;;
esac
case "$ui" in
  *"BABO_ROLE=ui"*) ok "babo-ui renders its role" ;;
  *) bad "babo-ui does not render BABO_ROLE=ui" ;;
esac

case "$OUT" in
  *"--network babo-mesh"*) ok "the pod joins one named mesh network (babo-mesh)" ;;
  *) bad "the pod does not join the named mesh network" ;;
esac

if printf '%s\n' "$OUT" | grep -q "NEOCLAW_MANAGER_URL"; then
  bad "a manager URL is rendered into the pod"
else
  ok "no manager URL in the render"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
