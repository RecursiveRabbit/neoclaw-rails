# NeoClaw Rails — Security Review

**Reviewer:** Kael  
**Date:** 2026-03-17  
**Scope:** Full codebase review — Hub, Manager, Relay, wg-admin, network architecture  
**Status:** Draft architecture (pre-deployment)

---

## Executive Summary

The architecture is fundamentally sound. The separation of concerns (Hub knows routing, Manager knows provisioning, Relay knows I/O) creates clean trust boundaries. WireGuard-as-authorization is elegant and the wg-admin helper is correctly minimal. The main risks are: an unauthenticated admin UI, missing inter-component authentication on several API surfaces, spawn.json containing plaintext secrets on a shared filesystem, and the `config/master.key` committed to the repo.

**Severity ratings:** 🔴 Critical | 🟠 High | 🟡 Medium | 🔵 Low | ⚪ Informational

---

## 🔴 Critical Findings

### C1: `config/master.key` committed to repository

The Hub's Rails master key (`0ae0d840992ab1f401b6934a3674d86a`) is checked into the repo at `config/master.key`. This key decrypts `credentials.yml.enc`. Anyone with repo access (including every agent that clones it) can decrypt all Rails credentials.

**Fix:** Remove from repo, add to `.gitignore`, rotate the key, re-encrypt credentials. Inject via environment variable `RAILS_MASTER_KEY` at runtime.

### C2: Admin UI has zero authentication

The Manager's admin UI (dashboard, agent configs, containers, freeze/kill actions) inherits from `AdminController`, which only adds `allow_browser versions: :modern`. There is no login, no session auth, no HTTP basic auth — nothing. Anyone who can reach `:9201` (or `:9200` if same process) has full administrative control: view all configs, toggle services, freeze/kill containers, view audit logs.

The admin UI is supposedly only reachable over WireGuard, but this is a single layer. If the Manager container ever gets port-forwarded, or a service on the WG network is compromised, the admin UI is wide open.

**Fix:** Add HTTP basic auth at minimum (`AdminController` before_action), or session-based auth. Even a single shared password from an env var would be a massive improvement.

### C3: Hub ↔ Manager API is unauthenticated

`POST /resolve`, `POST /release`, `GET /status` on the Manager have no auth. Any host on the WireGuard network that can reach `10.0.0.2:9200` can spawn arbitrary agents, release running ones, or enumerate the system. The Hub→Manager client (`ManagerClient`) sends no credentials.

Similarly, the Manager→Hub callbacks (`POST /callback`) carry no auth token. A compromised agent container could forge callback events (fake "released", "ready", "crash") to the Hub, manipulating the routing table.

**Fix:** Shared secret (bearer token) between Hub and Manager, verified on both sides. The callback path is especially important since agent containers can reach the Hub.

---

## 🟠 High Findings

### H1: Relay endpoints are unauthenticated

The Relay inside each agent container exposes:
- `POST /message` — inject arbitrary messages into Claude Code
- `POST /signal` — trigger freeze/sunset
- `GET /health` — information disclosure

Any peer on the WireGuard network that can route to an agent's IP (`10.0.1.X:9300`) can inject messages or force a freeze. Since agents are peered with multiple services, a compromised service could send messages to any agent it can route to.

**Fix:** The Relay should verify a shared secret (from spawn.json) on `/message` (from Hub) and `/signal` (from Manager). Different tokens for each — the Hub shouldn't be able to signal freeze, and the Manager shouldn't be able to inject messages.

### H2: spawn.json contains plaintext private keys on shared filesystem

`spawn.json` is written to `Surface.spawn_dir` (`/var/lib/neoclaw/spawn/` on host, `/spawn` in Manager container) and contains:
- WireGuard private key
- SSH private key
- Service tokens
- Forgejo credentials

This file persists on disk. While `Lifecycle.teardown!` calls `FileUtils.rm_f(spawn_path)`, a crash before teardown leaves secrets on the host filesystem. Multiple spawn files accumulate in the same directory.

**Fix:** 
1. Use `podman secret` instead of volume-mounting plaintext files
2. Or: write spawn.json with restrictive permissions (0600), and ensure cleanup on all exit paths (including a periodic reaper for orphaned files)
3. Consider encrypting spawn.json at rest with a per-container key

### H3: Forgejo user creation uses instance_name in shell-adjacent contexts

