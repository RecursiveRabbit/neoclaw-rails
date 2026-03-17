class ApplicationController < ActionController::Base
  # Hub is a pure API — no browser checks, no CSRF.
  # Receives HTTP from Synapse, relays, and the Manager.
  skip_forgery_protection
end
