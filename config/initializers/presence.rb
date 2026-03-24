# Start background services after Rails initializes.
# Skip during rake tasks, console, and tests.

Rails.application.config.after_initialize do
  if defined?(Rails::Server) || defined?(Puma) || ENV["RAILS_SERVE_STATIC_FILES"]
    Hub::SyncManager.start
    Hub::PresenceManager.start
  end
end
