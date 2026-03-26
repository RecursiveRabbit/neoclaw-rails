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

  svc = s[:services] || {}
  mode = if svc.key?(:"internet-full")
    "full"
  elsif svc.key?(:"internet-web")
    "web"
  else
    "none"
  end
  host_net = svc.key?(:"host-network") ? "1" : "0"
  puts "INTERNET_MODE=#{mode}"
  puts "HOST_NETWORK=#{host_net}"
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
  conf = "[Interface]\nPrivateKey = #{n[:wg_private_key]}\n"
  (n[:peers] || []).each do |p|
    conf += "\n[Peer]\nPublicKey = #{p[:public_key]}\nEndpoint = #{p[:endpoint]}\n"
    conf += "AllowedIPs = #{p[:allowed_ips]}\nPersistentKeepalive = 25\n"
  end
  File.write("/etc/wireguard/wg0.conf", conf)
' "$SPAWN_FILE"

chmod 600 /etc/wireguard/wg0.conf

# Manual WG setup — wg-quick's AllowedIPs=0.0.0.0/0 handling needs
# sysctl privileges containers don't have. We just need the interface
# up and a default route through the Router.
ip link add wg0 type wireguard
wg setconf wg0 /etc/wireguard/wg0.conf
ip addr add "${WG_ADDRESS}/32" dev wg0
ip link set wg0 up
ip route add 10.0.0.0/16 dev wg0
if ! ip link show wg0 up >/dev/null 2>&1; then
    log "FATAL: wireguard failed to start"
    exit 1
fi
log "wireguard up (${WG_ADDRESS})"

# --- Egress policy enforcement ---
# Default residents: WG service plane only.
# Optional pseudo services from spawn:
#   INTERNET_MODE=none|web|full
#   HOST_NETWORK=1 allows LAN host endpoint (10.7.7.62)
if command -v nft >/dev/null 2>&1; then
  # Build container-local egress policy with nftables.
  # We avoid touching host rules; this runs inside the container netns.
  nft delete table inet neoclaw_local 2>/dev/null || true
  nft add table inet neoclaw_local
  nft add chain inet neoclaw_local output '{ type filter hook output priority 0; policy accept; }'

  case "${INTERNET_MODE}" in
    full)
      # No extra restrictions in full mode.
      ;;
    web)
      nft -f - <<'NFT' || true
flush chain inet neoclaw_local output
add rule inet neoclaw_local output oifname "lo" accept
add rule inet neoclaw_local output ct state established,related accept
add rule inet neoclaw_local output ip daddr 10.0.0.0/16 accept
add rule inet neoclaw_local output ip protocol tcp tcp dport {80,443} accept
add rule inet neoclaw_local output ip protocol udp udp dport 53 accept
add rule inet neoclaw_local output ip protocol tcp tcp dport 53 accept
add rule inet neoclaw_local output counter reject
NFT
      ;;
    none|*)
      nft -f - <<'NFT' || true
flush chain inet neoclaw_local output
add rule inet neoclaw_local output oifname "lo" accept
add rule inet neoclaw_local output ct state established,related accept
add rule inet neoclaw_local output ip daddr 10.0.0.0/16 accept
NFT
      if [ "${HOST_NETWORK}" = "1" ]; then
        nft add rule inet neoclaw_local output ip daddr 10.7.7.62/32 accept || true
      fi
      nft add rule inet neoclaw_local output counter reject || true
      ;;
  esac

  log "egress policy applied (nft): internet=${INTERNET_MODE} host_network=${HOST_NETWORK}"
fi

# --- Claude credentials ---
AGENT_HOME="/home/agent"
CLAUDE_DIR="${AGENT_HOME}/.claude"
mkdir -p "$CLAUDE_DIR"

if [ -f /run/secrets/claude/.credentials.json ]; then
    # Copy credentials into agent-owned home. The mounted secret may be
    # root:root 600 and unreadable by `agent` when bind-mounted.
    cp /run/secrets/claude/.credentials.json "${CLAUDE_DIR}/.credentials.json"
    chmod 600 "${CLAUDE_DIR}/.credentials.json"
    chown agent:agent "${CLAUDE_DIR}/.credentials.json"
    log "claude credentials copied"
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

