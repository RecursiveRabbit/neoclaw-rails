# Vertical slice §3–§5 — Matrix/Kimi/pod side (dova's lane)

Test date: 2026-11-03, z620. Disposable rig only: `neoclaw-test-synapse`
(Synapse, accounts @slice-resident/@slice-tester/@slice-observer, one DM room
and one shared room), `neoclaw-test-agent` pod, soro's joint test Router.
Production Matrix/WireGuard/pods untouched.

## §1 baseline — invocations under test

- **Wake/guidance:** `kimi web --port 58999 --host 127.0.0.1` (stock Kimi
  Code 0.43.1 local server; bearer token from its startup banner).
  - `POST /api/v1/sessions` (create), `GET /api/v1/sessions/{id}`
    (`busy`, `last_turn_reason`), `GET .../messages`.
  - Wake: `POST /api/v1/sessions/{id}/prompts` with `content[]`, explicit
    `model`, `permission_mode:"auto"`.
  - Guidance: `POST /api/v1/sessions/{id}/prompts/{prompt_id}:steer`
    (single colon; returns `{steered:true, prompt_ids:[...]}`).
- **Matrix:** Synapse client API (v3) on the pod's only authorized service
  10.0.0.2:8008, reached through the Router. Pod-side client is the stock
  **matrix-nio** library (see Findings for why not matrix-commander).
- **Lifecycle:** `bin/neoclaw-pods` (this repo) against the podman socket.

## §3 Matrix wake and reply — evidence

From `evidence/listener.log` (all times UTC, 2026-11-03):

1. **DM wake + reply to the DM room.** Tester → DM `reply with exactly:
   ALPHA1`; `[08:50:58] WAKE [dm] ...`; `[08:51:21] replied to <DM>
   resp: RoomSendResponse`; room history shows `@slice-resident :: ALPHA1`.
2. **Mention wake + reply to the shared room.** Tester → shared room
   `@slice-resident reply with exactly: BETA2`; `[08:52:55] WAKE [mention]`;
   `[08:52:59] replied to <shared>`; history shows `@slice-resident :: BETA2`.
3. **Unrelated traffic does not wake.** `[07:43:19] no wake (...): unrelated`.
4. **Self-echo suppression.** Every resident send is followed by
   `self-echo suppressed: $...` in the listener log.
5. **Offline grey + Manager start.** Pod stopped via
   `bin/neoclaw-pods stop neoclaw-test-agent` (Manager surface); presence
   flips `online → offline` within 30s of the Manager stop (09:03:31→09:04:01 UTC); `bin/neoclaw-pods start` brings it
   back and the listener log shows `resumed session` + `initial sync` +
   both room joins on the SAME Kimi session id (identity preserved across
   restart).

## §4 Busy delivery by guidance — evidence

Mechanism proof (host-side probe, `evidence/guidance-probe-v2.json` +
`evidence/final-answer.json`): submit while busy returns
`status:"queued"`; `:steer` returns `steered:true`; the steered text
appears as a `user` message **mid-turn** in the timestamped transcript and
the active turn's final answer (same turn) incorporates it.

End-to-end through the pod (`evidence/listener.log`):

- `[08:54:54] WAKE [dm]` — 90-second bash loop task in the DM room.
- `[08:55:24] WAKE [mention]` from the shared room while busy →
  `busy -> steered guidance: {"steered": true, ...}`.
- `[08:57:08] replied to <DM>` (`LOOP_DONE_90`, len 14) and
  `[08:57:09] replied to <shared>` (len 14 — the combined final answer
  carrying `GUIDANCE_X7` and the highest tick).

**Honest limitation:** the test listener broadcasts the turn's final
assistant text to every room pending in that turn, so both rooms received
the combined answer verbatim. Guidance injection, mid-turn incorporation,
and correct-room *delivery* are proven; per-room answer segmentation in a
multi-pending turn is a responder-policy refinement, not a mechanism gap.

## §5 Manager-only lifecycle and Relay decision

`app/services/pod_lifecycle.rb` + `bin/neoclaw-pods` (new files; argv-array
podman exec, no shell, no pod-side agent). Exercised live against
`neoclaw-test-agent`:

- `inventory` — 17 containers enumerated with name/id/state/image.
- `logs --tail`, `exec` (reached the pod's kimi web route, 401 as
  expected), `stop`/`start` (used for the §3.5 grey test).
- `rescue --path /pod/workspace --to <dir>` — copied the pod's canonical
  session id file out: identity rescue works with **no Relay HTTP server**.
- `replace` (stop+rm+build+run) implemented; not exercised tonight.

**Relay-window verdict:** every lifecycle/inspection/rescue operation the
slice requires is satisfied by podman plus `kimi web`'s own API. No
concrete gap demonstrated → **no Relay window is proposed** (spec §7).

## Network path (joint with soro's §2)

- Pod WG config rendered by the Manager: `bin/neoclaw-network agent-config
  /home/sexton/neoclaw-test/state slice-resident` → 10.1.0.1/32, exactly
  one peer (Router 10.99.0.10:51820), AllowedIPs 10.0.0.2/32 only.
- Pod → http://10.0.0.2:8008 (Synapse through the Router): **200**.
- Pod → 10.0.0.3:22 (unauthorized): **failed-closed** (route-level; Router
  has no rule).
- Synapse's WG runs as a sidecar container in the synapse netns (the
  matrixdotorg image has no wireguard-tools; the sidecar applies the
  Manager-rendered host-config without modifying the service image).

## Findings (deviations and host conditions)

1. **`kimi web` sessions start with an empty model.** A prompt without an
   explicit `model` fails the turn instantly (`last_turn_reason:"failed"`).
   The listener passes `model` per prompt. Worth an upstream issue.
2. **Batch steer route mismatch.** `POST .../prompts::steer` (as the route
   table suggests) does not match; the per-prompt action form
   `.../prompts/{prompt_id}:steer` works.
3. **matrix-commander cannot parse Synapse's current server-less room IDs**
   (`KeyError 'room_id'` on join). The pod therefore uses matrix-nio, a
   stock client library. If "stock Matrix CLI" is load-bearing in the spec,
   this CLI/Synapse interop break needs an upstream fix or a different CLI.
4. **z620 podman DNS is broken host-wide** (pre-existing, not caused by the
   slice): dnsmasq holds 0.0.0.0:53 with `--local-service`, so
   aardvark-dns never binds; containers get a dead 10.99.0.1 resolver.
   Test workaround: mount a resolv.conf (8.8.8.8) into test containers.
   Production-facing; recommend the desk schedule a dnsmasq/aardvark fix.
5. Steer while no active turn errors honestly: `no active prompt to steer
   into` (good failure semantics, per spec "reported honestly").

## Reproduce

1. `bin/neoclaw-network agent-config <state> slice-resident` → pod WG conf.
2. Build the pod image from `container/` (`podman build -t
   neoclaw-test-agent container/` — context includes a verbatim stock
   kimi-code bundle, not committed here).
3. Run per the listener env contract in `container/pod/start.sh` (WG conf
   optional; `MATRIX_HOMESERVER`, `RESIDENT_USER`, `SLICE_DM`,
   `SLICE_SHARED`; provisioned Matrix credentials at `/pod/creds`).
