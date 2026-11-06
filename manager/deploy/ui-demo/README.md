# NeoClaw Manager UI demo

Runs the existing Manager UI in an isolated pod on z620. This is a
demonstration only: no Router, Hub, reconciliation, cron scheduler, watchdog,
WireGuard setup, host podman socket, resident pod, production database, or
production WireGuard/firewall state is touched.

## Build

From the `manager/` directory on the demo branch:

```sh
sudo podman build --network=host -f Containerfile.ui-demo \
  -t localhost/neoclaw-ui-demo:latest .
```

The image uses `NEOCLAW_UI_DEMO=1`, which skips Surface's production mount
assertions and all three background initializers. Puma is the only long-running
application process. Its SQLite database is disposable demo state.

## Run

Create `/var/lib/neoclaw/ui-demo/ui-demo.env` mode `0600` with a locally
generated `SECRET_KEY_BASE`, install `neoclaw-ui-demo.service`, then enable and
start it. The unit mounts only `/var/lib/neoclaw/ui-demo/data` and binds Rails
to `127.0.0.1:9200` on the host. `--network host` avoids z620's unrelated
Podman DNS issue without granting any additional capability.

Install `dnsmasq.conf` as `/etc/dnsmasq.d/neoclaw-ui-demo.conf` and
`caddy.conf` as `/etc/caddy/conf.d/neoclaw-ui-demo.conf`, import the latter
from the main Caddyfile, then reload dnsmasq and Caddy. The resulting door is:

    http://neoclaw.home/

The name resolves only to the house mesh address `100.64.0.1`; this is not a
public service or a new public door. Keep the Caddyfile's existing backup and
remove the import and two config files to retire the demo.
