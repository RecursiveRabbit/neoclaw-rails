# Post-boot reconciliation. Discovers orphaned agent pods left over
# from a previous Manager lifecycle and hot-swaps each one with fresh
# credentials registered on the new (ephemeral) Router.
#
# Runs once after Rails boot, in a background thread. Individual pod
# failures don't block others — each is logged and skipped.

class Orchestrator
  class << self
    def reconcile!
      Rails.logger.info "Orchestrator: starting reconciliation..."

      pods = Podman.inventory
      agent_pods = pods.reject { |p| Surface.infra_containers.include?(p[:name]) }

      if agent_pods.empty?
        Rails.logger.info "Orchestrator: no orphaned pods found"
        return
      end

      Rails.logger.info "Orchestrator: found #{agent_pods.size} orphaned agent pod(s)"

      agent_pods.each do |pod|
        reconcile_pod(pod)
      rescue => e
        Rails.logger.error "Orchestrator: failed to reconcile #{pod[:name]}: #{e.message}"
        AuditLog.record("RECONCILE_FAILED",
          instance_name: pod[:name],
          detail: e.message)
      end

      Rails.logger.info "Orchestrator: reconciliation complete"
    end

    private

    def reconcile_pod(pod)
      instance_name = pod[:name]
      Rails.logger.info "Orchestrator: reconciling #{instance_name}..."

      # Read spawn.json from inside the pod to recover identity/channel.
      # This is the contract — spawn.json has everything we need.
      # Uses exec+cat (not cp) to avoid host/container path mismatch.
      spawn_json = Podman.read_file(instance_name, "/run/secrets/spawn.json")
      unless spawn_json
        Rails.logger.warn "Orchestrator: #{instance_name} has no spawn.json — removing"
        Podman.stop_container(instance_name)
        return
      end

      spawn_data = JSON.parse(spawn_json, symbolize_names: true)
      identity = spawn_data[:identity]
      channel  = spawn_data[:channel]

      unless identity && channel
        Rails.logger.warn "Orchestrator: #{instance_name} spawn.json missing identity/channel — removing"
        Podman.stop_container(instance_name)
        return
      end

      # Agent must have a config in the Manager's database.
      # If the Manager was rebuilt and configs haven't been re-seeded,
      # we can't adopt this pod.
      config = AgentConfig.find_by(identity: identity)
      unless config
        Rails.logger.warn "Orchestrator: no AgentConfig for '#{identity}' — removing #{instance_name}"
        Podman.stop_container(instance_name)
        return
      end

      # Create or update Container record so Lifecycle.hot_swap! has
      # something to work with. If the record already exists (Manager
      # restarted without DB wipe), update it.
      container = Container.find_or_initialize_by(instance_name: instance_name)
      container.assign_attributes(
        identity: identity,
        channel: channel,
        container_id: pod[:id],
        state: "alive",
        wg_address: spawn_data.dig(:network, :wg_address),
        provisioned_services: config.services_for(channel),
        last_message_at: Time.current,
        last_health_at: Time.current
      )
      container.save!

      AuditLog.record("RECONCILE_ADOPT",
        instance_name: instance_name,
        identity: identity,
        detail: "Orphaned pod discovered — hot-swapping with fresh Router credentials")

      Lifecycle.hot_swap!(container)

      AuditLog.record("RECONCILE_COMPLETE",
        instance_name: instance_name,
        identity: identity)
    end
  end
end