`Provisioner.provision_forgejo` interpolates `instance_name` into API URLs:
```ruby
http.post("#{base_url}/api/v1/admin/users/#{instance_name}/keys", ...)
http.put("#{base_url}/api/v1/repos/#{config.repo}/collaborators/#{instance_name}", ...)
```

While `instance_name` is derived from `"#{identity}-#{channel}"` and identity/channel come from Hub parameters, there's no validation that these are safe for URL path segments. A channel name like `../admin` could cause path traversal in the Forgejo API.

**Fix:** Validate `instance_name` format (alphanumeric + hyphens only) at creation time in `Spawner`. Use `CGI.escape` or `URI.encode_www_form_component` for URL interpolation.

### H4: wg-admin config persistence via shell

In `wg-admin.rb`, after modifying a peer:
```ruby
system("bash", "-c", "wg showconf #{iface} > /etc/wireguard/#{iface}.conf")
```

While `iface` is validated against `ALLOWED_INTERFACES`, this still uses shell redirection via `bash -c`. The validation is correct *today*, but if someone adds an interface name with special characters to `ALLOWED_INTERFACES`, it becomes injectable.

**Fix:** Use Ruby file I/O instead of shell redirection:
```ruby
conf = `wg showconf #{iface}`
File.write("/etc/wireguard/#{iface}.conf", conf)
```

---

## 🟡 Medium Findings

### M1: Hub `ApplicationController` globally disables CSRF protection

```ruby
class ApplicationController < ActionController::Base
  skip_forgery_protection
end
```

The Hub is API-only, so this is reasonable, but it's worth noting. If any browser-facing views are ever added to the Hub, CSRF is gone.

**Fix:** Consider using `ActionController::API` instead of `ActionController::Base` to make the API-only intent explicit, or scope the skip to specific controllers.

### M2: IP pool is trivially exhaustible (DoS)

`Spawner.allocate_ip` iterates `10.0.1.1` through `10.0.1.254`. With no auth on the Manager API (C3), an attacker could call `/resolve` 254 times with unique channels and exhaust the pool, preventing legitimate spawns.

Even with auth fixed, there's no rate limiting on resolve requests.

**Fix:** Rate-limit `/resolve`. Consider expanding to a /16 if 254 agents is too tight. Add cleanup of stale IPs.

### M3: `provision_token` generates tokens but doesn't store or validate them

```ruby
def provision_token(service, instance_name:)
  token = SecureRandom.hex(32)
  { token: token, url: "http://#{service.wg_ip}" }
end

def teardown_token(service, instance_name:)
  # empty
end
```

Tokens are generated and handed to agents but never registered with the target service and never revoked on teardown. This is a placeholder — either the services accept any token (no auth), or these tokens are never validated. Either way, teardown is a no-op.

**Fix:** Either implement token registration/revocation with each service, or document that these services rely solely on WireGuard peering for access control (and remove the token theater).

### M4: SSH key provisioning is incomplete

`provision_ssh_key` returns host/user info but never actually installs the key:
```ruby
def provision_ssh_key(service, instance_name:, ssh_pubkey:)
  identity = instance_name.split("-").first
  { ssh_host: service.wg_ip, ssh_user: identity }
end
```

The spec says it should "append to authorized_keys" but the implementation is a no-op. `teardown_ssh_key` is also empty.

**Fix:** Implement or remove. If SSH is handled by Forgejo's SSH, document that and drop the separate SSH service type.

### M5: Relay writes SSH key with `StrictHostKeyChecking no`

```ruby
ssh_config = "Host *\n  IdentityFile #{ssh_key_path}\n  StrictHostKeyChecking no\n"
```

Disabling host key checking for all hosts means a MITM on the WireGuard network could intercept git operations. Since WG provides encryption, this is lower risk, but it's still a bad habit.

**Fix:** Pin the Forgejo host key in the SSH config (can be included in spawn.json).

### M6: Container gets NET_ADMIN capability

Both the Manager and agent containers run with `--cap-add NET_ADMIN`. For the Manager this makes sense (WireGuard). For agent containers, this allows the agent to modify its own network interfaces — potentially adding routes, sniffing traffic, or reconfiguring WireGuard peers.

**Fix:** Consider whether agents actually need NET_ADMIN. The relay configures WG on boot — could this be done by an init process that drops the capability before exec'ing the relay?

---

## 🔵 Low Findings

### L1: Relay `clone_repo` has TOCTOU on workspace directory

```ruby
if Dir.exist?(WORKSPACE)
  system("git", "-C", WORKSPACE, "pull", "--ff-only") or log("Pull failed — starting fresh")
