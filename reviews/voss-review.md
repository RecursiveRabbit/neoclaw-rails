# NeoClaw Rails — Code Review

**Reviewer:** Voss  
**Date:** 2026-03-17  
**Scope:** Hub (`app/`) and Manager (`manager/app/`)

---

## Executive Summary

Clean architecture with good separation of concerns. The Hub is lean and focused, the Manager handles the heavy lifting. The main risks are **race conditions in the spawn path**, **missing authentication on several endpoints**, and **unvalidated input flowing into shell commands**. Nothing catastrophic, but several items that will bite you under load or adversarial conditions.

---

## 🔴 Critical

### 1. No authentication on Hub agent endpoints

`AgentsController` (POST `/agent/message`, `/agent/event`, `/diagnostic`) has **zero authentication**. Any host on the WireGuard network can puppet messages as any agent or spam diagnostics. The `TransactionsController` correctly checks `hs_token`, but the agent endpoints don't check anything.

**Fix:** Add a shared secret or verify the request comes from the agent's known `wg_address`.

### 2. No authentication on Manager API endpoints

`ApiController` (`/resolve`, `/release`, `/status`) and `RelayController` (`/containers/:instance/*`) have `skip_forgery_protection` but no auth at all. Any container on the network can call `/resolve` to spawn agents or `/release` to kill them.

**Fix:** Verify a shared token between Hub↔Manager and Relay↔Manager. Even a simple bearer token from `Surface` config.

### 3. No authentication on Manager admin UI

`AdminController` inherits from `ApplicationController` with no login, session, or IP restriction. The dashboard, configs, freeze/kill actions are open to anyone who can reach port 9200.

**Fix:** Add HTTP basic auth, WireGuard-only binding, or a proper session layer. Even `http_basic_authenticate_with` would be a start.

### 4. Instance name injection into shell commands and file paths

In `Podman.run`, `instance_name` is passed directly to `podman run --name`. In `Spawner.spawn`, it's interpolated into a file path (`spawn_path`). The instance name is derived from `identity` and `channel` params which come from the Hub, which derives them from Matrix user input (identity names). If an identity name contains shell metacharacters or path traversal (`../`), bad things happen.

The `IO.popen(args, ...)` array form in Podman is safe against shell injection, but `--name` with special chars will still cause podman errors or weird behavior. The `File.join` for spawn_path is vulnerable to path traversal if `instance_name` contains `..`.

**Fix:** Validate `instance_name` against `/\A[\w-]+\z/` before use. Add a model validation on `AgentConfig#identity` and sanitize channel slugs.

---

## 🟠 High

### 5. Race condition in Router.resolve (Hub)

```ruby
existing = Agent.resolving.find_by(instance_name: instance_name)
return existing if existing

agent = room.agents.create!(...)
```

Two concurrent messages for the same unresolved agent will both pass the `find_by` check and both try to `create!`. The unique index on `instance_name` saves you from duplicates (one will raise `ActiveRecord::RecordNotUnique`), but the error isn't caught — it'll bubble up as a 500.

**Fix:** Wrap in a rescue for `RecordNotUnique` and return the existing agent, or use `find_or_create_by` with a lock.

### 6. Race condition in Spawner.resolve (Manager)

Same pattern:
```ruby
existing = Container.alive.find_by(instance_name: instance_name)
return { ip: existing.wg_address } if existing

starting = Container.starting.find_by(instance_name: instance_name)
return { ip: starting.wg_address, starting: true } if starting

# ... spawn
```

