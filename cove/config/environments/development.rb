# Development and production differ here in exactly one thing worth naming:
# reloading. Nothing else about the Manager changes between them, because nothing
# about it depends on a database, a cache, or an asset build.
Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.active_support.deprecation = :log
  config.action_controller.raise_on_missing_callback_actions = true
end
