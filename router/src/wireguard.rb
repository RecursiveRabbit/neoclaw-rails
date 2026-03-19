# wireguard.rb — WireGuard interface and peer management
#
# Manages the Router's single WG interface. Adds/removes peers.
# Static peers (host, manager) are configured at boot.
# Dynamic peers (agents) are managed via the API.

require "open3"

class WireGuard
  attr_reader :interface

  def initialize(config)
    @interface = config.dig("router", "wg_interface") || "wg0"
    @address = config.dig("router", "wg_address")
    @listen_port = (config.dig("router", "wg_listen_port") || 51820).to_i
    @private_key_file = config.dig("router", "wg_private_key")
  end

  def init!
    run("ip", "link", "add", @interface, "type", "wireguard", allow_fail: true)
    run("ip", "addr", "flush", "dev", @interface)
    run("ip", "addr", "add", @address, "dev", @interface)
    run("wg", "set", @interface,
        "private-key", @private_key_file,
        "listen-port", @listen_port.to_s)
    run("ip", "link", "set", @interface, "up")
    run("ip", "route", "replace", "10.0.0.0/8", "dev", @interface)
  end

  def add_peer(pubkey:, allowed_ips:, endpoint: nil, keepalive: 25)
    args = ["wg", "set", @interface,
            "peer", pubkey,
            "allowed-ips", allowed_ips,
            "persistent-keepalive", keepalive.to_s]
    args += ["endpoint", endpoint] if endpoint
    run(*args)
  end

  def remove_peer(pubkey:)
    run("wg", "set", @interface, "peer", pubkey, "remove", allow_fail: true)
  end

  def list_peers
    out, _, status = Open3.capture3("wg", "show", @interface, "dump")
    return [] unless status.success?

    out.lines.drop(1).map do |line|
      fields = line.strip.split("\t")
      {
        pubkey: fields[0],
        endpoint: fields[2] == "(none)" ? nil : fields[2],
        allowed_ips: fields[3],
        latest_handshake: fields[4].to_i,
        rx_bytes: fields[5].to_i,
        tx_bytes: fields[6].to_i
      }
    end
  end

  def public_key
    out, _, status = Open3.capture3("wg", "show", @interface, "public-key")
    return nil unless status.success?
    out.strip
  end

  private

  def run(*args, allow_fail: false)
    out, err, status = Open3.capture3(*args.map(&:to_s))
    unless status.success? || allow_fail
      raise "WG command failed: #{args.join(' ')}\n#{err}"
    end
    out
  end
end
