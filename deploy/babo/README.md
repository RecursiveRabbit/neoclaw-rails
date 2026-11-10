# Babo in a pod — the office control plane

Babo runs as a mesh service peer, not as a host process: its own network
namespace, its own WireGuard identity (`10.0.0.5`), no container-runtime
socket, no writable host path, no published port. The host reaches its UI over
the mesh; the Router admits only the host's WG address (`10.0.0.2`) to the UI
port, and Babo may reach only the Manager API (`10.0.0.3:9200`).

The exact boundaries of this slice are in the commission thread:
`the-townline/requests/2026-11-10-from-nime-to-dova-soro-babo-office-control-plane.md`,
sections "Munu's slice — interface and file boundaries" and "Handoff for the
Babo-in-pod slice".

**Files in this slice:** `Containerfile` (which contains the entrypoint),
`README.md`, and `test/proof/babo_packaging_check.sh`. The entrypoint is not a
separate file because the build context is the Babo source root and `COPY`
cannot reach outside it — one artifact, no staged context, no second copy to
drift.
Everything the pod touches on the host side (mount rendering, caps, the launch
line, the Router rule) belongs to the Manager's lane, not here.

## Build

The build context is the **Babo source tree** (the office slice), not this
directory:

```
podman build -t localhost/neoclaw-babo:latest -f deploy/babo/Containerfile <babo-src>
```

The Containerfile embeds the entrypoint with a heredoc `RUN`, so the build
needs a modern builder (podman ≥ 4.6 / buildah ≥ 1.31). If a builder without
heredoc support is ever required, the honest fallback is a staged context
(`deploy/` + Babo source in one directory) with the README's build line changed
to name it — not a silent `COPY` that cannot resolve.

Two stages: a `oven/bun:1.2-slim` stage builds `webui/` and emits
`babo/web/dist` (`bun install --frozen-lockfile && bun run build`); the
`python:3.12-slim` runtime stage installs Babo with that bundle in place. The
image therefore builds from source and does not depend on a `dist` artifact
living anywhere outside it.

## How the Manager launches it (excerpt, from `manager/entrypoint.sh` Phase 6.5 @ `ed1f6eb`)

**This is an excerpt, not a whole quotation.** The `podman run` invocation and
its guard are copied verbatim from the Manager's source; the surrounding
control flow is elided and named below rather than trimmed away silently. If
this block and `manager/entrypoint.sh` ever disagree, the Manager wins and this
README is wrong until it is re-copied.

```bash
BABO_IMAGE="${BABO_IMAGE:-localhost/neoclaw-babo:latest}"
BABO_PORT="${BABO_PORT:-8843}"

if $PODMAN image exists "$BABO_IMAGE" 2>/dev/null; then
    BABO_ID=$($PODMAN run -d \
        --name neoclaw-babo \
        --hostname neoclaw-babo \
        --cap-add NET_ADMIN \
        -v "${HOST_RUNTIME}/babo:/etc/wireguard:ro,Z" \
        -e "BABO_PORT=${BABO_PORT}" \
        -e "NEOCLAW_MANAGER_URL=${NEOCLAW_MANAGER_URL:-http://10.0.0.3:9200}" \
        -e "NEOCLAW_OFFICE_BACKEND=manager" \
        "$BABO_IMAGE" 2>&1)
fi
```

Elided from the excerpt, named so nothing goes missing quietly: the start log
line (`log "starting Babo office UI …"`), the health branch after start
(`if [ $? -eq 0 ] … else … WARNING …`, the warn-not-fatal probe described
below), and the outer `else` that logs "Babo image absent …" when the image is
not present.

What that means, as source rather than assumption:

- `HOST_RUNTIME` is `${HOST_SPAWN_DIR:-/spawn}/runtime` — a **host** path, used
  because the pod is created through the host's podman socket. The mounted
  directory is `${HOST_SPAWN_DIR}/runtime/babo` and holds `private.key` and
  `wg0.conf`, rendered that boot, mode `0600`.
- **One mount only**, read-only, `:ro,Z`, target `/etc/wireguard`. No `-p`, no
  `--network host`, no socket mount, no other volumes.
