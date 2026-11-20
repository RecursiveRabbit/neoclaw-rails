require_relative "boot"

# Deliberately NOT require "rails/all".
#
# The Manager has no database, no Active Record, no Active Job, no Action Cable and no
# asset pipeline. What it has is controllers, views, and files. Pulling in the rest
# would put a second copy of the truth somewhere, which is the one thing the spec
# forbids (cove.md §12, "No second copies").
require "rails"
require "action_controller/railtie"

# The state module is required, not autoloaded: its constant is the application's own
# namespace (`Cove` is already defined by this file), and Zeitwerk will not load a file
# that claims a constant already in place.
require_relative "../lib/cove/state"

module Cove
  class Application < Rails::Application
    config.load_defaults 8.1

    config.eager_load = false

    # The Rails app knows nothing about its own front door except that it is real:
    # a secret key for CSRF, and a host list we clear because the fence is the bind
    # address (cove.md §4: "reachable from the host IP only"), not the Host header.
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE") do
      "cove-manager-development-key-not-a-secret-#{Rails.root}"
    end
    config.hosts.clear

    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = ENV.fetch("COVE_LOG_LEVEL", "info").to_sym

    # One query per page load, by design. No caching layer, no fragment cache, no
    # ETag that could outlive the thing it describes.
    config.action_controller.perform_caching = false
  end
end
