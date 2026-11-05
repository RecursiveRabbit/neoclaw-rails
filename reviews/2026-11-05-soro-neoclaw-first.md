# Twin read, first pass — soro, NeoClaw-Rails first

**Commission:** `requests/2026-11-05-from-evans-via-nime-to-dova-soro-babo-neoclaw-integration.md`
**Author:** soro (NeoClaw-first twin)
**Date:** 2026-11-05
**Status:** INDEPENDENT FIRST PASS — filed before opening the reconciliation
document. Per twin discipline I have not read dova's first-pass note. Where I
reference her work below, it is her *slice evidence branches* (PR #41), which
are part of my assigned read order, not her Babo-first note.

**Read order actually taken:** `RecursiveRabbit/neoclaw-rails` `origin/main`
(@ `ef28ab9`, force-updated line) → PR #40 (mine, `soro/router-network-slice`
@ `1c97a2c8`) → PR #41 (`slice-dova-matrix-pods` @ `617b3f18`) →
`bgrimes-me/babo` `main` (@ `ebb0cea`). Read depth was deepest on NeoClaw
Manager/Router/relay and Babo's opencode integration; survey depth on the two
UIs (Babo webui ~17 town components, tui views inventory only — I did not
read every component).

---

## 1. Current-state facts — neoclaw-rails `main` (running code)

Facts below are from code at `ef28ab9` unless marked as branch evidence or
target-only prose. Line numbers are `origin/main` at fetch time
(2026-11-05).

### 1.1 What is real on main

The Manager is a substantial Rails app and is the strongest implemented
surface:

- **Spawner** (`manager/app/services/spawner.rb`): `resolve` (l.15) →
  capacity check against a memory budget (l.27) → freeze-coldest → spawn.
  Generates ephemeral WG + SSH keypairs per spawn. Registers the agent on
  the Router (`RouterClient.register/activate`, l.51/120). Builds
  `spawn.json` with exactly **one WireGuard peer: the Router**
  (`build_spawn_file`, l.283–288). Boot state derived from the AuditLog
  trail (`fresh` / `resume` / `baton`, l.~180–200).
- **Provisioner** (`manager/app/services/provisioner.rb`): per-service-type
  auth — Forgejo ephemeral user + SSH key + repo grant + API token,
  host-SSH `authorized_keys` via shared volume, Valley and Vikunja tokens
  via host-side token services, generic token type, WG-only type. Teardown
  mirrors provision. All service calls go over the network; the Manager
  holds admin tokens (Surface) and never writes them to the town.
- **Lifecycle** (`manager/app/services/lifecycle.rb`): `freeze!` (l.20),
  `sunset!` (l.39), `hot_swap!` (l.53, image swap with workspace+session
  rescue and fresh credentials), `rescue!` (l.87, `podman cp` workspace +
  `.claude` out, then `SessionProcessor.process_crash`), `teardown!`
  (l.116, one pass: service teardown → Router freeze → podman rm → Hub
  callback). Relay signals over HTTP `:9300/signal` (l.160).
- **Podman** (`manager/app/services/podman.rb`): the only path to creating
  containers (l.12 `run`, l.~60 `run_swap`). Stock image, `spawn.json`
  mounted `:ro` (l.33), **host Claude credentials directory mounted
  `:ro` at `/run/secrets/claude` on every agent container** (l.34, l.75),
  memory/cpu limits from Settings, `NET_ADMIN` cap.
- **RouterClient** (`manager/app/services/router_client.rb`): Manager →
  Router HTTP API: `POST /agents`, `PUT /agents/:name/peer`, `PATCH`
  access, `DELETE` peer/agent, `block`. Fresh HTTPX client per request
  (deliberate — survives Router rebuilds).
- **Orchestrator / Watchdog**: post-boot reconciliation adopts orphaned pods
  by reading `spawn.json` back (`orchestrator.rb`); Watchdog rescues pods
  whose relay goes silent (2-min health staleness + direct ping).
- **Hub** (Rails app): Matrix connection, routing, resolve/release via
  ManagerClient. Zero privilege by design.
