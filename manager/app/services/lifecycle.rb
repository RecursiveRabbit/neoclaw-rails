# Lifecycle management — freeze, sunset, force kill, teardown.
#
# The Router handles all WireGuard state. The Manager just tells it
# what to do (freeze = remove peer, decommission = remove everything).

class Lifecycle
  class << self
    def release(instance_name)
      container = Container.find_by(instance_name: instance_name)
      return unless container

      if container.alive?
        freeze!(container)
      else
        # Starting, freezing, or any other non-alive state — rescue.
        rescue!(container)
      end
    end

    def freeze!(container)
      return unless container.alive?

      container.update!(state: "freezing")
      AuditLog.record("FREEZE",
        instance_name: container.instance_name,
        identity: container.identity,
        detail: "Freezing — waiting for relay signal")

      unless relay_signal(container, :freeze)
        # Relay unreachable — fall back to rescue
        AuditLog.record("FREEZE_FALLBACK_RESCUE",
          instance_name: container.instance_name,
          identity: container.identity,
          detail: "Relay unreachable, falling back to rescue")
        rescue!(container)
      end
    end

    def sunset!(container)
      return unless container.alive?

      container.update!(state: "freezing")
      AuditLog.record("SUNSET",
        instance_name: container.instance_name,
        identity: container.identity,
        detail: "Context limit — sunsetting")

      relay_signal(container, :sunset)
    end

    # Hot swap — new image, fresh credentials, preserved workspace and session.
    # The agent resumes with --continue. Seconds, not minutes.
    def hot_swap!(container)
      instance = container.instance_name
      AuditLog.record("SWAP_START", instance_name: instance, identity: container.identity)

      # Rescue workspace and session from running pod
      rescue_dir = File.join(Surface.host_rescue_dir, "swap-#{instance}")
      Podman.rescue_workspace(instance, rescue_dir)

      # Regenerate spawn.json with fresh credentials.
      # Spawner.respawn handles: new WG/SSH keys, Router.activate,
      # re-provision Forgejo/tokens, write new spawn.json.
      spawn_path = Spawner.respawn(
        identity: container.identity,
        channel: container.channel,
        instance_name: instance
      )

      # Stop and remove old pod
      Podman.rm(container.container_id) if container.container_id

      # Start new pod with swap hold
      new_id = Podman.run_swap(
        instance_name: instance,
        spawn_path: spawn_path,
        rescue_dir: rescue_dir
      )

      container.update!(container_id: new_id, state: "starting")

      AuditLog.record("SWAP_COMPLETE",
        instance_name: instance, identity: container.identity,
        detail: "Workspace and session preserved, credentials refreshed")
    end

    def rescue!(container)
      AuditLog.record("RESCUE",
        instance_name: container.instance_name,
        identity: container.identity)

      # Save everything — workspace and .claude session.
      # The whole point of rescue is to not lose work.
      begin
        timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
        rescue_path = File.join(Surface.host_rescue_dir, container.instance_name, timestamp)
        Podman.rescue_workspace(container.instance_name, rescue_path)
        AuditLog.record("SESSION_RECOVERED",
          instance_name: container.instance_name,
          detail: "Workspace rescued to #{rescue_path}")
      rescue => e
        AuditLog.record("SESSION_RECOVERY_FAILED",
          instance_name: container.instance_name, detail: e.message)
      end

      teardown!(container)
    end

    def teardown!(container)
      (container.provisioned_services || []).each do |service_name|
        service = ServiceType.find_by(name: service_name)
        next unless service
        begin
          Provisioner.teardown(service, instance_name: container.instance_name)
        rescue => e
          AuditLog.record("TEARDOWN_PARTIAL",
            instance_name: container.instance_name,
            detail: "#{service_name}: #{e.message}")
        end
      end

      # Tell the Router to freeze this agent (removes WG peer, keeps firewall rules)
      begin
        RouterClient.freeze(name: container.instance_name)
      rescue => e
        AuditLog.record("ROUTER_FREEZE_FAILED",
          instance_name: container.instance_name, detail: e.message)
      end

      Podman.rm(container.container_id) if container.container_id

      spawn_path = File.join(Surface.spawn_dir, "#{container.instance_name}.json")
      FileUtils.rm_f(spawn_path)

      container.update!(state: "inactive")

      HubClient.callback(
        event: "released",
        instance: container.instance_name,
        reason: "teardown"
      )

      AuditLog.record("TEARDOWN",
        instance_name: container.instance_name,
        identity: container.identity,
        detail: "Clean teardown")
    end

    private

    def relay_signal(container, signal)
      response = HTTPX.post(
        "http://#{container.wg_address}:9300/signal",
        json: { signal: signal.to_s }
      )
      response.respond_to?(:status) && response.status == 200
    rescue => e
      AuditLog.record("RELAY_SIGNAL_FAILED",
        instance_name: container.instance_name,
        detail: "#{signal}: #{e.message}")
      false
    end
  end
end
