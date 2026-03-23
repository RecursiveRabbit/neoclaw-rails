# The routing engine. A message arrives with m.mentions telling us
# who it's for. We deliver to those agents. That's it.
#
# No body parsing. No listener system. No sole-agent guessing.
# Matrix already knows who's mentioned — we just act on it.

module Hub
  class Router
    class << self
      # Route a message to mentioned agents.
      def route(matrix_event, room_id:, slug:, attachments: [])
        sender = extract_sender(matrix_event)
        return if sender == Config.appservice_user  # loop prevention

        body = matrix_event.dig("content", "body") || ""
        if command = Commands.parse(body, sender: sender)
          return Commands.execute(command, room_id: room_id, slug: slug)
        end

        # Process !previous — fetch history and prepend to content.
        event_id = matrix_event["event_id"]
        body = process_previous(body, room_id: room_id, event_id: event_id)

        # Who is this message for? Matrix tells us via m.mentions.
        targets = extract_mentions(matrix_event)
        return if targets.empty?

        targets.each do |target|
          deliver_to(target, room_id: room_id, slug: slug, sender: sender, content: body, attachments: attachments)
        end
      end

      private

      # Resolve an agent and deliver a message. Spawns if needed.
      def deliver_to(identity_name, room_id:, slug:, sender:, content:, attachments: [])
        instance_name = Identities.instance_name_for(identity_name, slug)

        route = RouteCache.get(instance_name)

        unless route
          route = resolve(identity_name, instance_name: instance_name, room_id: room_id, slug: slug)
          return unless route
          wait_for_relay_and_deliver(instance_name, route, sender: sender, content: content, attachments: attachments)
          return
        end

        if RouteCache.resolving?(instance_name)
          wait_for_relay_and_deliver(instance_name, route, sender: sender, content: content, attachments: attachments)
          return
        end

        unless deliver(route[:ip], sender: sender, channel: slug, content: content, attachments: attachments)
          Rails.logger.warn "Delivery to #{instance_name} failed — clearing stale route"
          RouteCache.delete(instance_name)
          deliver_to(identity_name, room_id: room_id, slug: slug, sender: sender, content: content, attachments: attachments)
        end
      end

      # Ask the Manager for an agent. Caches the route on success.
      def resolve(identity_name, instance_name:, room_id:, slug:)
        return RouteCache.get(instance_name) if RouteCache.resolving?(instance_name)

        RouteCache.mark_resolving(instance_name)

        result = ManagerClient.resolve(identity: identity_name, channel: slug)

        if result && result[:ip]
          RouteCache.set(instance_name, ip: result[:ip], identity: identity_name, room_id: room_id, slug: slug)
          RouteCache.get(instance_name)
        else
          RouteCache.clear_resolving(instance_name)
          Matrix.puppet(identity_name, room_id, "Failed to spawn. Manager returned no IP.")
          nil
        end
      rescue => e
        Rails.logger.error "resolve failed for #{identity_name}: #{e.message}"
        RouteCache.clear_resolving(instance_name)
        Matrix.puppet(identity_name, room_id, "Failed to spawn: #{e.message}")
        nil
      end

      # Wait for a relay to come online, then deliver the message.
      # Runs in a background thread so we don't block Synapse.
      def wait_for_relay_and_deliver(instance_name, route, sender:, content:, attachments: [])
        Thread.new do
          ip = route[:ip]
          identity_name = route[:identity]
          room_id = route[:room_id]
          slug = route[:slug]

          ready = false
          150.times do |i|
            sleep 2
            if Relay.health(ip: ip)
              ready = true
              break
            end

            if i == 15
              status = ManagerClient.status
              if status
                container = status[:containers]&.find { |c| c[:instance] == instance_name }
                if container.nil? || container[:state] == "inactive"
                  Rails.logger.error "Pod #{instance_name} went inactive during boot"
                  break
                end
                if container[:state] == "starting"
                  Rails.logger.error "Container #{instance_name} still starting after 30s with no relay — likely crashed"
                  break
                end
              end
            end
          end

          if ready
            RouteCache.clear_resolving(instance_name)
            deliver(ip, sender: sender, channel: slug, content: content, attachments: attachments)
            Rails.logger.info "Delivered to #{instance_name} after relay came up"
          else
            Rails.logger.error "Relay for #{instance_name} never came up"
            RouteCache.delete(instance_name)
            Matrix.puppet(identity_name, room_id, "Failed to start. Check the pod logs.")
          end
        rescue => e
          Rails.logger.error "wait_for_relay failed for #{instance_name}: #{e.message}"
        end
      end

      def deliver(ip, sender:, channel:, content:, attachments: [])
        Relay.post_message(ip: ip, sender: sender, channel: channel, content: content, attachments: attachments)
      end

      # Extract all mentioned identities from m.mentions.user_ids.
      # Returns array of identity names we know about.
      def extract_mentions(event)
        user_ids = event.dig("content", "m.mentions", "user_ids") || []
        user_ids.filter_map do |uid|
          name = uid.split(":").first&.delete_prefix("@")
          name if name && Identities.exists?(name)
        end
      end

      # Process !previous syntax — fetch room history and prepend as context.
      def process_previous(body, room_id:, event_id:)
        # Strip optional @mention prefix — routing already handled by m.mentions
        stripped = body.sub(/\A\s*@[\w.\-]+\s+/, "")

        match = stripped.match(/\A!previous(?:\s+(\d+))?\s*(.*)\z/m)
        return body unless match

        count = (match[1] || "1").to_i.clamp(1, 50)
        remaining = match[2]&.strip
        remaining = nil if remaining&.empty?

        # Fetch extra to account for non-message events in the chunk
        messages = Matrix.recent_messages(room_id, limit: count + 5, exclude_event_id: event_id)
        messages = messages.last(count)

        return body if messages.empty?

        context = "[Previous messages]\n" +
          messages.map { |m| "@#{m[:sender]}: #{m[:content]}" }.join("\n")

        remaining ? "#{context}\n\n#{remaining}" : context
      end

      def extract_sender(event)
        sender = event["sender"] || ""
        sender.split(":").first&.delete_prefix("@") || sender
      end
    end
  end
end
