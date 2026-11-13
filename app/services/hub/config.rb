# Hub configuration — all from environment variables.
# One place to look, one place to change.

module Hub
  class Config
    class << self
      def synapse_url
        ENV.fetch("NEOCLAW_SYNAPSE_URL", "http://localhost:8008")
      end

      def server_name
        ENV.fetch("NEOCLAW_SERVER_NAME", "matrix.home")
      end

      def manager_url
        ENV.fetch("NEOCLAW_MANAGER_URL", "http://10.0.0.3:9200")
      end

      def as_token
        ENV.fetch("NEOCLAW_AS_TOKEN")
      end

      def hs_token
        ENV.fetch("NEOCLAW_HS_TOKEN")
      end

      # Who may run `!` commands. EMPTY BY DEFAULT: an unconfigured hub refuses
      # every operator command, and the refusal names the identity it rejected.
      #
      # Evans, 2026-11-12: "No fallbacks. Fallbacks are an illegal concept. If
      # something about that system is failing I need to know, not have some agent
      # smooth it over." A default owner is exactly that smoothing — two hardcoded
      # names admitted by a bot nobody configured. The empty string below is not a
      # fallback: it is the absence of a list, written once instead of arriving as
      # nil at every caller.
      #
      # Entries are full Matrix IDs (`@localpart:server`), because a localpart is
      # not an identity: `@evans:any.federated.server` shares `evans` with the
      # operator and is a different person. A bare localpart here matches nobody —
      # that fails closed, and the refusal shows the operator their own full id so
      # the misconfiguration names itself.
      def operators
        ENV.fetch("NEOCLAW_OPERATORS", "").split(",").map(&:strip).reject(&:empty?).to_set
      end

      def appservice_user
        ENV.fetch("NEOCLAW_APPSERVICE_USER", "neoclaw")
      end

      # Identity list — who gets a /sync loop.
      # Queries Manager at first call, caches for the process lifetime.
      # Falls back to NEOCLAW_IDENTITIES env var if Manager is unreachable.
      def identities
        @identities ||= fetch_identities
      end

      def reload_identities!
        @identities = nil
      end

      private

      def fetch_identities
        response = HTTPX.with(timeout: { operation_timeout: 10 })
          .get("#{manager_url}/identities")

        if response.status == 200
          data = JSON.parse(response.body, symbolize_names: true)
          names = data.map { |entry| entry[:name] }
          Rails.logger.info "Config: loaded #{names.size} identities from Manager"
          names
        else
          Rails.logger.warn "Config: Manager returned #{response.status}, falling back to env var"
          env_identities
        end
      rescue => e
        Rails.logger.warn "Config: Manager unreachable (#{e.message}), falling back to env var"
        env_identities
      end

      def env_identities
        ENV.fetch("NEOCLAW_IDENTITIES", "").split(",").map(&:strip).reject(&:empty?)
      end
    end
  end
end
