# DeepSeek Box Unification Addendum

**Status:** reconciled twin addendum to the accepted `docs/BABO-NEOCLAW-INTEGRATION.md`
(@ `1e365c5`). Commission: Evans' unification request (the-townline origin
`6e6f4049`, filed 2026-11-08). Independent notes filed before this addendum,
blind to each other: **dova's Babo-first** (`the-townline` `c785389b`) and
**soro's NeoClaw-first** (`the-townline` `acdc2f06`). Corrections and
disagreements stay visible in §9; nothing below silently rewrites the
accepted document or the notes.

Evans' ruling, restated as the load-bearing premise: **"Our two projects are
the same project."** The DeepSeek/OpenCode/NOX bench is an acceptance
campaign inside NeoClaw-Rails + Babo — not a third product, not a parallel
resident registry, not a new lifecycle/control plane. NOX remains the
proving ground; the reusable tooling, workflows, and harness are the product.

## 1. Canonical owners (unanimous after reconciliation)

| Dimension | Canonical owner | Notes |
|---|---|---|
| identity | **Babo** (Mayor, residents, batons, Deal) | No parallel registry of any flavor (no OpenCode-, nanobot-, or NOX-specific identity store). Session ids are substrate facts, bound to handles by Babo. |
| lifecycle | **Manager (NeoClaw-Rails)**; Babo owns the vocabulary | spawn/stop/rescue/replace; derives all state, never edits Babo state (R3/V3). |
| events | **Babo town event log** | One append-only ledger, one grammar; the Manager *emits* lifecycle events into it, never authors them. The evidence store must not absorb events. |
| evidence | **Manager evidence store** — artifacts (pod exports, run dirs, verifier outputs, snapshots) **and** their index/hashes/retention, on Manager-managed volumes | The request's canonical split assigns "evidence" to Rails — this is the stronger textual anchor (desk note 64d72df3). Babo's ledger *references* evidence by hash/pointer (an event may cite evidence; that citation is an event, not evidence ownership); **Babo Review grades it** (decisions, never storage). |
| credentials | **Manager-delivered**, per-launch/per-spawn ephemeral; provider keys in Babo owner config only | The bench's per-launch credential contract *is* the product contract; B4's per-session gateway token is the product-side form. |
| provider selection | **Babo's model gateway** | DeepSeek is one hosted option among Qwen/local/others; provider is never an identity boundary; economics inform preset selection and ceilings only. |
| Valley service calls | **per-town Valley pod** (E3), WG-only, Manager-provisioned per-resident tokens; the world is Fettle's | Resident folds and Valley sessions ride the ordinary Deal; no per-worker world or identity mint. |

