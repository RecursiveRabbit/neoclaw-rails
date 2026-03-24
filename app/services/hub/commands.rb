# Operator commands — !agents, !freeze, !kill, !status, !help.
# Parsed from Matrix messages before routing. Only operators can execute.

require "open3"

module Hub
  class Commands
    REGISTRY = {}

    class << self
      def parse(body, sender:)
        return nil unless Config.operators.include?(sender)

        text = strip_leading_mentions(body.to_s.strip)
        return nil if text.empty?
        return nil unless text.start_with?("!", "/")

        parts = text[1..].split(nil, 2)
        return nil if parts.empty?

        name = parts[0].downcase
        return nil unless REGISTRY.key?(name)

        { name: name, args: parts[1] || "", sender: sender, raw: text }
      end

      def execute(command, room_id:, slug:, identity:)
        handler = REGISTRY[command[:name]]
        return unless handler

        result = handler.call(command[:args], room_id: room_id, slug: slug, identity: identity)
        Matrix.notify(room_id, result) if result
      rescue => e
        Matrix.notify(room_id, "Command failed: #{e.message}")
      end

      def strip_leading_mentions(text)
        # Remove one or more leading Matrix/Discord mention tokens.
        # Examples: "<@123> /stop", "<@&123> /stop", "@neoclaw-rails /restart"
        t = text.dup
        loop do
          before = t
          t = t.sub(/\A\s*<@!?&?[^>]+>\s*/, "")
          t = t.sub(/\A\s*@[-\w\.]+\s+/, "")
          break if t == before
        end
        t.strip
      end

      def register(name, description: "", usage: "", &block)
        REGISTRY[name] = block
      end
    end

    # --- Built-in commands ---

    register("agents", description: "List running agents", usage: "!agents /agents") do |_args, room_id:, slug:, identity:|
      routes = RouteCache.all
      if routes.empty?
        "No agents running."
      else
        routes.sort_by { |name, _| name }.map { |name, r|
          "  #{name} (#{r[:identity]} in ##{r[:slug]})"
        }.join("\n")
      end
    end

    register("status", description: "System status", usage: "!status /status") do |_args, room_id:, slug:, identity:|
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

    register("freeze", description: "Freeze an agent", usage: "!freeze <nick> /freeze <nick>") do |args, room_id:, slug:, identity:|
      nick = args.strip
      route = RouteCache.get(nick)
      unless route
        next "#{nick} is not running."
      end

      Thread.new { ManagerClient.release(instance: nick) }
      "Freezing #{nick}..."
    end

    register("rescue", description: "Rescue an unresponsive agent", usage: "!rescue <nick> /rescue <nick>") do |args, room_id:, slug:, identity:|
      nick = args.strip
      route = RouteCache.get(nick)
      unless route
        next "#{nick} is not running."
      end

      Thread.new { ManagerClient.release(instance: nick) }
      RouteCache.delete(nick)
      "Rescuing #{nick}..."
    end

    register("stop", description: "Interrupt current agent run in this room", usage: "/stop") do |_args, room_id:, slug:, identity:|
      nick = "#{identity}-#{slug}"
      route = RouteCache.get(nick)
      unless route
        next "#{nick} is not running."
      end

      ok = Relay.stop(ip: route[:ip])
      ok ? "Stop signal sent to #{nick}." : "Stop failed for #{nick}."
    end

    register("restart", description: "Restart neoclaw-rails service command", usage: "/restart") do |_args, room_id:, slug:, identity:|
      cmd = ENV["NEOCLAW_OPERATOR_RESTART_CMD"].to_s.strip
      if cmd.empty?
        next "Restart not configured. Set NEOCLAW_OPERATOR_RESTART_CMD."
      end

      stdout, stderr, status = Open3.capture3(cmd)
      if status.success?
        "Restart command executed. #{stdout.to_s.strip}".strip
      else
        "Restart command failed (#{status.exitstatus}): #{stderr.to_s.strip}".strip
      end
    end

    register("help", description: "List commands", usage: "!help /help") do |_args, room_id:, slug:, identity:|
      "Commands:\n" + REGISTRY.keys.sort.map { |name| "  /#{name}" }.join("\n")
    end
  end
end
