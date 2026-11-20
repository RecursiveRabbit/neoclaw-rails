#!/usr/bin/env bash
# APPARATUS, NOT A DELIVERABLE. Cove slice two, the pod's side of the tunnel.
#
# The desk closed spec open-item 2 by naming this script the specification for
# `Cove::Network` (cove.md, second draft + e6dd7a5/2884c36). It is here so that the
# Router's author and the Manager's author read the same commands, and so that the
# shape the spec now describes —
#
#   one extra link carrying exactly one /32 and no other route
#
# — is a thing you can run, not a paragraph you can misread. Section 3 also carries
# the trap this script paid for: plain `wg set` installs no routes, so every peer
# needs `ip route add <peer>/32 dev wg0` or the Router tells its own pods
# "Network unreachable" while the handshake counters look healthy.
#
# It stands up: a Router in its own netns, two agent-ish pods and one pretend
# service, all `--network none`, and then it measures them. Run it, read section 8
# and 9, run it again with `clean`.
#
# What it is NOT: the Router (soro's), the Manager's wiring (not built), or a proof
# from a landed ref. Replace the stand-in Router first; then port these commands into
# `Cove::Network` and delete nothing else.

# Question: can a pod be given a WireGuard interface such that (a) it can reach a
# Router and nothing else, (b) another pod is unreachable, (c) the internet and the
# host do not answer, and (d) the far end sees the pod's true tunnel IP?
#
# Layout (all rootful, all on z620):
#
#   host root ns ── br-cove 10.89.0.1/24 ─┬── veth-rr ── [netns cove-router]
#                                          │              10.89.0.2/24, wg0 10.90.0.1
#                                          ├── veth-a-h  (no address)
#                                          └── veth-s-h  (no address)
#   netns pod-a  : lo, wg0 10.90.1.11/32, veth-a-p (no address, one /32 route)
#   netns pod-s  : lo, wg0 10.90.0.10/32, veth-s-p (no address, one /32 route)
#
# The pod's transport is one unaddressed veth and a single /32 toward 10.89.0.2.
# Everything else it can reach is decided by the Router.
set -uo pipefail

NAME=a
W=/tmp/spike-wg
ROUTER_NS=cove-router
BR=br-cove
HOST_BR_IP=10.89.0.1/24
ROUTER_TRANSPORT=10.89.0.2
WG_NET=10.90.0.0/16
WAN=10.90.1.11
WANB=10.90.1.12
SRV=10.90.0.10
LISTEN=8080
PORT=51820

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
run() { echo "+ $*"; "$@"; }

cleanup() {
  log "cleanup"
  for c in spk-router spk-a spk-s; do sudo podman rm -f "$c" >/dev/null 2>&1 || true; done
  sudo ip netns del "$ROUTER_NS" >/dev/null 2>&1 || true
  sudo ip link del "$BR" >/dev/null 2>&1 || true
  # pods' netns die with the containers; veth peer ends go with them
}
[ "${1:-}" = "clean" ] && { cleanup; exit 0; }
cleanup
rm -rf "$W"; mkdir -p "$W"; umask 077

log "1. keys"
for k in router a s b; do wg genkey > "$W/$k.key"; wg pubkey < "$W/$k.key" > "$W/$k.pub"; done
echo "router pub: $(cat "$W/router.pub")"

log "2. images (router needs wg+iptables; the service needs something to serve)"
sudo podman build -q -t localhost/cove-spike-router:latest - <<'EOF'
FROM docker.io/library/alpine:3.20
RUN apk add --no-cache wireguard-tools iptables iproute2
CMD ["sleep", "infinity"]
EOF

log "3. the router's own netns, and the host bridge that is its only real interface"
sudo ip netns add "$ROUTER_NS"
sudo ip link add "$BR" type bridge
sudo ip addr add "$HOST_BR_IP" dev "$BR"
sudo ip link set "$BR" up
sudo ip link add veth-rr type veth peer name veth-rr-host
sudo ip link set veth-rr-host master "$BR"
sudo ip link set veth-rr-host up
sudo ip link set veth-rr netns "$ROUTER_NS"
sudo ip netns exec "$ROUTER_NS" ip addr add "$ROUTER_TRANSPORT/16" dev veth-rr
sudo ip netns exec "$ROUTER_NS" ip link set veth-rr up
sudo ip netns exec "$ROUTER_NS" ip link set lo up
echo "--- router ns interfaces:"; sudo ip netns exec "$ROUTER_NS" ip -br addr

log "4. router container joins that netns and builds wg0 in it"
sudo podman run -d --name spk-router --network "ns:/var/run/netns/$ROUTER_NS" \
  --cap-add NET_ADMIN --cap-add NET_RAW --security-opt label=disable \
  --sysctl net.ipv4.ip_forward=1 \
  -v "$W:$W:ro" localhost/cove-spike-router:latest >/dev/null
sleep 2
sudo podman exec spk-router sh -c "
  set -e
  ip link add wg0 type wireguard
  ip addr add 10.90.0.1/32 dev wg0
  wg set wg0 listen-port $PORT private-key $W/router.key
  ip link set wg0 up
  cat /proc/sys/net/ipv4/ip_forward
  iptables -P FORWARD DROP
  # the roads: only what the Manager permits. For the spike: pod-a -> service only.
  iptables -A FORWARD -i wg0 -o wg0 -s $WAN -d $SRV -p tcp --dport $LISTEN -j ACCEPT
  iptables -A FORWARD -i wg0 -o wg0 -s $SRV -d $WAN -p tcp --sport $LISTEN -j ACCEPT
  ip addr show wg0 | head -3
