# Operator commands — !agents, !freeze, !kill, !status, !help.
# Parsed from Matrix messages before routing. Only operators can execute.

module Hub
  class Commands
    REGISTRY = {}

    # A cap on what the room is shown, and the true length beside it. A silently
    # clipped identity reads like the real one, which is the same fault as seating
    # a default owner: it tells the reader something that is not so.
    IDENTITY_MAX = 96
    VERB_MAX = 32

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

      def execute(command, room_id:, slug:, logger: Rails.logger)
        if (rejected = command[:refused])
          note_refusal(rejected, command[:attempted], room_id: room_id, logger: logger)
          return
        end

        handler = REGISTRY[command[:name]]
        return unless handler

        result = handler.call(command[:args], room_id: room_id, slug: slug)
        Matrix.notify(room_id, result) if result
      rescue => e
        Matrix.notify(room_id, "Command failed: #{e.message}")
      end

      # One notice per sender for the life of the process. The notice exists to
      # show a misconfigured operator their own identity, and that fact needs
      # saying once: a per-message post makes the Manager a relay for whoever
      # knocks, in its own voice, at their chosen rate.
      def notified_senders
        @notified_senders ||= Set.new
      end

      # The notice store is process-lifetime by design, so a row that asserts the
      # post has to start from a known state.
      def forget_notifications!
        notified_senders.clear
      end

      # The log gets the refusal in full: no cap, and inspected so a control
      # character stays escaped and the line stays one line. The room gets the
      # clipped, single-line version, because the room is the megaphone.
      def note_refusal(sender, verb, room_id:, logger: Rails.logger)
        logger.warn(
          "operator refusal: sender=#{sender.to_s.inspect} verb=#{verb.to_s.inspect} " \
          "room=#{room_id.to_s.inspect}"
        )
        return unless notified_senders.add?(sender.to_s)

        Matrix.notify(
          room_id,
          "#{clip(sender, Hub::Commands::IDENTITY_MAX)} is not an operator; " \
          "!#{clip(verb, Hub::Commands::VERB_MAX)} refused"
        )
      end

      def clip(value, limit)
        text = value.to_s
        return one_line(text) if text.length <= limit

        "#{one_line(text[0, limit])}… (#{text.length} chars)"
      end

      # One line, and unambiguously. Every control character, both Unicode line
      # separators, and the backslash itself are ESCAPED, not replaced:
      #
      #   \\   ->  \\
      #   LF   ->  \x0A     (U+000A, and every other C0/C1 character)
      #   U+2028 -> \u{2028} (Zl, line separator)
      #   U+2029 -> \u{2029} (Zp, paragraph separator)
      #
      # A replacement character was the earlier choice and it was forgeable: a
      # sender that literally contains U+FFFD printed the same glyph as a control
      # character we had replaced, so the room could not tell a sanitisation from
      # a value. Escaping the backslash in the same pass closes that: the sender's
      # own `\x0A` comes out as `\\x0A`, which reads differently from the `\x0A` we
      # produced for a real newline.
      def one_line(text)
        text.gsub(/\\|[[:cntrl:]\u2028\u2029]/) do |char|
          case char
          when "\\"     then "\\\\"
          when "\u2028" then "\\u{2028}"
          when "\u2029" then "\\u{2029}"
          else format("\\x%02X", char.ord)
          end
        end
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