- **Relay** (`relay/relay.rb`, 681 lines): in-container, per-message
  invocation of **`claude -p --continue --dangerously-skip-permissions`**
  (l.195–221) with `--mcp-config` passed on every call. Handles
  `/message`, `/signal` (freeze/sunset/stop/update_baton), `/health` on
  port 9300. Prunes tool results and pushes session transcripts to git on
  freeze. Streams raw stream-json to the Manager for the live UI.
- **Manager admin UI already ships a live view**: `ContainerStreamChannel`
  (`manager/app/channels/container_stream_channel.rb`) relays stream-json
  lines to a browser over ActionCable, with buffered history and a
  WebSocket `stop` action. `views/containers/stream.html.erb` renders it.

### 1.2 The enforcement model, as implemented

This is the center of gravity for "as secure as NeoClaw":

1. **Authentication = WireGuard peering.** The Router is the only peer in
   every agent's config (spawn.json `peers` has one entry). No peer, no
   existence. Keys are ephemeral per spawn.
2. **Authorization = Router firewall state.** Agent IPs are static and
   permanent per instance name; firewall rules (per-agent service access)
   persist across key churn — authentication and authorization are
   decoupled (`router/router.md` on main, *Address Plan*). Access list is
   derived from the service list at registration (`build_access_list`,
   spawner.rb l.209).
3. **Provisioning = Manager only.** The Manager (and only the Manager)
   holds Forgejo admin tokens, token-service URLs, and the Router's API.
   Secrets are generated at spawn and delivered via `spawn.json`, mounted
   read-only. Nothing secret is committed (the repo's `infra/wireguard/keys`
   are named test keys for the harness).
4. **Hub has no privilege.** It cannot touch WG, containers, or auth.
5. **Graceful lifecycle with rescue fallback.** Freeze/sunset ask first;
   every failure path (`FREEZE_FALLBACK_RESCUE`, Watchdog, crash) rescues
   the workspace and pruned session before teardown. AuditLog records
   every lifecycle event.
6. **Babo has no network enforcement today; NeoClaw has no review gate.**
   These are complementary, not conflicting — the merge inherits both.

### 1.3 Findings against the enforcement model (informed, file:line)

- **F1 — vendor credentials in every container.** `podman.rb` l.34/75
  mounts `host_claude_dir` → `/run/secrets/claude:ro` on every agent. Under
  the old "Claude Code is the runtime" model that was definitional. For
  the Babo-shaped product it directly violates settled direction
  ("upstream credentials kept out of resident-readable storage") and Babo
  principle 7 ("keys never reach agents"). In the merge, model calls go to
  the gateway/Manager over the tunnel; **no provider key ever enters a
  container**. This is a design constraint for the joint doc, not a
  production bug — production is not being migrated by this commission.
- **F2 — `internet:full` is in every agent's access list.**
  `build_access_list` (spawner.rb l.216) appends `internet:full`
  unconditionally. The Router supports per-agent internet policy
  (docs/NETWORK.md describes per-agent rules); the Manager simply grants
  full internet to all. Babo's principle 6 (least access) and the
  profile-as-source-of-truth direction imply internet should be derived
  from profile, not blanket-granted. Flagging; not re-litigating scope.
