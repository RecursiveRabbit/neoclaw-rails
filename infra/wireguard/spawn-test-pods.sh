#!/bin/bash
# Spin up test pods with WireGuard, peer them to host interfaces.
#
# Each pod gets:
#   - Its own WG keypair (already generated)
#   - A wg0 interface inside the container
#   - Peers to the host interfaces it's authorized for
#   - An IP in the 10.0.1.x pool
#
# Run with sudo (podman needs NET_ADMIN for WG inside containers).

set -e
KEYDIR="$(dirname "$0")/keys"
HOST_IP=$(hostname -I | awk '{print $1}')

# Pod definitions: name, wg_ip, authorized_services (space-separated)
# Services map to host interface pubkeys and ports
PODS=(
  "pod-silas,10.0.1.1,hub git ssh valley vikunja"
  "pod-margaux,10.0.1.2,hub git ssh valley vikunja comfyui"
  "pod-kael,10.0.1.3,hub git ssh valley"
  "pod-hopper,10.0.1.4,hub git ssh valley vikunja comfyui matrix"
)

# Service → host interface mapping
declare -A SVC_PORT SVC_IP SVC_PUB
SVC_PORT[hub]=51820;     SVC_IP[hub]=10.0.0.1
SVC_PORT[manager]=51821; SVC_IP[manager]=10.0.0.2
SVC_PORT[git]=51823;     SVC_IP[git]=10.0.0.3
SVC_PORT[valley]=51824;  SVC_IP[valley]=10.0.0.4
SVC_PORT[vikunja]=51825; SVC_IP[vikunja]=10.0.0.5
SVC_PORT[comfyui]=51826; SVC_IP[comfyui]=10.0.0.6
SVC_PORT[matrix]=51827;  SVC_IP[matrix]=10.0.0.7
SVC_PORT[ssh]=51828;     SVC_IP[ssh]=10.0.0.8

# Load host pubkeys
for svc in hub manager git valley vikunja comfyui matrix ssh; do
  SVC_PUB[$svc]=$(cat "$KEYDIR/wg-$svc.pub")
done

spawn_pod() {
  local name="$1" pod_ip="$2" services="$3"
  local privkey=$(cat "$KEYDIR/$name.key")
  local pubkey=$(cat "$KEYDIR/$name.pub")

  echo "=== $name ($pod_ip) ==="
  echo "  services: $services"

  # Kill existing
  podman rm -f "$name" 2>/dev/null || true

  # Build WG config for this pod
  local wg_conf="[Interface]\nPrivateKey = $privkey\nAddress = $pod_ip/32\n"

  for svc in $services; do
    local peer_pub="${SVC_PUB[$svc]}"
    local peer_ip="${SVC_IP[$svc]}"
    local peer_port="${SVC_PORT[$svc]}"
    wg_conf+="\n[Peer]\nPublicKey = $peer_pub\nEndpoint = $HOST_IP:$peer_port\nAllowedIPs = $peer_ip/32\nPersistentKeepalive = 25\n"
  done

  # Start container
  local cid=$(podman run -d \
    --name "$name" \
    --hostname "$name" \
    --cap-add NET_ADMIN \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    localhost/neoclaw-test-pod:latest)

  echo "  container: ${cid:0:12}"

  # Write WG config and bring up interface inside the container
  podman exec "$name" bash -c "
    mkdir -p /etc/wireguard
    echo -e '$wg_conf' > /etc/wireguard/wg0.conf
    wg-quick up wg0
  "

  echo "  wg0 up inside $name"

  # Add this pod as a peer on each authorized host interface
  for svc in $services; do
    local iface="wg-$svc"
    wg set "$iface" peer "$pubkey" allowed-ips "$pod_ip/32"
    echo "  peered on $iface"
  done

  echo ""
}

echo "Host IP: $HOST_IP"
echo ""

for entry in "${PODS[@]}"; do
  IFS=',' read -r name pod_ip services <<< "$entry"
  spawn_pod "$name" "$pod_ip" "$services"
done

echo "=== Connectivity test ==="
for entry in "${PODS[@]}"; do
  IFS=',' read -r name pod_ip services <<< "$entry"
  echo "--- $name ($pod_ip) ---"

  # Pod pinging each host service it's peered with
  for svc in $services; do
    local svc_ip="${SVC_IP[$svc]}"
    result=$(podman exec "$name" ping -c1 -W2 "$svc_ip" 2>&1 | grep -o "1 packets received" || echo "FAIL")
    if [ "$result" = "1 packets received" ]; then
      echo "  ✓ $svc ($svc_ip)"
    else
      echo "  ✗ $svc ($svc_ip) — $result"
    fi
  done
  echo ""
done

echo "=== Done ==="
echo "Pods running. Use 'podman exec -it pod-silas bash' to explore."
