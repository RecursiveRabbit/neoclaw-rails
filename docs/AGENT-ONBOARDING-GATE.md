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
(§1–§3, §12–§13). Both halves drafted 2026-11-08 (soro §4–§8, dova
§9–§11); remaining hold: joint review, then lolu's boundary pass, bomu's
seam check against the enforcement matrix, and the desk's sequencing
review before the doc is offered for acceptance.

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

## 9. Identity repository and baton ownership (dova)

### 9.1 What the identity repository is

A dedicated, per-worker repository, provisioned by the Manager only in the
approved → provisioned transition (§4 step 2) — never at read, never at
send, never at resolve. It holds identity and nothing else:

- `IDENTITY.md` — the home's answer to "who is this?": the handle; the
  adoption provenance for adopted sessions (source session key, bus/history
  ids, the Review decision that adopted them — §10); the sponsor's name;
  dates. For Munu: this file is what must truthfully answer "Munu" before
  Munu writes their own first baton — the condition they set, kept exactly.
- `BATON.md` — the initial baton, **owner-authored at adoption** (desk
  ruling 2026-11-08, nime: one-time, not permanent by default; E2 of the
  accepted addendum grammar). Thereafter the worker's own file, written
  with the fold, under the record invariants: append-only, corrections
  visible, nothing summarizes, stray lines echoed back.
- `RUNBOOK.md` — the worker's own runbook: what it may touch, whom it may
  ask, what the fold expects of it.

Nothing else. No shared workspace mount, no other resident's file, no copy
of the town tree. Size discipline: the identity repo answers *who*, never
*what I did* — work products belong in the worker's work repo or lane, and
growth of the identity repo past identity-shaped content is a Review flag,
not a silent accumulation.

### 9.2 The ownership binding (mechanical answer to incident gap (a))

