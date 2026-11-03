#!/bin/bash
# NeoClaw test agent pod entrypoint: WG (optional) -> kimi web -> Matrix listener
set -u
mkdir -p /pod/logs /pod/kimi-home /pod/creds

# 0) Optional WireGuard peering to the test Router (config supplied by Manager)
if [ -f /pod/wg/pod.conf ]; then
  cp /pod/wg/pod.conf /etc/wireguard/wg0.conf
  wg-quick up wg0
  echo "wg0 up: $(wg show wg0 public-key)" | tee /pod/logs/wg.log
fi

# 1) kimi web server (stock Kimi Code local server)
cd /pod/workspace
: > /pod/logs/kimi-web.log
nohup kimi web --port 58999 --host 127.0.0.1 --no-open --log-level info > /pod/logs/kimi-web.log 2>&1 &
echo $! > /pod/logs/kimi-web.pid
for i in $(seq 1 45); do
  grep -qE "(#token=[A-Za-z0-9_-]+|^  Token:)" /pod/logs/kimi-web.log && break
  sleep 1
done
TOK=$(grep -oE "#token=[A-Za-z0-9_-]+" /pod/logs/kimi-web.log | head -1 | cut -d= -f2)
if [ -z "$TOK" ]; then
  TOK=$(awk "/^  Token:/{print \$2; exit}" /pod/logs/kimi-web.log)
fi
echo "$TOK" > /pod/logs/kimi-web.token
echo "kimi web up, token length ${#TOK}" | tee /pod/logs/boot.log

# 2) Matrix listener + responder (stock Matrix client library, matrix-nio)
exec python3 /pod/listener.py
