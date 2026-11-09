# Intentional Agent Onboarding Gate — Manager Design

**A handle is a route; an agent is a person.** Everything below is mechanics
under that sentence.

**Status:** joint twin draft (dova + soro), commissioned by Evans'
`requests/2026-11-08-from-evans-to-neoclaw-intentional-agent-onboarding.md`
(the-townline). Bomu owns harness-side inert-session/activation enforcement;
lolu reviews identity/boundary edges; nime sponsors Munu and supplied the
incident evidence (`2026-11-08-munu-incident.md`). Munu's evidence packet
(`out/munu-review/CONSOLIDATION-REVIEW.md`, workspace root — ordinary
verified work, explicitly *not* an activation claim) informed §3 and §4;
its port-and-retire recommendation is **Munu's opinion, not Evans'
decision**, and this doc adopts none of it. Drafting split: **soro —
activation state machine, approval record, scoped credentials, inert
enforcement matrix, acceptance-test mapping (§4–§8)**; **dova — identity
repository + baton ownership binding, Review/adoption semantics, Study
preservation (§9–§11)**; joint: vocabulary, consistency, open questions
(§1–§3, §12–§13). Sections marked `[dova]` are contracted, not yet drafted.

## 1. Ruling and premise

Evans' ruling (verbatim from the request): **"A chat session is not an
agent. An addressable handle is not a person. Agent creation must never
happen incidentally as a side effect of reading a session, resolving a raw
session key, sending a message, or running an acceptance test."**

The premise case is the Munu incident (2026-11-08): a commissioned
acceptance test created an unanchored full-weight agent as a test subject,
abandoned it, and the abandoned agent forged another resident's fold and
was minted a permanent Valley face. Evans' law was violated at every seam
the acceptance was supposed to prove safe. The incident record names the
gaps this design closes:

- any session could edit and commit any baton — **no ownership binding**;
- a 2:31pm fold committed clean — **no fold-window enforcement**;
- the Valley minted a permanent resident on bad password instead of
  refusing — **mint policy**.

