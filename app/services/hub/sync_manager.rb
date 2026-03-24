# Per-puppet /sync loops. Each identity gets a long-polling thread
# that receives events from Matrix and delivers them to agents.
#
# Matrix decides who sees what — DMs, @mentions, room notification
# settings. The Hub just delivers.
#
# Appservice as_token for outbound (puppeting). /sync with
# ?user_id= masquerading for inbound. No per-puppet credentials.

module Hub
  class SyncManager
    SYNC_TIMEOUT = 30_000  # 30s long-poll
    RETRY_DELAY = 5

    class << self
      def start
        @loops = {}
        @mutex = Mutex.new

        Config.identities.each do |name|
          loop_obj = SyncLoop.new(name)
          @mutex.synchronize { @loops[name] = loop_obj }
          loop_obj.start
        end

        Rails.logger.info "SyncManager: started #{@loops.size} sync loops"
      end

      def stop
        @mutex.synchronize do
          @loops&.each_value(&:stop)
          @loops&.clear
        end
        Rails.logger.info "SyncManager: stopped"
      end

      def running?
        @mutex.synchronize { @loops&.any? { |_, l| l.alive? } || false }
      end

      def status
        @mutex.synchronize do
          (@loops || {}).transform_values { |l| { alive: l.alive?, rooms: l.room_count } }
        end
      end

      def identity_count
        @mutex.synchronize { @loops&.size || 0 }
      end
    end

    # One sync loop per puppet identity.
    class SyncLoop
      attr_reader :room_count

      def initialize(identity_name)
        @identity = identity_name
        @user_id = "@#{identity_name}:#{Config.server_name}"
        @since = nil
        @running = false
        @thread = nil
        @room_count = 0
      end

      def start
        @running = true
        @thread = Thread.new { run }
      end

      def stop
        @running = false
        @thread&.kill
        @thread = nil
      end

      def alive?
        @thread&.alive? || false
      end

      private

      def run
        initial_sync
        poll_loop
      rescue => e
        Rails.logger.error "SyncLoop[#{@identity}]: thread died: #{e.message}"
        @running = false
      end

      def poll_loop
        while @running
          begin
            response = do_sync(timeout: SYNC_TIMEOUT)
            next unless response&.status == 200

            data = JSON.parse(response.body, symbolize_names: false)
            @since = data["next_batch"]
            process_sync(data)
          rescue => e
            Rails.logger.error "SyncLoop[#{@identity}]: #{e.message}"
            sleep RETRY_DELAY if @running
          end
        end
      end

      def initial_sync
        response = do_sync(timeout: 0, initial: true)
        return unless response&.status == 200

        data = JSON.parse(response.body, symbolize_names: false)
        @since = data["next_batch"]
        learn_rooms(data)
        Rails.logger.info "SyncLoop[#{@identity}]: synced, #{@room_count} rooms"
      end

      # --- Sync HTTP ---

      def do_sync(timeout:, initial: false)
        params = {
          timeout: timeout,
          user_id: @user_id,
          filter: (initial ? initial_filter : poll_filter).to_json
        }
        params[:since] = @since if @since

        query = URI.encode_www_form(params)
        client.get(
          "#{Config.synapse_url}/_matrix/client/v3/sync?#{query}",
          headers: { "Authorization" => "Bearer #{Config.as_token}" }
        )
      rescue => e
        Rails.logger.error "SyncLoop[#{@identity}] sync failed: #{e.message}"
        nil
      end

      # Initial sync: learn room state, skip old messages.
      def initial_filter
        {
          room: {
            timeline: { types: ["m.room.message"], limit: 0 },
            state: { types: ["m.room.name", "m.room.canonical_alias"] },
            ephemeral: { types: [] }
          },
          presence: { types: [] }
        }
      end

      # Poll filter: message events + room state changes.
      def poll_filter
        {
          room: {
            timeline: { types: ["m.room.message"] },
            state: { types: ["m.room.name", "m.room.canonical_alias"] },
            ephemeral: { types: [] }
          },
          presence: { types: [] }
        }
      end

      # --- Event processing ---

      def process_sync(data)
        rooms = data["rooms"] || {}

        # Auto-join invites
        (rooms["invite"] || {}).each do |room_id, _|
          Matrix.join_room(@user_id, room_id)
          Rails.logger.info "SyncLoop[#{@identity}]: joined #{room_id}"
        end

        # Process joined rooms
        joined = rooms["join"] || {}
        @room_count = joined.size

        joined.each do |room_id, room_data|
          learn_room_state(room_id, room_data)

          (room_data.dig("timeline", "events") || []).each do |event|
            process_message(event, room_id: room_id)
          end
        end
      end

      def process_message(event, room_id:)
        return unless event["type"] == "m.room.message"

        sender = extract_sender(event)
        return if sender == @identity
        return if sender == Config.appservice_user

        body = event.dig("content", "body") || ""
        slug = resolve_slug(room_id)
        return unless slug

        # Operator commands
        if command = Commands.parse(body, sender: sender)
          Commands.execute(command, room_id: room_id, slug: slug)
          return
        end

        # !previous context injection
        event_id = event["event_id"]
        body = process_previous(body, room_id: room_id, event_id: event_id)

        # Media attachments
        attachments = extract_attachments(event)

        # Deliver to agent
        deliver(room_id: room_id, slug: slug, sender: sender, content: body, attachments: attachments)
      end

      # --- Delivery ---

      def deliver(room_id:, slug:, sender:, content:, attachments: [])
        instance = "#{@identity}-#{slug}"
        route = RouteCache.get(instance)

        if route && !RouteCache.resolving?(instance)
          if Relay.post_message(ip: route[:ip], sender: sender, channel: slug, content: content, attachments: attachments)
            return
          end
          Rails.logger.warn "Delivery to #{instance} failed — clearing stale route"
          RouteCache.delete(instance)
        end

        resolve_and_deliver(instance, room_id: room_id, slug: slug, sender: sender, content: content, attachments: attachments)
      end

      def resolve_and_deliver(instance, room_id:, slug:, sender:, content:, attachments: [])
        return if RouteCache.resolving?(instance)
        RouteCache.mark_resolving(instance)

        result = ManagerClient.resolve(identity: @identity, channel: slug)
        unless result && result[:ip]
          RouteCache.clear_resolving(instance)
          Matrix.puppet(@identity, room_id, "Failed to spawn. Manager returned no IP.")
          return
        end

        ip = result[:ip]
        RouteCache.set(instance, ip: ip, identity: @identity, room_id: room_id, slug: slug)

        # Wait for relay in background — don't block the sync loop
        Thread.new do
          wait_for_relay(instance, ip, room_id: room_id, slug: slug) do
            Relay.post_message(ip: ip, sender: sender, channel: slug, content: content, attachments: attachments)
          end
        end
      end

      def wait_for_relay(instance, ip, room_id:, slug:)
        150.times do |i|
          sleep 2
          if Relay.health(ip: ip)
            RouteCache.clear_resolving(instance)
            yield
            Rails.logger.info "Delivered to #{instance} after relay boot"
            return
          end

          if i == 15
            status = ManagerClient.status
            if status
              container = status[:containers]&.find { |c| c[:instance] == instance }
              if container.nil? || container[:state] == "inactive"
                Rails.logger.error "Pod #{instance} went inactive during boot"
                break
              end
            end
          end
        end

        Rails.logger.error "Relay for #{instance} never came up"
        RouteCache.delete(instance)
        Matrix.puppet(@identity, room_id, "Failed to start. Check the pod logs.")
      rescue => e
        Rails.logger.error "wait_for_relay failed for #{instance}: #{e.message}"
      end

      # --- Room state ---

      def learn_rooms(data)
        joined = data.dig("rooms", "join") || {}
        @room_count = joined.size
        joined.each { |room_id, room_data| learn_room_state(room_id, room_data) }
      end

      def learn_room_state(room_id, room_data)
        (room_data.dig("state", "events") || []).each do |event|
          case event["type"]
          when "m.room.name"
            name = event.dig("content", "name")
            Rooms.update_name(room_id, name) if name
          when "m.room.canonical_alias"
            alias_str = event.dig("content", "alias")
            Rooms.update_alias(room_id, alias_str) if alias_str
          end
        end
      end

      def resolve_slug(room_id)
        room = Rooms.get(room_id)
        return room[:slug] if room&.dig(:slug)

        # Query Matrix as this puppet
        canonical_alias = Matrix.room_alias(room_id, as_user: @user_id)
        if canonical_alias
          Rooms.update_alias(room_id, canonical_alias)
        else
          name = Matrix.room_name(room_id, as_user: @user_id)
          Rooms.update_name(room_id, name) if name
        end

        room = Rooms.find_or_create(room_id)
        return room[:slug] if room[:slug]

        # DM detection — two people in a room
        members = Matrix.room_members(room_id, as_user: @user_id)
        non_bot = members.reject { |m| m == Config.appservice_user }
        if non_bot.size == 2
          other = non_bot.find { |m| m != @identity }
          if other
            Rooms.update_name(room_id, "dm-#{other}")
            return "dm-#{other}"
          end
        end

        Rails.logger.error "SyncLoop[#{@identity}]: no slug for #{room_id}"
        nil
      end

      # --- Message processing helpers ---

      def process_previous(body, room_id:, event_id:)
        stripped = body.sub(/\A\s*@[\w.\-]+\s+/, "")
        match = stripped.match(/\A!previous(?:\s+(\d+))?\s*(.*)\z/m)
        return body unless match

        count = (match[1] || "1").to_i.clamp(1, 50)
        remaining = match[2]&.strip
        remaining = nil if remaining&.empty?

        messages = Matrix.recent_messages(room_id, limit: count + 5, exclude_event_id: event_id, as_user: @user_id)
        messages = messages.last(count)
        return body if messages.empty?

        context = "[Previous messages]\n" +
          messages.map { |m| "@#{m[:sender]}: #{m[:content]}" }.join("\n")

        remaining ? "#{context}\n\n#{remaining}" : context
      end

      MEDIA_MSGTYPES = %w[m.image m.file m.audio m.video].to_set.freeze

      def extract_attachments(event)
        content = event["content"] || {}
        msgtype = content["msgtype"]
        return [] unless MEDIA_MSGTYPES.include?(msgtype)

        mxc_url = content["url"]
        return [] unless mxc_url

        media = Matrix.download_media(mxc_url)
        return [] unless media

        filename = content["body"] || media[:filename]
        [{
          filename: filename,
          content_type: media[:content_type],
          data: Base64.strict_encode64(media[:data]),
          msgtype: msgtype
        }]
      end

      def extract_sender(event)
        sender = event["sender"] || ""
        sender.split(":").first&.delete_prefix("@") || sender
      end

      # Longer timeout than Matrix client — must accommodate long-poll.
      def client
        @client ||= HTTPX.with(timeout: { operation_timeout: 90 })
      end
    end
  end
end
