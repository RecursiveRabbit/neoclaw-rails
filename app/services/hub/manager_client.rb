# Two endpoints. That's the whole API.
#
#   POST /resolve  → { ip: "10.0.1.14" }
#   POST /release  → { ok: true }
#
# The Hub doesn't pass services — Manager owns that entirely.
# The Hub doesn't get a pubkey — Manager handles all WG.

module Hub
  class ManagerClient
    class << self
      # Ask the Manager to resolve (or spawn) an agent.
      # Returns { ip: "10.0.1.X" } or nil on failure.
      def resolve(identity:, channel:)
        response = post("/resolve", {
          identity: identity,
          channel: channel
        })

        return nil unless response&.status == 200 || response&.status == 201

        data = JSON.parse(response.body, symbolize_names: true)
        { ip: data[:ip] }
      rescue => e
        Rails.logger.error "Manager resolve failed: #{e.message}"
        nil
      end

      # Tell the Manager to release an agent.
      def release(instance:)
        response = post("/release", { instance: instance })
        response&.status == 200
      rescue => e
        Rails.logger.error "Manager release failed: #{e.message}"
        false
      end

      # Check Manager health.
      def status
        response = get("/status")
        return nil unless response&.status == 200
        JSON.parse(response.body, symbolize_names: true)
      rescue => e
        Rails.logger.error "Manager status failed: #{e.message}"
        nil
      end

      private

      def post(path, body)
        client.post(url(path), json: body)
      end

      def get(path)
        client.get(url(path))
      end

      def url(path)
        "#{Config.manager_url}#{path}"
      end

      def client
        @client ||= HTTPX.plugin(:persistent)
          .with(timeout: { operation_timeout: 60 })
      end
    end
  end
end
