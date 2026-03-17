#!/usr/bin/env ruby
# wg-admin — the one privileged thing on the host.
#
# Listens on 10.0.0.1:9100 (only reachable over WireGuard).
# Accepts add-peer and remove-peer requests from the Manager.
# Runs `wg set` on the host's WireGuard interfaces.
#
# This is intentionally tiny and auditable.
# It does one thing: modify WireGuard peer lists.
#
# Run as: ruby wg-admin.rb
# Requires: root (or CAP_NET_ADMIN + access to wg)

require "webrick"
require "json"

LISTEN_ADDR = ENV.fetch("WG_ADMIN_LISTEN", "10.0.0.1")
LISTEN_PORT = ENV.fetch("WG_ADMIN_PORT", "9100").to_i

# Only these interfaces can be modified
ALLOWED_INTERFACES = %w[
  wg-hub wg-git wg-ssh wg-valley wg-vikunja wg-comfyui wg-matrix
].freeze

server = WEBrick::HTTPServer.new(
  BindAddress: LISTEN_ADDR,
  Port: LISTEN_PORT,
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO),
  AccessLog: [[File.open("/var/log/wg-admin.log", "a"), WEBrick::AccessLog::COMMON_LOG_FORMAT]]
)

# POST /add-peer
# { interface: "wg-git", public_key: "...", allowed_ips: "10.0.1.5/32" }
server.mount_proc("/add-peer") do |req, res|
  unless req.request_method == "POST"
    res.status = 405
    next
  end

  data = JSON.parse(req.body)
  iface = data["interface"]
  pubkey = data["public_key"]
  allowed = data["allowed_ips"]

  unless ALLOWED_INTERFACES.include?(iface)
    res.status = 403
    res.body = JSON.generate(error: "interface not allowed: #{iface}")
    next
  end

  # Validate inputs — no shell injection
  unless pubkey =~ /\A[A-Za-z0-9+\/=]{44}\z/
    res.status = 400
    res.body = JSON.generate(error: "invalid public key format")
    next
  end

  unless allowed =~ /\A\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\/\d{1,2}\z/
    res.status = 400
    res.body = JSON.generate(error: "invalid allowed_ips format")
    next
  end

  success = system("wg", "set", iface, "peer", pubkey, "allowed-ips", allowed)

  if success
    # Persist the change
    system("bash", "-c", "wg showconf #{iface} > /etc/wireguard/#{iface}.conf")
    $stderr.puts "ADD peer on #{iface}: #{allowed}"
    res.status = 200
    res.body = JSON.generate(ok: true)
  else
    res.status = 500
    res.body = JSON.generate(error: "wg set failed")
  end
end

# POST /remove-peer
# { interface: "wg-git", public_key: "..." }
server.mount_proc("/remove-peer") do |req, res|
  unless req.request_method == "POST"
    res.status = 405
    next
  end

  data = JSON.parse(req.body)
  iface = data["interface"]
  pubkey = data["public_key"]

  unless ALLOWED_INTERFACES.include?(iface)
    res.status = 403
    res.body = JSON.generate(error: "interface not allowed: #{iface}")
    next
  end

  unless pubkey =~ /\A[A-Za-z0-9+\/=]{44}\z/
    res.status = 400
    res.body = JSON.generate(error: "invalid public key format")
    next
  end

  success = system("wg", "set", iface, "peer", pubkey, "remove")

  if success
    system("bash", "-c", "wg showconf #{iface} > /etc/wireguard/#{iface}.conf")
    $stderr.puts "REMOVE peer on #{iface}: #{pubkey[0..10]}..."
    res.status = 200
    res.body = JSON.generate(ok: true)
  else
    res.status = 500
    res.body = JSON.generate(error: "wg set remove failed")
  end
end

# GET /health
server.mount_proc("/health") do |req, res|
  res.status = 200
  res.body = JSON.generate(status: "ok", interfaces: ALLOWED_INTERFACES)
end

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

$stderr.puts "wg-admin listening on #{LISTEN_ADDR}:#{LISTEN_PORT}"
server.start