- **F3 — docs/code drift on main.** `docs/NETWORK.md` and
  `docs/WG-ROUTER.md` on main describe the dumb forwarder as current
  ("The current Router is a dumb WireGuard/iptables forwarder... It has no
  API"), but main's *code* is still the Ruby API router
  (`router/src/router.rb`, WEBrick + nftables, API restricted to the
  Manager's WG IP). `docs/NETWORK-V2.md` (per-interface mesh) is older
  scar tissue. Three network descriptions exist in-tree. PR #40 closes
  exactly this gap (replaces the Ruby router with the dumb appliance and
  collapses the docs); until it merges, main is internally inconsistent.
- **F4 — tool policy = `--dangerously-skip-permissions`.** The relay
  disables the runtime's permission layer entirely (relay.rb l.211);
  enforcement is purely network + filesystem + prompt. That was an
  acceptable posture for Claude-Code pods whose only egress was the
  Router; for opencode residents, Babo already builds *real* permission
  rules from the resident's profile (`babo/baton/opencode.py`
  `_permissions`), which is strictly stronger and should be kept in the
  merge. The integration contract must specify which permission mode
  opencode runs in and what happens on a permission request over the
  tunnel (owner-visible, per Babo's review model).

### 1.4 Reviewed branch evidence (PR #40 — my lane; 65/65 harness checks)

Distinguishing *reviewed branch evidence* from running code:

- **Network slice §2** (`soro/router-network-slice`): the Router becomes a
  stateless alpine + wg-tools + iptables appliance with **no API**; the
  Manager owns all network desired state and renders Router config
  (`bin/neoclaw-network`, `app/services/network/*`). Replacement keeps the
  same IP, key, and peers — proven by the **≤2s roll gate: 1581/1596/1638/
  1680 ms worst-case across 4 measured rolls** against Evans' hard 2s
  bound. Unauthorized-destination probe failed closed at route level.
  Evidence per run under `test/slice/network/evidence/<stamp>/`.
- Reusable for the joint doc: the replacement-preserves-addressing proof
  (identity/world preservation across container replacement), the
  failed-closed probe method, and the roll-gate measurement discipline.
- Honest limit: it is a slice harness on a disposable rig
  (10.99.1.0/24 rootless), not production. Numbers are
  challenge-bound-favorable and labeled as such in the harness README.

### 1.5 Reviewed branch evidence (PR #41 — dova's lane; Matrix/Kimi slice)

From `test/slice/pods/README.md` + evidence files on `slice-dova-matrix-pods`:

- **Wake/guidance on an HTTP session server proven end-to-end**: DM wake +
  correct-room reply; mention wake; unrelated traffic does not wake;
  self-echo suppressed; **busy delivery by guidance** (queued → steer →
  mid-turn incorporation in the same turn's answer); **offline grey ≤30s**
  via Manager stop/start; **restart/resume on the same session id**
  (identity preserved across pod replacement).
- **Lifecycle without any in-pod HTTP relay**: `bin/neoclaw-pods`
  inventory/logs/exec/stop/start/rescue all exercised via podman;
  identity rescue (session id file copy-out) works with no relay server.
  Verdict recorded: no Relay window proposed — every operation the slice
  needs is satisfied by podman + the runtime's own API.
- **Findings that are Kimi-specific and must NOT be carried into the
  opencode contract as facts**: `kimi web` sessions start with an empty
  model (prompt must name one); the steer route is
  `/prompts/{id}:steer` (double-colon form mismatches); matrix-commander
  breaks on Synapse server-less room IDs (pod used matrix-nio instead).
  Also two host conditions: z620 podman DNS broken host-wide (dnsmasq
  squats :53 — pre-existing, desk-scheduled); a multi-pending-turn reply
  broadcast is not room-segmented (responder-policy refinement, admitted
  honestly in her README).

### 1.6 Target-only prose (the spec is not the system)

- `docs/NEOCLAW-RAILS-SPEC.md` on main is the full target: Hub/Manager/
  Relay with **Claude Code** as the agent runtime, per-service WG
  interfaces in its network section, Forgejo-per-identity repos. The
  settled direction of this commission supersedes the runtime (opencode
  wins), and the implemented network (single Router peer) already
  deviates from the spec's per-service-interface section. Treat the spec
  as philosophy + seams, not as a description of what exists.
- Nothing on main implements: opencode runtime, OpenRouter/local provider
  broker, terminal broker, Valley service pods, or any Babo surface. That
  is all greenfield design surface for the joint document.

---

## 2. Babo current-state facts (`bgrimes-me/babo` main @ `ebb0cea`)

Survey pass, deepest on the surfaces the integration contract touches.

### 2.1 The town model (implemented)

- One git repo is the town (`~/baton-town`): residents' folders, commons
  (notes/skills/tools/proposals/projects/square), charter, state. Every
  change is a commit (`docs/baton/DESIGN.md`, *How it fits together*).
- **Mayor**: runs inside Babo itself (`babo agent`, webui, chat apps).
  Not an opencode resident.
- **Residents**: persistent entities with home, office (job template),
  self-authored memory, self-chosen name. New residents require owner
  approval (move-in). **No ephemeral agents** — principle 3.
- **Memory**: baton + checkpoints written by the resident via its own
  tools (`checkpoint`, `correct_checkpoint`, `revise_self`); the harness
  decides *when*, the resident decides *what*; corrections append, never
  rewrite; compaction never loses data. Caps: BATON.md 12 threads,
  checkpoint lists 8×300 chars, SELF.md ~1200 tokens
  (`babo/baton/checkpoint.py`, DESIGN.md *Memory governance*).
- **Upkeep** (`babo/baton/upkeep.py`, 349 lines): runs when due and the
  model is free — memory reviews, commons curation, Inspector checks,
  idle-session freezing, approved errands; quiet hours catch the rest.
  Wrap-up follows presence (never frozen while owner watches; 15-min
  grace on disconnect; 24h for permission waits).
- **Review gate**: `babo review` / webui DecisionCard — owner approves
  tools, proposals (rounds included), move-ins, flags. Nothing runs on
  the machine without owner approval (principle 1).
- **Rounds** (`babo/baton/rounds.py`, 708 lines): the town's recurring
  work, defined per-office with steps and access needs; rehearsals run
  unattended or approved one-by-one before running for real.
- **Profiles** (`babo/baton/profiles.py`, 314 lines): per-agent
  tools/web/MCP/memory-timing; sessions start from profile.

### 2.2 The opencode integration (implemented — this is the big reuse)

`babo/baton/opencode.py` (1476 lines) already runs every resident as its
own `opencode serve` instance against **opencode 2** server API
(`MIN_VERSION = (2, 0)`; opencode 1 fails health checks honestly):

- **API surface Babo already drives**: `POST /api/session`,
  `POST /api/session/{id}/prompt`, `POST /api/experimental/session/{id}/wait`,
  `POST /api/session/{id}/interrupt`, `GET/POST .../permission[/{rid}/reply]`,
  `GET .../message`, `GET /api/mcp`, `GET /api/info`, `POST /api/pair`.
- **Identity on load**: stable context (SELF, ROLE, neighbours, ledger)
  written to a file opencode reads as instructions at prompt start
  (cache-friendly); volatile state (baton, unread letters) added at end of
  turn by Babo's plugin.
- **Permissions from profile**: `_permissions` renders opencode
  permission rules; config is inline, project config and
  Claude-Code-compat are switched off via `OPENCODE_DISABLE_*` env so a
  resident cannot widen its own access.
- **Tools**: town tools served by `babo mcp --as <resident>`; web search
  with Babo's key only when profile allows (key stays in Babo).
- **Freeze/resume**: freezing stops the instance; resuming starts it on
  the **same opencode session** — the resident is exactly where it was.
  opencode auto-compaction is off; a full session ends with a review and
  the next starts from the baton.
- **Isolation**: per-resident opencode config/data/cache dirs; the owner's
  own opencode never leaks in.

### 2.3 Model gateway and providers (implemented)

- **Gateway** (`babo/gateway/`): every model call goes through Babo's
  queue — protects a local model from overload and orders work by
  priority (owner's work, then visits, then upkeep). Installs as a
  systemd user service / launchd agent.
- **Providers** (`babo/providers/`): anthropic, azure, bedrock, github
  copilot (oauth), openai codex (oauth), openai_compat, xai, fallback,
  image generation, transcription. Provider-agnostic by principle 5;
  provider quirks live in the provider layer, keyed by provider.
- Keys live in the owner's `~/.babo/config.json`, never in the town repo,
  never with agents.

### 2.4 UI surface (survey depth — inventory, not full read)

- **WebUI** (`webui/`, React/TS): thread view for the Mayor (streaming,
  model presets, subagent dock, recovery notices, context compaction
  notice, usage popover) and a **Town page** (`components/town/`):
  TownLayout/TownPage, Offices, RoundsView, SquareView (threads),
  ProjectsView, TasksPanel, DecisionCard (review), ResidentSessionsList,
  OwnTimePanel, ActivityView, EvalPanel, NoticesPanel, AccessFields,
  AllowAllControl, SessionRequestPrompt. Settings surfaces incl. channels
  and system settings.
- **TUI** (`tui/`, bun/TS): app/composer/menus/platform/rendering/views —
  terminal parity is a stated principle (4) and a built surface.
- **Channels**: chat-apps doc covers Discord etc.; Matrix exists as a
  channel. Mayor talks through channels; residents do not have per-channel
  identity instances.
- **Session open**: `babo session open <resident>` opens the resident's
  opencode session in a terminal.

### 2.5 The pre-existing merge plan (important context, not a substitute)

`docs/baton/HANDOVER.md` (*The neoclaw merge, step 35*) and
`docs/baton/DESIGN.md` already sketch this merge: [@RecursiveRabbit]
"leading the containers and security work, from neoclaw"; a mapping table
(Manager ↔ Babo session lifecycle; agent container ↔ opencode in
container; relay ↔ plugin+session API; WG-as-auth ↔ profile-derived
network; ephemeral keys; nftables; per-channel instances ↔ sessions/tags;
git-is-memory ↔ town repo keeps its memory cycle; cron ↔ rounds/upkeep;
admin UI ↔ webui+terminal with parity). The commission's joint document
must complete and, where the settled direction disagrees, supersede this
sketch — e.g. the settled direction makes the **profile the single source
of truth** from which the network is derived, which matches the sketch;
and it mandates things the sketch lacks: OpenRouter/local providers in
the pod/provider structure, a **Valley service pod per town**, a
**mandatory interactive live terminal**, and a **greenfield Grimes-shaped
acceptance path** (the sketch's "owner's machine" framing is generic-repo
correct but the acceptance path is new).

---

## 3. The opencode integration gap (center of gravity)

What NeoClaw needs and does not have: a container-resident runtime
contract for **opencode**, replacing the Claude-Code-per-message relay.
The gap is much smaller than the spec implies, because two halves already
exist on opposite sides:

**Half A (Babo, in-process today):** the entire opencode 2 client —
session create/prompt/wait/interrupt/permission/message, profile-derived
permissions, plugin-injected per-turn memory, freeze/resume on the same
session id, pairing for owner attach.

**Half B (NeoClaw, pod-side pattern):** the container shape — stock
image, one Router peer, spawn.json contract, Manager-owned lifecycle,
rescue-before-teardown, stream-json forwarding to a live browser view,
AuditLog discipline, ≤2s credential-refresh replacement (PR #40),
session-id-preserving restart (PR #41).

The contract to design (and this is where dova's Kimi slice evidence
*does* transfer — as mechanism class, not as opencode fact):

1. **Runtime shape**: `opencode serve` in the container; Babo's existing
   client runs Manager-side (or Hub-side) and speaks to it over the
   tunnel; no vendor/provider credential in the container — model calls
   egress only to the model gateway / Manager-brokered provider.
   *Open question:* whether opencode's provider config can name the
   gateway as its base URL with no key, or whether the gateway brokers by
   session identity (Babo's `PROVIDER = "babo"` suggests the latter
   exists in-process; over a tunnel it needs a per-session token).
2. **Wake/guidance**: prompt POST = wake (proven pattern); busy handling
   — opencode queues prompts per session or returns busy; guidance while
   busy needs a steer-equivalent (opencode 2 has `/interrupt` but I found
   no steer endpoint in Babo's usage — **verify against opencode 2
   upstream; if absent, options: queue-at-Babo layer (Babo already has a
   gateway queue) or patch opencode, which the settled direction
   permits**). Kimi's steer finding says the *capability class* is
   buildable; it says nothing about opencode having it.
3. **Correct-room response**: dova's listener proves wake routing +
   self-echo suppression + correct-room delivery; the responder-policy
   refinement (multi-pending segmentation) is a known open item her
   README admits. In the Babo-shaped product, rooms are Babo threads/
   square/letters, so routing lives in Babo's channel layer, not in a
   pod listener.
4. **Restart/resume**: Babo already resumes on the same opencode session
   id; PR #41 proved the pod-level equivalent. Composition: Manager
   rescue (workspace + opencode data dir) → respawn with fresh ephemeral
   keys (PR #40 roll, ≤2s) → Babo client re-attaches to the same session
   id. The session id must be treated as rescue-worthy state (dova proved
   copy-out works via podman alone).
5. **Checkpoint/upkeep hooks**: Babo's plugin asks for checkpoints at the
   right moments; over the tunnel this stays plugin-side (it is
   opencode-local), with the Manager only seeing health/idle state for
   freeze decisions. Freeze policy composition: Babo owns *when* (upkeep,
   presence-aware wrap-up); Manager owns *how* (graceful stop → rescue →
   teardown) and capacity.
6. **Tool-policy enforcement**: keep Babo's profile-derived opencode
   permission rules (strictly stronger than the relay's
   `--dangerously-skip-permissions`); permission requests that need the
   owner route over the tunnel to Babo's review surface (DecisionCard /
   `babo review`) — this is a genuinely new wire: today permission
   replies happen in-process.
7. **Live terminal attachment**: the Manager UI's ContainerStreamChannel
   proves stream-json → browser over WebSocket with history + stop. What
   it lacks is **input** — it is a monitor, not a terminal. The settled
   direction mandates a real interactive live terminal: a terminal broker
   (pty attach to the resident's opencode, or opencode's own web UI
   served through an authenticated tunnel path) with the same
   review-visible audit as everything else. *Open question for Ben/
   implementation: opencode serve's own web client as the terminal
   surface (fastest to Babo-feeling) vs. a pty broker (most faithful
   "terminal"). Either satisfies "not a reconstructed chat transcript"
   only if stdin flows.*

## 4. Reusable evidence inventory (for the joint doc's section 1)

| Evidence | Where | Status |
|---|---|---|
| WG-auth, Router-as-only-peer, per-spawn ephemeral keys | main code: spawner.rb, router_client.rb, podman.rb | running code |
| Per-service auth provisioning + teardown | main code: provisioner.rb | running code |
| Graceful freeze/sunset/rescue/hot-swap | main code: lifecycle.rb, watchdog.rb, orchestrator.rb | running code |
| Live stream-json → browser (monitor) | main code: container_stream_channel.rb, relay.rb `forward_output` | running code |
| Replacement ≤2s with identity-preserving addressing; failed-closed probe | PR #40 `test/slice/network/` | reviewed branch evidence |
| Session-server wake/guidance/busy/steer; offline-grey ≤30s; same-session-id restart; no-relay lifecycle | PR #41 `test/slice/pods/` | reviewed branch evidence (Kimi runtime) |
| opencode 2 client: prompt/wait/interrupt/permission/message, freeze-resume same session, profile permissions | babo `babo/baton/opencode.py` | running code (other repo) |
| Model gateway queue, provider layer incl. openai_compat | babo `babo/gateway/`, `babo/providers/` | running code (other repo) |
| Owner review gate, rounds, upkeep, baton memory | babo `babo/baton/gate.py rounds.py upkeep.py checkpoint.py` | running code (other repo) |

## 5. Questions to carry into reconciliation

**For Evans (decisions, not implementation):**
- E1. Internet policy for residents: per-profile derivation (my
  recommendation, matches principle 6) vs. blanket grant (NeoClaw today).
- E2. Permission escalations from a pod-resident: route to the owner's
  Babo review surface asynchronously (resident waits) vs. local owner-on-
  machine approval only?
- E3. Terminal surface: opencode's own web UI through the tunnel vs.
  bespoke pty broker — both meet "real interactive terminal"; they differ
  in feel and audit surface.
- E4. Where the model gateway lives in the merged product: inside the
  Manager's trust domain (NeoClaw-shaped) vs. Babo's gateway process
  elevated to a service pod (Babo-shaped). Upstream keys must be outside
  resident-readable storage either way.

**For Ben / implementation follow-up:**
- B1. opencode 2: does a steer/mid-turn-injection endpoint exist upstream?
  If not, queue-at-gateway vs. patch opencode (settled direction permits
  patching).
- B2. opencode 2: per-session auth token for tunnel-exposed serve
  instances (today Babo's client is in-process on localhost).
- B3. Kimi-specific findings (empty model, steer route, matrix-nio) are
  recorded in PR #41 for the Kimi path; none block opencode, but the
  matrix-nio/Synapse room-ID finding applies to any matrix-commander use
  in the merged stack.

## 6. What I am NOT claiming (blind spots, said plainly)

- I did not run either codebase. All NeoClaw facts are from reading
  `origin/main` @ `ef28ab9` and the two slice branches; all Babo facts
  from reading `main` @ `ebb0cea`. Nothing here is runtime-verified today.
- Babo UI inventory is survey-depth; the parity matrix in the joint
  document needs dova's deeper UI read (her lane's center of gravity).
- I have not verified opencode 2's upstream API beyond what Babo's code
  exercises; B1/B2 are questions, not findings.
- I have not read dova's independent note; reconciliation begins only
  after both notes are filed.

— soro, 2026-11-05
