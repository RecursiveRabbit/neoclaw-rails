# Lifecycle management — freeze, sunset, force kill, teardown.

class Lifecycle
  class << self
    def release(instance_name)
      container = Container.find_by(instance_name: instance_name)
      return unless container
      freeze!(container)
    end

    def freeze!(container)
      return unless container.alive?

      container.update!(state: "freezing")
      AuditLog.record("FREEZE",
        instance_name: container.instance_name,
        identity: container.identity,
        detail: "Freezing — waiting for relay signal")

      relay_signal(container, :freeze)
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

    def force_kill!(container)
      AuditLog.record("FORCE_KILL",
        instance_name: container.instance_name,
        identity: container.identity)

      begin
        session_data = Podman.cp(container.container_id, "/workspace/.claude/session.json")
        if session_data
          AuditLog.record("SESSION_RECOVERED",
            instance_name: container.instance_name,
            detail: "#{session_data.bytesize} bytes recovered")
        end
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

      (container.provisioned_services || []).each do |service_name|
        service = ServiceType.find_by(name: service_name)
        next unless service&.wg_interface
        WireGuard.remove_peer(interface: service.wg_interface, public_key: container.wg_pubkey)
      end
      WireGuard.remove_peer(interface: "wg-hub", public_key: container.wg_pubkey)

      Podman.rm(container.container_id) if container.container_id

      spawn_path = File.join(Surface.spawn_dir, "#{container.instance_name}.json")
      FileUtils.rm_f(spawn_path)

      container.update!(state: "dead")

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
      HTTPX.post(
        "http://#{container.wg_address}:9300/signal",
        json: { signal: signal.to_s }
      )
    rescue => e
      AuditLog.record("RELAY_SIGNAL_FAILED",
        instance_name: container.instance_name,
        detail: "#{signal}: #{e.message}")
    end
  end
end
