# Relay client — delivers messages to agent containers.
# Each agent has a Relay sidecar at <wg_address>:9300.

module Hub
  class Relay
    RELAY_PORT = 9300

    class << self
      # POST a message to an agent's relay.
      def post_message(ip:, sender:, channel:, content:, attachments: [])
        response = client.post(
          "http://#{ip}:#{RELAY_PORT}/message",
          json: {
            from: sender,
            channel: channel,
            content: content,
            attachments: attachments
          }
        )

        response.status == 200
      rescue => e
        Rails.logger.error "Relay delivery to #{ip} failed: #{e.message}"
        false
      end

      # Check relay health.
      def health(ip:)
        response = client.get("http://#{ip}:#{RELAY_PORT}/health")
        return nil unless response.status == 200
        JSON.parse(response.body, symbolize_names: true)
      rescue
        nil
      end

      private

      def client
        @client ||= HTTPX.with(timeout: { operation_timeout: 10 })
      end
    end
  end
end
