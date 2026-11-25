require_relative "boot"

# Deliberately NOT require "rails/all".
#
# The Manager has no database, no Active Record, no Active Job, no Action Cable and no
# asset pipeline. What it has is controllers, views, and files. Pulling in the rest
# would put a second copy of the truth somewhere, which is the one thing the spec
# forbids (cove.md §12, "No second copies").
# ACTIVE RECORD IS IN. Evans, 2026-11-25: "Everything about Cove lives in a relational
# database. There are no data files."
#
# The paragraph that used to stand here argued for the opposite, and its argument is worth
# keeping because it was the right argument aimed at the wrong thing: "Pulling in the rest
# would put a second copy of the truth somewhere, which is the one thing the spec forbids."
# That was true of a cache and is inverse for a database. The SECOND COPY was the files:
# the plan on disk said 10.99 while the repo said 10.201, a sheet's pod_ip lived in one
# YAML while the Router's permits were rendered from another, and the deploy could leave
# the two disagreeing indefinitely with nothing able to say so. One row is one copy.
require "rails"
require "active_record/railtie"
require "action_controller/railtie"

# The state module is required, not autoloaded: its constant is the application's own
# namespace (`Cove` is already defined by this file), and Zeitwerk will not load a file
# that claims a constant already in place.
require_relative "../lib/cove/state"
# The rest of the library is required for the same reason, in the order the
# dependencies run: the plan reads state and names pools, the keys live in state,
# and the network is the only thing that talks to the kernel. Rails 8 does not put
# lib/ on the autoload path, and a constant that resolves in development because a
# test loaded it is exactly the kind of green that cannot fail.
require_relative "../lib/cove/plan"
require_relative "../lib/cove/keys"
require_relative "../lib/cove/network"

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
