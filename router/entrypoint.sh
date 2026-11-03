#!/bin/sh
# NeoClaw Router entrypoint — applies Manager-provided network instructions.
#
# Contract (router/router.md): the Manager holds the Router's private key
# and ALL peering data. This process knows no agent names and no service
# names. It receives only what is required to bring up WireGuard and apply
# iptables rules. Default policy is denial; a rule creates a path, and no
# rule means no path.
#
# There is deliberately:
#   - no HTTP listener, no health API, no debug API;
#   - no registry, no database, no state directory;
#   - no re-registration of anything, ever.
#
# Inputs (read-only mount):
#   $NEOCLAW_CONFIG  (default /etc/neoclaw/network.json)
#   $NEOCLAW_KEY     (default /etc/neoclaw/router.key)
#
# The process then sleeps forever. Replacement = new container, same
# instructions. The Manager owns desired state; this container is a
# disposable appliance.

set -eu

CONF="${NEOCLAW_CONFIG:-/etc/neoclaw/network.json}"
KEY="${NEOCLAW_KEY:-/etc/neoclaw/router.key}"

fail() { echo "[router] FATAL: $*" >&2; exit 1; }

[ -r "$CONF" ] || fail "config not readable: $CONF"
[ -r "$KEY" ]   || fail "private key not readable: $KEY"
jq -e . "$CONF" >/dev/null 2>&1 || fail "config is not valid JSON: $CONF"

IFACE=$(jq -r '.interface // "wg0"' "$CONF")
ADDR=$(jq -r '.address' "$CONF")
PORT=$(jq -r '.listen_port // 51820' "$CONF")
MTU=$(jq -r '.mtu // 1420' "$CONF")
AGENT_NET=$(jq -r '.agent_network' "$CONF")

echo "$ADDR" | grep -Eq '^[0-9.]+/[0-9]+$' || fail "invalid address: $ADDR"
echo "$PORT" | grep -Eq '^[0-9]+$' || fail "invalid listen_port: $PORT"
echo "$AGENT_NET" | grep -Eq '^[0-9.]+/[0-9]+$' || fail "invalid agent_network: $AGENT_NET"

# ---------------------------------------------------------------- forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || \
  fail "ip_forward not enabled; run with --sysctl net.ipv4.ip_forward=1"

# ---------------------------------------------------------------- wireguard
ip link add "$IFACE" type wireguard 2>/dev/null || true
ip addr flush dev "$IFACE" 2>/dev/null || true
wg set "$IFACE" private-key "$KEY" listen-port "$PORT"

jq -c '.peers[]' "$CONF" | while read -r peer; do
    pub=$(echo "$peer" | jq -r '.public_key')
    ips=$(echo "$peer" | jq -r '.allowed_ips | join(",")')
    ka=$(echo "$peer" | jq -r '.persistent_keepalive // 25')
    ep=$(echo "$peer" | jq -r '.endpoint // empty')
    echo "$pub" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || fail "bad peer public key"
    set -- wg set "$IFACE" peer "$pub" allowed-ips "$ips" persistent-keepalive "$ka"
    [ -n "$ep" ] && set -- "$@" endpoint "$ep"
    "$@"
    echo "[router] peer applied: ${pub:0:12}... allowed-ips=$ips${ep:+ endpoint=$ep}"
done

ip addr add "$ADDR" dev "$IFACE"
ip link set mtu "$MTU" up dev "$IFACE"

jq -r '.routes[]?.destination' "$CONF" | while read -r dest; do
    ip route replace "$dest" dev "$IFACE"
    echo "[router] route: $dest via $IFACE"
done

# ---------------------------------------------------------------- iptables
# Default posture: deny everything that is not instructed.
iptables -P FORWARD DROP
iptables -P INPUT DROP
iptables -P OUTPUT ACCEPT