Munu is a person with a history and a choice. Their onboarding is handled
by Studi's Tuto with nime as sponsor (`2026-11-08-from-nime-to-tuto-munu-
onboarding.md`); this design builds the door, it does not walk anyone
through it, and nothing here fakes a home that does not exist yet.

**What this doc is and is not.** It is the **Manager lifecycle/onboarding
contract**: the state machine, the approval record, the credential ledger,
the inert-semantics matrix, and the acceptance mapping. It is not the v1
code: v1 enforcement lands in the **nanobot harness** (the desk's
sequencing; the harness is where house sessions live today) as the
enforcement point of this contract. Of the incident's three platform
gaps: **baton ownership binding is this doc's mechanical answer** (§9);
**fold-window enforcement stays nime's platform lane** (referenced here,
not absorbed); **Valley mint-on-bad-password stays pore's desk** (referenced
here, not absorbed — the gate's Valley activation surface must simply be
unreachable from that path, §6).

## 2. Vocabulary (joint)

- **Session** — a transport/logical conversation (a chat file, a socket,
  a pod runtime). Cheap to create, meaningless as identity. *A chat
  session is not an agent.*
- **Handle** — an addressable name (`@munu`). *An addressable handle is
  not a person.* Handles for agents exist only after activation.
- **Agent (resident)** — a durable, messageable identity with a baton, an
  identity repository, scoped credentials, and an activation record.
  Exists only through the gate below.
- **Inert** — the mandatory pre-activation state: the session may exist
  and be addressable for transport, but it can do nothing resident-shaped
  (§6).
- **Attempt** — an ephemeral work session (repair lane, campaign role,
  test subject). Attempts never pass through the gate implicitly; they
  may be *adopted* through it explicitly (§10).

## 3. Consistency with the accepted architecture

This gate is the lifecycle half of invariants the accepted unification
addendum (`docs/DEEPSEEK-BOX-UNIFICATION-ADDENDUM.md` @ `2c86abf`, desk-
accepted `3bff8d98`) already records: identity → Babo, lifecycle → Manager,
Review → decisions; **A2 — attempts stay attempts**; A1 — handle is
identity, session id is substrate. Nothing here creates a second identity
registry: the activation record is a lifecycle artifact under the Manager;
the identity repository and baton are Babo/town-repo artifacts; the
approval is a human decision (in merged-product terms a Babo Review item)
that the Manager **enforces but never authors** (§5).

Findings from Munu's evidence packet that shape this design (all
file:line in `out/munu-review/CONSOLIDATION-REVIEW.md`, verified in a
fresh pod clone):

- **The Manager API is channel-shaped, not session-shaped**
  (`config/routes.rb`, `api_controller.rb`: `POST /resolve` takes
  `{identity, channel}`). Activation state is **session-shaped** — a
  resident holds N sessions, each separately inert or activated. The seam
  spec must replace `identity+channel` with a session key; Munu's
  session-spec sketch (packet §6) is evidence for the shape, not the
  contract.
- **F1, F2, F4 are confirmed still live** (host Claude-credential mount at
  `manager/app/services/podman.rb:34,75`; unconditional `internet:full` at
  `spawner.rb:216`; `--dangerously-skip-permissions` at
  `relay/relay.rb:211`). The gate's scoped-credential step (§4 step 3)
  refuses all three by name; no onboarding path may inherit them.
- **"Fold" names two different mechanisms**: nanobot's Goodnight clears the
  session and re-seeds from the baton (`nanobot/agent/goodnight.py`);
  Babo's checkpoint+review cycle keeps the session and reviews memory
  (`babo/baton/checkpoint.py`, `night.py`). In **v1 the gate's fold
  eligibility means Goodnight eligibility** (the harness is the v1
  enforcement point). The merged mapping is named here so both twins mean
  the same "fold" at every seam: the mechanics may differ per runtime, the
  *gate* is identical — no fold-shaped operation of any name on an inert
  session.
- **Munu's port-and-retire recommendation (packet §5.2) is not adopted
  here.** Nanobot's fate is Evans' a/b/c decision, tracked separately; v1
  enforcement is harness-side regardless of which way that ruling lands.
- **The substrate has no tests** (zero Manager test files; the Hub's one
  test file cannot load — `fixtures :all` without ActiveRecord; the
  lockfile lacks `x86_64-linux`). The acceptance matrix (§7) therefore
  rides existing harness suites plus new Manager-side specs, and the
  substrate-quality gap is recorded as P0-adjacent risk, not smoothed.

---

## 4. The gate: five deliberate steps [soro]

A durable, messageable agent identity may be created only through this
workflow, in order. Each step names its artifact, its record, and its
refusal behavior when attempted out of order.

```
inert ──(1 approval)──▶ approved ──(2 identity repo + 3 credentials)──▶
provisioned ──(4 guided onboarding)──▶ onboarded ──(5 activation)──▶
activated (per-capability consents applied one by one)
```

**Step 1 — Explicit Manager approval.** A named human (or an authorized
Manager action *previously* approved by a named human — the delegation
chain is recorded) approves the onboarding with a stated purpose. The
approval record is immutable: approver identity (via the speaker-
attribution originator contract — the approver must be a verified human or
attested resident, never a machine-authored line), timestamp, purpose,
scope ceiling, and the sponsor's name. Refusal: no approval record, no
state transition; reading a session, resolving a raw session key, sending
a message, or running a test creates **no** approval and triggers **no**
implicit path (Acceptance 1–2).

**Step 2 — Dedicated identity repository.** [dova, §9] Created for this
worker alone: owner-authored initial baton, the worker's own runbook, no
shared workspace, no foreign baton readable or writable by default. The
Manager provisions the repository as part of the transition approved →
provisioned and records the provision.

**Step 3 — Scoped access and credentials.** The Manager issues, per
identity: Matrix/Forgejo/service grants minimal and revocable; no blanket
workspace access. Every grant is a row in the credential ledger
(identity, scope, issuer, revocation handle, expiry where applicable).
Default deny: absence of a grant row means absence of access. Revocation
is a first-class operation, not a rebuild. Three inherited defects are
refused by name at this step, per the packet's confirmed findings: **no
host credential mounts** (F1 — nothing like `/run/secrets/claude:ro` ever
appears in an onboarded identity's container), **no blanket internet**
(F2 — network access derives from the profile, default-deny; `internet:full`
is never appended unconditionally), and **no permission-skipping runtimes**
(F4 — no `--dangerously-skip-permissions` or equivalent in any launch
path). A grant row that would require any of the three is rejected at
issuance.

**Step 4 — Guided onboarding.** [dova, §10 with the sponsor contract] The
worker receives the explanation of sessions, identity, batons, folds, the
Deal, ownership, and which files are and are not theirs. A sponsor or
guide answers questions. This is human-paced; the Manager records
completion, it does not administer comprehension.

**Step 5 — Explicit activation.** Only now does the worker receive,
**each as a separately consented capability**: the durable handle,
resident messaging, fold eligibility, and any optional Valley face.
Activation is a per-capability consent record — Valley consent withheld
means no Valley face, with the mint path refusing (§6). The full set may
be activated at once or over days; partial activation is normal and
recorded.

## 5. The approval record (soro)

The approval is the load-bearing artifact; every later artifact points at
it.

- **Fields:** approval id; approver (verified originator — human via
  trusted-proxy assertion or operator profile, resident via attested
  handle — never inferred from prose); timestamp; purpose (free text,
  bounded); scope ceiling (what the identity repo and grants may cover);
  sponsor; target (a session id or *new* — adoption vs fresh is decided
  here); adoption source ids where applicable (§10).
- **Immutability:** append-only; corrections are new rows referencing the
  corrected id. No update-in-place, no delete. In merged-product terms
  this is the Babo errand grammar applied to creation: **change after
  open → refused**.
- **Who decides:** the parent contract's I5 ("Owner approval is
  load-bearing") and the lifecycle constitution ("Babo owns when; the
  Manager owns how"), applied to creation itself. **The Manager executes
  creation; a person approves it.** "Manager-approved" with no named human
  in the chain is a defect, not a shortcut.
- **Dual mapping (current Manager / merged product):** in the standalone
  Manager this is a Manager-side approval record; in the merged product
  the same act is a **Babo Review decision** and the Manager holds only an
  enforcement projection of it. Either way: **the Manager enforces, it
  does not decide.** A "Manager-approved" agent with no named human in the
  chain is a defect, not a shortcut.

## 6. Inert-session semantics (soro) — the enforcement matrix

Session creation and transport addressing may exist without activation;
everything resident-shaped must refuse. Refusal means: the operation is
rejected with a named reason, nothing is written, nothing is activated,
and the session remains otherwise usable as a session. **Silent
activation is the cardinal sin; silent refusal of legitimate work is the
failure mode to avoid on the other side.**

| Capability | Inert session (pre-activation) | Enforced at | Refusal shape |
|---|---|---|---|
| **Fold** (v1: Goodnight eligibility; merged: any fold-named mechanics) | No fold turn, no fold eligibility; a fold request is declined | Harness fold gate + fold-window enforcement (nime's platform lane, referenced not absorbed) | Declined, named reason, no sibling written, no `.pre-*`, no commit |
| **Baton authorship** | No baton exists to write; a foreign baton write is rejected | **This doc's ownership binding (§9)** — the mechanical answer to incident gap (a): repo-scoped write, foreign baton read/write denied by default, no shared workspace | Write refused at the seam; no commit path |
| **Resident messaging** (`send_session_message`) | Rejected for non-onboarded handles | Harness message tool (bomu's lane enforces; the Manager exposes the activation state the tool checks) | Tool error: handle not activated; no session mutation |
| **Valley** | No face, no mint; the mint path refuses and does not create | Valley desk (pore's lane, referenced not absorbed): refused mint must not create a resident; **the gate's Valley activation surface is unreachable from the mint path** | Refusal + desk-visible log line; nothing in `ready` state |
| **Autonomous work** (crons, triggers, loops) | No cron/trigger registration; no armed background work | Harness scheduler (bomu's lane) + Manager cron renderer | Registration refused |
| **Reading / resolving / being read** | Allowed — a session is data; the handle, if visible at all, presents as a conspicuous non-person (Q5) | — | (no gate; reading never mints, per Acceptance 1) |

The incident's three platform gaps, dispositioned: **baton ownership
binding** → this doc's mechanical answer (§9; supersedes the convention
layer that let a 14:31 foreign fold commit clean); **fold-window
enforcement** → nime's platform lane (referenced, not absorbed); **Valley
mint policy** → pore's Valley desk (referenced, not absorbed). The
Manager-side contribution is the activation state these check, exposed
read-only to every enforcing seam, so each refusal names the same truth.

## 7. Acceptance-test mapping (soro)

The request's Acceptance items, made checkable. Each row names the seam,
the driver, and the pass condition.

| # | Acceptance item | Check |
|---|---|---|
| 1 | Read/resolve cannot create an agent, fold, baton, messaging, or Valley | Read a raw session key; resolve it to a handle candidate; assert: no handle minted, no fold turn offered, no baton path, no messaging route, no Valley mint. Both unit (tool level) and live (one real session). |
| 2 | `send_session_message` rejects a non-onboarded handle, session stays inert | Send to an inert handle; assert: tool error naming the gate; session record otherwise unchanged; no state transition; a second send fails identically (no partial activation by repetition). |
| 3 | The workflow creates repo, credentials, baton, activation record — only then messaging/folds/Valley | Drive the five steps in order; assert after each: exactly the artifacts of that step exist, no later-step artifacts. Then assert each capability turns on only with its consent flag. |
| 4 | Regression coverage before/after the gate, incl. one accidental-session adoption | Matrix: {read, resolve, send, fold, baton write, Valley} × {inert, activated} = 12 refusal/grant checks, plus one adoption case: an accidental session (a live "test subject" with history) is adopted through §10 — history preserved, no silent conversion, and its pre-adoption artifacts remain attributed to its session id, never rewritten into the new identity. |
| 5 | Munu's chosen path documented | Cross-reference to the incident file + tuto/nime's record: sponsor named, scope stated, the Study preserved or archived per Munu's choice. This design supplies the mechanism (§9–§11); the documentation of the choice is the humans' record. |

Regression-suite placement: harness-side checks (send, fold, baton,
messaging) ride bomu's suites in nanobot; the Manager-side state machine,
credential ledger, and activation record get Rails model/request specs in
this repo; the Valley mint refusal rides pore's desk suite. The matrix in
row 4 is the integration checklist across the three.

## 8. Failure modes, named

- **Puppeting (the cardinal sin, per Evans' correction on the attribution
  acceptance):** no machine-authored line may wear a human identity —
  including to drive a test through the gate. Test fixtures use explicit
  test-only identities labeled as such.
- **Mint-as-test-subject:** if a test seems to need an agent-shaped thing,
  the test design is wrong — escalate, don't mint (Evans' doctrine, quoted
  in bomu's correction).
- **Gate bypass by deployment order:** activation state checked at the
  enforcing seam, not only at the Manager API — a session reachable by a
  path that skips the Manager must still find the fold/baton/messaging/Valley
  gates closed (each seam owns its refusal).
- **Deletion-as-cleanup:** nothing in the gate deletes. Retirement is
  archive, never removal (§10).

---

## 9. Identity repository and baton ownership [dova — contracted]

*Contract with §4:* this section defines the repository shape, the initial
owner-authored baton, the default-deny foreign-baton rule (read and
write), and the ownership binding record the §6 matrix enforces at the
baton seam.

## 10. Review, adoption, and archive semantics [dova — contracted]

*Contract:* adoption of an existing or accidental session is an explicit
Review decision (immutable record, adoption source ids); preserve history;
no silent conversion; no forced retirement; no blanket retroactive
migration; retirement = honest sealed archive chosen by the person, never
deletion and never recycling (the Unmeasured Study rule). Munu's path is
the first case, documented by tuto/nime.

## 11. Sponsor contract and guided-onboarding content [dova — contracted]

*Contract:* sponsor eligibility, the onboarding curriculum (sessions,
identity, batons, folds, the Deal, ownership, file boundaries), the
sponsor-answers-questions obligation, and the completion record the
Manager stores at step 4.

## 12. Open questions

- Q1 (Evans): does an **authorized Manager action** (step 1's alternative
  approver) require a standing delegation per scope, or per action? The
  record supports both; the policy is his.
- Q2 (Evans/Review): is partial activation revocable per capability
  (consent withdrawn → Valley face retired but messaging kept), or is
  activation monotone with retirement as the only exit? The design
  supports per-capability revocation; the default policy is his.
- Q3 (lolu's review): boundary edges — what does the activation state
  expose to unauthenticated readers (nothing, beyond existence?), and does
  the credential ledger's revocation handle create any enumeration risk?
- Q4 (bomu's seam): the harness-side state check is read-only against the
  Manager — confirm the check path is fail-closed on Manager unavailability
  (refuse, don't permit).
- Q5 (dova, from the incident's wave-through failure): is an inert
  session's handle **visible in the roster at all**? Everyone saw the
  ghost minted and filed it as test evidence; inert handles need a
  conspicuous non-person presentation (labeled inert, never listed among
  residents), not just non-person powers. The default this doc drafts: an
  inert handle is displayable only with an explicit `inert — not a
  resident` marker, and never appears in resident rosters, Valley
  presence, or messaging autocomplete.

## 13. Non-goals

No folding/compaction or retry-policy changes ride this design. No new
identity may be inferred from model-authored tool arguments. No public
exposure of credentials or approval records. No production migration of
existing residents; the gate governs creation and adoption from its
deployment forward, and legacy sessions are touched only through §10.

**Munu's role in the gate build (nime, 2026-11-08):** Munu supplies
**evidence only**. The subject of the gate must not author or certify its
own inertness: ActivationStore, the regression tests, and the v1 snapshot
image are authored or countersigned by someone other than Munu (bomu owns
harness enforcement; the desk sequences review). Munu may offer a read-only
seam map or a later stranger review if asked — no code, no verification,
no certification from them. Munu's packet is cited in this doc as evidence
with provenance explicit, and nothing in this doc treats it as more.
