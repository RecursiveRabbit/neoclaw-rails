#!/usr/bin/env bash
# NeoClaw Rails — vertical-slice network test (VERTICAL-SLICE-TEST.md §2).
#
# Runs on z620. DISPOSABLE ONLY: dedicated podman network (10.99.1.0/24),
# neoclaw-test-* containers, and Manager state under a fresh temp dir.
# Production WireGuard interfaces (wg0, wg-hub, nc-host), the host
# firewall, production Synapse, and live residents are never touched.
#
# Evidence: everything tees to evidence/<timestamp>/transcript.log plus
# per-check captures. Exits non-zero if any check fails.
#
# What is proven (mapped to VERTICAL-SLICE-TEST.md §2):
#   2.2  agent paired only with Router; Manager+Router paired with host
#   2.3  authorized host destination/port works
#   2.4  unauthorized port on same host fails
#   2.5  unauthorized source fails; agent-to-agent path fails
#   2.6  another peer's source IP is rejected
#   2.7  no API listener / registry / persistent state on the Router
#   2.8  Router replaced from Manager desired state
#   2.9  same IP / public key / peers; agent WG config untouched
#   2.10 authorized and unauthorized packet tests repeated after roll

set -u
cd "$(dirname "$0")/../../.."   # repo root
REPO=$PWD

STAMP=$(date +%Y%m%d-%H%M%S)
RUN="test/slice/network/evidence/$STAMP"
mkdir -p "$RUN"
LOG="$RUN/transcript.log"
: > "$LOG"

PASS=0; FAIL=0

