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

    # No silent fallback. A predictable secret means forgeable session cookies, so in
    # production the app refuses to boot without one rather than inventing one from the
    # path it happens to be installed at. bin/entrypoint generates a per-boot secret for
    # the container, because this Manager stores no secret at rest.
    config.secret_key_base =
      if Rails.env.production?
        ENV.fetch("SECRET_KEY_BASE") do
          abort "[cove] SECRET_KEY_BASE is required in production. " \
                "Run bin/entrypoint (it generates one per boot) or set it yourself."
        end
      else
        ENV.fetch("SECRET_KEY_BASE", "cove-development-key-not-a-secret")
      end

    # The fence is the bind address (cove.md §4: "reachable from the host IP only"), not
    # the Host header — the Manager is published on loopback and nowhere else.
    config.hosts.clear

    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = ENV.fetch("COVE_LOG_LEVEL", "info").to_sym

    # One query per page load, by design. No caching layer, no fragment cache, no ETag
    # that could outlive the thing it describes.
    config.action_controller.perform_caching = false
  end
end
