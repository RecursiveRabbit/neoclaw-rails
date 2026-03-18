# The spawn flow. Hub says "I need margaux-art", Spawner makes it happen.
#
# 1. Check if already running (return IP)
# 2. Check capacity (freeze coldest if needed)
# 3. Look up identity config + channel overrides -> service list
# 4. Generate ephemeral keys (WG + SSH)
# 5. Provision auth for each service
# 6. Add agent as WG peer on authorized interfaces
# 7. Write spawn.json
# 8. podman run
# 9. Wait for READY signal from relay
# 10. Return IP

class Spawner
  class << self
    def resolve(identity:, channel:)
      instance_name = build_instance_name(identity, channel)

      # Already running?
      existing = Container.alive.find_by(instance_name: instance_name)
      return { ip: existing.wg_address } if existing

      # Already starting?
      starting = Container.starting.find_by(instance_name: instance_name)
      return { ip: starting.wg_address, starting: true } if starting

      # At capacity? Freeze the coldest.
      if Container.alive.count >= Surface.soft_cap
        coldest = Container.idle.order(:last_message_at).first
        coldest ||= Container.alive.order(:last_message_at).first
        Lifecycle.freeze!(coldest) if coldest
      end

      spawn(identity: identity, channel: channel, instance_name: instance_name)
    end

    private

    def spawn(identity:, channel:, instance_name:)
      config = AgentConfig.find_by!(identity: identity)

      services = config.services_for(channel)
      agent_ip = allocate_ip

      # Generate ephemeral keys
      wg_keypair = WireGuard.generate_keypair
      ssh_keypair = generate_ssh_keypair

      # Provision auth for each service
      secrets = {}
      services.each do |service_name|
        service = ServiceType.find_by(name: service_name)
        next unless service
        secrets[service_name] = Provisioner.provision(service,
          instance_name: instance_name, ssh_pubkey: ssh_keypair[:public])
      end

      # Add agent as WG peer on authorized interfaces
      services.each do |service_name|
        service = ServiceType.find_by(name: service_name)
        next unless service&.wg_interface
        WireGuard.add_peer(
          interface: service.wg_interface,
          public_key: wg_keypair[:public],
          allowed_ips: "#{agent_ip}/32"
        )
      end
      # Always add to wg-hub so the Hub can reach the agent
      WireGuard.add_peer(
        interface: "wg-hub",
        public_key: wg_keypair[:public],
        allowed_ips: "#{agent_ip}/32"
      )

      # Build spawn file
      spawn_data = build_spawn_file(
        identity: identity, channel: channel, instance_name: instance_name,
        config: config, agent_ip: agent_ip, wg_keypair: wg_keypair,
        ssh_keypair: ssh_keypair, services: services, secrets: secrets
      )

      spawn_path = File.join(Surface.spawn_dir, "#{instance_name}.json")
      File.write(spawn_path, JSON.pretty_generate(spawn_data))

      # Create container record
      container = Container.create!(
        instance_name: instance_name,
        identity: identity,
        channel: channel,
        wg_address: agent_ip,
        wg_pubkey: wg_keypair[:public],
        state: "starting",
        provisioned_services: services,
        context_usage: 0.0,
        last_message_at: Time.current,
        last_health_at: Time.current
      )

      # Launch container
      container_id = Podman.run(instance_name: instance_name, spawn_path: spawn_path)
      container.update!(container_id: container_id)

      AuditLog.record("SPAWN",
        instance_name: instance_name, identity: identity,
        detail: "Services: #{services.join(', ')}. IP: #{agent_ip}")

      { ip: agent_ip }
    rescue => e
      AuditLog.record("SPAWN_FAILED",
        instance_name: instance_name, identity: identity, detail: e.message)
      raise
    end

    def build_instance_name(identity, channel)
      config = AgentConfig.find_by(identity: identity)
      config&.singleton? ? identity : "#{identity}-#{channel}"
    end

    def allocate_ip
      # Agent pool: 10.0.1.1 through 10.0.255.254 (~65k addresses)
      # Scan subnets sequentially, fill each /24 before moving to the next
      used = Container.where.not(state: "dead").pluck(:wg_address).compact.to_set
      (1..255).each do |third|
        (1..254).each do |fourth|
          ip = "10.0.#{third}.#{fourth}"
          return ip unless used.include?(ip)
        end
      end
      raise "IP pool exhausted (65k addresses in use)"
    end

    def generate_ssh_keypair
      dir = Dir.mktmpdir
      key_path = File.join(dir, "id_ed25519")
      system("ssh-keygen", "-t", "ed25519", "-f", key_path, "-N", "", "-q")
      {
        private: File.read(key_path),
        public: File.read("#{key_path}.pub").strip
      }
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    def build_spawn_file(identity:, channel:, instance_name:, config:, agent_ip:, wg_keypair:, ssh_keypair:, services:, secrets:)
      peers = services.filter_map { |svc_name|
        svc = ServiceType.find_by(name: svc_name)
        next unless svc
        svc.peer_config
      }

      {
        identity: identity,
        instance: instance_name,
        channel: channel,
        model: config.model_for(channel),
        git: {
          repo: config.repo,
          ssh_key: ssh_keypair[:private],
          **secrets.fetch("git", {})
        },
        network: {
          wg_private_key: wg_keypair[:private],
          wg_address: agent_ip,
          peers: peers
        },
        services: secrets
      }
    end
  end
end
