require "action_dispatch/middleware/session/cookie_store"

module Cove
  class Application < Rails::Application
    # CSRF protection is on, so the session middleware has to actually exist.
    # A Rails app assembled without `rails/all` does not get it by default, and a
    # form that posts a sheet is exactly the kind of thing CSRF exists for.
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore,
                          key: "_cove_manager_session", same_site: :lax
  end
end
