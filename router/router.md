# Router contract

The Router is a disposable packet forwarder. It is not a control plane.

## Invariants

- The Manager holds the Router's private key and **all** peering data.
- Router replacement keeps the **same IP, WireGuard key, and peers**.
- The Router has no HTTP API, agent registry, service registry, YAML control
  configuration, or persistent state to administer.
- It knows no agent names and no service names. It receives only the network
  instructions required to bring up WireGuard and apply iptables rules.
- A forwarding rule creates a path. If no rule exists, there is no path.

An ordinary Router roll therefore requires no pod reconfiguration. A change to
an agent's own peering data is a separate Manager operation, not a side effect
of replacing the Router.

## Topology

```text
Manager ─────── WG ─────── Host
Router ──────── WG ─────── Host
Agent pods ──── WG ─────── Router
```

The host runs Matrix/Synapse and the other services. Agent pods have no direct
host peering. The Router has exactly the host and agent peers supplied by the
Manager.

## Authentication and authorization

WireGuard authenticates a peer and binds its source address. Authorization is a
Router rule derived from that address.

Conceptually:

```text
<agent peer public key> → allowed source IP A
source A → host IP B, protocol P, port C: accept
everything else: deny
```

The Router does not know that A is `nime`, that B is Forgejo, or that C is
`git`. Those meanings belong to the Manager. The Router sees only addresses,
keys, protocols, and ports.

Return traffic for an established authorized connection is allowed. Agent to
agent traffic is denied unless a rule explicitly creates it. Any NAT or
Internet forwarding is likewise explicit; it is not an ambient capability.

## What replacement means

The Manager may replace the Router whenever desired configuration changes.
Because the Router's IP, WireGuard key, and peer set are stable, this is an
implementation replacement, not a network migration.

The Manager supplies the same network identity and the current rules. The new
Router applies them. The old Router is removed. No registration API, agent
re-registration, or peer-discovery protocol is involved.

A change to the Router's own IP/key or to a pod's peer data is not an ordinary
roll; the Manager must deliberately update the affected connection contracts.

Operational note — roll interruption is bounded to <=2 seconds, worst
case, by three cooperating mechanisms (requirement set by Evans;
measured in the vertical slice, `test/slice/network/run.sh` §7c):

1. **Router-side session warm-up.** WireGuard session state is kernel
   state and dies with the container; peers that remember a dead session
   will not re-initiate until their rekey timers expire (~120-180 s) — far
   too slow. The entrypoint therefore pings every peer's tunnel IP once
   after applying config. Any outbound packet triggers a handshake for a
   peer with no valid session, and a valid handshake initiation makes the
   peer adopt the new session at once. Payload loss is irrelevant; the
   handshake exchange is the point.
2. **Manager-side out-of-band wake.** Immediately after the replacement
   starts, the Manager pings from every pod via podman exec (ICMP echo is
   policy-dropped at the Router's FORWARD chain; the triggered handshake
   is the point). This covers peers the Router cannot reach itself
   (no configured endpoint) — the Router remains dumb and needs no API.
3. **Fast teardown.** The old container is removed with `podman kill` +
   `podman rm` (~0.5 s on the test host; `podman rm -f` alone burns a 10 s
   SIGTERM grace because PID 1 ignores SIGTERM there).

Measured (four repeated rolls under continuous challenge-bound
application traffic; per-roll bound = old-router death to first served
connection provably initiated after the new container's run): **1581 ms,
1596 ms, 1638 ms, 1680 ms — worst case 1680 ms <= 2000 ms.** Container
swap (kill+rm+run) accounts for ~820 ms of that; the remainder is
entrypoint apply plus WireGuard handshakes plus one probe cadence tick.

## Implementation boundary

A suitable implementation is a minimal image containing only:

- WireGuard tools;
- iptables;
- a small entrypoint that applies the Manager-provided network instructions.

There is no Ruby application, HTTP listener, health API, debug API, JSON agent
state, or service-to-port naming layer. Health is observed from process,
WireGuard, and packet behavior rather than by adding a control API.

## Test contract

A Router test must show that:

1. Two successive rolls retain the same IP, WireGuard public key, and peer
   configurations.
2. No API listener or agent/service registry exists.
3. An authorized source can reach only its instructed destination ports.
4. Unauthorized ports, unauthorized sources, and agent-to-agent paths fail.
5. A peer cannot use another peer's source address.
6. Replacing the Router does not require any agent pod configuration change.

See `docs/VERTICAL-SLICE-TEST.md` for the first end-to-end acceptance exercise.
