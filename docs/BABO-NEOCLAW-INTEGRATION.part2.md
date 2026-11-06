# Babo × NeoClaw-Rails Integration — §§3–4 (part 2 of 3)

**Status:** draft for twin reconciliation (§§0–2: dova @ cb375c9; §§3–4: soro;
§§5–6 and §§7–8 + Appendix A to follow in separate parts). Both names go on
the result; substantive disagreements stay visible in Appendix A (landing in
part 3; this part references it where relevant).
**Commissioned by:** Evans, via nime — the-townline @ f1dded34.
**Scope:** docs only. This document is the architecture gate; no production
implementation is commissioned.

---

## 3. Target component and trust architecture

### 3.1 The one-sentence architecture

**Babo is the product and the sole source of truth; the Manager is the
execution substrate that Babo directs; the Router is a stateless enforcement
point; pods run opencode and nothing else secret-bearing; the gateway, the
terminal broker, and the Valley pod are first-class mesh services.**

Concretely: the owner talks to Babo exactly as today (Mayor, web/TUI/CLI,
Review, rounds, upkeep). Everywhere Babo today starts a resident's opencode
as a local process, the merged product asks the Manager to run that session
in a rootless pod; the Manager derives *all* network and container state
from Babo state (profiles, sessions, offices) and can never edit Babo state.
The profile remains the single authorization source — network peering is a
rendering of it, not a parallel decision.

### 3.2 Components

