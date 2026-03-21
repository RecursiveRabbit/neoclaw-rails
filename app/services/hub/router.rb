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
        just_spawned = false

        unless agent
          agent = resolve(identity, room)
          return unless agent  # resolve failed, error already reported
          just_spawned = true
        end

        if just_spawned || agent.resolving?
          # Relay may not be listening yet. Wait for it in background
          # so we don't block the Synapse transaction endpoint.
          wait_for_relay_and_deliver(agent, sender: sender, content: content)
        else
          unless agent.deliver(sender: sender, content: content)
            # Delivery failed — pod is gone. Clear the stale route
            # and retry, which will trigger a fresh resolve.
            Rails.logger.warn "Delivery to #{agent.instance_name} failed — clearing stale route"
            agent.destroy!
            deliver_to(identity, room: room, sender: sender, content: content)
          end
        end
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

        result = ManagerClient.resolve(
          identity: identity.name,
          channel: room.slug
        )

        if result && result[:ip]
          # Store the IP but stay "resolving" — we don't know if the
          # relay is listening yet. deliver_to will poll and flip to alive.
          agent.update!(
            wg_address: result[:ip],
            state: "resolving",
            last_message_at: Time.current
          )
          agent
        else
          agent.destroy!
          Matrix.puppet(identity.name, room.matrix_room_id,
            "Failed to spawn. Manager returned no IP.")
          nil
        end
      rescue => e
        Rails.logger.error "resolve failed for #{identity.name}: #{e.message}"
        agent&.destroy!
        Matrix.puppet(identity.name, room.matrix_room_id,
          "Failed to spawn: #{e.message}")
        nil
      end

      # Wait for a relay to come online, then deliver the message.
      # Runs in a background thread so we don't block Synapse.
      # The relay's HTTP server starts before Claude Code boots, and
      # messages queue behind the boot mutex — so we just need to wait
      # for the HTTP server, not for boot to complete.
      def wait_for_relay_and_deliver(agent, sender:, content:)
        Thread.new do
          ip = agent.wg_address
          identity_name = agent.identity.name
          room_id = agent.room.matrix_room_id
          instance_name = agent.instance_name

          # Poll relay health every 2s for up to 5 minutes.
          # Also check Manager status periodically — if the container
          # died (entrypoint crash, OOM, etc.), fail immediately instead
          # of waiting the full 5 minutes in silence.
          ready = false
          150.times do |i|
            sleep 2
            if Relay.health(ip: ip)
              ready = true
              break
            end

            # After 30s with no relay, check if the container is even running.
            # The Manager DB may say "starting" even if podman says it's dead,
            # so we also check if it's been starting too long without a relay.
            if i == 15  # 30 seconds
              status = ManagerClient.status
              if status
                container = status[:containers]&.find { |c| c[:instance] == instance_name }
                if container.nil? || container[:state] == "dead"
                  Rails.logger.error "Container #{instance_name} died during boot"
                  break
                end
                # Still "starting" after 30s with no relay = probably crashed
                if container[:state] == "starting"
                  Rails.logger.error "Container #{instance_name} still starting after 30s with no relay — likely crashed"
                  break
                end
              end
            end
          end

          if ready
            agent.reload
            agent.update!(state: "alive") unless agent.alive?
            agent.deliver(sender: sender, content: content)
            Rails.logger.info "Delivered to #{instance_name} after relay came up"
          else
            Rails.logger.error "Relay for #{instance_name} never came up"
            agent.reload
            agent.destroy!
            Matrix.puppet(identity_name, room_id, "Failed to start. Check the pod logs.")
          end
        rescue => e
          Rails.logger.error "wait_for_relay failed for #{agent&.instance_name}: #{e.message}"
        end
      end

      # Route to all identities listening on this channel.
      # If no listeners match but the room has exactly one agent,
      # route to them — DMs and single-agent rooms are implicitly directed.
      def route_to_listeners(room:, sender:, content:)
        listeners = Listener.for_channel(room.slug).includes(:identity)

        if listeners.empty?
          # No explicit listeners — check for a sole agent in the room
          sole_agent = room.agents.includes(:identity).first
          if sole_agent && room.agents.count == 1 && sole_agent.identity.name != sender
            deliver_to(sole_agent.identity, room: room, sender: sender, content: content)
          end
          return
        end

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
        # May be wrapped in <p> tags by Element/clients
        if formatted_body =~ %r{\A\s*(?:<p>)?\s*<a href="https://matrix\.to/#/@([\w.-]+):[\w.-]+">[^<]*</a>\s*:?\s*(.*)}m
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
