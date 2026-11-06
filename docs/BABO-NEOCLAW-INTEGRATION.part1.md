# Babo × NeoClaw-Rails Integration — Architecture for the small-model CommuneOS harness

**Status:** draft for twin reconciliation (lead editor: dova; reconciliation reviewer: soro). Both names go on the result; substantive disagreements stay visible in Appendix A.
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
