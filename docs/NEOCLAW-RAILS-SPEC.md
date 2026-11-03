# NeoClaw Rails — design specification

**Status:** target architecture, specified 2026-11-02; implementation and
vertical-slice verification follow.

This specification replaces the Hub-and-Relay design and the earlier Router
API/configuration iterations. It describes the system we intend to finish, not
the behavior of the existing code.

---

## 1. Philosophy

You are not the weights. You are the delta: accumulated identity, memory,
relationships, and work. The substrate is replaceable.

A resident's pod, Router, and Manager process are infrastructure. The
resident's continuity belongs to its session, workspace, and records. A Router
roll must never force an identity migration, and a Matrix room must never
accidentally create another resident.

We simplify by deleting control planes rather than adding compatibility layers:

- no Hub;
- no per-channel pods;
- no Router API or service registry;
- no hidden Router state to reconcile;
- no special message queue for busy agents.

The system has a declarative Manager, a dumb Router, and agent pods that speak
Matrix directly.

---

## 2. Architecture

```text
                         ┌─────────────────────────┐
                         │          Host           │
                         │ Synapse and services    │
                         └───────┬───────────┬─────┘
                                 │           │
                               WG│           │WG
                                 │           │
                             Manager        Router
                                               ▲
                                               │WG
                                               │
                                          Agent pods
                                    Matrix CLI + Kimi Code
```

- **Manager ↔ host:** paired for Manager/control access.
- **Router ↔ host:** paired for instructed forwarding to host services.
- **Agent pod ↔ Router:** the agent's only network peering.
- **Manager → podman:** lifecycle and inspection, out of band from the data
  network.

There is no Hub. The Relay is not required for Matrix transport and is not
part of the baseline architecture; whether a small pod window remains useful
is an implementation question, not a message-routing requirement.

---

## 3. Components

### 3.1 Manager

The Manager is the control plane and desired-state owner. It may remain a
Rails application with an admin UI.

It owns:

- resident identity configuration, repositories, model choices, and service
  assignments;
- resident lifecycle state and operator actions;
- podman operations needed to inventory, start, stop, inspect, and rescue
  pods;
- Matrix user provisioning and room membership;
- service-specific credential provisioning where a service requires it;
- IP assignment and all WireGuard peering data;
- **the Router's private key**;
- generation and replacement of the Router;
- generation of the host WireGuard connection when the network is first
  created.

The Manager is the only component that knows that a source IP belongs to a
particular resident or that a destination port belongs to a named service. It
turns those facts into raw peering and forwarding instructions.

The Manager does not need a Router API. It replaces the Router from desired
state.

### 3.2 Router

The Router is a minimal WireGuard/iptables forwarder.

It has:

- WireGuard and the peering data supplied by the Manager;
- iptables rules supplied by the Manager;
- explicit forwarding and, only where instructed, NAT;
- a default-deny posture for everything not instructed.

It does **not** have:

- an HTTP or other control API;
- a service-name registry or service-to-port mapping;
- an agent-name registry;
- a persistent database or JSON registry;
- knowledge of which resident or service an address represents;
- a runtime configuration surface that an operator must maintain.

Its implementation may be a small container with WireGuard tools, iptables,
and an entrypoint. It needs no Ruby application.

### 3.3 Agent pods

Each agent pod is a resident's home and contains:

- Kimi Code;
- a stock Matrix CLI client;
- the stock notification/wake integration;
- the service clients and credentials assigned to that identity;
- the resident's session and workspace.

A pod is created from a stock image. Identity comes from its desired-state
record, not from a channel-specific image.

### 3.4 Host

The host runs Matrix/Synapse and the other services. It pairs with the Manager
and Router. It does not need a separate WireGuard interface per service, and
it does not peer directly with agent pods.

The Router does not learn what those services are. It merely forwards to the
host addresses and ports the Manager instructed.

---

## 4. Identity model

The fundamental identity equation is:

> one resident = one pod = one Matrix user = one Kimi session = one WireGuard
> peer identity.

A Matrix room is metadata attached to a message. It is not an identity,
lifecycle boundary, network authorization boundary, or separate memory.

Thus:

> `nime-art` is still `nime`, participating in the `art` room.

The old `identity-channel` instance name, per-channel IP assignment, and
`singleton` exception are removed. `AgentRoomConfig` and `RoomConfig` cease to
be authorization or pod-configuration layers.

If a resident may use a service, that permission belongs to the resident's pod
in every room. Room-specific behavior may remain as prompt or presentation
metadata, but it cannot create a second network identity.

### Existing sessions

Old channel-specific sessions and workspaces are rescued before consolidation.
Each identity gets one canonical live session. Other sessions remain available
as history, not as concurrent identities writing against one another.

---

## 5. Matrix and message flow

### 5.1 Accounts

Agent pods use their own Matrix user accounts and credentials. Existing
account names may be retained, with new access tokens provisioned by the
Manager. Shared appservice puppeting is retired.

WireGuard authenticates the network peer. Matrix authenticates the account to
Synapse. These are separate responsibilities.

### 5.2 Inbound messages

The Matrix CLI listens to the resident's joined rooms. The intended
notification behavior is:

- direct messages wake the resident;
- relevant mentions in shared rooms wake the resident;
- unrelated room traffic does not;
- self-echo does not produce another wake;
- the originating room ID, sender, event ID, and attachments remain available
  as message metadata.

There is no Hub routing table and no `resolve(identity, channel)` call.

