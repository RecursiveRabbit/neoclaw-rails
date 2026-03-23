# Maintains Matrix presence for running agents.
#
# Green (online):      Agent is running — relay up, Claude responding.
# Yellow (unavailable): Agent was frozen or crashed — set once, then expires.
# Grey (offline):      Presence expired — Hub is down or agent long gone.
#
# The key insight: we only MAINTAIN green. Yellow is set once at lifecycle
# events and left to expire naturally. Grey happens automatically when the
# Hub stops refreshing — which means Hub crash = instant grey dots for
# every agent. Free alarm signal.
#
# Never explicitly set "offline". Never log out agent tokens.

module Hub
  class PresenceManager
    REFRESH_INTERVAL = 60  # seconds — Matrix presence typically expires after 5+ minutes

    class << self
      def start
        return if @running
        @running = true
        @thread = Thread.new { run_loop }
        Rails.logger.info "PresenceManager: started (#{REFRESH_INTERVAL}s refresh)"
      end

      def stop
        @running = false
        @thread&.kill
        @thread = nil
        Rails.logger.info "PresenceManager: stopped"
      end

      def running?
        @running && @thread&.alive?
      end

      private

      def run_loop
        while @running
          sleep REFRESH_INTERVAL
          refresh_all
        end
      rescue => e
        Rails.logger.error "PresenceManager: thread died: #{e.message}"
        @running = false
      end

      def refresh_all
        routes = RouteCache.all
        return if routes.empty?

        # Deduplicate by identity — singleton agents appear once,
        # but multi-instance agents might share an identity across rooms.
        refreshed = Set.new

        routes.each do |_instance, route|
          identity = route[:identity]
          next if refreshed.include?(identity)

          Matrix.set_presence(identity, "online")
          refreshed.add(identity)
        end

        Rails.logger.debug "PresenceManager: refreshed #{refreshed.size} agents" if refreshed.size > 0
      rescue => e
        Rails.logger.error "PresenceManager: refresh failed: #{e.message}"
      end
    end
  end
end
