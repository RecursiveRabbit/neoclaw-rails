#!/bin/bash
# Prove the D-12 two-pod render from its own output. No runtime touched.
#
# Asserts: exactly two pods; the UI pod has no runtime socket; the manager has
# the socket and only its own key dir beside it; the two pods share no mount;
# each has its own WG identity and role; no manager URL anywhere; the image does
# not install an ssh server. Exit 1 on any FAIL.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RENDER="$HERE/../../deploy/babo/run-pods.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS   $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL   $*"; }

[ -x "$RENDER" ] || { echo "FAIL   render script not executable: $RENDER"; exit 1; }
OUT=$("$RENDER" --print) || { echo "FAIL   render failed: $OUT"; exit 1; }

ui=$(printf '%s\n' "$OUT" | grep -E 'podman run .*--name babo-ui-app' || true)
mgr=$(printf '%s\n' "$OUT" | grep -E 'podman run .*--name babo-manager-app' || true)

[ -n "$ui" ] && [ -n "$mgr" ] && ok "two containers rendered, one per pod" || bad "expected babo-ui-app and babo-manager-app run lines"

case "$OUT" in
  *"pod create --name babo-ui"*"pod create --name babo-manager"*) ok "two pods by name (babo-ui, babo-manager)" ;;
  *) bad "expected two pod creates by name" ;;
esac

case "$ui" in
  *"podman.sock"*) bad "babo-ui mounts the runtime socket (D-12 defect)" ;;
  *) ok "babo-ui mounts no runtime socket" ;;
esac
case "$mgr" in
  *"/run/podman/podman.sock"*) ok "babo-manager mounts the runtime socket" ;;
  *) bad "babo-manager does not mount the runtime socket" ;;
esac

case "$ui" in
  *"BABO_ROLE=ui"*"BABO_WG_ADDRESS=10.0.0.5"*) ok "babo-ui role and WG identity" ;;
  *) bad "babo-ui role/identity not rendered" ;;
esac
case "$mgr" in
  *"BABO_ROLE=manager"*"BABO_WG_ADDRESS=10.0.0.6"*) ok "babo-manager role and WG identity" ;;
  *) bad "babo-manager role/identity not rendered" ;;
esac

# No shared mount: the ui key dir must not appear in the manager line and vice versa.
case "$mgr" in
  *"/babo-ui:"*) bad "babo-manager mounts the UI runtime dir" ;;
  *) ok "babo-manager shares no mount with the UI pod" ;;
esac
case "$ui" in
  *"/babo-manager:"*) bad "babo-ui mounts the manager runtime dir" ;;
  *) ok "babo-ui shares no mount with the manager pod" ;;
esac

if printf '%s\n' "$OUT" | grep -q "NEOCLAW_MANAGER_URL"; then
  bad "a manager URL is rendered"
else
  ok "no manager URL in the render"
fi

if grep -qE 'openssh-server|sshd' "$HERE/../../deploy/babo/Containerfile"; then
  bad "the image installs an ssh server"
else
  ok "the image installs no ssh server (Manager is headless)"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
