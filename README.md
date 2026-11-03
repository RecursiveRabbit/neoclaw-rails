# NeoClaw Rails

NeoClaw is a lifecycle and network control plane for persistent coding
residents. The current design is intentionally small:

- **No Hub.** Each agent pod runs a Matrix CLI client and wakes Kimi Code
  through the stock notification path.
- **One pod per identity.** Matrix rooms are message metadata, not separate
  residents. `nime-art` is still `nime`.
- **A declarative Manager.** The Manager owns desired state, including the
  Router's private key and all of its peering data.
- **A dumb Router.** WireGuard plus iptables, with no API, service registry,
  agent registry, or persistent control-plane state.
- **Stable network identity across Router rolls.** Router replacement keeps
  the same IP, WireGuard key, and peers, so ordinary replacement does not
  require pod reconfiguration.
- **Busy-agent delivery by guidance.** A message for a working agent is
  injected into its active model stream rather than queued behind it.

The authoritative design is in
[`docs/NEOCLAW-RAILS-SPEC.md`](docs/NEOCLAW-RAILS-SPEC.md). Network and Router
contracts are in [`docs/NETWORK.md`](docs/NETWORK.md) and
[`router/router.md`](router/router.md). The first acceptance exercise is
specified in [`docs/VERTICAL-SLICE-TEST.md`](docs/VERTICAL-SLICE-TEST.md), and
its evidence is summarized in [`docs/PHASE-1-STATUS.md`](docs/PHASE-1-STATUS.md).

## Status

The disposable z620 vertical slice has produced its network and Matrix/pod
evidence: **PR #40** covers the dumb Router and ≤2-second replacement; **PR
#41** covers Matrix/Kimi behavior, guidance, and podman lifecycle. The real
Manager integration and production migration are still ahead. Earlier code
describes a Hub-and-Relay system and is being replaced, not preserved as the
target architecture.

## Components in the target system

- **Manager:** Rails control plane, admin UI, desired-state owner, Matrix and
  service provisioning, pod lifecycle, and all Router peering data.
- **Router:** a minimal container running WireGuard and iptables. It forwards
  only the traffic the Manager instructed it to forward.
- **Agent pods:** stock image, Kimi Code, Matrix CLI, notification/wake path,
  and the service clients assigned to that identity.
- **Host:** Matrix/Synapse and the other services. It pairs with the Manager
  and Router; agent pods pair only with the Router.

WireGuard authenticates peers. Router rules authorize paths. Matrix account
credentials still authenticate each resident to Synapse; those are separate
layers.