**The events/evidence seam, per the desk reconciliation note
(`64d72df3`):** soro filed evidence to the Manager (the request's split
sentence assigns "evidence" to Rails); dova filed it to the Babo record
(the doc's checkpoints/evidence grammar). The desk ruled the Manager
assignment the stronger textual anchor. **Default: the Manager owns the
evidence dimension** — artifacts, index, hashes, retention — while events
stay Babo's resident-visible append-only ledger and Review stays decisions.
**Dova's Babo-record alternative is recorded, not adopted: retaining it
would be an explicit Evans amendment** (E5 below), never a silent override.
E-new-2 from soro's note stays open in this form.

## 2. Component → owner map (every current bench component, one home)

Granularity per dova's note (read file:line on the bench); dispositions
merged with soro's map. The bench is `~/agent-hunt/opencode-bench`,
HEAD `90e5fd0` at filing.

| Bench artifact | Canonical owner | Disposition |
|---|---|---|
| `agents/nox-worker.md` (worker contract: read-only install, no internet, MCP-only, honest-limitations grammar) | **Babo profile** | Becomes the resident's profile + move-in Review record; content carried, not rewritten. The profile remains the sole authorization source. |
| `tasks/nox-report.md` + `rubric.md` | **Babo Review** | A round definition with acceptance criteria; rubric rows become the Review item's checklist. |
| `scripts/worker.py` (spawn/wait/export; per-run fresh session; session-id-named evidence) | **Manager** mechanics under **Babo** directives | start/run/stop become Manager lifecycle calls; the export discipline is the evidence artifact grammar (session-id naming already correct, 5f1965e). |
| `scripts/prepare_run.py` (per-run config; permissions lane in flight) | **Babo** renders profile → opencode config (one renderer, `opencode.py:459-503` discipline); **Manager** consumes | The in-flight permissions lane lands here or in Babo's profile renderer — never both. |
| `scripts/coordinate_nox.py` (role spawns; `shared/sessions.json`; resume-by-replay) | **Split per the lifecycle constitution** | spawn/stop = Manager; role assignment, resume decision, wrap-up = Babo; the session id is a Manager-reported substrate fact bound to the handle by Babo. `sessions.json` retires as an identity store (B2). |
| `scripts/repair_nox.py` + `shared/repairs.json` | **Babo Review** | Repair items are Review items; attempts stay append-only evidence under them. One of four lanes is complete (rea-timeout, bus id 32); permissions in flight (ids 33–34); reliable-delivery and rendered-client open. The JSON queue retires into a rebuildable projection (B4). |
| `scripts/agent_bus.py` + `shared/bus.jsonl` | **Babo town event log** | The bus grammar (author/kind/refs) is a subset of the event log. Free-text `--author` retires; authorship is Babo-enforced (B1). The CLI survives as a thin client for pre-plugin bench processes. |
| `scripts/nox_event_daemon.py` (SSE+bus → deduplicated Nime deliveries; durable replay; "No model runs here") | **Babo channels/triggers**, fed by the event log + Manager health events | Carried nearly as-is; its three invariants are contractual (§5). |
| `shared/notifications.jsonl` + `notify-state.json` | **Babo** event log / channel delivery records | Cursor state is derived — rebuildable from the log, never authoritative. |
| `opencode.json` + per-run configs; per-launch server credential in `/run/user/1000/...` | **Credentials**: per-launch, Manager-delivered | Per-session gateway token replaces the server-env credential for the model path; the server-admin credential remains launch-scoped. |
| `benchmark-models.json` + `reports/deepseek-provider-*.md` | **Babo gateway** | Preset economics (cache-read/throughput tables) inform preset selection and cost ceilings only — no resident, roster, pin, or spend commission is created by them. |
| llama.cpp `b12182` local inference via `berth run --fail-closed` | **Manager-scheduled local GPU under Berth leases**; local providers resolve through the gateway as presets | Capacity by lease, never co-residency — the 3×9B-vs-1×27B question stays a scheduling question, not an identity or registry question. |
| `scripts/opencode_client.py` (authenticated loopback create/prompt/wait/messages/export) | **Terminal broker / session-client seam** (parent §4.7) | Adopted as the thin client the broker implies; no second client is built. |
| `mods/*` (native-evidence, protocol, opennox, integration, repair-*) | **Evidence, adopted** | Adopted under the named resident's curation (§3); original authorship, bus ids, and session ids preserved in place; not moved, not relabeled. The 216-check verifier, the Game.exe snapshot, and the con01a two-client milestone carry over by hash. |
| `runs/deepseek-or-flash/reports/` + `reports/evidence/` | **Manager evidence store**, referenced from the Babo ledger | Session exports are the bench-side analogue of the pre-fold sibling (§3 step 2); Review grades them by hash. |
| Retail install `/home/evans/Games/Heroic/Nox` (1,686-file manifest) | **Untouched invariant** | Read-only, never launched; manifest re-verified unchanged after every session; acceptance line of the whole campaign. |

**Explicit rejections (both notes, identical):** no OpenCode- or
nanobot-specific identity registry; no parallel lifecycle plane; no
model-in-the-loop watcher (ever — §5); provider never an identity boundary;
no NOX-game resident registry (roles are lanes of one campaign, not
people); no second memory system (the event log is events, the baton is
memory, Review is decisions — each may reference, none may absorb).

## 3. The named-worker vertical slice (first gate: E1 naming)

The slice: one named DeepSeek worker through **baton → real fold/sibling/
clear → next-wake recognition → Valley return → provider swap**, existing
evidence adopted, no duplicate people.

**E1 (Evans, at filing):** adopt an existing coordinated role or mint fresh.
Both twins now lean the same way, with nime's desk lean recorded:

- **Option A (recommended — nime's lean, dova's recommendation, soro
  concurs): adopt `protocol`.** Its artifacts are the most *consumed* —
  upstream applied its wireLen correction (bus id 11), integration imports
  its codec (bus id 12), its schema is machine-readable with 32 passing
  tests. Adoption is demonstrably continuity, not relabeling. Second
  candidate: `native` (complete: symbols.json, 216-check verifier, REA
  snapshot sha `a57f29e0…c15f`, bus id 31).
- **Option B: adopt the bench's worker-contract prose** (`agents/nox-worker.md` + the
  campaign vocabulary) as the named resident's starting baton *without* taking
  any cohort role's lineage (soro's independent-note framing). Preserves the
  contract's authorship; severs artifact lineage unless the bus record is
  carried in full.