"

log "5. two pods with --network none, each with an unaddressed transport veth"
mkpod() { # name  wg-ip  transport-ip  image  cmd...
  local n="$1" ip="$2" tip="$3" img="$4"; shift 4
  local c="spk-$n"
  sudo podman run -d --name "$c" --network none --security-opt label=disable "$img" "$@" >/dev/null
  local pid; pid=$(sudo podman inspect -f '{{.State.Pid}}' "$c")
  sudo ip link add "veth-$n-h" type veth peer name "veth-$n-p"
  sudo ip link set "veth-$n-h" master "$BR"; sudo ip link set "veth-$n-h" up
  sudo ip link set "veth-$n-p" netns "$pid"
  # the transport link needs a source address, or the tunnel's packets leave from
  # 0.0.0.0 and the handshake never happens. One /32, nothing else.
  sudo nsenter -t "$pid" -n ip addr add "$tip/32" dev "veth-$n-p"
  # a transport link with no address at all: no v6 link-local either
  sudo nsenter -t "$pid" -n ip link set "veth-$n-p" addrgenmode none
  sudo nsenter -t "$pid" -n ip link set "veth-$n-p" up
  sudo nsenter -t "$pid" -n ip link set lo up
  sudo nsenter -t "$pid" -n ip link add wg0 type wireguard
  sudo nsenter -t "$pid" -n wg set wg0 private-key "$W/$n.key" listen-port 0
  sudo nsenter -t "$pid" -n ip addr add "$ip/32" dev wg0
  sudo nsenter -t "$pid" -n ip link set wg0 up
  # the one road: a /32 to the router's transport, over the unaddressed veth
  sudo nsenter -t "$pid" -n ip route add "$ROUTER_TRANSPORT/32" dev "veth-$n-p"
  sudo nsenter -t "$pid" -n wg set wg0 peer "$(cat "$W/router.pub")" \
      endpoint "$ROUTER_TRANSPORT:$PORT" allowed-ips "$WG_NET" persistent-keepalive 15
  sudo nsenter -t "$pid" -n ip route add "$WG_NET" dev wg0
  echo "  $c pid=$pid ip=$ip"
}

mkpod a "$WAN"  10.89.1.11 docker.io/library/alpine:3.20 sleep infinity
mkpod b "$WANB" 10.89.1.12 docker.io/library/python:3.12-alpine \
      python3 -m http.server 9999 --bind 0.0.0.0
mkpod s "$SRV" 10.89.1.10 docker.io/library/python:3.12-alpine \
      python3 -m http.server "$LISTEN" --bind 0.0.0.0

log "6. router peers"
# plain `wg set` does not install routes (only wg-quick does). Each peer's
# allowed-ips needs a route or the Router answers "Network unreachable" to its own pods.
sudo podman exec spk-router sh -c "
  wg set wg0 peer $(cat "$W/a.pub") allowed-ips $WAN/32
  wg set wg0 peer $(cat "$W/s.pub") allowed-ips $SRV/32
  wg set wg0 peer $(cat "$W/b.pub") allowed-ips $WANB/32
  ip route add $WAN/32 dev wg0
  ip route add $SRV/32 dev wg0
  ip route add $WANB/32 dev wg0
  wg show wg0 | head -20
"

log "7. what each pod can see (the spec says 'only wg0 and loopback' — check)"
for p in a s; do
  pid=$(sudo podman inspect -f '{{.State.Pid}}' "spk-$p")
  echo "--- spk-$p interfaces:"; sudo nsenter -t "$pid" -n ip -br addr
  echo "--- spk-$p routes:";   sudo nsenter -t "$pid" -n ip route
done

log "8. handshake and reachability"
sleep 3
# the first packet of the session is the handshake and is always lost; warm up first
pid_a=$(sudo podman inspect -f '{{.State.Pid}}' spk-a)
sudo nsenter -t "$pid_a" -n wget -q -O /dev/null -T4 http://$SRV:$LISTEN/ >/dev/null 2>&1
sleep 1
sudo podman exec spk-router wg show wg0 | sed -n '1,40p'
pid_a=$(sudo podman inspect -f '{{.State.Pid}}' spk-a)
echo "--- pod-a -> router wg address:"; sudo nsenter -t "$pid_a" -n ping -c1 -W2 10.90.0.1 2>&1 | tail -2
echo "--- pod-a -> service port:";      sudo nsenter -t "$pid_a" -n wget -q -O /dev/null -T3 "http://$SRV:$LISTEN/" ; echo "    wget rc=$?"
echo "--- pod-a -> internet (must fail):"; sudo nsenter -t "$pid_a" -n wget -q -O /dev/null -T3 http://1.1.1.1/ ; echo "    wget rc=$? (expect non-zero)"
echo "--- pod-a -> host bridge ip (must fail):"; sudo nsenter -t "$pid_a" -n ping -c1 -W2 10.89.0.1 2>&1 | tail -2

log "9. the other pod is dark: pod-a -> service-that-is-a-pod's *agent* address"
# there is no second agent yet; use the service pod's transport-side address instead:
echo "--- pod-a -> 10.89.0.2 (router transport, no permit):"
sudo nsenter -t "$pid_a" -n wget -q -O /dev/null -T2 http://10.89.0.2:80/ ; echo "    wget rc=$? (expect non-zero)"
echo "--- what the service saw as the client address (podman logs):"
sudo podman logs spk-s 2>&1 | tail -4

log "done — state left up for inspection; run '$0 clean' to remove"
