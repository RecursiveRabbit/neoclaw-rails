# Start the PresenceManager after Rails finishes loading.
# Runs a background thread that refreshes Matrix presence for running agents.
#
# Only start in server mode — skip during rake tasks, console, tests.

Rails.application.config.after_initialize do
  if defined?(Rails::Server) || defined?(Puma)
    Hub::PresenceManager.start
  end
end
