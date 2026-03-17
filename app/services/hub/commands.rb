# Operator commands — !agents, !freeze, !kill, !status, !help, !cron.
# Parsed from Matrix messages before routing. Only operators can execute.

module Hub
  class Commands
    REGISTRY = {}

    class << self
      # Parse a !command from a message. Returns nil if not a command.
      def parse(body, sender:)
        return nil unless body.strip.start_with?("!")
        return nil unless Config.operators.include?(sender)

        parts = body.strip[1..].split(nil, 2)
        return nil if parts.empty?

        name = parts[0].downcase
        return nil unless REGISTRY.key?(name)

        { name: name, args: parts[1] || "", sender: sender }
      end

      # Execute a parsed command.
      def execute(command, room:)
        handler = REGISTRY[command[:name]]
        return unless handler

        result = handler.call(command[:args], room: room)
        Matrix.notify(room.matrix_room_id, result) if result
      rescue => e
        Matrix.notify(room.matrix_room_id, "Command failed: #{e.message}")
      end

      def register(name, description: "", usage: "", &block)
        REGISTRY[name] = block
      end
    end

    # --- Built-in commands ---

    register("agents", description: "List running agents", usage: "!agents") do |_args, room:|
      agents = Agent.alive.includes(:identity, :room)
      if agents.empty?
        "No agents running."
      else
        agents.order(:instance_name).map { |a|
          uptime = distance_of_time(Time.current - a.created_at)
          ctx = a.context_usage > 0 ? "#{(a.context_usage * 100).round}%" : "—"
          "  #{a.instance_name} (#{a.identity.name} in ##{a.room.slug}) — #{uptime}, ctx #{ctx}"
        }.join("\n")
      end
    end

    register("status", description: "System status", usage: "!status") do |_args, room:|
      agents = Agent.alive.count
      resolving = Agent.resolving.count
      manager = ManagerClient.status
      lines = ["Hub: #{agents} alive, #{resolving} resolving"]
      if manager
        lines << "Manager: #{manager[:pods]} pods"
      else
        lines << "Manager: unreachable"
      end
      lines.join("\n")
    end

    register("freeze", description: "Freeze an agent", usage: "!freeze <nick>") do |args, room:|
      nick = args.strip
      agent = Agent.alive.find_by(instance_name: nick)
      unless agent
        next "#{nick} is not running."
      end

      Thread.new { ManagerClient.release(instance: nick) }
      "Freezing #{nick}..."
    end

    register("kill", description: "Kill immediately", usage: "!kill <nick>") do |args, room:|
      nick = args.strip
      agent = Agent.alive.find_by(instance_name: nick)
      unless agent
        next "#{nick} is not running."
      end

      Thread.new { ManagerClient.release(instance: nick) }
      agent.destroy!
      "Killed #{nick}."
    end

    register("help", description: "List commands", usage: "!help") do |_args, room:|
      "Commands:\n" + REGISTRY.keys.sort.map { |name| "  !#{name}" }.join("\n")
    end

    private_class_method def self.distance_of_time(seconds)
      s = seconds.to_i
      m, s = s.divmod(60)
      h, m = m.divmod(60)
      "#{h}h#{m.to_s.rjust(2, '0')}m"
    end
  end
end