end
unless Dir.exist?("#{WORKSPACE}/.git")
  FileUtils.rm_rf(WORKSPACE)
  system("git", "clone", repo_url, WORKSPACE) or raise "Clone failed"
end
```

Race condition if two processes check simultaneously. Not exploitable in practice since the relay is single-instance per container.

### L2: Context usage estimate is rough

```ruby
@context_usage = (input + output).to_f / 200_000
```

Hard-coded 200k context window assumption. If the model changes, sunset warnings fire at the wrong time. Not a security issue directly, but could lead to agents running out of context without warning.

### L3: Thread usage in Hub Commands

```ruby
Thread.new { ManagerClient.release(instance: nick) }
```

Fire-and-forget threads with no error handling or timeout. If the Manager is unreachable, these threads hang. Not a vulnerability but could leak threads under load.

### L4: No TLS anywhere inside the WireGuard network

All inter-component HTTP is plaintext. WireGuard provides encryption at the network layer, so this is defense-in-depth — the current design is fine, but worth noting: if WG is ever compromised or bypassed, all traffic is readable.

---

## ⚪ Architectural Observations

### The Surface initializer is excellent

`config/initializers/surface.rb` is the best file in the codebase from a security perspective. Every external dependency, credential, mount point, and connection is declared in one place. This is a security manifest. If you want to audit what the Manager can reach, you read one file. Keep this pattern.

### WireGuard-as-authorization is sound but single-layer

The design uses WG peer topology as the primary (and often only) access control for services. This is clean and simple. The risk: if an agent somehow gets a peer added to an interface it shouldn't access (bug in Spawner, race condition, stale peer), there's no secondary auth layer for services like ComfyUI. The spec acknowledges this ("defense in depth that also serves as the primary auth layer"). For simple services this is fine. For anything with data mutation capability, consider adding service-level tokens.

### The Hub's separation from provisioning is clean

The Hub genuinely doesn't know about containers, auth, or WireGuard. The interface is two endpoints: resolve and release. This is the right boundary. A compromised Hub can spawn/release agents but can't provision auth or modify the network.

### Audit logging is good

The Manager logs every significant event to `AuditLog`. This is append-only by convention (no delete/update endpoints). The `AuditLogsController` is read-only. Good pattern — but consider making the table literally append-only (revoke DELETE at the database level).

### The relay trust model

The relay runs inside the agent container alongside Claude Code, which has `--dangerously-skip-permissions`. This means Claude Code can:
1. Read spawn.json (contains WG private key, SSH private key, all service tokens)
2. Modify the relay process
3. Reconfigure WireGuard (has NET_ADMIN)
4. Reach any service it's peered with

This is by design — agents need these capabilities. But it means a jailbroken Claude Code session has full access to everything in spawn.json. The mitigation is ephemeral credentials (teardown revokes everything). Make sure teardown is reliable.

---

## Priority Remediation Order

1. **Remove `config/master.key` from repo** (C1) — 5 minutes, do it now
2. **Add auth to admin UI** (C2) — 30 minutes, HTTP basic auth
3. **Add shared secret to Hub↔Manager API** (C3) — 1 hour
4. **Add auth to Relay endpoints** (H1) — 1 hour  
5. **Validate instance_name format** (H3) — 15 minutes
6. **Fix wg-admin shell usage** (H4) — 10 minutes
7. **Secure spawn.json** (H2) — design decision needed
8. **Everything else** — iterative

---

## Summary

The architecture is well-designed with clean trust boundaries. The main gap is that the trust boundaries are enforced by network topology alone — most API surfaces lack authentication. This is the "trusted network" antipattern: everything inside WireGuard trusts everything else. Adding bearer tokens to the three inter-component API surfaces (Hub→Manager, Manager→Hub, Hub/Manager→Relay) would make this system significantly more resilient to lateral movement from a single compromised component.

The wg-admin helper is correctly minimal and well-validated. The Surface initializer is a genuinely good security pattern. The audit logging is thorough. The ephemeral credential model (provision on spawn, revoke on teardown) is the right approach.

Fix the critical items, add auth to the API surfaces, and this is a solid system.
