require_relative "boot"
require "rails/all"

Bundler.require(*Rails.groups)

module Manager
  class Application < Rails::Application
    config.load_defaults 8.1
    config.autoload_lib(ignore: %w[assets tasks])

    # The Manager's own SQLite database, separate from the Hub
    config.active_record.encryption = { primary_key: "manager" }
  end
end