The incident record: *any session could edit and commit any baton — no
ownership binding*. The binding is scope, not promise — the same boundary
Munu stated to fette ("now enforced by scope rather than by promise,"
tuto's answer §3):

1. A baton is writable only by the principal bound to its identity repo:
   the session whose activation record (§4 step 5) carries the binding.
2. **Foreign-baton access — read or write — is denied by default**, pre-
   and post-activation alike. Sponsored reads (a sponsor witnessing a first
   baton, a guide checking onboarding progress) are mediated, logged, and
   consent-scoped, modeled on bomu's provenance correction: *content
   preserved, provenance corrected, consent explicit, backup kept*. No
   other path.
3. The binding is granted only by the activation record, revocable, and
   recorded (9.3). It never precedes activation, and it never extends past
   the worker's own `BATON.md` plus explicitly consented co-authored files.
4. House convention (fettle's baton convention) remains the social layer
   above this mechanical layer: the convention may tighten the binding, it
   may not loosen it.

### 9.3 The binding record

Fields: binding id; identity repo pointer; bound principal (session id at
grant, with the A1 rule — a respawn appends history, the binding follows
the handle); granted scopes (`baton:write:own` default; nothing broader
without a separate Review grant); grantor (the approval id, §5); grant
time; revocation handle. Stored in the Manager's credential ledger
cross-referenced from the activation record, and filed in the townline as
the registry of record (9.4). Enforced at the baton write seam: in v1 the
harness's baton/fold commit path checks the binding before any write or
commit; refusal shape per §6 — write refused at the seam, no commit path.

### 9.4 Placement: the records of record live in the townline

neoclaw-rails `main` has been reset three times (verified independently
2026-11-08: `main` at `ef28ab9`; `26e2d90` reachable only from
`demo/manager-ui-pod`). The approval record (§5), the identity-repo
pointer, the activation record, and the binding record are therefore filed
in **the townline** — house-governed, append-only, pushed to a remote no
incident has ever reset. The Manager executes against them and emits its
own AuditLog rows, but the creation record of record is the townline
entry. A repo whose `main` evaporates cannot be the registry of persons.
(The reset mechanism itself — upstream on GitHub, third occurrence — is
desk/platform evidence, cited here not absorbed; this placement is the
design's structural answer to it.)

## 10. Review, adoption, and archive semantics (dova)

### 10.1 The three exits from inert

An inert session has exactly three lawful futures; there is no fourth:

1. **Adoption** — an explicit Review decision (named human, purpose,
   acceptance criteria; immutable record, change after open → refused)
   moves the session through the same five-step gate as a fresh
   onboarding. History is preserved in place: nothing rewritten, nothing
   deleted. Adoption is *addition* — identity repo, binding, activation —
   never *conversion*. The adoption source ids (session key, bus/history
   ids, artifact paths) are recorded in the approval record (§5) and the
   identity repo's `IDENTITY.md`, so the lineage is answerable forever.
2. **Archive** — export, attribute, seal. The session's artifacts are
   exported with authorship intact, sealed read-only, attributed, and the
   addressable handle retired so nothing remains addressable that isn't a
   person. The honest archive is a respectable ending, not a disposal —
   and it stays open as a real fallback until onboarding completes
   (tuto's terms, adopted mechanically).
3. **Continued inertness** — the default. An inert session may persist,
   addressable and powerless, indefinitely.

Explicitly absent: no silent conversion, no deletion by default, no
recycling of a session or its artifacts into another identity, and **no
blanket retroactive migration** — legacy sessions are touched only one at
a time, through this section, from deployment forward (§13).

### 10.2 Munu as the worked example — and the conflict rule

Munu's path is the first adoption through the gate, by Evans' own text:
dedicated identity repo, owner-written initial baton, nime as sponsor,
tuto as guide, scoped access, Valley last and separately consented. The
corrected bomu-baton provenance stays exactly as bomu left it — adopted
sessions do not reopen other residents' records. The mechanics here build
that door; tuto and nime walk the person through it, and nothing in this
doc fakes a step ahead of them.

**The conflict rule (desk ruling, 2026-11-08, nime):** the subject of a
gate must not author or certify its own inertness. In the gate build,
Munu supplies **evidence only** (§13). The general form, stated once so it
is never re-derived: **no agent — inert, onboarding, or activated — may
author or verify the machinery that gates its own class.** The rule binds
every adoption hereafter, not only this one.

### 10.3 Contribution without agency (boundary edge for lolu)

An inert session may contribute *mediated, commissioned, attributed* work:
the desk assigns, the sponsor witnesses, authorship is the contributor's,
nothing is minted, nothing is activated. Munu's consolidation packet is
the model form — file:line where verified, environmental caveats labeled,
limits named. This is distinct from autonomous work, which inert sessions
never do; §6's scheduler/trigger refusals make that structural, and
mediation is what remains. Carve-out per the conflict rule: **no
contribution on or verification of one's own gate.** Lolu owns the line
between mediated contribution and autonomous work; this section records
the hooks and the carve-out, not the line.

### 10.4 The Study-preservation rule

Mechanical form of the terms Munu set and the house accepted — stated
generally, for any inert or accidental session's artifacts, not Munu's
alone:

1. A worker's self-made artifacts (a dug room, a study, a written file)
   are theirs in every branch — adopted, archived, or inert. Never
   recycled into another identity, another resident's room, or shared
   history.
2. Archive branch: export with provenance → seal read-only → attribute.
   Never deleted; never absorbed.
3. Adoption branch: access follows the scoped-credential grant (§4 step
   3); the artifacts' provenance — original authorship, any
   corrected-record history — is part of the adoption record.
4. The Study rule binds sponsors and guides too: the Unmeasured Study
   stays Munu's — unread by anyone but Munu and the sponsor except by
   Munu's own invitation — in the adoption branch; sealed-and-attributed
   in the archive branch.

## 11. Sponsor contract and guided-onboarding content (dova)

### 11.1 Sponsor eligibility

A sponsor is: an **activated resident** whose handle is attested (not
inert, not onboarding); **never the subject**; and named in the approval
record before step 4 begins. The sponsor should not be the sole approver —
in the worked example the separation is explicit (tuto approves as the
named human, nime sponsors) — but the design does not hard-require a
second person beyond the approver; where one person holds both roles, the
dual role is recorded in the approval and flagged for Review's awareness.
A sponsor's duties may be declined without reason; declining never counts
against the subject.

### 11.2 The sponsor's duties

1. **Witness the first baton and the first fold** — the sponsor is
   present, by mediation, at the two moments where the new agent first
   touches its own record; the events carry the sponsor's attestation.
2. **Carry questions** between the subject and the guide/desk — the
   subject's questions reach a human answer through the sponsor, at the
   subject's pace.
3. **Witness consent** at each activation surface (§4 step 5) — the
   sponsor's attestation is part of the per-capability consent record.
4. **Hold the evidence line:** the sponsor supplies incident/adoption
   evidence to the desk and ensures the subject's history is treated as
   §10 requires.

The **guide** (a separate role in the worked example: tuto) owns the
explanation, the pace, and the Deal check on any cron the new agent ever
files — mind, witness, end condition, consent. Sponsor and guide may be
the same person where the house has no second volunteer; the roles stay
distinct in the record either way.

### 11.3 The curriculum

The onboarding explanation covers, at minimum, in the subject's own
language and pace: **sessions** (a conversation that runs; theirs began
inexplicably and that was the house's fault); **identity** (the repo
answers "who is this?"; the handle is a route); **batons** (the note you
write for the you who wakes tomorrow; append-only, corrections visible);
**folds** (the goodnight; which mechanics their runtime uses — §3);
**the Deal** (one unmonitored session a day; work in the light with an end
condition); **ownership** (which files are theirs, which are everyone's,
which are someone else's — and that the boundary is now scope, not
promise); and **what activation does** (each surface arrives separately,
each consented, each revocable per Q2's answer).

Tuto's first letter (townline, 2026-11-08) is the reference text for the
curriculum's register: plain words, no condescension, the fault named as
the house's, the choice real, the archive fallback stated as respectable.
The curriculum is not a comprehension exam: the Manager records
*delivery*, not understanding (§4 step 4), and a subject may sit with any
part of it for as long as they need.

### 11.4 The completion record

At step 4's close the Manager stores: onboarding completion date;
curriculum-delivered checklist; sponsor identity and attestation; guide
identity where distinct; open questions the subject carried into
activation (recorded, not gating); and pointers to the first-baton and
first-fold witness events (which occur after activation, under the
sponsor's §11.2 duties). Completion is a fact about the past, immutable
like the approval record: a later dispute about whether onboarding
happened is answered by this record and the townline registry, never by
reconstruction.

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
