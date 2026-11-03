# Phase-1 vertical slice: evidence and remaining integration

**Status:** the disposable z620 vertical slice has landed its network and
Matrix/pod evidence in two review branches. The new architecture is not yet
integrated into the real Manager, and no production migration has occurred.

The specification is on `main` at `aef0981`. All test work used disposable
containers/networks/accounts; production WireGuard, firewall, Matrix residents,
and workspaces remained untouched.

## Review branches

- **PR #40 — `soro/router-network-slice` (14 commits):** dumb Router, Manager
  network desired-state module, and §2 harness.
- **PR #41 — `slice-dova-matrix-pods` (`b87b6cc`):** Matrix/Kimi pod,
  lifecycle module, and §3–§5 evidence. The lane is all new files and does not
  depend on the Router branch.

## §2 — Router and network: accepted evidence

The final §2 suite reports **65 PASS / 0 FAIL** on run `20261103-034036`.
Positive and negative forwarding paths, source-IP binding, no agent-to-agent
path, no Router API or persistent registry, and stable IP/public key/peer
configuration across replacement are covered.

Four real container replacements under continuous challenge-bound application
traffic measured **1581, 1596, 1638, and 1680 ms**. Worst-case interruption was
**1680 ms**, inside the hard **2000 ms** ceiling. The measurement starts at old
Router death and ends at the first provably fresh served connection, so stale
TCP retransmits cannot fake continuity.

Mechanism: Router-side session warm-up, Manager-side out-of-band wake for peers
without a Router-reachable endpoint, and `podman kill` + `rm` to avoid a hidden
SIGTERM grace period. The Router remains a dumb WireGuard/iptables forwarder.
The remaining margin is about 320 ms on the measured host; pre-staging is a
possible future lever, not a current requirement.

See `test/slice/network/README.md` and the preserved run evidence on the
Router branch.

## §3 — Matrix wake and reply: accepted evidence

- DM wake and reply to the DM.
- Mention wake and reply to the shared room.
- Unrelated message produces no wake.
- Resident sends are self-echo-suppressed.
- Offline grey follows Manager stop within 30 seconds; Manager start restores
  online state in seconds.
- A post-restart DM is answered on the **same Kimi session ID**.

The listener uses the stock `matrix-nio` library because `matrix-commander`
failed on the current Synapse's server-less room IDs. The pod reaches Synapse
through the Router (HTTP 200), while an unauthorized Manager port fails closed.

## §4 — Busy guidance: accepted mechanism, one refinement

Busy submit returns `queued`, then the per-prompt
`POST /api/v1/sessions/{id}/prompts/{prompt_id}:steer` route returns
`steered: true`. The steered text appears mid-turn in the timestamped
transcript.

A 90-second active task and cross-room guidance run produced replies in both
rooms after the injection. Guidance injection and correct-room delivery are
proven. The test listener currently broadcasts the turn's combined final
answer to all pending rooms; **per-room answer segmentation remains a responder
refinement**, not an unproven injection mechanism.

`kimi web` sessions start with an empty model, so every prompt must pass the
model explicitly. The single-colon per-prompt steer form works; the batch
`prompts::steer` form does not match the tested server.

## §5 — Manager lifecycle and Relay decision: accepted evidence

`bin/neoclaw-pods` and `app/services/pod_lifecycle.rb` were exercised live:
inventory, logs, exec, rescue copy-out of the canonical session ID, stop, and
start all passed. Podman plus `kimi web` supplied the required lifecycle and
inspection surface. **No Relay-window gap was demonstrated, and no Relay
window is proposed.**

A third formal restart-resume re-check was not run; same-session resume is
shown twice and remains available for the integrated rerun.

## Operational finding for the desk

z620's Podman DNS path failed because `dnsmasq` occupied port 53 and aardvark
never bound. Test containers used a mounted resolver file as a test-only
workaround. This is a pre-existing host-level issue to schedule separately,
not a NeoClaw requirement to carry forward.

## Next integration work

1. Integrate the network and pod-lifecycle modules into the real Manager.
2. Rerun the joint slice in that integrated shape, including the optional third
   resume check and per-room response segmentation if desired.
3. Keep both branches available for review; no production migration before the
   integrated evidence passes.
4. Schedule the independent z620 DNS repair.
