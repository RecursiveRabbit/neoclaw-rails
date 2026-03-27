# firewall.rb — nftables rule management
#
# Architecture:
#   table inet neoclaw
#     set blocked            — emergency kill list (IPs)
#     chain input            — protect the Router itself
#     chain forward          — base policy, then `goto agents`
#     chain agents           — per-agent jump rules (dynamic)
#     chain agent_<name>     — per-agent access rules (dynamic)
#     set <name>_tcp         — per-agent TCP port allowlist
#     set <name>_udp         — per-agent UDP port allowlist
#     chain postrouting      — NAT for internet egress
#
# Per-agent chains make add/remove/update atomic and clean.
# The jump rule in `agents` routes by source IP.
# The agent chain checks destination port against named sets.
# Firewall rules persist across agent freeze/wake cycles —
# only the WG peer changes. Rules are permanent per instance name.

require "open3"

class Firewall
  def initialize(config)
    @host_ip = config.dig("network", "host_ip")
    @manager_ip = config.dig("network", "manager_ip")
    @hub_ip = config.dig("network", "hub_ip")
    @agent_subnet = config.dig("network", "agent_subnet") || "10.0.1.0/24"
    @services = config["services"] || {}
    @wg_port = (config.dig("router", "wg_listen_port") || 51820).to_i
    @api_port = (config.dig("router", "api_port") || 8080).to_i
    @lan_iface = config.dig("router", "lan_interface") || "eth0"
  end

  # Build the base nftables structure from scratch.
  # Idempotent — safe to call on every boot.
  def init_base!
    nft! <<~NFT
      add table inet neoclaw
      delete table inet neoclaw
      table inet neoclaw {
        set blocked {
          type ipv4_addr
        }

        chain input {
          type filter hook input priority 0; policy drop;
          iif lo accept
          ct state established,related accept
          udp dport #{@wg_port} accept
          ip saddr #{@manager_ip} tcp dport #{@api_port} accept
        }

        chain forward {
          type filter hook forward priority 0; policy drop;
          ip saddr @blocked drop
          ct state established,related accept
          ip saddr #{@manager_ip} ip daddr #{@host_ip} accept
          ip saddr #{@manager_ip} ip daddr #{@agent_subnet} accept
          ip saddr #{@host_ip} ip daddr #{@manager_ip} accept
          ip saddr #{@host_ip} ip daddr #{@agent_subnet} accept
          ip saddr #{@agent_subnet} ip daddr #{@manager_ip} accept
          ip saddr #{@hub_ip} ip daddr #{@host_ip} accept
          ip saddr #{@hub_ip} ip daddr #{@manager_ip} accept
          ip saddr #{@hub_ip} ip daddr #{@agent_subnet} accept
          ip saddr #{@host_ip} ip daddr #{@hub_ip} accept
          ip saddr #{@manager_ip} ip daddr #{@hub_ip} accept
          ip saddr #{@agent_subnet} ip daddr #{@hub_ip} accept
          goto agents
        }

        chain agents {}

        chain postrouting {
          type nat hook postrouting priority 100;
          oifname "#{@lan_iface}" masquerade
        }
      }
    NFT
  end

  # Create firewall rules for a new agent.
  # Called once per agent instance name, on first registration.
  def add_agent(name, ip:, access:)
    safe = sanitize(name)
    tcp = resolve_ports(access, "tcp")
    udp = resolve_ports(access, "udp")
    inet = resolve_internet(access)

    cmds = []

    # Port sets
    cmds << "add set inet neoclaw #{safe}_tcp { type inet_service; }"
    cmds << "add element inet neoclaw #{safe}_tcp { #{tcp.join(', ')} }" if tcp.any?
    cmds << "add set inet neoclaw #{safe}_udp { type inet_service; }"
    cmds << "add element inet neoclaw #{safe}_udp { #{udp.join(', ')} }" if udp.any?

    # Agent chain
    cmds << "add chain inet neoclaw agent_#{safe}"
    cmds << "add rule inet neoclaw agent_#{safe} ip daddr #{@host_ip} tcp dport @#{safe}_tcp accept" if tcp.any?
    cmds << "add rule inet neoclaw agent_#{safe} ip daddr #{@host_ip} udp dport @#{safe}_udp accept" if udp.any?

    case inet
    when :full
      cmds << "add rule inet neoclaw agent_#{safe} oifname \"#{@lan_iface}\" accept"
    when :web
      cmds << "add rule inet neoclaw agent_#{safe} oifname \"#{@lan_iface}\" tcp dport { 80, 443 } accept"
    end

    # Jump rule in agents chain
    cmds << "add rule inet neoclaw agents ip saddr #{ip} jump agent_#{safe}"

    nft!(cmds.join("\n"))
  end

  # Update access rules for an existing agent.
  # Flushes the agent chain and sets, rebuilds with new access list.
  # Jump rule is untouched — IP doesn't change.
  def update_agent(name, ip:, access:)
    safe = sanitize(name)
    tcp = resolve_ports(access, "tcp")
    udp = resolve_ports(access, "udp")
    inet = resolve_internet(access)

    cmds = []

    # Flush existing rules and set elements
    cmds << "flush chain inet neoclaw agent_#{safe}"
    cmds << "flush set inet neoclaw #{safe}_tcp"
    cmds << "flush set inet neoclaw #{safe}_udp"

    # Repopulate
    cmds << "add element inet neoclaw #{safe}_tcp { #{tcp.join(', ')} }" if tcp.any?
    cmds << "add element inet neoclaw #{safe}_udp { #{udp.join(', ')} }" if udp.any?

    cmds << "add rule inet neoclaw agent_#{safe} ip daddr #{@host_ip} tcp dport @#{safe}_tcp accept" if tcp.any?
    cmds << "add rule inet neoclaw agent_#{safe} ip daddr #{@host_ip} udp dport @#{safe}_udp accept" if udp.any?

    case inet
    when :full
      cmds << "add rule inet neoclaw agent_#{safe} oifname \"#{@lan_iface}\" accept"
    when :web
      cmds << "add rule inet neoclaw agent_#{safe} oifname \"#{@lan_iface}\" tcp dport { 80, 443 } accept"
    end

    nft!(cmds.join("\n"))
  end

  # Remove all firewall rules for an agent (full decommission).
  def remove_agent(name, ip:)
    safe = sanitize(name)

    # Remove jump rule from agents chain first (required before deleting the target chain)
    remove_jump_rule(ip, safe)

    # Flush and delete agent chain
    nft_quiet("flush chain inet neoclaw agent_#{safe}")
    nft_quiet("delete chain inet neoclaw agent_#{safe}")

    # Delete sets
    nft_quiet("delete set inet neoclaw #{safe}_tcp")
    nft_quiet("delete set inet neoclaw #{safe}_udp")
  end

  def block_agent(ip)
    nft!("add element inet neoclaw blocked { #{ip} }")
  end

  def unblock_agent(ip)
    nft!("delete element inet neoclaw blocked { #{ip} }")
  end

  # Rebuild entire ruleset from persisted state. Called on boot.
  def rebuild!(agents)
    init_base!
    agents.each do |name, agent|
      add_agent(name, ip: agent["ip"], access: agent["access"])
      block_agent(agent["ip"]) if agent["blocked"]
    end
  end

  def dump
    out, _ = Open3.capture3("nft", "list", "table", "inet", "neoclaw")
    out
  end

  # Return list of known service names for validation
  def known_services
    @services.keys
  end

  private

  def sanitize(name)
    name.tr("-", "_")
  end

  def resolve_ports(access, proto)
    ports = []
    access.each do |svc|
      next if svc.start_with?("internet:")
      svc_def = @services[svc]
      next unless svc_def && svc_def[proto]
      ports.concat(svc_def[proto])
    end
    ports.uniq.sort
  end

  def resolve_internet(access)
    entry = access.find { |s| s.start_with?("internet:") }
    return :none unless entry
    case entry.split(":").last
    when "full" then :full
    when "web"  then :web
    else :none
    end
  end

  def remove_jump_rule(ip, safe_name)
    out, _, status = Open3.capture3("nft", "-a", "list", "chain", "inet", "neoclaw", "agents")
    return unless status.success?

    out.each_line do |line|
      if line.include?("saddr #{ip}") &&
         line.include?("jump agent_#{safe_name}") &&
         line =~ /# handle (\d+)/
        nft_quiet("delete rule inet neoclaw agents handle #{$1}")
      end
    end
  end

  def nft!(commands)
    out, err, status = Open3.capture3("nft", "-f", "-", stdin_data: commands)
    unless status.success?
      raise "nft failed: #{err.strip}\n---\n#{commands}"
    end
    out
  end

  def nft_quiet(commands)
    Open3.capture3("nft", "-f", "-", stdin_data: commands)
  end
end