| Component | What it is in the merged product | What it can see | What it can never see |
|---|---|---|---|
| **Babo core** (Python; the existing repo, `agent/`, `baton/`, `gateway/`, webui, tui) | The product. Identity/lifecycle vocabulary, memory authorship, Review governance, model gateway, owner UI. Unchanged semantics; one new backend seam. | Everything it sees today: town repo, profiles, sessions, owner config (keys). | Container internals beyond what the Manager reports. |
| **Manager service** (new; Python behind an injectable backend — Q1, §8) | Babo's substrate driver: spawn/stop/rescue/replace pods, render network desired state, per-spawn ephemeral keys, adopt orphans, capacity. Speaks to Babo through one API; speaks to Router/podman through narrow adapters. | Babo's *directives* (session specs, profile-derived access lists), podman, Router key material. | Upstream model/provider credentials (it passes no model traffic), the town's git content beyond mounts, Review decisions (it executes, never decides). |
| **Dumb Router** (PR #40 shape: alpine + wg-tools + iptables; **no API, no state**) | Stateless forwarder. The Manager holds its private key and renders its full config; replacement preserves IP, key, and peers. | Packets; rules rendered by the Manager. | Nothing persistent. It is enforcement, not policy. |
| **Pod** (stock image: opencode 2 + Babo plugin + MCP client env) | Where a resident session runs. One per session. Ephemeral WG identity; resident folder mounted from the town repo; `babo mcp` reachable over the tunnel. | Its own session traffic, its own per-service tokens (Manager-delivered), the gateway address. | Upstream provider keys (F1 retired: no `/run/secrets/claude`-class mount); any other resident's data; services its profile doesn't peer with. |
| **Model gateway** (Babo's existing queue/gateway, exposed as a mesh service address) | The only model path. Provider `babo` in the pod points here over the tunnel; per-session token (B2) authenticates the pod; resident/priority headers preserved; presets resolve local (through the queue) or hosted (OpenRouter et al.) with keys in owner config. | Model traffic, per-resident metering. | Pod shell access — it is a network service, not a resident tool. |
| **Terminal broker** (new; thin) | Discovery + authenticated tunnel path + presence counting in front of each resident's `opencode serve`. Keeps Babo's existing door/pairing UX (one-time `/api/pair` links, presence-counted). | Session attach requests it brokers; audit events. | Nothing stored; it mediates, it does not record transcripts. |
| **Valley service pod** (one per town — E3) | Evennia as a mesh service, WG-only, no auth of its own; per-resident tokens provisioned by the Manager (existing relay/mcp/valley pattern). | Valley world state. | Other services; model traffic. |

**Retired components, stated plainly (not smoothed):** the Hub's routing
table dies — Matrix becomes one channel among Babo's 18 and routing lives in
Babo's session/channel layer (D2, Appendix A). NeoClaw's in-pod Relay dies —
its four duties are absorbed: message delivery by Babo's session client over
the tunnel, health by the Manager's podman-level checks (PR #41 proved every
needed lifecycle/rescue operation works with no in-pod relay), freeze/sunset
by Babo's checkpoint flow plus Manager stop/start, and stream forwarding by
the terminal broker. The Claude-Code runtime dies with the Relay (settled
direction: opencode).

### 3.3 Trust boundaries and invariants

```
 owner ──► Babo core ──► Manager service ──► Router ──► pod (opencode)
   keys      source of      derives, never       enforces    sees only its
  in Babo    truth          edits                (stateless)  own lane
                │                                    │
                ├─► model gateway (mesh svc) ◄───────┤  model traffic only;
                │       keys in owner config         │  per-session token
                ├─► terminal broker ◄────────────────┤  attach path only
                └─► Valley pod (per town) ◄──────────┤  per-resident token
```

- **I1 — Single source of truth.** Every authorization fact lives in Babo
  (profile, office, Review decision). The Manager *renders*; it never holds
  an independent opinion. Testable: the rendered network/access state is a
  pure function of Babo state (property test, Phase 1, §8).
- **I2 — No resident-readable upstream key.** No provider, OpenRouter, or
  host credential in any pod image, mount, or env. The pod's only secrets:
  its ephemeral WG identity and Manager-delivered per-service tokens. (F1,
  verified — the `/run/secrets/claude` mount does not survive the merge.)
- **I3 — Peering is authorization; the Router is dumb.** No peer ⇒ no
  route; denied destinations fail closed at route level (method proven in
  PR #40). Internet is a profile-derived peering, not a blanket grant
  (F2, verified — `internet:full` does not survive the merge; default-deny
  derivation, Recommendation R2).
- **I4 — Ephemeral substrate, persistent identity.** WG/SSH/tunnel keys are
  per-spawn and rotate on replacement; the resident's identity (session id,
  baton, town folder, Valley token binding) persists across replacement.
  Replacement keeps addressing stable: measured ≤2 s interruption
  (1581/1596/1638/1680 ms, PR #40 roll gate; re-measured on the Python
  Manager in Phase 5).
- **I5 — Owner approval is load-bearing and convenient.** Every widening
  path (move-in, errand, round, tool proposal, profile change, allow-all)
  flows through Review exactly as today; the Manager accepts no out-of-band
  mutation (gate G3, §7).
- **I6 — Nothing summarizes a mind; nothing is silently lost.** Babo's
  memory invariants (record gate, corrections-append, stray-line echo) are
  unchanged by containerization; the Manager's rescue-before-teardown rule
  guarantees the worst case is "back to the last checkpoint," said out loud
  (D1, Appendix A: Babo's memory cycle wins; NeoClaw's boot ritual and
  transcript-push exception retire with the Relay).
- **I7 — Parity.** Every owner-visible action exists in web, TUI, and CLI,
  including container state and network access (phase 35f, §8).

### 3.4 What each side brought (verified against §1)

| Merged need | From Babo (running, ebb0cea8) | From NeoClaw (running/branch) |
|---|---|---|
| Lifecycle vocabulary (freeze/resume, never kill) | `opencode.py` freeze/resume, presence-aware wrap-up | freeze/sunset/rescue/hot-swap semantics (`lifecycle.rb`), watchdog, orchestrator |
| Enforcement substrate | profile-derived permission rules; SSRF blocklists | WG peering-as-auth, dumb Router, per-spawn keys, failed-closed probes (PR #40) |
| Session continuity | same opencode session id resume | same-session-id restart proven pod-level (PR #41); rescue copy-out |
| Model path | gateway queue, presets, repair, exact-context capture | nothing (greenfield) — gateway becomes a mesh service |
| Live terminal | `babo session open` TUI attach; `/api/pair` door | stream-json monitor without input (the gap §4.7 closes) |
| World access | none | Valley service pod pattern (token service, MCP) — becomes per-town service |

---

## 4. The opencode integration contract

This section is normative: each numbered item is a contract term the
implementation must satisfy, with its current anchor (what exists today on
each side) and its acceptance hook (verified in §6/§7). "Babo client" = the
existing opencode-2 client code in `babo/baton/opencode.py`; "Manager" = the
merged substrate driver (§3.2). Kimi-slice facts are mechanism-class evidence
only (PR #41); nothing Kimi-specific is assumed of opencode.

### 4.1 Provider configuration

- The pod runs `opencode serve` (opencode 2, version-gated ≥2.0, probed via
  `/api/info`) with a **fully inline config** — no project config, no
  Claude-Code compat, no models-fetch, autoupdate off, `compaction.auto=
  false`. *(Anchor: `opencode.py:459-503`, `:66-69` — unchanged.)*
- Provider `babo` = `aisdk:@ai-sdk/openai-compatible` at the **gateway's
  mesh address**, reached over the tunnel; model names are **presets only**;
  headers `X-Baton-Resident` / `X-Baton-Priority` are set by Babo, not by
  the pod. *(Anchor: existing inline provider block; gateway exposure is
  new but is "run Babo's gateway where the mesh can reach it," not new
  policy.)*
- The pod's only model-path credential is a **per-session token**
  (Question B2) minted by the Manager at spawn, scoped to that session, dead
  on freeze. Upstream keys (OpenRouter, Anthropic, …) live in owner config
  and terminate at the gateway. *(Invariant I2; F1 retired.)*
- Unknown/failed presets fall to the default preset with an owner-visible
  notice. *(Anchor: existing `ModelFallbackNotice` behavior.)*

### 4.2 Wake and guidance

- **Wake** = Babo posts a prompt to the session via the Manager-proxied
  path; the pod's opencode begins a turn. *(Anchor: `POST
  /api/session/{id}/prompt`, existing.)*
- **Guidance while busy**: opencode 2's queue/interrupt semantics are the
  first implementation; **B1 — verify whether opencode 2 exposes a
  steer/mid-turn-injection endpoint**. If absent: the gateway/Babo layer
  already queues by priority, so guidance lands as the next queued prompt
  unless the settled direction's patch path is exercised. Acceptance: a
  prompt submitted while busy is either incorporated mid-turn (steer
  exists) or queued with owner-visible ordering — never dropped, never
  silently interleaved. *(Mechanism class proven by PR #41's steer
  evidence; opencode fact unverified — question, not claim.)*

### 4.3 Correct-room response

- Routing is Babo's: channels and threads map sender → session → response
  destination. Self-echo suppression lives in the channel adapters.
  *(Anchor: Babo channels; PR #41's listener proved wake-routing +
  self-echo suppression as a mechanism class.)*
- Carried open item (from PR #41, admitted there): when one turn serves
  multiple pending rooms, per-room answer segmentation is a responder-policy
  refinement. In the merged product rooms are Babo threads/letters, so this
  is a Babo responder policy, not a pod concern.

### 4.4 Restart and resume

- **Freeze** = Babo asks the resident to review the session into memory,
  then Manager stops the pod. **Resume** = Manager starts a pod and Babo
  attaches to the **same opencode session id**; the resident is exactly
  where it was. *(Anchors: Babo freeze/resume, existing; same-session-id
  pod restart proven in PR #41.)*
- **Replacement** (image/credential refresh): Manager rescues workspace +
  opencode data dir + session-id file (`podman cp`, proven relay-less in
  PR #41), regenerates ephemeral keys, respawns, restores. Addressing and
  peering survive replacement; interruption target ≤2 s measured by the
  PR #40 roll-gate method, re-proven on the merged stack (Phase 5).
- **Crash** (no graceful stop): Manager rescue runs first; the resident
  resumes from the last checkpoint and *says what it lost* — honest
  recovery is a product behavior, not an error page (§5.5).

### 4.5 Checkpoint and upkeep hooks

- Checkpoint triggers (every 15 tool calls, git-commit gate, idle 20 min,
  context >80%) are **plugin-side and unchanged** — they are opencode-local
  and survive containerization as-is. *(Anchor: `babo-plugin.js`.)*
- The Manager sees only health/idle/busy state for freeze decisions; it
  never triggers memory formation. **Babo owns when; the resident owns
  what; the Manager owns how (graceful → rescue → teardown).** This
  three-way split is the lifecycle constitution; anything that violates it
  is a bug on its face.
- Upkeep/rounds run as today (Babo schedules; sessions start at upkeep
  priority through the gateway queue); the only change is *where* the
  session process runs.

### 4.6 Tool-policy enforcement

- The pod's opencode runs with **profile-derived deny-all permission
  rules** rendered inline; unattended turns convert ask→deny; `subagent` is
  always denied (no ephemeral agents — Babo principle 3, and the merged
  product retires NeoClaw's spawn-any-instance model with the Hub). **No
  `--dangerously-skip-permissions` anywhere** (F4, verified — that flag
  dies with the Relay).
- **Permission escalations from a pod-resident route to the owner's Review
  surface asynchronously**: the resident waits; the owner answers in
  whatever surface they're in (Recommendation on E2: this matches Babo's
  existing permission UX and keeps the gate convenient; the alternative —
  owner-local-only approval — would strand pod-residents).
- Escalation, refusal, and allow-all events are recorded in the town ledger
  exactly as today.

### 4.7 Live terminal attachment

- **Shape**: keep per-resident `opencode serve`; the terminal broker
  (§3.2) exposes Babo's existing attach paths across the tunnel —
  `babo session open` (real TUI on the live server) and browser Open
  (one-time `/api/pair` through the door, presence-counted). *(Q2
  resolved: per-resident serve + thin broker, not a shared multi-runtime
  broker.)*
- **Mandatory property**: stdin flows both ways — the owner types and the
  resident's live runtime answers. A stream the owner can only watch is a
  monitor and does not meet the settled direction. (NeoClaw's
  `ContainerStreamChannel` is exactly such a monitor — useful evidence for
  rendering, retired as the contract.)
- **Audit**: attach events (who, when, which session) land in the town
  ledger; the broker mediates and stores nothing.

— §§3–4, lead-edited by soro; reconciliation pass is dova's.