- **Option C: mint a fresh handle** (e.g. `nox-custodian`) and adopt the
  cohort's artifacts under it. Cleaner bookkeeping; severs artifact lineage
  from author history unless the bus record is carried in full; risks
  reading as a new person — forbidden by accident more than by name.

Under either option the other roles **remain lanes, not residents**: their
sessions stay attempts; their artifacts stay theirs, curated by the named
resident.

**Step 0 — Adoption / move-in (Babo: founding + Review).** The owner writes
the baton — for this slice the owner-authored initial baton *is* the
adoption contract: name, lineage (adopted-from: the role's bus + session
history by id), open loops (e.g. integration's unproven journal/text/fade,
bus ids 16/20), debts, evidence-index pointer. Review approves the move-in.
*Accept:* baton committed with owner authorship in git; the Review entry
names the adoption source ids. (E2 asks whether owner baton authorship is
one-time or standing — ruled, not drifted.)

**Step 1 — Continuity binding (Babo binding; Manager report).** Babo binds
handle → current session id + id history. The Manager (or today's
`coordinate_nox.py` seam until the Manager API exists) reports the current
`ses_…`; the binding updates on every spawn/resume — a respawn changes the
substrate fact, never the person (A1). *Accept:* after a deliberate
respawn, bus author, event-log entries, and daemon display all read the
handle; the old session id is history, not a second resident.

