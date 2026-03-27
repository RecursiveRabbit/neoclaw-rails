# The spawn flow. Hub says "I need margaux-art", Spawner makes it happen.
#
# 1. Check if already running (return IP)
# 2. Check capacity (freeze coldest if needed)
# 3. Look up identity config + channel overrides → service list
# 4. Generate ephemeral WG + SSH keypairs
# 5. Register or activate agent on the Router (WG + firewall)
# 6. Provision service auth (Forgejo, etc.)
# 7. Write spawn.json (one peer: the Router)
# 8. podman run
# 9. Return IP

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

      # Over memory budget? Freeze the coldest to make room.
      if Podman.agent_memory_usage >= Surface.memory_budget
        coldest = Container.idle.order(:last_message_at).first
        coldest ||= Container.alive.order(:last_message_at).first
        Lifecycle.freeze!(coldest) if coldest
      end

      spawn(identity: identity, channel: channel, instance_name: instance_name)
    end

    # Regenerate credentials and spawn.json for a hot swap.
    # Does NOT create a Container record or launch a pod.
    # Returns the host-side spawn.json path.
    def respawn(identity:, channel:, instance_name:)
      config = AgentConfig.find_by!(identity: identity)
      services = config.services_for(channel)

      wg_keypair = generate_wg_keypair
      ssh_keypair = generate_ssh_keypair

      # Register or activate — agent may not exist on a fresh Router
      # (e.g., after Manager restart where Router was rebuilt ephemeral).
      if RouterClient.registered?(instance_name)
        result = RouterClient.activate(name: instance_name, pubkey: wg_keypair[:public])
      else
        access = build_access_list(services, config)
        result = RouterClient.register(
          name: instance_name, pubkey: wg_keypair[:public], access: access
        )
      end
      agent_ip = result[:ip]

      # Re-provision service auth
      secrets = {}
      services.each do |service_name|
        service = ServiceType.find_by(name: service_name)
        next unless service
        begin
          secrets[service_name] = Provisioner.provision(service,
            instance_name: instance_name, ssh_pubkey: ssh_keypair[:public])
        rescue => e
          Rails.logger.warn "Respawn provision #{service_name} for #{instance_name} failed: #{e.message}"
          secrets[service_name] = {}
        end
      end

      # Channel repo (agent already exists in Forgejo from prior spawn)
      channel_repo = nil
      if secrets["forgejo"]&.dig(:forge_user)
        begin
          channel_repo = Provisioner.provision_channel_repo(
            channel: channel, instance_name: instance_name)
        rescue => e
          Rails.logger.warn "Respawn channel repo for #{instance_name} failed: #{e.message}"
        end
      end

      boot_state = determine_boot_state(instance_name)

      spawn_data = build_spawn_file(
        identity: identity, channel: channel, instance_name: instance_name,
        config: config, agent_ip: agent_ip, wg_keypair: wg_keypair,
        ssh_keypair: ssh_keypair, secrets: secrets, boot_state: boot_state,
        channel_repo: channel_repo
      )

      spawn_path = File.join(Surface.spawn_dir, "#{instance_name}.json")
      File.write(spawn_path, JSON.pretty_generate(spawn_data))

      # Return the host-side path for podman
      File.join(Surface.host_spawn_dir, "#{instance_name}.json")
    end

    private

    def spawn(identity:, channel:, instance_name:)
      # Clean up inactive records so we can reuse the instance_name
      Container.where(instance_name: instance_name).where.not(state: %w[alive starting]).destroy_all

      config = AgentConfig.find_by!(identity: identity)
      services = config.services_for(channel)

      # Generate ephemeral keys
      wg_keypair = generate_wg_keypair
      ssh_keypair = generate_ssh_keypair

      # Register or activate on the Router.
      # The Router is the sole source of truth for IP allocation.
      if RouterClient.registered?(instance_name)
        # Already registered — just swap the WG key (hot path)
        result = RouterClient.activate(name: instance_name, pubkey: wg_keypair[:public])
        agent_ip = result[:ip]
      else
        # First time — register. Router allocates the IP.
        access = build_access_list(services, config)
        result = RouterClient.register(
          name: instance_name,
          pubkey: wg_keypair[:public],
          access: access
        )
        agent_ip = result[:ip]
      end

      # Provision service auth (Forgejo users, SSH keys, etc.)
      # Individual service failures don't block the spawn — the agent
      # boots without that service and gets an empty token.
      secrets = {}
      services.each do |service_name|
        service = ServiceType.find_by(name: service_name)
        next unless service
        begin
          secrets[service_name] = Provisioner.provision(service,
            instance_name: instance_name, ssh_pubkey: ssh_keypair[:public])
        rescue => e
          Rails.logger.warn "Provision #{service_name} for #{instance_name} failed: #{e.message}"
          secrets[service_name] = {}
        end
      end

      # Provision channel repo — shared git repo for all agents in this channel.
      # Non-fatal: agent works fine without it.
      channel_repo = nil
      if secrets["forgejo"]&.dig(:forge_user)
        begin
          channel_repo = Provisioner.provision_channel_repo(
            channel: channel, instance_name: instance_name)
        rescue => e
          Rails.logger.warn "Channel repo for #{instance_name} in ##{channel} failed: #{e.message}"
        end
      end

      # Determine boot state from history
      boot_state = determine_boot_state(instance_name)

      # Build spawn file — one peer: the Router
      spawn_data = build_spawn_file(
        identity: identity, channel: channel, instance_name: instance_name,
        config: config, agent_ip: agent_ip, wg_keypair: wg_keypair,
        ssh_keypair: ssh_keypair, secrets: secrets, boot_state: boot_state,
        channel_repo: channel_repo
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
      # Clean up the stale container record so future spawns aren't blocked
      container&.update!(state: "inactive") if container
      AuditLog.record("SPAWN_FAILED",
        instance_name: instance_name, identity: identity, detail: e.message)
      raise
    end

    def build_instance_name(identity, channel)
      config = AgentConfig.find_by(identity: identity)
      config&.singleton? ? identity : "#{identity}-#{channel}"
    end

    # Translate service names to Router access list format.
    # Adds "default" (Hub access) and "internet:full" for all agents.
    def build_access_list(services, config)
      access = ["default"]
      services.each do |svc|
        # Skip services that don't map to Router service names
        next if svc == "hub"
        access << svc
      end
      access << "internet:full"
      access.uniq
    end

    def generate_wg_keypair
      private_key = `wg genkey`.strip
      public_key = IO.popen("wg pubkey", "r+") { |io|
        io.write(private_key)
        io.close_write
        io.read.strip
      }
      { private: private_key, public: public_key }
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

    # Fresh, resume, or baton? The Manager knows.
    # - fresh: no audit trail (first time, or Manager rebuilt since last session)
    # - baton: last session was sunsetted (context limit)
    # - resume: last session was frozen or crashed (workspace may exist)
    #
    # Note: Router registration persists across Manager rebuilds but AuditLog
    # doesn't. So Router state alone can't distinguish fresh from resume —
    # the audit trail is the source of truth for boot state.
    def determine_boot_state(instance_name)
      last_event = AuditLog.where(instance_name: instance_name)
        .where(event: %w[SUNSET FREEZE TEARDOWN CRASH])
        .order(created_at: :desc).first

      case last_event&.event
      when "SUNSET"
        "baton"
      when "FREEZE", "TEARDOWN", "CRASH"
        "resume"
      else
        "fresh"
      end
    end

    # Spawn file has one WG peer: the Router. That's it.
    # The Router forwards to everything else.
    def build_spawn_file(identity:, channel:, instance_name:, config:, agent_ip:, wg_keypair:, ssh_keypair:, secrets:, boot_state: "fresh", channel_repo: nil)
      data = {
        identity: identity,
        instance: instance_name,
        channel: channel,
        model: config.model_for(channel),
        boot_state: boot_state,
        git: {
          repo: config.repo,
          ssh_key: ssh_keypair[:private],
          **secrets.fetch("git", {})
        },
        network: {
          wg_private_key: wg_keypair[:private],
          wg_address: agent_ip,
          hub_ip: Surface.hub_wg_address,
          peers: [
            {
              public_key: Surface.router_pubkey,
              endpoint: Surface.router_endpoint,
              allowed_ips: "0.0.0.0/0"
            }
          ]
        },
        services: secrets
      }

      if channel_repo
        data[:channel_repo] = channel_repo
      end

      # Settings — relay reads these from spawn.json
      data[:relay] = {
        health_interval: Setting.get("relay.health_interval"),
        typing_interval: Setting.get("relay.typing_interval"),
        http_timeout:    Setting.get("relay.http_timeout"),
      }

      # System prompts — only include non-empty overrides
      prompts = {}
      %w[fresh_boot resume_boot baton_boot hot_swap].each do |key|
        val = Setting.get("prompts.#{key}")
        prompts[key.to_sym] = val if val.present?
      end
      data[:prompts] = prompts if prompts.any?

      # Model context limits
      data[:model_context_limits] = Setting.get("models.context_limits")

      data
    end
  end
end
