module Hub
  # The operator contract, checked at boot.
  #
  # `NEOCLAW_OPERATORS` has no default (see Config.operators), so a deployment can be
  # in two different broken states that the old silence would have worded the same:
  #
  #   nobody configured an operator   -> every `!` command refuses everyone
  #   somebody configured a localpart -> the same symptom, for a different reason
  #
  # The fix is different in each case, so the words are different. This module is only
  # the words: it never refuses anything, never admits anything, and does not change
  # what the gate does. The gate fails closed either way and the process keeps running,
  # so an operator can read the log and see which fault they have.
  module OperatorContract
    # A full Matrix ID: `@localpart:server`. The server may carry a port, as Matrix
    # permits (`@evans:matrix.home:8448`), so anything after the first colon is the
    # server part and is not inspected further.
    MATCHABLE = /\A@[^:@\s]+:[^\s]+\z/

    EXAMPLE = "NEOCLAW_OPERATORS=@evans:matrix.home".freeze

    class << self
      # [] when there is nothing to say, otherwise one entry per problem:
      #
      #   { kind: :unconfigured }
      #   { kind: :unmatchable, entries: ["evans", "hopper"] }
      def problems(entries)
        return [{ kind: :unconfigured }] if entries.empty?

        bad = entries.reject { |entry| MATCHABLE.match?(entry) }
        bad.empty? ? [] : [{ kind: :unmatchable, entries: bad }]
      end

      # Logs one warning per problem. Returns true when the list was usable.
      def report(entries: Config.operators, logger: Rails.logger)
        found = problems(entries)
        found.each { |problem| logger.warn(self.message(problem)) }
        found.empty?
      end

      def message(problem)
        case problem[:kind]
        when :unconfigured
          "NEOCLAW_OPERATORS is unset or empty: every ! command will be refused and the " \
            "refusal will name the sender. Set it to comma-separated full Matrix IDs, " \
            "e.g. #{EXAMPLE}"
        when :unmatchable
          count = problem[:entries].size
          listed = problem[:entries].map(&:inspect).join(", ")
          "NEOCLAW_OPERATORS contains #{count} entr#{count == 1 ? 'y' : 'ies'} that " \
            "cannot match any sender: #{listed}. Entries must be full Matrix IDs " \
            "(@localpart:server); a bare localpart is never equal to a sender. " \
            "See docs/HUB-ENVIRONMENT.md"
        else
          "NEOCLAW_OPERATORS: #{problem.inspect}"
        end
      end
    end
  end
end
