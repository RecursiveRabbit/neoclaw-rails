Rails.application.routes.draw do
  # ================================================================
  # Hub — per-puppet /sync + agent routing
  # ================================================================

  # Appservice stubs — Synapse expects these. We ack but don't process.
  # Inbound events come via /sync now, not transactions.
  put "/_matrix/app/v1/transactions/:txn_id", to: proc { [200, { "Content-Type" => "application/json" }, ["{}"]] }
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
