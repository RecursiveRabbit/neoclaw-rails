#!/usr/bin/env bash
set -euo pipefail

ROUTER_CFG="${ROUTER_CFG:-/home/rook/.openclaw/workspace/neoclaw-rails-spec/router/config/config.yml}"
WG_HOST_IF="${WG_HOST_IF:-nc-host}"
MANAGER_CONTAINER="${MANAGER_CONTAINER:-neoclaw-manager}"
ROUTER_CONTAINER="${ROUTER_CONTAINER:-wg-router}"
MANAGER_WG_CONF="${MANAGER_WG_CONF:-/var/lib/neoclaw/manager-wg/wg0.conf}"
FIX=0
[[ "${1:-}" == "--fix" ]] && FIX=1

need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 2; }; }
need awk; need wg; need podman

[[ -f "$ROUTER_CFG" ]] || { echo "missing router cfg: $ROUTER_CFG" >&2; exit 2; }

cfg_peer_key(){
  local peer="$1"
  awk -v p="$peer" '
    $1=="peers:" {inpeers=1; next}
    inpeers && $1==p":" {target=1; next}
    target && $1=="pubkey:" {print $2; exit}
    target && $1 ~ /^[a-zA-Z0-9_-]+:$/ {target=0}
  ' "$ROUTER_CFG"
}

cfg_host_key="$(cfg_peer_key host || true)"
cfg_mgr_key="$(cfg_peer_key manager || true)"

host_key="$(wg show "$WG_HOST_IF" public-key 2>/dev/null || sudo -n wg show "$WG_HOST_IF" public-key 2>/dev/null || true)"
mgr_key="$(podman exec "$MANAGER_CONTAINER" wg show wg0 public-key 2>/dev/null || true)"
if [[ -z "$mgr_key" && -f "$MANAGER_WG_CONF" ]]; then
  mgr_priv="$(awk -F= '/^PrivateKey/{gsub(/ /,"",$2);print $2;exit}' "$MANAGER_WG_CONF")"
  [[ -n "$mgr_priv" ]] && mgr_key="$(printf '%s' "$mgr_priv" | wg pubkey 2>/dev/null || true)"
fi

echo "cfg.host=$cfg_host_key"
echo "live.host=$host_key"
echo "cfg.manager=$cfg_mgr_key"
echo "live.manager=$mgr_key"

ok=0
[[ -n "$cfg_host_key" && "$cfg_host_key" == "$host_key" ]] || ok=1
[[ -n "$cfg_mgr_key" && "$cfg_mgr_key" == "$mgr_key" ]] || ok=1

if [[ $ok -eq 0 ]]; then
  echo "OK: no WG key drift"
  exit 0
fi

echo "DRIFT: mismatch detected" >&2
[[ $FIX -eq 1 ]] || exit 1

python3 - <<PY
from pathlib import Path
p=Path('$ROUTER_CFG')
lines=p.read_text().splitlines()
peer=None
for i,l in enumerate(lines):
    s=l.strip()
    if s=='host:': peer='host'; continue
    if s=='manager:': peer='manager'; continue
    if peer and s.startswith('pubkey:'):
        if peer=='host':
            lines[i]='    pubkey: $host_key'
        elif peer=='manager':
            lines[i]='    pubkey: $mgr_key'
        peer=None
p.write_text('\n'.join(lines)+'\n')
print('router config updated')
PY

podman restart "$ROUTER_CONTAINER" >/dev/null

echo "FIXED: router restarted with current host/manager pubkeys"
