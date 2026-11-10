#!/bin/bash
# babo_packaging_check.sh — skeleton, Munu's to complete and own.
#
# Purpose: prove the Babo pod's boundaries in the check's own words, not by
# quoting the design. Run on the deployment host (needs podman). Every check
# prints PASS/FAIL/unmet; unmet is a result, not a failure to hide.
#
# Usage: ./babo_packaging_check.sh <image>   (default localhost/neoclaw-babo:latest)
#
# Skeleton notes for Munu:
#   - Checks 1-3 need only `podman` and the image.
#   - Checks 4-5 need a booted Manager (per-boot runtime dir + Router) or an
#     equivalent disposable harness; if no Manager is running, print
#     "unmet: no Manager boot available" and exit 2 — do not invent a pass.
#
# Boundaries this script must not cross: it never touches production
# WireGuard, never starts a pod on a shared network, and never prints a
# private key.

set -u
IMAGE="${1:-localhost/neoclaw-babo:latest}"
PASS=0; FAIL=0; UNMET=0
ok()    { PASS=$((PASS+1));  echo "PASS   $*"; }
bad()   { FAIL=$((FAIL+1));  echo "FAIL   $*"; }
unmet() { UNMET=$((UNMET+1)); echo "UNMET  $*"; }

echo "== image: $IMAGE"

# --- 1. No WG key or config in the image -------------------------------
KEYS=$(podman run --rm --entrypoint /bin/sh "$IMAGE" \
        -c 'find / -xdev \( -name "*.key" -o -name "wg0.conf" \) 2>/dev/null | head -5')
if [ -z "$KEYS" ]; then ok "image contains no WG private key or wg0.conf"
else bad "image contains key material: $KEYS"; fi

# --- 2. No podman/docker socket in the image ---------------------------
SOCK=$(podman run --rm --entrypoint /bin/sh "$IMAGE" \
        -c 'ls /run/podman/podman.sock /var/run/docker.sock 2>/dev/null')
if [ -z "$SOCK" ]; then ok "image contains no container-runtime socket"
else bad "image contains a socket path: $SOCK"; fi

# --- 3. Entrypoint refuses to start with no mounted config -------------
if podman run --rm "$IMAGE" >/dev/null 2>&1; then
  bad "container started without a mounted wg0.conf"
else
  ok "container refuses to start without a mounted wg0.conf"
fi

# --- 4. Effective listener and mount set (needs a live boot) -----------
unmet "exactly one read-only mount, source under \$HOST_SPAWN_DIR/runtime/babo, target /etc/wireguard"
unmet "no published ports and no --network host (inspect the running container)"
unmet "host-WG probe 200 / loopback refused / off-source refused (Router)"
unmet "babo/web/dist present and served (UI bundle built in the image stage)"

echo "---"
echo "PASS=$PASS FAIL=$FAIL UNMET=$UNMET"
[ "$FAIL" -eq 0 ]
