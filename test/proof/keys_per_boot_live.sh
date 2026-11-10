#!/usr/bin/env bash
set -euo pipefail

REPO=/home/sexton/neoclaw-rails-office-keys
IMAGE=localhost/neoclaw-router-proof:latest
TMP=$(mktemp -d /tmp/babo-key-proof-XXXXXX)
CONTAINERS=()
cleanup() {
  for c in "${CONTAINERS[@]}"; do
    sudo -n podman rm -f "$c" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; exit 1; }
key_prefix() { cut -c1-12 "$1"; }

start_router() {
  local name="$1" runtime="$2"
  CONTAINERS+=("$name")
  sudo -n podman run -d \
    --name "$name" \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --sysctl net.ipv4.ip_forward=1 \
    -v "$runtime/router:/etc/router:ro" \
    "$IMAGE" >/dev/null
  local i
  for i in $(seq 1 40); do
    if sudo -n podman exec "$name" curl -sf http://localhost:8080/health >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  sudo -n podman logs "$name" >&2
  fail "router $name did not become healthy"
}

render() {
  local runtime="$1"
  RUNTIME_DIR="$runtime" PUBLIC_DIR="$TMP/public" HOST_WG_PUBKEY="$(cat "$TMP/host.pub")" \
    bash -c 'source "$1/manager/runtime-keys.sh" && render_boot_runtime' _ "$REPO"
}

mkdir -p "$TMP/public"
(umask 077 && wg genkey > "$TMP/host.key")
wg pubkey < "$TMP/host.key" > "$TMP/host.pub"
printf '  user-1:\n    pubkey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="\n    allowed_ips: "10.2.0.1/32"\n' > "$TMP/public/users-peers.fragment"
printf '\nservices:\n  default:\n    tcp: [3100]\n' > "$TMP/public/router-services.yml"

A="$TMP/boot-a"
B="$TMP/boot-b"
render "$A"
key_a=$(cat "$A/router.pubkey")
[ "$(wg pubkey < "$A/router/private.key")" = "$key_a" ] || fail "boot A keypair mismatch"
[ "$(stat -c %a "$A")" = 700 ] || fail "boot A runtime dir is not 0700"
[ "$(stat -c %a "$A/router/private.key")" = 600 ] || fail "boot A private key is not 0600"
pass "boot A renders a consistent 0600 keypair in a 0700 runtime dir"

start_router babo-proof-a "$A"
pass "boot A Router is healthy with its rendered config"
sudo -n podman rm -f babo-proof-a >/dev/null

start_router babo-proof-a-replacement "$A"
key_a_replacement=$(cat "$A/router.pubkey")
[ "$key_a" = "$key_a_replacement" ] || fail "same-boot replacement changed Router key"
pass "Router replacement within boot A keeps the same key (${key_a:0:12}…), with no pod reconfiguration"
sudo -n podman rm -f babo-proof-a-replacement >/dev/null

render "$B"
key_b=$(cat "$B/router.pubkey")
[ "$key_a" != "$key_b" ] || fail "boot B reused boot A key"
pass "boot B has a different Router key (${key_b:0:12}…)"
start_router babo-proof-b "$B"
pass "boot B Router is healthy with the new key"
sudo -n podman rm -f babo-proof-b >/dev/null

sudo -n podman run --rm --entrypoint /bin/sh "$IMAGE" -c '
  test ! -e /etc/router/private.key &&
  test ! -e /etc/router/wg0.conf &&
  ! find /opt/router -type f -name "*.key" -print -quit | grep -q .
' || fail "image contains a key file"
pass "image contains no WireGuard private key or baked WG config"

set +e
output=$(sudo -n podman run --rm "$IMAGE" 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "Router without a mounted config started successfully"
printf '%s' "$output" | grep -q 'must be mounted' || fail "Router without config lacks the fail-closed message"
pass "Router without mounted config fails closed with the expected refusal"

printf 'LIVE PROOF PASS: same-boot key stable, next-boot key different, image keyless, missing config refuses\n'
