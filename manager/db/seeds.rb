# Seeds the Manager database with identity configs and service types.

# --- Service Types ---
[
  { name: "git",     wg_interface: "wg-git",     wg_ip: "10.0.0.3", provision_type: "forgejo",  has_own_auth: true  },
  { name: "ssh",     wg_interface: "wg-ssh",     wg_ip: "10.0.0.8", provision_type: "ssh_key",  has_own_auth: true  },
  { name: "valley",  wg_interface: "wg-valley",  wg_ip: "10.0.0.4", provision_type: "token",    has_own_auth: true  },
  { name: "vikunja", wg_interface: "wg-vikunja", wg_ip: "10.0.0.5", provision_type: "token",    has_own_auth: true  },
  { name: "comfyui", wg_interface: "wg-comfyui", wg_ip: "10.0.0.6", provision_type: "none",     has_own_auth: false },
  { name: "matrix",  wg_interface: "wg-matrix",  wg_ip: "10.0.0.7", provision_type: "none",     has_own_auth: true  },
].each do |attrs|
  ServiceType.find_or_create_by!(name: attrs[:name]) do |s|
    s.assign_attributes(attrs.merge(enabled: true))
  end
  puts "  service: #{attrs[:name]}"
end

# --- Agent Configs ---
[
  { identity: "hopper",   repo: "hopper/workspace",   model: "claude-opus-4-6",   singleton: true,
    base_services: %w[git ssh valley vikunja] },
  { identity: "silas",    repo: "silas/workspace",     model: "claude-opus-4-6",   singleton: false,
    base_services: %w[git ssh valley vikunja] },
  { identity: "margaux",  repo: "margaux/workspace",   model: "claude-opus-4-6",   singleton: false,
    base_services: %w[git ssh valley vikunja],
    channel_overrides: { "art" => %w[comfyui] } },
  { identity: "kael",     repo: "kael/workspace",      model: "claude-opus-4-6",   singleton: false,
    base_services: %w[git ssh valley] },
  { identity: "wren",     repo: "wren/workspace",      model: "claude-sonnet-4-6", singleton: false,
    base_services: %w[git ssh valley] },
  { identity: "ember",    repo: "ember/workspace",     model: "claude-sonnet-4-6", singleton: false,
    base_services: %w[git ssh] },
  { identity: "parallax", repo: "parallax/workspace",  model: "claude-opus-4-6",   singleton: false,
    base_services: %w[git ssh valley],
    channel_overrides: { "art" => %w[comfyui] } },
  { identity: "fletcher", repo: "fletcher/workspace",  model: "claude-sonnet-4-6", singleton: false,
    base_services: %w[git ssh] },
  { identity: "census",   repo: "census/workspace",    model: "claude-sonnet-4-6", singleton: false,
    base_services: %w[git ssh] },
].each do |attrs|
  AgentConfig.find_or_create_by!(identity: attrs[:identity]) do |c|
    c.assign_attributes(attrs.merge(idle_timeout: 480))
  end
  puts "  config: #{attrs[:identity]}"
end

puts "\nSeeded: #{ServiceType.count} services, #{AgentConfig.count} configs."