# --- Forgejo API token ---
# Written to ~/.forgejo-token so agents can use the Forgejo REST API
# for creating PRs, requesting reviews, etc.
FORGEJO_TOKEN=$(ruby -rjson -e '
  s = JSON.parse(File.read(ARGV[0]), symbolize_names: true)
  puts s.dig(:services, :forgejo, :api_token) || ""
' "$SPAWN_FILE")

if [ -n "${FORGEJO_TOKEN}" ]; then
    echo "${FORGEJO_TOKEN}" > "${AGENT_HOME}/.forgejo-token"
    chmod 600 "${AGENT_HOME}/.forgejo-token"
    chown agent:agent "${AGENT_HOME}/.forgejo-token"
    # Also set in gitconfig so `git` can use it for HTTPS operations
    gosu agent git config --global credential.helper "!f() { echo \"password=${FORGEJO_TOKEN}\"; }; f"
    log "forgejo API token installed"
fi

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

  # SSH — include only if explicitly provisioned for this agent
  if svc[:ssh] && File.exist?("#{agent_home}/.ssh/id_ed25519")
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

  # Vikunja — include only when token is provisioned
  if svc[:vikunja] && !svc.dig(:vikunja, :token).to_s.empty?
    vik_base = svc.dig(:vikunja, :url).to_s
    vik_api = if !vik_base.empty?
      "#{vik_base.sub(%r{/$}, "")}/api/v1"
    else
      "http://#{host_ip}:3456/api/v1"
    end

    config[:mcpServers][:vikunja] = {
      command: python,
      args: ["/opt/mcp/vikunja/server.py"],
      env: {
        VIKUNJA_API_URL: vik_api,
        VIKUNJA_TOKEN: svc.dig(:vikunja, :token).to_s,
        VIKUNJA_PROJECT_ID: (svc.dig(:vikunja, :project_id) || "1").to_s
      }
    }
  end

  # Valley — include if provisioned
  if svc[:valley]
    valley_base = svc.dig(:valley, :url).to_s
    valley_api = if !valley_base.empty?
      "#{valley_base.sub(%r{/$}, "")}/api/command"
    else
      "http://#{host_ip}:8888/api/command"
    end

    config[:mcpServers][:valley] = {
      command: python,
      args: ["/opt/mcp/valley/server.py"],
      env: {
        VALLEY_API: valley_api,
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
        MATRIX_HOMESERVER: (svc.dig(:matrix, :homeserver).to_s.empty? ? "http://#{host_ip}:8008" : svc.dig(:matrix, :homeserver).to_s),
        MATRIX_TOKEN: svc.dig(:matrix, :token).to_s,
        MATRIX_USER_ID: svc.dig(:matrix, :user_id).to_s
      }
    }
  end

  # Archiver — semantic retrieval over session/workspace archives
  if svc[:archiver]
    config[:mcpServers][:archiver] = {
      command: python,
      args: ["/opt/mcp/archiver/server.py"],
      env: {
        ARCHIVER_URL: (svc.dig(:archiver, :url).to_s.empty? ? "http://#{host_ip}:4010" : svc.dig(:archiver, :url).to_s),
        ARCHIVER_API_KEY: (svc.dig(:archiver, :api_key) || "").to_s
      }
    }
  end

  File.write(ARGV[1], JSON.pretty_generate(config))
  $stderr.puts config[:mcpServers].keys.join(" ")
' "$SPAWN_FILE" "${CLAUDE_DIR}/mcp.json" 2>&1 | while read -r line; do log "mcp config: $line"; done

chown agent:agent "${CLAUDE_DIR}/mcp.json"

# --- Service health probes ---
# Probe each provisioned service. Write results to service-status.md so the
# agent knows what's working before it wastes context retrying broken tools.
# Quick probes only — fail fast, don't block boot.
ruby -rjson -rnet/http -e '
  spawn = JSON.parse(File.read(ARGV[0]), symbolize_names: true)
  host_ip = "'"${HOST_IP}"'"
  svc = spawn[:services] || {}
  mcp = JSON.parse(File.read(ARGV[1]), symbolize_names: true)
  lines = ["# Service Status", "", "Probed at boot. If a service is DOWN, do not retry — note the error and move on.", ""]

  def probe(url, timeout: 3)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = timeout
    http.read_timeout = timeout
    http.get(uri.request_uri)
    "UP"
  rescue => e
    "DOWN (#{e.message})"
  end

  # SSH — try TCP connect
  if mcp[:mcpServers]&.key?(:ssh)
    begin
      s = TCPSocket.new(host_ip, 22)
      s.close
      lines << "- **ssh**: UP"
    rescue => e
      lines << "- **ssh**: DOWN (#{e.message})"
    end
  end

  # Vikunja
  if svc[:vikunja] && mcp[:mcpServers]&.key?(:vikunja)
    token = svc.dig(:vikunja, :token).to_s
    if token.empty?
      lines << "- **vikunja**: DOWN (no token provisioned)"
    else
      status = probe("http://#{host_ip}:3456/api/v1/tasks/all")
      lines << "- **vikunja**: #{status}"
    end
  end

  # Valley
  if svc[:valley] && mcp[:mcpServers]&.key?(:valley)
    status = probe("http://#{host_ip}:8888/api/command?cmd=look&token=#{svc.dig(:valley, :token)}")
    lines << "- **valley**: #{status}"
  end

  # ComfyUI
  if svc[:comfyui] && mcp[:mcpServers]&.key?(:comfyui)
    status = probe("http://#{host_ip}:8188/queue")
    lines << "- **comfyui**: #{status}"
  end

  # Zigbee/MQTT — just TCP probe the broker
  if svc[:zigbee] && mcp[:mcpServers]&.key?(:zigbee)
    begin
      s = TCPSocket.new(host_ip, 1883)
      s.close
      lines << "- **zigbee**: UP (MQTT broker reachable)"
    rescue => e
      lines << "- **zigbee**: DOWN (#{e.message})"
    end
  end

  if lines.length <= 4
    lines << "- No services provisioned."
  end

  File.write(ARGV[2], lines.join("\n") + "\n")
  $stderr.puts lines.select { |l| l.start_with?("- ") }.join(", ")
' "$SPAWN_FILE" "${CLAUDE_DIR}/mcp.json" "${AGENT_HOME}/service-status.md" 2>&1 | while read -r line; do log "services: $line"; done

chown agent:agent "${AGENT_HOME}/service-status.md"

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
