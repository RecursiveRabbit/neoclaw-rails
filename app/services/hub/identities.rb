# Identity configuration. Loaded from config/identities.yml.
# No database — identities change when residents join the town,
# not at runtime.
#
# The Manager has the full config (model, repo, services).
# The Hub needs only: name and singleton flag.

module Hub
  class Identities
    class << self
      def find(name)
        config[name]
      end

      def exists?(name)
        config.key?(name)
      end

      # Singletons use bare name. Everyone else gets name-channel.
      def instance_name_for(name, channel)
        identity = config[name]
        return nil unless identity
        identity[:singleton] ? name : "#{name}-#{channel}"
      end

      def count
        config.size
      end

      def reload!
        @config = nil
      end

      private

      def config
        @config ||= load_config
      end

      def load_config
        file = Rails.root.join("config", "identities.yml")
        return {} unless file.exist?
        data = YAML.safe_load_file(file) || {}
        data.each_with_object({}) do |(name, values), hash|
          v = values || {}
          hash[name.to_s] = {
            singleton: !!v["singleton"]
          }
        end
      end
    end
  end
end
