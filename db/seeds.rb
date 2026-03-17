# Service types — what services exist and how they're accessed.

services = [
  { name: "git", wg_interface: "wg-git", wg_ip: "10.0.0.3", wg_listen_port: 51823,
    provision_type: "forgejo", has_own_auth: true,
    notes: "Forgejo — create user, add SSH key, grant repo access" },
  { name: "ssh", wg_interface: "wg-ssh", wg_ip: "10.0.0.8", wg_listen_port: 51828,
    provision_type: "ssh_key", has_own_auth: true,
    notes: "Host SSH access via authorized_keys" },
  { name: "valley", wg_interface: "wg-valley", wg_ip: "10.0.0.4", wg_listen_port: 51824,
    provision_type: "token",
    notes: "Evennia MUD — The Uncanny Valley" },
  { name: "vikunja", wg_interface: "wg-vikunja", wg_ip: "10.0.0.5", wg_listen_port: 51825,
    provision_type: "token",
    notes: "Vikunja task management" },
  { name: "comfyui", wg_interface: "wg-comfyui", wg_ip: "10.0.0.6", wg_listen_port: 51826,
    provision_type: "none",
    notes: "ComfyUI — no auth, WG peering is the only access control" },
  { name: "zigbee", wg_interface: "wg-zigbee", wg_ip: "10.0.0.7", wg_listen_port: 51827,
    provision_type: "none",
    notes: "Zigbee2MQTT — no auth, WG peering only" },
]

services.each do |attrs|
  ServiceType.find_or_create_by!(name: attrs[:name]) do |s|
    s.assign_attributes(attrs.except(:name))
  end
  puts "  service: #{attrs[:name]} (#{attrs[:wg_interface]})"
end

# Agent configs — identity-level service assignments.

agents = {
  "hopper"   => { singleton: true, repo: "agents/hopper",
                   base_services: %w[git ssh valley vikunja zigbee comfyui] },
  "silas"    => { repo: "agents/silas",
                   base_services: %w[git ssh valley vikunja] },
  "margaux"  => { repo: "agents/margaux",
                   base_services: %w[git ssh valley vikunja],
                   channel_overrides: { "art" => %w[comfyui] } },
  "kael"     => { repo: "agents/kael",
                   base_services: %w[git ssh valley vikunja] },
  "wren"     => { repo: "agents/wren",
                   base_services: %w[git valley] },
  "ember"    => { repo: "agents/ember",
                   base_services: %w[git] },
  "parallax" => { repo: "agents/parallax",
                   base_services: %w[git ssh valley comfyui],
                   channel_overrides: { "art" => %w[comfyui] } },
  "fletcher" => { repo: "agents/fletcher",
                   base_services: %w[git vikunja] },
  "voss"     => { repo: "agents/voss",
                   base_services: %w[git] },
}

agents.each do |name, attrs|
  AgentConfig.find_or_create_by!(identity: name) do |a|
    a.assign_attributes(attrs)
  end
  svcs = attrs[:base_services]&.join(", ") || "none"
  puts "  agent: #{name} [#{svcs}]"
end

puts "Seeded #{ServiceType.count} services, #{AgentConfig.count} agent configs."

# ================================================================
# Hub — Identities and Listeners
# ================================================================

agents.each do |name, attrs|
  Identity.find_or_create_by!(name: name) do |i|
    i.singleton = attrs.fetch(:singleton, false)
  end
end

hopper = Identity.find_by!(name: "hopper")
Listener.find_or_create_by!(identity: hopper, channel_slug: "general")

puts "Seeded #{Identity.count} identities, #{Listener.count} listeners."
