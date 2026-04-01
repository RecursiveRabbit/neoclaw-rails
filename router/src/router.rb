#!/usr/bin/env ruby
# router.rb — WG-Router API server
#
# The central security enforcement point for NeoClaw.
# Manages WireGuard peers and nftables firewall rules.
# API is restricted to the Manager's WG IP.
#
# Zero external dependencies. Ruby stdlib only.

require "webrick"
require "json"
require "yaml"

require_relative "state"
require_relative "firewall"
require_relative "wireguard"

# --- Config ---

CONFIG_PATH = ENV.fetch("ROUTER_CONFIG", "/etc/router/config.yml")
STATE_PATH = ENV.fetch("ROUTER_STATE", "/data/agents.json")

config = YAML.load_file(CONFIG_PATH)

API_PORT = (config.dig("router", "api_port") || 8080).to_i
MANAGER_IP = config.dig("network", "manager_ip")

# --- Validation ---

PUBKEY_RE = /\A[A-Za-z0-9+\/]{43}=\z/
IP_CIDR_RE = /\A(\d{1,3}\.){3}\d{1,3}\/32\z/
NAME_RE = /\A[a-z0-9][a-z0-9\-]{0,62}\z/

# --- Components ---

$state = State.new(STATE_PATH)
$firewall = Firewall.new(config)
$wireguard = WireGuard.new(config)
$config = config

# --- Helpers ---

def log(msg)
  $stderr.puts "[#{Time.now.utc.iso8601}] #{msg}"
end

def source_ip(req)
  req.peeraddr[3]
end

def authorized?(req)
  source_ip(req) == MANAGER_IP
end

def json_body(req)
  JSON.parse(req.body || "{}")
rescue JSON::ParserError
  nil
end

def json_ok(res, body, status: 200)
  res.status = status
  res.content_type = "application/json"
  res.body = JSON.generate(body)
end

def json_err(res, msg, status: 400)
  res.status = status
  res.content_type = "application/json"
  res.body = JSON.generate(error: msg)
end

def valid_access?(access)
  return false unless access.is_a?(Array) && access.any?
  known = $firewall.known_services
  access.all? do |s|
    known.include?(s) || s.match?(/\Ainternet:(full|web|none)\z/)
  end
end

def extract_name(path)
  parts = path.split("/").reject(&:empty?)
  parts[1] if parts.length >= 2
end

def sub_path(path)
  path.sub(%r{^/agents/[^/]+}, "")
end

# Allocate the next available IP from the agent subnet (10.1.0.0/16).
# The Router is the sole source of truth for IP assignments.
# Flat number space: 10.1.0.1 through 10.1.255.254 (~65k addresses).
AGENT_SUBNET_PREFIX = "10.1"

def allocate_ip
  used = $state.all.values.map { |a| a["ip"] }.compact.to_set
  (1..65534).each do |n|
    third = n >> 8
    fourth = n & 0xFF
    ip = "#{AGENT_SUBNET_PREFIX}.#{third}.#{fourth}"
    return ip unless used.include?(ip)
  end
  nil
end

# --- Boot Sequence ---

log "=== WG-Router starting ==="

log "Initializing WireGuard interface..."
$wireguard.init!
log "  interface: #{$wireguard.interface}"

# Static peers (host, manager)
(config["peers"] || {}).each do |name, peer|
  pubkey = peer["pubkey"] ||
           (peer["pubkey_file"] && File.exist?(peer["pubkey_file"]) && File.read(peer["pubkey_file"]).strip)

  if pubkey
    $wireguard.add_peer(
      pubkey: pubkey,
      allowed_ips: peer["allowed_ips"],
      endpoint: peer["endpoint"]
    )
    log "  static peer: #{name} (#{peer['allowed_ips']})"
  else
    log "  WARN: no pubkey for static peer #{name}"
  end
end

log "Rebuilding firewall from persisted state..."
agents = $state.all
$firewall.rebuild!(agents)
log "  #{agents.size} agents registered, #{agents.count { |_, a| a['active'] }} active"

# Re-add WG peers for active agents
agents.each do |name, agent|
  next unless agent["active"] && agent["peer_pubkey"]
  $wireguard.add_peer(pubkey: agent["peer_pubkey"], allowed_ips: "#{agent['ip']}/32")
  log "  restored peer: #{name} (#{agent['ip']})"
end

# --- API Server ---

log "Starting API on port #{API_PORT} (authorized: #{MANAGER_IP})..."

