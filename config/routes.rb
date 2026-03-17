Rails.application.routes.draw do
  # ================================================================
  # Admin UI (Manager)
  # ================================================================

  root "dashboard#index"
  resources :agent_configs
  resources :containers, only: [:index, :show] do
    member do
      post :freeze
      post :kill
      get :stream
    end
  end
  resources :audit_logs, only: [:index]

  # ================================================================
  # Hub — Matrix appservice + agent routing
  # ================================================================

  put "/_matrix/app/v1/transactions/:txn_id", to: "transactions#create"
  get "/rooms/*path", to: proc { [200, { "Content-Type" => "application/json" }, ["{}"]] }
  get "/users/*path", to: proc { [200, { "Content-Type" => "application/json" }, ["{}"]] }

  # Relay → Hub
  post "/agent/message", to: "agents#message"
  post "/agent/event", to: "agents#event"
  post "/diagnostic", to: "agents#diagnostic"

  # Manager → Hub callbacks
  post "/callback", to: "callbacks#create"

  # ================================================================
  # Manager API — Hub calls these to resolve/release agents
  # ================================================================

  post "/resolve", to: "resolve#create"
  post "/release", to: "resolve#release"

  # Relay → Manager
  post "/containers/:instance/output", to: "stream#output"
  post "/containers/:instance/health", to: "stream#health"

  # ================================================================
  # Health
  # ================================================================

  get "/health", to: "health#show"
  get "up" => "rails/health#show", as: :rails_health_check
end