log()  { echo "$*" | tee -a "$LOG"; }
ok()   { PASS=$((PASS+1)); log "PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); log "FAIL  $*"; }
hdr()  { log ""; log "=== $* ==="; }

runlog() { # run a command, tee output to transcript, return status
  echo "+ $*" >> "$LOG"
  "$@" 2>&1 | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}

# ------------------------------------------------------------ topology
NET=neoclaw-test
SUBNET=10.99.1.0/24
IP_ROUTER=10.99.1.10
IP_HOST=10.99.1.2
IP_MANAGER=10.99.1.3
IP_AGENT_A=10.99.1.11
IP_AGENT_B=10.99.1.12

C_ROUTER=neoclaw-test-router
C_HOST=neoclaw-test-host
C_MANAGER=neoclaw-test-manager
C_A=neoclaw-test-agent-a
C_B=neoclaw-test-agent-b

STATE=$(mktemp -d /tmp/neoclaw-netstate.XXXXXX)
chmod 700 "$STATE"
log "state dir: $STATE (mode 700; holds ALL private keys)"
log "evidence:  $RUN"

cleanup() {
  podman rm -f "$C_ROUTER" "$C_HOST" "$C_MANAGER" "$C_A" "$C_B" >/dev/null 2>&1
  podman network rm "$NET" >/dev/null 2>&1
  rm -rf "$STATE"
}
# On failure, leave the stack and state dir in place for live inspection.
trap 'if [ "$FAIL" = 0 ]; then cleanup; else
  log "FAILURES — stack left running for inspection:"
  log "  state: $STATE"
  log "  pods:  podman exec $C_A|${C_B}|$C_HOST|$C_MANAGER|$C_ROUTER ..."
fi' EXIT

wait_fresh_wg() { # container [budget_secs] — any peer with a handshake <90s old
  local c=$1 budget=${2:-90} hs now
  local end=$((SECONDS + budget))
  while [ "$SECONDS" -lt "$end" ]; do
    hs=$(podman exec "$c" wg show wg0 dump 2>/dev/null | awk 'NR>1 && $5>m {m=$5} END{print m+0}')
    now=$(date +%s)
    [ "${hs:-0}" -gt $((now - 90)) ] && return 0
    sleep 2
  done
  return 1
}

probe() { # container dst port expect(ok|fail) label
  local c=$1 dst=$2 port=$3 expect=$4 label=$5
  local out rc tries=0
  while :; do
    out=$(podman exec "$c" nc -w 3 "$dst" "$port" 2>&1)
    rc=$?
    tries=$((tries+1))
    [ "$expect" = ok ] && [ $rc -ne 0 ] && [ $tries -lt 3 ] && { sleep 1; continue; }
    break
  done
  if [ "$expect" = ok ]; then
    if [ $rc -eq 0 ] && [ -n "$out" ]; then ok "$label (got: $out)"
    else bad "$label — expected success, rc=$rc out='$out'"; fi
  else
    if [ $rc -ne 0 ] || [ -z "$out" ]; then ok "$label (rc=$rc)"
    else bad "$label — expected failure but got: $out"; fi
  fi
}

snapshot_router() { # out_prefix — identity fields only (stable across rolls)
  local p=$1
  podman exec "$C_ROUTER" wg show wg0 public-key   > "$p.pubkey"  2>&1
  podman exec "$C_ROUTER" ip -4 addr show wg0      > "$p.addr"   2>&1
  podman exec "$C_ROUTER" wg show wg0 dump | awk '{print $1, $4}' | sort > "$p.peers" 2>&1
  podman exec "$C_ROUTER" iptables-save | sed 's/^\[[0-9:]*\] //' > "$p.iptables" 2>&1
}

# ---------------------------------------------------------------- 1. build
hdr "1. build Router + node images"
runlog podman build -q -t localhost/neoclaw-router:test -f router/Containerfile router/ \
  && ok "router image built" || bad "router image build"
runlog podman build -q -t localhost/neoclaw-node:test -f test/slice/network/Containerfile.node test/slice/network \
  && ok "node image built" || bad "node image build"

# ------------------------------------------------------- 2. manager state
hdr "2. Manager creates the network (desired state)"
CLI="ruby -I app/services bin/neoclaw-network"
runlog ruby -I app/services bin/neoclaw-network init "$STATE" \
    --router-endpoint "$IP_ROUTER:51820" \
    --host-endpoint "$IP_HOST:51820" \
    --manager-endpoint "$IP_MANAGER:51820" \
  && ok "state initialized" || bad "state init"
runlog $CLI add-service "$STATE" svc-matrix --host 10.0.0.2 --port 443 \
  && ok "service svc-matrix:443" || bad "add-service matrix"
runlog $CLI add-service "$STATE" svc-admin --host 10.0.0.2 --port 22 \
  && ok "service svc-admin:22" || bad "add-service admin"
runlog $CLI add-service "$STATE" svc-alt --host 10.0.0.2 --port 8448 \
  && ok "service svc-alt:8448" || bad "add-service alt"
runlog $CLI add-agent "$STATE" test1 --endpoint "$IP_AGENT_A:51820" \
  && ok "agent test1" || bad "add-agent test1"
runlog $CLI add-agent "$STATE" test2 --endpoint "$IP_AGENT_B:51820" \
  && ok "agent test2" || bad "add-agent test2"
runlog $CLI authorize "$STATE" test1 svc-matrix \
  && runlog $CLI authorize "$STATE" test2 svc-alt \
  && ok "authorizations recorded" || bad "authorizations"
runlog $CLI show "$STATE" | tee "$RUN/state-show.txt" >/dev/null && ok "state summary" || bad "state show"
ROUTER_PUB_EXPECTED=$($CLI router-public "$STATE")
log "Manager-held Router public key: $ROUTER_PUB_EXPECTED"

# ------------------------------------------------------------- 3. network
hdr "3. disposable podman network + Router"
# Belts and braces: a previous interrupted run must not poison this one.
podman rm -f "$C_ROUTER" "$C_HOST" "$C_MANAGER" "$C_A" "$C_B" >/dev/null 2>&1
podman network rm "$NET" >/dev/null 2>&1 || true
runlog podman network create --subnet "$SUBNET" "$NET" && ok "network $NET created" || bad "network create"

CONF_A="$STATE/router-render-a"
runlog $CLI render-router "$STATE" "$CONF_A" && ok "router config rendered" || bad "render-router"
cp "$CONF_A/network.json" "$RUN/network.json.roll1"

runlog podman run -d --name "$C_ROUTER" --network "$NET" --ip "$IP_ROUTER" \
    --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1 \
    -v "$CONF_A:/etc/neoclaw:ro" \
    localhost/neoclaw-router:test \
  && ok "router container running" || bad "router run"
sleep 3
podman logs "$C_ROUTER" | tee -a "$LOG"

# ------------------------------------------------- 4. host + manager + pods
hdr "4. host, Manager, and agent pods (WG configs rendered by Manager)"

node_up() { # container_name ip conf_file role_script [rw]
  local c=$1 ip=$2 conf=$3 role=$4 rw=${5:-ro}
  mkdir -p "$STATE/node-$c"
  cp "$conf" "$STATE/node-$c/wg0.conf"
  printf '%s\n' "$role" > "$STATE/node-$c/role.sh"
  cat > "$STATE/node-$c/serve.sh" <<'EOS'
#!/bin/sh
# -e hook: runs per accepted connection, socket on stdio. The accept
# timestamp is the server-side truth of "traffic actually flowed".
echo "$(date +%s%N) accept $1" >> /etc/wg/accepts.log
echo "host:$1-ok"
EOS
  chmod 600 "$STATE/node-$c/wg0.conf"
  cat > "$STATE/node-$c/init.sh" <<'EOS'
#!/bin/sh
# wg-quick can lose a race with container netns setup on first boot; retry.
n=0
until wg-quick up /etc/wg/wg0.conf 2>/tmp/wg-quick.err; do
    n=$((n+1))
    [ "$n" -ge 5 ] && { cat /tmp/wg-quick.err; echo "[node] FATAL: wg never came up"; exit 1; }
    sleep 2
done
echo "[node] wg0 up, pubkey: $(wg show wg0 public-key)"
exec sh /etc/wg/role.sh
EOS
  chmod +x "$STATE/node-$c/init.sh" "$STATE/node-$c/serve.sh"
  podman run -d --name "$c" --network "$NET" --ip "$ip" \
    --cap-add NET_ADMIN \
    -v "$STATE/node-$c:/etc/wg:$rw" \
    localhost/neoclaw-node:test /etc/wg/init.sh >/dev/null 2>&1
}

ROLE_HOST=$(cat <<'EOS'
#!/bin/sh
for p in 443:matrix 22:admin 8448:alt; do
  port=${p%%:*}; name=${p##*:}
  ( while :; do nc -l -p "$port" -w 60 -e /etc/wg/serve.sh "$name" 2>/dev/null; done ) &
done
echo "[host] listeners on 443 22 8448 (accepts timestamped to /etc/wg/accepts.log)"
wait
EOS
)
ROLE_IDLE='#!/bin/sh
sleep infinity'

node_up "$C_HOST" "$IP_HOST" <($CLI host-config "$STATE") "$ROLE_HOST" rw && ok "host container up" || bad "host up"
node_up "$C_MANAGER" "$IP_MANAGER" <($CLI manager-config "$STATE") "$ROLE_IDLE" && ok "manager container up" || bad "manager up"
node_up "$C_A" "$IP_AGENT_A" <($CLI agent-config "$STATE" test1) "$ROLE_IDLE" && ok "agent-a (test1) up" || bad "agent-a up"
node_up "$C_B" "$IP_AGENT_B" <($CLI agent-config "$STATE" test2) "$ROLE_IDLE" && ok "agent-b (test2) up" || bad "agent-b up"

AGENT_CONF_A_HASH_BEFORE=$(sha256sum "$STATE/node-$C_A/wg0.conf" | awk '{print $1}')
log "agent-a wg config sha256 (before): $AGENT_CONF_A_HASH_BEFORE"

hdr "4b. WG handshakes"
wait_fresh_wg "$C_A"    && ok "agent-a handshake with Router" || bad "agent-a handshake"
wait_fresh_wg "$C_B"    && ok "agent-b handshake with Router" || bad "agent-b handshake"
wait_fresh_wg "$C_HOST" && ok "host handshake with Router" || bad "host handshake"
wait_fresh_wg "$C_MANAGER" && ok "manager handshake with host" || bad "manager handshake"

hdr "4c. pairing assertions (§2.2)"
# Every pod's ONLY [Peer] is the Router; host peers with Router+Manager.
for c in "$C_A" "$C_B"; do
  n=$(podman exec "$c" sh -c 'grep -c "^\[Peer\]" /etc/wg/wg0.conf')
  [ "$n" = "1" ] && ok "$c has exactly one WG peer" || bad "$c peer count = $n (expected 1)"
  podman exec "$c" sh -c 'grep -A2 "^\[Peer\]" /etc/wg/wg0.conf' | grep -q "$ROUTER_PUB_EXPECTED" \
    && ok "$c peers with the Router pubkey" || bad "$c does not peer with Router"
done
podman exec "$C_HOST" sh -c 'grep -c "^\[Peer\]" /etc/wg/wg0.conf' | grep -q 2 \
  && ok "host peers with Router and Manager" || bad "host peer count != 2"
podman exec "$C_ROUTER" wg show wg0 dump | awk '{print $1}' | grep -q . \
  && ok "Router has a peer set" || bad "Router has no peers"

# ------------------------------------------------- 5. authorization matrix
hdr "5. authorization matrix (§2.3–2.6)"
probe "$C_A" 10.0.0.2 443  ok   "§2.3 authorized: test1 -> host:443 (its service)"
probe "$C_A" 10.0.0.2 22   fail "§2.4 unauthorized port: test1 -> host:22"
probe "$C_A" 10.0.0.2 8448 fail "§2.4 unauthorized port: test1 -> host:8448"
probe "$C_B" 10.0.0.2 8448 ok   "§2.3 authorized: test2 -> host:8448 (its service)"
probe "$C_B" 10.0.0.2 443 fail "§2.5 unauthorized source: test2 -> host:443"

# Manager identity: it pairs DIRECTLY with the host (topology §2.2), so its
# traffic never crosses the Router. Port policy on that control channel is
# host-side, out of Router scope — assert the pairing topology instead:
# manager<->host flows must move bytes on the HOST's manager peer and zero
# on the Router's manager peer.
MANAGER_PUB=$(podman exec "$C_HOST" sh -c 'grep PublicKey /etc/wg/wg0.conf | sed -n 2p' | awk '{print $3}')
HDRX_BEFORE=$(podman exec "$C_HOST" wg show wg0 dump | awk -v p="$MANAGER_PUB" 'index($0,p){print $6,$7}')
URX_BEFORE=$(podman exec "$C_ROUTER" wg show wg0 dump | awk -v p="$MANAGER_PUB" 'index($0,p){print $6}')
probe "$C_MANAGER" 10.0.0.2 22 ok "manager -> host:22 (direct manager<->host pairing)"
probe "$C_MANAGER" 10.0.0.2 443 ok "manager -> host:443 (direct pairing; port policy is host-side, not Router scope)"
HDRX_AFTER=$(podman exec "$C_HOST" wg show wg0 dump | awk -v p="$MANAGER_PUB" 'index($0,p){print $6,$7}')
URX_AFTER=$(podman exec "$C_ROUTER" wg show wg0 dump | awk -v p="$MANAGER_PUB" 'index($0,p){print $6}')
[ "$HDRX_BEFORE" != "$HDRX_AFTER" ] \
  && ok "manager traffic moved on the HOST's manager peer ($HDRX_BEFORE -> $HDRX_AFTER)" \
  || bad "host manager-peer counters did not move ($HDRX_BEFORE)"
[ "$URX_BEFORE" = "$URX_AFTER" ] \
  && ok "manager traffic did NOT traverse the Router (router-side rx constant at $URX_AFTER)" \
  || bad "router rx for manager peer changed: $URX_BEFORE -> $URX_AFTER"

# Agent-to-agent: pod-side (AllowedIPs excludes peers) — packets must not
# even enter the tunnel.
podman exec "$C_A" ip route add 10.1.0.0/16 dev wg0 2>/dev/null || true
out=$(podman exec "$C_A" nc -w 3 10.1.0.2 443 2>&1); rc=$?
[ $rc -ne 0 ] && ok "§2.5 agent-to-agent: test1 -> test2 has no path (rc=$rc)" \
              || bad "§2.5 agent-to-agent unexpectedly reachable: $out"

# Source-IP binding (§2.6): test1 attempts to speak as test2. Source is
# forced by a src-route; WireGuard on the Router must drop packets whose
# inner source is not the sending peer's allowed-ip.
hdr "5b. source-IP binding (§2.6)"
TEST2_PUB=$($CLI show "$STATE" | awk '/agent test2/{print $NF}')
RX_BEFORE=$(podman exec "$C_ROUTER" wg show wg0 dump | awk -v p="$TEST2_PUB" 'index($0,p){print $6}')
podman exec "$C_A" ip addr add 10.1.0.2/32 dev wg0 2>/dev/null || true
podman exec "$C_A" sh -c 'ip route replace 10.0.0.2/32 dev wg0 src 10.1.0.2 2>/dev/null; true'
out=$(podman exec "$C_A" nc -w 3 10.0.0.2 8448 2>&1); rc=$?
[ $rc -ne 0 ] && ok "spoofed source rejected: test1 speaking as 10.1.0.2 (test2) — path denied (rc=$rc)" \
              || bad "spoofed source worked: $out"
sleep 2
RX_AFTER=$(podman exec "$C_ROUTER" wg show wg0 dump | awk -v p="$TEST2_PUB" 'index($0,p){print $6}')
[ "$RX_BEFORE" = "$RX_AFTER" ] \
  && ok "Router received zero spoofed packets on test2's peer (rx $RX_BEFORE -> $RX_AFTER)" \
  || bad "Router rx for test2 changed: $RX_BEFORE -> $RX_AFTER"
podman exec "$C_A" ip addr del 10.1.0.2/32 dev wg0 2>/dev/null || true
# Restore the route we borrowed for the spoof attempt — without this the
# src-route lingers and every later probe from agent-a is source-spoofed.
podman exec "$C_A" ip route replace 10.0.0.2/32 dev wg0 src 10.1.0.1 2>/dev/null || true
podman exec "$C_ROUTER" iptables -L NEOCLAW_FWD -v -n | tee "$RUN/iptables-fwd.txt" >/dev/null

# ------------------------------------------- 6. no API / registry / state
hdr "6. Router inspection: no control plane (§2.7)"
LISTEN=$(podman exec "$C_ROUTER" sh -c 'netstat -lntup 2>/dev/null || true')
echo "$LISTEN" | tee -a "$LOG"
if echo "$LISTEN" | grep -Eq '^tcp.*LISTEN'; then
  bad "unexpected TCP listener on Router"
else
  ok "no TCP listener on the Router"
fi
podman exec "$C_ROUTER" sh -c 'ls /' | tee -a "$LOG"
podman exec "$C_ROUTER" sh -c 'test ! -e /data && echo "no /data state dir"' | tee -a "$LOG" \
  && ok "no persistent state directory" || bad "state dir exists"
podman exec "$C_ROUTER" sh -c 'test ! -e /opt/router/src && echo "no Ruby application"' | tee -a "$LOG" \
  && ok "no Ruby application present" || bad "old router code present"
podman exec "$C_ROUTER" sh -c 'ps -o pid,args | grep -v grep' | tee -a "$LOG"

# ------------------------------------------------------ 7. router roll
hdr "7. Router replacement from desired state (§2.8–2.9)"
snap1="$RUN/snapshot-roll1"
snapshot_router "$snap1"
log "roll1 pubkey: $(cat "$snap1.pubkey")"
log "roll1 peers (pubkey allowed-ips):"
cat "$snap1.peers" | tee -a "$LOG"

CONF_B="$STATE/router-render-b"
$CLI render-router "$STATE" "$CONF_B" >/dev/null
cp "$CONF_B/network.json" "$RUN/network.json.roll2"
diff -u "$RUN/network.json.roll1" "$RUN/network.json.roll2" && ok "rendered config identical across rolls" || bad "render differed"

podman rm -f "$C_ROUTER" >/dev/null 2>&1
runlog podman run -d --name "$C_ROUTER" --network "$NET" --ip "$IP_ROUTER" \
    --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1 \
    -v "$CONF_B:/etc/neoclaw:ro" \
    localhost/neoclaw-router:test \
  && ok "replacement router running" || bad "replacement router run"
sleep 3
podman logs "$C_ROUTER" | tee -a "$LOG"

# A replaced Router holds no session state, so it initiates fresh sessions
# itself (entrypoint warm-up) instead of waiting for peer rekey timers.
# Manager-side wake pings (out of band, podman exec) cover the same from
# the pod direction. Require a FRESH handshake so stale state can't fake
# this check.
hdr "7b. session re-establishment after roll (Router-initiated warm-up)"
wait_fresh_wg "$C_A" 240 && ok "agent-a re-handshaken after roll (fresh handshake)" \
                     || bad "agent-a did not re-handshake within 240s"
wait_fresh_wg "$C_HOST" 240 && ok "host re-handshaken after roll (fresh handshake)" \
                        || bad "host did not re-handshake within 240s"

snap2="$RUN/snapshot-roll2"
snapshot_router "$snap2"
[ "$(cat "$snap1.pubkey")" = "$(cat "$snap2.pubkey")" ] \
  && ok "§2.9 Router public key unchanged across rolls" || bad "Router pubkey changed"
[ "$(cat "$snap1.pubkey")" = "$ROUTER_PUB_EXPECTED" ] \
  && ok "Router public key matches Manager-held key" || bad "Router pubkey != Manager-held key"
diff -u "$snap1.addr" "$snap2.addr" && ok "§2.9 Router IP unchanged across rolls" || bad "Router IP changed"
diff -u "$snap1.peers" "$snap2.peers" && ok "§2.9 peer set unchanged across rolls" || bad "peer set changed"
diff -u "$snap1.iptables" "$snap2.iptables" | grep -v '^[+-]:' \
  && ok "iptables policy identical across rolls" || bad "iptables policy changed"

AGENT_CONF_A_HASH_AFTER=$(sha256sum "$STATE/node-$C_A/wg0.conf" | awk '{print $1}')
[ "$AGENT_CONF_A_HASH_BEFORE" = "$AGENT_CONF_A_HASH_AFTER" ] \
  && ok "§2.9 agent-a WG config untouched by the roll" || bad "agent-a config changed"

# --------------------------------------- 7c. repeated rolls, hard <=2s gate
# Evans' requirement: worst-case interruption across a roll <= 2 seconds.
# Continuous authorized traffic flows from agent-a (3 staggered streams)
# for the whole phase; the host timestamps every accepted connection.
# Interruption per roll is measured server-side: first accept after roll
# start minus last accept before it. Assertion is on the WORST roll, not
# the average. Traffic verification is real (application accepts), not
# `wg show`.
hdr "7c. repeated rolls under continuous traffic (worst case <= 2.0s)"
TPIDS=""
for s in 0 0.06 0.13; do
  sleep "$s"
  podman exec "$C_A" sh -c 'while :; do printf "\n" | nc -w 1 10.0.0.2 443 >/dev/null 2>&1; done' &
  TPIDS="$TPIDS $!"
done
sleep 1   # settle: accept log has pre-roll traffic

gate_roll() { # roll_index
  local i=$1
  local conf="$STATE/router-render-roll$i"
  $CLI render-router "$STATE" "$conf" >/dev/null
  local t0 tstart tend
  t0=$(date +%s%N)
  podman rm -f "$C_ROUTER" >/dev/null 2>&1
  podman run -d --name "$C_ROUTER" --network "$NET" --ip "$IP_ROUTER" \
    --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1 \
    -v "$conf:/etc/neoclaw:ro" \
    localhost/neoclaw-router:test >/dev/null
  tstart=$(date +%s%N)
  # Manager-side out-of-band wake: pods initiate sessions too. The ICMP
  # echo itself is policy-dropped at the Router's FORWARD chain; the
  # handshake the ping triggers is the point.
  local wake_pids=""
  podman exec "$C_A" sh -c 'ping -c1 -W1 10.0.0.2 >/dev/null 2>&1 || true' & wake_pids="$wake_pids $!"
  podman exec "$C_B" sh -c 'ping -c1 -W1 10.0.0.2 >/dev/null 2>&1 || true' & wake_pids="$wake_pids $!"
  wait $wake_pids
  sleep 2.2   # let post-recovery accepts land in the log
  tend=$(date +%s%N)
  local result rc
  result=$(awk -v t0="$t0" -v tend="$tend" '
    $1 >= t0-10000000000 {
      if ($1 < t0) { if ($1 > lastb) lastb=$1 }
      else if (firsta == 0 && $1 <= tend) { firsta=$1 }
    }
    END {
      if (lastb == 0 || firsta == 0) { printf "NOMEASURE(lastb=%d,firsta=%d)", lastb, firsta+0; exit 1 }
      printf "%.3f", (firsta-lastb)/1000000000
    }' "$STATE/node-$C_HOST/accepts.log")
  rc=$?
  log "roll $i: container swap $(( (tstart-t0)/1000000 ))ms; observed interruption ${result}s (server-side accepts)"
  if [ $rc -eq 0 ]; then
    awk -v r="$result" 'BEGIN{exit !(r<=2.0)}' \
      && ok "roll $i: interruption ${result}s <= 2.0s worst-case gate" \
      || bad "roll $i: interruption ${result}s EXCEEDS 2.0s worst-case gate"
  else
    bad "roll $i: traffic did not resume ($result)"
  fi
}

for i in 2 3 4 5; do gate_roll "$i"; done
kill $TPIDS 2>/dev/null || true
[ "$(podman exec "$C_ROUTER" wg show wg0 public-key)" = "$ROUTER_PUB_EXPECTED" ] \
  && ok "after roll 5: Router public key still matches Manager-held key" \
  || bad "Router pubkey drifted across repeated rolls"

# ------------------------------------------------- 8. re-run packet tests
hdr "8. packet tests repeated after roll (§2.10)"
{
  echo "--- agent-a wg/ip state post-roll"
  podman exec "$C_A" sh -c 'wg show wg0; ip -4 addr show wg0; ip route; ip neigh show 10.99.1.10' 2>&1
  echo "--- router wg dump post-roll"
  podman exec "$C_ROUTER" wg show wg0 dump 2>&1
  echo "--- router forward-chain counters post-roll"
  podman exec "$C_ROUTER" iptables -L NEOCLAW_FWD -v -n 2>&1
} | tee "$RUN/post-roll-diagnostics.txt" >> "$LOG"
probe "$C_A" 10.0.0.2 443  ok   "post-roll authorized: test1 -> host:443"
probe "$C_A" 10.0.0.2 8448 fail "post-roll unauthorized port: test1 -> host:8448"
probe "$C_B" 10.0.0.2 443 fail "post-roll unauthorized source: test2 -> host:443"
probe "$C_MANAGER" 10.0.0.2 22 ok "post-roll manager -> host:22 (direct pairing unaffected)"

# ------------------------------------------------------------- verdict
hdr "verdict"
log "PASS=$PASS FAIL=$FAIL"
log "evidence preserved at: $RUN"
[ "$FAIL" = 0 ]
