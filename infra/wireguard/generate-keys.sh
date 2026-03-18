#!/bin/bash
# Generate WireGuard keypairs for all interfaces and test pods.
# Run once. Keys land in ./keys/

set -e
KEYDIR="$(dirname "$0")/keys"
mkdir -p "$KEYDIR"

gen_keypair() {
  local name="$1"
  if [ -f "$KEYDIR/$name.key" ]; then
    echo "  exists: $name"
    return
  fi
  wg genkey | tee "$KEYDIR/$name.key" | wg pubkey > "$KEYDIR/$name.pub"
  chmod 600 "$KEYDIR/$name.key"
  echo "  generated: $name"
}

echo "=== Host interfaces ==="
for iface in hub manager git ssh valley vikunja comfyui matrix; do
  gen_keypair "wg-$iface"
done

echo "=== Test pods ==="
for pod in silas margaux kael hopper; do
  gen_keypair "pod-$pod"
done

echo "=== wg-admin helper ==="
gen_keypair "wg-admin"

echo ""
echo "Keys in $KEYDIR"
ls -la "$KEYDIR"
