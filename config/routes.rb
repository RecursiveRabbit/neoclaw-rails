Rails.application.routes.draw do
  # ================================================================
  # Hub — Matrix appservice + agent routing
  # ================================================================

  # Synapse sends events here
  put "/_matrix/app/v1/transactions/:txn_id", to: "transactions#create"
  get "/rooms/*path", to: proc { [200, { "Content-Type" => "application/json" }, ["{}"]] }
  get "/users/*path", to: proc { [200, { "Content-Type" => "application/json" }, ["{}"]] }

  # Relay → Hub (agent responses flow back here)
  post "/agent/message", to: "agents#message"
  post "/agent/event",   to: "agents#event"
  post "/diagnostic",    to: "agents#diagnostic"

  # Manager → Hub callbacks (released, sunset_warning, crash)
  post "/callback", to: "callbacks#create"

  # ================================================================
  # Health
  # ================================================================

  get "/health", to: "health#show"
  get "up" => "rails/health#show", as: :rails_health_check
end
