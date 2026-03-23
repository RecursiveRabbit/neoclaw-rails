# Start the Watchdog after the Manager finishes loading.
# Detects silent pods and freezes idle agents.
#
# Only start in server mode — skip during rake tasks, console, tests.

Rails.application.config.after_initialize do
  if defined?(Rails::Server) || defined?(Puma)
    Watchdog.start
  end
end
