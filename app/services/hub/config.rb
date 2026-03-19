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

      def operators
        ENV.fetch("NEOCLAW_OPERATORS", "evans,hopper").split(",").map(&:strip).to_set
      end

      def appservice_user
        ENV.fetch("NEOCLAW_APPSERVICE_USER", "neoclaw")
      end
    end
  end
end
