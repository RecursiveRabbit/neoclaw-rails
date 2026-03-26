# Start background services after Rails initializes.
# Skip during rake tasks, console, and tests.

Rails.application.config.after_initialize do
  if defined?(Puma)
    Hub::SyncManager.start
    Hub::PresenceManager.start
  end
end