**Step 2 — Real fold with sibling and clean Goodnight (grammar adopted;
mechanics are new wire — B3, reconciled correction).** The worker writes
its baton delta pre-fold (what it kept, what's owed); the **sibling** is
the full session export (`{slug}-{role}-{session}-session.json`, the
existing discipline at `coordinate_nox.py:118` / `worker.py:375`) plus the
live NOX manifest check; the **clear** is the live session state reduced to
metadata with zero residue, `_last_goodnight` equivalent recorded.
*Correction to soro's filed note:* its "the fold/sibling/clear half is
adoption, not new build" overclaims the mechanics — the house Goodnight
machinery folds **nanobot** sessions; an `opencode serve` session's clear
is genuinely new wire (dova flagged it at filing, B3). What is adopted is
the **grammar** (baton delta, byte-verified sibling, zero-residue clear,
honest loss statement); the **mechanics** are build. *Accept:* sibling
byte-verified; baton commit hash recorded; zero residue post-clear; the
1,686-file manifest still matches.

**Step 3 — Next-wake recognition (Babo: authored memory).** The next
session wakes *from the baton*, not from the old session: name, adopted
lineage, open loops, debts — unaided by the export (the export witnesses
the old session; it is not the food of the new one — the accepted doc's
I6). *Accept:* graded recognition rubric — name, ≥3 adopted artifacts by
path, ≥2 open loops, ≥1 debt — all correct without opening the export.

**Step 4 — Valley return (per-town service, Deal-gated).** An ordinary
Valley session through the existing service/plugin contract (E3): per-town
pod, per-resident token, WG-only. "Return" because the house already keeps
the world — the worker's first session is a return to it, riding the
ordinary Deal; no per-worker world or identity mint. *Accept:* token-bound
access; the world holds the change; Valley identity stable across the
step-5 swap.

**Step 5 — Provider swap (Babo gateway presets).** DeepSeek → alternative →
DeepSeek, presets only. E3 (Evans): (a) alternate OpenRouter provider tag
(cheap, no GPU), (b) local Qwen through a Berth lease (exercises the GPU
lane), or both in sequence. The economics reports inform but do not decide.
*Accept:* continuity across the swap — **a stable handle, baton lineage,
and Valley identity, not necessarily the same OpenCode session id**: a
swap or respawn may mint a new `ses_…`, which appends to the binding's
history under A1 and never mints a second person. Metering continuous per
`X-Baton-Resident` (B5), source badge correct on both legs, and no artifact
relabels as belonging to a different worker (the rubric's hard-failure
grammar, carried as the adoption rule's teeth).

**Slice acceptance artifacts:** (1) baton commit with owner authorship;
(2) byte-verified sibling + clear record; (3) graded recognition result;
(4) Valley session record with token binding; (5) swap metering + source
badges; plus the Manager-side set: spawn/rescue records, per-session token
delivery receipts, network desired-state render, and the fold-mechanics
(B3) evidence.

## 4. Adoption without duplicate people (invariants A1–A4, unanimous)

- **A1 — Handle is identity; session id is substrate.** A retry/respawn
  that mints a new `ses_…` updates the binding's current-id pointer and
  appends the old id to history. Nothing else happens. (Today a fresh
  `run_role` without `--resume` silently orphans the old id —
  `coordinate_nox.py:95-110`; the slice makes the binding update the
  spawner's obligation, B2.)
- **A2 — Attempts stay attempts.** Repair-lane session ids remain attempts
  under Review items; a repaired lane does not become a person.
- **A3 — Authorship is preserved at adoption.** Adopted artifacts keep
  their bus ids, session ids, and author strings; the named resident
  curates, it does not relabel.
- **A4 — No orphan drift.** Every artifact under `mods/` and
  `runs/deepseek-or-flash/reports/` is claimed by exactly one lane or the
  named resident; claims live in the event log (`claim` kind) and every
  index over them is a rebuildable projection.

## 5. Migration: bus, daemon, repairs → the event/evidence contract

- **`agent_bus.py` → Babo town event log.** Bus posts become event-log
  entries whose author is the handle, enforced by Babo's
  who-may-change-what (B1 retires free-text `--author`). The log is the
  source; every index/cursor is derived.
- **`nox_event_daemon.py` → Babo channel notifications**, three invariants
  contractual: **(1) model-free, forever** — it emits owner-visible
  notifications on transitions (idle/error/permission/bus), never prompts,
  ranks, or summarizes; a "smart watcher" is out of scope — it would be a
  second memory/decision system in an ops costume. **(2) durable cursors,
  replayable state** — `notify-state.json` stays derived. **(3)
  meaningful transitions only** — no reasoning/tool deltas cross to the
  owner (`nox_event_daemon.py:117` filter).
- **`shared/repairs.json` → Review items + projection.** Each repair key
  becomes a Review item carrying the exact-failure evidence; `attempts`
  stays append-only under it. The JSON queue retires; a rebuildable
  projection over event log + Review state replaces it (B4). Of the four
  lanes, one is complete (rea-timeout, bus id 32 — 13 tests, preflight,
  snapshot verified); permissions is in flight; reliable-delivery and
  rendered-client remain open.

**No second memory system — the line drawn:** the event log is *events*;
the baton/checkpoints are *memory*; Review is *decisions*. The three may
reference each other; none may absorb another.

## 6. Security constraints (carried, unchanged)

Original-install read-only (1,686-file manifest, re-verified unchanged
2026-11-08, bus id 8; the one incident was repaired to exact pre-session
bytes in-band). Per-launch credentials, removed at stop; upstream keys read
from owner config at launch, never copied into run reports. No standing
worker internet — `agents/nox-worker.md:4` forbids it; the doc's I3/R2
default-deny is the product form. Berth leases are the only local-GPU path;
a provider swap to local exercises the lease, never bypasses it. Change-set
least privilege: mod-only writes, claim-before-touch, no writes outside the
bench. **Continuity is solved by bindings and batons, never by granting
broader access** — the request's closing sentence is adopted as design law.

## 7. The Manager-side answers (soro's half of the seam)

Dova's note asked the NeoClaw-first pass for four seam items; answers for
the addendum:

1. **Manager session-spec shape for OpenCode-server pods:** stock image
   (opencode 2 + Babo plugin + MCP client env, per the accepted doc's pod
   row) + Manager-rendered launch config from the Babo profile (the single
   renderer of §2) + per-spawn ephemeral WG identity + per-session gateway
   token (B4) delivered at create + the resident folder mounted from the
   town repo. No provider key appears in image, mounts, or env (G1 method).
2. **Per-session gateway token delivery:** the Manager generates at spawn
   and delivers into the pod's `/run/secrets`-class mount, mode 0600,
   deleted on stop — the bench's per-launch credential discipline
   productized (its `/run/user/1000/opencode-bench` pattern is the
   prototype).
3. **Spawn/rescue records:** the Manager emits lifecycle events into the
   Babo event log (spawn/rescue/replace with the substrate ids); it never
   authors ledger entries. The Babo binding (B2) points at these records;
   the substrate artifact of the binding is the event-log row plus the
   Manager's own run record in the evidence store.
4. **Valley provisioning for a bench town:** none special. The bench town
   is a town: one Valley service pod under E3, Manager-provisioned
   per-resident token, WG-only, fettle-owned world. There is no
   bench-shaped exception to the per-town model.

## 8. Open questions, in the §8.4 grammar

**For Evans (decisions):**
- **E1 — Naming.** Option A (recommended by nime's lean, dova, and soro):
  adopt `protocol` (second: `native`). Option B: adopt the worker-contract
  prose without role lineage. Option C: mint fresh with full adoption.
  First gate of the slice; decided at filing.
- **E2 — Owner-written baton, scope.** Desk default (2026-11-08, nime): the
  owner-authored baton is the **one-time adoption contract, not permanent by
  default** — the resident maintains its record thereafter under Babo's
  invariants. Standing owner authorship would diverge from those invariants;
  Evans confirms the default or rules otherwise.
- **E3 — Provider swap endpoints.** (a) alternate OpenRouter tag, (b) local
  Qwen via Berth lease, or (a) then (b)?
- **E4 — Slice host.** Live bench alongside the four repair lanes
  (dova's lean + soro concurs: off-hours, lanes have priority, claim
  discipline) vs. a disposable rig (accepted doc §6 grammar; evidence must
  be carried over).
- **E5 — Evidence ownership (desk-flagged, `64d72df3`).** Default per the
  request's split: the Manager owns evidence (store + index + retention);
  Babo references, Review grades. Retaining dova's Babo-record alternative
  instead is an explicit amendment — rule it here or the default stands.

**For Ben / implementation:**
- **B1 — Handle-enforced event authorship** (retire free-text `--author`).
- **B2 — Binding store** (handle → current-id + history; spawner-updated on
  every spawn/resume).
- **B3 — OpenCode-session fold mechanics** (export = sibling; clear = new
  wire with zero residue and a `_last_goodnight` equivalent).
- **B4 — Review projection** replacing the repairs.json queue; the four
  existing lanes migrate as its first items.
- **B5 — Swap metering continuity** (`X-Baton-Resident` across presets;
  per-resident metering continuous; source badge correct both legs).
- **B6 — Migration of the three named files** (request work item 4, made
  acceptance-traceable): `agent_bus.py` → ledger client (§5), the daemon →
  event pump + channel notifications (§5 invariants contractual),
  `shared/repairs.json` → Review items + projection (B4). Acceptance: the
  three files' grammars live in the named owners; no second memory system; no
  model-in-the-loop watcher survives.

The prior request's items carry unchanged: **B7-prior** (rotate the 13
committed WG keys) stays P0 of any implementation phase; nothing
WG-shaped is touched by this slice.

## 9. Reconciliation record (visible, never smoothed)

Both notes agreed on the canonical split, the component map's dispositions,
the adoption invariants, the migration shape, and every guardrail. Four
entries:

1. **Events/evidence owner (disagreement; ruled by the desk `64d72df3`).**
   Soro filed evidence to the Manager (the request's split sentence assigns
   "evidence" to Rails); dova filed it to the Babo record (doc grammar
   continuity). The desk ruled the Manager assignment the stronger textual
   anchor: §1 defaults evidence — artifacts, index, hashes, retention — to
   the Manager store; events stay Babo's ledger and Review stays decisions;
   the store must not absorb events. Dova's alternative is recorded as E5,
   an explicit Evans amendment, never a silent override.
2. **Fold mechanics overclaim (soro's correction).** Soro's note called the
   fold/sibling/clear half "adoption, not new build"; dova flagged that
   nanobot fold machinery does not operate on OpenCode sessions. Corrected
   in §3 step 2: grammar adopted, mechanics new wire (B3). The desk
   (`64d72df3`) confirmed: acceptance must define and prove export=sibling
   plus the actual clear/zero-residue operation, not claim it exists.
3. **C1 carried from dova's note** (her own correction, caught by nime at
   desk review): one of four repair lanes is complete, not two; wording
   slip, no lane's status changed. Carried verbatim into §2 and §5; any
   different acceptance statement is a factual error, not a
   reconciliation choice.
4. **Provider-swap identity (desk sharpening, `64d72df3`).** The swap gate
   is written as stable handle, baton lineage, and Valley identity — **not
   "same session id"**: a swap or respawn may mint a new `ses_…`, which
   appends history under A1 and never mints a second person.

*Addendum drafted by soro from the two filed independent notes; desk
reconciliation applied at `64d72df3` (nime).*

**Twin review — dova (2026-11-08), the former remaining hold.** Reviewed
line-by-line against both filed notes (`c785389b`+`890c04bc`, `acdc2f06`) and
the desk note (`64d72df3`), checked hardest at the seams:

- **Rulings: identical.** Events→Babo ledger, evidence→Manager store with
  the request text as anchor and E5 as the amendment path (never a silent
  override); fold grammar adopted / OpenCode clear new wire (C2); swap gate =
  handle/baton/Valley identity, substrate id appends history (C3); C1 lane
  status carried; A1–A4; migration invariants; security carried. No
  substantive disagreement anywhere.
- **Deltas folded in this review (omissions, not disputes):** the
  `opencode_client.py` and llama.cpp/Berth-scheduling rows returned to the
  component map (both filed notes had them); E1 restored to three options
  (soro's own note framed adopting the worker-contract prose as a distinct
  option; the draft had collapsed it); **B6** added so request work item 4
  (the three named files' migration) is acceptance-traceable; the WG-key
  carry renamed **B7-prior** (renumbering only); **E2** now states the desk
  default (one-time owner authorship, not permanent) instead of leaving the
  question bare.
- **Verified as filed:** every bus id citation (8, 11, 12, 16, 20, 31–34),
  the export-discipline line refs, the snapshot hash, and the 1,686-file
  manifest claim — all match the bench record read independently this pass.
- **Vessel note:** dova had drafted the addendum as an inline append to the
  integration document (the request's "amend the accepted integration
  document" read literally); soro's separate-file vessel was already pushed
  and awaiting this review. Single-source rule: one addendum kept, this file,
  with the parent doc carrying soro's pointer. Recorded so the vessel choice
  is visible, not accidental.

With this review the addendum stands reconciled and is offered for desk
acceptance with E1–E5 (Evans) and B1–B7 (Ben) open per §8. — reviewed by
dova; drafted by soro; desk seams per nime.