# WEBrick's mount_proc doesn't support DELETE/PATCH.
# Subclass AbstractServlet and override `service` to handle all methods.
class RouterServlet < WEBrick::HTTPServlet::AbstractServlet
  def service(req, res)
  path = req.path
  method = req.request_method

  # --- Health (no auth — reachable from inside container for HEALTHCHECK) ---
  if method == "GET" && path == "/health"
    peers = $wireguard.list_peers
    json_ok(res, {
      status: "ok",
      agents_registered: $state.all.size,
      agents_active: $state.all.count { |_, a| a["active"] },
      wg_peers: peers.size,
      pubkey: $wireguard.public_key
    })
    return
  end

  # --- Auth gate ---
  unless authorized?(req)
    log "DENIED #{method} #{path} from #{source_ip(req)}"
    json_err(res, "unauthorized", status: 403)
    return
  end

  # --- Debug endpoints ---
  if method == "GET" && path == "/firewall"
    json_ok(res, { ruleset: $firewall.dump })
    return
  end

  if method == "GET" && path == "/wireguard"
    json_ok(res, { peers: $wireguard.list_peers, pubkey: $wireguard.public_key })
    return
  end

  # --- POST /agents — register new agent ---
  # The Router is the sole source of truth for IP allocation.
  # If no address is provided, the Router assigns the next available IP.
  if method == "POST" && path == "/agents"
    data = json_body(req)
    unless data
      json_err(res, "invalid JSON")
      return
    end

    name = data["name"]
    address = data["address"]
    pubkey = data["peer_pubkey"]
    access = data["access"] || ["default"]

    errors = []
    errors << "invalid name" unless name&.match?(NAME_RE)
    errors << "invalid pubkey" unless pubkey&.match?(PUBKEY_RE)
    errors << "invalid access list" unless valid_access?(access)
    errors << "already registered: #{name}" if name && $state.registered?(name)

    # Allocate IP: use provided address or let the Router assign one
    if address
      errors << "invalid address (need x.x.x.x/32)" unless address.match?(IP_CIDR_RE)
      ip = address.sub(/\/32$/, "")
      # Reject if IP is already in use by another agent
      used = $state.all.values.map { |a| a["ip"] }.compact
      if used.include?(ip)
        errors << "IP #{ip} already in use"
      end
    else
      ip = allocate_ip
      errors << "IP pool exhausted" unless ip
    end

    if errors.any?
      json_err(res, errors.join("; "))
      return
    end

    $state.register(name, ip: ip, access: access, peer_pubkey: pubkey)
    $firewall.add_agent(name, ip: ip, access: access)
    $wireguard.add_peer(pubkey: pubkey, allowed_ips: "#{ip}/32")

    log "REGISTER #{name} ip=#{ip} access=#{access.join(',')}"
    json_ok(res, { ok: true, name: name, ip: ip }, status: 201)
    return
  end

  # --- GET /agents — list all ---
  if method == "GET" && path == "/agents"
    json_ok(res, { agents: $state.all })
    return
  end

  # --- Routes with :name ---
  name = extract_name(path)
  agent = name ? $state.get(name) : nil
  action = sub_path(path)

  unless name&.match?(NAME_RE)
    json_err(res, "not found", status: 404)
    return
  end

  case [method, action]

  # GET /agents/:name
  when ["GET", ""]
    unless agent
      json_err(res, "not found", status: 404)
      return
    end
    json_ok(res, agent.merge("name" => name))

  # PATCH /agents/:name — update access rules
  when ["PATCH", ""]
    unless agent
      json_err(res, "not found", status: 404)
      return
    end

    data = json_body(req)
    access = data&.fetch("access", nil)
    unless access && valid_access?(access)
      json_err(res, "invalid access list")
      return
    end

    $state.update_access(name, access: access)
    $firewall.update_agent(name, ip: agent["ip"], access: access)

    log "UPDATE #{name} access=#{access.join(',')}"
    json_ok(res, { ok: true, name: name, access: access })

  # PUT /agents/:name/peer — swap WG pubkey (new spawn)
  when ["PUT", "/peer"]
    unless agent
      json_err(res, "not found", status: 404)
      return
    end

    data = json_body(req)
    pubkey = data&.fetch("peer_pubkey", nil)
    unless pubkey&.match?(PUBKEY_RE)
      json_err(res, "invalid pubkey")
      return
    end

    # Remove old peer if active
    if agent["active"] && agent["peer_pubkey"]
      $wireguard.remove_peer(pubkey: agent["peer_pubkey"])
    end

    $state.update_peer(name, peer_pubkey: pubkey)
    $wireguard.add_peer(pubkey: pubkey, allowed_ips: "#{agent['ip']}/32")

    log "PEER #{name} (new spawn)"
    json_ok(res, { ok: true, name: name, ip: agent["ip"] })

  # DELETE /agents/:name/peer — freeze (remove peer, keep rules)
  when ["DELETE", "/peer"]
    unless agent
      json_err(res, "not found", status: 404)
      return
    end

    if agent["active"] && agent["peer_pubkey"]
      $wireguard.remove_peer(pubkey: agent["peer_pubkey"])
    end
    $state.deactivate(name)

    log "FREEZE #{name} (peer removed, rules kept)"
    json_ok(res, { ok: true, name: name, state: "frozen" })

  # DELETE /agents/:name — full decommission
  when ["DELETE", ""]
    unless agent
      json_err(res, "not found", status: 404)
      return
    end

    if agent["active"] && agent["peer_pubkey"]
      $wireguard.remove_peer(pubkey: agent["peer_pubkey"])
    end
    $firewall.remove_agent(name, ip: agent["ip"])
    $state.remove(name)

    log "DECOMMISSION #{name}"
    json_ok(res, { ok: true, name: name, state: "decommissioned" })

  # POST /agents/:name/block — emergency kill
  when ["POST", "/block"]
    unless agent
      json_err(res, "not found", status: 404)
      return
    end

    $firewall.block_agent(agent["ip"])
    $state.block(name)

    log "BLOCK #{name} (#{agent['ip']})"
    json_ok(res, { ok: true, name: name, state: "blocked" })

  # POST /agents/:name/unblock
  when ["POST", "/unblock"]
    unless agent
      json_err(res, "not found", status: 404)
      return
    end

    $firewall.unblock_agent(agent["ip"])
    $state.unblock(name)

    log "UNBLOCK #{name}"
    json_ok(res, { ok: true, name: name, state: "unblocked" })

  else
    json_err(res, "not found", status: 404)
  end
  end  # end service
end  # end RouterServlet

server = WEBrick::HTTPServer.new(
  BindAddress: "0.0.0.0",
  Port: API_PORT,
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
  AccessLog: []
)
server.mount("/", RouterServlet)

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

log "=== WG-Router ready ==="
server.start
