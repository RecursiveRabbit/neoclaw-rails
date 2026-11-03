# Vertical-slice acceptance test

**Purpose:** prove the new design on one disposable resident before deleting
or migrating production infrastructure.

This is the test plan. Current evidence and remaining integration work are
tracked in [`docs/PHASE-1-STATUS.md`](PHASE-1-STATUS.md).

## Scope

Use a disposable test resident, test Matrix rooms/account, a test Router, and
a test Manager environment. Do not use a live resident's private workspace or
production Matrix traffic.

The slice must include real WireGuard and iptables behavior, a real Matrix
message path, Kimi Code's actual notification and guidance functions, and the
Manager's actual podman control path. Unit tests alone are insufficient.

## 1. Baseline

Record:

- the test resident's Matrix user and two test room IDs;
- the Router IP and public key (never print the private key);
- the host and agent peer configurations (public material only);
- the service destination/port used for the authorized network test;
- the exact Matrix CLI, notification, and guidance invocations under test.

Start with no Hub and no Relay message server.

## 2. Router replacement and authorization

1. Start the Manager and create the initial network. Capture the emitted host
   WG connection configuration and apply it in the test environment.
2. Bring up the Router and one agent pod. Confirm the agent is paired only
   with the Router, and that the Manager and Router are paired with the host.
3. Confirm the authorized host destination/port works.
4. Confirm an unauthorized port on the same host fails.
5. Confirm an unauthorized source and an agent-to-agent path fail.
6. Attempt to use another peer's source IP and confirm it is rejected.
7. Inspect the Router: no API listener, agent-name registry, service-name
   registry, or persistent agent database exists.
8. Replace the Router from the Manager's desired state.
9. Verify that Router IP, public key, and peer configurations are unchanged,
   and that the agent pod's WG configuration was not modified.
10. Repeat the authorized and unauthorized packet tests.

**Pass evidence:** public Router/peer dumps, packet results, unchanged agent
WG config, and two matching Router public keys.

## 3. Matrix wake and reply

1. Send a direct message to the test resident. Verify that the stock
   notification path wakes Kimi and that the reply returns to that DM.
2. Send a message mentioning the resident in a shared test room. Verify the
   wake and a reply to that room.
3. Send an unrelated message in the shared room. Verify no wake occurs.
4. Verify the resident's own outbound messages do not wake it again.
5. Stop the resident. Verify it appears grey on Matrix, then start it through
   the Manager and verify synchronization/resumption.

**Pass evidence:** Matrix event IDs, listener/notification output, Kimi session
identity, and Manager start evidence.

## 4. Busy delivery by guidance

1. Give the resident a long-running task that keeps its model turn active.
2. While it is working, send a second message from a different test room.
3. Verify that the second message is injected through Kimi Code's guidance
   function during the active turn, rather than waiting in a queue.
4. Verify that the active turn can acknowledge or use the guidance and that
   any reply carries the correct room metadata.
5. Repeat once after restart/resume and confirm the same resident/session
   identity is retained.

**Pass evidence:** timestamped active-turn transcript showing the guidance
injection, the incoming Matrix event ID, and the corresponding response.

## 5. Manager-only lifecycle and Relay decision

1. Use podman through the Manager to inventory, start, inspect, and retrieve
   logs for the test pod.
2. Exercise the required rescue/read path without using a Relay HTTP server.
3. Record any concrete lifecycle or inspection operation that podman and
   Kimi-native facilities cannot provide.

Only if such a gap is demonstrated should a narrow pod-window component be
proposed. The old Relay message plane is not restored as a default.

## Acceptance gate

The slice passes only when every item above has direct evidence. A successful
unit test, a healthy container, or a single Matrix reply is not sufficient.

If any part fails, preserve the test evidence, fix the narrowest responsible
component, and rerun the complete slice before production migration.
