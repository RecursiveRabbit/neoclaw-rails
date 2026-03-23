# The routing engine. A message arrives, the router figures out
# where it goes. If the agent isn't running, it asks the Manager.
#
# No database. Routes live in memory. Need status? Ask the relay.

module Hub
  class Router
    class << self
      # Route a message to the right agent(s).
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

        # Use Matrix m.mentions to find the target — works regardless of
        # where in the message the @mention appears.
        target = extract_mention(matrix_event)

        if target
          # Queue this message for listeners — they'll get it as context
          # when the target agent responds. Without this, listeners see
          # the reply but not what was asked.
          if Identities.listeners_for(slug).any?
            ListenerQueue.push(room_id, sender: sender, content: body)
          end
          deliver_to(target, room_id: room_id, slug: slug, sender: sender, content: body, attachments: attachments)
        else
          route_to_listeners(room_id: room_id, slug: slug, sender: sender, content: body, attachments: attachments)
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

      # Route to all identities listening on this channel.
      def route_to_listeners(room_id:, slug:, sender:, content:, attachments: [])
        # Flush queued context — @mentioned messages that listeners missed.
        queued = ListenerQueue.flush(room_id)
        unless queued.empty?
          context = "[Earlier in ##{slug}]\n" +
            queued.map { |m| "@#{m[:sender]}: #{m[:content]}" }.join("\n")
          content = "#{context}\n\n#{content}"
        end

        listener_names = Identities.listeners_for(slug)

        if listener_names.empty?
          routes = RouteCache.routes_in_room(room_id)
          if routes.size == 1
            _, route = routes.first
            unless route[:identity] == sender
              deliver_to(route[:identity], room_id: room_id, slug: slug, sender: sender, content: content, attachments: attachments)
            end
            return
          end

          if routes.empty?
            identity_name = sole_agent_in_room(room_id, exclude: sender)
            if identity_name
              deliver_to(identity_name, room_id: room_id, slug: slug, sender: sender, content: content, attachments: attachments)
            end
          end
          return
        end

        listener_names.each do |name|
          next if name == sender
          listen_content = "@#{sender} in ##{slug} said: \"#{content}\""
          deliver_to(name, room_id: room_id, slug: slug, sender: sender, content: listen_content, attachments: attachments)
        end
      end

      # Check Matrix room membership for a sole agent.
      def sole_agent_in_room(room_id, exclude:)
        members = Matrix.room_members(room_id)
        agents = members.select { |name| name != exclude && Identities.exists?(name) }
        agents.size == 1 ? agents.first : nil
      rescue => e
        Rails.logger.error "sole_agent_in_room failed: #{e.message}"
        nil
      end

      # Extract mentioned identity from m.mentions.user_ids.
      # Returns the first mentioned identity we know, or nil.
      def extract_mention(event)
        user_ids = event.dig("content", "m.mentions", "user_ids") || []
        user_ids.each do |uid|
          name = uid.split(":").first&.delete_prefix("@")
          return name if name && Identities.exists?(name)
        end
        nil
      end

      # Process !previous syntax — fetch room history and prepend as context.
      #
      # Syntax:
      #   @agent !previous          → send 1 previous message
      #   @agent !previous 3        → send 3 previous messages
      #   @agent !previous 3 <msg>  → send 3 previous messages + new message
      #   !previous 3               → works without @mention (DMs, sole agent)
      #
      # Returns the transformed body, or the original body if no !previous found.
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

      def deny(reason, room_id:)
        Rails.logger.info "DENY: #{reason}"
      end
    end
  end
end
