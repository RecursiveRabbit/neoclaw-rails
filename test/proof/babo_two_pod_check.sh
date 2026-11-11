#!/bin/bash
# Prove the D-12 two-pod render from its own output. No runtime touched.
# Rows: one underlay per peer, Router joins both, separate API/UI ports,
# addresses from the single source, manager socket only, no shared mount,
# headless image, egress allow-list derived from the service definitions.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RENDER="$HERE/../../deploy/babo/run-pods.sh"
PASS=0; FAIL=0; UNMET=0
ok()  { PASS=$((PASS+1)); echo "PASS   $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL   $*"; }
unmet() { UNMET=$((UNMET+1)); echo "UNMET  $*"; }

[ -x "$RENDER" ] || { echo "FAIL   render script not executable: $RENDER"; exit 1; }
OUT=$("$RENDER" --print) || { echo "FAIL   render failed: $OUT"; exit 1; }

ui=$(printf '%s\n' "$OUT" | grep -E 'podman run .*--name babo-ui-app' || true)
mgr=$(printf '%s\n' "$OUT" | grep -E 'podman run .*--name babo-manager-app' || true)

[ -n "$ui" ] && [ -n "$mgr" ] && ok "two containers rendered, one per pod" || bad "expected babo-ui-app and babo-manager-app"

# M-1: one underlay per peer, Router joins both.
case "$OUT" in
  *"pod create --name babo-ui --network babo-ui-mesh"*) ok "UI pod on its own underlay (babo-ui-mesh)" ;;
  *) bad "UI pod is not on its own underlay" ;;
esac
case "$OUT" in
  *"pod create --name babo-manager --network babo-manager-mesh"*) ok "Manager pod on its own underlay (babo-manager-mesh)" ;;
  *) bad "Manager pod is not on its own underlay" ;;
esac
if printf '%s\n' "$OUT" | grep -q "network connect babo-ui-mesh wg-router" \
   && printf '%s\n' "$OUT" | grep -q "network connect babo-manager-mesh wg-router"; then
  ok "the Router joins both underlays (the only shared peer, N-03)"
else
  bad "the Router is not rendered onto both underlays"
fi
if printf '%s\n' "$OUT" | grep -qE 'podman run .*--network'; then
  bad "a container carries --network directly instead of the pod's underlay"
else
  ok "containers attach via their pod, not a shared bridge"
fi

# M-2: separate API and UI port symbols.
case "$ui" in *"BABO_PORT=8843"*) ok "UI port is its own symbol (8843)" ;; *) bad "UI port missing" ;; esac
case "$mgr" in *"BABO_API_PORT=8844"*) ok "Manager API port is its own symbol (8844)" ;; *) bad "Manager API port missing" ;; esac
case "$mgr" in *"BABO_HEALTH_PORT=8844"*) ok "Manager health is on the API port (desk ruling)" ;; *) bad "Manager health is not on the API port" ;; esac
case "$ui" in
  *"BABO_MANAGER_HEALTH=http://10.0.0.10:8844/health"*) ok "UI health includes Manager reachability (desk ruling)" ;;
  *) bad "UI has no Manager health endpoint" ;;
esac

# The negative: a colliding address is refused by the renderer itself.
if "$RENDER" --check-address 10.0.0.9 >/dev/null 2>&1; then
  bad "the renderer accepts an address claimed by a service definition (10.0.0.9)"
else
  ok "the renderer refuses an address claimed by a service definition (10.0.0.9)"
fi
if "$RENDER" --check-address 10.0.0.10 >/dev/null 2>&1; then
  ok "the renderer accepts the Manager address (10.0.0.10 collides with neither table)"
else
  bad "the renderer refuses its own Manager address"
fi
if grep -q "BABO_MESH_NETWORK" "$HERE/../../deploy/babo/mesh.env"; then
  bad "an unconsumed third network name is still declared"
else
  ok "no unconsumed network name in the render source"
fi

# M-3: identities from the single source.
case "$ui" in *"BABO_WG_ADDRESS=10.0.0.5"*) ok "UI identity from the single source (10.0.0.5)" ;; *) bad "UI identity wrong" ;; esac
if "$RENDER" --check-address 10.0.0.5 >/dev/null 2>&1; then
  : # no collision
else
  unmet "UI identity 10.0.0.5 is claimed by a legacy service definition (vikunja); the desk must rule the legacy plan superseded or renumber the UI (D-12 address question)"
fi
case "$mgr" in *"BABO_WG_ADDRESS=10.0.0.10"*) ok "Manager identity from the single source (10.0.0.10)" ;; *) bad "Manager identity wrong" ;; esac

# D12-7: socket only in the manager; no shared mount.
case "$ui" in *"podman.sock"*) bad "babo-ui mounts the runtime socket" ;; *) ok "babo-ui mounts no runtime socket" ;; esac
case "$mgr" in *"/run/podman/podman.sock"*) ok "babo-manager mounts the runtime socket" ;; *) bad "Manager has no runtime socket" ;; esac
case "$mgr" in *"babo-ui:"*) bad "Manager mounts the UI runtime dir" ;; *) ok "no shared mount between the pods" ;; esac

# Headless: no ssh server in the image.
if grep -qE 'openssh-server|sshd' "$HERE/../../deploy/babo/Containerfile"; then
  bad "the image installs an ssh server"
else
  ok "the image installs no ssh server (Manager is headless)"
fi

# M-4: egress allow-list derived from the service definitions.
case "$mgr" in
  *"BABO_EGRESS_ALLOW="*) ok "Manager egress allow-list is rendered" ;;
  *) bad "Manager egress allow-list is missing" ;;
esac
case "$OUT" in
  *UNMET*) unmet "service definitions not readable here; egress allow-list unproven" ;;
esac

echo "---"
echo "PASS=$PASS FAIL=$FAIL UNMET=$UNMET"
[ "$FAIL" -eq 0 ] || exit 1
[ "$UNMET" -eq 0 ] || exit 2
exit 0
