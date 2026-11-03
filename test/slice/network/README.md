# Vertical-slice network lane — §1 baseline record

**Lane:** Router/network + z620 readiness (VERTICAL-SLICE-TEST.md §2).
**Harness:** `test/slice/network/run.sh` — self-contained; builds both images,
creates the disposable network, runs every check, preserves all evidence
under `evidence/<timestamp>/`.

## §1 baseline items for this lane

- **Test residents:** `test1` (WG 10.1.0.1) and `test2` (WG 10.1.0.2) —
  disposable identities created per run by the Manager CLI. (Matrix
  users/rooms for §3 are the Matrix lane's baseline.)
- **Test network:** podman `neoclaw-test`, 10.99.0.0/24, created and
  destroyed by the harness. Production WireGuard/firewall on z620 is never
  touched.
- **Router under test:** image `localhost/neoclaw-router:test` built from
  `router/Containerfile`; WG identity rendered from Manager state per run
  (public key recorded in the evidence transcript each run).
- **Host / Manager identities:** WG 10.0.0.2 / 10.0.0.3, keys generated per
  run by the Manager (public halves in the transcript; private halves in the
  per-run state dir, destroyed on success).
- **Services under test:** `svc-matrix` 10.0.0.2:443 (authorized for
  test1), `svc-alt` 10.0.0.2:8448 (authorized for test2), `svc-admin`
  10.0.0.2:22 (manager control channel, asserted host-side).
- **Exact invocations under test:**
  - `ruby -I app/services bin/neoclaw-network init|add-service|add-agent|authorize|render-router|host-config|agent-config|manager-config|router-public|show`
  - `podman build/run/exec/rm` of `neoclaw-test-{router,host,manager,agent-a,agent-b}`
  - In-container: `wg show wg0 [public-key|dump]`, `iptables -L NEOCLAW_FWD -v -n`, `nc -w 3 <host-ip> <port>` probes.

## Last full run

2026-11-03 (evidence `20261103-034036` challenge-bound gate): **65 PASS /
0 FAIL** — every §2 item proven: pairing topology, authorized/unauthorized
matrix, agent-to-agent deny, source-IP spoof rejection (zero spoofed
packets received), no API listener / registry / state on the Router, and
repeated replacement rolls (5 total) that kept the same IP, public key,
peer set, and iptables policy with agent pod WG config untouched.

**Roll interruption gate (Evans' hard requirement: <=2 s worst case):**
four rolls under continuous challenge-bound application traffic measured
1581 / 1596 / 1638 / 1680 ms from old-router death to first fresh served
connection — worst 1680 ms. Mechanism: Router entrypoint session warm-up
+ Manager out-of-band pod wake (podman exec ping) + `podman kill`/`rm`
fast teardown. See `router/router.md`.

## Operational findings (recorded per §1 honesty)

- Manager<->host pairing bypasses the Router by design; Manager port
  policy is host-side, out of Router scope (asserted with wg counters).
- A roll drops in-kernel WireGuard sessions; without the warm-up/wake
  mechanisms, recovery would wait out ~120-180 s rekey timers. With them:
  <=2 s proven above.
- `podman rm -f` alone burns a 10 s SIGTERM grace on the test host (PID 1
  ignores SIGTERM environment-wide); rolls must use `podman kill` + `rm`.
