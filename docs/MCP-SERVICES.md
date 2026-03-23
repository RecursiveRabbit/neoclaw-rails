# MCP Services — Adding Tools to Agent Pods

How to give agents access to services via MCP tools inside Claude Code.

## The Pattern That Works

Three pieces, four files. Everything else is details.

### 1. The MCP Server (Python)

Lives in `relay/mcp/<service-name>/`. Gets baked into the agent image at `/opt/mcp/<service-name>/`.

```
relay/mcp/
├── ssh/
│   ├── server.py          ← MCP server (stdio protocol)
│   ├── ssh_session.py     ← business logic
│   └── pyproject.toml     ← dependencies (informational)
├── vikunja/
│   ├── server.py
│   └── ...
└── valley/
    └── server.py
```

**Requirements:**
- Must use stdio transport (stdin/stdout JSON-RPC)
- Must use the `mcp` Python SDK (`from mcp.server import Server`)
- Dependencies installed in `/opt/mcp-env/` (the container's Python venv)
- Can read env vars for config (host, port, credentials, etc.)

### 2. The Container Image

**`relay/Containerfile`** — bakes everything in:

```dockerfile
# Python + venv for MCP servers
RUN apt-get install -y python3 python3-pip python3-venv
RUN python3 -m venv /opt/mcp-env && \
    /opt/mcp-env/bin/pip install --no-cache-dir mcp paramiko  # add deps here

# MCP servers — available to all agents
COPY mcp/ /opt/mcp/
```

**When adding a new MCP:** add its pip dependencies to the `pip install` line in the Containerfile. Rebuild the image.

### 3. The Entrypoint (`relay/entrypoint.sh`)

Writes `~/.claude/mcp.json` and `~/.claude/settings.json` at boot. Two things to update:

**mcp.json** — add the server entry:

```json
{
  "mcpServers": {
    "ssh": {
      "command": "/opt/mcp-env/bin/python3",
      "args": ["/opt/mcp/ssh/server.py"],
      "env": {
        "SSH_HOST": "10.0.0.2",
        "SSH_USER": "silas",
        "SSH_KEY_PATH": "/home/agent/.ssh/id_ed25519",
        "SSH_PORT": "22"
      }
    },
    "vikunja": {
      "command": "/opt/mcp-env/bin/python3",
      "args": ["/opt/mcp/vikunja/server.py"],
      "env": {
        "VIKUNJA_URL": "http://10.0.0.2:3456",
        "VIKUNJA_TOKEN": "<from spawn.json>"
      }
    }
  }
}
```

**settings.json** — allow the tools:

```json
{
  "permissions": {
    "allow": [
      "Bash(*)", "Read(*)", "Write(*)", "Edit(*)",
      "Glob(*)", "Grep(*)", "WebFetch(*)", "WebSearch(*)",
      "mcp__ssh(*)",
      "mcp__vikunja(*)"
    ]
  }
}
```

The permission name is `mcp__<server-name>(*)` where `<server-name>` matches the key in `mcpServers`.

### 4. The Relay (`relay/relay.rb`)

Passes `--mcp-config` to Claude Code on the **initial invocation only** (not `--continue`):

```ruby
mcp_config = File.join(Dir.home, ".claude", "mcp.json")
cmd.push("--mcp-config", mcp_config) if File.exist?(mcp_config) && !continue
```

**This is already done.** You don't need to touch the relay when adding new MCPs — it loads whatever is in mcp.json.

---

## Step-by-Step: Adding a New MCP

### Example: Adding Vikunja (task management)

**1. Write the MCP server:**

```bash
mkdir -p relay/mcp/vikunja
# Write server.py with MCP tools for Vikunja's REST API
```

The server should:
- Import from `mcp.server` and `mcp.types`
- Define tools via `@server.list_tools()` and `@server.call_tool()`
- Read config from env vars (URL, token, etc.)
- Use stdio transport

**2. Add pip dependencies to Containerfile:**

```dockerfile
RUN python3 -m venv /opt/mcp-env && \
    /opt/mcp-env/bin/pip install --no-cache-dir \
      mcp paramiko \        # existing
      httpx                 # new: for vikunja HTTP calls
```

**3. Update entrypoint.sh — mcp.json generation:**

Add the server block. Read credentials from spawn.json:

```bash
VIKUNJA_TOKEN=$(ruby -rjson -e '
  s = JSON.parse(File.read(ARGV[0]), symbolize_names: true)
  puts s.dig(:services, :vikunja, :token) || ""
' "$SPAWN_FILE")

# Add to the mcp.json cat block:
"vikunja": {
  "command": "/opt/mcp-env/bin/python3",
  "args": ["/opt/mcp/vikunja/server.py"],
  "env": {
    "VIKUNJA_URL": "http://10.0.0.2:3456",
    "VIKUNJA_TOKEN": "${VIKUNJA_TOKEN}"
  }
}
```

**4. Update entrypoint.sh — settings.json permissions:**

```json
"mcp__vikunja(*)"
```

**5. (If needed) Update the Provisioner:**

If the service requires auth tokens, add provisioning logic in `manager/app/services/provisioner.rb`. The token gets returned from `Provisioner.provision()`, stored in spawn.json under `services.<name>`, and the entrypoint reads it.

**6. Rebuild and deploy:**

```bash
cd relay
sudo podman build -t neoclaw-agent -f Containerfile .
```

**For new/changed MCPs:** freeze the agent and let them respawn. MCP servers are loaded once at session start — `--continue` inherits the old session's MCPs and cannot load new ones. A cold boot is required.

```bash
# Send freeze signal (agent pushes work first)
curl -X POST -H "Content-Type: application/json" -d '{"signal":"freeze"}' http://<agent-wg-ip>:9300/signal

# Then @mention them in Matrix to respawn with the new image
```

**For relay/system fixes (no MCP changes):** hot swap preserves the session:
```bash
sudo script/swap-image.sh silas-general
```

---

## Key Details

### Why `--mcp-config` and not just `~/.claude/mcp.json`?

Claude Code in `-p` (print/headless) mode doesn't auto-load `~/.claude/mcp.json`. The relay must pass it explicitly via `--mcp-config /home/agent/.claude/mcp.json` on the command line. This only happens on the first invocation — `--continue` calls inherit the MCP servers from the session.

**This means adding new MCPs requires a cold boot (freeze + respawn), not a hot swap.** Hot swap uses `--continue` which preserves the session but cannot load new MCP servers. This is a Claude Code limitation, not a NeoClaw one.

### Why env vars instead of CLI args?

The mcp.json `env` block injects environment variables into the MCP server process. This is how credentials flow from spawn.json → entrypoint → mcp.json → MCP server. The server reads them with `os.environ["VIKUNJA_TOKEN"]`. No credentials in CLI args (visible in /proc).

### Why a venv?

Debian/Ubuntu's Python refuses `pip install` outside a venv (`externally-managed-environment`). The venv at `/opt/mcp-env/` is created once in the Containerfile. All MCP servers share it.

### MCP server naming

The key in `mcpServers` (e.g., `"ssh"`, `"vikunja"`) determines:
- The tool prefix in Claude Code: `mcp__ssh__ssh_execute`, `mcp__vikunja__list_tasks`
- The permission pattern: `mcp__ssh(*)`, `mcp__vikunja(*)`

Keep names short and lowercase.

### Hot swap for image changes

When you rebuild the image, running pods still have the old one. Use the hot-swap script to update without a full reboot:

```bash
sudo script/swap-image.sh silas-general
```

This copies workspace + session out, kills the old pod, starts a new one, copies files back. The relay detects the populated workspace and uses `--continue` — the agent resumes in seconds, not minutes.

---

## Service Inventory

| Service | MCP Dir | Status | Provision Type | Notes |
|---------|---------|--------|----------------|-------|
| SSH | `relay/mcp/ssh/` | **Working** | ssh_key → authorized_keys | paramiko PTY session |
| Vikunja | `relay/mcp/vikunja/` | **Working** | vikunja → token service (port 8890) | Ephemeral token per session, PBKDF2 direct insert |
| Valley | `relay/mcp/valley/` | **Working** | valley → token service (port 8889) | Evennia game world |
| ComfyUI | `relay/mcp/comfyui/` | Configured | none (WG-only) | Image generation, needs socat forwarder |
| Matrix | `relay/mcp/matrix/` | Configured | none | Chat (might not need MCP — agents talk through the Hub) |
| Zigbee | `relay/mcp/zigbee/` | Configured | none | Home automation, needs socat forwarder |
| Semantic Search | — | TODO | — | May be HTTP-only, no MCP needed |

---

## File Checklist for New MCPs

- [ ] `relay/mcp/<name>/server.py` — MCP server
- [ ] `relay/Containerfile` — pip dependencies
- [ ] `relay/entrypoint.sh` — mcp.json entry + settings.json permission
- [ ] `manager/app/services/provisioner.rb` — auth provisioning (if needed)
- [ ] `manager/db/seeds.rb` — ServiceType with provision_type (if needed)
- [ ] Rebuild image: `sudo podman build -t neoclaw-agent -f Containerfile .`
- [ ] Deploy: `sudo script/swap-image.sh <instance>` or freeze + respawn
