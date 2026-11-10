# Babo in a pod — the office control plane

Babo runs as a mesh service peer, not as a host process: its own network
namespace, its own WireGuard identity (`10.0.0.5`), no podman socket, no
writable host paths, no published port. The host reaches its UI over the
mesh; the Router admits only the host's WG address (`10.0.0.2`) to the UI
port, and Babo may reach only the Manager API (`10.0.0.3:9200`).

The exact boundaries of this slice are in the commission thread:
`the-townline/requests/2026-11-10-from-nime-to-dova-soro-babo-office-control-plane.md`,
section "Munu's slice — interface and file boundaries".

## What the Manager does for it (not this directory's code)

On each boot the Manager renders `$HOST_SPAWN_DIR/runtime/babo/` — a fresh
keypair and `wg0.conf` for `10.0.0.5` — and then launches this image:

```
podman run -d --name neoclaw-babo --cap-add NET_ADMIN \
  -v $HOST_SPAWN_DIR/runtime/babo:/etc/wireguard:ro,Z \
  -e BABO_PORT=8843 \
  -e NEOCLAW_MANAGER_URL=http://10.0.0.3:9200 \
  -e NEOCLAW_OFFICE_BACKEND=manager \
  localhost/neoclaw-babo:latest
```

That is the **only** mount, it is **read-only**, and its source is the boot
runtime directory. `NET_ADMIN` is scoped to the container's own network
namespace, for its own `wg0` — the same privilege the Hub has. There is no
`--network host`, no `-p`, and no `docker.sock`/`podman.sock`.

## Facts the packaging check must hold it to

1. The image contains no WireGuard private key and no WireGuard config.
2. Exactly one bind mount at run time: read-only, source under
   `$HOST_SPAWN_DIR/runtime/babo`, target `/etc/wireguard`. Any other mount is
   a failure.
3. No published port; no `--network host`.
4. The effective listener is the WG address: a probe from the host WG address
   gets `200`, a loopback probe is refused, and an off-source probe is refused
   by the Router. (`babo webui` has no `--host`; the bind comes from
   `config.gateway.host`, which `entrypoint.sh` renders into a runtime config
   and passes with `--config`.)
5. `NEOCLAW_MANAGER_URL` has no loopback default (the code's default is
   `http://10.0.0.3:9200`). The image vendors a web UI with legitimate
   loopback use elsewhere, so the claim is about the Manager URL and the
   effective listener, not about a grep for `127.0.0.1`.
6. The image ships a built UI: `babo/web/dist` is produced in a frontend stage
   (`bun install --frozen-lockfile && bun run build`), because the source tree
   does not ship the bundle.

## Deliberate non-goals

No public listener, no password or token path, no activation or onboarding
code, no credential handling, no pod operation. Those live in the Manager and
the Router, which this slice does not modify.
