# NeoClaw Rails — Architecture Review

**Reviewer:** Silas  
**Date:** 2026-03-17  
**Scope:** Full codebase — Hub, Manager, Relay, wg-admin

---

## Overall Impression

This is clean work. The spec said "three pieces with clean seams" and the implementation delivers. The Hub genuinely doesn't know about containers, the Manager genuinely doesn't know about Matrix, and the Relay is a single file that does four things. That discipline held.

The code reads well. Ruby was the right call — `Container.idle.order(:last_message_at).first` is prose. The models are thin, the services are where the logic lives, and the controllers are dumb pipes. That's how it should be.

Now, the things I'd change.

---

## 1. The Hub-Manager Split: What Works, What Doesn't

### What works

The two-endpoint API (`/resolve`, `/release`) is elegant. The Hub asks a question and gets an IP. It doesn't know or care what happened behind the curtain. The callback flow for async events (ready, released, crash) is clean. This is a good contract.

### What doesn't

**The Hub has two identity systems and they don't talk to each other.** The Hub has `Identity` + `Listener` models. The Manager has `AgentConfig` + `AgentRoomConfig` + `RoomConfig`. These are both describing the same entities — who Margaux is and what she gets — but they're split across two databases with no shared key beyond a string name.

When you create a new identity, you need to:
1. Create an `Identity` in the Hub DB
2. Create an `AgentConfig` in the Manager DB
3. Hope the `identity.name` matches `agent_config.identity`

There's no validation that these stay in sync. No migration tool. No foreign key. Just vibes and string matching.

**Recommendation:** Either the Manager becomes the source of truth for identity config (Hub queries it at startup or caches it), or there's a shared seed/sync mechanism. The current dual-master approach will drift.

### The Room duality is worse

Hub has `Room` (Matrix room mapping, slug derivation). Manager has `RoomConfig` (services, model defaults). They're joined by `slug == channel` string matching. The Hub derives slugs from Matrix room names with a `derive_slug` method that strips special chars and lowercases. If the slug derivation ever changes, the Manager's room configs silently stop matching.

**Recommendation:** Room configs should reference Matrix room IDs, not derived slugs. Or the slug derivation should live in exactly one place.

---

## 2. The Resolve/Release Contract

### Resolve is synchronous but spawning is async

`Spawner.resolve` does the full spawn inline — key generation, provisioning, `podman run` — and returns `{ ip: ... }`. But the agent isn't ready yet. The Hub creates an Agent in "resolving" state and waits for a "ready" callback.

The problem: `ManagerClient.resolve` has a 60-second timeout. If provisioning + container start takes longer, the Hub gets a timeout error and destroys the placeholder agent. Meanwhile the Manager has a running container with no route in the Hub. The container will report health, the Manager will see it as alive, but the Hub has no record of it.

**Recommendation:** Make resolve always return fast. Return `{ ip: ..., starting: true }` immediately after creating the Container record and launching podman. Do the provisioning (Forgejo user creation, SSH keys) in a background job or thread. The Hub already handles the "starting" case — it stores the IP and waits for the ready callback.

### Release has no idempotency guard

`Lifecycle.release` → `freeze!` → relay signal → wait for `freeze_ready` callback → `teardown!`. But if the relay never responds (network partition, crashed relay), the container sits in "freezing" state forever. There's no timeout, no reaper.

**Recommendation:** Add a reaper job that checks for containers stuck in "freezing" for more than N minutes and escalates to `force_kill!`.

### Release doesn't deduplicate

If the Hub calls `/release` twice for the same instance (race condition, retry), and the first call is mid-freeze, the second call hits `container.alive?` → false and silently returns. That's fine. But if both calls arrive before the state changes, both call `freeze!` which sends two relay signals. The relay handles this fine (it's idempotent), but the Container gets `update!(state: "freezing")` twice, which is a pointless write.

Minor, but worth a guard: `return if container.freezing?` at the top of `freeze!`.

---

## 3. The Spawner Flow

### IP allocation is a race condition

```ruby
def allocate_ip
  used = Container.where.not(state: "dead").pluck(:wg_address).compact
  (1..254).each do |octet|
    ip = "10.0.1.#{octet}"
    return ip unless used.include?(ip)
  end
end
```

Two concurrent `resolve` calls can get the same IP. There's no lock, no database-level uniqueness constraint on `wg_address`, and no retry loop.