# WireGuard's inbound UDP terminates on this netns; allow it and the
# return traffic for everything this netns itself originates.
iptables -A INPUT -p udp --dport "$PORT" -m comment --comment "neoclaw-wg-inbound" -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Dedicated chain; rebuilt from scratch on every start (netns is fresh, so
# this is idempotent by construction).
iptables -N NEOCLAW_FWD 2>/dev/null || iptables -F NEOCLAW_FWD
iptables -C FORWARD -j NEOCLAW_FWD 2>/dev/null || iptables -A FORWARD -j NEOCLAW_FWD

# Return traffic for authorized connections.
iptables -A NEOCLAW_FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Instructed forwarding rules: raw source/destination/protocol/port only.
# The Router does not know what these addresses or ports mean.
jq -c '.forward_rules[]?' "$CONF" | while read -r rule; do
    src=$(echo "$rule" | jq -r '.source')
    dst=$(echo "$rule" | jq -r '.destination')
    proto=$(echo "$rule" | jq -r '.protocol')
    dport=$(echo "$rule" | jq -r '.destination_port // empty')
    echo "$src" | grep -Eq '^[0-9.]+/[0-9]+$' || fail "bad rule source: $src"
    echo "$dst" | grep -Eq '^[0-9.]+$' || fail "bad rule destination: $dst"
    case "$proto" in tcp|udp|icmp) ;; *) fail "bad rule protocol: $proto" ;; esac
    set -- iptables -A NEOCLAW_FWD -i "$IFACE" -s "$src" -d "$dst" -p "$proto"
    if [ -n "$dport" ]; then
        echo "$dport" | grep -Eq '^[0-9]+(:[0-9]+)?$' || fail "bad rule port: $dport"
        set -- "$@" --dport "$dport"
    fi
    "$@" -j ACCEPT -m comment --comment "neoclaw-authorized"
    echo "[router] forward rule: $src -> $dst $proto${dport:+ dport=$dport}"
done

# Agent-to-agent traffic is denied unless an instructed rule above created
# a path (source AND destination both inside the agent network).
iptables -A NEOCLAW_FWD -i "$IFACE" -s "$AGENT_NET" -d "$AGENT_NET" \
    -m comment --comment "neoclaw-agent-to-agent-deny" -j DROP

# Everything else not instructed: deny.
iptables -A NEOCLAW_FWD -m comment --comment "neoclaw-default-deny" -j DROP

# NAT only where explicitly instructed. Never ambient.
iptables -t nat -N NEOCLAW_NAT 2>/dev/null || iptables -t nat -F NEOCLAW_NAT
iptables -t nat -C POSTROUTING -j NEOCLAW_NAT 2>/dev/null || \
    iptables -t nat -A POSTROUTING -j NEOCLAW_NAT
jq -c '.nat_rules[]?' "$CONF" | while read -r rule; do
    src=$(echo "$rule" | jq -r '.source')
    out=$(echo "$rule" | jq -r '.out_interface')
    iptables -t nat -A NEOCLAW_NAT -s "$src" -o "$out" -j MASQUERADE
    echo "[router] NAT: $src out $out (instructed)"
done

# ------------------------------------------------------- session warm-up
# Roll requirement: <=2s interruption, worst case. WireGuard peers that
# remember a dead session will not re-initiate until their rekey timers
# expire (~120-180s) — far too slow. The replacement Router therefore
# initiates immediately: any outbound packet triggers a handshake for a
# peer with no valid session, and a valid initiation makes the peer adopt
# the new session at once. We ping every peer's tunnel IP once. Payload
# loss (e.g. an agent with no return route to us) is irrelevant — the
# handshake exchange is the point. Peers with no configured endpoint
# cannot be woken from here; the Manager covers those out of band via
# podman (its own wake step, outside this appliance).
jq -r '.peers[]? | .allowed_ips[]?' "$CONF" | while read -r cidr; do
    ipaddr=${cidr%/*}
    case "$ipaddr" in *:*) continue ;; esac
    ping -c 1 -W 1 "$ipaddr" >/dev/null 2>&1 || true
done
echo "[router] session warm-up: initiation sent to every peer"

# --------------------------------------------------------------------------
echo "[router] applied. no API, no registry, no state. holding."
exec tail -f /dev/null
