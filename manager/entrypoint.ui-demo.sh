#!/bin/bash
set -euo pipefail

# UI-only demonstration. No Router, Hub, reconciliation, scheduler, watchdog,
# or host podman socket is started or required.
export RAILS_ENV=production
export NEOCLAW_UI_DEMO=1
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')}"

mkdir -p /data
if [ ! -f /data/manager_production.sqlite3 ]; then
  echo "[ui-demo] initializing disposable database..."
  bin/rails db:schema:load
  bin/rails db:seed
else
  bin/rails db:migrate
fi

echo "[ui-demo] starting Manager UI on ${BIND_ADDR:-127.0.0.1}:${PORT:-19200}"
exec bin/rails server -b "${BIND_ADDR:-127.0.0.1}" -p "${PORT:-19200}" -e production
