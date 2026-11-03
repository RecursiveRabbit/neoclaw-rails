# NeoClaw network architecture

This document describes the target network. Earlier multi-interface,
source-policy-routing, and Router-API designs are superseded.

## Ownership

The Manager owns the network's desired state:

- every peer's addressing and peering data;
- the Router's private key;
- each agent's WireGuard key material;
- service names and their host addresses/ports;
- the mapping from an identity to its authorized destination ports;
- the host connection configuration emitted when the network is first created.

The Router owns none of that semantics. It applies the network instructions it
is given and forwards packets.

## Topology and pairings

```text
                    ┌────────────────────────────┐
                    │            Host            │
                    │ Synapse and other services │
                    └───────┬──────────────┬─────┘
                            │              │
                          WG│              │WG
                            │              │
                        Manager           Router
                                           ▲
                                           │WG
                                           │
                                     Agent pods
```

- **Manager ↔ host:** paired for Manager/control access.
- **Router ↔ host:** paired for instructed service forwarding.
- **Agent pod ↔ Router:** each agent's only network peering.
- **Agent pod ↔ host:** no direct peering.
- **Agent pod ↔ agent pod:** no path unless the Manager explicitly creates one.

Matrix/Synapse is a service on the host. Each agent pod reaches it through its
Router path using the pod's own Matrix account credential. WireGuard does not
replace that application-level account authentication.

## Stable identity across Router rolls

Router replacement is deliberately boring. The Manager keeps and reuses:

- the Router IP;
- the Router WireGuard private/public keypair;
- the Router's peer set.

Consequently, replacing the Router does not change an agent pod's connection
contract and does not require rekeying or re-registering pods.

Starting the service initially creates the WireGuard network and outputs the
host's WG connection configuration. Subsequent ordinary rolls preserve those
same network facts. If the Manager deliberately changes peer data, that is a
separate configuration change with an explicit pod/host update, not an
incidental effect of a roll.

## Authorization

WireGuard supplies peer authentication and source-address binding. Iptables
supplies path authorization.

The Manager translates identity-level access into raw network instructions:

```text
source agent IP → destination host IP, protocol, destination port
```

The generated Router has no knowledge of which identity owns a source IP or
which service name owns a destination port.

Default policy is denial. The intended behavior is:

- authorized source to authorized host port: accept;
- established/related return traffic for that connection: accept;
- unauthorized source or port: deny;
- agent-to-agent traffic: deny unless explicitly instructed;
- Internet/NAT forwarding: only if explicitly instructed for that source.

"No path, no access" is the entire authorization model at the Router layer.
Services with their own authentication, including Matrix, still apply it.

## Agent identity

One identity has one pod, one Matrix user, one Kimi session, and one WireGuard
identity. A Matrix room does not create another network identity or another
set of service permissions.

For example, `nime-art` is not a pod or peer name. It is `nime` receiving a
message whose room metadata is `art`. If `nime` may reach a service, that
service is reachable by the same pod in every room.

## Offline behavior

An offline pod is shown as grey on Matrix. It receives no live notification
while its listener is down. The Manager can start it manually; after startup,
its Matrix client synchronizes and its ordinary notification path resumes.

There is no Hub responsible for resolving a mention into a new pod. Podman
start/stop/exec and Kimi-native lifecycle facilities determine how much direct
control the Manager needs; an optional Relay may provide a window into a pod,
but it is not part of the message-routing design.

## Required network tests

- The same Router IP/key/peer set survives successive replacements.
- Host and Manager pair as intended; every agent pairs only with the Router.
- Authorized host ports work and unauthorized ports fail closed.
- Agent-to-agent and other uninstructed paths fail closed.
- A source IP is usable only by its authenticated WireGuard peer.
- No direct agent-to-host peering or bridge-side bypass exists.
- Router replacement leaves pod WireGuard configuration untouched.