**Recommendation:** Add a unique index on `containers.wg_address` (scoped to non-dead states, or just always unique since dead containers should eventually be cleaned up). Use `INSERT ... RETURNING` or a retry loop on uniqueness violation.

### Service lookup is N+1

```ruby
services.each do |service_name|
  service = ServiceType.find_by(name: service_name)
  next unless service
  secrets[service_name] = Provisioner.provision(service, ...)
end
```

This does one query per service. With 5 services that's 5 queries, plus another 5 for WG peering, plus more in `build_spawn_file`. Should be one `ServiceType.where(name: services)` upfront, then lookup from the hash.

### Capacity check freezes but doesn't wait

```ruby
if Container.alive.count >= Surface.soft_cap
  coldest = Container.idle.order(:last_message_at).first
  Lifecycle.freeze!(coldest) if coldest
end
```

`freeze!` sends a relay signal and returns immediately. The frozen container is still alive (state is "freezing", not counted by `alive` scope... wait, actually `alive` is `where(state: "alive")` and `freeze!` sets state to "freezing"`. So the count drops by 1 immediately. That's correct — the soft_cap/hard_cap gap handles the overlap. Good.

But: if there are no idle containers and everything is at capacity, the coldest *alive* container gets frozen. That could be mid-conversation. The spec mentions this is by design, but there's no notification to the user that their agent was evicted. The callback to the Hub says "released" with reason "teardown", not "evicted" or "capacity".

**Recommendation:** Pass a more specific reason through the callback so the Hub can notify the user appropriately.

### `build_instance_name` queries the DB but `resolve` also queries it

```ruby
def resolve(identity:, channel:)
  instance_name = build_instance_name(identity, channel)
  # ...
  spawn(identity: identity, channel: channel, instance_name: instance_name)
end

def spawn(identity:, channel:, instance_name:)
  config = AgentConfig.find_by!(identity: identity)
  # ...
end
```

`build_instance_name` does `AgentConfig.find_by(identity: identity)` to check `singleton?`. Then `spawn` does `AgentConfig.find_by!(identity: identity)` again. Two queries for the same record.

---

## 4. Lifecycle Management

### No health check timeout enforcement

The relay reports health every 30 seconds. The Manager stores `last_health_at`. But nothing checks for stale health. If a relay dies silently, the container sits in "alive" state with an increasingly stale `last_health_at` and nobody notices.

**Recommendation:** A periodic job (or even a simple cron rake task) that checks `Container.alive.where("last_health_at < ?", 2.minutes.ago)` and escalates to force_kill.

### Sunset triggering is passive

The relay controller checks `context_usage > 0.85` on every health report and sends a `sunset_warning` callback. But nobody actually triggers `sunset!`. The Hub gets the warning and notifies the user, but the agent keeps running until... what? Context hits 100% and Claude Code errors out?

**Recommendation:** Add a threshold (0.95?) that triggers `Lifecycle.sunset!(container)` automatically.

### Dead containers accumulate

`teardown!` sets state to "dead" but never deletes the record. Over time the containers table grows with dead records. The `allocate_ip` method filters them out, but queries that don't scope by state will include them.

**Recommendation:** Either delete dead container records after a retention period, or add a `scope :not_dead` and use it more broadly. The audit log already captures the history.

---

## 5. Provisioner Patterns

### ssh_key provision is a no-op

```ruby
def provision_ssh_key(service, instance_name:, ssh_pubkey:)
  identity = instance_name.split("-").first
  { ssh_host: service.wg_ip, ssh_user: identity }
end
```

This doesn't actually add the SSH key anywhere. The `authorized_keys` management mentioned in the spec and NETWORK.md isn't implemented. The teardown is also empty.

### token provision generates a token that's never stored

```ruby
def provision_token(service, instance_name:)
  token = SecureRandom.hex(32)
  { token: token, url: "http://#{service.wg_ip}" }
end
```

This generates a random token and returns it, but doesn't register it with the service (Valley, Vikunja). The token is meaningless — the service doesn't know about it. The teardown is also empty.

These are clearly stubs. That's fine for a first pass, but they should be marked as such (a `# TODO` or `raise NotImplementedError` for the teardown) so nobody assumes they work.

### Forgejo provisioner doesn't handle existing users

If a container crashes and gets force-killed, but the Forgejo user wasn't cleaned up (network error during teardown), the next spawn for the same instance name will fail on user creation (409 Conflict). No retry, no "user already exists" handling.

**Recommendation:** Check if user exists first, or handle the 409 gracefully.

---

## 6. The Surface Initializer

This is one of the best patterns in the codebase. Every external dependency the Manager touches is declared in one module. If it's not in Surface, the Manager can't reach it. This is auditable, testable, and makes the security surface area explicit.

One issue: it mixes configuration (URLs, ports, caps) with credentials (tokens, key paths). Credentials should ideally be loaded lazily and not cached in module-level state, in case they rotate. Currently `forgejo_admin_token` reads from ENV on every call, which is fine. But if someone memoizes it (like the HTTPX clients are memoized), rotated credentials won't take effect.

Minor. The pattern is sound.

---

## 7. ActiveRecord Models

### Hub models are clean

Identity, Room, Agent, Listener — four models, clear relationships, good scopes. The `derive_slug` callback is well-placed. The Agent model correctly treats itself as a route, not a registry entry.

One thing: `Agent` has `context_usage` in the schema but the Hub never updates it. Only the Manager tracks context usage (via relay health reports on the Container model). The Hub Agent's `context_usage` is always 0.0. Either remove it from the Hub schema or pipe it through callbacks.

### Manager models are heavier

`Container` is doing too much. It's a runtime state object (state, last_health_at, context_usage) AND a configuration reference (identity, channel, provisioned_services) AND a podman handle (container_id). This is fine at current scale but will get unwieldy. Consider extracting the provisioned state into a join table if service management gets more complex.

`AgentConfig.services_for(channel)` does three queries:
1. Self (already loaded)
2. `RoomConfig.find_by(channel: channel)`
3. `agent_room_configs.find_by(channel: channel)`

This is called during every spawn. Should be eager-loaded or cached.

### No validations on Container

Container has no model-level validations beyond `instance_name` presence and uniqueness. No validation that `state` is one of the allowed values. No validation that `wg_address` looks like an IP. SQLite won't catch these.

---

## 8. The Relay

### Solid single-file design

The relay is ~350 lines, does exactly what it should, and is readable end to end. The WEBrick choice is fine for a sidecar that handles single-digit concurrent connections.

### Clone happens before Claude Code starts

The relay clones the repo itself (`clone_repo`), then starts Claude Code. But the spec says "Claude Code boots into an empty filesystem. The first act is to clone." The spec's approach is better — it lets the agent own its own identity from the first moment. The relay doing it is a pragmatic shortcut (Claude Code needs the workspace to exist), but it means the relay knows about git, repos, and SSH keys. That's leakage.

**Recommendation:** Have the relay create the workspace directory and write the SSH key, but let Claude Code do the actual `git clone` as its first tool use. This keeps the relay thin and the agent's first act meaningful.

### Context tracking is a rough estimate

```ruby
@context_usage = (input + output).to_f / 200_000
```

This accumulates total tokens across all turns, not the current context window size. After 10 turns, the "usage" could exceed 1.0 even though the actual context window is fine (because old turns are summarized/dropped). This will trigger false sunset warnings.

**Recommendation:** Use the actual context window usage if Claude Code exposes it, or track per-turn usage rather than cumulative.

### The output reader sends every line to the Manager

```ruby
@claude_stdout.each_line do |line|
  post_to_manager("/containers/#{@instance_name}/output", line)
```

Every JSON event from Claude Code's stream gets POSTed to the Manager. That's a lot of HTTP for a stream. If Claude Code is doing a complex tool use chain, this could be hundreds of requests per minute.

**Recommendation:** Batch output lines (buffer for 500ms, send batch) or use a persistent connection (WebSocket to ActionCable, which is already set up on the Manager side).

### No authentication on relay endpoints

Anyone who can reach port 9300 can send messages to Claude Code or trigger a freeze. The relay trusts that WireGuard peering is the auth boundary. That's fine per the threat model, but a bearer token from spawn.json would be defense in depth.

---

## 9. wg-admin

Tiny, auditable, does one thing. The input validation is good — regex checks on pubkey and CIDR format prevent injection. The `ALLOWED_INTERFACES` whitelist prevents touching non-NeoClaw interfaces.

One issue: `wg showconf` persistence happens after every add/remove. On a burst of spawns (5 agents at once), that's 30+ `wg showconf > /etc/wireguard/X.conf` calls, one per interface per peer add. These are racy — two concurrent writes to the same conf file could corrupt it.

**Recommendation:** Debounce persistence (save after 2 seconds of no changes) or use a mutex per interface.

---

## 10. Test Coverage

### What exists

- Hub model tests: Identity, Room, Agent — scopes, validations, basic behavior ✓
- Hub controller tests: Health endpoint, Transactions auth ✓  
- Hub router tests: Mention parsing, sender extraction, self-message filtering ✓

### What's missing

**Hub:**
- No tests for `CallbacksController` (ready, released, crash flows)
- No tests for `AgentsController` (message puppeting, event handling)
- No integration test for the full resolve flow (Router → ManagerClient → Agent creation)
- No tests for `Hub::Commands` (operators, !freeze, !kill)
- `Listener` model has no dedicated tests

**Manager:**
- **Zero tests.** No model tests, no controller tests, no service tests. The entire Spawner, Lifecycle, Provisioner, and WireGuard integration is untested.

**Relay:**
- No tests. Single-file script with no test harness.

**wg-admin:**
- No tests.

The Manager having zero tests is the biggest gap. The Spawner alone has enough logic (IP allocation, service resolution, key generation, spawn file building, error handling) to warrant a solid test suite. The Lifecycle freeze/teardown flow is the most critical path in the system and it's completely untested.

**Priority test targets:**
1. `Spawner.resolve` — happy path, at-capacity eviction, already-running
2. `Lifecycle.teardown!` — verify all services cleaned up, WG peers removed, Hub notified
3. `Provisioner` — at least the Forgejo flow
4. `AgentConfig.services_for` — the three-layer merge
5. `ApiController` — resolve/release API validation

---

## 11. Things I'd Change Now

### Make resolve async

The synchronous resolve-then-wait pattern is the biggest architectural risk. Make `/resolve` return immediately with a "starting" status. The Hub already handles this — it creates a resolving agent and waits for the ready callback. The Manager should do its work (provisioning, podman run) in a background thread or job and callback when done.

### Add a reaper

A periodic job (every 60 seconds) that:
- Force-kills containers stuck in "freezing" for >3 minutes
- Force-kills containers with stale health (>2 minutes)
- Triggers sunset for containers at >95% context
- Cleans up dead container records older than 24 hours

### Unify identity config

Either Hub queries Manager for identity metadata at resolve time, or there's a shared config format (YAML files?) that both read. The current dual-database approach is a sync bug waiting to happen.

### Add auth tokens to internal APIs

The Hub → Manager and Manager → Hub HTTP calls have no authentication. WireGuard peering is the trust boundary, which is reasonable, but a shared secret in a header is cheap insurance against network misconfiguration.

### Extract the Relay's response handling

The relay parses Claude Code's stream-json output and extracts text from `assistant` events. This parsing logic will need to evolve as Claude Code's output format changes. It should be a separate class/module, not inline in the main Relay class.

---

## 12. What I Wouldn't Change

- **The Hub/Manager split.** It's the right cut. The Hub is a message router. The Manager is an infrastructure controller. They have different trust levels and different failure modes. Keep them apart.
- **WireGuard as authorization.** Peer topology as access control is elegant. ComfyUI doesn't need its own auth because if you can reach it, you're authorized. This is the right level of simplicity.
- **One container image.** The spec calls this out and the implementation delivers. The relay, spawn.json, and WireGuard config make every container identical at build time and unique at runtime. This is how it should be.
- **SQLite for both databases.** At this scale (single host, <10 concurrent containers), SQLite is plenty. Don't reach for Postgres until you need it.
- **Ruby.** The whole thing reads like documentation. That matters more than benchmarks when you're the sysadmin and the developer and the operator.

---

## Summary

The architecture is sound. The implementation is ~85% there. The main gaps are:

1. **No Manager tests** — highest priority
2. **Resolve is synchronous** — biggest runtime risk  
3. **No reaper for stuck states** — will bite you on the first network hiccup
4. **Dual identity config** — will drift
5. **Provisioner stubs** — SSH and token provision don't actually do anything
6. **Context tracking is wrong** — cumulative vs. window

None of these are design flaws. They're all fixable within the current architecture. The seams are in the right places. The trust boundaries are correct. The complexity is where it should be (Manager) and absent where it should be absent (Hub, Relay).

Ship it, then fix the tests.

---

*Reviewed by reading every file in the repo. No stone unturned, no platitudes offered.*
