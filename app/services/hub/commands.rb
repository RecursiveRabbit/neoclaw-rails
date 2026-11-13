# Operator commands — !agents, !freeze, !kill, !status, !help.
# Parsed from Matrix messages before routing. Only operators can execute.

module Hub
  class Commands
    REGISTRY = {}

    class << self
      # `sender` is the full Matrix ID (`@localpart:server`), never a localpart.
      #
      # Three outcomes, and they are different facts:
      #   nil            — not a command (no `!`, nothing after it, unknown verb)
      #   { refused: }   — a command-shaped message from someone who may not run it
      #   { name: ... }  — the command, from an operator
      #
      # The refusal names the identity it rejected rather than saying "not
      # permitted": an operator who has been configured with the wrong id — a bare
      # localpart, or their name on another server — needs to see which identity was
      # compared, or the same silence would answer a typo and a wrong rule.
      def parse(body, sender:)
        return nil unless body.strip.start_with?("!")

        parts = body.strip[1..].split(nil, 2)
        return nil if parts.empty?

        name = parts[0].to_s.downcase
        return nil if name.empty?

        # The gate: empty list refuses everybody, and the comparison is the exact
        # full ID. This runs before the registry lookup on purpose — "who are you"
        # is not a question whose answer depends on which verb was typed.
        unless Config.operators.include?(sender)
          return { refused: sender, attempted: name }
        end

        return nil unless REGISTRY.key?(name)

        { name: name, args: parts[1] || "", sender: sender }
      end

      def execute(command, room_id:, slug:)
        if (rejected = command[:refused])
          Matrix.notify(room_id, "#{rejected} is not an operator; !#{command[:attempted]} refused")
          return
        end

        handler = REGISTRY[command[:name]]
        return unless handler

        result = handler.call(command[:args], room_id: room_id, slug: slug)
        Matrix.notify(room_id, result) if result
      rescue => e
        Matrix.notify(room_id, "Command failed: #{e.message}")
      end

      def register(name, description: "", usage: "", &block)
        REGISTRY[name] = block
      end
    end

    # --- Built-in commands ---

    register("agents", description: "List running agents", usage: "!agents") do |_args, room_id:, slug:|
      routes = RouteCache.all
      if routes.empty?
        "No agents running."
      else
        routes.sort_by { |name, _| name }.map { |name, r|
          "  #{name} (#{r[:identity]} in ##{r[:slug]})"
        }.join("\n")
      end
    end

    register("status", description: "System status", usage: "!status") do |_args, room_id:, slug:|
      route_count = RouteCache.count
      resolving = RouteCache.resolving_count
      manager = ManagerClient.status
      lines = ["Hub: #{route_count} routes, #{resolving} resolving"]
      lines << "Presence: #{PresenceManager.running? ? 'active' : 'stopped'}"
      if manager
        lines << "Manager: #{manager[:pods]} pods"
      else
        lines << "Manager: unreachable"
      end
      lines.join("\n")
    end

    register("freeze", description: "Freeze an agent", usage: "!freeze <nick>") do |args, room_id:, slug:|
      nick = args.strip
      route = RouteCache.get(nick)
      unless route
        next "#{nick} is not running."
      end

      Thread.new { ManagerClient.release(instance: nick) }
      "Freezing #{nick}..."
    end

    register("rescue", description: "Rescue an unresponsive agent", usage: "!rescue <nick>") do |args, room_id:, slug:|
      nick = args.strip
      route = RouteCache.get(nick)
      unless route
        next "#{nick} is not running."
      end

      Thread.new { ManagerClient.release(instance: nick) }
      RouteCache.delete(nick)
      "Rescuing #{nick}..."
    end

    register("help", description: "List commands", usage: "!help") do |_args, room_id:, slug:|
      "Commands:\n" + REGISTRY.keys.sort.map { |name| "  !#{name}" }.join("\n")
    end
  end
end