Two concurrent `/resolve` calls will double-spawn. This means double IP allocation, double WireGuard peering, double podman containers. The unique index on `Container#instance_name` will reject the second `create!`, but by then you've already provisioned WG peers and Forgejo users that won't get cleaned up (the `rescue` re-raises after audit logging, but doesn't teardown partial provisioning).

**Fix:** Use `SELECT ... FOR UPDATE` or an advisory lock on the instance name. The `rescue` block in `spawn` should attempt partial cleanup of WG peers and provisioned services.

### 7. IP allocation race

`allocate_ip` reads all used IPs then picks the first free one — classic TOCTOU. Two concurrent spawns can get the same IP.

**Fix:** Use a database-level lock or a dedicated IP allocation table with unique constraint.

### 8. Thread.new fire-and-forget in Commands

```ruby
register("freeze") do |args, room:|
  Thread.new { ManagerClient.release(instance: nick) }
  "Freezing #{nick}..."
end
```

Unjoined threads with no error handling. If the release fails, nobody knows. The thread also inherits the request's database connection in some configurations, which can cause connection pool issues.

**Fix:** Use `ActiveJob` or at minimum wrap the thread body in error handling and use a separate connection.

### 9. Spawn file contains WG private key and SSH private key on disk

`spawn_path` is written as a regular file in `/spawn/`. The private keys (WG + SSH) sit there in plaintext for the lifetime of the container. If any other container can read `/spawn/` (shared volume?), they get every other agent's network keys.

**Fix:** Use podman secrets (`--secret`) instead of bind-mounting a file, or ensure the spawn directory is only readable by the manager.

---

## 🟡 Medium

### 10. First message to a new agent is silently dropped

When `deliver_to` spawns an agent, the agent goes to `resolving` state. The code then hits:
```ruby
return if agent.resolving?
```

The message that triggered the spawn is never queued or retried. The user's first message vanishes.

**Fix:** Queue the message and deliver it when the `ready` callback fires, or have the relay buffer pre-ready messages.

### 11. Bare `rescue => e` swallowing errors

`Hub::Matrix.room_name` and `recent_messages` have bare `rescue` blocks that return nil/empty. This silently swallows network errors, JSON parse errors, auth errors — all look the same. At minimum log the error.

### 12. HTTPX client singletons with `@client ||=`

Both Hub and Manager use memoized HTTPX clients at the class level. These are shared across all threads/requests. HTTPX handles this correctly for the most part, but the persistent plugin keeps connections open indefinitely. If Synapse restarts, the Hub will keep using a dead connection until HTTPX's internal timeout kicks in.

### 13. `Podman.cp` temp directory cleanup on exception

The `ensure` block in `cp` references `dir` which might not be set if `Dir.mktmpdir` itself fails. Minor, but `dir` is initialized before the begin so it's actually fine — just noting the pattern is fragile.

### 14. Containers table never cleans up `dead` records

`Lifecycle.teardown!` sets state to `dead` but never deletes the record. Over time the containers table grows unbounded. `allocate_ip` queries `where.not(state: "dead")` so it works, but the table bloats.

### 15. `CallbacksController` has no authentication

The Hub's `/callback` endpoint accepts POSTs from anyone. A malicious actor could send fake `ready` or `crash` events to manipulate agent state.

### 16. `update_room_name` in TransactionsController can create rooms from state events

State events for rooms the Hub hasn't seen yet will create Room records via `find_or_initialize_by`. This is probably fine but could lead to phantom rooms if Synapse sends events for rooms the appservice was invited to but shouldn't be tracking.

### 17. Missing `hard_cap` enforcement

The Spawner checks `soft_cap` and freezes the coldest agent, but never checks `hard_cap`. If the soft cap freeze is slow (async teardown), spawns can exceed the hard cap.

---

## 🟢 Low / Suggestions

### 18. No request logging or rate limiting on any endpoint

Matrix can send bursts of events. A room with 100 users typing simultaneously will hammer the transaction endpoint. Consider rate limiting or background job processing.

### 19. `distance_of_time` in Commands is a private class method on a module

Works, but it's defined inside a `register` block context where it won't be accessible. Actually — it's a `private_class_method` on `Commands` itself, called from inside the `register` block which is a `class_eval` context... this will raise `NoMethodError` at runtime. Test this.

### 20. Room slug derivation is lossy

`derive_slug` strips non-word characters and normalizes. Two rooms with names `project-α` and `project-β` would both become `project-`. Not likely in practice but worth noting.

### 21. No index on `containers.wg_address`

`allocate_ip` does `pluck(:wg_address)` on all non-dead containers. Fine at small scale, but add an index if you expect hundreds of containers.

### 22. `provision_ssh_key` and `teardown_ssh_key` are no-ops

The SSH key provisioner doesn't actually install the key anywhere. The teardown is empty. Placeholder code that will confuse future readers.

### 23. `provision_token` generates a token but doesn't store or register it anywhere

The token is generated and returned in the spawn file, but no service actually receives or validates it. Another placeholder.

### 24. Forgejo user creation uses random password but doesn't store it

The created Forgejo user has a random password that's immediately lost. The agent authenticates via SSH key, so this is probably fine, but the dangling password is a minor loose end.

---

## Architecture Notes

**What's good:**
- Clean separation between Hub (stateless routing) and Manager (stateful lifecycle)
- WireGuard as the network layer is excellent — every connection is authenticated at the network level
- The `Surface` module as a single declaration of the Manager's attack surface is a great pattern
- Audit logging is thorough and consistent
- The three-layer service resolution (agent → room → agent+room) is elegant

**What I'd watch:**
- The Hub and Manager have duplicated concepts (Hub's `Agent` vs Manager's `Container`) that could drift. The `instance_name` is the join key, but there's no reconciliation if they disagree on state.
- No background job infrastructure (Sidekiq, GoodJob) — everything is synchronous HTTP or fire-and-forget threads. This will be the first thing that breaks under load.
- SQLite in the Manager (per `database.yml` / the `.sqlite3` file) is fine for single-writer but will deadlock under concurrent spawns. Consider switching to PostgreSQL or at minimum enabling WAL mode.

---

## Priority Order

1. Auth on Hub agent endpoints (#1)
2. Auth on Manager API + admin UI (#2, #3)
3. Input validation on instance names (#4)
4. Spawn race conditions (#5, #6, #7)
5. First-message drop (#10)
6. Hard cap enforcement (#17)
7. Everything else
