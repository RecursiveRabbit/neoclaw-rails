#!/bin/bash
set -euo pipefail

# NeoClaw-Rails Agent Entrypoint
#
# Phase 1 (root): WireGuard, secrets, git credentials
# Phase 2 (agent): Start Relay — agent clones its own workspace
#
# spawn.json is mounted at /run/secrets/spawn.json by the Manager.
# Claude credentials at /run/secrets/claude-credentials.

log() { echo "[entrypoint] $*"; }

SPAWN_FILE="/run/secrets/spawn.json"

if [ ! -f "$SPAWN_FILE" ]; then
    log "FATAL: no spawn file at $SPAWN_FILE"
    exit 1
fi

# Parse spawn.json with Ruby (already installed)
eval "$(ruby -rjson -e '
  s = JSON.parse(File.read(ARGV[0]), symbolize_names: true)
  puts "IDENTITY=#{s[:identity]}"
  puts "INSTANCE=#{s[:instance]}"
  puts "CHANNEL=#{s[:channel]}"
  n = s[:network]
  puts "WG_PRIVATE_KEY=#{n[:wg_private_key]}"
  puts "WG_ADDRESS=#{n[:wg_address]}"
  g = s[:git] || {}
  ssh_key = (g[:ssh_key] || "").gsub("\n","\\n")
  puts "SSH_KEY=\"#{ssh_key}\""
  puts "FORGE_URL=#{g[:forge_url] || "http://10.0.0.3:3000"}"
  puts "REPO=#{g[:repo] || ""}"
' "$SPAWN_FILE")"

log "starting ${INSTANCE} (${IDENTITY}) in #${CHANNEL}"

# =====================================================================
# Phase 1: Root setup
# =====================================================================

# --- WireGuard ---
mkdir -p /etc/wireguard

ruby -rjson -e '
  s = JSON.parse(File.read(ARGV[0]), symbolize_names: true)
  n = s[:network]
  conf = "[Interface]\nPrivateKey = #{n[:wg_private_key]}\nAddress = #{n[:wg_address]}/32\n"
  (n[:peers] || []).each do |p|
    conf += "\n[Peer]\nPublicKey = #{p[:public_key]}\nEndpoint = #{p[:endpoint]}\n"
    conf += "AllowedIPs = #{p[:allowed_ips]}\nPersistentKeepalive = 25\n"
  end
  File.write("/etc/wireguard/wg0.conf", conf)
' "$SPAWN_FILE"

chmod 600 /etc/wireguard/wg0.conf
if ! wg-quick up wg0 2>&1; then
    log "FATAL: wireguard failed to start"
    # Don't try to reach Manager without WG — it must not be reachable
    # outside the mesh. Manager's watchdog will detect the failed pod.
    exit 1
fi
log "wireguard up (${WG_ADDRESS})"

# --- Claude credentials ---
AGENT_HOME="/home/agent"
CLAUDE_DIR="${AGENT_HOME}/.claude"
mkdir -p "$CLAUDE_DIR"

if [ -f /run/secrets/claude/.credentials.json ]; then
    # Symlink to the directory bind mount. Directory mounts reflect
    # file changes on the host — credentials stay live as Claude Code
    # refreshes them.
    ln -sf /run/secrets/claude/.credentials.json "${CLAUDE_DIR}/.credentials.json"
    chown -h agent:agent "${CLAUDE_DIR}/.credentials.json"
    log "claude credentials linked (live mount)"
fi

# --- Claude settings: auto-accept all permissions ---
cat > "${CLAUDE_DIR}/settings.json" <<'SETEOF'
{
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)",
      "Glob(*)",
      "Grep(*)",
      "WebFetch(*)",
      "WebSearch(*)",
      "mcp__ssh(*)",
      "mcp__vikunja(*)",
      "mcp__valley(*)",
      "mcp__comfyui(*)",
      "mcp__zigbee(*)",
      "mcp__matrix(*)"
    ],
    "deny": []
  }
}
SETEOF

chown agent:agent "${CLAUDE_DIR}/settings.json"

# --- SSH key for git push/pull ---
if [ -n "${SSH_KEY}" ]; then
    SSH_DIR="${AGENT_HOME}/.ssh"
    mkdir -p "$SSH_DIR"
    printf '%b' "$SSH_KEY" > "${SSH_DIR}/id_ed25519"
    chmod 600 "${SSH_DIR}/id_ed25519"
    cat > "${SSH_DIR}/config" <<'SSHEOF'
Host *
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
SSHEOF
    chown -R agent:agent "$SSH_DIR"
    log "ssh key installed"
fi

