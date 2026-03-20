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
wg-quick up wg0
log "wireguard up (${WG_ADDRESS})"

# --- Claude credentials ---
AGENT_HOME="/home/agent"
CLAUDE_DIR="${AGENT_HOME}/.claude"
mkdir -p "$CLAUDE_DIR"

if [ -f /run/secrets/claude-credentials ]; then
    # Symlink to the bind mount so credential refreshes on the host
    # are visible immediately. No stale copies.
    ln -sf /run/secrets/claude-credentials "${CLAUDE_DIR}/.credentials.json"
    chown -h agent:agent "${CLAUDE_DIR}/.credentials.json"
    log "claude credentials linked"
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
      "WebSearch(*)"
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

# --- Own everything ---
chown -R agent:agent "$CLAUDE_DIR"
chown -R agent:agent "$AGENT_HOME"

# =====================================================================
# Phase 2: Start Relay (as agent user)
# =====================================================================

log "starting relay"
exec gosu agent ruby /app/relay.rb
