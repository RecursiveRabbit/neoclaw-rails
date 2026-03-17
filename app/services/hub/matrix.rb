# Matrix integration — the Hub's connection to the outside world.
#
# Puppets agent accounts via the appservice API.
# Sends system messages as the appservice bot.
# Manages typing indicators and presence.

module Hub
  class Matrix
    class << self
      # Send a message as an agent (puppeting).
      def puppet(agent_name, room_id, content)
        user_id = "@#{agent_name}:#{Config.server_name}"
        txn_id = SecureRandom.uuid

        put(
          "/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn_id}?user_id=#{user_id}",
          { msgtype: "m.text", body: content }
        )
      end

      # Send a system message (as the appservice bot).
      def notify(room_id, message)
        return unless room_id
        txn_id = SecureRandom.uuid

        put(
          "/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn_id}",
          { msgtype: "m.text", body: message }
        )
      end

      # Set typing indicator for an agent.
      def set_typing(agent_name, room_id, typing)
        return unless room_id
        user_id = "@#{agent_name}:#{Config.server_name}"

        body = typing ? { typing: true, timeout: 30_000 } : { typing: false }
        put(
          "/_matrix/client/v3/rooms/#{room_id}/typing/#{user_id}?user_id=#{user_id}",
          body
        )
      end

      # Set presence for an agent.
      def set_presence(agent_name, presence)
        user_id = "@#{agent_name}:#{Config.server_name}"
        put(
          "/_matrix/client/v3/presence/#{user_id}/status?user_id=#{user_id}",
          { presence: presence }
        )
      end

      # Fetch room name from Synapse.
      def room_name(room_id)
        response = get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.name")
        return nil unless response&.status == 200
        JSON.parse(response.body)["name"]
      rescue
        nil
      end

      # Fetch recent messages from a room (for !previous).
      def recent_messages(room_id, limit: 10)
        response = get(
          "/_matrix/client/v3/rooms/#{room_id}/messages?dir=b&limit=#{limit}")
        return [] unless response&.status == 200

        data = JSON.parse(response.body)
        (data["chunk"] || [])
          .select { |e| e["type"] == "m.room.message" }
          .map { |e| e.dig("content", "body") }
          .compact
          .reverse
      rescue
        []
      end

      private

      def put(path, body)
        client.put(
          "#{Config.synapse_url}#{path}",
          headers: auth_headers,
          json: body
        )
      rescue => e
        Rails.logger.error "Matrix PUT #{path}: #{e.message}"
        nil
      end

      def get(path)
        client.get(
          "#{Config.synapse_url}#{path}",
          headers: auth_headers
        )
      rescue => e
        Rails.logger.error "Matrix GET #{path}: #{e.message}"
        nil
      end

      def auth_headers
        { "Authorization" => "Bearer #{Config.as_token}" }
      end

      def client
        @client ||= HTTPX.plugin(:persistent)
          .with(timeout: { operation_timeout: 10 })
      end
    end
  end
end
