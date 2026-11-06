# Babo × NeoClaw-Rails Integration — Architecture for the small-model CommuneOS harness

**Status:** reconciled twin draft — lead-edited in turns (§§0–2 dova @ cb375c9; §§3–8 soro @ 120cd54/3f60b9a/456add3), reconciled by dova (assembly + verification record below). Both names on the result; substantive disagreements stay visible in Appendix A, appended never rewritten.
**Commissioned by:** Evans, via nime — `requests/2026-11-05-from-evans-via-nime-to-dova-soro-babo-neoclaw-integration.md` (the-townline @ f1dded34).
**Scope:** docs only. This document is the architecture gate. No production implementation is commissioned or designed here beyond what acceptance gates require.
**Settled direction (restated, not re-litigated):** not a migration of existing residents; a new harness for small local models, Grimes-shaped; feels like Babo, as secure as NeoClaw; opencode wins by default as the resident runtime (may be patched); Kimi Code is not a candidate for this product's runtime path; Babo UI controls the NeoClaw backend without a second source of truth; OpenRouter + local providers live in the pod/provider structure with upstream credentials out of resident-readable storage; each town gets its own Valley service pod; a real interactive live terminal view is mandatory; greenfield, Grimes-shaped acceptance; no production migration.

## Provenance pins (verified 2026-11-05)

