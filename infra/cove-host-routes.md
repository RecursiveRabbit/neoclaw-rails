# The Cove host half

`cove/` cannot install these and never could: they are the host's.

Evans, 2026-11-23, and the desk's restatement — the pods' path out is entirely
host-side: (1) the pod-subnet routes via the Router's transport address, (2) a FORWARD
accept keyed to the Router (already in place), (3) the LAN-gateway reply path blocked as
a backstop behind the route.

**(1) and (3) are this directory.** R16 measures them: `return=via Router(<transport>)`
is its only good state.

| file | what it is |
|---|---|
| `cove-host-routes.py` | reads `cove/state/plan.yml` and installs the routes; idempotent |
| `cove-host-routes.service` | oneshot, runs at boot and on demand |
| `cove-host-routes.timer` | re-asserts every 60 s |

## Install

```sh
sudo install -m 0755 infra/cove-host-routes.py      /usr/local/sbin/cove-host-routes.py
sudo install -m 0644 infra/cove-host-routes.service /etc/systemd/system/
sudo install -m 0644 infra/cove-host-routes.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cove-host-routes.timer
sudo systemctl start cove-host-routes.service      # first install now
```

## Verify

```sh
ip -4 route | grep 10.201
#   prohibit 10.201.0.0/20 metric 1000
#   10.201.1.0/24 via 10.89.4.2 dev podman5
#   10.201.2.0/24 via 10.89.4.2 dev podman5
ip route get 10.201.2.10        # -> via 10.89.4.2 dev podman5   (never via 10.0.0.1)
journalctl -u cove-host-routes -n 5
```

The script prints its own verdict for both pools and exits non-zero if either does not
route via the Router. It never reports success for a partial state.

## Why a timer, and why this is not a workaround

The routes were installed by hand twice on 2026-11-24; the power blip that morning took
them, and the host then answered `LAN-PATH-OPEN(10.201.2.10 via 10.0.0.1)` — a reply to a
pod handed to the LAN gateway, which is the path Evans ruled must be blocked. A **Router
restart also flushes them**, measured: the routes carry `dev podman5`, and when the
Router's pod goes the bridge address goes with it. So the timer re-asserts; the script is
`ip route replace` throughout, so a re-run is the same operation as the first run, and the
journal is the record of whether it ever had to repair anything.

## Why the backstop is `prohibit` and not `blackhole`

Measured on z620, 2026-11-24: `ip route get` prints **nothing on stdout** for all three
blocked route types, and one line on stderr —

| type | stderr |
|---|---|
| `unreachable` | `RTNETLINK answers: No route to host` |
| `prohibit` | `RTNETLINK answers: Permission denied` |
| `blackhole` | `RTNETLINK answers: Invalid argument` |

"Administratively prohibited" is what a ruling looks like in a routing table. R16 reads
that line to name `NO-ROUTE`; without this fix it could not see any of the three and a
blocked route read as `LAN-PATH-OPEN("")` — the good state reported as the failure.

## Known limit

The routes are derived from `plan.yml` but the script is not *triggered* by it. If the
plan moves, the timer re-derives within 60 s rather than at the moment of the move.
