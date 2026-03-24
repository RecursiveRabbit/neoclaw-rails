# Start the CronScheduler after the Manager finishes loading.
# Checks for due cron messages every 30 seconds and fires them via Hub.
#
# Only start in server mode — skip during rake tasks, console, tests.

Rails.application.config.after_initialize do
  if defined?(Rails::Server) || defined?(Puma)
    CronScheduler.start
  end
end
