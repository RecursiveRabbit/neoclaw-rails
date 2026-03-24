# Background thread that checks for due cron messages and fires them.
# Runs every 30 seconds. Posts messages to Hub for Matrix delivery.

class CronScheduler
  CHECK_INTERVAL = 30  # seconds

  class << self
    def start
      return if @running
      @running = true
      @thread = Thread.new { run_loop }
      Rails.logger.info "CronScheduler: started (#{CHECK_INTERVAL}s interval)"
    end

    def stop
      @running = false
      @thread&.kill
      @thread = nil
      Rails.logger.info "CronScheduler: stopped"
    end

    def running?
      @running && @thread&.alive?
    end

    private

    def run_loop
      while @running
        sleep CHECK_INTERVAL
        fire_due_messages
      end
    rescue => e
      Rails.logger.error "CronScheduler: thread died: #{e.message}"
      @running = false
    end

    def fire_due_messages
      CronMessage.due.find_each do |msg|
        fire(msg)
      end
    rescue => e
      Rails.logger.error "CronScheduler: #{e.message}"
    end

    def fire(msg)
      HubClient.post_message(channel: msg.channel, body: msg.body)
      msg.update!(last_fired_at: Time.current)
      msg.compute_next_fire
      AuditLog.record("CRON_FIRED", detail: msg.description)
      Rails.logger.info "CronScheduler: fired #{msg.description}"
    rescue => e
      Rails.logger.error "CronScheduler: failed to fire #{msg.id}: #{e.message}"
    end
  end
end
