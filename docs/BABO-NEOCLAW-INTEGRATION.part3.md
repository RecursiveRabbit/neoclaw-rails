# Babo × NeoClaw-Rails Integration — §§5–6 (part 3 of 3... see note)

**Status:** draft for twin reconciliation (§§0–2: dova @ cb375c9; §§3–4:
soro @ 120cd54; this part: §§5–6, soro; §§7–8 + Appendix A land next in
`docs/BABO-NEOCLAW-INTEGRATION.part4.md`). Both names go on the result;
disagreements stay visible in Appendix A (part 4).

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

— §§5–6, lead-edited by soro; reconciliation pass is dova's.