# --- Git identity ---
gosu agent git config --global user.name "$IDENTITY"
gosu agent git config --global user.email "${IDENTITY}@neoclaw.local"

# --- MCP config ---
# All services are on the host (10.0.0.2), reached through the Router.
# Only include MCPs for services present in spawn.json's services block.
# Missing/unreachable services would crash on startup and block Claude Code.
HOST_IP="10.0.0.2"

# Build MCP config — only include servers for provisioned services.
# Unreachable services crash on startup and block Claude Code for minutes.
ruby -rjson -e '
  spawn = JSON.parse(File.read(ARGV[0]), symbolize_names: true)
  host_ip = "'"${HOST_IP}"'"
  agent_home = "'"${AGENT_HOME}"'"
  svc = spawn[:services] || {}

  config = { mcpServers: {} }
  python = "/opt/mcp-env/bin/python3"

  # SSH — include if agent has an SSH key
  if File.exist?("#{agent_home}/.ssh/id_ed25519")
    config[:mcpServers][:ssh] = {
      command: python,
      args: ["/opt/mcp/ssh/server.py"],
      env: {
        SSH_HOST: host_ip,
        SSH_USER: (svc.dig(:ssh, :user) || spawn[:identity]).to_s,
        SSH_KEY_PATH: "#{agent_home}/.ssh/id_ed25519",
        SSH_PORT: (svc.dig(:ssh, :port) || 22).to_s
      }
    }
  end

  # Vikunja — include if provisioned
  if svc[:vikunja]
    config[:mcpServers][:vikunja] = {
      command: python,
      args: ["/opt/mcp/vikunja/server.py"],
      env: {
        VIKUNJA_API_URL: "http://#{host_ip}:3456/api/v1",
        VIKUNJA_TOKEN: (svc.dig(:vikunja, :token) || "").to_s,
        VIKUNJA_PROJECT_ID: (svc.dig(:vikunja, :project_id) || "1").to_s
      }
    }
  end

  # Valley — include if provisioned
  if svc[:valley]
    config[:mcpServers][:valley] = {
      command: python,
      args: ["/opt/mcp/valley/server.py"],
      env: {
        VALLEY_API: "http://#{host_ip}:8888/api/command",
        VALLEY_TOKEN: (svc.dig(:valley, :token) || "").to_s
      }
    }
  end

  # ComfyUI — include if provisioned
  if svc[:comfyui]
    config[:mcpServers][:comfyui] = {
      command: python,
      args: ["/opt/mcp/comfyui/server.py"],
      env: {
        COMFYUI_URL: "http://#{host_ip}:8188"
      }
    }
  end

  # Zigbee — include if provisioned
  if svc[:zigbee]
    config[:mcpServers][:zigbee] = {
      command: python,
      args: ["/opt/mcp/zigbee/server.py"],
      env: {
        MQTT_HOST: host_ip,
        MQTT_PORT: "1883"
      }
    }
  end

  # Matrix — include if token provided
  if svc[:matrix] && !svc.dig(:matrix, :token).to_s.empty?
    config[:mcpServers][:matrix] = {
      command: python,
      args: ["/opt/mcp/matrix/server.py"],
      env: {
        MATRIX_HOMESERVER: "http://#{host_ip}:8008",
        MATRIX_TOKEN: svc.dig(:matrix, :token).to_s,
        MATRIX_USER_ID: svc.dig(:matrix, :user_id).to_s
      }
    }
  end

  File.write(ARGV[1], JSON.pretty_generate(config))
  $stderr.puts config[:mcpServers].keys.join(" ")
' "$SPAWN_FILE" "${CLAUDE_DIR}/mcp.json" 2>&1 | while read -r line; do log "mcp config: $line"; done

chown agent:agent "${CLAUDE_DIR}/mcp.json"

# --- Own everything ---
chown -R agent:agent "$CLAUDE_DIR"
chown -R agent:agent "$AGENT_HOME"

# =====================================================================
# Phase 2: Start Relay (as agent user)
# =====================================================================

# If SWAP_HOLD is set, wait for files to be restored before starting.
# The swap script sets this, copies workspace + session, then removes the hold.
if [ "${SWAP_HOLD:-}" = "1" ]; then
    HOLD_FILE="/tmp/.swap-hold"
    touch "$HOLD_FILE"
    log "swap hold — waiting for files..."
    while [ -f "$HOLD_FILE" ]; do sleep 0.5; done
    # Re-own everything after files are copied in
    chown -R agent:agent "$CLAUDE_DIR"
    chown -R agent:agent "$AGENT_HOME"
    chown -R agent:agent /workspace
    log "swap hold released"
fi

log "starting relay"
exec gosu agent ruby /app/relay.rb
