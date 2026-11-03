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

Operational note: WireGuard session state is kernel state and dies with the
container. A peer that was talking to the old Router keeps transmitting with
its old session and is silently dropped until WireGuard's RejectAfterTime
(~180 seconds) expires, at which point it re-handshakes automatically. An
ordinary roll therefore causes up to ~3 minutes of agent outage with no
configuration change and no operator action. If a future requirement cannot
tolerate that window, the remedy is a deliberate design change (for example,
a Manager-initiated link bounce delivered out of band), not a Router control
API.

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