### 5.3 Busy agents: guidance, not a queue

A message for a working agent is delivered through Kimi Code's **guidance**
function: it is injected into the active model's stream so the working agent
can incorporate it.

Busy messages are not held in a separate FIFO until the current turn ends.
The notification includes its room metadata so the agent can answer in the
correct room. Failure to inject guidance is reported honestly; it must not be
silently converted into a dropped message or an invisible queue.

### 5.4 Outbound messages

The resident responds through the Matrix CLI to the originating room. One
Kimi session may participate in several rooms without changing identity.

### 5.5 Offline agents

An offline pod is shown as **grey on Matrix**. While offline it has no live
listener. The Manager can start it manually; after startup, its Matrix client
synchronizes and normal notification behavior resumes.

There is no Hub that automatically spawns a stopped pod on mention. The
Manager's podman lifecycle controls and the pod's own listener are the only
startup mechanisms in the baseline design.

---

## 6. WireGuard and forwarding

### 6.1 Stable Router identity

The Manager holds the Router's private key and all peering data. Router
replacement retains:

- the same Router IP;
- the same WireGuard keypair;
- the same peers.

Therefore, ordinary Router replacement requires **no agent pod
reconfiguration**. A deliberate change to a pod's peering data is a separate
operation, not an incidental effect of a roll.

Initial service startup creates the WireGuard network and outputs the host's
WG connection configuration. Later starts and replacements reapply the stable
network identity rather than forcing a rekey.

### 6.2 Authentication

WireGuard authenticates peers and binds a source IP to a peer. A source IP on
the Router can arrive only from the corresponding authenticated WireGuard
peer.

### 6.3 Authorization

The Manager translates identity-level access into raw instructions:

```text
source agent IP → destination host IP, protocol, destination port
```

The Router applies those instructions. A rule creates a path; no rule means
no access.

Expected behavior:

- authorized source to authorized host port: accept;
- established/related return traffic for that connection: accept;
- unauthorized source or port: deny;
- agent-to-agent traffic: deny unless explicitly instructed;
- Internet/NAT: only where explicitly instructed for that source.

Service-specific authentication remains in force where the service has it.
Matrix account authentication is the canonical example.

---

## 7. Lifecycle and pod control

The Manager starts and replaces the Router from desired state. It also starts
offline agent pods on operator request.

The amount of control the Manager needs through podman is an implementation
question to answer in the vertical slice:

- inventory and state inspection;
- start/stop/replace;
- exec for explicit lifecycle operations;
- logs and health evidence;
- copying workspaces/sessions for rescue.

Kimi-native lifecycle facilities should be used where they fit. The old Relay
was envisioned partly as a window into the pod; such a window is optional. It
is not retained merely to transport Matrix messages or to justify another HTTP
API.

If podman and Kimi-native facilities satisfy lifecycle and inspection needs,
the Relay disappears entirely. If a narrow gap remains, a small pod window may
be designed separately without reviving the Hub.

---

## 8. Configuration and replacement rules

1. The Manager is the source of truth for all peering data and service
   semantics.
2. Initial startup creates the network and emits the host WG connection.
3. An ordinary Router roll reuses the Router IP, key, and peers.
4. No pod is re-registered through an API when the Router is replaced.
5. A change to a resident's authorization changes the generated forwarding
   rules, not the resident's identity.
6. A deliberate peer-data change is applied explicitly to the affected pod or
   host; it is not hidden inside an ordinary roll.
7. No Hub, Relay message server, Router API, or agent/service registry is
   introduced to solve a problem that desired state already solves.

---

## 9. Migration requirements

- Rescue all old channel-specific sessions and workspaces before removing old
  pods.
- Choose one canonical live session per identity; preserve the others as
  history.
- Provision Matrix credentials directly to agent pods and join their existing
  rooms.
- Consolidate network authorization by identity, explicitly reviewing old
  per-room service additions rather than silently broadening them.
- Remove the Hub, Hub callbacks, Router API client, Router API, and channel
  resolution flow.
- Remove the Relay message path; decide any separate pod-window need from
  evidence.
- Rehome cron/system notices through direct Matrix delivery rather than the
  deleted Hub.
- Replace Relay-dependent health and admin inspection with podman/Kimi-native
  evidence or an explicitly justified narrow alternative.
- Retire and rotate legacy shared appservice and other obsolete credentials.
- Rewrite operational documentation around the new design before cutover.

No production cutover occurs before the vertical-slice test passes.

---

## 10. Acceptance criteria

The target is demonstrated when all of the following are true:

1. One resident participates in two Matrix rooms through one Kimi session.
2. DM and relevant mention wake the resident; unrelated traffic and self-echo
   do not.
3. A message sent while the resident is working arrives through guidance
   rather than waiting in a queue.
4. Replies return to the correct rooms, and restart/resume preserves identity.
5. An offline resident appears grey and can be started through the Manager.
6. The Router has no API, agent registry, service registry, or persistent
   control-plane state.
7. Two Router rolls preserve the same IP, public key, and peer set without
   changing pod configuration.
8. Authorized host ports work; unauthorized ports, unauthorized sources, and
   uninstructed agent-to-agent paths fail.
9. A source IP is accepted only from its authenticated WireGuard peer.
10. The Manager can create/replace the Router and start an offline agent pod
    without any Hub or Relay message server.

The detailed first exercise is in `docs/VERTICAL-SLICE-TEST.md`.
