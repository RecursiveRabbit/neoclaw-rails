# Superseded Router design

This document described the earlier zero-forward-host and Router control-plane
iterations. It is retained only as a historical marker.

The current Router is a dumb WireGuard/iptables forwarder. The Manager holds
its private key and all peering data; replacement keeps the same IP, key, and
peers. It has no API, agent/service registry, or persistent control-plane
state.

Read `router/router.md` and `docs/NETWORK.md` for the current contract, and
`docs/NEOCLAW-RAILS-SPEC.md` for the whole target architecture.
