#!/bin/bash
# NeoClaw infrastructure init.
#
# Reads services.conf, builds the entire WireGuard network from scratch.
# Generates keys if missing, creates interfaces, sets up policy routing,
# configures firewall rules.
#
# Idempotent — safe to re-run. Tears down existing interfaces first.
# Run with sudo.
#
# Usage:
#   sudo ./init.sh              # build everything
#   sudo ./init.sh teardown     # tear everything down
#   sudo ./init.sh status       # show current state

set -e
INFRA_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYDIR="$INFRA_DIR/wireguard/keys"
SERVICES_FILE="$INFRA_DIR/services.conf"
BRIDGE_SUBNET="10.88.0.0/16"    # podman default bridge
WG_SUBNET="10.0.0.0/16"         # our WG address space

# =================================================================
# Parse services.conf
# =================================================================

read_services() {
  local services=()
  while read -r name ip port; do
    [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
    services+=("$name,$ip,$port")
  done < "$SERVICES_FILE"
  echo "${services[@]}"
}

# =================================================================
# Key management
# =================================================================

ensure_keypair() {
  local name="$1"
  mkdir -p "$KEYDIR"
  if [ -f "$KEYDIR/wg-$name.key" ]; then
    return
  fi
  wg genkey | tee "$KEYDIR/wg-$name.key" | wg pubkey > "$KEYDIR/wg-$name.pub"
  chmod 600 "$KEYDIR/wg-$name.key"
  echo "  generated keypair: wg-$name"
}

# =================================================================
# Interface management
# =================================================================

create_interface() {
  local name="$1" ip="$2" port="$3"
  local iface="wg-$name"
  local privkey="$KEYDIR/$iface.key"
  local pubkey="$KEYDIR/$iface.pub"

  # Tear down if exists
  ip link delete "$iface" 2>/dev/null || true

  # Create
  ip link add "$iface" type wireguard
  ip addr add "$ip/32" dev "$iface"
  wg set "$iface" private-key "$privkey" listen-port "$port"
  ip link set "$iface" up

  echo "  up: $iface = $ip:$port"
}

teardown_interface() {
  local name="$1"
  local iface="wg-$name"
  ip link delete "$iface" 2>/dev/null && echo "  down: $iface" || true
}

# =================================================================
# Policy routing
# =================================================================

setup_routing() {
  local name="$1" ip="$2"
  local iface="wg-$name"
  local octet="${ip##*.}"
  local table_id="1${octet}"

  # Remove existing rule
  ip rule del from "$ip" lookup "$table_id" 2>/dev/null || true

  # Add rule and route
  ip rule add from "$ip" lookup "$table_id"
  ip route replace "$WG_SUBNET" dev "$iface" table "$table_id"

  echo "  route: from $ip → table $table_id → $iface"
}

teardown_routing() {
  local ip="$1"
  local octet="${ip##*.}"
  local table_id="1${octet}"
  ip rule del from "$ip" lookup "$table_id" 2>/dev/null || true
  ip route flush table "$table_id" 2>/dev/null || true
}

# =================================================================
# Firewall
# =================================================================

setup_firewall() {
  # Block bridge → WG address space (prevents bypass of WG auth)
  iptables -C INPUT -s "$BRIDGE_SUBNET" -d "$WG_SUBNET" -j DROP 2>/dev/null || \
    iptables -I INPUT -s "$BRIDGE_SUBNET" -d "$WG_SUBNET" -j DROP
  echo "  iptables: DROP $BRIDGE_SUBNET → $WG_SUBNET on INPUT"

  # UFW: allow WG UDP from podman bridge
  # Find the podman bridge interface name
  local bridge=$(ip -o link show type bridge | grep podman | head -1 | awk -F': ' '{print $2}')
  if [ -n "$bridge" ]; then
    # Get port range from services
    local min_port=99999 max_port=0
    for entry in $(read_services); do
      IFS=',' read -r name ip port <<< "$entry"
      [ "$port" -lt "$min_port" ] && min_port="$port"
      [ "$port" -gt "$max_port" ] && max_port="$port"
    done
    ufw allow in on "$bridge" proto udp to any port "$min_port:$max_port" \
      comment "WG - neoclaw-rails" 2>/dev/null || true
    echo "  ufw: allow UDP $min_port:$max_port on $bridge"
  fi
}

teardown_firewall() {
  iptables -D INPUT -s "$BRIDGE_SUBNET" -d "$WG_SUBNET" -j DROP 2>/dev/null || true
  echo "  iptables rule removed"
}

# =================================================================
# Manager peering
# =================================================================

peer_manager() {
  local manager_pub=$(cat "$KEYDIR/wg-manager.pub" 2>/dev/null)
  if [ -z "$manager_pub" ]; then
    echo "  WARNING: no manager key, skipping manager peering"
    return
  fi

  local manager_ip=""
  for entry in $(read_services); do
    IFS=',' read -r name ip port <<< "$entry"
    [ "$name" = "manager" ] && manager_ip="$ip"
  done

  for entry in $(read_services); do
    IFS=',' read -r name ip port <<< "$entry"
    [ "$name" = "manager" ] && continue
    wg set "wg-$name" peer "$manager_pub" allowed-ips "$manager_ip/32"
    echo "  wg-$name: manager peered"
  done
}

# =================================================================
# Commands
# =================================================================

cmd_init() {
  echo "=== NeoClaw Infrastructure Init ==="
  echo ""

  echo "--- Keys ---"
  for entry in $(read_services); do
    IFS=',' read -r name ip port <<< "$entry"
    ensure_keypair "$name"
  done
  echo ""

  echo "--- Interfaces ---"
  for entry in $(read_services); do
    IFS=',' read -r name ip port <<< "$entry"
    create_interface "$name" "$ip" "$port"
  done
  echo ""

  echo "--- Policy Routing ---"
  for entry in $(read_services); do
    IFS=',' read -r name ip port <<< "$entry"
    setup_routing "$name" "$ip"
  done
  echo ""

  echo "--- Manager Peering ---"
  peer_manager
  echo ""

  echo "--- Firewall ---"
  setup_firewall
  echo ""

  echo "=== Done ==="
  echo ""
  echo "Services:"
  for entry in $(read_services); do
    IFS=',' read -r name ip port <<< "$entry"
    local pub=$(cat "$KEYDIR/wg-$name.pub" 2>/dev/null | head -c 20)
    echo "  wg-$name  $ip:$port  pubkey:${pub}..."
  done
  echo ""
  echo "Add a service: add a line to services.conf, re-run init.sh"
  echo "Remove a service: remove the line, run init.sh teardown then init.sh"
}

cmd_teardown() {
  echo "=== NeoClaw Infrastructure Teardown ==="
  echo ""

  echo "--- Interfaces ---"
  for entry in $(read_services); do
    IFS=',' read -r name ip port <<< "$entry"
    teardown_interface "$name"
  done
  echo ""

  echo "--- Routing ---"
  for entry in $(read_services); do
    IFS=',' read -r name ip port <<< "$entry"
    teardown_routing "$ip"
  done
  echo ""

  echo "--- Firewall ---"
  teardown_firewall
  echo ""

  echo "=== Torn down ==="
}

cmd_status() {
  echo "=== NeoClaw Infrastructure Status ==="
  echo ""

  for entry in $(read_services); do
    IFS=',' read -r name ip port <<< "$entry"
    local iface="wg-$name"
    if ip link show "$iface" &>/dev/null; then
      local state=$(ip -o link show "$iface" | grep -o "state [A-Z]*" | awk '{print $2}')
      local peers=$(wg show "$iface" peers 2>/dev/null | wc -l)
      local handshakes=$(wg show "$iface" latest-handshakes 2>/dev/null | grep -v "0$" | wc -l)
      echo "  ✓ $iface  $ip:$port  state=$state  peers=$peers  active=$handshakes"
    else
      echo "  ✗ $iface  not running"
    fi
  done

  echo ""

  # Check firewall
  if iptables -C INPUT -s "$BRIDGE_SUBNET" -d "$WG_SUBNET" -j DROP 2>/dev/null; then
    echo "  ✓ bridge isolation active"
  else
    echo "  ✗ bridge isolation NOT active"
  fi

  # Check routing tables
  local missing_routes=0
  for entry in $(read_services); do
    IFS=',' read -r name ip port <<< "$entry"
    local octet="${ip##*.}"
    local table_id="1${octet}"
    if ! ip rule show | grep -q "from $ip lookup $table_id"; then
      echo "  ✗ missing route rule: from $ip lookup $table_id"
      missing_routes=1
    fi
  done
  [ "$missing_routes" -eq 0 ] && echo "  ✓ policy routing complete"
}

# =================================================================
# Entry point
# =================================================================

case "${1:-init}" in
  init)     cmd_init ;;
  teardown) cmd_teardown ;;
  status)   cmd_status ;;
  *)
    echo "Usage: $0 {init|teardown|status}"
    exit 1
    ;;
esac
