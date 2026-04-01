#!/bin/bash
# Create all WireGuard interfaces on the host.
# Each service gets its own interface, its own port, its own IP.
# Agents get peered on the interfaces they're authorized for.
#
# Run with sudo. Idempotent — safe to re-run.

set -e
KEYDIR="$(dirname "$0")/keys"

# Service interfaces — static IPs, unique listen ports
# Format: name, IP, listen_port
INTERFACES=(
  "wg-hub,10.0.0.1,51820"
  "wg-manager,10.0.0.2,51821"
  "wg-git,10.0.0.3,51823"
  "wg-valley,10.0.0.4,51824"
  "wg-vikunja,10.0.0.5,51825"
  "wg-comfyui,10.0.0.6,51826"
  "wg-matrix,10.0.0.7,51827"
  "wg-ssh,10.0.0.8,51828"
)

create_interface() {
  local name="$1" ip="$2" port="$3"
  local privkey="$KEYDIR/$name.key"
  local pubkey="$KEYDIR/$name.pub"

  if ! [ -f "$privkey" ]; then
    echo "ERROR: no key for $name at $privkey"
    return 1
  fi

  # Tear down if exists — clean slate
  ip link delete "$name" 2>/dev/null || true
  sleep 0.1

  # Create interface
  ip link add "$name" type wireguard
  ip addr add "$ip/32" dev "$name"
  wg set "$name" \
    private-key "$privkey" \
    listen-port "$port"
  ip link set "$name" up

  echo "  up: $name = $ip:$port (pubkey: $(cat "$pubkey"))"
}

echo "=== Creating host WireGuard interfaces ==="
for entry in "${INTERFACES[@]}"; do
  IFS=',' read -r name ip port <<< "$entry"
  create_interface "$name" "$ip" "$port"
done

echo ""
echo "=== Adding Manager as peer on all interfaces ==="
MANAGER_PUB=$(cat "$KEYDIR/wg-manager.pub")
# The Manager needs to reach every interface for provisioning
for entry in "${INTERFACES[@]}"; do
  IFS=',' read -r name ip port <<< "$entry"
  # Skip the manager's own interface
  [ "$name" = "wg-manager" ] && continue
  wg set "$name" peer "$MANAGER_PUB" allowed-ips "10.0.0.2/32"
  echo "  $name: added manager peer"
done

echo ""
echo "=== Source-based policy routing ==="
# Each service interface gets its own routing table.
# Responses from a service IP route back through that service's WG interface.
# See docs/NETWORK.md for the full explanation.
for entry in "${INTERFACES[@]}"; do
  IFS=',' read -r name ip port <<< "$entry"
  local_octet="${ip##*.}"
  table_id="1${local_octet}"

  ip rule del from "$ip" lookup "$table_id" 2>/dev/null || true
  ip rule add from "$ip" lookup "$table_id"
  ip route replace 10.0.0.0/8 dev "$name" table "$table_id"

  echo "  $name ($ip) → table $table_id"
done

echo ""
echo "=== Bridge back door prevention ==="
# Block podman bridge traffic to WG address space.
# Agents can only reach WG addresses through WireGuard, not the bridge.
# Internet access via bridge NAT is unaffected.
iptables -C INPUT -s 10.88.0.0/16 -d 10.0.0.0/8 -j DROP 2>/dev/null || \
  iptables -I INPUT -s 10.88.0.0/16 -d 10.0.0.0/8 -j DROP
echo "  iptables: DROP 10.88.0.0/16 → 10.0.0.0/8 on INPUT"

echo ""
echo "=== Interface status ==="
for entry in "${INTERFACES[@]}"; do
  IFS=',' read -r name ip port <<< "$entry"
  echo "--- $name ---"
  wg show "$name" 2>/dev/null | head -5
  echo ""
done

echo "=== Done ==="
echo "Host interfaces ready. Next: spin up pods and add them as peers."
