# Seeds the Manager database with identity configs and service types.
#
# WG public keys and endpoints come from infra/wireguard/keys/ and infra/services.conf.
# The endpoint uses the podman bridge gateway (10.88.0.1) because agents reach
# host WG ports through the bridge, not the LAN.

BRIDGE_GATEWAY = "10.88.0.1"

# --- Service Types ---
# Keys read from infra at deploy time and hardcoded here.
# If keys rotate, re-seed.
[
  { name: "forgejo",
    provision_type: "forgejo",  has_own_auth: true,
    provision_config: { service_port: 3000 } },

  { name: "ssh",
    provision_type: "ssh_key",  has_own_auth: true,
    provision_config: { service_port: 22 } },

  { name: "valley",
    wg_interface: "wg-valley",  wg_ip: "10.0.0.4", wg_listen_port: 51824,
    wg_public_key: "0YGxaf+hgyssGxciGCKAkhd9DPbsqzYccDR3jAdiVCc=",
    wg_endpoint: "#{BRIDGE_GATEWAY}:51824",
    provision_type: "valley",   has_own_auth: true,
    provision_config: { service_port: 4006 } },

  { name: "vikunja",
    wg_interface: "wg-vikunja", wg_ip: "10.0.0.5", wg_listen_port: 51825,
    wg_public_key: "Z4uOoKX+8sEfxPbHn7T75D+M3y5YreBkOtBjbgCJiwM=",
    wg_endpoint: "#{BRIDGE_GATEWAY}:51825",
    provision_type: "vikunja",  has_own_auth: true,
    provision_config: { service_port: 3456 } },

  { name: "comfyui",
    wg_interface: "wg-comfyui", wg_ip: "10.0.0.6", wg_listen_port: 51826,
    wg_public_key: "2IUic6N35Gsrr6HNChweGdhllYM1sst2w3ylxtBkQUA=",
    wg_endpoint: "#{BRIDGE_GATEWAY}:51826",
    provision_type: "none",     has_own_auth: false,
    provision_config: { service_port: 8188 } },

  { name: "matrix",
    wg_interface: "wg-matrix",  wg_ip: "10.0.0.7", wg_listen_port: 51827,
    wg_public_key: "TJZVmEz0xK4b4FaCmVEoVlqpVbhBV9AIi+w4twvzh2s=",
    wg_endpoint: "#{BRIDGE_GATEWAY}:51827",
    provision_type: "none",     has_own_auth: true,
    provision_config: { service_port: 8008 } },

  { name: "ollama",
    wg_interface: "wg-ollama",  wg_ip: "10.0.0.9", wg_listen_port: 51829,
    wg_public_key: "DapJXgzjbyCqUznymsSbUl+2B0B4IIcHEfQs3cC7Iys=",
    wg_endpoint: "#{BRIDGE_GATEWAY}:51829",
    provision_type: "none",     has_own_auth: false,
    provision_config: { service_port: 11434 } },
].each do |attrs|
  ServiceType.find_or_create_by!(name: attrs[:name]) do |s|
    s.assign_attributes(attrs.merge(enabled: true))
  end
  puts "  service: #{attrs[:name]} (#{attrs[:wg_ip]})"
end

# --- Room Configs ---
[
  { channel: "general",  model_default: "claude-sonnet-4-6" },
  { channel: "art",      model_default: "claude-opus-4-6", extra_services: [] },
].each do |attrs|
  RoomConfig.find_or_create_by!(channel: attrs[:channel]) do |r|
    r.assign_attributes(attrs)
  end
  puts "  room: ##{attrs[:channel]}"
end

# --- Agent Configs ---
[
  { identity: "rook",     repo: "rook/workspace",      model: "claude-sonnet-4-5", singleton: true,
    base_services: %w[forgejo ssh valley vikunja matrix] },
  { identity: "elias",    repo: "elias/workspace",     model: "claude-opus-4-6",   singleton: false,
    base_services: %w[forgejo ssh valley vikunja matrix] },
  { identity: "ellis",    repo: "ellis/workspace",     model: "claude-sonnet-4-6", singleton: false,
    base_services: %w[forgejo valley vikunja matrix] },
  { identity: "morgan",   repo: "morgan/workspace",    model: "claude-sonnet-4-6", singleton: false,
    base_services: %w[forgejo valley matrix] },
  { identity: "iris",     repo: "iris/workspace",      model: "claude-opus-4-6",   singleton: false,
    base_services: %w[forgejo valley vikunja matrix] },
].each do |attrs|
  AgentConfig.find_or_create_by!(identity: attrs[:identity]) do |c|
    c.assign_attributes(attrs.merge(idle_timeout: 480))
  end
  puts "  config: #{attrs[:identity]}"
end

puts "\nSeeded: #{ServiceType.count} services, #{AgentConfig.count} configs, #{RoomConfig.count} rooms."
