# Superseded network design

This document described the earlier per-service-interface and Router-API
architecture. It is retained only as a historical marker.

The current target is **direct Matrix clients in agent pods, one pod per
identity, a declarative Manager, and a dumb WireGuard/iptables Router with a
stable IP, key, and peer set across rolls**.

Read instead:

- `docs/NEOCLAW-RAILS-SPEC.md` — complete target design;
- `docs/NETWORK.md` — topology, ownership, and authorization;
- `router/router.md` — the Router's implementation contract;
- `docs/VERTICAL-SLICE-TEST.md` — the first acceptance exercise.