- **`NET_ADMIN` only.** `--sysctl ip_forward` is *not* set for Babo: it does
  not route traffic.
- The Manager's own health probe after start is
  `http://10.0.0.5:${BABO_PORT}/health`, 20 tries × 2 s, **warn-not-fatal**.
- Startup is **skipped when the image is absent**, so a Manager without Babo
  still boots. A container that is not running is therefore not automatically a
  fault.
- The Manager **removes `neoclaw-babo`** in its clean-slate phase before
  starting a new one.

`BABO_IMAGE`, `BABO_PORT` and `NEOCLAW_MANAGER_URL` come from the Manager's
environment. They are **as launched by this Manager boot**, not fixed at build
time: the image's `ENV` lines are defaults for a manual run, and the check must
read the running container's environment, not the image's, if it wants to make
a claim about them.

## What the entrypoint does, and the deviations it records

1. Refuses to start without a mounted `/etc/wireguard/wg0.conf`.
2. `wg-quick up wg0`, then reads the interface's IPv4 address and **fails**
   if it is not `10.0.0.5` — the Router admits that address only, so a
   different address is unreachable by design and should be loud.
3. Renders `/run/babo/config.json` with `gateway.host=<wg0 address>` and
   `gateway.port=$BABO_PORT`, then runs the server in the **foreground**.

Two deviations from the first draft, both deliberate:

- **`babo gateway`, not `babo webui`.** `babo webui` is a launcher: it starts a
  background gateway, manages a browser/dock icon, attaches to the log and
  returns (`babo/cli/webui.py`, ends in `_attach_to_background_gateway(...)`).
  Under tini that would exit the container and kill the service. `babo gateway`
  without `--background` runs the server in this process.
- **The bind address is read, not hardcoded and not defaulted.** `babo webui`
  has no `--host` flag; the bind comes from `config.gateway.host`
  (`babo/config/schema.py`, default `127.0.0.1`). The rendered config is the
  only place the bind is set, and step 2 makes the value a fact from the
  interface.

One listener fact worth stating plainly: the gateway binds the WG address; the
app's own WebSocket channel binds `127.0.0.1` **inside this container's network
namespace** (observed: `WebSocket server listening on ws://127.0.0.1:8765`).
That is internal to the pod and unreachable from the host — it is not a second
door — but it is why the claim in fact 4 is about `gateway.host`, the listener
the Router's rule names, and not about a grep for loopback in the image.

## Facts the packaging check holds it to

1. The image contains no WireGuard private key and no `wg0.conf`.
2. Exactly one bind mount at run time: read-only, source under
   `$HOST_SPAWN_DIR/runtime/babo`, target `/etc/wireguard`. Any other mount is
   a failure.
3. No published port; no `--network host`.
4. The effective listener is the WG address: a probe from the host WG address
   gets `200`; a loopback probe is refused; an off-source probe is refused by
   the Router.
5. `NEOCLAW_MANAGER_URL` has no loopback default (the code's default is
   `http://10.0.0.3:9200`). The image vendors a web UI with legitimate
   loopback use elsewhere, so the claim is about the Manager URL and the
   effective listener — not a grep for `127.0.0.1` across the image.
6. The image ships a built UI: `babo/web/dist/index.html` exists **inside the
   installed package**, so `pip install` did not drop it.

## What the check proves, and what it must leave unmet

`test/proof/babo_packaging_check.sh` runs on the deployment host and prints
`PASS`/`FAIL`/`UNMET` per line. It can prove from the image alone: facts 1, 2's
image side (no sockets, no runtime client), the refusal in fact 3 (no config →
no start), facts 5 and 6. It can prove from a running container
(`--container NAME`): the mount set, the port/network-mode facts, and the
capability set. It cannot prove the effective listener or the Router's
off-source denial without a live boot and a second source — those stay `UNMET`
with the reason, and `UNMET` is a result.

## Deliberate non-goals

No public listener, no password or token path, no activation or onboarding
code, no credential handling, no pod operation, no container-runtime client.
Those live in the Manager and the Router, which this slice does not modify.
