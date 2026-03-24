# Matrix integration — the Hub's connection to the outside world.
#
# Puppets agent accounts via the appservice API.
# Sends system messages as the appservice bot.
# Manages typing indicators and presence.

module Hub
  class Matrix
    class << self
      # Send a message as an agent (puppeting).
      # Auto-joins the puppet to the room if needed.
      # msgtype: "m.text" for agent speech, "m.notice" for narration.
      def puppet(agent_name, room_id, content, msgtype: "m.text")
        user_id = "@#{agent_name}:#{Config.server_name}"
        txn_id = SecureRandom.uuid

        response = put(
          "/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn_id}?user_id=#{user_id}",
          { msgtype: msgtype, body: content }
        )

        # If puppet isn't in the room, join and retry
        if response&.status == 403
          join_room(user_id, room_id)
          put(
            "/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{SecureRandom.uuid}?user_id=#{user_id}",
            { msgtype: msgtype, body: content }
          )
        end
      end

      # Send a system message (as the appservice bot).
      def notify(room_id, message)
        return unless room_id
        txn_id = SecureRandom.uuid

        response = put(
          "/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn_id}",
          { msgtype: "m.text", body: message }
        )

        # Bot not in room — join and retry
        if response&.status == 403
          bot_id = "@#{Config.appservice_user}:#{Config.server_name}"
          join_room(bot_id, room_id)
          put(
            "/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{SecureRandom.uuid}",
            { msgtype: "m.text", body: message }
          )
        end
      end

      # Set typing indicator for an agent.
      def set_typing(agent_name, room_id, typing)
        return unless room_id
        user_id = "@#{agent_name}:#{Config.server_name}"

        # Ensure puppet is in the room
        join_room(user_id, room_id)

        body = typing ? { typing: true, timeout: 30_000 } : { typing: false }
        put(
          "/_matrix/client/v3/rooms/#{room_id}/typing/#{user_id}?user_id=#{user_id}",
          body
        )
      end

      # Join a puppet user to a room.
      def join_room(user_id, room_id)
        encoded = room_id.gsub("!", "%21").gsub(":", "%3A")
        post("/_matrix/client/v3/join/#{encoded}?user_id=#{user_id}", {})
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
      # as_user: "@name:server" to query as a specific puppet.
      def room_name(room_id, as_user: nil)
        response = room_state(room_id, "m.room.name", as_user: as_user)
        return nil unless response&.status == 200
        JSON.parse(response.body)["name"]
      rescue
        nil
      end

      # Fetch canonical alias for a room.
      def room_alias(room_id, as_user: nil)
        response = room_state(room_id, "m.room.canonical_alias", as_user: as_user)
        return nil unless response&.status == 200
        JSON.parse(response.body)["alias"]
      rescue
        nil
      end

      # Fetch joined members of a room. Returns array of localparts.
      def room_members(room_id, as_user: nil)
        response = room_query(room_id, "joined_members", as_user: as_user)
        return [] unless response&.status == 200
        data = JSON.parse(response.body)
        (data["joined"] || {}).keys.map { |uid|
          uid.split(":").first&.delete_prefix("@")
        }.compact
      rescue => e
        Rails.logger.error "Matrix room_members #{room_id}: #{e.message}"
        []
      end

      # Fetch recent messages from a room. Returns array of
      # { sender: "name", content: "text" } in chronological order.
      def recent_messages(room_id, limit: 10, exclude_event_id: nil, as_user: nil)
        base_path = "/_matrix/client/v3/rooms/#{room_id}/messages?dir=b&limit=#{limit}"
        response = get(base_path, as_user: as_user)

        # Fallback: try as each known puppet
        unless response&.status == 200 || as_user
          Config.identities.each do |name|
            uid = "@#{name}:#{Config.server_name}"
            response = get(base_path, as_user: uid)
            break if response&.status == 200
          end
        end

        return [] unless response&.status == 200

        data = JSON.parse(response.body)
        (data["chunk"] || [])
          .select { |e| e["type"] == "m.room.message" }
          .reject { |e| exclude_event_id && e["event_id"] == exclude_event_id }
          .map { |e|
            sender = e["sender"]&.split(":")&.first&.delete_prefix("@") || "unknown"
            content = e.dig("content", "body") || ""
            { sender: sender, content: content }
          }
          .reverse
      rescue => e
        Rails.logger.error "Matrix recent_messages #{room_id}: #{e.message}"
        []
      end

      # Download media from an mxc:// URL. Returns { data:, filename:, content_type: } or nil.
      def download_media(mxc_url)
        return nil unless mxc_url&.start_with?("mxc://")
        parts = mxc_url[6..].split("/", 2)
        return nil unless parts.size == 2

        server, media_id = parts
        response = get("/_matrix/media/v3/download/#{server}/#{media_id}")
        return nil unless response&.status == 200

        content_type = response.headers["content-type"] || "application/octet-stream"
        disposition = response.headers["content-disposition"] || ""
        filename = if disposition =~ /filename="?([^";\s]+)"?/
          $1
        else
          ext = MIME_EXTENSIONS[content_type] || ""
          "#{media_id}#{ext}"
        end

        { data: response.body.to_s, filename: filename, content_type: content_type }
      rescue => e
        Rails.logger.error "Media download failed for #{mxc_url}: #{e.message}"
        nil
      end

      MIME_EXTENSIONS = {
        "image/png" => ".png",
        "image/jpeg" => ".jpg",
        "image/gif" => ".gif",
        "image/webp" => ".webp",
        "audio/ogg" => ".ogg",
        "audio/mp4" => ".m4a",
        "video/mp4" => ".mp4",
        "application/pdf" => ".pdf",
      }.freeze

      private

      # Query room state, optionally as a specific puppet.
      def room_state(room_id, state_type, as_user: nil)
        response = get("/_matrix/client/v3/rooms/#{room_id}/state/#{state_type}", as_user: as_user)
        return response if response&.status == 200

        return response if as_user

        Config.identities.each do |name|
          uid = "@#{name}:#{Config.server_name}"
          response = get("/_matrix/client/v3/rooms/#{room_id}/state/#{state_type}", as_user: uid)
          return response if response&.status == 200
        end
        nil
      end

      def room_query(room_id, endpoint, as_user: nil)
        response = get("/_matrix/client/v3/rooms/#{room_id}/#{endpoint}", as_user: as_user)
        return response if response&.status == 200

        return response if as_user

        Config.identities.each do |name|
          uid = "@#{name}:#{Config.server_name}"
          response = get("/_matrix/client/v3/rooms/#{room_id}/#{endpoint}", as_user: uid)
          return response if response&.status == 200
        end
        nil
      end

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

      def post(path, body)
        client.post(
          "#{Config.synapse_url}#{path}",
          headers: auth_headers,
          json: body
        )
      rescue => e
        Rails.logger.error "Matrix POST #{path}: #{e.message}"
        nil
      end

      def get(path, as_user: nil)
        url = "#{Config.synapse_url}#{path}"
        if as_user
          url += (path.include?("?") ? "&" : "?") + "user_id=#{as_user}"
        end
        client.get(url, headers: auth_headers)
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
