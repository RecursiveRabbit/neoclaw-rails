# The routing engine. A message arrives, the router figures out
# where it goes. If the agent isn't running, it asks the Manager.
#
# This is the heart of the Hub. Everything else is plumbing.

module Hub
  class Router
    class << self
      # Route a message to the right agent(s). Returns delivery results.
      def route(matrix_event, room:)
        sender = extract_sender(matrix_event)
        return if sender == Config.appservice_user  # loop prevention

        # Operator commands intercept before routing
        body = matrix_event.dig("content", "body") || ""
        if command = Commands.parse(body, sender: sender)
          return Commands.execute(command, room: room)
        end

        # Who is this message for?
        target, message = parse_mention(body, matrix_event.dig("content", "formatted_body"))

        if target
          # Explicit @mention → route to one identity
          identity = Identity.find_by(name: target)
          return deny("unknown agent '#{target}'", room: room) unless identity
          deliver_to(identity, room: room, sender: sender, content: message)
        else
          # No mention → route to all listeners on this channel
          route_to_listeners(room: room, sender: sender, content: body)
        end
      end

      private

      # Resolve an agent and deliver a message. Spawns if needed.
      def deliver_to(identity, room:, sender:, content:)
        agent = room.agent_for(identity)

        unless agent
          agent = resolve(identity, room)
          return unless agent  # resolve failed, error already reported
        end

        agent.deliver(sender: sender, content: content)
      end

      # Ask the Manager for an agent. Creates the Agent route on success.
      def resolve(identity, room)
        instance_name = identity.instance_name_for(room.slug)

        # Already resolving? Don't double-spawn.
        existing = Agent.resolving.find_by(instance_name: instance_name)
        return existing if existing

        # Create a placeholder route while we wait
        agent = room.agents.create!(
          identity: identity,
          instance_name: instance_name,
          state: "resolving"
        )

        # Set typing immediately — agent is booting
        Matrix.set_typing(identity.name, room.matrix_room_id, true)

        result = ManagerClient.resolve(
          identity: identity.name,
          channel: room.slug
        )

        if result && result[:ip]
          agent.update!(
            wg_address: result[:ip],
            state: "alive",
            last_message_at: Time.current
          )
          Matrix.set_typing(identity.name, room.matrix_room_id, false)
          agent
        else
          agent.destroy!
          Matrix.set_typing(identity.name, room.matrix_room_id, false)
          Matrix.notify(room.matrix_room_id,
            "Spawn failed for #{identity.name}")
          nil
        end
      rescue => e
        Rails.logger.error "resolve failed for #{identity.name}: #{e.message}"
        agent&.destroy!
        Matrix.notify(room.matrix_room_id,
          "Spawn failed for #{identity.name}: #{e.message}")
        nil
      end

      # Route to all identities listening on this channel.
      def route_to_listeners(room:, sender:, content:)
        listeners = Listener.for_channel(room.slug).includes(:identity)
        return if listeners.empty?

        listeners.each do |listener|
          identity = listener.identity
          next if identity.name == sender  # don't echo back

          listen_content = "@#{sender} in ##{room.slug} said: \"#{content}\""
          deliver_to(identity, room: room, sender: sender, content: listen_content)
        end
      end

      # Parse @mention from message body or Matrix pill.
      def parse_mention(body, formatted_body = nil)
        # Plain @mention
        if body =~ /\A\s*@([\w-]+)\s*(.*)/m
          return [$1.downcase, $2.strip]
        end

        # Matrix pill: <a href="https://matrix.to/#/@user:server">Name</a>
        if formatted_body =~ %r{\A\s*<a href="https://matrix\.to/#/@([\w.-]+):[\w.-]+">[^<]*</a>\s*:?\s*(.*)}m
          localpart = $1.downcase
          rest = body.sub(/\A\s*\S+\s*:?\s*/, "").strip
          return [localpart, rest]
        end

        [nil, body]
      end

      def extract_sender(event)
        sender = event["sender"] || ""
        sender.split(":").first&.delete_prefix("@") || sender
      end

      def deny(reason, room:)
        Rails.logger.info "DENY: #{reason}"
      end
    end
  end
end
