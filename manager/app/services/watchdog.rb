# Background watchdog — detects and rescues silent pods.
#
# A silent pod is one where the relay has crashed and stopped responding.
# The relay reports health every 30s. If we haven't heard in 2 minutes
# AND the relay doesn't answer a direct ping, the pod is dead.
#
# This is the ONLY thing the Watchdog does. Idle freezing is handled by
# the Spawner when memory pressure requires it. Living agents are left alone.
#
# Runs every 60 seconds inside the Manager.

class Watchdog
  class << self
    def start
      return if @running
      @running = true
      @thread = Thread.new { run_loop }
      Rails.logger.info "Watchdog: started (#{check_interval}s interval)"
    end

    def stop
      @running = false
      @thread&.kill
      @thread = nil
    end

    def running?
      @running && @thread&.alive?
    end

    private

    # Re-read from DB each cycle so changes take effect without restart.
    def health_stale_threshold = Setting.get("watchdog.health_stale_threshold")
    def check_interval         = Setting.get("watchdog.check_interval")
    def boot_grace_period      = Setting.get("watchdog.boot_grace_period")

    def run_loop
      # Let the system settle before the first check
      sleep check_interval

      while @running
        begin
          check_silent_pods
        rescue => e
          Rails.logger.error "Watchdog: #{e.message}"
        end
        sleep check_interval
      end
    end

    # Detect pods where the relay has crashed.
    # Only rescue if the relay is confirmed unreachable.
    def check_silent_pods
      stale_threshold = health_stale_threshold.seconds.ago

      Container.alive.where("last_health_at < ?", stale_threshold).each do |container|
        # Skip recently spawned pods — they might still be booting
        next if container.created_at > boot_grace_period.seconds.ago

        # Confirm: try to reach the relay directly
        if relay_reachable?(container)
          # Relay is alive, just missed health reports. Update timestamp.
          container.update!(last_health_at: Time.current)
          next
        end

        Rails.logger.warn "Watchdog: #{container.instance_name} is silent (last health #{container.last_health_at}) — rescuing"

        AuditLog.record("SILENT_POD_DETECTED",
          instance_name: container.instance_name,
          identity: container.identity,
          detail: "No health report for #{((Time.current - container.last_health_at) / 60).round(1)} min, relay unreachable")

        # Notify the Hub — presence goes yellow, room gets notified
        HubClient.callback(event: "crash", instance: container.instance_name)

        # Rescue handles: save workspace, process session, teardown
        Lifecycle.rescue!(container)
      end
    end

    def relay_reachable?(container)
      response = HTTPX.get(
        "http://#{container.wg_address}:9300/health",
        timeout: { operation_timeout: 5 }
      )
      response.respond_to?(:status) && response.status == 200
    rescue
      false
    end
  end
end
