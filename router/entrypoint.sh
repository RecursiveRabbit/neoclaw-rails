#!/bin/sh

echo "[entrypoint] WG-Router starting"

# IP forwarding — required for routing between WG peers and to internet.
# Prefer --sysctl net.ipv4.ip_forward=1 on container run.
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
fwd=$(cat /proc/sys/net/ipv4/ip_forward)
echo "[entrypoint] ip_forward = ${fwd}"
if [ "$fwd" != "1" ]; then
  echo "[entrypoint] FATAL: ip_forward not enabled. Run with --sysctl net.ipv4.ip_forward=1"
  exit 1
fi

# Ensure log and data directories exist
mkdir -p /var/log
mkdir -p /data

exec ruby /opt/router/src/router.rb
