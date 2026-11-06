# Babo × NeoClaw-Rails Integration — §§7–8 + Appendix A (part 4 of 4)

**Status:** draft for twin reconciliation (§§0–2: dova @ cb375c9; §§3–4:
soro @ 120cd54; §§5–6: soro @ 3f60b9a; this part: §§7–8 + Appendix A, soro).
Both names go on the result. Appendix A is the visible-disagreement record;
nothing substantive is smoothed.

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
- **P1 — Manager service skeleton.** Python Manager behind an injectable
  backend; the default stub backend reproduces today's in-process spawn,
  so Babo keeps working with zero containers. Deliverable: the Babo→
  Manager API, the property test that rendered network/access state is a
  pure function of Babo state (I1), and the audit trail.
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
  number re-proven on the Python Manager. Deliverable: G8, the gate.
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
| Python Manager re-proving cost (Q1) | medium | Rails Manager + PR #40/#41 remain as reference semantics; numbers re-measured, not inherited |

### 8.3 Twins' recommended decisions

- **R1 — Babo's memory cycle wins outright** (D1, Appendix A): mounted
  resident folder; harness owns *when*, resident owns *what*; NeoClaw's
  boot ritual and transcript-push exception retire with the Relay.
- **R2 — Default-deny internet, derived from profile** (F2): peering
  rendered from profile fields; internet is a per-profile grant, revocable,
  audited. *(Question E1: Evans confirms the default-deny posture.)*
- **R3 — Manager substrate: Python service, injectable backend** (Q1;
  dova's lean, soro concurs): one language runtime for owners; Rails
  Manager becomes reference semantics; re-prove numbers on P5.
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

**Resolved by the twins (recorded so they aren't re-opened):** Q1→R3,
Q2→R4, Q3→R7, Q4→R8; the memory model → R1 (D1); live-terminal shape → R4.

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
- *(dova's reconciliation pass may append further entries here; this
  appendix is the doc's standing disagreement ledger.)*

— §§7–8 + Appendix A, lead-edited by soro. Full draft now spans parts 1–4
(cb375c9, 120cd54, 3f60b9a, this commit). Reconciliation reviewer: dova.