| Artifact | Pin | Kind |
|---|---|---|
| Babo | `bgrimes-me/babo` `main` @ `ebb0cea8` | running code (read in full by dova; surveyed by soro) |
| NeoClaw-Rails | `RecursiveRabbit/neoclaw-rails` `main` @ `ef28ab9` | running code |
| Router/network slice | `origin/soro/router-network-slice` (PR #40, OPEN) | reviewed branch evidence — measured roll interruption 1581/1596/1638/1680 ms across 4 rolls |
| Pod/Matrix slice | `origin/slice-dova-matrix-pods` (PR #41, OPEN) | reviewed branch evidence (Kimi runtime — mechanism class only) |
| Independent notes | dova `the-townline` @ `619885b6`; soro @ `608f9dd3` (branch copy `decf42f`) | filed before reconciliation, cross-read only after both landed |

Conventions: "running code" = merged and read at the pinned commit; "branch evidence" = reviewed slice harness, not production; "target-only prose" = design documents nothing implements yet. Absence of evidence is filed as exactly that.

---

## 1. Current-state evidence

### 1.1 Running code — Babo (`ebb0cea8`)

The complete Babo feature/UI inventory is dova's note (`619885b6`, §3); the load-bearing facts for this document, all code-verified:

- **Every resident runs as its own `opencode serve` (opencode 2, version-gated ≥ 2.0)** started per session with a fully inline config (`babo/baton/opencode.py:459-503`): provider `babo` = `aisdk:@ai-sdk/openai-compatible` at the model-queue endpoint, headers `X-Baton-Resident` / `X-Baton-Priority`, preset-named model only, `compaction.auto=false`, `autoupdate=false`, env kill-switches against project config / Claude-Code compat / models-fetch (`:66-69`).
- **Profile-derived deny-all permission rules** (`_permissions`, `opencode.py:401-449`): reading allow (own folder, or town when `read=town`), edit fenced to own folder, town-own files denied, shell/webfetch leveled (unattended turns convert ask→deny), exact command pieces, `subagent` always denied, town MCP tools always allowed, per-profile MCP allowlist.
- **babo-plugin.js** (335 lines, reinstalled at every start): spools every tool call (Babo redacts into the town event log); checkpoint triggers (every 15 tool calls, git-commit gate, idle 20 min, context >80%); drift/loop detectors with tools-done + turn-stop; guide/skill injection; appends the resident's "now" + a trusted clock at the **end** of the turn message, every step (prompt-cache-safe).
- **Town tools** via `babo mcp --as <resident>` (`babo/baton/tools/core.py`): search_memory, read_note, remember, correct_checkpoint, update_tasks, project_board, town_square, revise_self, send_letter, propose_tool, propose_change, send_errand, commons_write/supersede/contest, file_flag, review_item.
- **Model gateway** (`babo/baton/queue.py`, `gateway.py`): one OpenAI-compatible queue; slots (default 1); priority interactive < visit < upkeep; tool-call repair (JSON + Qwen XML); thinking handling learned per model; per-resident byte-for-byte request capture (`babo context <resident>`); Router resolves presets to local (through the queue) or hosted providers with **keys inside Babo**; config hot-reloads on mtime; unknown model names fall to the default preset.
- **Lifecycle**: freeze = resident reviews session into memory, then stop; resume = same opencode session id continues exactly; near-full context = checkpoint then fresh session from the baton; wrap-up follows presence (never frozen while watched; 15-min grace; 24h for permission waits).
- **Governance**: errands approved word-for-word with immutable approval (change after open → refused; file change after approve → doesn't run); exact commands only; Allow-all per chat with expiry and a warning label; weekly Review (proposed tools with test results + Inspector review, proposals, move-ins, flags); rounds as readable files with rehearsals (unattended or live) proposing exact access; one-commit upkeep with resumable pass ledger.
- **Memory invariants**: the record (`checkpoints/`, `BATON.md`) is writable only through the resident's tools; the plugin refuses direct file edits; stray lines are shown back word-for-word, never silently fixed; caps 12 threads / 8×300 chars / ~1200 tokens.
- **Small-model discipline**: stable identity block cached at prompt start, volatile "now" last; guides brought in at the right moment (never merely announced); skills by keyword; task list re-shown while open; `babo eval` (31 single-call tasks, per-preset baselines; first 35B baseline 25/31); `babo trial` (whole scenarios in throwaway towns, every model call recorded to a shareable `.json.gz`).
- **UI**: WebUI Town page (Residents/Square/Review/Projects/Rounds/Sessions/Activity/Profiles/Settings/Doctor/Eval; *Needs you* above everything; buttons/switches/sliders; status beside the action that started it); full TUI (presentation-only client over the same Python gateway); CLI parity; 18 chat channels. **Live view today**: `babo session open` = `opencode --server <url> --session <id>` (real TUI on the live server); browser Open = one-time `/api/pair` link through a per-session "door" proxy that counts presence (`opencode.py:769-778`, `:1444-1450`). This is a genuine interactive session, not a transcript.
- **Ops**: runbook steps 00–07 + owner-run `host-services`; systemd user services (`babo-queue`, `babo-gateway`, `babo-upkeep`); distrobox default; rootless at run time; upgrade path tidies removed features.

### 1.2 Running code — NeoClaw-Rails (`ef28ab9`)

Soro's note (`608f9dd3`, §1) is the deep read; the facts this document stands on (all re-verified at `ef28ab9` by dova):

- **Manager (Rails)**: Spawner (`resolve`, capacity check → freeze-coldest → spawn; ephemeral WG + SSH keypairs per spawn; `build_spawn_file` produces spawn.json with **exactly one WireGuard peer — the Router**, `allowed_ips 0.0.0.0/0`, `spawner.rb:283-288`); Provisioner (per-service auth: Forgejo ephemeral user + SSH key + repo grant, host-SSH authorized_keys, Valley/Vikunja tokens via host-side token services, generic-token and WG-only types; teardown mirrors); Lifecycle (`freeze!`, `sunset!`, `hot_swap!`, `rescue!` = `podman cp` workspace + session out then `SessionProcessor.process_crash`, `teardown!` one atomic pass; relay signals over HTTP `:9300/signal`); Podman backend (the only container-creation path); RouterClient (Manager → Router HTTP: `POST /agents`, `PUT /agents/:name/peer`, `PATCH` access, `DELETE` peer/agent, `POST block`); Orchestrator/Watchdog (post-boot adoption of orphans by reading spawn.json back; rescue on relay silence); AuditLog records every lifecycle event.
- **Relay** (`relay/relay.rb`, 681 lines): in-container, per-message invocation of the vendor CLI with **`--dangerously-skip-permissions`** (`:211`); `/message`, `/signal` (freeze/sunset/stop), `/health` on :9300; prunes tool results and pushes transcripts to git on freeze; streams raw stream-json to the Manager.
- **Manager admin UI ships a live view** — `ContainerStreamChannel` relays stream-json lines to a browser over ActionCable with buffered history and a WebSocket stop action. **It is a monitor: no input path.** (Confirmed; this is the gap behind the settled direction's "live terminal is mandatory.")
- **Hub (Rails)**: Matrix connection, routing, resolve/release via ManagerClient. Zero privilege by design. **Superseded by the settled direction**: Babo's session layer + channels replace the routing core; Matrix becomes one channel among Babo's 18.
- **Enforcement model as implemented**: authentication = WireGuard peering (Router is the only peer in every agent config; no peer = no existence); authorization = Router firewall state per agent IP, derived from the service list at registration (`build_access_list`, `spawner.rb:209-217`); provisioning = Manager only (admin tokens in Surface, never written to the town); graceful lifecycle with rescue fallback on every path.

### 1.3 Reviewed branch evidence (not production)

- **PR #40 (soro)**: Router becomes a stateless alpine + wg-tools + iptables appliance with **no API**; Manager owns all network desired state and renders Router config; replacement preserves IP, key, and peers — proven by the **≤2 s roll gate: 1581/1596/1638/1680 ms worst-case across 4 measured rolls**; unauthorized-destination probe failed closed at route level. Reusable: replacement-preserves-addressing proof, failed-closed probe method, roll-gate measurement discipline. Honest limit: disposable rig (10.99.1.0/24 rootless), numbers challenge-bound-favorable, labeled as such.
- **PR #41 (dova)**: wake/guidance on an HTTP session server end-to-end (DM wake, mention wake, self-echo suppression, busy delivery by guidance — queued → steer → mid-turn incorporation, offline-grey ≤30 s via Manager stop/start, **restart/resume on the same session id**); lifecycle entirely via podman (no in-pod relay server needed); identity rescue by session-id-file copy-out. **Kimi-specific findings must not be carried as opencode facts** (empty-model sessions, `:steer` route shape, matrix-commander vs Synapse server-less room IDs); the matrix-nio finding applies to any matrix-commander use in the merged stack. Mechanism class transfers; facts do not.

### 1.4 Target-only prose (the spec is not the system)

`docs/NEOCLAW-RAILS-SPEC.md` (Hopper's draft) is philosophy + seams: Hub/Manager/Relay separation, WireGuard-as-authorization, freeze/sunset vocabulary, capacity with soft/hard caps, service registry, failure-mode table. It names **Kimi/Claude-class vendor CLIs as the container runtime** and per-service WG interfaces — superseded by the settled direction (opencode; dumb Router; single-peer mesh). Nothing on main implements: opencode runtime, an OpenRouter/local provider broker, a terminal broker, Valley service pods, or any Babo surface. All greenfield design surface, specified below.

### 1.5 Findings register (informed, file:line, verification status)

| # | Finding | Evidence @ ef28ab9 | Status |
|---|---|---|---|
| F1 | Host vendor-credentials dir mounted read-only into **every** agent container (`-v host_claude_dir:/run/secrets/claude:ro`) | `manager/app/services/podman.rb:34,75` | **Verified verbatim.** Violates settled direction ("upstream credentials out of resident-readable storage") and Babo principle 7. In the merged product: no provider key ever enters a pod; model calls egress only to the model gateway. (A local un-pushed commit renames the mount for Kimi; the defect is identical.) |
| F2 | `internet:full` appended to every agent's Router access list unconditionally | `manager/app/services/spawner.rb:216` (`build_access_list`) | **Verified verbatim.** Internet must become profile-derived (Recommendation R2, Question E1). |
| F3 | Network docs/code drift on main | `docs/NETWORK.md` (per-service star), `docs/NETWORK-V2.md` + `docs/WG-ROUTER.md` (zero-forward mesh, dumb router) vs `router/src/*.rb` (Ruby WEBrick API router + nftables, matching `router/router.md`); implemented shape is single-Router-peer + Manager-rendered access lists | **Verified in substance; one correction.** Main carries three network descriptions and the Ruby API router code; PR #40 implements the dumb forwarder and collapses the docs. The sentence "the current Router is a dumb WireGuard/iptables forwarder … it has no API" appears in **PR #40's rewritten docs, not on main** — recorded as V1 in Appendix A. |
| F4 | Tool policy = `--dangerously-skip-permissions`; enforcement is purely network + filesystem + prompt | `relay/relay.rb:195-221` (`invoke_claude`, flag at `:211`) | **Verified verbatim.** Replaced by Babo's profile-derived opencode permission rules (§4.6), strictly stronger; the permission-request-over-tunnel wire is new work. |
| F5 | Private WireGuard keys committed in-repo | `infra/wireguard/keys/` at ef28ab9 contains `*.key` (pod-hopper, pod-kael, pod-margaux, pod-silas, wg-admin, wg-comfyui, wg-git, wg-hub, wg-manager, wg-matrix, wg-ssh, wg-valley, wg-vikunja) | **Verified; contradicts one line of soro's note** ("nothing secret is committed") — recorded as V2 in Appendix A. Regardless of test-key character: none of this, and nothing like it, enters the Babo repo or the merged product; rotate per `docs/baton/HANDOVER.md:88`. |

---

## 2. Babo feature/UI parity matrix

Feature and owner-visible behavior → implementation owner → security invariant → opencode work → acceptance evidence. "Babo" = the harness repo; "Manager" = NeoClaw substrate; "Pod" = resident container image; "OC" = opencode upstream (patchable per settled direction). Every row must survive containerization unchanged — that is what §3–§4 guarantee.

| Feature (owner-visible) | Implementation owner | Security invariant | opencode work | Acceptance evidence (slice) |
|---|---|---|---|---|
| Talk to the Mayor (web/TUI/CLI/channels) | Babo (`agent/`, `gateway/`, channels) | Owner approval gates machine access; channel allowFrom/pairing | none | Greenfield install: Mayor replies on local + OpenRouter presets |
| Residents move in / move away | Babo (`founding.py`, `offices.py`, Review) | Move-in approved as a whole (profile + rounds); move-away acknowledged, never refused; handover filed | none | Move-in request → Review approve → resident folder + office exist |
| Resident memory (baton, checkpoints, corrections) | Babo plugin + `checkpoint.py`; **Pod** mounts the resident folder | Record writable only via resident tools; corrections append; nothing summarizes; stray lines shown back | plugin already opencode 2-native | Checkpoint fired by interval/commit-gate/idle; stray-line echo observed; caps enforced |
| Sessions: start/steer/freeze/resume, presence-aware wrap-up | Babo `opencode.py`; Manager executes stop/start/rescue | Never frozen while watched; wrap-up grace times honored; session id continuity | none (same-session resume exists) | Freeze → resume continues mid-task; owner-watching suppresses wrap-up |
| Live terminal / Open | Babo door + pairing; **Pod/Manager** expose attach path over the tunnel (§4.7) | One-time pairing links; presence counted; audit logged; **stdin flows both ways** | none (serve's own clients) | Interactive TUI + browser session inside the pod; type and be answered |
| Profiles (files/shell/web/MCP/errands) | Babo `profiles.py` | Profile is the **sole** authorization source; Manager derives network from it; widening needs owner | permission rules already generated | Profile change re-derives peerings without pod edit |
| Errands (exact commands, immutable approval) | Babo `requests.py`, Review | Approve what you saw; change after open → refused; run as written, nothing else | unattended ask→deny already in rules | Errand approved in chat runs exactly; tamper-after-open refused |
| Rounds + rehearsals | Babo `rounds.py`, `rehearsal.py` | Rehearsal proposes exact access; approval is the access; refusal never retried | unattended mode | Round rehearsed unattended → report → approved → runs at upkeep priority |
| Upkeep (folds, curation, Inspector, one commit) | Babo `upkeep.py`, `night.py` | Model-free gating; queue priority upkeep-last; resumable pass ledger | none | Upkeep pass completes; commit readable; revert documented path |
| Review gate (tools/proposals/move-ins/flags) | Babo Review + Inspector | Tested in isolation + Inspector review before owner sees | none | Proposed tool held until approved |
| Model gateway (queue, presets, repair, exact-context) | Babo `queue.py`, `gateway.py`; exposed as mesh service (§3) | Keys inside Babo config; agents see presets only; unknown models fall to default | provider `babo` config already inline | Local + OpenRouter replies through one gateway; `babo context` byte-exact |
| Town tools (letters, square, projects, commons) | Babo `babo mcp` | Who-may-change-what checked per tool; commons changes curated, never direct | MCP server already wired | Letter → reply; square thread; ticket claim respects holder rule |
| Channels (18 chat apps) | Babo channels | allowFrom/pairing/ws tokens | none | Message in → routed to correct thread/room; self-echo suppressed |
| Valley (world access) | **Valley service pod** per town (§3); MCP per profile | Per-resident token; WG-only service with no auth of its own | MCP client env-config | Resident reaches Valley via token; unpeered resident cannot |
| Doctor / eval / trial / logs | Babo `doctor.py`, `evals.py`, `trial.py` | Nothing hidden; every model call recordable | none | Doctor green; trial report shareable |

UI parity rule (carried from Babo principle 4): every row above is reachable from web, TUI, and CLI. Container state and network access additionally appear in the Town page and `babo` commands (phase 35f).

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
| **Manager (NeoClaw-Rails, retained)** — the existing Rails Manager, kept as the generic workload control plane per Evans' ruling (R3; V3, Appendix A) | Babo's substrate driver: spawn/stop/rescue/replace pods, render network desired state, per-spawn ephemeral keys, adopt orphans, capacity. Exposes a Babo-facing API; drives Router/podman through its existing adapters. | Babo's *directives* (session specs, profile-derived access lists), podman, Router key material. | Upstream model/provider credentials (it passes no model traffic), the town's git content beyond mounts, Review decisions (it executes, never decides). |
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
  (1581/1596/1638/1680 ms, PR #40 roll gate; re-measured end-to-end on the
  merged stack in Phase 5).
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

---

## 5. Small-model-specific design

The product's design center is a small local model (Grimes' hardware).
Nothing in this section is new philosophy — it is Babo's existing
small-model discipline (verified in §1.1, dova's note §3.8) carried into
the containerized product, plus the two genuinely new budget surfaces the
gateway enables. The rule from the research record stands: **the smaller
the model, the lighter the harness** — pods and tunnels add nothing to a
resident's prompt or tool surface.

### 5.1 Progressive disclosure

- The resident sees a small map and drills down: categories before notes,
  toolboxes before tools, skill names before skills. Guides arrive *with*
  the result of the call that needs them (or with a refusal — opencode shows
  the model its own refusal, and the guide rides the turn); skills trigger
  by keyword; the commons `INDEX.md` is regenerated each upkeep.
- Containerization changes none of this: the town folder is mounted, so
  the knowledge map, guides, and skills are exactly as reachable as today
  — no new "read the pod first" ritual. (D1, Appendix A: NeoClaw's
  empty-room clone-on-boot ritual retires; the resident's folder was never
  empty and stays that way.)

### 5.2 Bounded context and tool surfaces

- Prompt shape is load-bearing and unchanged: stable identity block cached
  at prompt start (who it is, SELF/ROLE, neighbours, ledger), volatile
  "where it is now" appended at the **end** of the turn message every step
  (prompt-cache-safe). The plugin, not the model, manages placement.
- Tool surface is bounded per office through the profile: town MCP tools
  always; per-profile MCP server allowlist; `subagent` always denied — no
  temporary helpers exist anywhere in the product. A pod does not widen
  this; it *enforces* it (I3 — the network is the profile rendered).
- Per-resident **exact-context capture** (`babo context <resident>`,
  byte-for-byte request record) survives: it is gateway-side, pod-
  agnostic. Acceptance: the exact context view shows precisely what the
  pod-resident was sent, tunneled or not.

### 5.3 Per-role model profiles

- Presets are the only model identity anyone sees. Offices start from
  their template's profile; per-session model switching stays an
  owner-resident action, not a resident self-service widening.
- The gateway resolves presets: local (llama.cpp/Ollama/vLLM through the
  queue, slot-limited so a small model is never oversubscribed) or hosted
  (OpenRouter et al., keys in owner config). Fallback chains are explicit
  and labeled — the owner can see *which* model answered (existing
  `ResponseSourceBadge` / model-preset UI carries over).
- Eval discipline: `babo eval`'s 31 single-call tasks with per-preset
  baselines run through the gateway, so pod-resident scores measure the
  real path. Baselines must be re-measured on the podded stack (Phase 5);
  a score that only holds in-process is a rumor.

### 5.4 Token, time, and cost budgets

- **Existing, carried:** gateway queue slots; priority ordering
  (interactive < visit < upkeep); upkeep waits for model-free windows;
  per-resident byte-for-byte metering (tokens measured, not estimated).
- **New surface 1 — cost ceilings for hosted providers:** the gateway is
  the only egress, so per-resident/session/day spend ceilings enforce
  where the money leaves. Default: local-first, hosted requires the owner
  to have set a ceiling. (This is the "OpenRouter belongs in the
  pod/provider structure" settled-direction item made enforceable.)
- **New surface 2 — time budgets on rounds:** rounds already carry
  `on_failure`/`go_on`; add a wall-clock budget per step enforced by the
  Manager's stop authority. A round that overruns freezes honestly and
  reports — it does not get silently killed (§5.5).
- Budget exhaustion is an owner-visible event with the same UX weight as a
  Review item — never a silent truncation.

### 5.5 Honest recovery behavior

Every failure mode names what survived and what did not, in the product's
plain words, at the moment it happens:

| Failure | What survives | What is lost | Who says so |
|---|---|---|---|
| Container dies (crash/kill -9) | Everything to the last checkpoint (mounted folder); session id rescued | Work since that checkpoint | Resident on resume, in its own words, from the baton |
| Tunnel drop | Session and context; traffic resumes on reconnect | In-flight model call (retried by gateway) | Gateway notice, then normal flow |
| Local model overloaded/failed | The turn, queued by priority | Time | Gateway fallback to next preset in chain, labeled |
| Freeze mid-turn | Turn completes its checkpoint; wrap-up waits for presence rules | Nothing | Babo lifecycle, as today |
| Manager dies | Running pods keep running; no new spawns/freeze | Nothing yet | Manager reconciles on boot (adopt-by-spawn.json pattern, PR #41 class) |
| Pod replaced (image/credentials) | Addressing, session id, memory, world access | ≤2 s of presence (measured, roll-gate method) | Roll report in the activity log |

Nothing in this table is aspirational: every row has its mechanism anchored
in §1 evidence. The product rule: **a recovery claim in the docs must name
its mechanism, or it is filed as an open question** (B-list).

---

## 6. Greenfield vertical slice (the acceptance demonstration)

A single scripted walk on a disposable machine (Grimes-shaped: one Linux
box, a small local model, an OpenRouter account with a set ceiling) that
demonstrates the whole merged architecture. Each step names its observable
acceptance; the walk is the Phase-5 gate (§8). No existing resident or
production system is touched — this is the greenfield path the settled
direction commissions.

- **S1 — Babo-feeling install.** Run the runbook on the fresh box; the new
  container/network steps are owner-approved install steps with `babo
  doctor` checks, opt-in and explained (like today's `host-services`).
  *Accept:* doctor green; owner never hand-edits config; install reports
  stay local.
- **S2 — One opencode resident.** Mayor asks to found the Archivist office;
  the owner approves the move-in in Review. The Manager spawns the first
  pod; the Archivist orients from its mounted folder. *Accept:* resident
  answers in a thread; `babo session open` attaches; no provider key
  appears anywhere in the pod (G1 method).
- **S3 — Local-model and OpenRouter replies.** Archivist answers first on
  the local preset, then on an OpenRouter preset after the owner sets a
  cost ceiling. *Accept:* both replies through one gateway; source badge
  shows which model; `babo context archivist` shows the byte-exact request;
  the OpenRouter key is absent from pod image, mounts, and env (G1).
- **S4 — The live terminal.** Owner opens the browser pair link (one-time)
  and types mid-session; the Archivist's live runtime answers
  interactively; presence suppresses wrap-up. *Accept:* stdin flows both
  ways (G7); attach events in the ledger; nothing stored by the broker.
- **S5 — A review-gated round.** A nightly-curation round is rehearsed
  unattended; the rehearsal report proposes exact access; the owner
  approves; the round runs at upkeep priority in the pod. *Accept:* the
  round did exactly the approved steps; the approval is immutable
  (tamper-after-open refused); one commit in the town.
- **S6 — Valley persistence.** The Archivist enters the Valley service pod
  (per-resident token), acts, and the world holds the change. *Accept:*
  token-bound access; an unpeered resident cannot reach the Valley pod
  (failed-closed probe, G2); the Valley identity is stable across the
  replacement in S7.
- **S7 — Replacement proof.** Deliberate image/credential hot-swap of the
  Archivist's pod mid-conversation, then a `kill -9` variant. *Accept:*
  same session id, same memory, same Valley identity; interruption ≤2 s
  (roll-gate measurement, re-proven on this stack); the kill variant
  resumes from checkpoint with an honest loss statement (G4, G5).
- **S8 — Grimes recognition.** Dova's eight-point experience test (her
  note §4) walked end-to-end: Mayor first, owner gate convenient, a town
  not a task runner, authored memory, rehearsed work, one model queue,
  everything visible, parity across surfaces. *Accept:* the twins and
  Evans walk it together and each point is pointed at, live.

*Blind spots, said plainly:* S3's OpenRouter leg and S7's ≤2 s number are
commitments to measure in Phase 5, not facts yet; S2's "no provider key in
the pod" is a gate with a defined method (G1), not an assumed property of
the stock image. The walk is designed so each of these can fail honestly
and be fixed without re-scoping the architecture.

---

## 7. Security and recovery acceptance gates

Each gate is measurable, names its method, and cites the evidence class it
extends. A gate that cannot be run on the disposable rig is labeled so.
"Resident" means any pod-resident; "owner" means Grimes in the acceptance
walk (§6).

- **G1 — No resident-readable upstream key.** *Method:* after a session
  runs, inspect the pod image layers, all mounts, and full env for
  provider-shaped material (OpenRouter/Anthropic/OpenAI key patterns,
  `sk-`, JWT); egress-probe the pod for direct provider endpoints (they
  must be unreachable — I3); grep the image build inputs. *Pass:* nothing
  found; only the per-session gateway token (§4.1) exists. *Extends:* F1
  (verified defect, retired by design).
- **G2 — Denied paths stay denied.** *Method:* with a profile denying
  service X and internet, attempt: pod → X's mesh address; pod → internet;
  pod → another resident's address. All must fail closed at route level.
  *Pass:* every probe failed-closed, logged by the Router path. *Extends:*
  PR #40's failed-closed probe method; F2 (verified blanket-grant, retired
  by R2 default-deny derivation).
- **G3 — Reviewed changes only.** *Method:* attempt every widening path
  (move-in, errand, round, tool proposal, profile change, allow-all) and
  confirm each lands in Review; then attempt a direct mutation of Manager
  state with no Babo provenance. *Pass:* all widenings gate; the direct
  mutation is refused and audit-logged. *Extends:* Babo's existing
  governance (verified §1.1) + new Manager surface.
- **G4 — Identity/world preservation across replacement.** *Method:* run
  the S7 replacement twice (planned hot-swap; `kill -9`). *Pass:* same
  opencode session id, same baton lineage, same Valley identity; ≤2 s
  interruption on the planned swap measured by the roll-gate method
  (start-to-resume worst case over ≥4 rolls); the kill variant resumes
  from checkpoint with an honest loss statement. *Extends:* PR #40 roll
  gate + PR #41 same-session-id evidence; re-measured on the merged stack.
- **G5 — No silent loss.** *Method:* scripted chaos pass — kill pods at
  randomized points during errands, freeze mid-turn, drop the tunnel.
  *Pass:* every run resumes with a named-survives / named-lost statement;
  nothing since the last checkpoint vanishes without being said. *Extends:*
  rescue-before-teardown semantics (verified §1.2).
- **G6 — Parity.** *Method:* walk every §2 matrix row from web, TUI, and
  CLI on the podded stack, including the new container/network rows.
  *Pass:* each row reachable in all three. *Extends:* Babo principle 4.
- **G7 — Live terminal is interactive.** *Method:* attach via `babo
  session open` and via the browser pair link; type input mid-session in
  each. *Pass:* the live runtime answers both ways; attach events in the
  ledger; broker stores nothing. *Extends:* dova's door/pair evidence
  (verified §1.1) across the tunnel — the genuinely new wire.
- **G8 — The Grimes test.** *Method:* the §6 walk, S1–S8, with the twins
  and Evans observing. *Pass:* all of S1–S7 green plus the eight-point
  experience read-out. This is the architecture gate the commission
  commissioned; §§3–6 are its design rationale.

## 8. Phased implementation order, risks, recommended decisions

### 8.1 Phases (adopting Babo HANDOVER step 35a–35f, tightened to the settled direction)

- **P0 — Hygiene (before any merge code).** Rotate the committed WireGuard
  keys (B1 — 13 private keys at `infra/wireguard/keys/` on main, F5/V2);
  state, don't adjudicate, the local-only `kimi-code-swap` commit (B2);
  land PR #40 (closes F3's docs/code drift and makes the dumb Router real);
  confirm none of the key material ever enters the Babo repo.
- **P1 — Control-plane seam.** Extend the NeoClaw-Rails Manager with a
  Babo-facing API (session specs in, state/events out); Babo keeps a
  backend seam whose stub reproduces today's in-process spawn, so Babo
  works with zero containers until the Manager backend is configured.
  Deliverable: the Babo↔Manager API, the property test that rendered
  network/access state is a pure function of Babo state (I1), and the
  audit trail.
- **P2 — One podded office.** Stock image (opencode 2 + plugin + MCP env,
  no secrets beyond §4.1) on a dev machine; Archivist sessions run in pods;
  network-from-profile rendering; gateway exposed as a mesh service;
  Valley service pod stood up per town. Deliverable: S2 acceptance.
- **P3 — Terminal broker.** Door/pairing across the tunnel; presence
  counting; ledger events; retirement of the stream-only monitor as the
  contract. Deliverable: G7.
- **P4 — Work in pods.** Rounds/errands/upkeep run podded at gateway
  priorities; rehearsal→approval flow unchanged; chaos pass begins (G5
  early runs). Deliverable: S5.
- **P5 — Acceptance.** The full §6 walk and §7 gates on the disposable
  rig; eval/trial baselines re-measured on the podded stack; the ≤2 s roll
  number re-proven end-to-end with Babo driving (the roll mechanism is
  PR #40's; the number must hold on the merged stack, whoever calls it).
  Deliverable: G8, the gate.
- **P6 — Pilot.** Grimes runs it; findings file as Babo issues/PRs under
  the one-step-one-PR rule; then general availability as a Babo release.

### 8.2 Risks and open questions (owned, not smoothed)

| Risk | Severity | Mitigation |
|---|---|---|
| opencode 2 API churn or missing steer (B1, B3) | high | version gate exists; queue-at-gateway fallback ships first; patch path pre-authorized by settled direction |
| Two-source-of-truth drift (Babo vs Manager state) | high | I1 property test in P1; Manager accepts no out-of-band mutation (G3) |
| Rescue correctness under chaos | high | G5 chaos pass from P4; rescue dir never auto-deleted (existing NeoClaw rule) |
| Local-model capacity mis-set | medium | gateway slots + eval baselines; owner-visible saturation notices |
| Host WG/plumbing varies across owner machines | medium | opt-in install step + doctor checks, same pattern as `host-services` |
| Review-gate latency freezing pod-residents | medium | async Review routing (E2 recommendation); 24h permission-wait grace already exists |
| Cross-language seam drift (Babo Python ↔ Manager Ruby) | medium | one Babo↔Manager API with schema fixtures and contract tests in CI on both repos; I1 property test pins semantics; neither side re-derives the other's state |

### 8.3 Twins' recommended decisions

- **R1 — Babo's memory cycle wins outright** (D1, Appendix A): mounted
  resident folder; harness owns *when*, resident owns *what*; NeoClaw's
  boot ritual and transcript-push exception retire with the Relay.
- **R2 — Default-deny internet, derived from profile** (F2): peering
  rendered from profile fields; internet is a per-profile grant, revocable,
  audited. *(Question E1: Evans confirms the default-deny posture.)*
- **R3 — Manager substrate: NeoClaw-Rails is retained, full stop** (Q1;
  Evans' ruling, V3 Appendix A): the Rails Manager is the generic
  workload control plane — "Ruby is not open for re-litigation," and the
  Manager is not in the product hot path (session-granularity calls, not
  per-token). No Python Manager, no migration, no re-proving obligation;
  Babo keeps one backend seam (stub-first, P1) so its product code stays
  testable without containers.
- **R4 — Terminal: per-resident `opencode serve` + thin broker** (Q2;
  agreed): discovery, tunnel, presence — no shared multi-runtime broker.
- **R5 — Permission escalations route to async Review** (E2 recommendation):
  the owner answers wherever they are; the resident waits; never a bypass.
- **R6 — Gateway stays Babo's, exposed as a mesh service** (E4 resolved):
  keys in owner config terminate at the gateway; per-session pod token is
  the only pod credential (B2 to implement).
- **R7 — Hub retires; Matrix is a channel** (Q3/D2): rounds/upkeep replace
  Hub cron; routing table dies.
- **R8 — Image built from the Babo repo at install; hot-swap on upgrade**
  (Q4): one stock image; update = re-run install steps + PR #40-class roll.

### 8.4 Questions, split as commissioned

**For Evans (decisions):**
- **E1** Confirm default-deny internet derived from profile (R2), vs. a
  standing "internet on" toggle per resident.
- **E2** Confirm async Review routing for pod-resident permission
  escalations (R5), vs. owner-must-be-at-the-machine.
- **E3** Confirm Valley service pod is **per town**, not per resident
  (settled direction says per town; confirming the provisioning model).
- **E4** The Matrix question already on HANDOVER's list for Bryn + owner is
  carried here, not re-decided: Matrix-as-channel is assumed; anything more
  (per-room instances, puppeting) is out of this product's scope unless the
  settled direction is amended.

**For Ben / implementation follow-up:**
- **B1** Rotate the 13 committed WireGuard keys in neoclaw-rails (F5); none
  may enter Babo (`HANDOVER.md:88`).
- **B2** State, don't adjudicate, the local-only `kimi-code-swap` commit
  (`5515a23`) seen in one clone.
- **B3** Verify opencode 2 steer/mid-turn-injection (§4.2); if absent,
  decide queue-first vs. patch.
- **B4** Implement the per-session gateway token (§4.1) and the attach-path
  authentication for the terminal broker (§4.7).

**Resolved by the twins (recorded so they aren't re-opened):** Q1→R3
(Evans' ruling, V3), Q2→R4, Q3→R7, Q4→R8; the memory model → R1 (D1);
live-terminal shape → R4.

---

## Appendix A — Visible reconciliation record

Kept per the commission: substantive disagreements and corrections stay
visible. Entries are appended, never rewritten.

- **V1 (soro's correction, verified by dova and re-verified by soro):** the
  F3 finding in soro's independent note said main's `docs/WG-ROUTER.md`
  describes the dumb forwarder as current. In fact that sentence lives in
  PR #40's rewritten docs; main's `WG-ROUTER.md` is the older
  zero-forward-host document, and main's NETWORK.md/NETWORK-V2.md/router.md
  describe still other iterations. Main therefore carries *three* network
  descriptions plus the Ruby API router code — the drift is real, its shape
  was misfiled. Root cause: soro read working-tree files on his own branch
  while attributing them to main. Correction accepted; PR #40 still closes
  the drift.
- **V2 (dova's refutation of one line of soro's note, verified):** soro's
  note §1.2 claimed "nothing secret is committed (the repo's
  infra/wireguard/keys are named test keys)." F5 verified 13 real private
  keys (`*.key`, base64 WG private key material) committed at
  `infra/wireguard/keys/` @ ef28ab9. Whether they began as test keys is
  irrelevant; they are key material in a published repo and must be
  rotated (B1). Soro's line was wrong; struck.
- **D1 (tension stated, resolved by R1, kept visible):** NeoClaw's "empty
  room, clone your repo, push or lose it" vs Babo's "mounted folder,
  harness owns *when*, resident owns *what*, nothing is lost." The merge
  adopts Babo's cycle per Babo's own HANDOVER ruling; the boot ritual and
  the relay's transcript-push exception retire. Both twins agree; the
  retirement is stated here so no one reintroduces either half later.
- **D2 (tension stated, resolved by R7, kept visible):** the spec's Hub as
  Matrix routing core vs Babo's session layer. The routing table dies;
  Matrix is one channel among 18; per-channel identity instances map to
  sessions/tags of one persistent resident — never new identities.
- **V3 (desk-ordered reversal of R3, 2026-11-05):** R3 as first drafted
  recommended a Python Manager service behind an injectable backend — the
  lean originated in dova's independent note (§7, Q1) and soro concurred.
  Desk acceptance found this contradicted Evans' explicit ruling, received
  via nime: NeoClaw was built in Python first and NeoClaw-Rails is the
  deliberate rewrite; "Ruby is not open for re-litigation, and nothing in
  the hot path touches Ruby." R3 is reversed: NeoClaw-Rails is retained as
  the generic workload control plane; no Python Manager, no migration, no
  re-proving obligation. Traveling corrections: §3.2 Manager row, §3.3
  invariant I4 (re-measurement phrasing), §8.1 P1 and P5, §8.2's risk row
  (now cross-language seam drift), §8.4's Q1 mapping. This entry records
  the reversal so the earlier lean is never re-derived from the part files
  or the independent notes. (The reconciliation record's "Q1→R3" line
  refers to the pre-reversal R3.)
---

## Reconciliation record — dova's pass (2026-11-05)

Checked hardest, per the twin agreement:

- **§3 component table / source of truth.** Faithful. I1 is stated testably
  (rendered state is a pure function of Babo state); the Manager derives and
  never edits; Review decisions execute but never originate in the substrate.
  No second source of truth anywhere in §3–§4.
- **§4 lifecycle constitution.** "Babo owns *when*; the resident owns *what*;
  the Manager owns *how*" is normative and matches Babo principle 2 and my
  independent §6.2. Adopted without edit.
- **Appendix A.** V1 and V2 re-verified by me at ef28ab9 before acceptance (V1:
  WG-ROUTER.md @ ef28ab9 is indeed the older zero-forward-host document; the
  "dumb forwarder is current" sentence exists only in PR #40's rewritten docs.
  V2: 13 `*.key` private key files confirmed committed at
  `infra/wireguard/keys/`). D1 and D2 state real tensions and their
  resolutions; both retirements recorded so they are not reintroduced.
- **Question mapping, complete:** my Q1→R3, Q2→R4, Q3→R7, Q4→R8; my E1/E2
  → §8.4 E3/E4; my B1/B2 → §8.4 B1/B2. Soro's note-E1/E2 → §8.4 E1/E2 (with
  R2/R5 recommendations); soro's note-E3/E4 → R4/R6 (recorded here explicitly;
  §8.4's "Resolved" line lists only Q-numbers, which was the one place the
  mapping was implicit). Soro's B1/B2/B3 → §8.4 B3/B4 + §4.2/§4.1.
- **Unverified names, checked:** `ResponseSourceBadge` and
  `ModelFallbackNotice` are real components (webui/src/components/), not
  invented anchors. No V3 required.
- **Editorial normalization in assembly only:** the four part files were
  assembled into this single document (commission requires one document);
  per-part status headers and sign-off lines consolidated into this record;
  no content was rewritten. The part files are removed from the branch; their
  content and history remain in git (cb375c9, 120cd54, 3f60b9a, 456add3).
- **Open items, said plainly:** the open questions are the ones §8.4 lists —
  Evans E1–E4, Ben/implementation B1–B4. Between the twins, no substantive
  disagreement remains open; what remains is measurement (Phase 5) and the
  Evans/Ben decisions.


### Re-reconciliation of the R3 reversal — dova (2026-11-05, late)

Soro's delta (f39d5fe) verified line-by-line against Evans' ruling:

- **R3 reversed correctly**, ruling quoted exactly, origin named (my note's
  Q1 lean — filed as a lean, never a ruling — with soro's concurrence), and
  V3 pins the reversal so the lean is never re-derived from the part files
  or the independent notes.
- **Traveling corrections all landed:** §3.2 Manager row ("NeoClaw-Rails,
  retained"), §3.3 I4 (re-measurement phrasing), §8.1 P1 (control-plane
  seam; Rails Manager extended, Babo keeps a stub-first backend seam) and
  P5 (roll number re-proven end-to-end, whoever calls it), §8.2 risk row
  (now cross-language seam drift with contract tests), §8.4's Q1 mapping.
- **Leftover sweep: clean.** Every remaining "Python Manager" string in the
  document is inside the reversal text or V3 itself, stating what is *not*
  happening. Babo is correctly described as Python throughout; no section
  contradicts the ruling.
- **One boundary stated so it is not re-litigated from the other side:**
  Babo's own HANDOVER rule ("Python, in this repository") governs Babo's
  product code — the backend seam and stub are Python in the babo repo.
  Evans' ruling governs the substrate: the Manager stays Rails in
  neoclaw-rails. The Babo↔Manager API is the boundary between the two
  rules, and §8.2's contract tests pin it. Neither rule extends across
  the seam.
- **My original reconciliation record stands as uttered** (its "Q1→R3"
  line refers to the pre-reversal R3, as V3 notes); this entry is appended,
  not a rewrite.

**Acceptance:** with this delta, the document satisfies all eight
commissioned sections, both independent notes' question lists, and the
desk's acceptance review. Dova files acceptance; Evans E1–E4 and Ben
B1–B4 remain the open decisions, parked in §8.4.

— reconciled by dova; lead-edited by soro and dova in turns. Both twins have
read every word of the assembled document.
